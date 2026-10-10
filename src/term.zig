//! A terminal emulator just wide enough to check a renderer.
//!
//! It consumes what `draw` wrote and rebuilds a `Screen` from it, so a
//! program's frame can be asserted on with no terminal anywhere: draw, feed,
//! compare. That comparison is this package's own headline test, run under
//! shakedown's `check` over random grids, and it is public because a program
//! built on this package needs exactly the same check.
//!
//! It is as complete as the renderer's output and no more: the cursor
//! movements, the erases, the scrolls, the repeat, SGR, OSC 8, the width a
//! cluster is told through OSC 66, and the modes this package writes. A graphics command is recorded rather than drawn, which is what
//! lets the rule that the text pass never deletes a placement be a test.
//!
//! The bytes are morse's, and so is reading them: sequences are framed by
//! `morse.parseCsi` and `morse.parseControlString`, a style change is
//! applied by `morse.applySgr`, a link and sized text are read by
//! `morse.parseHyperlink` and `morse.parseTextSize`, each the inverse of
//! what wrote it, and modes and cursor shapes are matched by the numbers
//! morse writes them with.
//!
//! What this file will never be: a terminal emulator for general use. It has
//! no character sets, no tabs stops, no margins, no mouse, no scrollback and
//! no bell. Anything it does not recognise is dropped rather than guessed at.

const std = @import("std");
const morse = @import("dependencies.zig").morse;
const aegis = @import("dependencies.zig").aegis;

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const textmod = @import("text.zig");
const Screen = @import("screen.zig").Screen;
const screen_internal = @import("screen.zig").internal;

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Size = geom.Size;
const Color = cellmod.Color;
const Style = cellmod.Style;
const Writer = std.Io.Writer;
const log = std.log.scoped(.visor);
const assert = std.debug.assert;

/// The terminal.
pub const Term = struct {
    /// Private: the allocator `init` was given.
    gpa: Allocator,
    /// Private: the grid the bytes so far have built.
    scr: Screen,
    /// Private: bytes of a sequence or a cluster that the last `feed` ended in the
    /// middle of.
    own_pending: std.ArrayList(u8) = .empty,
    /// Private: the style cells are being written in.
    style: Style = .{},
    /// Private: the link cells are being written under.
    link: Link = .none,
    /// Private: where the next cell goes.
    col: u16 = 0,
    /// Private: the row it goes in.
    own_row: u16 = 0,
    /// Private: whether the last write filled the last column, so the next one wraps.
    wrap_pending: bool = false,
    /// Private: whether writing past the last column wraps, DECAWM.
    autowrap: bool = true,
    /// Private: the first row scrolling is confined to.
    scroll_top: u16 = 0,
    /// Private: the last row scrolling is confined to.
    scroll_bottom: u16,
    /// Private: every graphics command the bytes carried, in order.
    own_graphics: std.ArrayList([]const u8) = .empty,
    /// Private: the saved cursor, DECSC.
    saved: ?struct { col: u16, row: u16, style: Style } = null,
    /// Private: what `REP` repeats: the codepoint that began the cell printed last,
    /// the base of a cluster and not its last mark, as the pinned emulator
    /// repeats it (`e` + U+0301 then `CSI 2 b` is two more `e`).
    previous: ?u21 = null,
    /// Private: mode 2027 turned off with `CSI ? 2027 l`. Measuring clusters, the
    /// terminal joins what it prints to the cell on the left of the cursor
    /// where the break rules say so (`join`); with the mode off it does not.
    clusters_off: bool = false,

    /// Current write position, by value.
    pub fn position(t: *const Term) geom.Point {
        return .{ .col = t.col, .row = t.own_row };
    }

    /// The saved cursor position, by value, or null before DECSC.
    pub fn savedCursor(t: *const Term) ?geom.Point {
        const saved = t.saved orelse return null;
        return .{ .col = saved.col, .row = saved.row };
    }

    /// Recorded graphics commands, borrowed read-only until feed or deinit.
    pub fn graphics(t: *const Term) []const []const u8 {
        return t.own_graphics.items;
    }

    /// A terminal of a size, showing nothing.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Term {
        var scr: Screen = try .init(gpa, size);
        errdefer scr.deinit();
        return .{
            .gpa = gpa,
            .scr = scr,
            .scroll_bottom = if (size.rows == 0) 0 else size.rows - 1,
        };
    }

    /// Gives the terminal back.
    pub fn deinit(t: *Term) void {
        t.scr.deinit();
        t.own_pending.deinit(t.gpa);
        for (t.own_graphics.items) |g| t.gpa.free(g);
        t.own_graphics.deinit(t.gpa);
        t.* = undefined;
    }

    /// How this terminal measures text. Set it to whatever the renderer was
    /// told, or the two will disagree about a wide grapheme for good
    /// reasons.
    pub fn setMethod(t: *Term, method: textmod.Method) void {
        t.scr.method = method;
    }

    /// The screen the terminal now holds.
    pub fn screen(t: *const Term) *const Screen {
        return &t.scr;
    }

    /// A new size, the way a terminal's alternate screen takes one: the rows
    /// and columns that still fit keep what they held, the rest is blank,
    /// the cursor stays where it was as far as the new size allows, and the
    /// scrolling region is the whole screen again.
    ///
    /// What survives is what a renderer must not assume away. A real
    /// terminal keeps it -- or cuts it, or moves it up with the cursor, or
    /// reflows it -- and says nothing, so a renderer that takes a resized
    /// terminal to be blank leaves the old frame showing wherever the new
    /// one has nothing to write.
    pub fn resize(t: *Term, size: Size) Allocator.Error!void {
        try screen_internal.resizeKeepingLink(&t.scr, size, &t.link);
        t.scroll_top = 0;
        t.scroll_bottom = if (size.rows == 0) 0 else size.rows - 1;
        t.col = @min(t.col, if (size.cols == 0) 0 else size.cols - 1);
        t.own_row = @min(t.own_row, if (size.rows == 0) 0 else size.rows - 1);
        t.wrap_pending = false;
        t.assertCursor();
    }

    /// The bytes a renderer wrote.
    ///
    /// A sequence or a grapheme cut in half by the end of `bytes` is held
    /// until the rest of it arrives, so a caller may hand over whatever a
    /// read gave it.
    pub fn feed(t: *Term, bytes: []const u8) Allocator.Error!void {
        defer t.assertCursor();
        if (t.own_pending.items.len != 0) {
            try t.own_pending.appendSlice(t.gpa, bytes);
            const held = try t.own_pending.toOwnedSlice(t.gpa);
            defer t.gpa.free(held);
            try t.consume(held);
            return;
        }
        try t.consume(bytes);
    }

    /// What any bytes leave true: the cursor on the grid, a pending wrap
    /// only at the last column, and the scrolling region inside the grid,
    /// top above bottom.
    fn assertCursor(t: *const Term) void {
        const size = t.scr.dimensions();
        if (size.cols == 0 or size.rows == 0) return;
        assert(t.col < size.cols);
        assert(t.own_row < size.rows);
        assert(!t.wrap_pending or t.col == size.cols - 1);
        assert(t.scroll_top <= t.scroll_bottom);
        assert(t.scroll_bottom < size.rows);
    }

    //=====================================================================
    // The byte stream.
    //=====================================================================

    /// Walks the stream, handing each piece to whatever reads it.
    fn consume(t: *Term, bytes: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                const used = try t.escape(bytes[i..]);
                if (used == 0) {
                    try t.own_pending.appendSlice(t.gpa, bytes[i..]);
                    return;
                }
                i += used;
                continue;
            }
            if (b < 0x20 or b == 0x7f) {
                t.control(b);
                i += 1;
                continue;
            }
            const run_end = runEnd(bytes, i);
            if (run_end == bytes.len) {
                // A codepoint cut in half by the end of what was fed is
                // held; a cluster that merely ends there is not. A renderer
                // writes a cluster in one call, so the only thing that can
                // arrive in pieces is the bytes of one codepoint.
                const held = incompleteTail(bytes[i..run_end]);
                try t.printRun(bytes[i .. run_end - held]);
                if (held != 0) try t.own_pending.appendSlice(t.gpa, bytes[run_end - held ..]);
                return;
            }
            try t.printRun(bytes[i..run_end]);
            i = run_end;
        }
    }

    /// One of the control characters a renderer writes.
    fn control(t: *Term, b: u8) void {
        switch (b) {
            '\r' => {
                t.col = 0;
                t.wrap_pending = false;
            },
            '\n' => t.lineFeed(),
            0x08 => {
                if (t.col > 0) t.col -= 1;
                t.wrap_pending = false;
            },
            else => {},
        }
    }

    /// A run of printable bytes, as grapheme clusters in cells. Measuring by
    /// codepoint, a cluster goes in the cells such a terminal gives it: each
    /// codepoint that takes columns begins a cell of its own, and the ones
    /// that take none stay with it.
    fn printRun(t: *Term, run: []const u8) Allocator.Error!void {
        var it: textmod.Graphemes = .init(run);
        while (it.next()) |g| {
            if (t.scr.method != .wcwidth) {
                try t.put(g);
                continue;
            }
            var parts: textmod.Parts = .init(g);
            while (parts.next()) |part| try t.put(part.bytes);
        }
    }

    /// One grapheme cluster into a cell, wrapping and scrolling as a
    /// terminal does.
    fn put(t: *Term, grapheme: []const u8) Allocator.Error!void {
        return t.putAs(grapheme, null);
    }

    /// The same, with the width the cluster was told to take rather than
    /// the one this terminal would measure. A control is drawn as nothing,
    /// and bytes that are not UTF-8 as the replacement character, before
    /// anything reads them: the stream is arbitrary, the grid is not.
    fn putAs(t: *Term, bytes: []const u8, told: ?u2) Allocator.Error!void {
        if (t.scr.dimensions().cols == 0 or t.scr.dimensions().rows == 0) return;
        const grapheme = screen_internal.sanitized(bytes) orelse return;
        if (told == null and try t.join(grapheme)) return;
        return t.place(grapheme, told);
    }

    /// Text for a cell, already sanitized and so within the pool's length.
    fn intern(t: *Term, grapheme: []const u8) Allocator.Error!Cell.Text {
        return screen_internal.internShort(&t.scr, grapheme);
    }

    /// A grapheme into a cell of its own, joined to nothing.
    fn place(t: *Term, grapheme: []const u8, told: ?u2) Allocator.Error!void {
        const cols = t.scr.dimensions().cols;
        if (cols == 0 or t.scr.dimensions().rows == 0) return;
        const w: u16 = told orelse textmod.graphemeWidth(grapheme, t.scr.method);
        if (w == 0 or w > 2) return;

        if (t.wrap_pending) {
            if (!t.autowrap) return;
            t.col = 0;
            t.lineFeed();
            t.wrap_pending = false;
        }
        if (@as(u32, t.col) + w > cols) {
            if (!t.autowrap) return;
            // The columns a wide grapheme was too late in the row to use are
            // spacers, not spaces: a terminal leaves them blank and the
            // model has to say why.
            var spacer: Cell = .blank(t.style);
            spacer.shape.kind = .spacer_head;
            var at = t.col;
            while (at < cols) : (at += 1) t.setCell(at, t.own_row, spacer);
            t.col = 0;
            t.lineFeed();
        }
        if (told) |_| {
            const text = try t.intern(grapheme);
            t.setCell(t.col, t.own_row, .init(.{
                .text = text,
                .style = t.style,
                .link = t.link,
                .shape = .{ .kind = if (w == 2) .wide else .narrow, .drift = textmod.disagrees(grapheme) },
            }));
        } else {
            // unreachable: the link is this screen's own and live, and the
            // grapheme is one sanitized cluster, or one part of one, that
            // takes columns by this method -- which `write` draws and never
            // refuses.
            t.scr.write(t.col, t.own_row, grapheme, t.style, t.link) catch |err| switch (err) {
                error.InvalidHandle, error.InvalidCell => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        t.previous = firstCodepoint(grapheme);
        t.col += w;
        if (t.col >= cols) {
            t.col = cols - 1;
            t.wrap_pending = true;
        }
    }

    /// Measuring clusters, a grapheme the break rules join to the cell on the
    /// left of the cursor goes into that cell, as Ghostty does: that is the
    /// cell before the cursor, or the one under it when a write filled the
    /// last column and the cursor waits to wrap, and never one in the first
    /// column's place. The joined cell takes the width of what it now holds,
    /// and the cursor moves past it. True when the grapheme was joined.
    ///
    /// A blank cell is taken as holding a space, which joins a spacing mark,
    /// though a terminal's erased cell holds nothing and joins nothing: this
    /// terminal cannot tell the two apart, and the renderer keeps a mark from
    /// both alike.
    fn join(t: *Term, grapheme: []const u8) Allocator.Error!bool {
        if (t.scr.method != .unicode or t.clusters_off or t.col == 0) return false;
        const cols = t.scr.dimensions().cols;
        var at: u16 = if (t.wrap_pending) t.col else t.col - 1;
        if (t.scr.readCell(at, t.own_row)) |c| {
            if (c.isTail() and at > 0) at -= 1;
        }
        const left = t.scr.readCell(at, t.own_row) orelse return false;
        if (left.isTail() or left.isScaled()) return false;
        const held = (t.scr.textOf(&left) catch @panic("invalid cell in screen"));
        if (!textmod.joinsCell(held, grapheme)) return false;

        var buf: [64]u8 = undefined;
        if (held.len + grapheme.len > buf.len) return false;
        @memcpy(buf[0..held.len], held);
        @memcpy(buf[held.len..][0..grapheme.len], grapheme);
        const joined = buf[0 .. held.len + grapheme.len];
        const w: u16 = @max(left.width(), @min(textmod.graphemeWidth(joined, .unicode), 2));
        var head = at;
        var row = t.own_row;
        if (@as(u32, head) + w > cols) {
            // Grown too wide for the end of the row: a spacer where it was,
            // and the whole cluster at the start of the next.
            var spacer: Cell = .blank(t.style);
            spacer.shape.kind = .spacer_head;
            t.setCell(head, row, spacer);
            t.col = 0;
            t.lineFeed();
            head = 0;
            row = t.own_row;
        }
        const text = try t.intern(joined);
        t.setCell(head, row, .init(.{
            .text = text,
            .style = left.style,
            .link = left.link,
            .shape = .{ .kind = if (w == 2) .wide else .narrow, .drift = textmod.disagrees(joined) },
        }));
        t.previous = firstCodepoint(joined);
        t.wrap_pending = false;
        t.col = head + w;
        if (t.col >= cols) {
            t.col = cols - 1;
            t.wrap_pending = true;
        }
        return true;
    }

    /// `CSI n b`, REP: the codepoint that began the last cell printed
    /// (`previous`), printed again `n` times, wrapping, scrolling and joining
    /// exactly as printing it would.
    ///
    /// A count in the billions is one short sequence, and printing it copy
    /// by copy would hang the emulator. Past a screenful and a row, each
    /// further row of copies only scrolls one more identical row in, so the
    /// count is cut to that plus its remainder in rows, which leaves the grid
    /// and the cursor as the whole count would. A codepoint a terminal
    /// measuring clusters joins to its own copy has no such row, and stops
    /// at twice a screenful, by when every cell it can reach is written.
    fn repeat(t: *Term, count: u32) Allocator.Error!void {
        const cp = t.previous orelse return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        const copy = buf[0..len];
        const n = repeatCount(count, t.scr.dimensions(), copy, t.scr.method);
        var i: usize = 0;
        // each copy printed as the codepoint would be, joining what it joins
        while (i < n) : (i += 1) try t.put(copy);
    }

    /// Down one row, scrolling the region when there is nowhere to go.
    fn lineFeed(t: *Term) void {
        if (t.own_row == t.scroll_bottom) {
            t.scrollRegion(1);
        } else if (t.own_row + 1 < t.scr.dimensions().rows) {
            t.own_row += 1;
        }
        t.wrap_pending = false;
    }

    /// Moves the scrolling region's contents, blanking what it vacates with
    /// the current background, the way a terminal does.
    fn scrollRegion(t: *Term, n: i32) void {
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.scroll_top,
            .cols = t.scr.dimensions().cols,
            .rows = t.scroll_bottom - t.scroll_top + 1,
        };
        const keep = t.scr.cursor;
        t.scr.scroll(rect, n);
        t.blankVacated(rect, n);
        t.scr.cursor = keep;
    }

    /// `Screen.scroll` blanks in the default style; a terminal blanks in the
    /// background colour it is currently writing in.
    fn blankVacated(t: *Term, rect: geom.Rect, n: i32) void {
        if (t.style.bg.kind == .default and !t.style.reverse) return;
        const distance: u32 = @min(@abs(n), rect.rows);
        const blank: Cell = .blank(.{ .bg = t.style.bg, .reverse = t.style.reverse });
        const first: u16 = if (n > 0)
            @intCast(rect.bottom() - distance)
        else
            rect.row;
        for (0..distance) |k| {
            const row: u16 = @intCast(first + k);
            var col = rect.col;
            while (col < rect.right()) : (col += 1) t.setCell(col, row, blank);
        }
    }

    //=====================================================================
    // Sequences.
    //=====================================================================

    /// Reads one escape sequence, returning how many bytes it took or zero
    /// when the sequence is not all here yet.
    fn escape(t: *Term, bytes: []const u8) Allocator.Error!usize {
        if (bytes.len < 2) return 0;
        return switch (bytes[1]) {
            '[' => try t.controlSequence(bytes),
            ']' => try t.operatingSystemCommand(bytes),
            '_' => try t.applicationCommand(bytes),
            '7' => blk: {
                t.saved = .{ .col = t.col, .row = t.own_row, .style = t.style };
                break :blk 2;
            },
            '8' => blk: {
                if (t.saved) |s| {
                    t.moveTo(s.col, s.row);
                    t.style = s.style;
                }
                break :blk 2;
            },
            // `ESC \` on its own is a string terminator with nothing to
            // terminate, and anything else two bytes long is not written by
            // this package.
            else => 2,
        };
    }

    /// `CSI ... final`, framed by morse.
    fn controlSequence(t: *Term, bytes: []const u8) Allocator.Error!usize {
        const csi = morse.parseCsi(bytes) orelse return 0;
        if (csi.final != 0) try t.dispatch(csi);
        return csi.len.raw();
    }

    /// One complete control sequence, acted on.
    fn dispatch(t: *Term, csi: morse.Csi) Allocator.Error!void {
        if (csi.marker == '?') {
            t.privateMode(csi);
            return;
        }
        if (csi.marker != 0) return;
        if (std.mem.eql(u8, csi.intermediates, " ") and csi.final == 'q') {
            // A shape this package does not name is not one a renderer
            // wrote, and leaves the cursor as it was.
            const shape = aegis.int.cast(u8, csi.param(0) orelse 0) catch return;
            t.scr.cursor.shape = std.enums.fromInt(morse.CursorShape, shape) orelse return;
            return;
        }
        if (csi.intermediates.len != 0) return;
        switch (csi.final) {
            'm' => morse.applySgr(&t.style, csi.params),
            'H', 'f' => t.moveTo(coordinate(csi, 1), coordinate(csi, 0)),
            'A' => t.moveTo(t.col, t.own_row -| clamp(atLeastOne(csi))),
            'B' => t.moveTo(t.col, t.own_row +| clamp(atLeastOne(csi))),
            'C' => t.moveTo(t.col +| clamp(atLeastOne(csi)), t.own_row),
            'D' => t.moveTo(t.col -| clamp(atLeastOne(csi)), t.own_row),
            'E' => t.moveTo(0, t.own_row +| clamp(atLeastOne(csi))),
            'F' => t.moveTo(0, t.own_row -| clamp(atLeastOne(csi))),
            'G', '`' => t.moveTo(coordinate(csi, 0), t.own_row),
            'd' => t.moveTo(t.col, coordinate(csi, 0)),
            'J' => t.eraseScreen(csi.param(0) orelse 0),
            'K' => t.eraseLine(csi.param(0) orelse 0),
            'L' => t.insertLines(atLeastOne(csi)),
            'M' => t.deleteLines(atLeastOne(csi)),
            '@' => t.insertChars(atLeastOne(csi)),
            'P' => t.deleteChars(atLeastOne(csi)),
            'X' => t.eraseChars(atLeastOne(csi)),
            'S' => t.scrollRegion(t.scrollCount(csi)),
            'T' => t.scrollRegion(-t.scrollCount(csi)),
            'r' => t.setScrollRegion(csi),
            'b' => try t.repeat(atLeastOne(csi)),
            else => {},
        }
    }

    fn scrollCount(t: *const Term, csi: morse.Csi) i32 {
        const rows: u32 = t.scroll_bottom - t.scroll_top + 1;
        return @intCast(@min(atLeastOne(csi), rows));
    }

    /// `CSI ? n h` and `CSI ? n l`: the modes this package switches, by
    /// the numbers morse writes them with.
    fn privateMode(t: *Term, csi: morse.Csi) void {
        if (csi.final != 'h' and csi.final != 'l') return;
        const on = csi.final == 'h';
        var index: usize = 0;
        var fields = std.mem.splitScalar(u8, csi.params, ';');
        while (fields.next()) |_| : (index += 1) {
            switch (csi.param(index) orelse continue) {
                morse.cursorVisible.number => t.scr.cursor.visible = on,
                morse.autoWrap.number => t.autowrap = on,
                morse.unicodeCore.number => t.clusters_off = !on,
                else => {},
            }
        }
    }

    /// `CSI top ; bottom r`, DECSTBM, which also homes the cursor.
    fn setScrollRegion(t: *Term, csi: morse.Csi) void {
        const rows = t.scr.dimensions().rows;
        if (rows == 0) return;
        const top = @min(nonzeroParam(csi, 0, 1), rows) - 1;
        const bottom = @min(nonzeroParam(csi, 1, rows), rows) - 1;
        if (bottom <= top) return;
        t.scroll_top = @intCast(top);
        t.scroll_bottom = @intCast(bottom);
        t.moveTo(0, t.scroll_top);
    }

    /// The cursor, clamped to the grid.
    fn moveTo(t: *Term, col: u16, row: u16) void {
        if (t.scr.dimensions().cols == 0 or t.scr.dimensions().rows == 0) return;
        t.col = @min(col, t.scr.dimensions().cols - 1);
        t.own_row = @min(row, t.scr.dimensions().rows - 1);
        t.wrap_pending = false;
    }

    //=====================================================================
    // Erasing, inserting and deleting.
    //=====================================================================

    /// The cell an erase leaves behind: a space in the background the
    /// terminal is currently writing in.
    /// A cell into the grid. Every cell Term writes holds handles taken
    /// from its own screen and still live there: text interned a moment
    /// before or inline, and no link, the link Term holds in that screen, or
    /// a link read from one of its cells.
    fn setCell(t: *Term, col: u16, row: u16, c: Cell) void {
        // unreachable: the handles are this screen's own and live, as above
        t.scr.writeOwnedCellUnchecked(col, row, c) catch unreachable;
    }

    fn erased(t: *const Term) Cell {
        return .blank(.{ .bg = t.style.bg, .reverse = t.style.reverse });
    }

    /// `CSI n J`.
    fn eraseScreen(t: *Term, what: u32) void {
        const size = t.scr.dimensions();
        switch (what) {
            0 => {
                t.eraseRun(t.col, t.own_row, size.cols - t.col);
                var row = t.own_row + 1;
                while (row < size.rows) : (row += 1) t.eraseRun(0, row, size.cols);
            },
            1 => {
                var row: u16 = 0;
                while (row < t.own_row) : (row += 1) t.eraseRun(0, row, size.cols);
                t.eraseRun(0, t.own_row, t.col + 1);
            },
            2, 3 => {
                var row: u16 = 0;
                while (row < size.rows) : (row += 1) t.eraseRun(0, row, size.cols);
            },
            else => {},
        }
    }

    /// `CSI n K`.
    fn eraseLine(t: *Term, what: u32) void {
        const cols = t.scr.dimensions().cols;
        switch (what) {
            0 => t.eraseRun(t.col, t.own_row, cols - t.col),
            1 => t.eraseRun(0, t.own_row, t.col + 1),
            2 => t.eraseRun(0, t.own_row, cols),
            else => {},
        }
    }

    /// `CSI n X`, which erases without moving anything.
    fn eraseChars(t: *Term, n: u32) void {
        const cols = t.scr.dimensions().cols;
        t.eraseRun(t.col, t.own_row, @intCast(@min(n, cols - t.col)));
    }

    /// A run of cells back to blanks.
    fn eraseRun(t: *Term, col: u16, row: u16, count: u16) void {
        const blank = t.erased();
        var i: u16 = 0;
        while (i < count and col + i < t.scr.dimensions().cols) : (i += 1) {
            t.setCell(col + i, row, blank);
        }
    }

    /// `CSI n L`, inside the scrolling region.
    fn insertLines(t: *Term, n: u32) void {
        if (t.own_row < t.scroll_top or t.own_row > t.scroll_bottom) return;
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.own_row,
            .cols = t.scr.dimensions().cols,
            .rows = t.scroll_bottom - t.own_row + 1,
        };
        const count: i32 = @intCast(@min(n, rect.rows));
        t.scr.scroll(rect, -count);
        t.blankVacated(rect, -count);
    }

    /// `CSI n M`, inside the scrolling region.
    fn deleteLines(t: *Term, n: u32) void {
        if (t.own_row < t.scroll_top or t.own_row > t.scroll_bottom) return;
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.own_row,
            .cols = t.scr.dimensions().cols,
            .rows = t.scroll_bottom - t.own_row + 1,
        };
        const count: i32 = @intCast(@min(n, rect.rows));
        t.scr.scroll(rect, count);
        t.blankVacated(rect, count);
    }

    /// `CSI n @`: blanks opened at the cursor, the rest of the row pushed
    /// right.
    fn insertChars(t: *Term, n: u32) void {
        const cols = t.scr.dimensions().cols;
        const count: u16 = @intCast(@min(n, cols - t.col));
        var col = cols;
        while (col > t.col + count) {
            col -= 1;
            t.setCell(col, t.own_row, t.scr.readCell(col - count, t.own_row).?);
        }
        t.eraseRun(t.col, t.own_row, count);
    }

    /// `CSI n P`: cells removed at the cursor, the rest of the row pulled
    /// left.
    fn deleteChars(t: *Term, n: u32) void {
        const cols = t.scr.dimensions().cols;
        const count: u16 = @intCast(@min(n, cols - t.col));
        var col = t.col;
        while (col + count < cols) : (col += 1) {
            t.setCell(col, t.own_row, t.scr.readCell(col + count, t.own_row).?);
        }
        t.eraseRun(cols - count, t.own_row, count);
    }

    //=====================================================================
    // Styles and links.
    //=====================================================================

    /// `ESC ] ... ST`: OSC 8 changes what a cell links to, and OSC 66 prints
    /// text at a width it was told. Nothing else changes a cell. The bodies
    /// are read by `morse.parseHyperlink` and `morse.parseTextSize`, the
    /// inverses of what wrote them.
    fn operatingSystemCommand(t: *Term, bytes: []const u8) Allocator.Error!usize {
        const string = morse.parseControlString(bytes) orelse return 0;
        if (!string.terminated) return string.len.raw();
        if (morse.parseTextSize(string.body)) |sized| {
            try t.sizedText(sized);
        } else if (morse.parseHyperlink(string.body)) |found| {
            t.link = if (found.uri.len == 0)
                .none
            else
                t.scr.link(found.uri, found.params) catch |err| switch (err) {
                    error.ControlInText, error.TooLong => return string.len.raw(),
                    error.OutOfMemory => return error.OutOfMemory,
                };
        }
        return string.len.raw();
    }

    /// The text of an OSC 66, drawn at the width it was told and the scale
    /// it asks for. A width of one or two is acted on and any other is
    /// measured here; the fraction and the alignments are read and not acted
    /// on, because the renderer does not write them.
    fn sizedText(t: *Term, sized: morse.SizedText) Allocator.Error!void {
        const told: ?u2 = switch (sized.size.width) {
            1 => 1,
            2 => 2,
            else => null,
        };
        const scale = sized.size.scale;
        var it: textmod.Graphemes = .init(sized.text);
        while (it.next()) |g| {
            if (scale > 1) {
                try t.putScaled(g, told, scale);
            } else {
                try t.putAs(g, told);
            }
        }
    }

    /// One grapheme drawn at a scale: a block at the cursor, which then
    /// moves past it along the top row. A block that does not fit draws
    /// nothing, which is as far as this emulator follows the protocol.
    fn putScaled(t: *Term, bytes: []const u8, told: ?u2, scale: u3) Allocator.Error!void {
        const cols = t.scr.dimensions().cols;
        const rows = t.scr.dimensions().rows;
        if (cols == 0 or rows == 0) return;
        const grapheme = screen_internal.sanitized(bytes) orelse return;
        const w: u16 = told orelse textmod.graphemeWidth(grapheme, t.scr.method);
        if (w == 0 or w > 2) return;
        if (t.wrap_pending) {
            if (!t.autowrap) return;
            t.col = 0;
            t.lineFeed();
        }
        const span: u32 = @as(u32, w) * scale;
        if (t.col + span > cols or @as(u32, t.own_row) + scale > rows) return;
        const text = try t.intern(grapheme);
        t.setCell(t.col, t.own_row, .init(.{
            .text = text,
            .style = t.style,
            .link = t.link,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                .drift = textmod.disagrees(grapheme),
                .scale = scale,
            },
        }));
        t.previous = firstCodepoint(grapheme);
        t.col = @intCast(t.col + span);
        if (t.col >= cols) {
            t.col = cols - 1;
            t.wrap_pending = true;
        }
    }

    /// `ESC _ ... ST`, which is where a graphics command travels. It is
    /// recorded and never drawn: the text pass must be able to be asserted
    /// not to have written one.
    fn applicationCommand(t: *Term, bytes: []const u8) Allocator.Error!usize {
        const string = morse.parseControlString(bytes) orelse return 0;
        if (!string.terminated) return string.len.raw();
        const payload = try t.gpa.dupe(u8, string.body);
        errdefer t.gpa.free(payload);
        try t.own_graphics.append(t.gpa, payload);
        return string.len.raw();
    }

    //=====================================================================
    // Reading the terminal back.
    //=====================================================================

    /// The grid as text, one row a line.
    pub fn dump(t: *const Term, w: *Writer) Writer.Error!void {
        try dumpScreen(&t.scr, w, .{});
    }

    /// What `dumpStyles` and `dumpScreenStyles` fail with: the writer, or
    /// memory for telling the styles apart.
    pub const DumpStylesError = Writer.Error || std.mem.Allocator.Error;

    /// The styles as one identifier a cell, with the legend above.
    pub fn dumpStyles(t: *const Term, w: *Writer) DumpStylesError!void {
        try dumpScreenStyles(&t.scr, w);
    }

    /// A comparison that names the first cell that differs.
    pub fn expectEqual(want: *const Screen, got: *const Screen) ExpectError!void {
        return expectScreensEqual(want, got);
    }
};

/// How `dumpScreen` writes a grid as text.
pub const DumpOptions = struct {
    /// What a wide cluster's covered column is written as. Nothing, the
    /// default, holds each cluster once; a space makes every line as many
    /// characters as the grid has columns, for a program that reads a column
    /// back by its position in the line.
    tail: []const u8 = "",
};

/// The grid as text, one row a line, a wide cluster's covered column
/// written as `options.tail`: nothing by default, so each cluster is
/// written once.
pub fn dumpScreen(s: *const Screen, w: *Writer, options: DumpOptions) Writer.Error!void {
    var row: u16 = 0;
    while (row < s.dimensions().rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.dimensions().cols) : (col += 1) {
            const c = &s.own_cells[s.index(col, row)];
            try w.writeAll(if (c.isTail()) options.tail else screen_internal.textOf(s, c));
        }
        try w.writeByte('\n');
    }
}

/// The styles as one identifier a cell, with a legend above naming each one.
///
/// The goldens compare glyphs, and a swap that passes them has proved half a
/// renderer. This is the other half: the same draw writes a second file and
/// a colour that moved fails as loudly as a glyph that did.
///
/// The format, which is also what other programs write to compare against
/// this one:
///
/// - The legend first, one line per distinct style in the order it first
///   appears reading row by row: `# <id> fg=<c> bg=<c>` and then, where they
///   are on, ` ul=<u>`, ` ulc=<c>`, ` bold`, ` dim`, ` italic`, ` blink`,
///   ` reverse`, ` hidden`, ` strike`, ` overline`, ` superscript` or
///   ` subscript`, and last ` link=<uri>`
///   for a cell carrying an OSC 8 link. The link is part of what makes a
///   style distinct; its parameters are not printed.
/// - A colour is `default`, one of the sixteen names, `palette:<n>`, or
///   `#rrggbb` in lower case.
/// - Ids are `0-9a-zA-Z`, one character a cell when the screen has 62 styles
///   or fewer. Every id has the fewest base-62 digits that can name the whole
///   legend, padded with zeroes, most significant first, in legend and grid.
///   A grid row is its column count times that shared digit count.
/// - The grid is one line a row and one id a column. The column a wide
///   grapheme covers prints the id of the cell it continues.
/// - Every line ends in a newline, with no blank line after the last.
///
/// Allocates, on the screen's own allocator, what it needs to tell any
/// number of styles apart; nothing survives the call.
pub fn dumpScreenStyles(s: *const Screen, w: *Writer) Term.DumpStylesError!void {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each cell's legend line, keyed by the line itself: two cells whose
    // lines read the same are the same style to anyone reading the dump.
    var seen: std.array_hash_map.String(void) = .empty;
    const ids = try arena.alloc(u32, s.own_cells.len);
    var key: std.Io.Writer.Allocating = .init(arena);
    for (s.own_cells, 0..) |cell, i| {
        const col: u16 = @intCast(i % s.dimensions().cols);
        const row: u16 = @intCast(i / s.dimensions().cols);
        // A covered column speaks for the grapheme that covers it.
        const source = if (s.headOf(col, row)) |head| s.own_cells[s.index(head.col, head.row)] else cell;
        key.clearRetainingCapacity();
        writeStyleName(&key.writer, source.style) catch return error.OutOfMemory;
        if (screen_internal.target(s, source.link)) |target| {
            key.writer.print(" link={s}", .{target.uri}) catch return error.OutOfMemory;
        }
        const found = try seen.getOrPut(arena, key.written());
        if (!found.found_existing) found.key_ptr.* = try arena.dupe(u8, key.written());
        ids[i] = @intCast(found.index);
    }

    var digits: usize = 1;
    var capacity: u64 = alphabet.len;
    while (seen.count() > capacity) : (digits += 1) capacity *= alphabet.len;
    const Id = struct {
        fn write(out: *Writer, id: u32, width: usize) Writer.Error!void {
            // Six base-62 digits cover every u32 id a grid can hold.
            var bytes: [6]u8 = undefined;
            var value = id;
            var at = width;
            while (at > 0) {
                at -= 1;
                bytes[at] = alphabet[value % alphabet.len];
                value /= alphabet.len;
            }
            try out.writeAll(bytes[0..width]);
        }
    };
    for (seen.keys(), 0..) |line, i| {
        try w.writeAll("# ");
        try Id.write(w, @intCast(i), digits);
        try w.writeByte(' ');
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    var row: u16 = 0;
    while (row < s.dimensions().rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.dimensions().cols) : (col += 1) {
            try Id.write(w, ids[s.index(col, row)], digits);
        }
        try w.writeByte('\n');
    }
}

/// A style as a name a person can read in a diff.
fn writeStyleName(w: *Writer, style: Style) Writer.Error!void {
    try w.writeAll("fg=");
    try writeColorName(w, style.fg);
    try w.writeAll(" bg=");
    try writeColorName(w, style.bg);
    if (style.underline != .none) try w.print(" ul={t}", .{style.underline});
    if (style.underline_color.kind != .default) {
        try w.writeAll(" ulc=");
        try writeColorName(w, style.underline_color);
    }
    inline for (.{
        .{ "bold", style.bold },            .{ "dim", style.dim },
        .{ "italic", style.italic },        .{ "blink", style.blink },
        .{ "reverse", style.reverse },      .{ "hidden", style.hidden },
        .{ "strike", style.strikethrough }, .{ "overline", style.overline },
    }) |flag| {
        if (flag[1]) try w.print(" {s}", .{flag[0]});
    }
    if (style.script != .none) try w.print(" {t}", .{style.script});
}

/// A colour as a name.
fn writeColorName(w: *Writer, c: cellmod.Color) Writer.Error!void {
    switch (c.kind) {
        .default => try w.writeAll("default"),
        .ansi => try w.print("{t}", .{c.toAnsi()}),
        .palette => try w.print("palette:{d}", .{c.index()}),
        .rgb => {
            const v = c.toRgb();
            try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ v.r, v.g, v.b });
        },
    }
}

/// Whether two styles would write the same bytes.
fn stylesEqual(a: Style, b: Style) bool {
    const ca = cellmod.canonical(a);
    const cb = cellmod.canonical(b);
    return cellmod.sameBytes(Style, &ca, &cb);
}

/// What `expectScreensEqual` fails with when the two screens differ, the
/// error `std.testing.expectEqual` uses.
pub const ExpectError = error{TestExpectedEqual};

/// Two screens compared cell by cell, naming the first that differs and
/// logging both grids as errors under the `visor` scope, which the program's
/// `std.log` handler writes or drops.
pub fn expectScreensEqual(want: *const Screen, got: *const Screen) ExpectError!void {
    if (!std.meta.eql(want.dimensions(), got.dimensions())) {
        log.err(
            "screen size: want {d}x{d}, have {d}x{d}",
            .{ want.dimensions().cols, want.dimensions().rows, got.dimensions().cols, got.dimensions().rows },
        );
        return error.TestExpectedEqual;
    }
    const where = firstDifference(want, got) orelse return;
    reportCell(want, got, where.col, where.row);
    return error.TestExpectedEqual;
}

/// The first cell two screens disagree about, read by column, or null.
///
/// The kind is not compared, only what the terminal can show: a spacer left
/// by a wrap and a space someone asked for are the same cell to it, and only
/// this package knows the difference.
pub fn firstDifference(want: *const Screen, got: *const Screen) ?geom.Point {
    if (!std.meta.eql(want.dimensions(), got.dimensions())) return .{ .col = 0, .row = 0 };
    var row: u16 = 0;
    while (row < want.dimensions().rows) : (row += 1) {
        var col: u16 = 0;
        while (col < want.dimensions().cols) : (col += 1) {
            const a = want.own_cells[want.index(col, row)];
            const b = got.own_cells[got.index(col, row)];
            if (std.mem.eql(u8, want.textAt(col, row), got.textAt(col, row)) and
                linksEqual(want, got, a.link, b.link) and
                stylesEqual(a.style, b.style) and
                a.width() == b.width() and
                a.isTail() == b.isTail()) continue;
            return .{ .col = col, .row = row };
        }
    }
    return null;
}

/// Says what differs at one cell, then logs both grids whole.
fn reportCell(want: *const Screen, got: *const Screen, col: u16, row: u16) void {
    const a = want.own_cells[want.index(col, row)];
    const b = got.own_cells[got.index(col, row)];
    log.err("cell {d},{d} differs", .{ col, row });
    log.err("  want: \"{s}\" {any} link={any} shape={any}", .{
        want.textAt(col, row), a.style, screen_internal.target(want, a.link), a.shape,
    });
    log.err("  have: \"{s}\" {any} link={any} shape={any}", .{
        got.textAt(col, row), b.style, screen_internal.target(got, b.link), b.shape,
    });
    log.err("--- want ---\n{f}", .{Grid{ .screen = want }});
    log.err("--- have ---\n{f}", .{Grid{ .screen = got }});
}

/// A grid as text for a failing test to be read from: one row a line
/// between bars, each cluster once.
pub const Grid = struct {
    screen: *const Screen,

    pub fn format(g: Grid, w: *Writer) Writer.Error!void {
        const s = g.screen;
        var row: u16 = 0;
        while (row < s.dimensions().rows) : (row += 1) {
            try w.writeByte('|');
            var col: u16 = 0;
            while (col < s.dimensions().cols) : (col += 1) {
                if (s.own_cells[s.index(col, row)].isTail()) continue;
                try w.writeAll(s.textAt(col, row));
            }
            try w.writeAll("|\n");
        }
    }
};

/// Whether two cells' links name the same target, which is not the same as
/// holding the same index: the two screens interned in different orders.
fn linksEqual(want: *const Screen, got: *const Screen, a: @TypeOf(@as(cellmod.internal.StoredCell, .{}).link), b: @TypeOf(@as(cellmod.internal.StoredCell, .{}).link)) bool {
    const ta = screen_internal.target(want, a);
    const tb = screen_internal.target(got, b);
    if (ta == null or tb == null) return (ta == null) == (tb == null);
    return std.mem.eql(u8, ta.?.uri, tb.?.uri) and std.mem.eql(u8, ta.?.params, tb.?.params);
}

//=========================================================================
// Reading the bytes.
//=========================================================================

/// How many bytes at the end of a run are the start of a codepoint whose
/// rest has not arrived.
fn incompleteTail(run: []const u8) usize {
    var back: usize = 0;
    while (back < 4 and back < run.len) : (back += 1) {
        const b = run[run.len - 1 - back];
        if (b < 0x80) return 0;
        if (b >= 0xc0) {
            const need = std.unicode.utf8ByteSequenceLength(b) catch return back + 1;
            return if (need > back + 1) back + 1 else 0;
        }
    }
    return 0;
}

/// The first codepoint of a grapheme: U+FFFD when its first bytes are not
/// UTF-8, and null for no bytes.
fn firstCodepoint(grapheme: []const u8) ?u21 {
    if (grapheme.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(grapheme[0]) catch return 0xfffd;
    if (len > grapheme.len) return 0xfffd;
    const decoded = switch (len) {
        1 => grapheme[0],
        2 => std.unicode.utf8Decode2(grapheme[0..2].*),
        3 => std.unicode.utf8Decode3(grapheme[0..3].*),
        else => std.unicode.utf8Decode4(grapheme[0..4].*),
    };
    return decoded catch 0xfffd;
}

/// How many copies of `copy` a repeat of `count` prints (`Term.repeat`).
fn repeatCount(count: u32, size: Size, copy: []const u8, method: textmod.Method) usize {
    const w = textmod.graphemeWidth(copy, method);
    if (w == 0 or w > size.cols) return 0;
    if (method == .unicode and textmod.joinsCell(copy, copy)) return @min(count, 2 * size.area());
    const per_row: usize = size.cols / w;
    const steady = per_row * (@as(usize, size.rows) + 1);
    if (count <= steady) return count;
    return steady + (count - steady) % per_row;
}

/// Where a run of printable bytes ends.
fn runEnd(bytes: []const u8, from: usize) usize {
    var i = from;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] != 0x7f) i += 1;
    return i;
}

// Position and count parameters treat zero as their default. SGR does not.
fn nonzeroParam(csi: morse.Csi, n: usize, fallback: u32) u32 {
    const value = csi.param(n) orelse fallback;
    return if (value == 0) fallback else value;
}

/// A parameter as a coordinate, saturating rather than wrapping: a number
/// too large for the grid is clamped by `moveTo` anyway.
fn clamp(n: u32) u16 {
    return aegis.int.cast(u16, n) catch std.math.maxInt(u16);
}

/// A one-based coordinate, with zero and a missing field both meaning one.
fn coordinate(csi: morse.Csi, n: usize) u16 {
    return clamp(nonzeroParam(csi, n, 1) - 1);
}

/// The first parameter, never zero: the movement sequences all treat a
/// missing or zero count as one.
fn atLeastOne(csi: morse.Csi) u32 {
    return nonzeroParam(csi, 0, 1);
}

const testing = std.testing;
const checkInvariants = @import("screen.zig").test_access.checkInvariants;

/// A terminal of a size, with a helper for feeding it a string.
fn made(cols: u16, rows: u16) !Term {
    var t: Term = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    t.setMethod(.unicode);
    return t;
}

fn textAt(t: *const Term, col: u16, row: u16) []const u8 {
    return t.screen().textAt(col, row);
}

fn rowText(t: *const Term, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var col: u16 = 0;
    while (col < t.scr.dimensions().cols) : (col += 1) {
        const g = t.screen().textAt(col, row);
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

test "measuring by codepoint, a cluster of wide codepoints is printed a cell each" {
    var t: Term = try .init(testing.allocator, .{ .cols = 6, .rows = 2 });
    defer t.deinit();
    t.setMethod(.wcwidth);
    try t.feed("\u{1f469}\u{200d}\u{1f680}x");
    try testing.expectEqualStrings("\u{1f469}\u{200d}", t.screen().textAt(0, 0));
    try testing.expectEqualStrings("\u{1f680}", t.screen().textAt(2, 0));
    try testing.expectEqualStrings("x", t.screen().textAt(4, 0));
    // A cell of its own that does not fit wraps on its own.
    try t.feed("\u{1f468}\u{200d}\u{1f469}");
    try testing.expectEqualStrings("\u{1f468}\u{200d}", t.screen().textAt(0, 1));
    try testing.expectEqualStrings("\u{1f469}", t.screen().textAt(2, 1));
}

test "plain text lands where the cursor is" {
    var t = try made(8, 2);
    defer t.deinit();
    try t.feed("\x1b[2;3Hhi");
    try testing.expectEqualStrings("h", textAt(&t, 2, 1));
    try testing.expectEqualStrings("i", textAt(&t, 3, 1));
}

test "every movement this package writes is understood" {
    var t = try made(20, 10);
    defer t.deinit();
    try t.feed("\x1b[5;5H");
    try testing.expectEqual(@as(u16, 4), t.col);
    try testing.expectEqual(@as(u16, 4), t.own_row);
    try t.feed("\x1b[2A");
    try testing.expectEqual(@as(u16, 2), t.own_row);
    try t.feed("\x1b[3B");
    try testing.expectEqual(@as(u16, 5), t.own_row);
    try t.feed("\x1b[4C");
    try testing.expectEqual(@as(u16, 8), t.col);
    try testing.expectEqual(@as(u16, 5), t.own_row);
    try t.feed("\x1b[2D");
    try testing.expectEqual(@as(u16, 6), t.col);
    try t.feed("\x1b[9G");
    try testing.expectEqual(@as(u16, 8), t.col);
    try t.feed("\x1b[3d");
    try testing.expectEqual(@as(u16, 2), t.own_row);
    try t.feed("\r");
    try testing.expectEqual(@as(u16, 0), t.col);
    try t.feed("\x1b[2E");
    try testing.expectEqual(@as(u16, 4), t.own_row);
    try t.feed("\x1b[1F");
    try testing.expectEqual(@as(u16, 3), t.own_row);
    try t.feed("ab\x08");
    try testing.expectEqual(@as(u16, 1), t.col);
}

test "a movement past the edge is clamped rather than wrapped" {
    var t = try made(4, 3);
    defer t.deinit();
    try t.feed("\x1b[99;99H");
    try testing.expectEqual(@as(u16, 3), t.col);
    try testing.expectEqual(@as(u16, 2), t.own_row);
    try t.feed("\x1b[99A\x1b[99D");
    try testing.expectEqual(@as(u16, 0), t.col);
    try testing.expectEqual(@as(u16, 0), t.own_row);
}

test "every SGR this package writes comes back as the style it was" {
    const cases = [_]struct { bytes: []const u8, style: Style }{
        .{ .bytes = "\x1b[1m", .style = .{ .bold = true } },
        .{ .bytes = "\x1b[2m", .style = .{ .dim = true } },
        .{ .bytes = "\x1b[3m", .style = .{ .italic = true } },
        .{ .bytes = "\x1b[4m", .style = .{ .underline = .single } },
        .{ .bytes = "\x1b[4:3m", .style = .{ .underline = .curly } },
        .{ .bytes = "\x1b[4:5m", .style = .{ .underline = .dashed } },
        .{ .bytes = "\x1b[5m", .style = .{ .blink = true } },
        .{ .bytes = "\x1b[7m", .style = .{ .reverse = true } },
        .{ .bytes = "\x1b[8m", .style = .{ .hidden = true } },
        .{ .bytes = "\x1b[9m", .style = .{ .strikethrough = true } },
        .{ .bytes = "\x1b[53m", .style = .{ .overline = true } },
        .{ .bytes = "\x1b[73m", .style = .{ .script = .superscript } },
        .{ .bytes = "\x1b[74m", .style = .{ .script = .subscript } },
        .{ .bytes = "\x1b[73;75m", .style = .{} },
        .{ .bytes = "\x1b[31m", .style = .{ .fg = .ansi(.red) } },
        .{ .bytes = "\x1b[96m", .style = .{ .fg = .ansi(.bright_cyan) } },
        .{ .bytes = "\x1b[44m", .style = .{ .bg = .ansi(.blue) } },
        .{ .bytes = "\x1b[102m", .style = .{ .bg = .ansi(.bright_green) } },
        .{ .bytes = "\x1b[38;5;137m", .style = .{ .fg = .palette(137) } },
        .{ .bytes = "\x1b[48;5;7m", .style = .{ .bg = .palette(7) } },
        .{ .bytes = "\x1b[38;2;1;2;3m", .style = .{ .fg = .rgb(1, 2, 3) } },
        .{ .bytes = "\x1b[48;2;9;8;7m", .style = .{ .bg = .rgb(9, 8, 7) } },
        .{ .bytes = "\x1b[58:5:12m", .style = .{ .underline_color = .palette(12) } },
        .{
            .bytes = "\x1b[58:2::4:5:6m",
            .style = .{ .underline_color = .rgb(4, 5, 6) },
        },
    };
    for (cases) |case| {
        var t = try made(4, 1);
        defer t.deinit();
        try t.feed(case.bytes);
        try testing.expectEqual(case.style, t.style);
        try t.feed("\x1b[0m");
        try testing.expectEqual(Style{}, t.style);
    }
}

test "a style diff with several parameters is read as one" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("\x1b[1;3;4:2;31;48;2;7;7;7m");
    try testing.expectEqual(Style{
        .bold = true,
        .italic = true,
        .underline = .double,
        .fg = .ansi(.red),
        .bg = .rgb(7, 7, 7),
    }, t.style);
    try t.feed("\x1b[22;23;24;39;49m");
    try testing.expectEqual(Style{}, t.style);
}

test "an erase to the end of a row leaves blanks and nothing else" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("abcdef\x1b[1;3H\x1b[0K");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("ab    ", rowText(&t, 0, &buf));
}

test "erase chars erases without moving anything" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("abcdef\x1b[1;2H\x1b[3X");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("a   ef", rowText(&t, 0, &buf));
    try testing.expectEqual(@as(u16, 1), t.col);
}

test "an erase takes the background the terminal is writing in" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("\x1b[41m\x1b[2K");
    for (0..4) |col| {
        try testing.expect(Color.eql(.ansi(.red), t.screen().readCell(@intCast(col), 0).?.style.bg));
    }
}

test "a scroll region scrolls and the rest of the screen stays" {
    var t = try made(4, 6);
    defer t.deinit();
    for (0..6) |r| {
        try t.feed("\x1b[");
        var buf: [8]u8 = undefined;
        try t.feed(try std.mem.print(&buf, "{d};1H", .{r + 1}));
        try t.feed(&.{'a' + @as(u8, @intCast(r))});
    }
    try t.feed("\x1b[2;5r\x1b[1S\x1b[r");
    try testing.expectEqualStrings("a", textAt(&t, 0, 0));
    try testing.expectEqualStrings("c", textAt(&t, 0, 1));
    try testing.expectEqualStrings("d", textAt(&t, 0, 2));
    try testing.expectEqualStrings("e", textAt(&t, 0, 3));
    try testing.expectEqualStrings(" ", textAt(&t, 0, 4));
    try testing.expectEqualStrings("f", textAt(&t, 0, 5));
}

test "scroll down is the mirror of scroll up" {
    var t = try made(4, 4);
    defer t.deinit();
    try t.feed("a\x1b[2;1Hb\x1b[3;1Hc\x1b[4;1Hd");
    try t.feed("\x1b[2T");
    try testing.expectEqualStrings(" ", textAt(&t, 0, 0));
    try testing.expectEqualStrings(" ", textAt(&t, 0, 1));
    try testing.expectEqualStrings("a", textAt(&t, 0, 2));
    try testing.expectEqualStrings("b", textAt(&t, 0, 3));
}

test "scroll counts larger than i32 saturate to the region" {
    var t = try made(4, 4);
    defer t.deinit();
    try t.feed("a\x1b[2;1Hb\x1b[3;1Hc\x1b[4;1Hd");
    try t.feed("\x1b[2147483648S");
    for (0..4) |row| try testing.expectEqualStrings(" ", textAt(&t, 0, @intCast(row)));
}

test "insert and delete move a row sideways" {
    var t = try made(6, 1);
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try t.feed("abcdef\x1b[1;2H\x1b[2@");
    try testing.expectEqualStrings("a  bcd", rowText(&t, 0, &buf));
    try t.feed("\x1b[1;2H\x1b[2P");
    try testing.expectEqualStrings("abcd  ", rowText(&t, 0, &buf));
}

test "insert and delete move rows up and down" {
    var t = try made(4, 4);
    defer t.deinit();
    try t.feed("a\x1b[2;1Hb\x1b[3;1Hc\x1b[4;1Hd");
    try t.feed("\x1b[2;1H\x1b[1L");
    try testing.expectEqualStrings("a", textAt(&t, 0, 0));
    try testing.expectEqualStrings(" ", textAt(&t, 0, 1));
    try testing.expectEqualStrings("b", textAt(&t, 0, 2));
    try t.feed("\x1b[2;1H\x1b[1M");
    try testing.expectEqualStrings("b", textAt(&t, 0, 1));
}

test "a wide grapheme takes two columns and the second one never draws" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("a\u{4e2d}b");
    try testing.expectEqualStrings("a", textAt(&t, 0, 0));
    try testing.expectEqualStrings("\u{4e2d}", textAt(&t, 1, 0));
    try testing.expect(t.screen().readCell(2, 0).?.isTail());
    try testing.expectEqualStrings("b", textAt(&t, 3, 0));
}

test "text past the last column wraps to the next row" {
    var t = try made(3, 2);
    defer t.deinit();
    try t.feed("abcd");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("abc", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("d  ", rowText(&t, 1, &buf));
}

test "a wide grapheme that does not fit leaves a spacer and goes to the next row" {
    var t = try made(4, 2);
    defer t.deinit();
    try t.feed("abc\u{4e2d}");
    try testing.expectEqual(Cell.Kind.spacer_head, t.screen().readCell(3, 0).?.shape.kind);
    try testing.expectEqualStrings("\u{4e2d}", textAt(&t, 0, 1));
}

test "a link opens and closes and its parameters come through" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("\x1b]8;id=7;https://ziglang.org\x1b\\ab\x1b]8;;\x1b\\c");
    const link = t.screen().readCell(0, 0).?.link;
    try testing.expect(link != .none);
    try testing.expectEqualStrings("https://ziglang.org", t.screen().target(link).?.uri);
    try testing.expectEqualStrings("id=7", t.screen().target(link).?.params);
    try testing.expectEqual(link, t.screen().readCell(1, 0).?.link);
    try testing.expectEqual(cellmod.Link.none, t.screen().readCell(2, 0).?.link);
}

test "a hyperlink allocation failure is reported and can be retried" {
    var t = try made(4, 1);
    defer t.deinit();
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const failed_gpa = failing.allocator();
    t.gpa = failed_gpa;
    t.scr.gpa = failed_gpa;
    t.scr.links.gpa = failed_gpa;
    try testing.expectError(error.OutOfMemory, t.feed("\x1b]8;id=7;https://ziglang.org\x1b\\"));
    t.gpa = testing.allocator;
    t.scr.gpa = testing.allocator;
    t.scr.links.gpa = testing.allocator;
    try testing.expectEqual(Link.none, t.link);

    try t.feed("\x1b]8;id=7;https://ziglang.org\x1b\\x");
    const link = t.screen().readCell(0, 0).?.link;
    try testing.expect(link != .none);
    try testing.expectEqualStrings("https://ziglang.org", t.screen().target(link).?.uri);
}

test "the cursor's visibility and shape are read off the wire" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("\x1b[?25h");
    try testing.expect(t.screen().cursor.visible);
    try t.feed("\x1b[?25l");
    try testing.expect(!t.screen().cursor.visible);
    try t.feed("\x1b[6 q");
    try testing.expectEqual(morse.CursorShape.bar, t.screen().cursor.shape);
    // Every shape morse writes, by the number it writes it with.
    for (std.enums.values(morse.CursorShape)) |shape| {
        var bytes: [16]u8 = undefined;
        var w: Writer = .fixed(&bytes);
        try morse.cursorShape(&w, shape);
        try t.feed(w.buffered());
        try testing.expectEqual(shape, t.screen().cursor.shape);
    }
    // A shape morse has no name for is not one a renderer wrote.
    try t.feed("\x1b[5 q\x1b[9 q");
    try testing.expectEqual(morse.CursorShape.bar_blink, t.screen().cursor.shape);
}

test "the modes are read by the numbers morse writes them with" {
    var t = try made(4, 1);
    defer t.deinit();
    var bytes: [64]u8 = undefined;
    var w: Writer = .fixed(&bytes);
    try morse.autoWrap.set(&w, false);
    try morse.cursorVisible.set(&w, false);
    try morse.unicodeCore.set(&w, false);
    try t.feed(w.buffered());
    try testing.expect(!t.autowrap);
    try testing.expect(!t.screen().cursor.visible);
    try testing.expect(t.clusters_off);
    w = .fixed(&bytes);
    try morse.autoWrap.set(&w, true);
    try morse.cursorVisible.set(&w, true);
    try morse.unicodeCore.set(&w, true);
    try t.feed(w.buffered());
    try testing.expect(t.autowrap);
    try testing.expect(t.screen().cursor.visible);
    try testing.expect(!t.clusters_off);
}

test "a graphics command is recorded and draws nothing" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("ab\x1b_Ga=p,i=1,p=1\x1b\\c");
    try testing.expectEqual(@as(usize, 1), t.own_graphics.items.len);
    try testing.expectEqualStrings("Ga=p,i=1,p=1", t.own_graphics.items[0]);
    try testing.expectEqualStrings("c", textAt(&t, 2, 0));
}

test "a sequence split across two feeds is held until the rest arrives" {
    var t = try made(8, 2);
    defer t.deinit();
    try t.feed("\x1b[2;");
    try testing.expectEqual(@as(u16, 0), t.own_row);
    try t.feed("3Hx");
    try testing.expectEqualStrings("x", textAt(&t, 2, 1));
}

test "a codepoint split across two feeds is held until the rest arrives" {
    var t = try made(8, 1);
    defer t.deinit();
    const wide = "\u{4e2d}";
    try t.feed(wide[0..1]);
    try testing.expectEqualStrings(" ", textAt(&t, 0, 0));
    try t.feed(wide[1..]);
    try testing.expectEqualStrings(wide, textAt(&t, 0, 0));
}

test "an unrecognised sequence is dropped rather than guessed at" {
    var t = try made(8, 1);
    defer t.deinit();
    try t.feed("a\x1b[?1000h\x1b[>4;2mb\x1b]0;a title\x07c");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("abc     ", rowText(&t, 0, &buf));
}

test "a repeat prints the last codepoint again and wraps as printing would" {
    var t = try made(4, 2);
    defer t.deinit();
    try t.feed("x\x1b[5b");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("xxxx", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("xx  ", rowText(&t, 1, &buf));
    try testing.expectEqual(@as(u16, 2), t.col);
}

test "measuring clusters, a codepoint the break rules join goes into the cell on the left, wherever the cursor came from" {
    // A regional indicator printed after a move, beside another: one flag.
    var t = try made(8, 1);
    defer t.deinit();
    try t.feed("\u{1f1e6}\x1b[1;3H\u{1f1e7}z");
    try testing.expectEqualStrings("\u{1f1e6}\u{1f1e7}", textAt(&t, 0, 0));
    try testing.expectEqualStrings("z", textAt(&t, 2, 0));
    // A spacing mark widens the letter it joins.
    var mark = try made(8, 1);
    defer mark.deinit();
    try mark.feed("a\x1b[1;2H\u{903}z");
    try testing.expectEqualStrings("a\u{903}", textAt(&mark, 0, 0));
    try testing.expectEqual(Cell.Kind.wide, mark.screen().readCell(0, 0).?.shape.kind);
    try testing.expectEqualStrings("z", textAt(&mark, 2, 0));
    // With mode 2027 off, or in the first column, nothing joins.
    var off = try made(8, 1);
    defer off.deinit();
    try off.feed("\u{1f1e6}\x1b[?2027l\u{1f1e7}\x1b[?2027h");
    try testing.expectEqualStrings("\u{1f1e6}", textAt(&off, 0, 0));
    try testing.expectEqualStrings("\u{1f1e7}", textAt(&off, 2, 0));
    var first = try made(8, 2);
    defer first.deinit();
    try first.feed("a\x1b[2;1H\u{903}");
    try testing.expectEqualStrings("a", textAt(&first, 0, 0));
    try testing.expectEqualStrings("\u{903}", textAt(&first, 0, 1));
}

test "a repeat after a cluster repeats the codepoint that began its cell, as the pinned emulator does" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("e\u{301}\x1b[2b");
    try testing.expectEqualStrings("e\u{301}", textAt(&t, 0, 0));
    try testing.expectEqualStrings("e", textAt(&t, 1, 0));
    try testing.expectEqualStrings("e", textAt(&t, 2, 0));
    try testing.expectEqual(@as(?u21, 'e'), t.previous);
    // a pair of indicators joined in one cell: the first repeats, and the
    // two repeats pair with each other (conformance's "a repeat after a
    // cluster")
    var pair = try made(8, 1);
    defer pair.deinit();
    pair.setMethod(.unicode);
    try pair.feed("\u{1f1e6}\u{1f1e7}\x1b[2b");
    try testing.expectEqualStrings("\u{1f1e6}\u{1f1e7}", textAt(&pair, 0, 0));
    try testing.expectEqualStrings("\u{1f1e6}\u{1f1e6}", textAt(&pair, 2, 0));
}

test "a repeat with nothing printed yet prints nothing" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("\x1b[3b");
    try testing.expect(!t.scr.damage.any());
}

test "a cluster told its width takes that width whatever this terminal measures" {
    var t = try made(8, 1);
    defer t.deinit();
    t.setMethod(.wcwidth);
    // Narrow by codepoint, and told it is wide.
    try t.feed("\x1b]66;w=2;\u{26a0}\u{fe0f}\x1b\\a");
    try testing.expectEqualStrings("\u{26a0}\u{fe0f}", textAt(&t, 0, 0));
    try testing.expect(t.screen().readCell(1, 0).?.isTail());
    try testing.expectEqualStrings("a", textAt(&t, 2, 0));
    // Wide by cluster, and told it is narrow.
    try t.feed("\x1b]66;w=1;\u{4e2d}\x1b\\b");
    try testing.expectEqualStrings("\u{4e2d}", textAt(&t, 3, 0));
    try testing.expectEqualStrings("b", textAt(&t, 4, 0));
}

test "scaled text is a block, and the cursor moves past it along the top" {
    var t = try made(8, 3);
    defer t.deinit();
    try t.feed("\x1b]66;s=2:w=1;a\x1b\\b");
    try testing.expectEqualStrings("a", textAt(&t, 0, 0));
    try testing.expectEqual(@as(u3, 2), t.screen().readCell(0, 0).?.shape.scale);
    try testing.expect(t.screen().readCell(1, 0).?.isTail());
    try testing.expect(t.screen().readCell(0, 1).?.isTail());
    try testing.expect(t.screen().readCell(1, 1).?.isTail());
    try testing.expectEqualStrings("b", textAt(&t, 2, 0));
    // A block with no room draws nothing.
    try t.feed("\x1b[3;1H\x1b]66;s=2;c\x1b\\");
    try testing.expectEqualStrings(" ", textAt(&t, 0, 2));
}

test "sized text without a width is printed as ordinary text" {
    var t = try made(8, 1);
    defer t.deinit();
    try t.feed("\x1b]66;;ab\x1b\\");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("ab      ", rowText(&t, 0, &buf));
}

test "sized text morse does not read is dropped, not guessed at" {
    var t = try made(8, 1);
    defer t.deinit();
    try t.feed("\x1b]66;s=9;a\x1b\\\x1b]66;w=2:w=1;b\x1b\\\x1b]66;x\x1b\\c");
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("c       ", rowText(&t, 0, &buf));
}

test "a saved cursor comes back where it was" {
    var t = try made(8, 2);
    defer t.deinit();
    try t.feed("\x1b[2;4H\x1b[1m\x1b7\x1b[1;1H\x1b[0m\x1b8x");
    try testing.expectEqualStrings("x", textAt(&t, 3, 1));
    try testing.expect(t.screen().readCell(3, 1).?.style.bold);
}

test "the dump is one row a line and a wide grapheme takes its two columns" {
    var t = try made(4, 2);
    defer t.deinit();
    try t.feed("a\u{4e2d}b");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.dump(&out.writer);
    try testing.expectEqualStrings("a\u{4e2d}b\n    \n", out.written());
}

test "the style dump names every style it used" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("\x1b[31ma\x1b[0mb");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.dumpStyles(&out.writer);
    try testing.expectEqualStrings(
        \\# 0 fg=red bg=default
        \\# 1 fg=default bg=default
        \\0111
        \\
    , out.written());
}

test "the style dump spells every attribute in one order, and a link is part of the style" {
    var sc: Screen = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer sc.deinit();
    const everything: Style = .{
        .fg = .palette(208),
        .bg = .rgb(0x1e, 0x1e, 0x2e),
        .underline = .curly,
        .underline_color = .ansi(.bright_red),
        .bold = true,
        .dim = true,
        .italic = true,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
        .script = .superscript,
    };
    try sc.write(0, 0, "a", everything, .none);
    const zig = try sc.link("https://ziglang.org", "id=1");
    const other = try sc.link("https://ziglang.org", "id=2");
    try sc.write(1, 0, "b", .{}, zig);
    // The same URI under another id prints the same line, so it is the same
    // style to anyone reading the dump.
    try sc.write(2, 0, "c", .{}, other);
    // A wide grapheme's covered column prints the id of the cell it covers.
    try sc.write(0, 1, "\u{4e2d}", .{ .fg = .ansi(.cyan) }, .none);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dumpScreenStyles(&sc, &out.writer);
    try testing.expectEqualStrings(
        \\# 0 fg=palette:208 bg=#1e1e2e ul=curly ulc=bright_red bold dim italic blink reverse hidden strike overline superscript
        \\# 1 fg=default bg=default link=https://ziglang.org
        \\# 2 fg=default bg=default
        \\# 3 fg=cyan bg=default
        \\0112
        \\3322
        \\
    , out.written());
}

test "past sixty-two styles every id is two characters, legend and grid alike" {
    const cols = 10;
    const rows = 7;
    var sc: Screen = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    defer sc.deinit();
    for (0..rows) |r| for (0..cols) |c| {
        const n: u8 = @intCast(r * cols + c);
        try sc.write(@intCast(c), @intCast(r), "x", .{ .fg = .rgb(n, 0, 0) }, .none);
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dumpScreenStyles(&sc, &out.writer);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var legend: usize = 0;
    var grid: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            try testing.expect(lines.next() == null);
            break;
        }
        if (line[0] == '#') {
            legend += 1;
            continue;
        }
        try testing.expectEqual(@as(usize, 2 * cols), line.len);
        grid += 1;
    }
    try testing.expectEqual(@as(usize, cols * rows), legend);
    try testing.expectEqual(@as(usize, rows), grid);
    try testing.expect(std.mem.startsWith(u8, out.written(), "# 00 fg=#000000 bg=default\n"));
    // The sixty-third style is the first to need the second character.
    try testing.expect(std.mem.find(u8, out.written(), "# 10 fg=#3e0000 bg=default\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), "# 0Z fg=#3d0000 bg=default\n") != null);
    // And the grid's first row is the first ten, two characters each.
    try testing.expect(std.mem.find(u8, out.written(), "\n00010203040506070809\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), "?") == null);
}

test "comparing two screens names the first cell that differs" {
    var a: Screen = try .init(testing.allocator, .{ .cols = 3, .rows = 2 });
    defer a.deinit();
    var b: Screen = try .init(testing.allocator, .{ .cols = 3, .rows = 2 });
    defer b.deinit();
    try expectScreensEqual(&a, &b);
    try testing.expectEqual(@as(?geom.Point, null), firstDifference(&a, &b));

    // Read by column, so the covered column of a wide grapheme is compared
    // rather than lost in a dump.
    try a.write(1, 1, "x", .{}, .none);
    try testing.expectEqual(geom.Point{ .col = 1, .row = 1 }, firstDifference(&a, &b).?);
    try b.write(1, 1, "x", .{ .bold = true }, .none);
    try testing.expectEqual(geom.Point{ .col = 1, .row = 1 }, firstDifference(&a, &b).?);
    try b.write(1, 1, "x", .{}, .none);
    try testing.expectEqual(@as(?geom.Point, null), firstDifference(&a, &b));

    try a.write(0, 0, "\u{4e2d}", .{}, .none);
    try b.write(0, 0, "\u{ff21}", .{}, .none);
    try testing.expectEqual(geom.Point{ .col = 0, .row = 0 }, firstDifference(&a, &b).?);
}

//=========================================================================
// The dump format, pinned as a program keeps its goldens in it: the glyph
// dump and the style dump of one small screen, byte for byte. A program that
// writes the same dump from another renderer, or keeps years of goldens in
// it, is holding this package to these bytes.
//=========================================================================

test "the dumps a program keeps its goldens in are these bytes" {
    var screen: Screen = try .init(testing.allocator, .{ .cols = 6, .rows = 2 });
    defer screen.deinit();
    screen.method = .unicode;
    try screen.write(0, 0, "a", .{ .fg = .ansi(.red), .bold = true }, .none);
    try screen.write(1, 0, "b", .{ .fg = .ansi(.bright_red), .bg = .palette(200) }, .none);
    try screen.write(2, 0, "\u{4E2D}", .{ .fg = .rgb(255, 16, 0), .underline = .curly, .underline_color = .palette(3) }, .none);
    try screen.write(4, 0, "l", .{}, try screen.link("https://example.com", "id=1"));
    try screen.write(0, 1, "r", .{ .reverse = true, .hidden = true, .strikethrough = true, .dim = true, .italic = true, .blink = true }, .none);

    var styles: std.Io.Writer.Allocating = .init(testing.allocator);
    defer styles.deinit();
    try dumpScreenStyles(&screen, &styles.writer);
    try testing.expectEqualStrings(
        \\# 0 fg=red bg=default bold
        \\# 1 fg=bright_red bg=palette:200
        \\# 2 fg=#ff1000 bg=default ul=curly ulc=palette:3
        \\# 3 fg=default bg=default link=https://example.com
        \\# 4 fg=default bg=default
        \\# 5 fg=default bg=default dim italic blink reverse hidden strike
        \\012234
        \\544444
        \\
    , styles.written());

    var glyphs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer glyphs.deinit();
    try dumpScreen(&screen, &glyphs.writer, .{});
    try testing.expectEqualStrings("ab\u{4E2D}l \nr     \n", glyphs.written());

    // and with a filler for the covered column, a line a column a character
    glyphs.clearRetainingCapacity();
    try dumpScreen(&screen, &glyphs.writer, .{ .tail = " " });
    try testing.expectEqualStrings("ab\u{4E2D} l \nr     \n", glyphs.written());
}

test "past sixty-two styles the ids run 00 to 0Z and then 10, in order of first appearance" {
    var screen: Screen = try .init(testing.allocator, .{ .cols = 64, .rows = 1 });
    defer screen.deinit();
    for (0..64) |c| try screen.writeOwnedCell(@intCast(c), 0, .blank(.{ .fg = .palette(@intCast(c + 16)) }));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dumpScreenStyles(&screen, &out.writer);
    const got = out.written();
    try testing.expect(std.mem.startsWith(u8, got, "# 00 fg=palette:16 bg=default\n"));
    try testing.expect(std.mem.find(u8, got, "\n# 10 fg=palette:78 bg=default\n# 11 fg=palette:79 bg=default\n") != null);
    try testing.expect(std.mem.endsWith(u8, got, "\n000102030405060708090a0b0c0d0e0f0g0h0i0j0k0l0m0n0o0p0q0r0s0t0u0v0w0x0y0z0A0B0C0D0E0F0G0H0I0J0K0L0M0N0O0P0Q0R0S0T0U0V0W0X0Y0Z1011\n"));
}

test "the terminal consumes a refused link without opening it" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("\x1b]8;;https://bad/\x01tail\x1b\\x");
    try testing.expectEqual(Link.none, t.screen().readCell(0, 0).?.link);
    try t.feed("\x1b]8;;https://good\x1b\\y");
    try testing.expect(t.screen().readCell(1, 0).?.link != .none);
}

test "a resize keeps the terminal's open link even before any cell uses it" {
    var t = try Term.init(testing.allocator, .{ .cols = 4, .rows = 1 });
    defer t.deinit();
    try t.feed("\x1b]8;id=shown;https://shown.invalid\x1b\\a\x1b]8;id=open;https://open.invalid\x1b\\");
    try t.resize(.{ .cols = 5, .rows = 1 });
    const active = t.scr.target(t.link) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("https://open.invalid", active.uri);
    try testing.expectEqualStrings("id=open", active.params);
    try t.feed("b");
    try testing.expectEqualStrings("https://shown.invalid", t.scr.target(t.scr.readCell(0, 0).?.link).?.uri);
    try testing.expectEqualStrings("https://open.invalid", t.scr.target(t.scr.readCell(1, 0).?.link).?.uri);
    try testing.expectEqualStrings("a", t.scr.textAt(0, 0));
    try testing.expectEqualStrings("b", t.scr.textAt(1, 0));
}

/// Tests only. Every allocation-failure check runs over it: each growth is then an
/// allocation in every run, so the count of allocations to fail repeats.
const NoResize = @import("shakedown").alloc.NoResize;

test "a failed terminal resize keeps its open link and both pool generations" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var t = try Term.init(gpa, .{ .cols = 4, .rows = 1 });
            defer t.deinit();
            try t.feed("\x1b]8;id=open;https://open.invalid\x1b\\");
            const before = t.link;
            const generation = t.scr.pool_generation;
            t.resize(.{ .cols = 5, .rows = 2 }) catch |err| {
                try testing.expectEqual(before, t.link);
                try testing.expectEqual(generation, t.scr.pool_generation);
                try testing.expectEqualStrings("https://open.invalid", t.scr.target(t.link).?.uri);
                return err;
            };
            try t.feed("x");
            try testing.expectEqualStrings("https://open.invalid", t.scr.target(t.scr.readCell(0, 0).?.link).?.uri);
        }
    }.run, .{});
}

test "zero coordinates and oversized line counts stay inside the terminal grid" {
    var t = try made(3, 2);
    defer t.deinit();
    try t.feed("\x1b[0;0Hq\x1b[0G\x1b[0d");
    try testing.expectEqualStrings("q", textAt(&t, 0, 0));
    try t.feed("\x1b[4294967295L");
    try testing.expectEqualStrings(" ", textAt(&t, 0, 0));
    try t.feed("q\x1b[0;0H\x1b[4294967295M");
    try testing.expectEqualStrings(" ", textAt(&t, 0, 0));
}

test "a growing cluster and scaled text check the u16 coordinate edge before narrowing" {
    var t = try made(std.math.maxInt(u16), 2);
    defer t.deinit();
    try t.feed("\x1b[1;65535H❤");
    try t.feed("️");
    try testing.expectEqualStrings("❤️", textAt(&t, 0, 1));
    try testing.expectEqualStrings(" ", textAt(&t, std.math.maxInt(u16) - 1, 0));
    var tall = try made(7, std.math.maxInt(u16));
    defer tall.deinit();
    try tall.feed("\x1b[65535;1H\x1b]66;s=7;x\x1b\\");
    try testing.expectEqualStrings(" ", textAt(&tall, 0, std.math.maxInt(u16) - 1));
}

test "a saved terminal cursor stays inside the grid after a resize" {
    var t = try made(4, 3);
    defer t.deinit();
    try t.feed("\x1b[3;4H\x1b7");
    try t.resize(.{ .cols = 1, .rows = 1 });
    try t.feed("\x1b8x");
    try testing.expectEqualStrings("x", textAt(&t, 0, 0));
}

test "style dump IDs grow beyond the two digit legend" {
    for ([_]u16{ 1, 62, 63, 3844, 3845 }) |count| {
        var screen = try Screen.init(testing.allocator, .{ .cols = count, .rows = 1 });
        defer screen.deinit();
        for (0..count) |i| try screen.writeOwnedCell(@intCast(i), 0, .blank(.{ .fg = .rgb(@intCast(i / 256), @intCast(i % 256), 0) }));
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try dumpScreenStyles(&screen, &out.writer);
        const digits: usize = if (count <= 62) 1 else if (count <= 3844) 2 else 3;
        var lines = std.mem.splitScalar(u8, out.written(), '\n');
        for (0..count) |i| {
            const legend = lines.next().?;
            try testing.expect(std.mem.startsWith(u8, legend, "# "));
            try testing.expectEqual(@as(u8, ' '), legend[2 + digits]);
            var id: usize = 0;
            for (legend[2..][0..digits]) |digit| id = id * 62 + std.mem.findScalar(u8, "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", digit).?;
            try testing.expectEqual(i, id);
        }
        const grid = lines.next().?;
        try testing.expectEqual(@as(usize, count) * digits, grid.len);
        for (0..count) |i| {
            var id: usize = 0;
            for (grid[i * digits ..][0..digits]) |digit| id = id * 62 + std.mem.findScalar(u8, "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", digit).?;
            try testing.expectEqual(i, id);
        }
        try testing.expectEqualStrings("", lines.next().?);
        try testing.expect(lines.next() == null);
    }
}

test "scroll margins normalize zero defaults before checking their region" {
    var term = try made(4, 4);
    defer term.deinit();
    try term.feed("\x1b[0;2r");
    try testing.expectEqual(@as(u16, 0), term.scroll_top);
    try testing.expectEqual(@as(u16, 1), term.scroll_bottom);
    try term.feed("\x1b[2;0r");
    try testing.expectEqual(@as(u16, 1), term.scroll_top);
    try testing.expectEqual(@as(u16, 3), term.scroll_bottom);
    try term.feed("\x1b[0;0r");
    try testing.expectEqual(@as(u16, 0), term.scroll_top);
    try testing.expectEqual(@as(u16, 3), term.scroll_bottom);
    try term.feed("\x1b[4294967294;4294967295r");
    try testing.expectEqual(@as(u16, 0), term.scroll_top);
    try testing.expectEqual(@as(u16, 3), term.scroll_bottom);
    try term.feed("\x1b[4;2r");
    try testing.expectEqual(@as(u16, 0), term.scroll_top);
    try testing.expectEqual(@as(u16, 3), term.scroll_bottom);
}

test "bytes that are not UTF-8 are the replacement character, under every width method" {
    for ([_]textmod.Method{ .wcwidth, .unicode, .explicit }) |method| {
        var t = try made(10, 3);
        defer t.deinit();
        t.setMethod(method);
        try t.feed("a\xffb\xe4\xb8");
        try t.feed("c");
        try testing.expectEqualStrings("a", textAt(&t, 0, 0));
        try testing.expectEqualStrings("\u{fffd}", textAt(&t, 1, 0));
        try testing.expectEqualStrings("b", textAt(&t, 2, 0));
        try testing.expectEqualStrings("\u{fffd}", textAt(&t, 3, 0));
        try testing.expectEqualStrings("c", textAt(&t, 4, 0));
        // A repeat of a replacement character is one more of it.
        try t.feed("\xff\x1b[2b");
        try testing.expectEqualStrings("\u{fffd}", textAt(&t, 7, 0));
        try checkInvariants(t.screen());
    }
}

test "a cluster that takes a column only measured whole is printed, not refused" {
    for ([_]textmod.Method{ .wcwidth, .unicode, .explicit }) |method| {
        var t = try made(4, 1);
        defer t.deinit();
        t.setMethod(method);
        try t.feed("\u{1161}\u{85}x");
        try testing.expectEqualStrings("x", textAt(&t, if (method == .wcwidth) 0 else 1, 0));
    }
}

test "a repeat count in the billions ends as the whole count would" {
    // 2^32 copies in all, a multiple of the row: every row full, the
    // cursor waiting to wrap at the last column.
    var t = try made(4, 2);
    defer t.deinit();
    try t.feed("a\x1b[4294967295b");
    for (0..2) |row| for (0..4) |col| try testing.expectEqualStrings("a", textAt(&t, @intCast(col), @intCast(row)));
    // And a cut count leaves what printing every copy does, at every
    // remainder, narrow and wide, with an odd column left over.
    for ([_][]const u8{ "a", "\u{4e2d}" }) |glyph| for (16..40) |count| {
        var whole = try made(5, 2);
        defer whole.deinit();
        var cut = try made(5, 2);
        defer cut.deinit();
        try whole.feed(glyph);
        try cut.feed(glyph);
        for (0..count) |_| try whole.feed(glyph);
        var seq: [16]u8 = undefined;
        try cut.feed(try std.mem.print(&seq, "\x1b[{d}b", .{count}));
        try expectScreensEqual(whole.screen(), cut.screen());
        try testing.expectEqual(whole.col, cut.col);
        try testing.expectEqual(whole.own_row, cut.own_row);
        try testing.expectEqual(whole.wrap_pending, cut.wrap_pending);
        try testing.expect(repeatCount(@intCast(count + 40), whole.screen().dimensions(), glyph, .unicode) <= 40);
    };
}

test "arbitrary bytes keep the grid's invariants under every width method" {
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const random = prng.random();
    // Bytes biased toward what breaks a decoder: escapes, C1 lead bytes,
    // continuation bytes, marks and wide codepoints.
    const pieces = [_][]const u8{ "\x1b", "[", "]", "8;;", "\x07", "\xc2\x85", "\xc2\x9b", "\x80", "\xff", "\xe4", "\u{301}", "\u{1161}", "\u{4e2d}", "\u{1f1e6}", "\u{200d}", "\u{600}", "b", "66;w=2;", "4294967295", "\r\n", ";" };
    for (0..600) |_| {
        for ([_]textmod.Method{ .wcwidth, .unicode, .explicit }) |method| {
            var t = try made(7, 3);
            defer t.deinit();
            t.setMethod(method);
            var buf: [96]u8 = undefined;
            var n: usize = 0;
            while (n < buf.len) {
                const piece: []const u8 = if (random.boolean()) pieces[random.uintLessThan(usize, pieces.len)] else &.{random.int(u8)};
                if (n + piece.len > buf.len) break;
                @memcpy(buf[n..][0..piece.len], piece);
                n += piece.len;
            }
            try t.feed(buf[0..n]);
            try checkInvariants(t.screen());
        }
    }
}
