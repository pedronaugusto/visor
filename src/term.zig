//! A terminal emulator just wide enough to check a renderer.
//!
//! It consumes what `draw` wrote and rebuilds a `Screen` from it, so a
//! program's frame can be asserted on with no terminal anywhere: draw, feed,
//! compare. That comparison is this package's own headline test, run under
//! `std.testing.fuzz` over random grids, and it is public because a program
//! built on this package needs exactly the same check.
//!
//! It is as complete as the renderer's output and no more: the cursor
//! movements, the erases, the scrolls, SGR, OSC 8 and the modes this package
//! writes. A graphics command is recorded rather than drawn, which is what
//! lets the rule that the text pass never deletes a placement be a test.
//!
//! What this file will never be: a terminal emulator for general use. It has
//! no character sets, no tabs stops, no margins, no mouse, no scrollback and
//! no bell. Anything it does not recognise is dropped rather than guessed at.

const std = @import("std");
const morse = @import("morse");

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const textmod = @import("text.zig");
const Screen = @import("screen.zig").Screen;

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Size = geom.Size;
const Style = cellmod.Style;
const Writer = std.Io.Writer;

/// The terminal.
pub const Term = struct {
    /// The allocator `init` was given.
    gpa: Allocator,
    /// The grid the bytes so far have built.
    scr: Screen,
    /// Bytes of a sequence or a cluster that the last `feed` ended in the
    /// middle of.
    pending: std.ArrayList(u8) = .empty,
    /// The style cells are being written in.
    style: Style = .{},
    /// The link cells are being written under.
    link: Link = .none,
    /// Where the next cell goes.
    col: u16 = 0,
    /// The row it goes in.
    row: u16 = 0,
    /// Whether the last write filled the last column, so the next one wraps.
    wrap_pending: bool = false,
    /// Whether writing past the last column wraps, DECAWM.
    autowrap: bool = true,
    /// The first row scrolling is confined to.
    scroll_top: u16 = 0,
    /// The last row scrolling is confined to.
    scroll_bottom: u16,
    /// Every graphics command the bytes carried, in order.
    graphics: std.ArrayList([]const u8) = .empty,
    /// The saved cursor, DECSC.
    saved: ?struct { col: u16, row: u16, style: Style } = null,

    /// A terminal of a size, showing nothing.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Term {
        var scr: Screen = try .init(gpa, size);
        errdefer scr.deinit(gpa);
        return .{
            .gpa = gpa,
            .scr = scr,
            .scroll_bottom = if (size.rows == 0) 0 else size.rows - 1,
        };
    }

    /// Gives the terminal back.
    pub fn deinit(t: *Term) void {
        t.scr.deinit(t.gpa);
        t.pending.deinit(t.gpa);
        for (t.graphics.items) |g| t.gpa.free(g);
        t.graphics.deinit(t.gpa);
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

    /// A new size. Everything on the terminal is lost, as it is on a real
    /// one that reflowed.
    pub fn resize(t: *Term, size: Size) Allocator.Error!void {
        try t.scr.resize(t.gpa, size);
        t.scr.clear();
        t.scroll_top = 0;
        t.scroll_bottom = if (size.rows == 0) 0 else size.rows - 1;
        t.col = 0;
        t.row = 0;
        t.wrap_pending = false;
    }

    /// The bytes a renderer wrote.
    ///
    /// A sequence or a grapheme cut in half by the end of `bytes` is held
    /// until the rest of it arrives, so a caller may hand over whatever a
    /// read gave it.
    pub fn feed(t: *Term, bytes: []const u8) Allocator.Error!void {
        if (t.pending.items.len != 0) {
            try t.pending.appendSlice(t.gpa, bytes);
            const held = try t.pending.toOwnedSlice(t.gpa);
            defer t.gpa.free(held);
            try t.consume(held);
            return;
        }
        try t.consume(bytes);
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
                    try t.pending.appendSlice(t.gpa, bytes[i..]);
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
                if (held != 0) try t.pending.appendSlice(t.gpa, bytes[run_end - held ..]);
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

    /// A run of printable bytes, as grapheme clusters in cells.
    fn printRun(t: *Term, run: []const u8) Allocator.Error!void {
        var it: textmod.Graphemes = .init(run);
        while (it.next()) |g| try t.put(g);
    }

    /// One grapheme cluster into a cell, wrapping and scrolling as a
    /// terminal does.
    fn put(t: *Term, grapheme: []const u8) Allocator.Error!void {
        const cols = t.scr.size.cols;
        if (cols == 0 or t.scr.size.rows == 0) return;
        const w = textmod.graphemeWidth(grapheme, t.scr.method);
        if (w == 0) return;

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
            while (at < cols) : (at += 1) t.scr.writeCell(at, t.row, spacer);
            t.col = 0;
            t.lineFeed();
        }
        try t.scr.write(t.col, t.row, grapheme, t.style, t.link);
        t.col += w;
        if (t.col >= cols) {
            t.col = cols - 1;
            t.wrap_pending = true;
        }
    }

    /// Down one row, scrolling the region when there is nowhere to go.
    fn lineFeed(t: *Term) void {
        if (t.row == t.scroll_bottom) {
            t.scrollRegion(1);
        } else if (t.row + 1 < t.scr.size.rows) {
            t.row += 1;
        }
        t.wrap_pending = false;
    }

    /// Moves the scrolling region's contents, blanking what it vacates with
    /// the current background, the way a terminal does.
    fn scrollRegion(t: *Term, n: i32) void {
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.scroll_top,
            .cols = t.scr.size.cols,
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
        const plain: Style = .{};
        if (std.meta.eql(t.style.bg, plain.bg) and !t.style.reverse) return;
        const distance: u32 = @min(@abs(n), rect.rows);
        const blank: Cell = .blank(.{ .bg = t.style.bg, .reverse = t.style.reverse });
        const first: u16 = if (n > 0)
            @intCast(rect.bottom() - distance)
        else
            rect.row;
        for (0..distance) |k| {
            const row: u16 = @intCast(first + k);
            var col = rect.col;
            while (col < rect.right()) : (col += 1) t.scr.writeCell(col, row, blank);
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
            '[' => t.controlSequence(bytes),
            ']' => t.operatingSystemCommand(bytes),
            '_' => try t.applicationCommand(bytes),
            '7' => blk: {
                t.saved = .{ .col = t.col, .row = t.row, .style = t.style };
                break :blk 2;
            },
            '8' => blk: {
                if (t.saved) |s| {
                    t.col = s.col;
                    t.row = s.row;
                    t.style = s.style;
                    t.wrap_pending = false;
                }
                break :blk 2;
            },
            // `ESC \` on its own is a string terminator with nothing to
            // terminate, and anything else two bytes long is not written by
            // this package.
            else => 2,
        };
    }

    /// `CSI ... final`.
    fn controlSequence(t: *Term, bytes: []const u8) usize {
        var i: usize = 2;
        var private: u8 = 0;
        if (i < bytes.len and bytes[i] >= 0x3c and bytes[i] <= 0x3f) {
            private = bytes[i];
            i += 1;
        }
        const params_start = i;
        while (i < bytes.len and ((bytes[i] >= 0x30 and bytes[i] <= 0x3b) or bytes[i] == ':')) i += 1;
        const params = bytes[params_start..i];
        const intermediate_start = i;
        while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) i += 1;
        const intermediates = bytes[intermediate_start..i];
        if (i >= bytes.len) return 0;
        const final = bytes[i];
        t.dispatch(private, params, intermediates, final);
        return i + 1;
    }

    /// One complete control sequence, acted on.
    fn dispatch(t: *Term, private: u8, params: []const u8, intermediates: []const u8, final: u8) void {
        if (private == '?') {
            t.privateMode(params, final);
            return;
        }
        if (private != 0) return;
        if (intermediates.len == 1 and intermediates[0] == ' ' and final == 'q') {
            t.scr.cursor.shape = @enumFromInt(@as(u8, @intCast(@min(param(params, 0, 0), 6))));
            return;
        }
        if (intermediates.len != 0) return;
        switch (final) {
            'm' => t.selectGraphicRendition(params),
            'H', 'f' => t.moveTo(clamp(param(params, 1, 1) - 1), clamp(param(params, 0, 1) - 1)),
            'A' => t.moveTo(t.col, t.row -| clamp(atLeastOne(params))),
            'B' => t.moveTo(t.col, t.row +| clamp(atLeastOne(params))),
            'C' => t.moveTo(t.col +| clamp(atLeastOne(params)), t.row),
            'D' => t.moveTo(t.col -| clamp(atLeastOne(params)), t.row),
            'E' => t.moveTo(0, t.row +| clamp(atLeastOne(params))),
            'F' => t.moveTo(0, t.row -| clamp(atLeastOne(params))),
            'G', '`' => t.moveTo(clamp(param(params, 0, 1) - 1), t.row),
            'd' => t.moveTo(t.col, clamp(param(params, 0, 1) - 1)),
            'J' => t.eraseScreen(param(params, 0, 0)),
            'K' => t.eraseLine(param(params, 0, 0)),
            'L' => t.insertLines(atLeastOne(params)),
            'M' => t.deleteLines(atLeastOne(params)),
            '@' => t.insertChars(atLeastOne(params)),
            'P' => t.deleteChars(atLeastOne(params)),
            'X' => t.eraseChars(atLeastOne(params)),
            'S' => t.scrollRegion(@intCast(atLeastOne(params))),
            'T' => t.scrollRegion(-@as(i32, @intCast(atLeastOne(params)))),
            'r' => t.setScrollRegion(params),
            else => {},
        }
    }

    /// `CSI ? n h` and `CSI ? n l`: the modes this package switches.
    fn privateMode(t: *Term, params: []const u8, final: u8) void {
        if (final != 'h' and final != 'l') return;
        const on = final == 'h';
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |one| {
            const n = std.fmt.parseInt(u32, one, 10) catch continue;
            switch (n) {
                25 => t.scr.cursor.visible = on,
                7 => t.autowrap = on,
                else => {},
            }
        }
    }

    /// `CSI top ; bottom r`, DECSTBM, which also homes the cursor.
    fn setScrollRegion(t: *Term, params: []const u8) void {
        const rows = t.scr.size.rows;
        if (rows == 0) return;
        const top = param(params, 0, 1);
        const bottom = param(params, 1, rows);
        if (bottom <= top) return;
        t.scroll_top = @intCast(@min(top - 1, rows - 1));
        t.scroll_bottom = @intCast(@min(bottom - 1, rows - 1));
        t.moveTo(0, t.scroll_top);
    }

    /// The cursor, clamped to the grid.
    fn moveTo(t: *Term, col: u16, row: u16) void {
        if (t.scr.size.cols == 0 or t.scr.size.rows == 0) return;
        t.col = @min(col, t.scr.size.cols - 1);
        t.row = @min(row, t.scr.size.rows - 1);
        t.wrap_pending = false;
    }

    //=====================================================================
    // Erasing, inserting and deleting.
    //=====================================================================

    /// The cell an erase leaves behind: a space in the background the
    /// terminal is currently writing in.
    fn erased(t: *const Term) Cell {
        return .blank(.{ .bg = t.style.bg, .reverse = t.style.reverse });
    }

    /// `CSI n J`.
    fn eraseScreen(t: *Term, what: u32) void {
        const size = t.scr.size;
        switch (what) {
            0 => {
                t.eraseRun(t.col, t.row, size.cols - t.col);
                var row = t.row + 1;
                while (row < size.rows) : (row += 1) t.eraseRun(0, row, size.cols);
            },
            1 => {
                var row: u16 = 0;
                while (row < t.row) : (row += 1) t.eraseRun(0, row, size.cols);
                t.eraseRun(0, t.row, t.col + 1);
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
        const cols = t.scr.size.cols;
        switch (what) {
            0 => t.eraseRun(t.col, t.row, cols - t.col),
            1 => t.eraseRun(0, t.row, t.col + 1),
            2 => t.eraseRun(0, t.row, cols),
            else => {},
        }
    }

    /// `CSI n X`, which erases without moving anything.
    fn eraseChars(t: *Term, n: u32) void {
        const cols = t.scr.size.cols;
        t.eraseRun(t.col, t.row, @intCast(@min(n, cols - t.col)));
    }

    /// A run of cells back to blanks.
    fn eraseRun(t: *Term, col: u16, row: u16, count: u16) void {
        const blank = t.erased();
        var i: u16 = 0;
        while (i < count and col + i < t.scr.size.cols) : (i += 1) {
            t.scr.writeCell(col + i, row, blank);
        }
    }

    /// `CSI n L`, inside the scrolling region.
    fn insertLines(t: *Term, n: u32) void {
        if (t.row < t.scroll_top or t.row > t.scroll_bottom) return;
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.row,
            .cols = t.scr.size.cols,
            .rows = t.scroll_bottom - t.row + 1,
        };
        t.scr.scroll(rect, -@as(i32, @intCast(n)));
        t.blankVacated(rect, -@as(i32, @intCast(n)));
    }

    /// `CSI n M`, inside the scrolling region.
    fn deleteLines(t: *Term, n: u32) void {
        if (t.row < t.scroll_top or t.row > t.scroll_bottom) return;
        const rect: geom.Rect = .{
            .col = 0,
            .row = t.row,
            .cols = t.scr.size.cols,
            .rows = t.scroll_bottom - t.row + 1,
        };
        t.scr.scroll(rect, @intCast(n));
        t.blankVacated(rect, @intCast(n));
    }

    /// `CSI n @`: blanks opened at the cursor, the rest of the row pushed
    /// right.
    fn insertChars(t: *Term, n: u32) void {
        const cols = t.scr.size.cols;
        const count: u16 = @intCast(@min(n, cols - t.col));
        var col = cols;
        while (col > t.col + count) {
            col -= 1;
            t.scr.writeCell(col, t.row, t.scr.readCell(col - count, t.row).?);
        }
        t.eraseRun(t.col, t.row, count);
    }

    /// `CSI n P`: cells removed at the cursor, the rest of the row pulled
    /// left.
    fn deleteChars(t: *Term, n: u32) void {
        const cols = t.scr.size.cols;
        const count: u16 = @intCast(@min(n, cols - t.col));
        var col = t.col;
        while (col + count < cols) : (col += 1) {
            t.scr.writeCell(col, t.row, t.scr.readCell(col + count, t.row).?);
        }
        t.eraseRun(cols - count, t.row, count);
    }

    //=====================================================================
    // Styles and links.
    //=====================================================================

    /// `CSI ... m`.
    ///
    /// The parameters are taken as fields separated by semicolons, each of
    /// which may itself carry sub-parameters separated by colons. Both
    /// spellings of an extended colour are read, because both are written:
    /// the foreground and background in semicolons, which every terminal
    /// takes, and the underline colour in colons, which is the only spelling
    /// the terminals that implement it document.
    fn selectGraphicRendition(t: *Term, params: []const u8) void {
        if (params.len == 0) {
            t.style = .{};
            return;
        }
        var fields: [64][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |field| : (count += 1) {
            if (count == fields.len) break;
            fields[count] = field;
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var subs: [8][]const u8 = undefined;
            var sub_count: usize = 0;
            var sub_it = std.mem.splitScalar(u8, fields[i], ':');
            while (sub_it.next()) |sub| : (sub_count += 1) {
                if (sub_count == subs.len) break;
                subs[sub_count] = sub;
            }
            const code = number(subs[0]) orelse continue;
            switch (code) {
                38 => t.style.fg = t.readColor(subs[0..sub_count], fields[0..count], &i) orelse t.style.fg,
                48 => t.style.bg = t.readColor(subs[0..sub_count], fields[0..count], &i) orelse t.style.bg,
                58 => t.style.underline_color =
                    t.readColor(subs[0..sub_count], fields[0..count], &i) orelse t.style.underline_color,
                4 => t.style.underline = if (sub_count >= 2)
                    underlineOf(subs[1])
                else
                    .single,
                else => t.applyAttribute(code),
            }
        }
    }

    /// Every SGR code that is a single attribute or a named colour.
    fn applyAttribute(t: *Term, code: u32) void {
        switch (code) {
            0 => t.style = .{},
            1 => t.style.bold = true,
            2 => t.style.dim = true,
            3 => t.style.italic = true,
            5 => t.style.blink = true,
            7 => t.style.reverse = true,
            8 => t.style.hidden = true,
            9 => t.style.strikethrough = true,
            53 => t.style.overline = true,
            22 => {
                t.style.bold = false;
                t.style.dim = false;
            },
            23 => t.style.italic = false,
            24 => t.style.underline = .none,
            25 => t.style.blink = false,
            27 => t.style.reverse = false,
            28 => t.style.hidden = false,
            29 => t.style.strikethrough = false,
            55 => t.style.overline = false,
            30...37 => t.style.fg = .{ .ansi = @enumFromInt(code - 30) },
            90...97 => t.style.fg = .{ .ansi = @enumFromInt(code - 90 + 8) },
            39 => t.style.fg = .default,
            40...47 => t.style.bg = .{ .ansi = @enumFromInt(code - 40) },
            100...107 => t.style.bg = .{ .ansi = @enumFromInt(code - 100 + 8) },
            49 => t.style.bg = .default,
            59 => t.style.underline_color = .default,
            else => {},
        }
    }

    /// The colour a `38`, `48` or `58` introduces, from its own
    /// sub-parameters when it has them and from the fields after it when it
    /// does not. Advances `i` past whatever it consumed.
    fn readColor(
        _: *Term,
        subs: []const []const u8,
        fields: []const []const u8,
        i: *usize,
    ) ?cellmod.Color {
        if (subs.len >= 2) return colonColor(subs[1..]);
        var at = i.*;
        const kind = number(nextField(fields, &at) orelse return null) orelse return null;
        switch (kind) {
            5 => {
                const n = byte(nextField(fields, &at) orelse return null) orelse return null;
                i.* = at;
                return .{ .palette = n };
            },
            2 => {
                const r = byte(nextField(fields, &at) orelse return null) orelse return null;
                const g = byte(nextField(fields, &at) orelse return null) orelse return null;
                const b = byte(nextField(fields, &at) orelse return null) orelse return null;
                i.* = at;
                return .{ .rgb = .{ .r = r, .g = g, .b = b } };
            },
            else => return null,
        }
    }

    /// `ESC ] ... ST`, of which only OSC 8 changes a cell.
    fn operatingSystemCommand(t: *Term, bytes: []const u8) usize {
        const body = stringBody(bytes, 2) orelse return 0;
        const payload = bytes[2..body.end];
        if (std.mem.startsWith(u8, payload, "8;")) {
            const rest = payload[2..];
            const split = std.mem.indexOfScalar(u8, rest, ';') orelse return body.len;
            const params = rest[0..split];
            const uri = rest[split + 1 ..];
            t.link = if (uri.len == 0)
                .none
            else
                t.scr.link(t.gpa, uri, params) catch .none;
        }
        return body.len;
    }

    /// `ESC _ ... ST`, which is where a graphics command travels. It is
    /// recorded and never drawn: the text pass must be able to be asserted
    /// not to have written one.
    fn applicationCommand(t: *Term, bytes: []const u8) Allocator.Error!usize {
        const body = stringBody(bytes, 2) orelse return 0;
        const payload = try t.gpa.dupe(u8, bytes[2..body.end]);
        errdefer t.gpa.free(payload);
        try t.graphics.append(t.gpa, payload);
        return body.len;
    }

    //=====================================================================
    // Reading the terminal back.
    //=====================================================================

    /// The grid as text, one row a line.
    pub fn dump(t: *const Term, w: *Writer) Writer.Error!void {
        try dumpScreen(&t.scr, w);
    }

    /// The styles as one identifier a cell, with the legend above.
    pub fn dumpStyles(t: *const Term, w: *Writer) Writer.Error!void {
        try dumpScreenStyles(&t.scr, w);
    }

    /// A comparison that names the first cell that differs.
    pub fn expectEqual(want: *const Screen, got: *const Screen) !void {
        return expectScreensEqual(want, got);
    }
};

/// The grid as text, one row a line, a tail written for a wide grapheme's
/// covered column so the line is as wide as the grid.
pub fn dumpScreen(s: *const Screen, w: *Writer) Writer.Error!void {
    var row: u16 = 0;
    while (row < s.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const c = s.cells[s.index(col, row)];
            if (c.isTail()) continue;
            try w.writeAll(s.textOf(&s.cells[s.index(col, row)]));
        }
        try w.writeByte('\n');
    }
}

/// The styles as one identifier a cell, with a legend above naming each one.
///
/// The goldens compare glyphs, and a swap that passes them has proved half a
/// renderer. This is the other half: the same draw writes a second file and
/// a colour that moved fails as loudly as a glyph that did.
pub fn dumpScreenStyles(s: *const Screen, w: *Writer) Writer.Error!void {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var seen: [62]Style = undefined;
    var count: usize = 0;

    // First pass: the legend, in the order the styles first appear.
    for (s.cells) |c| {
        if (indexOfStyle(seen[0..count], c.style()) != null) continue;
        if (count == seen.len) continue;
        seen[count] = c.style();
        count += 1;
    }
    for (seen[0..count], 0..) |style, i| {
        try w.print("# {c} ", .{alphabet[i]});
        try writeStyleName(w, style);
        try w.writeByte('\n');
    }

    var row: u16 = 0;
    while (row < s.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const c = s.cells[s.index(col, row)];
            const i = indexOfStyle(seen[0..count], c.style());
            try w.writeByte(if (i) |n| alphabet[n] else '?');
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
    const plain: Style = .{};
    if (!std.meta.eql(style.underline_color, plain.underline_color)) {
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
}

/// A colour as a name.
fn writeColorName(w: *Writer, c: cellmod.Color) Writer.Error!void {
    switch (c) {
        .default => try w.writeAll("default"),
        .ansi => |a| try w.print("{t}", .{a}),
        .palette => |n| try w.print("palette:{d}", .{n}),
        .rgb => |v| try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ v.r, v.g, v.b }),
    }
}

/// Where a style already is in the legend, or null.
fn indexOfStyle(seen: []const Style, style: Style) ?usize {
    for (seen, 0..) |s, i| if (std.meta.eql(s, style)) return i;
    return null;
}

/// Two screens compared cell by cell, naming the first that differs and
/// printing both grids.
pub fn expectScreensEqual(want: *const Screen, got: *const Screen) !void {
    if (!std.meta.eql(want.size, got.size)) {
        std.debug.print(
            "screen size: want {d}x{d}, have {d}x{d}\n",
            .{ want.size.cols, want.size.rows, got.size.cols, got.size.rows },
        );
        return error.TestExpectedEqual;
    }
    var row: u16 = 0;
    while (row < want.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < want.size.cols) : (col += 1) {
            const a = want.cells[want.index(col, row)];
            const b = got.cells[got.index(col, row)];
            const same_text = std.mem.eql(u8, want.textAt(col, row), got.textAt(col, row));
            const same_link = linksEqual(want, got, a.link, b.link);
            // The kind is not compared, only what the terminal can show: a
            // `spacer_head` and a space are the same cell to it, and only
            // this package knows one was left by a wrap.
            if (same_text and same_link and
                std.meta.eql(a.bits, b.bits) and
                a.width() == b.width() and
                a.isTail() == b.isTail()) continue;
            try reportCell(want, got, col, row);
            return error.TestExpectedEqual;
        }
    }
}

/// Says what differs at one cell, then prints both grids whole.
fn reportCell(want: *const Screen, got: *const Screen, col: u16, row: u16) !void {
    const a = want.cells[want.index(col, row)];
    const b = got.cells[got.index(col, row)];
    std.debug.print("cell {d},{d} differs\n", .{ col, row });
    std.debug.print("  want: \"{s}\" {any} link={any} shape={any}\n", .{
        want.textAt(col, row), a.style(), want.target(a.link), a.shape,
    });
    std.debug.print("  have: \"{s}\" {any} link={any} shape={any}\n", .{
        got.textAt(col, row), b.style(), got.target(b.link), b.shape,
    });
    std.debug.print("--- want ---\n", .{});
    printGrid(want);
    std.debug.print("--- have ---\n", .{});
    printGrid(got);
}

/// The grid on stderr, one row a line, for a failing test to be read from.
fn printGrid(s: *const Screen) void {
    var row: u16 = 0;
    while (row < s.size.rows) : (row += 1) {
        std.debug.print("|", .{});
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            if (s.cells[s.index(col, row)].isTail()) continue;
            std.debug.print("{s}", .{s.textAt(col, row)});
        }
        std.debug.print("|\n", .{});
    }
}

/// Whether two cells' links name the same target, which is not the same as
/// holding the same index: the two screens interned in different orders.
fn linksEqual(want: *const Screen, got: *const Screen, a: Link, b: Link) bool {
    const ta = want.target(a);
    const tb = got.target(b);
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

/// Where a run of printable bytes ends.
fn runEnd(bytes: []const u8, from: usize) usize {
    var i = from;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] != 0x7f) i += 1;
    return i;
}

/// The end of an `ST`- or `BEL`-terminated string, or null when it has not
/// arrived.
fn stringBody(bytes: []const u8, from: usize) ?struct { end: usize, len: usize } {
    var i = from;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x07) return .{ .end = i, .len = i + 1 };
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
            return .{ .end = i, .len = i + 2 };
        }
    }
    return null;
}

/// The `n`th parameter, or `fallback` when it is missing or empty.
fn param(params: []const u8, n: usize, fallback: u32) u32 {
    var it = std.mem.splitScalar(u8, params, ';');
    var i: usize = 0;
    while (it.next()) |one| : (i += 1) {
        if (i != n) continue;
        const head = std.mem.sliceTo(one, ':');
        if (head.len == 0) return fallback;
        return std.fmt.parseInt(u32, head, 10) catch fallback;
    }
    return fallback;
}

/// A parameter as a coordinate, saturating rather than wrapping: a number
/// too large for the grid is clamped by `moveTo` anyway.
fn clamp(n: u32) u16 {
    return std.math.cast(u16, n) orelse std.math.maxInt(u16);
}

/// The first parameter, never zero: the movement sequences all treat a
/// missing or zero count as one.
fn atLeastOne(params: []const u8) u32 {
    return @max(param(params, 0, 1), 1);
}

/// The underline style a `4:n` names.
fn underlineOf(sub: []const u8) cellmod.Underline {
    const n = number(sub) orelse return .single;
    return if (n <= 5) @enumFromInt(@as(u8, @intCast(n))) else .single;
}

/// A decimal field, with an empty one meaning zero, as SGR spells it.
fn number(field: []const u8) ?u32 {
    if (field.len == 0) return 0;
    return std.fmt.parseInt(u32, field, 10) catch null;
}

/// A decimal field that has to fit in a byte.
fn byte(field: []const u8) ?u8 {
    const n = number(field) orelse return null;
    return std.math.cast(u8, n);
}

/// The field after `at`, advancing it.
fn nextField(fields: []const []const u8, at: *usize) ?[]const u8 {
    if (at.* + 1 >= fields.len) return null;
    at.* += 1;
    return fields[at.*];
}

/// The colon spelling of an extended colour: `5:n`, or `2:<space>:r:g:b`
/// with the colour space identifier usually left empty.
fn colonColor(subs: []const []const u8) ?cellmod.Color {
    if (subs.len == 0) return null;
    const kind = number(subs[0]) orelse return null;
    switch (kind) {
        5 => {
            if (subs.len < 2) return null;
            return .{ .palette = byte(subs[1]) orelse return null };
        },
        2 => {
            const rest = if (subs.len >= 5) subs[2..] else subs[1..];
            if (rest.len < 3) return null;
            return .{ .rgb = .{
                .r = byte(rest[0]) orelse return null,
                .g = byte(rest[1]) orelse return null,
                .b = byte(rest[2]) orelse return null,
            } };
        },
        else => return null,
    }
}
