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
const scroll_detect = @import("scroll.zig");
const textmod = @import("text.zig");
const Caps = @import("caps.zig").Caps;
const Screen = @import("screen.zig").Screen;

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Point = geom.Point;
const Size = geom.Size;
const Style = cellmod.Style;
const Writer = std.Io.Writer;

/// What a full-screen program takes on the way in.
pub const Mode = enum {
    /// The alternate screen: the whole terminal, and the user's scrollback
    /// untouched underneath.
    alt,
    /// Growing in place above the prompt. Not implemented yet; `enter` says
    /// so rather than half doing it.
    @"inline",
};

/// Anything `draw`, `enter` or `leave` can fail with.
pub const Error = Writer.Error || error{
    /// The screen is not the size the renderer was made or resized to.
    SizeMismatch,
    /// `Mode.inline` is not implemented yet.
    InlineModeUnsupported,
};

/// The frame size at or below which the synchronised-output bracket is not
/// worth its sixteen bytes.
///
/// A frame small enough for the terminal to take in one read does not tear,
/// and the bracket costs more than the frame saves. The number is the usual
/// stdio buffer, which is what decides "one read" on the receiving end.
pub const sync_gate = 8192;

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
    /// A hash of each row of `prev` and of the screen, for finding a frame
    /// whose rows moved.
    hashes: []u64,
    /// The renderer's own write buffer. A frame that fits in it is written
    /// to the caller in one go, which is what lets the synchronised-output
    /// bracket be decided after the frame's size is known.
    buf: []u8,

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

    /// The modes `enter` switched, remembered so `leave` is its mirror.
    pub const Entered = struct {
        /// Which screen the program took.
        mode: Mode,
        /// Whether in-band resize reports were turned on.
        in_band_resize: bool,
        /// Whether the terminal was asked to measure clusters, mode 2027.
        unicode_core: bool,
    };

    /// What one `draw` cost, so a budget can be a test rather than a
    /// comment.
    ///
    /// The pairs are elisions against emissions, in notcurses' sense: what
    /// the diff did not have to write against what it did. A renderer that
    /// gets worse moves them, and a test that pins them says so.
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
        /// Style changes written.
        styles: u32 = 0,
        /// Link changes written.
        links: u32 = 0,
        /// Cursor moves written.
        moves: u32 = 0,
    };

    /// Allocates the previous frame.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Renderer {
        var r: Renderer = .{
            .gpa = gpa,
            .size = size,
            .prev = &.{},
            .force = &.{},
            .drifted = &.{},
            .hashes = &.{},
            .buf = &.{},
        };
        try r.allocate(gpa, size);
        return r;
    }

    /// Gives the previous frame back.
    pub fn deinit(r: *Renderer, gpa: Allocator) void {
        r.release(gpa);
        r.* = undefined;
    }

    /// A new size. The next draw writes every cell, because the terminal
    /// reflowed whatever was on it and nothing about the old frame is known
    /// any more.
    pub fn resize(r: *Renderer, gpa: Allocator, size: Size) Allocator.Error!void {
        var next: Renderer = .{
            .gpa = gpa,
            .size = size,
            .prev = &.{},
            .force = &.{},
            .drifted = &.{},
            .hashes = &.{},
            .buf = &.{},
        };
        try next.allocate(gpa, size);
        r.release(gpa);
        r.size = size;
        r.prev = next.prev;
        r.force = next.force;
        r.drifted = next.drifted;
        r.hashes = next.hashes;
        r.buf = next.buf;
        r.repaint();
    }

    /// The next `draw` writes every cell.
    pub fn repaint(r: *Renderer) void {
        r.repaint_all = true;
        r.cursor = null;
    }

    /// One row written whole, absolutely positioned. What a drifting row
    /// gets, and what a caller that suspects one row gives it.
    pub fn repaintRow(r: *Renderer, row: u16) void {
        if (row < r.force.len) r.force[row] = true;
    }

    /// Writes the difference between the last frame and this one. Allocates
    /// nothing. Never flushes the caller's writer.
    pub fn draw(r: *Renderer, w: *Writer, s: *Screen, caps: Caps) Error!Stats {
        if (!std.meta.eql(r.size, s.size)) return error.SizeMismatch;
        var stats: Stats = .{};

        // A terminal told to measure clusters differently has redrawn
        // everything the two models disagreed about, and the model cannot
        // see it happen.
        if (r.method) |was| {
            if (was != caps.width_method) r.forceDrifted();
        }
        r.method = caps.width_method;

        const body = r.repaint_all or s.damage.any() or r.anyForced();
        const tail = r.cursorWork(s);
        if (!body and !tail) {
            s.damage.clear();
            return stats;
        }

        var frame: Frame = .init(w, r.buf, caps.sync and !caps.sync_unwanted);
        const out = &frame.writer;

        if (body and r.shown != false) {
            try morse.cursorVisible.set(out, false);
            r.shown = false;
        }
        if (r.repaint_all) try r.beginRepaint(out, caps);
        if (body) {
            if (caps.scroll_detection) {
                if (try scroll_detect.apply(r, out, s, caps)) |moved| stats.scrolled = moved;
            }
            try r.drawRows(out, s, caps, &stats);
            s.damage.clear();
            @memset(r.force, false);
            r.repaint_all = false;
        }
        try r.finishCursor(out, s);

        try frame.finish();
        stats.bytes = frame.n;
        return stats;
    }

    /// What a full-screen program writes on the way in, in one call.
    ///
    /// Synchronised output is deliberately not here. Mode 2026 is a bracket
    /// around one frame, not a mode a session sits in: left on, every
    /// terminal that invented a timeout for it repaints at that timeout
    /// instead of when the program asks, which is ten frames a second on the
    /// tightest of them. `draw` writes the bracket, and only when the frame
    /// is large enough to be worth it.
    pub fn enter(r: *Renderer, w: *Writer, caps: Caps, mode: Mode) Error!void {
        if (mode == .@"inline") return error.InlineModeUnsupported;
        try morse.altScreen.set(w, true);
        if (caps.in_band_resize) try morse.inBandResize.set(w, true);
        if (caps.width_method == .unicode) try morse.unicodeCore.set(w, true);
        try morse.resetStyle(w);
        try morse.clearScreen(w, .all);
        try morse.cursorTo(w, 1, 1);
        try morse.cursorVisible.set(w, false);

        r.entered = .{
            .mode = mode,
            .in_band_resize = caps.in_band_resize,
            .unicode_core = caps.width_method == .unicode,
        };
        @memset(r.prev, .blank(.{}));
        @memset(r.force, false);
        @memset(r.drifted, false);
        r.style = .{};
        r.link = .none;
        r.cursor = .{ .col = 0, .row = 0 };
        r.shown = false;
        r.shape = null;
        r.repaint_all = false;
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
        try morse.altScreen.set(w, false);
        r.entered = null;
    }

    //=====================================================================
    // What the scroll detector reaches for.
    //=====================================================================

    /// One row of the previous frame.
    pub fn prevRow(r: *const Renderer, row: u16) []const Cell {
        return r.prev[@as(usize, row) * r.size.cols ..][0..r.size.cols];
    }

    /// Moves the previous frame's rows the way the terminal just moved the
    /// real ones, and marks the rows it vacated to be written whole.
    pub fn shiftPrev(r: *Renderer, top: u16, bottom: u16, distance: u16, up: bool) void {
        const cols = r.size.cols;
        const blank: Cell = .blank(.{});
        const region = r.prev[@as(usize, top) * cols ..][0 .. @as(usize, bottom - top + 1) * cols];
        const moved = @as(usize, distance) * cols;
        if (up) {
            std.mem.copyForwards(Cell, region[0 .. region.len - moved], region[moved..]);
            @memset(region[region.len - moved ..], blank);
            for (bottom + 1 - distance..bottom + 1) |row| r.force[row] = true;
        } else {
            std.mem.copyBackwards(Cell, region[moved..], region[0 .. region.len - moved]);
            @memset(region[0..moved], blank);
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
        r.hashes = try gpa.alloc(u64, @as(usize, size.rows) * 2);
        errdefer gpa.free(r.hashes);
        r.buf = try gpa.alloc(u8, sync_gate);
    }

    /// Gives all of it back.
    fn release(r: *Renderer, gpa: Allocator) void {
        gpa.free(r.prev);
        gpa.free(r.force);
        gpa.free(r.drifted);
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

    /// The terminal is in a state the renderer does not know, so it is put
    /// into one it does.
    fn beginRepaint(r: *Renderer, out: *Writer, caps: Caps) Error!void {
        if (caps.osc8) try morse.hyperlinkEnd(out);
        r.link = .none;
        try morse.resetStyle(out);
        r.style = .{};
        r.cursor = null;
        @memset(r.force, true);
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

            // A row the damage map named but nothing really changed in is
            // one whole-row comparison away from costing nothing.
            if (!forced and cellmod.rowsEqual(s.rowAt(row), r.prevRow(row))) {
                stats.skipped += cols;
                continue;
            }
            const drift = r.rowDrifts(s, row);
            if (drift) r.drifted[row] = true;
            stats.rows += 1;

            const first = if (forced) 0 else span.?.first;
            const last = if (forced) cols - 1 else span.?.last;
            const whole = forced or drift or try r.paintIsCheaper(s, caps, row, first, last);
            if (whole) stats.repainted += 1;
            try r.emitRow(out, s, caps, row, first, last, whole, stats);
            // An over-measured cluster runs past the margin and wraps, so
            // after a drifted row the cursor may be a row low as well as a
            // column off. Nothing but an absolute move is safe.
            if (drift and caps.width_method != .unicode) r.cursor = null;
            r.commitRow(s, caps, row);
        }
    }

    /// Whether a row holds a grapheme whose width the terminal might not
    /// agree with, or a wide one at all.
    ///
    /// A cell diff cannot safely step across a glyph whose width the two ends
    /// measure differently, and it cannot land on a covered column at all.
    /// The disagreement is worked out once, when the cell is written, so this
    /// is a scan of one bit per cell. Under mode 2027 the terminal measures
    /// clusters the way this package does, so only the wide cells matter.
    fn rowDrifts(r: *const Renderer, s: *const Screen, row: u16) bool {
        const cluster_widths = r.method == .unicode;
        for (s.rowAt(row)) |c| {
            if (c.width() != 1) return true;
            if (!cluster_widths and c.shape.drift) return true;
        }
        for (r.prevRow(row)) |c| {
            if (c.width() != 1) return true;
            if (!cluster_widths and c.shape.drift) return true;
        }
        return false;
    }

    /// Whether writing the row whole costs fewer bytes than diffing it.
    ///
    /// Both are priced by emitting them into a writer that counts and throws
    /// away, so the answer is the real byte count and not a model of one. A
    /// narrow span cannot lose, so it is not priced.
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
        const diff = try r.price(s, caps, row, first, last, false);
        const paint = try r.price(s, caps, row, 0, cols - 1, true);
        return paint <= diff;
    }

    /// What one way of writing a row would cost, in bytes, leaving the
    /// renderer exactly as it found it.
    pub fn price(
        r: *Renderer,
        s: *Screen,
        caps: Caps,
        row: u16,
        first: u16,
        last: u16,
        whole: bool,
    ) Error!u64 {
        const saved: struct { style: Style, link: Link, cursor: ?Point } = .{
            .style = r.style,
            .link = r.link,
            .cursor = r.cursor,
        };
        defer {
            r.style = saved.style;
            r.link = saved.link;
            r.cursor = saved.cursor;
        }
        var thrown: Writer.Discarding = .init(&.{});
        var ignored: Stats = .{};
        try r.emitRow(&thrown.writer, s, caps, row, first, last, whole, &ignored);
        return thrown.fullCount();
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
        const erase_from = trailingBlank(cells);

        if (erase_from == 0) {
            if (r.rowIsBlank(row)) return;
            try r.moveTo(out, 0, row, stats);
            try r.eraseToEnd(out, s, caps, stats, cols);
            return;
        }
        try r.moveTo(out, 0, row, stats);
        stats.runs += 1;
        try r.writeCells(out, s, caps, row, 0, erase_from - 1, stats);
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
            const run_end = runEnd(cells, old, caps, col, last);

            // A run that reaches the end of the row and ends in default
            // blanks is erased rather than painted.
            const erase_from = if (run_end == cols - 1) @max(col, trailingBlank(cells)) else cols;
            const paint_to = if (erase_from <= run_end) erase_from else run_end + 1;

            try r.moveTo(out, col, row, stats);
            if (paint_to > col) {
                stats.runs += 1;
                try r.writeCells(out, s, caps, row, col, paint_to - 1, stats);
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
    fn writeCells(
        r: *Renderer,
        out: *Writer,
        s: *Screen,
        caps: Caps,
        row: u16,
        from: u16,
        to: u16,
        stats: *Stats,
    ) Error!void {
        const cells = s.rowAt(row);
        var col = from;
        while (col <= to) {
            const c = cells[col];
            if (c.isTail()) {
                col += 1;
                continue;
            }
            // A run of default blanks at the end of what is being written
            // costs fewer bytes as an erase than as spaces, and the erase
            // leaves the cursor where it is, which the next move knows.
            const blanks = blankRunLen(cells, col, to);
            if (blanks > erase_cost and col + blanks > to) {
                try r.setStyle(out, .{}, stats);
                try r.setLink(out, s, .none, caps, stats);
                try morse.eraseChars(out, blanks);
                stats.erased += blanks;
                return;
            }
            try r.setStyle(out, c.style(), stats);
            try r.setLink(out, s, c.link, caps, stats);
            try out.writeAll(s.textOf(&cells[col]));
            stats.cells += 1;
            col += c.width();
            r.advance(col, row);
        }
    }

    /// Copies a row of the screen into the previous frame.
    fn commitRow(r: *Renderer, s: *const Screen, caps: Caps, row: u16) void {
        const cells = s.rowAt(row);
        const old = r.prev[@as(usize, row) * r.size.cols ..][0..r.size.cols];
        if (caps.osc8) {
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
    pub fn setStyle(r: *Renderer, out: *Writer, to: Style, stats: *Stats) Error!void {
        if (std.meta.eql(r.style, to)) return;
        try morse.diffStyle(out, r.style, to);
        r.style = to;
        stats.styles += 1;
    }

    /// Opens, closes or swaps the OSC 8 link the terminal has open.
    pub fn setLink(
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

    /// Puts the cursor at a place in the fewest bytes.
    fn moveTo(r: *Renderer, out: *Writer, col: u16, row: u16, stats: *Stats) Error!void {
        const there: Point = .{ .col = col, .row = row };
        if (r.cursor) |at| {
            if (at.col == col and at.row == row) return;
            try writeMove(out, at, there);
        } else {
            try morse.cursorTo(out, row + 1, col + 1);
        }
        r.cursor = there;
        stats.moves += 1;
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

/// What `CSI n X` costs before it starts saving: the introducer, one digit
/// and the final byte. A blank run longer than this is cheaper erased.
const erase_cost = 4;

/// A cell as the terminal will actually show it. A link on a terminal with
/// no OSC 8 is not a difference worth a byte, so it is not one the previous
/// frame records either.
pub fn visible(c: Cell, caps: Caps) Cell {
    if (caps.osc8) return c;
    var out = c;
    out.link = .none;
    return out;
}

/// Where the run of default blanks at the end of a row starts, or the row's
/// width when it does not end in one.
fn trailingBlank(cells: []const Cell) u16 {
    var i: u16 = @intCast(cells.len);
    while (i > 0 and cells[i - 1].isBlankIn(.{})) i -= 1;
    return i;
}

/// How many default blanks there are from `col`, stopping at `to`.
fn blankRunLen(cells: []const Cell, col: u16, to: u16) u16 {
    var n: u16 = 0;
    var i = col;
    while (i <= to and cells[i].isBlankIn(.{})) : (i += 1) n += 1;
    return n;
}

/// The last column of the run starting at `col`.
///
/// A run keeps going across cells that did not change when writing them costs
/// fewer bytes than moving over them would, which is the shortest cursor move
/// by another name: the cheapest way past four unchanged cells is to print
/// them again.
fn runEnd(cells: []const Cell, old: []const Cell, caps: Caps, col: u16, last: u16) u16 {
    const bridge = 4;
    var end = col;
    var i = col + 1;
    var same: u16 = 0;
    while (i <= last) : (i += 1) {
        if (visible(cells[i], caps).eql(old[i])) {
            same += 1;
            if (same > bridge) break;
        } else {
            same = 0;
            end = i;
        }
    }
    return end;
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

/// Writes the cheapest sequence that moves the cursor from `at` to `to`.
///
/// Every candidate is costed in bytes and the shortest wins; an absolute move
/// is the tie-break, because it is the one that is right whatever the
/// terminal did with the last one.
fn writeMove(out: *Writer, at: Point, to: Point) Writer.Error!void {
    var best = absoluteCost(to);
    var choice: Move = .absolute;

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
        best = pick(&choice, .row, 2 + digits(@as(u32, to.row) + 1) + 1, best);
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
    }

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
            var counter: Writer.Discarding = .init(&.{});
            try morse.syncOutput.set(&counter.writer, true);
            try morse.syncOutput.set(f.out, true);
            f.n += counter.fullCount();
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
        var before = f.out.end;
        _ = &before;
        var counter: Writer.Discarding = .init(&.{});
        try morse.syncOutput.set(&counter.writer, false);
        try morse.syncOutput.set(f.out, false);
        f.n += counter.fullCount();
    }
};

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
        return f.renderer.draw(&f.out.writer, &f.screen, f.caps);
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
    try f.screen.write(2, 0, "c", .{ .bold = true, .fg = .{ .ansi = .red } }, .none);
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
            "\x1b]8;id=2;https://ziglang.org\x1b\\b",
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
    try f.renderer.enter(&f.out.writer, .{ .in_band_resize = true }, .alt);
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

test "entering asks the terminal to measure clusters when it was told to" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();

    f.out.clearRetainingCapacity();
    try f.renderer.enter(&f.out.writer, .{ .width_method = .unicode }, .alt);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2027h") != null);
    f.out.clearRetainingCapacity();
    try f.renderer.leave(&f.out.writer);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b[?2027l") != null);
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
                .fg = .{ .rgb = .{ .r = @intCast(col * 2 % 256), .g = 1, .b = 2 } },
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

test "a screen of the wrong size is refused rather than drawn" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();
    try f.screen.resize(testing.allocator, .{ .cols = 5, .rows = 2 });
    try testing.expectError(error.SizeMismatch, f.draw());
}

test "inline mode says it is not implemented rather than half doing it" {
    var f: Fixture = try .init(testing.allocator, 4, 2);
    defer f.deinit();
    try testing.expectError(
        error.InlineModeUnsupported,
        f.renderer.enter(&f.out.writer, .{}, .@"inline"),
    );
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
