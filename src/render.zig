//! The diff: two grids in, the fewest bytes that move the terminal from one
//! to the other out.
//!
//! The renderer holds the only state the render pass keeps — the frame the
//! terminal was last shown, and the style, link and cursor it was left in.
//! `draw` is a function of that state, the screen and the capabilities, to
//! bytes on a `*std.Io.Writer`. It allocates nothing, flushes nothing, and
//! can be asserted on without a terminal, which is the whole reason the
//! bytes and the grid are two packages.
//!
//! Three rules run the emit path, and each of them is a measurement rather
//! than a preference. Changed cells go out as **runs**, one cursor move and
//! one style pen apiece, because a move per cell costs more than repainting
//! the screen. A row whose diff would cost more than writing it whole is
//! written whole, and both are priced exactly rather than guessed at. And a
//! row holding a grapheme the terminal might measure differently is never
//! diffed at all.
//!
//! Every sequence written here comes from `morse`. There is no string
//! literal of escape bytes in this file, and a reviewer can check that with
//! `grep`.
//!
//! What this file will never hold: a widget, a layout, an event, a thread, a
//! timeout, a flush of the caller's writer, or an allocation on the frame
//! path.

const std = @import("std");
const morse = @import("morse");

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const moved_rows = @import("moved_rows.zig");
const Layers = @import("layer.zig").Layers;
const textmod = @import("text.zig");
const Caps = @import("caps.zig").Caps;
const Screen = @import("screen.zig").Screen;
const tty = @import("tty.zig");

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Point = geom.Point;
const Size = geom.Size;
pub const Style = cellmod.Style;
const Writer = std.Io.Writer;

/// Where a program's screen goes on the way in.
pub const Mode = enum {
    /// The alternate screen: the whole terminal, and the user's scrollback
    /// untouched underneath.
    alt,
    /// The main screen, at the cursor. The screen's rows are taken from the
    /// row the cursor is on, the terminal scrolling to make room for the
    /// ones that do not fit, and on the way out the last frame is left
    /// showing with the cursor on the row below it. Growing takes more rows
    /// the same way; shrinking gives them back blank.
    ///
    /// No row of the terminal is known by number here, so every move is
    /// relative: to the cursor, or to an origin saved with `DECSC` at the
    /// first row and restored when the cursor is not trusted. Scroll
    /// detection is off, because a scrolling region is an absolute thing.
    /// After the terminal itself is resized the origin is wherever the
    /// terminal put the saved cursor, which is the most anything can know
    /// without asking.
    @"inline",
};

/// The input a program asks the terminal for, beside the screen it takes.
///
/// Every field is off by default, and whatever `enter` turns on `leave` turns
/// off again, and nothing else: a mode the program never asked for is left as
/// the terminal had it.
pub const Modes = struct {
    /// Keys in the kitty protocol, with these flags. Pushed onto the
    /// terminal's keyboard stack on the way in and popped on the way out, so
    /// the flags the shell had come back. The stack is per screen, which is
    /// why the push comes after the switch to the alternate screen and the
    /// pop before the switch back.
    keyboard: ?morse.KittyFlags = null,
    /// Which mouse reports to send, or null for none: one motion and one
    /// encoding, as the terminal keeps them. `enter` puts the terminal's
    /// mouse in exactly this state, whatever was on before, and the way out
    /// turns this motion and this encoding off.
    mouse: ?morse.Mouse = null,
    /// Focus in and out reports, mode 1004.
    focus: bool = false,
    /// Pasted text bracketed, mode 2004, so it can be told from typing.
    paste: bool = false,
    /// Unprompted reports when the palette turns light or dark, mode 2031.
    color_scheme: bool = false,
};

/// Turns off the mouse `m` put on: its motion and its encoding. On a
/// terminal that keeps each as one setting, either `l` resets the whole
/// setting; on one that keeps a flag per mode, these are the only two flags
/// `morse.mouse` left on. Either way the mouse is off and nothing else was
/// touched.
fn mouseOff(w: *Writer, m: morse.Mouse) Writer.Error!void {
    try morse.setMode(w, m.motion.number(), false);
    try morse.setMode(w, m.encoding.number(), false);
}

/// From one mouse the terminal is known to be in to another, writing only
/// the settings that differ: the old mode off before the new one on, so the
/// `l` cannot reset the setting the `h` just made.
fn mouseChange(w: *Writer, was: ?morse.Mouse, now: ?morse.Mouse) Writer.Error!void {
    const old = was orelse {
        if (now) |m| try morse.mouse(w, m);
        return;
    };
    const new = now orelse return mouseOff(w, old);
    if (old.motion != new.motion) {
        try morse.setMode(w, old.motion.number(), false);
        try morse.setMode(w, new.motion.number(), true);
    }
    if (old.encoding != new.encoding) {
        try morse.setMode(w, old.encoding.number(), false);
        try morse.setMode(w, new.encoding.number(), true);
    }
}

/// What the previous frame holds where the renderer does not know what the
/// terminal shows: a cell with no grapheme at all, which no write puts on a
/// screen. No row of a screen is ever equal to it or blank beside it, so a
/// row of it is always written whole, blanks erased rather than skipped.
const unknown: Cell = .{ .text = .{ .buf = @splat(0), .len = 0 }, .style = .{}, .link = .none, .shape = .{} };

/// Anything `draw`, `enter` or `leave` can fail with.
pub const Error = Writer.Error || error{
    /// The screen is not the size the renderer was made or resized to.
    SizeMismatch,
};

/// The frame size at or below which the synchronised-output bracket is not
/// worth its sixteen bytes.
///
/// A frame small enough for the terminal to take in one read does not tear,
/// and the bracket costs more than the frame saves. What decides "one read"
/// is the pseudo-terminal between the program and the terminal, not either
/// end's buffer: macOS hands the terminal a program's write 1024 bytes at a
/// time, however large the write, so a frame past that arrives in pieces a
/// terminal can draw between.
pub const sync_gate = 1024;

/// The last frame, and the style, link and cursor the terminal is currently
/// in.
pub const Renderer = struct {
    /// The allocator `init` was given.
    gpa: Allocator,
    /// The size both the previous frame and the screen must be.
    size: Size,
    /// What the terminal was last shown.
    prev: []Cell,
    /// Rows the renderer has its own reason to write whole.
    force: []bool,
    /// Rows that have ever held a grapheme the two width models disagree
    /// about. A change of width method repaints all of them, touched or not:
    /// a terminal that clips a row it measures wider than the model does is
    /// not something the model can see happen.
    drifted: []bool,
    /// Rows of `prev` a cell diff cannot safely cross. Unlike `drifted`,
    /// this follows scrolling content and is cleared when the row becomes
    /// safe again.
    untrusted: []bool,
    /// A hash of each row of `prev` and of the screen, for finding a frame
    /// whose rows moved.
    hashes: []u64,
    /// The renderer's own write buffer. A frame that fits in it is written
    /// to the caller in one go, which is what lets the synchronised-output
    /// bracket be decided after the frame's size is known.
    buf: []u8,
    /// SGR spellings already constructed for style pairs this renderer has
    /// seen. A collision only rebuilds one spelling.
    style_sequences: StyleSequenceCache = .{},

    /// The style the terminal is in.
    style: Style = .{},
    /// The link the terminal has open.
    link: Link = .none,
    /// Where the terminal's cursor is, or null when the renderer does not
    /// know — after a scroll, after a repaint, after a row whose width the
    /// terminal may have disagreed about, and after a write into the last
    /// column, where a terminal holds a wrap pending.
    cursor: ?Point = null,
    /// Whether the terminal is showing its cursor, or null when unknown.
    shown: ?bool = null,
    /// The shape the terminal is drawing its cursor as, or null when
    /// unknown.
    shape: ?morse.CursorShape = null,
    /// The width method the last frame was drawn under.
    method: ?textmod.Method = null,
    /// Whether the next draw writes every cell.
    repaint_all: bool = false,
    /// What `enter` turned on, so `leave` turns off exactly that.
    entered: ?Entered = null,
    /// In inline mode, how many rows of the terminal are the screen's,
    /// counted from the saved origin; null in the alternate screen. The next
    /// repaint takes or gives back rows when this and `size.rows` differ.
    region: ?u16 = null,

    /// The modes `enter` switched, remembered so `leave` is its mirror.
    pub const Entered = struct {
        /// Which screen the program took.
        mode: Mode,
        /// Whether in-band resize reports were turned on.
        in_band_resize: bool,
        /// Whether the terminal was asked to measure clusters, mode 2027.
        unicode_core: bool,
        /// The input modes in effect: what `enter` set, as `setModes` has
        /// changed it since.
        modes: Modes = .{},
    };

    /// What one `draw` cost, so a budget can be a test rather than a
    /// comment.
    ///
    /// The counters come in pairs: what the diff did not have to write
    /// against what it did. A renderer that gets worse moves them, and a
    /// test that pins them says so.
    pub const Stats = struct {
        /// Cells whose grapheme was written out.
        cells: u32 = 0,
        /// Cells the diff looked at and did not write.
        skipped: u32 = 0,
        /// Runs of cells written, each of which cost a cursor move.
        runs: u32 = 0,
        /// Bytes written to the caller's writer.
        bytes: usize = 0,
        /// Rows the diff looked at.
        rows: u32 = 0,
        /// Rows written whole because the diff would have cost more, or
        /// because their widths could not be trusted.
        repainted: u32 = 0,
        /// Rows the terminal moved for us, rather than rows repainted.
        scrolled: u32 = 0,
        /// Cells erased with one sequence rather than painted as spaces.
        erased: u32 = 0,
        /// Cells drawn by repeating the one before them rather than written
        /// out, where the terminal has `REP`.
        repeated: u32 = 0,
        /// Cells whose width was told to the terminal rather than agreed
        /// with it, through the text sizing protocol.
        told: u32 = 0,
        /// Graphemes drawn at more than one cell's size.
        scaled: u32 = 0,
        /// Style changes written.
        styles: u32 = 0,
        /// Link changes written.
        links: u32 = 0,
        /// Cursor moves written.
        moves: u32 = 0,
        /// Graphics commands written, after the text pass.
        placements: u32 = 0,
    };

    /// Allocates the previous frame.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Renderer {
        var r: Renderer = .{
            .gpa = gpa,
            .size = size,
            .prev = &.{},
            .force = &.{},
            .drifted = &.{},
            .untrusted = &.{},
            .hashes = &.{},
            .buf = &.{},
        };
        try r.allocate(gpa, size);
        return r;
    }

    /// Gives the previous frame back.
    ///
    /// A renderer a `Tty` entered through is forgotten by the panic path
    /// here, so the way out never reaches for a renderer that is gone.
    pub fn deinit(r: *Renderer, gpa: Allocator) void {
        tty.forget(r);
        r.release(gpa);
        r.* = undefined;
    }

    /// A new size. The next draw writes every cell of every row, blank ones
    /// included: what the terminal did to its rows on the way -- kept what
    /// fitted, cut it, moved it up with the cursor, or took in a frame drawn
    /// at the old size after it had changed -- is its own business, and
    /// nothing about what it now shows is known.
    pub fn resize(r: *Renderer, gpa: Allocator, size: Size) Allocator.Error!void {
        var next: Renderer = .{
            .gpa = gpa,
            .size = size,
            .prev = &.{},
            .force = &.{},
            .drifted = &.{},
            .untrusted = &.{},
            .hashes = &.{},
            .buf = &.{},
        };
        try next.allocate(gpa, size);
        r.release(gpa);
        r.size = size;
        r.prev = next.prev;
        r.force = next.force;
        r.drifted = next.drifted;
        r.untrusted = next.untrusted;
        r.hashes = next.hashes;
        r.buf = next.buf;
        r.repaint();
    }

    /// The next `draw` writes every cell, as though the terminal could be
    /// showing anything: the previous frame is forgotten, so a row the
    /// screen holds blank is erased rather than taken to be blank already.
    pub fn repaint(r: *Renderer) void {
        r.repaint_all = true;
        r.cursor = null;
        @memset(r.prev, unknown);
    }

    /// One row written whole, absolutely positioned, as though the terminal
    /// could be showing anything on it. What a caller that suspects one row
    /// gives it.
    pub fn repaintRow(r: *Renderer, row: u16) void {
        if (row >= r.force.len) return;
        r.force[row] = true;
        @memset(r.prev[@as(usize, row) * r.size.cols ..][0..r.size.cols], unknown);
    }

    /// Writes the difference between the last frame and this one: the grid,
    /// then the pictures in `layers` when the program shows any. Allocates
    /// nothing. Never flushes the caller's writer.
    ///
    /// The grid is text and nothing else, and the pictures beside it are the
    /// program's to keep; the renderer takes both because it is the one
    /// that orders them, the text pass whole before the first graphics
    /// command. A program that shows no pictures passes null.
    pub fn draw(r: *Renderer, w: *Writer, s: *Screen, layers: ?*Layers, caps: Caps) Error!Stats {
        if (!std.meta.eql(r.size, s.size)) return error.SizeMismatch;
        // The emit path updates its model while it constructs the frame. If
        // any write fails, none of those updates describe what the terminal
        // received, so the next attempt must establish the whole frame from
        // an absolute position again. Damage and layers are committed only
        // after the caller accepted every byte below.
        errdefer r.repaint();
        var stats: Stats = .{};

        // A terminal told to measure clusters differently has redrawn
        // everything the two models disagreed about, and the model cannot
        // see it happen.
        if (r.method) |was| {
            if (was != caps.width_method) r.forceDrifted();
        }
        r.method = caps.width_method;

        const pictures = if (layers) |l| l.declared.items.len != 0 or l.count() != 0 else false;
        const body = r.repaint_all or s.damage.any() or r.anyForced() or pictures;
        const tail = r.cursorWork(s);
        if (!body and !tail) {
            s.damage.clear();
            return stats;
        }

        var frame: Frame = .init(w, r.buf, caps.sync and !caps.sync_unwanted);
        const out = &frame.writer;

        if (r.repaint_all) {
            try r.beginRepaint(out, caps);
            // The terminal's pictures are as unknown as its text.
            if (layers) |l| l.repaint();
        }
        if (body) {
            if (caps.scroll_detection and r.region == null) {
                if (try moved_rows.apply(r, out, s, caps)) |moved| stats.scrolled = moved;
            }
            try r.drawRows(out, s, caps, &stats);
        }
        // Between frames the terminal carries no open link. It costs the
        // seven bytes that close one on the frame that opened it, and it
        // means a cell written next frame never pays for a link it has
        // nothing to do with.
        if (body) {
            var ignored: Stats = .{};
            try r.setLink(out, s, .none, caps, &ignored);
        }
        // After the text pass, never inside it: the rule this package exists
        // to keep is that redrawing a cell cannot disturb a picture.
        if (layers) |l| stats.placements = @intCast(try l.emit(out, caps));
        if (stats.placements != 0) r.cursor = null;
        try r.finishCursor(out, s);

        try frame.finish();
        if (body) {
            s.damage.clear();
            @memset(r.force, false);
            r.repaint_all = false;
        }
        if (layers) |l| l.commitFrame(caps);
        stats.bytes = frame.n;
        return stats;
    }

    /// What a full-screen program writes on the way in, in one call: the
    /// screen it takes and the input it wants.
    ///
    /// Synchronised output is deliberately not here. Mode 2026 is a bracket
    /// around one frame, not a mode a session sits in: left on, every
    /// terminal that invented a timeout for it repaints at that timeout
    /// instead of when the program asks, which is ten frames a second on the
    /// tightest of them. `draw` writes the bracket, and only when the frame
    /// is large enough to be worth it.
    pub fn enter(r: *Renderer, w: *Writer, caps: Caps, mode: Mode, modes: Modes) Error!void {
        // Record every mode before it may have reached a partially failing
        // writer. Disabling a mode that never arrived is harmless; omitting
        // one that did arrive leaves the caller's terminal changed.
        r.entered = .{
            .mode = mode,
            .in_band_resize = caps.in_band_resize,
            .unicode_core = caps.width_method == .unicode,
            .modes = modes,
        };
        r.region = if (mode == .@"inline") r.size.rows else null;
        if (mode == .alt) try morse.altScreen.set(w, true);
        // After the switch: the alternate screen has a keyboard stack of its
        // own, and this push belongs on it.
        if (modes.keyboard) |flags| try morse.kittyKeyboardPush(w, flags);
        if (modes.mouse) |m| try morse.mouse(w, m);
        if (modes.focus) try morse.focusEvents.set(w, true);
        if (modes.paste) try morse.bracketedPaste.set(w, true);
        if (modes.color_scheme) try morse.colorScheme.set(w, true);
        if (caps.in_band_resize) try morse.inBandResize.set(w, true);
        if (caps.width_method == .unicode) try morse.unicodeCore.set(w, true);
        try morse.resetStyle(w);
        switch (mode) {
            .alt => {
                try morse.clearScreen(w, .all);
                try morse.cursorTo(w, 1, 1);
            },
            .@"inline" => {
                // From the start of the row the prompt left the cursor on.
                try w.writeByte('\r');
                try r.reserve(w, r.size.rows);
            },
        }
        try morse.cursorVisible.set(w, false);

        @memset(r.prev, .blank(.{}));
        @memset(r.force, false);
        @memset(r.drifted, false);
        @memset(r.untrusted, false);
        r.style = .{};
        r.link = .none;
        r.cursor = .{ .col = 0, .row = 0 };
        r.shown = false;
        r.shape = null;
        r.repaint_all = false;
    }

    /// Anything `setModes` can fail with.
    pub const ModesError = Writer.Error || error{
        /// The renderer has not entered a screen, so there is nothing to
        /// change and nothing that would undo the change.
        NotEntered,
    };

    /// Changes the input modes mid-session — mouse reports for one view and
    /// not another, say — writing only what differs, and remembers the
    /// change so `leave` undoes what is in effect then.
    pub fn setModes(r: *Renderer, w: *Writer, modes: Modes) ModesError!void {
        const was = if (r.entered) |e| e.modes else return error.NotEntered;
        r.entered.?.modes = modes;
        if (was.keyboard) |old| {
            if (modes.keyboard) |new| {
                if (old != new) try morse.kittyKeyboardSet(w, new, .replace);
            } else try morse.kittyKeyboardPop(w);
        } else if (modes.keyboard) |new| try morse.kittyKeyboardPush(w, new);
        try mouseChange(w, was.mouse, modes.mouse);
        if (was.focus != modes.focus) try morse.focusEvents.set(w, modes.focus);
        if (was.paste != modes.paste) try morse.bracketedPaste.set(w, modes.paste);
        if (was.color_scheme != modes.color_scheme) try morse.colorScheme.set(w, modes.color_scheme);
    }

    /// The same in reverse, exactly and only what `enter` turned on, plus the
    /// one thing that has to be written whether or not it was.
    ///
    /// Synchronised output goes off unconditionally: a program that died
    /// between the bracket's two halves has left the terminal holding the
    /// screen still, and the only way out is to say so.
    pub fn leave(r: *Renderer, w: *Writer) Error!void {
        try morse.syncOutput.set(w, false);
        const was = r.entered orelse return;
        if (r.link != .none) {
            try morse.hyperlinkEnd(w);
            r.link = .none;
        }
        try morse.resetStyle(w);
        r.style = .{};
        if (r.shape) |_| {
            try morse.cursorShape(w, .default);
            r.shape = null;
        }
        try morse.cursorVisible.set(w, true);
        r.shown = true;
        if (was.unicode_core) try morse.unicodeCore.set(w, false);
        if (was.in_band_resize) try morse.inBandResize.set(w, false);
        if (was.modes.color_scheme) try morse.colorScheme.set(w, false);
        if (was.modes.paste) try morse.bracketedPaste.set(w, false);
        if (was.modes.focus) try morse.focusEvents.set(w, false);
        if (was.modes.mouse) |m| try mouseOff(w, m);
        // Before the switch back: the stack this pops is the alternate
        // screen's own.
        if (was.modes.keyboard != null) try morse.kittyKeyboardPop(w);
        switch (was.mode) {
            .alt => try morse.altScreen.set(w, false),
            .@"inline" => {
                // The last frame stays. The cursor goes to the origin, down
                // the screen's rows, and one line feed further, which is the
                // row below when there is one and a scroll when there is not.
                try morse.cursorRestore(w);
                const rows = r.region orelse r.size.rows;
                if (rows > 1) try morse.cursorDown(w, rows - 1);
                try w.writeByte('\n');
                try w.writeByte('\r');
            },
        }
        r.region = null;
        r.entered = null;
    }

    /// In inline mode, makes the rows from the cursor's row the screen's,
    /// `rows` of them: the terminal scrolls for the ones that do not fit, the
    /// origin is saved on the first, and everything from there down is
    /// erased. The cursor is at the start of a row when this is called and
    /// at the origin when it returns.
    fn reserve(r: *Renderer, w: *Writer, rows: u16) Error!void {
        if (rows > 1) {
            try w.splatByteAll('\n', rows - 1);
            try morse.cursorUp(w, rows - 1);
        }
        try morse.cursorSave(w);
        if (rows > 0) try morse.clearScreen(w, .to_end);
        r.region = rows;
        r.cursor = .{ .col = 0, .row = 0 };
    }

    /// Back to the saved origin, which also puts the style back to the
    /// default it was saved in.
    fn home(r: *Renderer, out: *Writer) Error!void {
        try morse.cursorRestore(out);
        r.cursor = .{ .col = 0, .row = 0 };
        r.style = .{};
    }

    //=====================================================================
    // What the scroll detector reaches for.
    //=====================================================================

    /// One row of the previous frame.
    fn prevRow(r: *const Renderer, row: u16) []const Cell {
        return r.prev[@as(usize, row) * r.size.cols ..][0..r.size.cols];
    }

    /// Moves the previous frame's rows the way the terminal just moved the
    /// real ones, and marks the rows it vacated to be written whole.
    fn shiftPrev(r: *Renderer, top: u16, bottom: u16, distance: u16, up: bool) void {
        const cols = r.size.cols;
        const blank: Cell = .blank(.{});
        const region = r.prev[@as(usize, top) * cols ..][0 .. @as(usize, bottom - top + 1) * cols];
        const untrusted = r.untrusted[top .. @as(usize, bottom) + 1];
        const moved = @as(usize, distance) * cols;
        if (up) {
            std.mem.copyForwards(Cell, region[0 .. region.len - moved], region[moved..]);
            @memset(region[region.len - moved ..], blank);
            std.mem.copyForwards(bool, untrusted[0 .. untrusted.len - distance], untrusted[distance..]);
            @memset(untrusted[untrusted.len - distance ..], false);
            for (bottom + 1 - distance..bottom + 1) |row| r.force[row] = true;
        } else {
            std.mem.copyBackwards(Cell, region[moved..], region[0 .. region.len - moved]);
            @memset(region[0..moved], blank);
            std.mem.copyBackwards(bool, untrusted[distance..], untrusted[0 .. untrusted.len - distance]);
            @memset(untrusted[0..distance], false);
            for (top..top + distance) |row| r.force[row] = true;
        }
    }

    //=====================================================================
    // The frame, row by row.
    //=====================================================================

    /// Takes the memory the renderer needs, all of it at once.
    fn allocate(r: *Renderer, gpa: Allocator, size: Size) Allocator.Error!void {
        r.prev = try gpa.alloc(Cell, size.area());
        errdefer gpa.free(r.prev);
        @memset(r.prev, .blank(.{}));
        r.force = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(r.force);
        @memset(r.force, false);
        r.drifted = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(r.drifted);
        @memset(r.drifted, false);
        r.untrusted = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(r.untrusted);
        @memset(r.untrusted, false);
        r.hashes = try gpa.alloc(u64, @as(usize, size.rows) * 2);
        errdefer gpa.free(r.hashes);
        r.buf = try gpa.alloc(u8, sync_gate);
    }

    /// Gives all of it back.
    fn release(r: *Renderer, gpa: Allocator) void {
        gpa.free(r.prev);
        gpa.free(r.force);
        gpa.free(r.drifted);
        gpa.free(r.untrusted);
        gpa.free(r.hashes);
        gpa.free(r.buf);
    }

    /// Whether any row carries the renderer's own reason to be written.
    fn anyForced(r: *const Renderer) bool {
        for (r.force) |f| if (f) return true;
        return false;
    }

    /// Marks every row that has ever drifted to be written whole.
    fn forceDrifted(r: *Renderer) void {
        for (r.drifted, r.force) |d, *f| {
            if (d) f.* = true;
        }
    }

    /// Whether the cursor's place, visibility or shape needs a sequence.
    fn cursorWork(r: *const Renderer, s: *const Screen) bool {
        if (s.cursor.visible) {
            if (r.shown != true) return true;
            if (r.shape != s.cursor.shape) return true;
            const at = r.cursor orelse return true;
            return at.col != s.cursor.col or at.row != s.cursor.row;
        }
        return r.shown != false;
    }

    /// The cursor is hidden before the first byte a frame writes, and not
    /// before.
    ///
    /// A frame that turns out to have nothing to write must write nothing at
    /// all, and a damage map that named a row whose contents did not change
    /// is the ordinary case rather than the odd one -- a program that marks
    /// what it redrew rather than what it changed produces one every frame.
    /// Hiding the cursor up front and showing it again at the end costs
    /// twelve bytes on every one of them, and breaks the property the whole
    /// package is checked against.
    ///
    /// Called by the render pass, including from the scroll detector; not
    /// part of what a program using this package calls.
    fn hideForWrite(r: *Renderer, out: *Writer) Error!void {
        if (r.shown == false) return;
        try morse.cursorVisible.set(out, false);
        r.shown = false;
    }

    /// The terminal is in a state the renderer does not know, so it is put
    /// into one it does: the style, the link and the cursor reset, and every
    /// row written whole over whatever the previous frame, now `unknown`,
    /// could not say.
    ///
    /// On the alternate screen there is no erase first. An erase of the
    /// display takes every picture on it down with it, and the rule this
    /// package keeps is that drawing text never disturbs a picture. Every
    /// row written whole, its blanks erased to the end of the line, leaves
    /// no cell of the terminal's grid unwritten without it.
    fn beginRepaint(r: *Renderer, out: *Writer, caps: Caps) Error!void {
        try r.hideForWrite(out);
        if (caps.osc8) try morse.hyperlinkEnd(out);
        r.link = .none;
        try morse.resetStyle(out);
        r.style = .{};
        r.cursor = null;
        @memset(r.force, true);
        // Inline, a repaint starts from the origin with the screen's rows
        // taken or given back if the size changed, and everything from the
        // origin down erased: the previous frame is then exactly blank,
        // which is the one state a repaint can be sure of.
        if (r.region) |had| {
            try r.home(out);
            if (had != r.size.rows) {
                try r.reserve(out, r.size.rows);
            } else {
                try morse.clearScreen(out, .to_end);
            }
            @memset(r.prev, .blank(.{}));
            @memset(r.untrusted, false);
        }
    }

    /// Every row that changed, in order.
    fn drawRows(r: *Renderer, out: *Writer, s: *Screen, caps: Caps, stats: *Stats) Error!void {
        const cols = r.size.cols;
        if (cols == 0) return;
        var row: u16 = 0;
        while (row < r.size.rows) : (row += 1) {
            const span = s.damage.row(row);
            const forced = r.force[row];
            if (span == null and !forced) continue;
            const first = if (forced) 0 else span.?.first;
            const last = if (forced) cols - 1 else span.?.last;

            // A row the damage map named but nothing really changed in is
            // one whole-row comparison away from costing nothing.
            if (!forced and r.rowUnchanged(s, caps, row, first, last)) {
                stats.skipped += cols;
                continue;
            }
            const scan_first = if (r.untrusted[row]) 0 else first;
            const scan_last = if (r.untrusted[row]) cols - 1 else last;
            const current_untrusted = rowDrifts(s, caps, row, scan_first, scan_last);
            const drift = r.untrusted[row] or current_untrusted;
            if (drift) r.drifted[row] = true;
            stats.rows += 1;

            const whole = forced or drift or try r.paintIsCheaper(s, caps, row, first, last);
            if (whole) stats.repainted += 1;
            try r.hideForWrite(out);
            try r.emitRow(out, s, caps, row, first, last, whole, stats);
            // An over-measured cluster runs past the margin and wraps, so
            // after a drifted row the cursor may be a row low as well as a
            // column off. Nothing but an absolute move is safe.
            if (drift and !widthsAgree(caps)) r.cursor = null;
            r.commitRow(s, caps, row, first, last);
            r.untrusted[row] = current_untrusted;
        }
    }

    /// Whether a row holds what the terminal is already showing.
    ///
    /// One `memcmp` over the conservative damage span where every cell is
    /// shown as it is held, because the previous frame then holds the cells
    /// as they were written. Where the terminal has no OSC 8 or no scaled
    /// text, a link or a scale is not a difference it can show and the
    /// previous frame does not record one, so the comparison has to strip it
    /// rather than find a difference nothing could write.
    fn rowUnchanged(r: *const Renderer, s: *const Screen, caps: Caps, row: u16, first: u16, last: u16) bool {
        const now = s.rowAt(row)[first .. @as(usize, last) + 1];
        const was = r.prevRow(row)[first .. @as(usize, last) + 1];
        if (shownAsHeld(caps)) return cellmod.rowsEqual(now, was);
        for (now, was) |current, previous| {
            if (!visible(current, caps).eql(previous)) return false;
        }
        return true;
    }

    /// Whether a row holds a grapheme whose width the terminal might not
    /// agree with, or a wide one at all.
    ///
    /// A cell diff cannot safely step across a glyph whose width the two ends
    /// measure differently, and it cannot land on a covered column at all.
    /// The disagreement is worked out once, when the cell is written, so this
    /// is a scan of one bit per cell. The caller scans only damage while the
    /// previous row is trusted, and the whole row while it is not. Where the
    /// terminal measures clusters the way this package does, or is told the
    /// width of every cluster it could disagree about, only wide cells matter.
    fn rowDrifts(s: *const Screen, caps: Caps, row: u16, first: u16, last: u16) bool {
        const agree = widthsAgree(caps);
        for (s.rowAt(row)[first .. @as(usize, last) + 1]) |raw| {
            const c = visible(raw, caps);
            if (c.width() != 1) return true;
            if (!agree and c.shape.drift) return true;
        }
        return false;
    }

    /// Whether writing the row whole costs fewer bytes than diffing it.
    ///
    /// Both are counted with the same state transitions as emission, so the
    /// answer is the exact byte count and not an estimate. A narrow span
    /// cannot lose, so it is not priced.
    fn paintIsCheaper(
        r: *Renderer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
    ) Error!bool {
        const cols = r.size.cols;
        if (@as(u32, last - first) + 1 <= cols / 2) return false;
        if (first == 0 and last == cols - 1 and r.allChanged(s, caps, row)) return true;
        const floor = r.paintTextFloor(s, caps, row);
        if (r.isolatedDiffCost(s, caps, row, first, last, floor)) |diff| {
            if (diff < floor) return false;
        }
        const diff = try r.price(s, caps, row, first, last, false);
        const paint = try r.price(s, caps, row, 0, cols - 1, true);
        return paint <= diff;
    }

    /// Whether every cell in a row differs from what the terminal shows.
    /// In that case diffing and painting emit the same row, so the tie goes
    /// to painting without pricing either one.
    fn allChanged(r: *const Renderer, s: *const Screen, caps: Caps, row: u16) bool {
        for (s.rowAt(row), r.prevRow(row)) |now, was| {
            if (visible(now, caps).eql(was)) return false;
        }
        return true;
    }

    /// A valid, deliberately unbridged diff. The real planner can only make
    /// it shorter, so beating the unavoidable text in a whole row proves the
    /// diff wins without pricing either candidate in full.
    fn isolatedDiffCost(
        r: *Renderer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
        limit: usize,
    ) ?usize {
        const cells = s.rowAt(row);
        const old = r.prevRow(row);
        var state: CostState = .{ .style = r.style, .link = r.link, .cursor = r.cursor };
        var cost: usize = 0;
        var col = first;
        while (col <= last) {
            if (visible(cells[col], caps).eql(old[col])) {
                col += 1;
                continue;
            }
            const from = col;
            while (col < last and !visible(cells[col + 1], caps).eql(old[col + 1])) col += 1;
            cost += r.moveCost(&state, from, row);
            cost += r.writeCellsCost(&state, s, caps, row, from, col, false);
            if (cost >= limit) return null;
            col += 1;
        }
        return cost;
    }

    /// Bytes a whole-row paint cannot avoid. Pen, link, cursor and erase
    /// sequences are omitted; text sizing and REP are retained because they
    /// change how many text bytes the paint actually needs.
    fn paintTextFloor(_: *Renderer, s: *Screen, caps: Caps, row: u16) usize {
        const cells = s.rowAt(row);
        const end = trailingBlank(cells, caps);
        var cost: usize = 0;
        var col: u16 = 0;
        while (col < end) {
            const c = visible(cells[col], caps);
            if (c.isTail()) {
                col += 1;
                continue;
            }
            const text: []const u8 = if (cells[col].isTail()) " " else s.textOf(&cells[col]);
            if (c.isScaled()) cost += 15 else if (toldWidth(c, caps)) cost += 11;
            cost += text.len;
            col += c.width();
            if (caps.rep and repeatable(c, text)) {
                const same = sameRunLen(cells, col, end - 1, visible(c, caps), caps);
                if (@as(usize, same) > 3 + digits(same)) {
                    cost += 3 + digits(same);
                    col += same;
                }
            }
        }
        return cost;
    }

    /// What one way of writing a row costs, in bytes, without emitting it or
    /// changing the renderer.
    fn price(
        r: *Renderer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
        whole: bool,
    ) Error!u64 {
        var state: CostState = .{
            .style = r.style,
            .link = r.link,
            .cursor = r.cursor,
        };
        return if (whole)
            r.paintRowCost(&state, s, caps, row)
        else
            r.diffRowCost(&state, s, caps, row, first, last);
    }

    /// The arithmetic counterpart of `paintRow`.
    fn paintRowCost(r: *Renderer, state: *CostState, s: *Screen, caps: Caps, row: u16) usize {
        const cols = r.size.cols;
        const cells = s.rowAt(row);
        const erase_from = trailingBlank(cells, caps);

        if (erase_from == 0) {
            if (r.rowIsBlank(row)) return 0;
            return r.moveCost(state, 0, row) + r.eraseToEndCost(state, s, caps);
        }
        var cost = r.moveCost(state, 0, row);
        cost += r.writeCellsCost(state, s, caps, row, 0, erase_from - 1, true);
        if (erase_from < cols) {
            cost += r.moveCost(state, erase_from, row);
            cost += r.eraseToEndCost(state, s, caps);
        }
        return cost;
    }

    /// The arithmetic counterpart of `diffRow`.
    fn diffRowCost(
        r: *Renderer,
        state: *CostState,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
    ) usize {
        const cols = r.size.cols;
        const cells = s.rowAt(row);
        const old = r.prevRow(row);

        var cost: usize = 0;
        var col = first;
        while (col <= last) {
            if (visible(cells[col], caps).eql(old[col])) {
                col += 1;
                continue;
            }
            const run_end = r.runEndCost(state.*, s, caps, row, col, last);
            const erase_from = if (run_end == cols - 1) @max(col, trailingBlank(cells, caps)) else cols;
            const paint_to = if (erase_from <= run_end) erase_from else run_end + 1;

            cost += r.moveCost(state, col, row);
            if (paint_to > col) {
                cost += r.writeCellsCost(state, s, caps, row, col, paint_to - 1, true);
            }
            if (erase_from <= run_end) {
                cost += r.moveCost(state, erase_from, row);
                cost += r.eraseToEndCost(state, s, caps);
            }
            col = run_end + 1;
        }
        return cost;
    }

    /// The arithmetic counterpart of `eraseToEnd`.
    fn eraseToEndCost(r: *Renderer, state: *CostState, s: *Screen, caps: Caps) usize {
        return setStyleCost(r, state, .{}) + setLinkCost(state, s, .none, caps) + clear_line_cost;
    }

    /// The arithmetic counterpart of `writeCells`.
    fn writeCellsCost(
        r: *Renderer,
        state: *CostState,
        s: *Screen,
        caps: Caps,
        row: u16,
        from: u16,
        to: u16,
        erase_tail: bool,
    ) usize {
        const cells = s.rowAt(row);
        const erase_from = if (erase_tail)
            @max(from, trailingBlank(cells[0 .. @as(usize, to) + 1], caps))
        else
            to + 1;
        var cost: usize = 0;
        var col = from;
        while (col <= to) {
            const c = visible(cells[col], caps);
            if (c.isTail()) {
                col += 1;
                continue;
            }
            cost += r.moveCost(state, col, row);
            if (erase_tail and col == erase_from) {
                const blanks = to - col + 1;
                if (blanks > erase_cost) {
                    cost += setStyleCost(r, state, .{});
                    cost += setLinkCost(state, s, .none, caps);
                    return cost + 3 + digits(blanks);
                }
            }
            cost += setStyleCost(r, state, c.style);
            cost += setLinkCost(state, s, c.link, caps);
            const text: []const u8 = if (cells[col].isTail()) " " else s.textOf(&cells[col]);
            if (c.isScaled()) {
                // OSC 66, two one-digit keys, their separator, the metadata
                // terminator and ST.
                cost += 15 + text.len;
            } else if (toldWidth(c, caps)) {
                // OSC 66, one one-digit width key, the metadata terminator
                // and ST.
                cost += 11 + text.len;
            } else if (r.marksApart(c, text, caps)) {
                // Mode 2027 off and on again around it.
                cost += 16 + text.len;
            } else {
                cost += text.len;
            }
            col += c.width();
            if (caps.rep and repeatable(c, text)) {
                const same = sameRunLen(cells, col, to, visible(c, caps), caps);
                if (@as(usize, same) > 3 + digits(same)) {
                    cost += 3 + digits(same);
                    col += same;
                }
            }
            r.advanceCost(state, col, row);
        }
        return cost;
    }

    /// Advances the priced terminal state past a non-empty changed stretch.
    /// Diffable rows contain only one-column visible cells, so the last cell
    /// determines the pen and the cursor without pricing the stretch whose
    /// bytes the caller does not use.
    fn writeCellsState(r: *Renderer, state: *CostState, s: *Screen, caps: Caps, row: u16, from: u16, to: u16) void {
        const cells = s.rowAt(row);
        const c = visible(cells[to], caps);
        state.style = c.style;
        if (caps.osc8) {
            for (cells[from .. @as(usize, to) + 1]) |raw| {
                const link = visible(raw, caps).link;
                if (state.link != link) {
                    state.link = if (link == .none or s.target(link) != null) link else .none;
                }
            }
        }
        r.advanceCost(state, to + 1, row);
    }

    /// Whether text alone already makes a bridge dearer than `limit`.
    /// Styles, links and moves can only add bytes, so this can reject a long
    /// gap before pricing any of them. REP is handled by the caller because
    /// it can make repeated text shorter than its byte lengths.
    fn textCostExceeds(s: *Screen, caps: Caps, row: u16, from: u16, to: u16, limit: usize) bool {
        const cells = s.rowAt(row);
        var cost: usize = 0;
        var col = from;
        while (col <= to) {
            const c = visible(cells[col], caps);
            if (c.isTail()) {
                col += 1;
                continue;
            }
            const text: []const u8 = if (cells[col].isTail()) " " else s.textOf(&cells[col]);
            cost += text.len;
            if (c.isScaled()) cost += 15 else if (toldWidth(c, caps)) cost += 11;
            if (cost > limit) return true;
            col += c.width();
        }
        return false;
    }

    /// Plans a run exactly as `runEnd` does, while counting instead of
    /// writing the candidate bridge and move.
    fn runEndCost(
        r: *Renderer,
        initial: CostState,
        s: *Screen,
        caps: Caps,
        row: u16,
        col: u16,
        last: u16,
    ) u16 {
        const cells = s.rowAt(row);
        const old = r.prevRow(row);
        var state = initial;

        var end = col;
        var scan: u32 = @as(u32, col) + 1;
        while (scan <= last and !visible(cells[scan], caps).eql(old[scan])) : (scan += 1) end = @intCast(scan);
        r.writeCellsState(&state, s, caps, row, col, end);

        while (scan <= last) {
            const gap: u16 = @intCast(scan);
            while (scan <= last and visible(cells[scan], caps).eql(old[scan])) : (scan += 1) {}
            if (scan > last) break;
            const next: u16 = @intCast(scan);

            var moved = state;
            var move_cost = r.moveCost(&moved, next, row);
            move_cost += r.writeCellsCost(&moved, s, caps, row, next, next, false);
            if (!caps.rep and textCostExceeds(s, caps, row, gap, next, move_cost)) return end;

            var bridged = state;
            const bridge_cost = r.writeCellsCost(&bridged, s, caps, row, gap, next, false);

            if (bridge_cost > move_cost) return end;
            state = bridged;
            end = next;
            if (next == last) return end;
            scan = @as(u32, next) + 1;

            const more: u16 = @intCast(scan);
            while (scan <= last and !visible(cells[scan], caps).eql(old[scan])) : (scan += 1) end = @intCast(scan);
            if (scan > more) r.writeCellsState(&state, s, caps, row, more, end);
        }
        return end;
    }

    /// One row, either whole or only where it changed.
    fn emitRow(
        r: *Renderer,
        out: *Writer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
        whole: bool,
        stats: *Stats,
    ) Error!void {
        if (whole) return r.paintRow(out, s, caps, row, stats);
        return r.diffRow(out, s, caps, row, first, last, stats);
    }

    /// A whole row, written from an absolute position.
    fn paintRow(r: *Renderer, out: *Writer, s: *Screen, caps: Caps, row: u16, stats: *Stats) Error!void {
        const cols = r.size.cols;
        const cells = s.rowAt(row);
        const erase_from = trailingBlank(cells, caps);

        if (erase_from == 0) {
            if (r.rowIsBlank(row)) return;
            try r.moveTo(out, 0, row, stats);
            try r.eraseToEnd(out, s, caps, stats, cols);
            return;
        }
        try r.moveTo(out, 0, row, stats);
        stats.runs += 1;
        try r.writeCells(out, s, caps, row, 0, erase_from - 1, stats, true);
        if (erase_from < cols) {
            try r.moveTo(out, erase_from, row, stats);
            try r.eraseToEnd(out, s, caps, stats, cols - erase_from);
        }
    }

    /// The cells of a row that changed, in as few runs as the cursor moves
    /// make worthwhile.
    fn diffRow(
        r: *Renderer,
        out: *Writer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
        stats: *Stats,
    ) Error!void {
        const cols = r.size.cols;
        const cells = s.rowAt(row);
        const old = r.prevRow(row);

        var col = first;
        while (col <= last) {
            if (visible(cells[col], caps).eql(old[col])) {
                stats.skipped += 1;
                col += 1;
                continue;
            }
            const run_end = r.runEnd(s, caps, row, col, last);

            // A run that reaches the end of the row and ends in default
            // blanks is erased rather than painted.
            const erase_from = if (run_end == cols - 1) @max(col, trailingBlank(cells, caps)) else cols;
            const paint_to = if (erase_from <= run_end) erase_from else run_end + 1;

            try r.moveTo(out, col, row, stats);
            if (paint_to > col) {
                stats.runs += 1;
                try r.writeCells(out, s, caps, row, col, paint_to - 1, stats, true);
            }
            if (erase_from <= run_end) {
                try r.moveTo(out, erase_from, row, stats);
                try r.eraseToEnd(out, s, caps, stats, cols - erase_from);
            }
            col = run_end + 1;
        }
    }

    /// Erases from the cursor to the end of the row, which is four bytes
    /// however many cells it covers.
    fn eraseToEnd(r: *Renderer, out: *Writer, s: *Screen, caps: Caps, stats: *Stats, cells: u16) Error!void {
        try r.setStyle(out, .{}, stats);
        try r.setLink(out, s, .none, caps, stats);
        try morse.clearLine(out, .to_end);
        stats.erased += cells;
    }

    /// Writes cells `from` to `to`, both ends inside, assuming the cursor is
    /// already at `from`.
    ///
    /// With `erase_tail`, a run of default blanks at the end of the range is
    /// erased rather than painted: it costs fewer bytes and leaves the cursor
    /// where it is, which the next move knows. Run planning turns that off so
    /// both ways across an unchanged gap arrive at the first changed cell in
    /// the same terminal state.
    ///
    /// Where the terminal has `REP`, a run of one narrow single-codepoint
    /// glyph in one style is the glyph once and a repeat count. The count
    /// has to save more than its own bytes, and it never spans a grapheme
    /// that is more than one codepoint, because what a terminal repeats
    /// after one of those is the last codepoint and not the cluster.
    fn writeCells(
        r: *Renderer,
        out: *Writer,
        s: *Screen,
        caps: Caps,
        row: u16,
        from: u16,
        to: u16,
        stats: *Stats,
        erase_tail: bool,
    ) Error!void {
        const cells = s.rowAt(row);
        const erase_from = if (erase_tail)
            @max(from, trailingBlank(cells[0 .. @as(usize, to) + 1], caps))
        else
            to + 1;
        var col = from;
        while (col <= to) {
            const c = visible(cells[col], caps);
            if (c.isTail()) {
                // Covered by a grapheme written elsewhere: the cell is never
                // written, and the cursor has to be put past it by hand when
                // that grapheme is on another row.
                col += 1;
                continue;
            }
            try r.moveTo(out, col, row, stats);
            if (erase_tail and col == erase_from) {
                const blanks = to - col + 1;
                if (blanks > erase_cost) {
                    try r.setStyle(out, .{}, stats);
                    try r.setLink(out, s, .none, caps, stats);
                    try morse.eraseChars(out, blanks);
                    stats.erased += blanks;
                    return;
                }
            }
            try r.setStyle(out, c.style, stats);
            try r.setLink(out, s, c.link, caps, stats);
            // A covered cell shown as a blank is a space, whatever the head
            // it carried the text of.
            const text: []const u8 = if (cells[col].isTail()) " " else s.textOf(&cells[col]);
            if (c.isScaled()) {
                try morse.textSize(out, .{ .scale = c.shape.scale, .width = c.glyphWidth() }, text);
                stats.scaled += 1;
            } else if (toldWidth(c, caps)) {
                try morse.textSize(out, .{ .width = c.glyphWidth() }, text);
                stats.told += 1;
            } else if (r.marksApart(c, text, caps)) {
                try morse.unicodeCore.set(out, false);
                try out.writeAll(text);
                try morse.unicodeCore.set(out, true);
            } else {
                try out.writeAll(text);
            }
            stats.cells += 1;
            col += c.width();
            if (caps.rep and repeatable(c, text)) {
                const same = sameRunLen(cells, col, to, visible(c, caps), caps);
                if (@as(usize, same) > 3 + digits(same)) {
                    try morse.repeatChar(out, same);
                    stats.cells += same;
                    stats.repeated += same;
                    col += same;
                }
            }
            r.advance(col, row);
        }
    }

    /// Whether a cluster goes out with mode 2027 off around it: a base and
    /// the marks that combine with it, in the one column of a screen one
    /// column wide, on a terminal measuring clusters.
    ///
    /// A terminal measuring clusters decides whether a codepoint joins the
    /// cell before the cursor or the one under it, and the one under it is
    /// only taken when the cursor is past the first column: after the base
    /// fills the only column, the cursor waits there to wrap, and one such
    /// terminal (Ghostty, whose grid the conformance build reads) drops the
    /// mark that follows rather than join it. Measuring by codepoint, a
    /// terminal joins a codepoint of no width to the cell under a cursor
    /// waiting to wrap, so the cluster is written that way. Only clusters
    /// that are nothing but a base and codepoints of no width to either
    /// measure qualify: anything else would take a cell of its own measured
    /// by codepoint, and wrap.
    fn marksApart(r: *const Renderer, c: Cell, text: []const u8, caps: Caps) bool {
        if (r.size.cols != 1 or caps.width_method != .unicode) return false;
        if (c.isScaled() or c.width() != 1 or text.len < 2) return false;
        const codepoints = std.unicode.utf8CountCodepoints(text) catch return false;
        if (codepoints < 2) return false;
        return textmod.combinesOnly(text) and textmod.graphemeWidth(text, .wcwidth) == 1;
    }

    /// The last column of the run starting at `col`.
    ///
    /// At every unchanged gap, both continuing the run and moving to the
    /// next changed cell are counted exactly. Including that changed cell
    /// makes the two candidates meet with the same style, link and cursor,
    /// so the cheaper choice cannot make a later choice dearer.
    fn runEnd(
        r: *Renderer,
        s: *Screen,
        caps: Caps,
        row: u16,
        col: u16,
        last: u16,
    ) u16 {
        const state: CostState = .{ .style = r.style, .link = r.link, .cursor = r.cursor };
        return r.runEndCost(state, s, caps, row, col, last);
    }

    /// Copies a row's conservative damage span into the previous frame.
    fn commitRow(r: *Renderer, s: *const Screen, caps: Caps, row: u16, first: u16, last: u16) void {
        const cells = s.rowAt(row)[first .. @as(usize, last) + 1];
        const row_start = @as(usize, row) * r.size.cols;
        const old = r.prev[row_start + first .. row_start + @as(usize, last) + 1];
        if (shownAsHeld(caps)) {
            @memcpy(old, cells);
            return;
        }
        for (cells, old) |c, *o| o.* = visible(c, caps);
    }

    /// Whether the previous frame's row is already blank in the default
    /// style, in which case erasing it writes nothing.
    fn rowIsBlank(r: *const Renderer, row: u16) bool {
        for (r.prevRow(row)) |c| if (!c.isBlankIn(.{})) return false;
        return true;
    }

    //=====================================================================
    // The terminal's state: style, link, cursor.
    //=====================================================================

    /// Writes the shortest SGR between the style the terminal is in and the
    /// one it should be in.
    fn setStyle(r: *Renderer, out: *Writer, to: Style, stats: *Stats) Error!void {
        if (std.mem.eql(u8, std.mem.asBytes(&r.style), std.mem.asBytes(&to))) return;
        const from = r.style;
        if (r.style_sequences.get(from, to)) |sequence| {
            try out.writeAll(sequence);
        } else {
            var bytes: [StyleSequenceCache.max_len]u8 = undefined;
            var fixed: Writer = .fixed(&bytes);
            morse.diffStyle(&fixed, from, to) catch {
                try morse.diffStyle(out, from, to);
                r.style = to;
                stats.styles += 1;
                return;
            };
            const sequence = fixed.buffered();
            r.style_sequences.put(from, to, sequence);
            try out.writeAll(sequence);
        }
        r.style = to;
        stats.styles += 1;
    }

    /// Opens, closes or swaps the OSC 8 link the terminal has open.
    fn setLink(
        r: *Renderer,
        out: *Writer,
        s: *const Screen,
        to: Link,
        caps: Caps,
        stats: *Stats,
    ) Error!void {
        if (!caps.osc8 or r.link == to) return;
        if (to == .none) {
            try morse.hyperlinkEnd(out);
        } else {
            const t = s.target(to) orelse {
                try morse.hyperlinkEnd(out);
                r.link = .none;
                stats.links += 1;
                return;
            };
            try morse.hyperlinkStart(out, t.uri, if (t.params.len == 0) null else t.params);
        }
        r.link = to;
        stats.links += 1;
    }

    /// Records that the cursor moved to `col` by having written a cell. A
    /// write that filled the last column leaves the terminal holding a wrap,
    /// which is a state no arithmetic should be done from.
    fn advance(r: *Renderer, col: u16, row: u16) void {
        if (col >= r.size.cols) {
            r.cursor = null;
        } else {
            r.cursor = .{ .col = col, .row = row };
        }
    }

    /// The arithmetic counterpart of `advance`.
    fn advanceCost(r: *Renderer, state: *CostState, col: u16, row: u16) void {
        if (col >= r.size.cols) {
            state.cursor = null;
        } else {
            state.cursor = .{ .col = col, .row = row };
        }
    }

    /// The arithmetic counterpart of `moveTo`, including the style reset a
    /// saved-origin restore performs in inline mode.
    fn moveCost(r: *Renderer, state: *CostState, col: u16, row: u16) usize {
        const there: Point = .{ .col = col, .row = row };
        if (state.cursor) |at| {
            if (at.col == col and at.row == row) return 0;
        }

        const cost: usize = if (r.region != null) region: {
            const origin: Point = .{ .col = 0, .row = 0 };
            const from_origin = plan(origin, there, .region);
            const via_origin: usize = if (col == 0 and row == 0) 2 else 2 + from_origin.cost;
            if (state.cursor) |at| {
                const direct = plan(at, there, .region);
                if (direct.cost <= via_origin) break :region direct.cost;
            }
            state.style = .{};
            break :region via_origin;
        } else if (state.cursor) |at|
            plan(at, there, .screen).cost
        else
            absoluteCost(there);
        state.cursor = there;
        return cost;
    }

    /// Puts the cursor at a place in the fewest bytes.
    fn moveTo(r: *Renderer, out: *Writer, col: u16, row: u16, stats: *Stats) Error!void {
        const there: Point = .{ .col = col, .row = row };
        if (r.cursor) |at| {
            if (at.col == col and at.row == row) return;
        }
        if (r.region != null) {
            try r.moveWithin(out, there);
        } else if (r.cursor) |at| {
            try writeMove(out, at, there);
        } else {
            try morse.cursorTo(out, row + 1, col + 1);
        }
        r.cursor = there;
        stats.moves += 1;
    }

    /// A move in inline mode, where no row of the terminal is known by
    /// number: the cheaper of a relative move from where the cursor is and a
    /// restore to the saved origin followed by a relative move from there.
    fn moveWithin(r: *Renderer, out: *Writer, to: Point) Error!void {
        const origin: Point = .{ .col = 0, .row = 0 };
        const from_origin = plan(origin, to, .region);
        const via_origin: usize = if (to.col == 0 and to.row == 0) 2 else 2 + from_origin.cost;
        if (r.cursor) |at| {
            const direct = plan(at, to, .region);
            if (direct.cost <= via_origin) {
                try emitMove(out, at, to, direct.choice);
                return;
            }
        }
        try r.home(out);
        if (to.col == 0 and to.row == 0) return;
        try emitMove(out, origin, to, from_origin.choice);
    }

    /// The cursor, its shape and its visibility, settled at the end of the
    /// frame.
    fn finishCursor(r: *Renderer, out: *Writer, s: *const Screen) Error!void {
        var ignored: Stats = .{};
        if (!s.cursor.visible) {
            if (r.shown != false) {
                try morse.cursorVisible.set(out, false);
                r.shown = false;
            }
            return;
        }
        if (r.shape != s.cursor.shape) {
            try morse.cursorShape(out, s.cursor.shape);
            r.shape = s.cursor.shape;
        }
        try r.moveTo(
            out,
            @min(s.cursor.col, r.size.cols -| 1),
            @min(s.cursor.row, r.size.rows -| 1),
            &ignored,
        );
        if (r.shown != true) {
            try morse.cursorVisible.set(out, true);
            r.shown = true;
        }
    }
};

//=========================================================================
// The pieces the renderer's methods are made of.
//=========================================================================

/// The terminal state carried through an arithmetic price.
const CostState = struct {
    style: Style,
    link: Link,
    cursor: ?Point,
};

/// Constructed SGR transitions. Formatting colour parameters is much more
/// work than copying the result, and real interfaces draw from a small style
/// vocabulary even when adjacent pairs are varied.
const StyleSequenceCache = struct {
    const count = 512;
    const max_len = 128;
    const Entry = struct {
        from: Style = .{},
        to: Style = .{},
        bytes: [max_len]u8 = undefined,
        len: u8 = 0,
        cost: u8 = 0,
        valid: bool = false,
        cost_valid: bool = false,
    };

    entries: [count]Entry = @splat(.{}),

    fn entry(cache: *StyleSequenceCache, from: Style, to: Style) *Entry {
        var hash = styleHash(from) *% 0x9e3779b185ebca87 ^ styleHash(to) *% 0xc2b2ae3d27d4eb4f;
        hash ^= hash >> 33;
        hash *%= 0xff51afd7ed558ccd;
        hash ^= hash >> 33;
        return &cache.entries[hash & (count - 1)];
    }

    /// A cheap index for the fixed-layout style. Equality is still checked
    /// on every hit, so a collision changes only how often a cost is rebuilt.
    fn styleHash(style: Style) u64 {
        const bytes = std.mem.asBytes(&style);
        comptime std.debug.assert(@sizeOf(Style) == 22);
        return std.mem.readInt(u64, bytes[0..8], .little) *% 0x9e3779b185ebca87 ^
            std.mem.readInt(u64, bytes[8..16], .little) *% 0xc2b2ae3d27d4eb4f ^
            @as(u64, std.mem.readInt(u32, bytes[16..20], .little)) *% 0x165667b19e3779f9 ^
            @as(u64, std.mem.readInt(u16, bytes[20..22], .little)) *% 0x85ebca77c2b2ae63;
    }

    fn get(cache: *StyleSequenceCache, from: Style, to: Style) ?[]const u8 {
        const found = cache.entry(from, to);
        if (!found.valid or !matches(found, from, to)) return null;
        return found.bytes[0..found.len];
    }

    fn getCost(cache: *StyleSequenceCache, from: Style, to: Style) ?usize {
        const found = cache.entry(from, to);
        if (!found.cost_valid or !matches(found, from, to)) return null;
        return found.cost;
    }

    fn put(cache: *StyleSequenceCache, from: Style, to: Style, sequence: []const u8) void {
        std.debug.assert(sequence.len <= max_len);
        const found = cache.entry(from, to);
        found.from = from;
        found.to = to;
        @memcpy(found.bytes[0..sequence.len], sequence);
        found.len = @intCast(sequence.len);
        found.cost = @intCast(sequence.len);
        found.valid = true;
        found.cost_valid = true;
    }

    fn putCost(cache: *StyleSequenceCache, from: Style, to: Style, cost: usize) void {
        std.debug.assert(cost <= max_len);
        const found = cache.entry(from, to);
        found.from = from;
        found.to = to;
        found.cost = @intCast(cost);
        found.valid = false;
        found.cost_valid = true;
    }

    fn matches(found: *const Entry, from: Style, to: Style) bool {
        return std.mem.eql(u8, std.mem.asBytes(&found.from), std.mem.asBytes(&from)) and
            std.mem.eql(u8, std.mem.asBytes(&found.to), std.mem.asBytes(&to));
    }
};

/// One SGR parameter list, counted rather than written.
const SgrCost = struct {
    n: usize = 0,
    any: bool = false,
    turned_off: bool = false,

    fn open(p: *SgrCost) void {
        if (p.any) {
            p.n += 1;
        } else {
            p.n += 2;
            p.any = true;
        }
    }

    fn code(p: *SgrCost, value: u8) void {
        p.open();
        p.n += digits(value);
    }

    fn offCode(p: *SgrCost, value: u8) void {
        p.turned_off = true;
        p.code(value);
    }

    fn compound(p: *SgrCost, len: usize) void {
        p.open();
        p.n += len;
    }

    fn field(p: *SgrCost, value: u8) void {
        p.n += 1 + digits(value);
    }

    fn finish(p: *SgrCost) void {
        if (p.any) p.n += 1;
    }
};

/// Counts one foreground or background colour parameter.
fn colorCost(p: *SgrCost, color: morse.Color, default_code: u8, base: u8, bright_base: u8, extended: u8) void {
    switch (color.kind) {
        .default => p.offCode(default_code),
        .ansi => {
            const slot = color.index();
            p.code(if (slot < 8) base + slot else bright_base + (slot - 8));
        },
        .palette => {
            p.code(extended);
            p.n += 3 + digits(color.index());
        },
        .rgb => {
            p.code(extended);
            p.n += 3 + digits(color.r);
            p.field(color.g);
            p.field(color.b);
        },
    }
}

/// Counts one underline-colour parameter.
fn underlineColorCost(p: *SgrCost, color: morse.Color) void {
    switch (color.kind) {
        .default => p.offCode(59),
        .ansi, .palette => {
            p.compound(5);
            p.n += digits(color.index());
        },
        .rgb => {
            p.compound(6);
            p.n += digits(color.r);
            p.n += 1 + digits(color.g);
            p.n += 1 + digits(color.b);
        },
    }
}

/// Counts either spelling of one SGR transition.
fn sgrCost(from: Style, to: Style, reset: bool) SgrCost {
    var p: SgrCost = .{};
    if (reset) p.code(0);
    const base: Style = if (reset) .{} else from;

    const off_bold_dim = (base.bold and !to.bold) or (base.dim and !to.dim);
    if (off_bold_dim) p.offCode(22);
    if (base.italic and !to.italic) p.offCode(23);
    if (base.underline != .none and to.underline == .none) p.offCode(24);
    if (base.blink and !to.blink) p.offCode(25);
    if (base.reverse and !to.reverse) p.offCode(27);
    if (base.hidden and !to.hidden) p.offCode(28);
    if (base.strikethrough and !to.strikethrough) p.offCode(29);
    if (base.overline and !to.overline) p.offCode(55);
    if (base.script != to.script and to.script == .none) p.offCode(75);

    if (to.bold and (!base.bold or off_bold_dim)) p.code(1);
    if (to.dim and (!base.dim or off_bold_dim)) p.code(2);
    if (to.italic and !base.italic) p.code(3);
    if (to.underline != base.underline and to.underline != .none) {
        if (to.underline == .single) {
            p.code(4);
        } else {
            p.compound(2);
            p.n += digits(@intFromEnum(to.underline));
        }
    }
    if (to.blink and !base.blink) p.code(5);
    if (to.reverse and !base.reverse) p.code(7);
    if (to.hidden and !base.hidden) p.code(8);
    if (to.strikethrough and !base.strikethrough) p.code(9);
    if (to.overline and !base.overline) p.code(53);
    if (to.script != base.script and to.script != .none) p.code(@intFromEnum(to.script));

    if (!base.fg.eql(to.fg)) colorCost(&p, to.fg, 39, 30, 90, 38);
    if (!base.bg.eql(to.bg)) colorCost(&p, to.bg, 49, 40, 100, 48);
    if (!base.underline_color.eql(to.underline_color)) underlineColorCost(&p, to.underline_color);
    p.finish();
    return p;
}

/// The shortest SGR transition, by the same arithmetic as `morse.diffStyle`.
fn styleCost(from: Style, to: Style) usize {
    if (std.mem.eql(u8, std.mem.asBytes(&from), std.mem.asBytes(&to))) return 0;
    const delta = sgrCost(from, to, false);
    if (!delta.turned_off) return delta.n;
    return @min(delta.n, sgrCost(from, to, true).n);
}

fn setStyleCost(r: *Renderer, state: *CostState, to: Style) usize {
    if (std.mem.eql(u8, std.mem.asBytes(&state.style), std.mem.asBytes(&to))) return 0;
    const from = state.style;
    const n = r.style_sequences.getCost(from, to) orelse cost: {
        const computed = styleCost(from, to);
        r.style_sequences.putCost(from, to, computed);
        break :cost computed;
    };
    state.style = to;
    return n;
}

/// The OSC 8 transition cost, including the target strings for an open.
fn setLinkCost(state: *CostState, s: *const Screen, to: Link, caps: Caps) usize {
    if (!caps.osc8 or state.link == to) return 0;
    if (to == .none) {
        state.link = .none;
        return hyperlink_end_cost;
    }
    const target = s.target(to) orelse {
        state.link = .none;
        return hyperlink_end_cost;
    };
    state.link = to;
    return hyperlink_end_cost + target.uri.len + target.params.len;
}

/// What `CSI n X` costs before it starts saving: the introducer, one digit
/// and the final byte. A blank run longer than this is cheaper erased.
const erase_cost = 4;

/// `CSI 0 K` and `OSC 8 ; ; ST` respectively.
const clear_line_cost = 4;
const hyperlink_end_cost = 7;

/// What the scroll detection needs of a renderer, and
/// nothing a program reaches: `Renderer` is re-exported, this file's own
/// declarations are not, so these are the package's and not its API.
pub const internal = struct {
    pub fn prevRow(r: *const Renderer, row: u16) []const Cell {
        return r.prevRow(row);
    }
    pub fn shiftPrev(r: *Renderer, top: u16, bottom: u16, distance: u16, up: bool) void {
        r.shiftPrev(top, bottom, distance, up);
    }
    pub fn hideForWrite(r: *Renderer, out: *Writer) Error!void {
        return r.hideForWrite(out);
    }
    pub fn setStyle(r: *Renderer, out: *Writer, to: Style, stats: *Renderer.Stats) Error!void {
        return r.setStyle(out, to, stats);
    }
    pub fn setLink(r: *Renderer, out: *Writer, s: *Screen, to: Link, caps: Caps, stats: *Renderer.Stats) Error!void {
        return r.setLink(out, s, to, caps, stats);
    }
};

/// Whether every cell is shown exactly as the grid holds it, so a row can be
/// compared and remembered as memory rather than cell by cell through
/// `visible`.
pub fn shownAsHeld(caps: Caps) bool {
    return caps.osc8 and caps.scaled_text;
}

/// A cell as the terminal will actually show it.
///
/// A link on a terminal with no OSC 8 is not a difference worth a byte, so
/// it is not one the previous frame records either. On a terminal without
/// the text sizing protocol a scaled grapheme is drawn at its own size and
/// the rest of its block is blank, so that is what the cells become.
pub fn visible(c: Cell, caps: Caps) Cell {
    var out = c;
    if (!caps.osc8) out.link = .none;
    if (!caps.scaled_text and c.isScaled()) {
        if (c.isTail()) return .blank(c.style);
        out.shape.scale = 0;
    }
    return out;
}

/// Where the run of default blanks at the end of a row starts, or the row's
/// width when it does not end in one.
fn trailingBlank(cells: []const Cell, caps: Caps) u16 {
    var i: u16 = @intCast(cells.len);
    while (i > 0 and visible(cells[i - 1], caps).isBlankIn(.{})) i -= 1;
    return i;
}

/// Whether the terminal and this package cannot disagree about a cluster's
/// width: because the terminal measures clusters the way this package does,
/// or because every cluster they could disagree about is written with its
/// width stated.
fn widthsAgree(caps: Caps) bool {
    return switch (caps.width_method) {
        .unicode => true,
        .wcwidth, .explicit => caps.explicit_width,
    };
}

/// Whether a cell goes out through the text sizing protocol with its width
/// stated.
///
/// Under `.explicit` that is every cluster a width model could measure at
/// all differently, which is everything but printable ASCII. Under
/// `.wcwidth` it is only the clusters the two models disagree about, since
/// the rest the terminal measures the way this package did. Under
/// `.unicode` the terminal already agrees, and stating a width would cost
/// eleven bytes a cluster for nothing.
fn toldWidth(c: Cell, caps: Caps) bool {
    if (!caps.explicit_width) return false;
    return switch (caps.width_method) {
        .unicode => false,
        .wcwidth => c.shape.drift,
        .explicit => !c.text.isAscii(),
    };
}

/// Whether `REP` may stand in for further copies of a cell: one column, one
/// codepoint, and measured the same way by every width model.
fn repeatable(c: Cell, text: []const u8) bool {
    if (c.width() != 1 or c.shape.drift) return false;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    return len == text.len;
}

/// How many cells from `col` show exactly `same`, stopping at `to`.
fn sameRunLen(cells: []const Cell, col: u16, to: u16, same: Cell, caps: Caps) u16 {
    var n: u16 = 0;
    var i: u32 = col;
    while (i <= to and visible(cells[i], caps).eql(same)) : (i += 1) n += 1;
    return n;
}

/// How many decimal digits a number takes as a parameter.
fn digits(n: u32) usize {
    var v = n;
    var d: usize = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// The bytes an absolute move costs: `CSI row ; col H`.
fn absoluteCost(to: Point) usize {
    return 2 + digits(@as(u32, to.row) + 1) + 1 + digits(@as(u32, to.col) + 1) + 1;
}

/// Writes the cheapest sequence that moves the cursor from `at` to `to` on
/// a screen whose rows are known by number.
///
/// Every candidate is costed in bytes and the shortest wins; an absolute move
/// is the tie-break, because it is the one that is right whatever the
/// terminal did with the last one.
fn writeMove(out: *Writer, at: Point, to: Point) Writer.Error!void {
    try emitMove(out, at, to, plan(at, to, .screen).choice);
}

/// What the cursor's rows are counted against.
const Addressing = enum {
    /// The terminal's own rows, so an absolute move is available.
    screen,
    /// A saved origin, so only relative moves and absolute columns are.
    region,
};

/// The cheapest move from `at` to `to`, and what it costs.
fn plan(at: Point, to: Point, addressing: Addressing) struct { choice: Move, cost: usize } {
    var best: usize = std.math.maxInt(usize);
    var choice: Move = .absolute;
    if (addressing == .screen) best = absoluteCost(to);

    if (at.row == to.row) {
        if (to.col == 0) best = pick(&choice, .carriage_return, 1, best);
        best = pick(&choice, .column, 2 + digits(@as(u32, to.col) + 1) + 1, best);
        if (to.col > at.col) {
            best = pick(&choice, .right, 2 + digits(to.col - at.col) + 1, best);
        } else if (to.col < at.col) {
            best = pick(&choice, .left, 2 + digits(at.col - to.col) + 1, best);
            best = pick(&choice, .backspace, at.col - to.col, best);
        }
    } else if (at.col == to.col) {
        if (addressing == .screen) {
            best = pick(&choice, .row, 2 + digits(@as(u32, to.row) + 1) + 1, best);
        }
        if (to.row > at.row) {
            best = pick(&choice, .down, 2 + digits(to.row - at.row) + 1, best);
        } else {
            best = pick(&choice, .up, 2 + digits(at.row - to.row) + 1, best);
        }
    } else if (to.col == 0) {
        if (to.row > at.row) {
            best = pick(&choice, .next_line, 2 + digits(to.row - at.row) + 1, best);
        } else {
            best = pick(&choice, .prev_line, 2 + digits(at.row - to.row) + 1, best);
        }
    } else if (addressing == .region) {
        // No absolute move to fall back on, so the move is two: the row,
        // then the column, by whichever pair is shorter.
        const down = to.row > at.row;
        const vertical = 2 + digits(if (down) to.row - at.row else at.row - to.row) + 1;
        const column = 2 + digits(@as(u32, to.col) + 1) + 1;
        const right = 2 + digits(to.col) + 1;
        best = pick(&choice, if (down) .down_then_column else .up_then_column, vertical + column, best);
        best = pick(&choice, if (down) .next_line_then_right else .prev_line_then_right, vertical + right, best);
    }
    return .{ .choice = choice, .cost = best };
}

/// Writes one planned move.
fn emitMove(out: *Writer, at: Point, to: Point, choice: Move) Writer.Error!void {
    switch (choice) {
        .absolute => try morse.cursorTo(out, to.row + 1, to.col + 1),
        .carriage_return => try out.writeByte('\r'),
        .column => try morse.cursorColumn(out, to.col + 1),
        .row => try morse.cursorRow(out, to.row + 1),
        .right => try morse.cursorRight(out, to.col - at.col),
        .left => try morse.cursorLeft(out, at.col - to.col),
        .backspace => try out.splatByteAll(8, at.col - to.col),
        .up => try morse.cursorUp(out, at.row - to.row),
        .down => try morse.cursorDown(out, to.row - at.row),
        .next_line => try morse.cursorNextLine(out, to.row - at.row),
        .prev_line => try morse.cursorPrevLine(out, at.row - to.row),
        .down_then_column => {
            try morse.cursorDown(out, to.row - at.row);
            try morse.cursorColumn(out, to.col + 1);
        },
        .up_then_column => {
            try morse.cursorUp(out, at.row - to.row);
            try morse.cursorColumn(out, to.col + 1);
        },
        .next_line_then_right => {
            try morse.cursorNextLine(out, to.row - at.row);
            try morse.cursorRight(out, to.col);
        },
        .prev_line_then_right => {
            try morse.cursorPrevLine(out, at.row - to.row);
            try morse.cursorRight(out, to.col);
        },
    }
}

/// The ways the cursor can be moved, each costed before one is chosen.
const Move = enum {
    absolute,
    carriage_return,
    column,
    row,
    right,
    left,
    backspace,
    up,
    down,
    next_line,
    prev_line,
    down_then_column,
    up_then_column,
    next_line_then_right,
    prev_line_then_right,
};

/// Takes `candidate` when it is strictly cheaper than what is held.
fn pick(choice: *Move, candidate: Move, cost: usize, best: usize) usize {
    if (cost >= best) return best;
    choice.* = candidate;
    return cost;
}

/// One frame's bytes: counted, and bracketed with synchronised output only
/// when the frame turns out to be big enough to be worth it.
///
/// The bracket is decided after the fact without a second pass. The frame is
/// written into the renderer's own buffer; a frame that fits is small enough
/// for the terminal to take in one read, so it cannot tear and the sixteen
/// bytes would buy nothing. A frame that overruns the buffer opens the
/// bracket at the moment it overruns and closes it at the end. Either way
/// there is no branch in the emit path and nothing is copied twice.
const Frame = struct {
    out: *Writer,
    n: usize,
    /// Whether the terminal takes mode 2026 and wants it.
    sync: bool,
    /// Whether the bracket has been opened.
    opened: bool,
    writer: Writer,

    fn init(out: *Writer, buf: []u8, sync: bool) Frame {
        return .{
            .out = out,
            .n = 0,
            .sync = sync,
            .opened = false,
            .writer = .{ .buffer = buf, .vtable = &.{ .drain = drain } },
        };
    }

    /// The frame overran the buffer, so it is large enough to be worth
    /// bracketing and the bracket has to open now.
    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const f: *Frame = @alignCast(@fieldParentPtr("writer", w));
        if (f.sync and !f.opened) {
            f.opened = true;
            try morse.syncOutput.set(f.out, true);
            f.n += sync_sequence_cost;
        }
        const aux = w.buffered();
        const aux_n = try f.out.writeSplatHeader(aux, data, splat);
        f.n += aux_n;
        if (aux_n < w.end) {
            const remaining = w.buffer[aux_n..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        const written = aux_n - w.end;
        w.end = 0;
        return written;
    }

    /// Pushes the frame to the caller's writer, bracketing it if it was
    /// bracketed. Never flushes the caller's writer.
    fn finish(f: *Frame) Writer.Error!void {
        if (!f.opened) {
            const body = f.writer.buffered();
            if (body.len != 0) {
                try f.out.writeAll(body);
                f.n += body.len;
            }
            f.writer.end = 0;
            return;
        }
        try f.writer.flush();
        try morse.syncOutput.set(f.out, false);
        f.n += sync_sequence_cost;
    }
};

/// `CSI ? 2026 h` or `CSI ? 2026 l`.
const sync_sequence_cost = 4 + digits(morse.syncOutput.number);

const testing = std.testing;

/// A screen, a renderer and a writer, so a test can say what a frame writes.
const Fixture = struct {
    gpa: Allocator,
    screen: Screen,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,
    caps: Caps,

    fn init(gpa: Allocator, cols: u16, rows: u16) !Fixture {
        const size: Size = .{ .cols = cols, .rows = rows };
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit(gpa);
        s.method = .unicode;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit(gpa);
        // The renderer starts where `enter` leaves the terminal: blank,
        // cursor hidden and at the top-left, no style and no link.
        r.shown = false;
        r.cursor = .{ .col = 0, .row = 0 };
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{ .width_method = .unicode, .osc8 = true, .truecolor = true },
        };
    }

    fn deinit(f: *Fixture) void {
        f.screen.deinit(f.gpa);
        f.renderer.deinit(f.gpa);
        f.out.deinit();
    }

    /// Draws and gives back what was written.
    fn draw(f: *Fixture) !Renderer.Stats {
        f.out.clearRetainingCapacity();
        return f.renderer.draw(&f.out.writer, &f.screen, null, f.caps);
    }

    fn written(f: *Fixture) []const u8 {
        return f.out.written();
    }

    /// Asserts on what the last draw wrote.
    fn expectBytesAgain(f: *Fixture, want: []const u8) !void {
        try testing.expectEqualStrings(want, f.written());
    }

    /// Draws and asserts on the exact bytes.
    fn expectBytes(f: *Fixture, want: []const u8) !void {
        const stats = try f.draw();
        try testing.expectEqualStrings(want, f.written());
        try testing.expectEqual(want.len, stats.bytes);
    }
};

test "a frame with nothing in it writes nothing at all" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();
    try f.expectBytes("");
}

test "one cell changed is one move and one grapheme" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();

    try f.screen.write(4, 1, "x", .{}, .none);
    try f.expectBytes("\x1b[2;5Hx");
}

test "a run of cells is one move and the run" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();

    for ("hello", 0..) |c, i| try f.screen.write(@intCast(i + 2), 0, &.{c}, .{}, .none);
    // The cursor is already on this row, so the column alone is the move.
    try f.expectBytes("\x1b[3Ghello");
}

test "a style change mid-run writes only what changed" {
    var f: Fixture = try .init(testing.allocator, 10, 1);
    defer f.deinit();

    try f.screen.write(0, 0, "a", .{ .bold = true }, .none);
    try f.screen.write(1, 0, "b", .{ .bold = true }, .none);
    try f.screen.write(2, 0, "c", .{ .bold = true, .fg = .ansi(.red) }, .none);
    // Nothing beyond column two changed, so nothing beyond it is written:
    // the rest of the row was already blank on the terminal.
    try f.expectBytes("\x1b[1mab\x1b[31mc");
}

test "a link is opened once and closed once" {
    var f: Fixture = try .init(testing.allocator, 8, 1);
    defer f.deinit();

    const l = try f.screen.link(testing.allocator, "https://ziglang.org", "id=1");
    try f.screen.write(0, 0, "z", .{}, l);
    try f.screen.write(1, 0, "i", .{}, l);
    try f.screen.write(2, 0, "g", .{}, .none);
    try f.expectBytes(
        "\x1b]8;id=1;https://ziglang.org\x1b\\zi\x1b]8;;\x1b\\g",
    );
}

test "a link's parameters are part of it" {
    var f: Fixture = try .init(testing.allocator, 8, 1);
    defer f.deinit();

    const one = try f.screen.link(testing.allocator, "https://ziglang.org", "id=1");
    const two = try f.screen.link(testing.allocator, "https://ziglang.org", "id=2");
    try testing.expect(one != two);
    try f.screen.write(0, 0, "a", .{}, one);
    try f.screen.write(1, 0, "b", .{}, two);
    try f.expectBytes(
        "\x1b]8;id=1;https://ziglang.org\x1b\\a" ++
            "\x1b]8;id=2;https://ziglang.org\x1b\\b\x1b]8;;\x1b\\",
    );
}

test "a wide grapheme repaints its row and writes one grapheme for two columns" {
    var f: Fixture = try .init(testing.allocator, 6, 1);
    defer f.deinit();

    try f.screen.write(1, 0, "\u{4e2d}", .{}, .none);
    try f.expectBytes(" \u{4e2d}\x1b[0K");
}

test "a wide grapheme overwritten by a narrow one leaves no half behind" {
    var f: Fixture = try .init(testing.allocator, 6, 1);
    defer f.deinit();

    try f.screen.write(1, 0, "\u{4e2d}", .{}, .none);
    _ = try f.draw();
    try f.screen.write(1, 0, "a", .{}, .none);
    try f.expectBytes("\r a\x1b[0K");
}

test "a row cleared to the end is an erase and not a row of spaces" {
    var f: Fixture = try .init(testing.allocator, 40, 1);
    defer f.deinit();

    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    f.screen.fill(.{ .col = 4, .row = 0, .cols = 36, .rows = 1 }, .blank(.{}));
    try f.expectBytes("\x1b[1;5H\x1b[0K");
}

test "an interior blank run is one erase rather than a row of spaces" {
    var f: Fixture = try .init(testing.allocator, 40, 1);
    defer f.deinit();

    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    f.screen.fill(.{ .col = 4, .row = 0, .cols = 20, .rows = 1 }, .blank(.{}));
    const stats = try f.draw();
    try f.expectBytesAgain("\x1b[1;5H\x1b[20X");
    try testing.expectEqual(@as(u32, 20), stats.erased);
    try testing.expect(stats.bytes < 16);
}

test "the same frame twice writes nothing the second time" {
    var f: Fixture = try .init(testing.allocator, 20, 5);
    defer f.deinit();

    try f.screen.write(3, 2, "\u{4e2d}", .{ .bold = true }, .none);
    _ = try f.draw();
    try f.expectBytes("");
    f.screen.damageAll();
    try f.expectBytes("");
}

test "a failed frame is written in full when retried" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();

    try f.screen.write(4, 1, "x", .{}, .none);
    var short: [1]u8 = undefined;
    var failing: Writer = .fixed(&short);
    try testing.expectError(error.WriteFailed, f.renderer.draw(&failing, &f.screen, null, f.caps));

    // Every row, the blank one erased: what part of the failed frame got
    // through is not known.
    try f.expectBytes("\x1b]8;;\x1b\\\x1b[0m\x1b[1;1H\x1b[0K\x1b[2d    x\x1b[0K");
    try f.expectBytes("");
}

test "the cursor is settled at the end of the frame and not before" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();

    f.screen.cursor = .{ .col = 3, .row = 1, .visible = true, .shape = .bar };
    try f.expectBytes("\x1b[6 q\x1b[2;4H\x1b[?25h");
    try f.expectBytes("");
}

test "a frame drawn while the cursor shows hides it first and shows it last" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();

    f.screen.cursor = .{ .col = 0, .row = 0, .visible = true };
    _ = try f.draw();
    try f.screen.write(5, 0, "x", .{}, .none);
    try f.expectBytes("\x1b[?25l\x1b[6Gx\r\x1b[?25h");
}

test "entering and leaving write exactly the modes they turn on" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, .{ .in_band_resize = true }, .alt, .{});
    try testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?2048h\x1b[0m\x1b[2J\x1b[1;1H\x1b[?25l",
        f.written(),
    );

    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expectEqualStrings(
        "\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?2048l\x1b[?1049l",
        f.written(),
    );
}

test "the input modes go on after the screen and come off before it, exactly" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();

    const modes: Modes = .{
        .keyboard = .{ .disambiguate_escape_codes = true, .report_event_types = true },
        .mouse = .{ .motion = .press },
        .focus = true,
        .paste = true,
        .color_scheme = true,
    };
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, .{}, .alt, modes);
    try testing.expectEqualStrings(
        "\x1b[?1049h" ++ // the alternate screen, and its own keyboard stack
            "\x1b[>3u" ++ // pushed onto that stack
            // the mouse exactly: every other mode of both settings off,
            // whatever was on, then one motion and one encoding
            "\x1b[?9l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1015l\x1b[?1016l\x1b[?1000h\x1b[?1006h" ++
            "\x1b[?1004h" ++ // focus, a mode of its own
            "\x1b[?2004h\x1b[?2031h" ++
            "\x1b[0m\x1b[2J\x1b[1;1H\x1b[?25l",
        f.written(),
    );

    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expectEqualStrings(
        "\x1b[?2026l\x1b[0m\x1b[?25h" ++
            "\x1b[?2031l\x1b[?2004l\x1b[?1004l" ++
            // The motion and the encoding that were on, and no other: the
            // modes `enter` found on were turned off then, and are not this
            // program's to write again.
            "\x1b[?1000l\x1b[?1006l" ++
            "\x1b[<u" ++ // popped while still on the screen it was pushed on
            "\x1b[?1049l",
        f.written(),
    );
}

test "a mode never asked for is never written, either way" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, .{}, .alt, .{});
    try f.renderer.leave(&f.out.writer);
    const bytes = f.written();
    for ([_][]const u8{ "\x1b[>", "\x1b[<u", "?9", "?1000", "?1002", "?1003", "?1004", "?1005", "?1006", "?1015", "?1016", "?2004", "?2031" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, bytes, needle) == null);
    }
}

test "modes changed mid-session write the difference, and leaving undoes what is on then" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();
    try testing.expectError(error.NotEntered, f.renderer.setModes(&f.out.writer, .{ .paste = true }));

    try f.renderer.enter(&f.out.writer, .{}, .alt, .{ .mouse = .{ .motion = .press } });

    // The same modes again: nothing.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .mouse = .{ .motion = .press } });
    try testing.expectEqualStrings("", f.written());

    // Drag for a view that has one: the old motion off before the new one
    // on, so the off cannot reset the motion just set. The encoding stays.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .mouse = .{ .motion = .drag } });
    try testing.expectEqualStrings("\x1b[?1000l\x1b[?1002h", f.written());

    // Pixels: the encoding changes the same way, and the motion stays.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .mouse = .{ .motion = .drag, .encoding = .sgr_pixels } });
    try testing.expectEqualStrings("\x1b[?1006l\x1b[?1016h", f.written());

    // The mouse off for a view that does not want it, the keyboard and
    // focus on.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .keyboard = .{ .disambiguate_escape_codes = true }, .focus = true });
    try testing.expectEqualStrings("\x1b[>1u\x1b[?1002l\x1b[?1016l\x1b[?1004h", f.written());

    // New flags replace the top of the stack rather than pushing again.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .keyboard = .{ .report_event_types = true }, .paste = true });
    try testing.expectEqualStrings("\x1b[=2;1u\x1b[?1004l\x1b[?2004h", f.written());

    // The mouse back, from off: exactly, as on the way in.
    f.out.clearRetainingCapacity();
    try f.renderer.setModes(&f.out.writer, .{ .keyboard = .{ .report_event_types = true }, .paste = true, .mouse = .{ .motion = .any } });
    try testing.expectEqualStrings(
        "\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1005l\x1b[?1015l\x1b[?1016l\x1b[?1003h\x1b[?1006h",
        f.written(),
    );

    // And the way out pops once and turns off the paste and mouse it now
    // has on.
    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expectEqualStrings(
        "\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?2004l\x1b[?1003l\x1b[?1006l\x1b[<u\x1b[?1049l",
        f.written(),
    );
}

test "entering asks the terminal to measure clusters when it was told to" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, .{ .width_method = .unicode }, .alt, .{});
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2027h") != null);
    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2027l") != null);
}

test "leaving unwinds a partially written enter" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();

    var short: [8]u8 = undefined;
    var failing: Writer = .fixed(&short);
    try testing.expectError(error.WriteFailed, f.renderer.enter(&failing, .{}, .alt, .{}));

    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?1049l") != null);
}

test "a small frame is not bracketed and a large one is" {
    var f: Fixture = try .init(testing.allocator, 120, 40);
    defer f.deinit();
    f.caps.sync = true;

    try f.screen.write(4, 1, "x", .{}, .none);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2026h") == null);

    for (0..40) |row| {
        for (0..120) |col| {
            try f.screen.write(@intCast(col), @intCast(row), "\u{e9}", .{
                .fg = .rgb(@intCast(col * 2 % 256), 1, 2),
            }, .none);
        }
    }
    const stats = try f.draw();
    try testing.expect(stats.bytes > sync_gate);
    try testing.expect(std.mem.startsWith(u8, f.written(), "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, f.written(), "\x1b[?2026l"));
    try testing.expectEqual(f.written().len, stats.bytes);
}

test "a terminal that does not want the bracket never gets it" {
    var f: Fixture = try .init(testing.allocator, 8, 2);
    defer f.deinit();
    f.caps.sync = true;
    f.caps.sync_unwanted = true;
    f.renderer.repaint();
    try f.screen.write(0, 0, "x", .{}, .none);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2026") == null);
}

test "cells changed in every other column are one run, not twenty" {
    var f: Fixture = try .init(testing.allocator, 40, 1);
    defer f.deinit();

    // A cursor move costs more than the unchanged cell it would step over,
    // so the run bridges them and the row goes out once.
    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    for (0..40) |i| {
        if (i % 2 == 0) try f.screen.write(@intCast(i), 0, "y", .{}, .none);
    }
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.runs);
    try testing.expectEqual(@as(u32, 1), stats.moves);
    try testing.expect(stats.bytes <= 48);
}

test "a run of one glyph is the glyph and a repeat where the terminal has REP" {
    var f: Fixture = try .init(testing.allocator, 40, 1);
    defer f.deinit();
    f.caps.rep = true;

    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{ .bold = true }, .none);
    const stats = try f.draw();
    try f.expectBytesAgain("\x1b[1mx\x1b[39b");
    try testing.expectEqual(@as(u32, 40), stats.cells);
    try testing.expectEqual(@as(u32, 39), stats.repeated);
}

test "a terminal without REP is given every glyph" {
    var f: Fixture = try .init(testing.allocator, 12, 1);
    defer f.deinit();
    for (0..12) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    try f.expectBytes("xxxxxxxxxxxx");
}

test "a repeat that would not save its own bytes is not written" {
    var f: Fixture = try .init(testing.allocator, 12, 1);
    defer f.deinit();
    f.caps.rep = true;
    // Four repeats cost four bytes and save four; five save five.
    for (0..5) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    try f.expectBytes("xxxxx");
    for (0..6) |i| try f.screen.write(@intCast(i), 0, "y", .{}, .none);
    try f.expectBytes("\ry\x1b[5b");
}

test "a repeat never crosses a style change or a different glyph" {
    var f: Fixture = try .init(testing.allocator, 24, 1);
    defer f.deinit();
    f.caps.rep = true;
    for (0..8) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    for (8..16) |i| try f.screen.write(@intCast(i), 0, "x", .{ .bold = true }, .none);
    for (16..24) |i| try f.screen.write(@intCast(i), 0, "y", .{ .bold = true }, .none);
    try f.expectBytes("x\x1b[7b\x1b[1mx\x1b[7by\x1b[7b");
}

test "a repeat never stands for a cluster of more than one codepoint" {
    var f: Fixture = try .init(testing.allocator, 8, 1);
    defer f.deinit();
    f.caps.rep = true;
    // What a terminal repeats after a base and a mark is the mark.
    for (0..8) |i| try f.screen.write(@intCast(i), 0, "e\u{301}", .{}, .none);
    try f.expectBytes("e\u{301}" ** 8);
    // A single non-ASCII codepoint is repeated like any other glyph. The
    // first row filled its last column, so the move is an absolute one.
    for (0..8) |i| try f.screen.write(@intCast(i), 0, "\u{2500}", .{}, .none);
    try f.expectBytes("\x1b[1;1H\u{2500}\x1b[7b");
}

test "a repeated run that reaches the margin leaves the cursor untrusted" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();
    f.caps.rep = true;
    for (0..10) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    try testing.expectEqual(@as(?Point, null), f.renderer.cursor);
    try f.screen.write(0, 1, "y", .{}, .none);
    try f.expectBytes("\x1b[2;1Hy");
}

test "an expensive unchanged grapheme is moved over instead of bridged" {
    var f: Fixture = try .init(testing.allocator, 8, 1);
    defer f.deinit();

    const long = "a\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}\u{307}\u{308}\u{309}\u{30a}";
    try f.screen.write(0, 0, "a", .{}, .none);
    try f.screen.write(1, 0, long, .{}, .none);
    try f.screen.write(2, 0, "a", .{}, .none);
    _ = try f.draw();

    try f.screen.write(0, 0, "b", .{}, .none);
    try f.screen.write(2, 0, "b", .{}, .none);
    const stats = try f.draw();

    try testing.expectEqual(@as(u32, 2), stats.runs);
    try testing.expectEqual(@as(u32, 2), stats.cells);
    try testing.expect(std.mem.indexOf(u8, f.written(), long) == null);
}

test "both ways of writing a row are priced in the bytes they really cost" {
    var f: Fixture = try .init(testing.allocator, 40, 2);
    defer f.deinit();

    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    try f.screen.write(9, 0, "y", .{}, .none);

    const priced = try f.renderer.price(&f.screen, f.caps, 0, 9, 9, false);
    const stats = try f.draw();
    try testing.expectEqual(priced, stats.bytes);
}

test "arithmetic style prices match every emitted transition" {
    const styles = [_]Style{
        .{},
        .{ .bold = true },
        .{ .bold = true, .dim = true, .italic = true },
        .{ .underline = .curly, .underline_color = .ansi(.green) },
        .{ .blink = true, .reverse = true, .hidden = true, .strikethrough = true },
        .{ .overline = true, .script = .superscript },
        .{ .fg = .ansi(.bright_magenta), .bg = .palette(137) },
        .{ .fg = .rgb(1, 22, 203), .bg = .rgb(255, 0, 9) },
        .{ .underline = .dashed, .underline_color = .rgb(9, 88, 7) },
    };
    for (styles) |from| {
        for (styles) |to| {
            var bytes: [128]u8 = undefined;
            var out: Writer = .fixed(&bytes);
            try morse.diffStyle(&out, from, to);
            try testing.expectEqual(out.buffered().len, styleCost(from, to));
        }
    }
}

test "arithmetic row prices match emitted rows" {
    var f: Fixture = try .init(testing.allocator, 40, 2);
    defer f.deinit();
    f.caps.rep = true;
    f.caps.scaled_text = true;

    const link = try f.screen.link(testing.allocator, "https://ziglang.org", "id=price");
    for (0..40) |col| try f.screen.write(@intCast(col), 0, "x", .{}, .none);
    _ = try f.draw();

    try f.screen.write(0, 0, "a", .{ .bold = true }, link);
    try f.screen.write(2, 0, "b", .{ .fg = .rgb(1, 22, 203) }, .none);
    for (8..20) |col| try f.screen.write(@intCast(col), 0, "y", .{ .underline = .curly }, .none);
    f.screen.fill(.{ .col = 30, .row = 0, .cols = 10, .rows = 1 }, .blank(.{}));

    const Check = struct {
        fn row(fixture: *Fixture, whole: bool) !void {
            const r = &fixture.renderer;
            const saved = .{ .style = r.style, .link = r.link, .cursor = r.cursor };
            var emitted: Writer.Discarding = .init(&.{});
            var ignored: Renderer.Stats = .{};
            try r.emitRow(&emitted.writer, &fixture.screen, fixture.caps, 0, 0, 39, whole, &ignored);
            r.style = saved.style;
            r.link = saved.link;
            r.cursor = saved.cursor;

            const priced = try r.price(&fixture.screen, fixture.caps, 0, 0, 39, whole);
            try testing.expectEqual(emitted.fullCount(), priced);
            if (whole) {
                try testing.expect(r.paintTextFloor(&fixture.screen, fixture.caps, 0) <= priced);
            } else {
                try testing.expect(r.isolatedDiffCost(&fixture.screen, fixture.caps, 0, 0, 39, std.math.maxInt(usize)).? >= priced);
            }
            try testing.expectEqual(saved.style, r.style);
            try testing.expectEqual(saved.link, r.link);
            try testing.expectEqual(saved.cursor, r.cursor);
        }
    };

    try Check.row(&f, false);
    try Check.row(&f, true);
    f.renderer.region = 2;
    f.renderer.cursor = .{ .col = 17, .row = 1 };
    f.renderer.style = .{ .bold = true, .fg = .ansi(.cyan) };
    try Check.row(&f, false);
    try Check.row(&f, true);
}

test "a row with one cell changed is not written whole" {
    var f: Fixture = try .init(testing.allocator, 40, 1);
    defer f.deinit();

    for (0..40) |i| try f.screen.write(@intCast(i), 0, "x", .{}, .none);
    _ = try f.draw();
    try f.screen.write(20, 0, "y", .{}, .none);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.repainted);
    try testing.expectEqual(@as(u32, 1), stats.cells);
}

test "restoring a cell leaves conservative damage but writes nothing" {
    var f: Fixture = try .init(testing.allocator, 8, 1);
    defer f.deinit();

    try f.screen.write(3, 0, "x", .{}, .none);
    try f.screen.write(3, 0, " ", .{}, .none);
    try testing.expect(f.screen.damage.any());

    const stats = try f.draw();
    try testing.expectEqual(@as(usize, 0), stats.bytes);
    try testing.expect(!f.screen.damage.any());
}

test "a cluster the two width models disagree about makes its row drift" {
    var f: Fixture = try .init(testing.allocator, 12, 2);
    defer f.deinit();
    f.caps.width_method = .wcwidth;
    f.screen.method = .wcwidth;

    // U+26A0 with a presentation selector: narrow to one model, wide to the
    // other. The row is repainted rather than diffed, and the cursor is not
    // trusted afterwards.
    try f.screen.write(0, 0, "\u{26a0}\u{fe0f}", .{}, .none);
    _ = try f.draw();
    try testing.expectEqual(@as(?Point, null), f.renderer.cursor);
    try testing.expect(f.renderer.drifted[0]);
    try testing.expect(!f.renderer.drifted[1]);
}

test "a cluster the models disagree about is written with its width when the terminal takes one" {
    var f: Fixture = try .init(testing.allocator, 12, 2);
    defer f.deinit();
    f.caps.width_method = .wcwidth;
    f.caps.explicit_width = true;
    f.screen.method = .wcwidth;

    try f.screen.write(0, 0, "\u{26a0}\u{fe0f}", .{}, .none);
    try f.screen.write(1, 0, "a", .{}, .none);
    const stats = try f.draw();
    try f.expectBytesAgain("\x1b]66;w=1;\u{26a0}\u{fe0f}\x1b\\a");
    try testing.expectEqual(@as(u32, 1), stats.told);
    // The row was diffed, not repainted, and the cursor is still trusted.
    try testing.expectEqual(@as(u32, 0), stats.repainted);
    try testing.expectEqual(Point{ .col = 2, .row = 0 }, f.renderer.cursor.?);
    try testing.expect(!f.renderer.drifted[0]);
}

test "told every width, the terminal is told everything but ASCII" {
    var f: Fixture = try .init(testing.allocator, 12, 1);
    defer f.deinit();
    f.caps.width_method = .explicit;
    f.caps.explicit_width = true;
    f.screen.method = .explicit;

    try f.screen.write(0, 0, "a", .{}, .none);
    try f.screen.write(1, 0, "\u{e9}", .{}, .none);
    try f.screen.write(2, 0, "\u{4e2d}", .{}, .none);
    const stats = try f.draw();
    try f.expectBytesAgain("a\x1b]66;w=1;\u{e9}\x1b\\\x1b]66;w=2;\u{4e2d}\x1b\\\x1b[0K");
    try testing.expectEqual(@as(u32, 2), stats.told);
}

test "a terminal that measures clusters is never told a width" {
    var f: Fixture = try .init(testing.allocator, 12, 1);
    defer f.deinit();
    f.caps.explicit_width = true;
    try f.screen.write(0, 0, "\u{26a0}\u{fe0f}", .{}, .none);
    try f.screen.write(2, 0, "\u{4e2d}", .{}, .none);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b]66") == null);
}

test "a scaled grapheme is one sequence and its block is never written" {
    var f: Fixture = try .init(testing.allocator, 8, 3);
    defer f.deinit();
    f.caps.scaled_text = true;

    try testing.expect(try f.screen.writeScaled(1, 0, "\u{4e2d}", .{ .bold = true }, .none, 2));
    try f.screen.write(5, 0, "a", .{}, .none);
    try f.screen.write(0, 1, "b", .{}, .none);
    try f.screen.write(5, 1, "c", .{}, .none);
    const stats = try f.draw();
    try f.expectBytesAgain(
        " \x1b[1m\x1b]66;s=2:w=2;\u{4e2d}\x1b\\\x1b[0ma\x1b[0K\x1b[1Eb\x1b[6Gc\x1b[0K",
    );
    try testing.expectEqual(@as(u32, 1), stats.scaled);
    try f.expectBytes("");
    f.screen.damageAll();
    try f.expectBytes("");
}

test "on a terminal without the protocol a scaled grapheme is drawn at its own size" {
    var f: Fixture = try .init(testing.allocator, 8, 2);
    defer f.deinit();
    try testing.expect(try f.screen.writeScaled(0, 0, "a", .{ .bold = true }, .none, 2));
    try f.screen.write(2, 1, "c", .{}, .none);
    // The block's cells are blanks in the head's style, and the cursor is
    // stepped past nothing: every cell of the block is written.
    try f.expectBytes("\x1b[1ma \x1b[1E  \x1b[0mc");
    try f.expectBytes("");
}

test "a scaled grapheme on a terminal without the protocol is remembered as it was shown" {
    var f: Fixture = try .init(testing.allocator, 8, 3);
    defer f.deinit();
    try testing.expect(try f.screen.writeScaled(1, 0, "a", .{}, .none, 2));
    _ = try f.draw();
    try f.expectBytes("");
    f.screen.damageAll();
    try f.expectBytes("");
    // A change elsewhere on the row does not bring the head with it.
    try f.screen.write(6, 0, "x", .{}, .none);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.cells);
    try f.expectBytesAgain("\x1b[7Gx");
}

test "a scaled grapheme reaches the emulator as the block it is" {
    var f: Fixture = try .init(testing.allocator, 8, 3);
    defer f.deinit();
    f.caps.scaled_text = true;
    var t: Term = try .init(testing.allocator, f.screen.size);
    defer t.deinit();
    t.setMethod(.unicode);

    try testing.expect(try f.screen.writeScaled(1, 0, "\u{4e2d}", .{}, .none, 2));
    try f.screen.write(5, 1, "c", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());
    try @import("term.zig").expectScreensEqual(&f.screen, t.screen());

    // Written over, the block goes on both sides the same way.
    try f.screen.write(2, 1, "x", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());
    try @import("term.zig").expectScreensEqual(&f.screen, t.screen());
}

test "a change of width method repaints every row that ever drifted" {
    var f: Fixture = try .init(testing.allocator, 12, 3);
    defer f.deinit();
    f.caps.width_method = .wcwidth;
    f.screen.method = .wcwidth;

    try f.screen.write(0, 1, "\u{26a0}\u{fe0f}", .{}, .none);
    _ = try f.draw();
    try f.expectBytes("");

    f.caps.width_method = .unicode;
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.rows);
    try testing.expectEqual(@as(u32, 1), stats.repainted);
}

test "cached row safety follows scrolled previous rows" {
    var f: Fixture = try .init(testing.allocator, 4, 4);
    defer f.deinit();

    f.renderer.untrusted[2] = true;
    f.renderer.shiftPrev(0, 3, 1, true);
    try testing.expect(f.renderer.untrusted[1]);
    try testing.expect(!f.renderer.untrusted[2]);
    try testing.expect(!f.renderer.untrusted[3]);

    f.renderer.shiftPrev(0, 3, 2, false);
    try testing.expect(f.renderer.untrusted[3]);
    try testing.expect(!f.renderer.untrusted[0]);
    try testing.expect(!f.renderer.untrusted[1]);
}

test "a screen of the wrong size is refused rather than drawn" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();
    try f.screen.resize(testing.allocator, .{ .cols = 5, .rows = 2 });
    try testing.expectError(error.SizeMismatch, f.draw());
}

const Term = @import("term.zig").Term;

/// A terminal with a prompt's worth of lines already on it, so the cursor is
/// somewhere down the screen the way it is when a program starts.
fn promptedTerm(cols: u16, rows: u16, lines: u16) !Term {
    var t: Term = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    errdefer t.deinit();
    t.setMethod(.unicode);
    var i: u16 = 0;
    while (i < lines) : (i += 1) {
        var buf: [16]u8 = undefined;
        try t.feed(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));
    }
    return t;
}

fn expectRowText(t: *const Term, row: u16, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var col: u16 = 0;
    while (col < t.screen().size.cols) : (col += 1) {
        const g = t.screen().textAt(col, row);
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    try testing.expectEqualStrings(want, std.mem.trimEnd(u8, buf[0..n], " "));
}

test "entering inline mode takes the rows at the cursor and leaves the prompt above" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();
    var t = try promptedTerm(10, 8, 2);
    defer t.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try testing.expectEqualStrings("\x1b[?2027h\x1b[0m\r\n\n\x1b[2A\x1b7\x1b[0J\x1b[?25l", f.written());
    try t.feed(f.written());
    try testing.expectEqual(@as(u16, 2), t.row);
    try testing.expectEqual(@as(u16, 2), t.saved.?.row);

    try f.screen.write(0, 0, "a", .{}, .none);
    try f.screen.write(4, 2, "b", .{ .bold = true }, .none);
    _ = try f.draw();
    try t.feed(f.written());
    try expectRowText(&t, 0, "line 0");
    try expectRowText(&t, 1, "line 1");
    try expectRowText(&t, 2, "a");
    try expectRowText(&t, 4, "    b");
    try testing.expect(t.screen().readCell(4, 4).?.style.bold);

    // Nothing changed: nothing written, even with every row claimed.
    try f.expectBytes("");
    f.screen.damageAll();
    try f.expectBytes("");
}

test "an inline screen at the bottom of the terminal scrolls it to make room" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();
    var t = try promptedTerm(10, 4, 3);
    defer t.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try t.feed(f.written());
    // Two lines scrolled off; the third is the row above the screen.
    try expectRowText(&t, 0, "line 2");
    try testing.expectEqual(@as(u16, 1), t.saved.?.row);

    try f.screen.write(0, 2, "x", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());
    try expectRowText(&t, 3, "x");
    try f.expectBytes("");
}

test "the cursor is moved relative to the saved origin in inline mode" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});

    // Down and across from the origin is two moves; there is no absolute one.
    try f.screen.write(3, 2, "x", .{}, .none);
    try f.expectBytes("\x1b[2B\x1b[4Gx");
    // Back to the origin, restoring it is two bytes and the shortest.
    try f.screen.write(0, 0, "y", .{}, .none);
    try f.expectBytes("\x1b8y");
    // Along a row, the column is absolute and allowed.
    try f.screen.write(3, 0, "w", .{}, .none);
    try f.expectBytes("\x1b[4Gw");
    // With the cursor untrusted, the origin is restored and the move made
    // from there.
    f.renderer.cursor = null;
    try f.screen.write(5, 5, "z", .{}, .none);
    try f.expectBytes("\x1b8\x1b[5B\x1b[6Gz");
    try testing.expect(std.mem.indexOf(u8, f.written(), "H") == null);
}

test "growing an inline screen takes more rows and keeps what was above" {
    var f: Fixture = try .init(testing.allocator, 10, 2);
    defer f.deinit();
    var t = try promptedTerm(10, 5, 2);
    defer t.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try t.feed(f.written());
    try f.screen.write(0, 0, "a", .{}, .none);
    try f.screen.write(0, 1, "b", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());

    // Four rows from row 2 of a five-row terminal: one row scrolls off.
    try f.screen.resize(testing.allocator, .{ .cols = 10, .rows = 4 });
    try f.renderer.resize(testing.allocator, .{ .cols = 10, .rows = 4 });
    try f.screen.write(0, 3, "d", .{}, .none);
    _ = try f.draw();
    try testing.expect(std.mem.startsWith(u8, f.written(), "\x1b]8;;\x1b\\\x1b[0m\x1b8\n\n\n\x1b[3A\x1b7\x1b[0J"));
    try t.feed(f.written());
    try expectRowText(&t, 0, "line 1");
    try testing.expectEqual(@as(u16, 1), t.saved.?.row);
    try expectRowText(&t, 1, "a");
    try expectRowText(&t, 2, "b");
    try expectRowText(&t, 3, "");
    try expectRowText(&t, 4, "d");
    try f.expectBytes("");
}

test "after a resize every row is written, the blank ones erased" {
    var f: Fixture = try .init(testing.allocator, 6, 3);
    defer f.deinit();
    try f.screen.write(0, 2, "x", .{}, .none);
    _ = try f.draw();

    // The window grows a row. The terminal kept the "x" where it was; the
    // new layout has nothing there, and the old frame is not what the
    // terminal is known to show, so the row is erased, not skipped.
    const size: Size = .{ .cols = 6, .rows = 4 };
    try f.screen.resize(testing.allocator, size);
    try f.renderer.resize(testing.allocator, size);
    f.screen.clear();
    try f.screen.write(0, 3, "y", .{}, .none);
    try f.expectBytes("\x1b]8;;\x1b\\\x1b[0m" ++
        "\x1b[1;1H\x1b[0K\x1b[2d\x1b[0K\x1b[3d\x1b[0K" ++
        "\x1b[4dy\x1b[0K");
    try f.expectBytes("");
}

test "a repaint erases a row the previous frame took to be blank" {
    var f: Fixture = try .init(testing.allocator, 6, 2);
    defer f.deinit();
    var t: Term = try .init(testing.allocator, .{ .cols = 6, .rows = 2 });
    defer t.deinit();
    t.setMethod(.unicode);
    _ = try f.draw();

    // Something wrote to the terminal behind the renderer's back; the
    // screen has nothing on that row, and a repaint is the way back.
    try t.feed("\x1b[1;1Hjunk");
    f.renderer.repaint();
    _ = try f.draw();
    try t.feed(f.written());
    try @import("term.zig").expectScreensEqual(&f.screen, t.screen());
}

test "a row repainted on suspicion is written whole even where it is blank" {
    var f: Fixture = try .init(testing.allocator, 6, 2);
    defer f.deinit();
    _ = try f.draw();
    f.renderer.repaintRow(1);
    try f.expectBytes("\x1b[2d\x1b[0K");
    try f.expectBytes("");
}

test "shrinking an inline screen gives its rows back blank" {
    var f: Fixture = try .init(testing.allocator, 10, 4);
    defer f.deinit();
    var t = try promptedTerm(10, 8, 1);
    defer t.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try t.feed(f.written());
    for (0..4) |row| try f.screen.write(0, @intCast(row), "x", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());
    try expectRowText(&t, 4, "x");

    try f.screen.resize(testing.allocator, .{ .cols = 10, .rows = 2 });
    try f.renderer.resize(testing.allocator, .{ .cols = 10, .rows = 2 });
    _ = try f.draw();
    try t.feed(f.written());
    try expectRowText(&t, 0, "line 0");
    try expectRowText(&t, 1, "x");
    try expectRowText(&t, 2, "x");
    try expectRowText(&t, 3, "");
    try expectRowText(&t, 4, "");
    try testing.expectEqual(@as(u16, 1), t.saved.?.row);
    try f.expectBytes("");
}

test "a repaint in inline mode starts from a blank screen at the origin" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();
    var t = try promptedTerm(10, 6, 1);
    defer t.deinit();
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try t.feed(f.written());
    try f.screen.write(2, 1, "x", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());

    // The terminal is written to behind the renderer's back.
    try t.feed("\x1b[3;1Hjunk");
    f.renderer.repaint();
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b8\x1b[0J") != null);
    try t.feed(f.written());
    try expectRowText(&t, 1, "");
    try expectRowText(&t, 2, "  x");
    try expectRowText(&t, 3, "");
    try f.expectBytes("");
}

test "inline mode never writes a scrolling region" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    f.caps.scroll_detection = true;
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    for (0..12) |row| {
        var buf: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "r{d:0>2}", .{row});
        for (text, 0..) |c, i| try f.screen.write(@intCast(i), @intCast(row), &.{c}, .{}, .none);
    }
    _ = try f.draw();
    f.screen.scroll(.fromSize(f.screen.size), 1);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.scrolled);
    try testing.expect(std.mem.indexOf(u8, f.written(), "r") == null);
    try testing.expect(std.mem.indexOf(u8, f.written(), "S") == null);
}

test "leaving inline mode puts the cursor below the screen and keeps the frame" {
    var f: Fixture = try .init(testing.allocator, 10, 3);
    defer f.deinit();
    var t = try promptedTerm(10, 8, 1);
    defer t.deinit();
    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, f.caps, .@"inline", .{});
    try t.feed(f.written());
    try f.screen.write(0, 2, "x", .{}, .none);
    _ = try f.draw();
    try t.feed(f.written());

    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expectEqualStrings("\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?2027l\x1b8\x1b[2B\n\r", f.written());
    try t.feed(f.written());
    try testing.expectEqual(@as(u16, 4), t.row);
    try testing.expectEqual(@as(u16, 0), t.col);
    try expectRowText(&t, 3, "x");
    try testing.expect(t.screen().cursor.visible);

    // At the bottom of the terminal the line feed scrolls, and the frame
    // moves up with everything else.
    var g: Fixture = try .init(testing.allocator, 10, 2);
    defer g.deinit();
    var u = try promptedTerm(10, 3, 1);
    defer u.deinit();
    g.out.clearRetainingCapacity();
    try g.renderer.enter(&g.out.writer, g.caps, .@"inline", .{});
    try u.feed(g.written());
    try g.screen.write(0, 1, "y", .{}, .none);
    _ = try g.draw();
    try u.feed(g.written());
    g.out.clearRetainingCapacity();
    try g.renderer.leave(&g.out.writer);
    try u.feed(g.written());
    try testing.expectEqual(@as(u16, 2), u.row);
    try expectRowText(&u, 1, "y");
    try expectRowText(&u, 2, "");
}

test "the shortest cursor move is the one written" {
    const cases = [_]struct { from: Point, to: Point, bytes: []const u8 }{
        // Along a row: a carriage return beats everything to column one.
        .{ .from = .{ .col = 9, .row = 0 }, .to = .{ .col = 0, .row = 0 }, .bytes = "\r" },
        // Three columns back is three backspaces, not a four-byte escape.
        .{ .from = .{ .col = 9, .row = 0 }, .to = .{ .col = 6, .row = 0 }, .bytes = "\x08\x08\x08" },
        // Further than that, the escape wins.
        .{ .from = .{ .col = 9, .row = 0 }, .to = .{ .col = 1, .row = 0 }, .bytes = "\x1b[2G" },
        // Forward along a row: both spellings are five bytes, and the
        // absolute one is the tie-break.
        .{ .from = .{ .col = 1, .row = 0 }, .to = .{ .col = 40, .row = 0 }, .bytes = "\x1b[41G" },
        // Where the relative move is shorter, it wins.
        .{ .from = .{ .col = 30, .row = 0 }, .to = .{ .col = 38, .row = 0 }, .bytes = "\x1b[8C" },
        // Down a column: the relative move is a byte shorter than the
        // absolute row.
        .{ .from = .{ .col = 4, .row = 1 }, .to = .{ .col = 4, .row = 9 }, .bytes = "\x1b[8B" },
        // And where the two are the same length, the absolute row wins.
        .{ .from = .{ .col = 4, .row = 105 }, .to = .{ .col = 4, .row = 9 }, .bytes = "\x1b[10d" },
        // Nowhere near: the full move.
        .{ .from = .{ .col = 4, .row = 1 }, .to = .{ .col = 40, .row = 9 }, .bytes = "\x1b[10;41H" },
        // To the start of another row.
        .{ .from = .{ .col = 40, .row = 1 }, .to = .{ .col = 0, .row = 3 }, .bytes = "\x1b[2E" },
    };
    for (cases) |case| {
        var buffer: [32]u8 = undefined;
        var out: Writer = .fixed(&buffer);
        try writeMove(&out, case.from, case.to);
        try testing.expectEqualStrings(case.bytes, out.buffered());
    }
}

test "the renderer gives its memory back under a failing allocator" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var r: Renderer = try .init(gpa, .{ .cols = 20, .rows = 8 });
            defer r.deinit(gpa);
            try r.resize(gpa, .{ .cols = 40, .rows = 12 });
            try r.resize(gpa, .{ .cols = 10, .rows = 4 });
        }
    }.run, .{});
}

test "a base and its marks in the only column go out with cluster measuring off around them" {
    var f: Fixture = try .init(testing.allocator, 1, 2);
    defer f.deinit();
    try f.screen.write(0, 0, "e\u{301}", .{}, .none);
    try f.screen.write(0, 1, "a", .{}, .none);
    const stats = try f.draw();
    const bytes = f.written();
    try testing.expectEqual(bytes.len, stats.bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2027le\u{301}\x1b[?2027h") != null);
    // Only there: a plain letter, and the same cluster where there is room
    // for the cursor to move past it, go out as they are.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "2027l"));
    var wide: Fixture = try .init(testing.allocator, 3, 1);
    defer wide.deinit();
    try wide.screen.write(2, 0, "e\u{301}", .{}, .none);
    _ = try wide.draw();
    try testing.expect(std.mem.indexOf(u8, wide.written(), "2027") == null);
    // Nor measured by codepoint, where the terminal joins the mark anyway.
    var narrow: Fixture = try .init(testing.allocator, 1, 1);
    defer narrow.deinit();
    narrow.caps.width_method = .wcwidth;
    narrow.screen.method = .wcwidth;
    try narrow.screen.write(0, 0, "e\u{301}", .{}, .none);
    _ = try narrow.draw();
    try testing.expect(std.mem.indexOf(u8, narrow.written(), "2027") == null);
}
