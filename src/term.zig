//! A terminal emulator just wide enough to check a renderer.
//!
//! It consumes what `draw` wrote and rebuilds a `Screen` from it, so a
//! program's frame can be asserted on with no terminal anywhere: draw, feed,
//! compare. That comparison is this package's own headline test, run under
//! `std.testing.fuzz` over random grids, and it is public because a program
//! built on this package needs exactly the same check.
//!
//! It is as complete as the renderer's output and no more: the cursor
//! movements, the erases, the scrolls, the repeat, SGR, OSC 8, the width a
//! cluster is told through OSC 66, and the modes this package writes. A graphics command is recorded rather than drawn, which is what
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
const Color = cellmod.Color;
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
    /// The last codepoint printed, which is what `REP` repeats.
    previous: ?u21 = null,

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
        try t.scr.resize(t.gpa, size);
        t.scroll_top = 0;
        t.scroll_bottom = if (size.rows == 0) 0 else size.rows - 1;
        t.col = @min(t.col, if (size.cols == 0) 0 else size.cols - 1);
        t.row = @min(t.row, if (size.rows == 0) 0 else size.rows - 1);
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
    /// the one this terminal would measure.
    fn putAs(t: *Term, grapheme: []const u8, told: ?u2) Allocator.Error!void {
        const cols = t.scr.size.cols;
        if (cols == 0 or t.scr.size.rows == 0) return;
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
            while (at < cols) : (at += 1) t.scr.writeOwnedCell(at, t.row, spacer);
            t.col = 0;
            t.lineFeed();
        }
        if (told) |_| {
            const text = try t.scr.intern(t.gpa, grapheme);
            t.scr.writeOwnedCell(t.col, t.row, .init(.{
                .text = text,
                .style = t.style,
                .link = t.link,
                .shape = .{ .kind = if (w == 2) .wide else .narrow, .drift = textmod.disagrees(grapheme) },
            }));
        } else {
            try t.scr.write(t.col, t.row, grapheme, t.style, t.link);
        }
        t.previous = lastCodepoint(grapheme);
        t.col += w;
        if (t.col >= cols) {
            t.col = cols - 1;
            t.wrap_pending = true;
        }
    }

    /// `CSI n b`, REP: the last codepoint printed, printed again `n` times,
    /// wrapping and scrolling exactly as printing it would.
    fn repeat(t: *Term, n: u32) Allocator.Error!void {
        const cp = t.previous orelse return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        var i: u32 = 0;
        while (i < n) : (i += 1) try t.put(buf[0..len]);
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
            while (col < rect.right()) : (col += 1) t.scr.writeOwnedCell(col, row, blank);
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
    fn controlSequence(t: *Term, bytes: []const u8) Allocator.Error!usize {
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
        try t.dispatch(private, params, intermediates, final);
        return i + 1;
    }

    /// One complete control sequence, acted on.
    fn dispatch(t: *Term, private: u8, params: []const u8, intermediates: []const u8, final: u8) Allocator.Error!void {
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
            'S' => t.scrollRegion(t.scrollCount(params)),
            'T' => t.scrollRegion(-t.scrollCount(params)),
            'r' => t.setScrollRegion(params),
            'b' => try t.repeat(atLeastOne(params)),
            else => {},
        }
    }

    fn scrollCount(t: *const Term, params: []const u8) i32 {
        const rows: u32 = t.scroll_bottom - t.scroll_top + 1;
        return @intCast(@min(atLeastOne(params), rows));
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
            t.scr.writeOwnedCell(col + i, row, blank);
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
            t.scr.writeOwnedCell(col, t.row, t.scr.readCell(col - count, t.row).?);
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
            t.scr.writeOwnedCell(col, t.row, t.scr.readCell(col + count, t.row).?);
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
            30...37 => t.style.fg = .ansi(@enumFromInt(code - 30)),
            90...97 => t.style.fg = .ansi(@enumFromInt(code - 90 + 8)),
            39 => t.style.fg = .default,
            40...47 => t.style.bg = .ansi(@enumFromInt(code - 40)),
            100...107 => t.style.bg = .ansi(@enumFromInt(code - 100 + 8)),
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
                return .palette(n);
            },
            2 => {
                const r = byte(nextField(fields, &at) orelse return null) orelse return null;
                const g = byte(nextField(fields, &at) orelse return null) orelse return null;
                const b = byte(nextField(fields, &at) orelse return null) orelse return null;
                i.* = at;
                return .rgb(r, g, b);
            },
            else => return null,
        }
    }

    /// `ESC ] ... ST`: OSC 8 changes what a cell links to, and OSC 66 prints
    /// text at a width it was told. Nothing else changes a cell.
    fn operatingSystemCommand(t: *Term, bytes: []const u8) Allocator.Error!usize {
        const body = stringBody(bytes, 2) orelse return 0;
        const payload = bytes[2..body.end];
        if (std.mem.startsWith(u8, payload, "66;")) {
            try t.sizedText(payload[3..]);
            return body.len;
        }
        if (std.mem.startsWith(u8, payload, "8;")) {
            const rest = payload[2..];
            const split = std.mem.indexOfScalar(u8, rest, ';') orelse return body.len;
            const params = rest[0..split];
            const uri = rest[split + 1 ..];
            t.link = if (uri.len == 0)
                .none
            else
                try t.scr.link(t.gpa, uri, params);
        }
        return body.len;
    }

    /// The body of an OSC 66: `key=value:key=value ; text`. The `w` key is
    /// the width every cluster in the text takes and `s` the scale it is
    /// drawn at; the others are read and not acted on, because the renderer
    /// does not write them.
    fn sizedText(t: *Term, body: []const u8) Allocator.Error!void {
        const split = std.mem.indexOfScalar(u8, body, ';') orelse return;
        var told: ?u2 = null;
        var scale: u3 = 0;
        var keys = std.mem.splitScalar(u8, body[0..split], ':');
        while (keys.next()) |pair| {
            if (pair.len < 3 or pair[1] != '=') continue;
            const value = std.fmt.parseInt(u8, pair[2..], 10) catch continue;
            switch (pair[0]) {
                'w' => told = switch (value) {
                    1 => 1,
                    2 => 2,
                    else => null,
                },
                's' => scale = @intCast(@min(value, 7)),
                else => {},
            }
        }
        var it: textmod.Graphemes = .init(body[split + 1 ..]);
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
    fn putScaled(t: *Term, grapheme: []const u8, told: ?u2, scale: u3) Allocator.Error!void {
        const cols = t.scr.size.cols;
        const rows = t.scr.size.rows;
        if (cols == 0 or rows == 0) return;
        const w: u16 = told orelse textmod.graphemeWidth(grapheme, t.scr.method);
        if (w == 0 or w > 2) return;
        if (t.wrap_pending) {
            if (!t.autowrap) return;
            t.col = 0;
            t.lineFeed();
        }
        const span: u32 = @as(u32, w) * scale;
        if (t.col + span > cols or t.row + scale > rows) return;
        const text = try t.scr.intern(t.gpa, grapheme);
        t.scr.writeOwnedCell(t.col, t.row, .init(.{
            .text = text,
            .style = t.style,
            .link = t.link,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                .drift = textmod.disagrees(grapheme),
                .scale = scale,
            },
        }));
        t.previous = lastCodepoint(grapheme);
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
    pub fn dumpStyles(t: *const Term, w: *Writer) (Writer.Error || std.mem.Allocator.Error)!void {
        try dumpScreenStyles(&t.scr, w);
    }

    /// A comparison that names the first cell that differs.
    pub fn expectEqual(want: *const Screen, got: *const Screen) !void {
        return expectScreensEqual(want, got);
    }
};

/// The grid as text, one row a line, each cluster once: a wide cluster's
/// covered column writes nothing (`dumpScreenWith` writes a filler there).
pub fn dumpScreen(s: *const Screen, w: *Writer) Writer.Error!void {
    return dumpScreenWith(s, w, .{});
}

/// How `dumpScreenWith` writes a grid as text.
pub const DumpOptions = struct {
    /// What a wide cluster's covered column is written as. Nothing, the
    /// default, holds each cluster once; a space makes every line as many
    /// characters as the grid has columns, for a program that reads a column
    /// back by its position in the line.
    tail: []const u8 = "",
};

/// The grid as text, one row a line, a wide cluster's covered column
/// written as `opts.tail`.
pub fn dumpScreenWith(s: *const Screen, w: *Writer, opts: DumpOptions) Writer.Error!void {
    var row: u16 = 0;
    while (row < s.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const c = &s.cells[s.index(col, row)];
            try w.writeAll(if (c.isTail()) opts.tail else s.textOf(c));
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
///   ` reverse`, ` hidden`, ` strike`, ` overline`, and last ` link=<uri>`
///   for a cell carrying an OSC 8 link. The link is part of what makes a
///   style distinct; its parameters are not printed.
/// - A colour is `default`, one of the sixteen names, `palette:<n>`, or
///   `#rrggbb` in lower case.
/// - Ids are `0-9a-zA-Z`, one character a cell when the screen has 62 styles
///   or fewer. With more, every id is two characters, most significant first,
///   in the legend and in the grid, so a row of the grid is twice the width.
/// - The grid is one line a row and one id a column. The column a wide
///   grapheme covers prints the id of the cell it continues.
/// - Every line ends in a newline, with no blank line after the last.
///
/// Allocates, on the screen's own allocator, what it needs to tell any
/// number of styles apart; nothing survives the call.
pub fn dumpScreenStyles(s: *const Screen, w: *Writer) (Writer.Error || std.mem.Allocator.Error)!void {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each cell's legend line, keyed by the line itself: two cells whose
    // lines read the same are the same style to anyone reading the dump.
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    const ids = try arena.alloc(u32, s.cells.len);
    var key: std.Io.Writer.Allocating = .init(arena);
    for (s.cells, 0..) |cell, i| {
        const col: u16 = @intCast(i % s.size.cols);
        const row: u16 = @intCast(i / s.size.cols);
        // A covered column speaks for the grapheme that covers it.
        const source = if (s.headOf(col, row)) |head| s.cells[s.index(head.col, head.row)] else cell;
        key.clearRetainingCapacity();
        writeStyleName(&key.writer, source.style) catch return error.OutOfMemory;
        if (s.target(source.link)) |target| {
            key.writer.print(" link={s}", .{target.uri}) catch return error.OutOfMemory;
        }
        const found = try seen.getOrPut(arena, key.written());
        if (!found.found_existing) found.key_ptr.* = try arena.dupe(u8, key.written());
        ids[i] = @intCast(found.index);
    }

    const two = seen.count() > alphabet.len;
    const Id = struct {
        fn write(out: *Writer, id: u32, wide: bool) Writer.Error!void {
            if (wide) try out.writeByte(alphabet[id / alphabet.len]);
            try out.writeByte(alphabet[id % alphabet.len]);
        }
    };
    for (seen.keys(), 0..) |line, i| {
        try w.writeAll("# ");
        try Id.write(w, @intCast(i), two);
        try w.writeByte(' ');
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    var row: u16 = 0;
    while (row < s.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            try Id.write(w, ids[s.index(col, row)], two);
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
    return std.mem.eql(u8, std.mem.asBytes(&ca), std.mem.asBytes(&cb));
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
    const where = firstDifference(want, got) orelse return;
    try reportCell(want, got, where.col, where.row);
    return error.TestExpectedEqual;
}

/// The first cell two screens disagree about, read by column, or null.
///
/// The kind is not compared, only what the terminal can show: a spacer left
/// by a wrap and a space someone asked for are the same cell to it, and only
/// this package knows the difference.
pub fn firstDifference(want: *const Screen, got: *const Screen) ?geom.Point {
    if (!std.meta.eql(want.size, got.size)) return .{ .col = 0, .row = 0 };
    var row: u16 = 0;
    while (row < want.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < want.size.cols) : (col += 1) {
            const a = want.cells[want.index(col, row)];
            const b = got.cells[got.index(col, row)];
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

/// Says what differs at one cell, then prints both grids whole.
fn reportCell(want: *const Screen, got: *const Screen, col: u16, row: u16) !void {
    const a = want.cells[want.index(col, row)];
    const b = got.cells[got.index(col, row)];
    std.debug.print("cell {d},{d} differs\n", .{ col, row });
    std.debug.print("  want: \"{s}\" {any} link={any} shape={any}\n", .{
        want.textAt(col, row), a.style, want.target(a.link), a.shape,
    });
    std.debug.print("  have: \"{s}\" {any} link={any} shape={any}\n", .{
        got.textAt(col, row), b.style, got.target(b.link), b.shape,
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

/// The last codepoint of a grapheme, or null when the bytes are not UTF-8.
fn lastCodepoint(grapheme: []const u8) ?u21 {
    var last: ?u21 = null;
    var it: std.unicode.Utf8Iterator = .{ .bytes = grapheme, .i = 0 };
    while (it.nextCodepoint()) |cp| last = cp;
    return last;
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
            return .palette(byte(subs[1]) orelse return null);
        },
        2 => {
            const rest = if (subs.len >= 5) subs[2..] else subs[1..];
            if (rest.len < 3) return null;
            return .rgb(
                byte(rest[0]) orelse return null,
                byte(rest[1]) orelse return null,
                byte(rest[2]) orelse return null,
            );
        },
        else => return null,
    }
}

const testing = std.testing;

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
    while (col < t.scr.size.cols) : (col += 1) {
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
    try testing.expectEqual(@as(u16, 4), t.row);
    try t.feed("\x1b[2A");
    try testing.expectEqual(@as(u16, 2), t.row);
    try t.feed("\x1b[3B");
    try testing.expectEqual(@as(u16, 5), t.row);
    try t.feed("\x1b[4C");
    try testing.expectEqual(@as(u16, 8), t.col);
    try testing.expectEqual(@as(u16, 5), t.row);
    try t.feed("\x1b[2D");
    try testing.expectEqual(@as(u16, 6), t.col);
    try t.feed("\x1b[9G");
    try testing.expectEqual(@as(u16, 8), t.col);
    try t.feed("\x1b[3d");
    try testing.expectEqual(@as(u16, 2), t.row);
    try t.feed("\r");
    try testing.expectEqual(@as(u16, 0), t.col);
    try t.feed("\x1b[2E");
    try testing.expectEqual(@as(u16, 4), t.row);
    try t.feed("\x1b[1F");
    try testing.expectEqual(@as(u16, 3), t.row);
    try t.feed("ab\x08");
    try testing.expectEqual(@as(u16, 1), t.col);
}

test "a movement past the edge is clamped rather than wrapped" {
    var t = try made(4, 3);
    defer t.deinit();
    try t.feed("\x1b[99;99H");
    try testing.expectEqual(@as(u16, 3), t.col);
    try testing.expectEqual(@as(u16, 2), t.row);
    try t.feed("\x1b[99A\x1b[99D");
    try testing.expectEqual(@as(u16, 0), t.col);
    try testing.expectEqual(@as(u16, 0), t.row);
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
        try t.feed(try std.fmt.bufPrint(&buf, "{d};1H", .{r + 1}));
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
    try testing.expectError(error.OutOfMemory, t.feed("\x1b]8;id=7;https://ziglang.org\x1b\\"));
    t.gpa = testing.allocator;
    t.scr.gpa = testing.allocator;
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
}

test "a graphics command is recorded and draws nothing" {
    var t = try made(4, 1);
    defer t.deinit();
    try t.feed("ab\x1b_Ga=p,i=1,p=1\x1b\\c");
    try testing.expectEqual(@as(usize, 1), t.graphics.items.len);
    try testing.expectEqualStrings("Ga=p,i=1,p=1", t.graphics.items[0]);
    try testing.expectEqualStrings("c", textAt(&t, 2, 0));
}

test "a sequence split across two feeds is held until the rest arrives" {
    var t = try made(8, 2);
    defer t.deinit();
    try t.feed("\x1b[2;");
    try testing.expectEqual(@as(u16, 0), t.row);
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

test "a repeat after a cluster repeats its last codepoint, as a terminal does" {
    var t = try made(6, 1);
    defer t.deinit();
    try t.feed("e\u{301}\x1b[2b");
    try testing.expectEqualStrings("e\u{301}", textAt(&t, 0, 0));
    try testing.expectEqual(@as(?u21, 0x301), t.previous);
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
    defer sc.deinit(testing.allocator);
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
    };
    try sc.write(0, 0, "a", everything, .none);
    const zig = try sc.link(testing.allocator, "https://ziglang.org", "id=1");
    const other = try sc.link(testing.allocator, "https://ziglang.org", "id=2");
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
        \\# 0 fg=palette:208 bg=#1e1e2e ul=curly ulc=bright_red bold dim italic blink reverse hidden strike overline
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
    defer sc.deinit(testing.allocator);
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
    try testing.expect(std.mem.indexOf(u8, out.written(), "# 10 fg=#3e0000 bg=default\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "# 0Z fg=#3d0000 bg=default\n") != null);
    // And the grid's first row is the first ten, two characters each.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n00010203040506070809\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "?") == null);
}

test "comparing two screens names the first cell that differs" {
    var a: Screen = try .init(testing.allocator, .{ .cols = 3, .rows = 2 });
    defer a.deinit(testing.allocator);
    var b: Screen = try .init(testing.allocator, .{ .cols = 3, .rows = 2 });
    defer b.deinit(testing.allocator);
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
    defer screen.deinit(testing.allocator);
    screen.method = .unicode;
    try screen.write(0, 0, "a", .{ .fg = .ansi(.red), .bold = true }, .none);
    try screen.write(1, 0, "b", .{ .fg = .ansi(.bright_red), .bg = .palette(200) }, .none);
    try screen.write(2, 0, "\u{4E2D}", .{ .fg = .rgb(255, 16, 0), .underline = .curly, .underline_color = .palette(3) }, .none);
    try screen.write(4, 0, "l", .{}, try screen.link(testing.allocator, "https://example.com", "id=1"));
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
    try dumpScreen(&screen, &glyphs.writer);
    try testing.expectEqualStrings("ab\u{4E2D}l \nr     \n", glyphs.written());

    // and with a filler for the covered column, a line a column a character
    glyphs.clearRetainingCapacity();
    try dumpScreenWith(&screen, &glyphs.writer, .{ .tail = " " });
    try testing.expectEqualStrings("ab\u{4E2D} l \nr     \n", glyphs.written());
}

test "past sixty-two styles the ids run 00 to 0Z and then 10, in order of first appearance" {
    var screen: Screen = try .init(testing.allocator, .{ .cols = 64, .rows = 1 });
    defer screen.deinit(testing.allocator);
    for (0..64) |c| screen.writeOwnedCell(@intCast(c), 0, .blank(.{ .fg = .palette(@intCast(c + 16)) }));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dumpScreenStyles(&screen, &out.writer);
    const got = out.written();
    try testing.expect(std.mem.startsWith(u8, got, "# 00 fg=palette:16 bg=default\n"));
    try testing.expect(std.mem.indexOf(u8, got, "\n# 10 fg=palette:78 bg=default\n# 11 fg=palette:79 bg=default\n") != null);
    try testing.expect(std.mem.endsWith(u8, got, "\n000102030405060708090a0b0c0d0e0f0g0h0i0j0k0l0m0n0o0p0q0r0s0t0u0v0w0x0y0z0A0B0C0D0E0F0G0H0I0J0K0L0M0N0O0P0Q0R0S0T0U0V0W0X0Y0Z1011\n"));
}
