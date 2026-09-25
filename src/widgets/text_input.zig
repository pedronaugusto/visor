//! Text being typed: laid out as rows, with the cursor as a place in them.
//!
//! The arithmetic is the whole of it and is public, because the program that
//! draws the text is also the one that moves the cursor up a row or to the
//! end of one, and the two have to agree on where every row breaks. So the
//! layout is a set of functions of the text, the width and the width method,
//! and `draw` is those functions and a few writes.
//!
//! A row is a byte range of the text. Rows break at a newline, and before a
//! word that would cross the width; a word wider than the row is cut between
//! clusters. Every byte belongs to exactly one row — the spaces a break
//! falls after and the newline a row ends on included — so a cursor anywhere
//! in the text has a row and a column. That is why this is not `visor.wrap`,
//! which swallows the spaces at a break.
//!
//! What this file will never hold: key handling. Which key moves the cursor
//! where is the program's; this says where "up a row" lands.

const std = @import("std");
const visor = @import("visor");

const Method = visor.Method;
const Style = visor.Style;
const Window = visor.Window;

/// Text being typed, and where the cursor is in it.
pub const TextInput = struct {
    /// The text.
    text: []const u8,
    /// Where the cursor is, as a byte offset into `text`. Clamped to its end.
    cursor: usize = 0,
    /// The style the text draws in.
    style: Style = .{},
    /// Whether the terminal's cursor is put at the text cursor. A program
    /// that draws a caret of its own leaves it off and asks `place` where.
    show_cursor: bool = true,

    /// One row: the bytes `text[from..to]`, and whether it ends on a newline
    /// the text carries, which belongs to the row but is not drawn.
    pub const Row = struct {
        /// Where the row starts.
        from: usize,
        /// Where its drawn bytes end.
        to: usize,
        /// Whether a newline follows `to` and ends the row.
        hard: bool = false,
    };

    /// A place in the layout: a row, and a column in cells.
    pub const Place = struct {
        /// Which row.
        row: usize,
        /// Which column of it, in cells.
        col: usize,
    };

    /// What a text input remembers between frames: the first row shown.
    pub const State = struct {
        /// The first row drawn. `draw` moves it to keep the cursor's row on
        /// screen.
        first: usize = 0,
    };

    /// The rows of a text at a width, one at a time. Never empty: an empty
    /// text is one empty row.
    pub const Rows = struct {
        text: []const u8,
        cols: u16,
        method: Method,
        at: usize = 0,
        done: bool = false,

        /// The next row, or null after the last.
        pub fn next(r: *Rows) ?Row {
            if (r.done) return null;
            const start = r.at;
            var used: u32 = 0;
            var last_space: ?usize = null;
            var it: visor.Graphemes = .init(r.text[start..]);
            while (it.nextAt()) |found| {
                const i = start + found.start;
                const g = found.bytes;
                // A newline is one cluster, or two when a carriage return
                // came before it; either ends the row and belongs to it.
                if (g[g.len - 1] == '\n') {
                    r.at = i + g.len;
                    return .{ .from = start, .to = i, .hard = true };
                }
                const w = visor.graphemeWidth(g, r.method);
                // A cluster wider than the whole row still takes a row: the
                // alternative is a row that never ends.
                if (used != 0 and used + w > r.cols) {
                    const brk = if (last_space) |sp| sp + 1 else i;
                    r.at = brk;
                    return .{ .from = start, .to = brk };
                }
                if (g.len == 1 and g[0] == ' ') last_space = i;
                used += w;
            }
            r.done = true;
            r.at = r.text.len;
            return .{ .from = start, .to = r.text.len };
        }
    };

    /// The rows of `text` at `cols` cells, measured by `method`.
    pub fn rows(text: []const u8, cols: u16, method: Method) Rows {
        return .{ .text = text, .cols = @max(cols, 1), .method = method };
    }

    /// How many rows `text` takes at `cols` cells.
    pub fn rowCount(text: []const u8, cols: u16, method: Method) usize {
        var it = rows(text, cols, method);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Where a byte offset stands: its row, and the cell column in it. A
    /// cursor at a soft break belongs to the start of the next row; one at a
    /// newline, to the end of the row the newline ends.
    pub fn place(text: []const u8, cols: u16, method: Method, cursor: usize) Place {
        const c = @min(cursor, text.len);
        var it = rows(text, cols, method);
        var row: usize = 0;
        var current = it.next().?;
        while (true) : (row += 1) {
            // A row owns its bytes up to where the next one starts: its
            // newline, when it ends on one, and nothing when it ends on a
            // soft break, whose place is the next row's start.
            const following = it.next();
            const owned_end = if (following) |f| f.from else text.len + 1;
            if (c < owned_end) {
                return .{ .row = row, .col = visor.width(text[current.from..@min(c, current.to)], method) };
            }
            current = following.?;
        }
    }

    /// The byte offset at a row and a column: the cluster there, or the
    /// row's end when the row is shorter. A row past the last is the last.
    pub fn at(text: []const u8, cols: u16, method: Method, row: usize, col: usize) usize {
        var it = rows(text, cols, method);
        var r = it.next().?;
        var n: usize = 0;
        while (n < row) : (n += 1) r = it.next() orelse break;
        var x: usize = 0;
        var g: visor.Graphemes = .init(text[r.from..r.to]);
        while (g.nextAt()) |found| {
            const w = visor.graphemeWidth(found.bytes, method);
            // The cluster covering the column, or the first to start at it:
            // a cluster that takes no columns is somewhere a cursor can be.
            if (x + w > col or x >= col) return r.from + found.start;
            x += w;
        }
        return r.to;
    }

    /// The start of the cluster before `cursor`.
    pub fn prev(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        if (c == 0) return 0;
        // Clusters never cross a newline, so the search starts at the line.
        const from = lineStart(text, c - 1);
        var g: visor.Graphemes = .init(text[from..c]);
        var last: usize = from;
        while (g.nextAt()) |found| last = from + found.start;
        return last;
    }

    /// The end of the cluster at `cursor`.
    pub fn next(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        var g: visor.Graphemes = .init(text[c..]);
        const found = g.next() orelse return text.len;
        return c + found.len;
    }

    /// The start of the word before `cursor`: spaces and newlines skipped,
    /// then the word. Where erasing a word back from the cursor stops.
    pub fn wordStart(text: []const u8, cursor: usize) usize {
        var i = @min(cursor, text.len);
        while (i > 0 and isSpace(text[i - 1])) i -= 1;
        while (i > 0 and !isSpace(text[i - 1])) i -= 1;
        return i;
    }

    /// The start of the line the cursor is on, just after the newline
    /// before it.
    pub fn lineStart(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        return if (std.mem.lastIndexOfScalar(u8, text[0..c], '\n')) |nl| nl + 1 else 0;
    }

    /// The end of the line the cursor is on, just before the next newline
    /// and the carriage return that may come with it.
    pub fn lineEnd(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        const nl = std.mem.indexOfScalarPos(u8, text, c, '\n') orelse return text.len;
        return if (nl > c and text[nl - 1] == '\r') nl - 1 else nl;
    }

    fn isSpace(b: u8) bool {
        return b == ' ' or b == '\n' or b == '\r';
    }

    /// Draws as many rows as the window has, moving `state.first` so the
    /// cursor's row is among them, and puts the terminal's cursor at the
    /// text cursor when `show_cursor` is on.
    pub fn draw(t: TextInput, win: Window, state: *State) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const method = win.screen.method;
        const cols = win.cols();
        const height: usize = win.rows();
        const total = rowCount(t.text, cols, method);
        const cursor = place(t.text, cols, method, t.cursor);

        if (cursor.row < state.first) state.first = cursor.row;
        if (cursor.row >= state.first + height) state.first = cursor.row + 1 - height;
        // Text that shrank does not leave the view scrolled past its end.
        state.first = @min(state.first, total -| height);

        var it = rows(t.text, cols, method);
        var n: usize = 0;
        while (it.next()) |r| : (n += 1) {
            if (n < state.first) continue;
            const y = n - state.first;
            if (y >= height) break;
            _ = try win.printSegment(
                .{ .text = t.text[r.from..r.to], .style = t.style },
                .{ .row = @intCast(y), .wrap = .none },
            );
        }
        if (t.show_cursor) {
            win.showCursor(@intCast(@min(cursor.col, cols -| 1)), @intCast(cursor.row - state.first));
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

fn allRows(text: []const u8, cols: u16) ![]TextInput.Row {
    var list: std.ArrayList(TextInput.Row) = .empty;
    var it = TextInput.rows(text, cols, .unicode);
    while (it.next()) |r| try list.append(testing.allocator, r);
    return list.toOwnedSlice(testing.allocator);
}

test "rows break at newlines and before a word that would cross the width" {
    const text = "fix the bay filter\nthen the header of the crew bay please";
    const all = try allRows(text, 16);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqualStrings("fix the bay ", text[all[0].from..all[0].to]);
    try testing.expectEqualStrings("filter", text[all[1].from..all[1].to]);
    try testing.expect(all[1].hard);
    try testing.expectEqualStrings("then the header ", text[all[2].from..all[2].to]);
    try testing.expectEqualStrings("of the crew bay ", text[all[3].from..all[3].to]);
    try testing.expectEqualStrings("please", text[all[4].from..all[4].to]);
    // Every byte belongs to one row, in order.
    var seen: usize = 0;
    for (all) |r| {
        try testing.expectEqual(seen, r.from);
        seen = if (r.hard) r.to + 1 else r.to;
    }
    try testing.expectEqual(text.len, seen);

    // An empty text is one empty row; a word wider than the row is cut.
    try testing.expectEqual(@as(usize, 1), TextInput.rowCount("", 10, .unicode));
    const cut = try allRows("abcdefghijkl", 5);
    defer testing.allocator.free(cut);
    try testing.expectEqual(@as(usize, 3), cut.len);
    try testing.expectEqualStrings("fghij", "abcdefghijkl"[cut[1].from..cut[1].to]);
}

test "a wide cluster is two columns, and never splits or stalls a row" {
    const text = "ab\u{4e2d}\u{6587}cd";
    const two = try allRows(text, 3);
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("ab", text[two[0].from..two[0].to]);
    try testing.expectEqualStrings("\u{4e2d}", text[two[1].from..two[1].to]);
    // A row one column wide still takes the wide cluster rather than
    // looping on an empty row.
    try testing.expectEqual(@as(usize, 6), TextInput.rowCount(text, 1, .unicode));
    // A family emoji is one cluster of two columns, not five codepoints.
    const family = "\u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 2 }, TextInput.place(family, 10, .unicode, family.len));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(family, family.len));
    try testing.expectEqual(family.len, TextInput.next(family, 0));
}

test "the cursor has a row and a column, and a column has a byte" {
    const text = "one two three\nfour";
    // "one two " · "three" (hard) · "four"
    try testing.expectEqual(@as(usize, 3), TextInput.rowCount(text, 8, .unicode));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 4 }, TextInput.place(text, 8, .unicode, 4));
    // At the soft break the cursor stands at the next row's start.
    try testing.expectEqual(TextInput.Place{ .row = 1, .col = 0 }, TextInput.place(text, 8, .unicode, 8));
    // At a hard break's newline it stands at the end of its row.
    try testing.expectEqual(TextInput.Place{ .row = 1, .col = 5 }, TextInput.place(text, 8, .unicode, 13));
    try testing.expectEqual(TextInput.Place{ .row = 2, .col = 4 }, TextInput.place(text, 8, .unicode, text.len));
    try testing.expectEqual(@as(usize, 4), TextInput.at(text, 8, .unicode, 0, 4));
    try testing.expectEqual(@as(usize, 13), TextInput.at(text, 8, .unicode, 1, 9));
    try testing.expectEqual(@as(usize, 14), TextInput.at(text, 8, .unicode, 2, 0));
    try testing.expectEqual(@as(usize, 18), TextInput.at(text, 8, .unicode, 9, 9));
    // Steps, words, lines.
    try testing.expectEqual(@as(usize, 3), TextInput.prev(text, 4));
    try testing.expectEqual(@as(usize, 5), TextInput.next(text, 4));
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(text, 7));
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(text, 8));
    try testing.expectEqual(@as(usize, 14), TextInput.lineStart(text, 16));
    try testing.expectEqual(@as(usize, 13), TextInput.lineEnd(text, 3));
    // A step back over a newline lands on it, and at the start stays.
    try testing.expectEqual(@as(usize, 13), TextInput.prev(text, 14));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(text, 0));
    try testing.expectEqual(text.len, TextInput.next(text, text.len));
}

test "a combining mark moves with the letter it sits on" {
    const text = "e\u{301}x";
    try testing.expectEqual(@as(usize, 3), TextInput.next(text, 0));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(text, 3));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 1 }, TextInput.place(text, 10, .unicode, 3));
}

test "a cluster that takes no columns is still a place the cursor can be" {
    const text = "a\tb";
    const p = TextInput.place(text, 8, .unicode, 1);
    try testing.expectEqual(@as(usize, 1), TextInput.at(text, 8, .unicode, p.row, p.col));
    try testing.expectEqual(@as(usize, 0), TextInput.at("\t", 8, .unicode, 0, 0));
}

test "a row too narrow for its one wide cluster keeps the clusters that take no room" {
    // A tab takes no columns here, so it shares the row with the wide
    // cluster that does not fit a one-column row anyway.
    const text = "\n\t\u{1f469}\u{200d}\u{1f680}";
    const all = try allRows(text, 1);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings(text[1..], text[all[1].from..all[1].to]);
}

test "a malformed byte is one cell and still has a row" {
    try testing.expectEqual(@as(usize, 1), TextInput.rowCount(&.{0xff}, 1, .unicode));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 1 }, TextInput.place(&.{ 0xff, 'a' }, 10, .unicode, 1));
}

test "the input draws the rows around the cursor and puts the cursor there" {
    var h: Harness = try .init(testing.allocator, 8, 2);
    defer h.deinit();
    var state: TextInput.State = .{};
    const text = "one two three four";
    try (TextInput{ .text = text, .cursor = text.len }).draw(h.window(), &state);
    // "one two " · "three " · "four": the last two, with the cursor after
    // "four".
    try testing.expectEqual(@as(usize, 1), state.first);
    try h.expectFrame(
        \\three
        \\four
        \\
    );
    try testing.expect(h.screen.cursor.visible);
    try testing.expectEqual(@as(u16, 4), h.screen.cursor.col);
    try testing.expectEqual(@as(u16, 1), h.screen.cursor.row);

    // Home: the view follows the cursor back up.
    h.window().clear();
    try (TextInput{ .text = text, .cursor = 0 }).draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 0), state.first);
    try h.expectFrame(
        \\one two
        \\three
        \\
    );
}

test "a carriage return and newline end a row together" {
    const text = "ab\r\ncd";
    const all = try allRows(text, 10);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("ab", text[all[0].from..all[0].to]);
    try testing.expect(all[0].hard);
    try testing.expectEqualStrings("cd", text[all[1].from..all[1].to]);
    try testing.expectEqual(@as(usize, 2), TextInput.lineEnd(text, 0));
    try testing.expectEqual(@as(usize, 2), TextInput.prev(text, 4));
    try testing.expectEqual(@as(usize, 4), TextInput.next(text, 2));
    // A cursor left between the two is on the first row's end.
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 2 }, TextInput.place(text, 10, .unicode, 3));
}

/// Pieces of typed and pasted text: words, spaces, newlines both ways, wide
/// and combined clusters, and bytes that are not UTF-8 at all.
const pieces = [_][]const u8{
    "a",    "word",     " ",        "  ",                         "\n",
    "\r\n", "\u{4e2d}", "e\u{301}", "\u{1f469}\u{200d}\u{1f680}", "\u{1f1e6}\u{1f1e7}",
    "\t",   "\xff",     "\xe4\xb8", "\u{26a0}\u{fe0f}",           "x.y/z",
};

fn layoutHolds(gpa: std.mem.Allocator, smith: *std.testing.Smith) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    while (text.items.len < 200 and !smith.eos()) {
        try text.appendSlice(gpa, pieces[smith.index(pieces.len)]);
    }
    const t = text.items;
    const cols: u16 = smith.valueRangeAtMost(u8, 1, 12);
    const method: Method = if (smith.value(bool)) .unicode else .wcwidth;

    // The rows cover the text: every byte in exactly one, in order.
    var owned: usize = 0;
    var count: usize = 0;
    var it = TextInput.rows(t, cols, method);
    while (it.next()) |r| : (count += 1) {
        try testing.expectEqual(owned, r.from);
        try testing.expect(r.from <= r.to);
        // No row is wider than the width unless one cluster alone is: a row
        // over the width holds one cluster that takes columns, and any that
        // take none beside it.
        if (visor.width(t[r.from..r.to], method) > cols) {
            var g: visor.Graphemes = .init(t[r.from..r.to]);
            var wide: usize = 0;
            while (g.next()) |cluster| {
                if (visor.graphemeWidth(cluster, method) != 0) wide += 1;
            }
            try testing.expectEqual(@as(usize, 1), wide);
        }
        owned = it.at;
        if (!r.hard) try testing.expectEqual(r.to, it.at);
    }
    try testing.expect(it.done);
    try testing.expectEqual(t.len, owned);
    try testing.expectEqual(count, TextInput.rowCount(t, cols, method));

    // Every cluster boundary has a place, and the place leads back to it.
    var boundaries: visor.Graphemes = .init(t);
    var c: usize = 0;
    while (true) {
        const p = TextInput.place(t, cols, method, c);
        try testing.expect(p.row < count);
        const back = TextInput.at(t, cols, method, p.row, p.col);
        try testing.expect(back <= c);
        try testing.expectEqual(@as(u16, 0), visor.width(t[back..c], method));
        const n = TextInput.next(t, c);
        if (c < t.len) {
            try testing.expect(n > c);
            try testing.expectEqual(c, TextInput.prev(t, n));
        } else try testing.expectEqual(c, n);
        const found = boundaries.next() orelse break;
        c += found.len;
    }

    // Drawn into a small window with the cursor anywhere, the cursor shows
    // inside it.
    var h: Harness = try .init(gpa, cols, 3);
    defer h.deinit();
    var state: TextInput.State = .{ .first = smith.value(u8) };
    const cursor = smith.index(t.len + 1);
    try (TextInput{ .text = t, .cursor = cursor }).draw(h.window(), &state);
    try testing.expect(h.screen.cursor.visible);
    try testing.expect(h.screen.cursor.row < 3);
    try testing.expect(h.screen.cursor.col < cols);
    _ = try h.frame();
}

test "the layout covers every byte and every cluster has a place that leads back to it" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try layoutHolds(gpa, smith);
        }
    }.one, .{ .corpus = &.{
        "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e",
        "\x05\x05\x05\x04\x04\x03\x09\x0a\x0b\x0c\x02\x02\x01\x00",
        "\x01\x02\x01\x02\x01\x02\x01\x02\x06\x07\x08\x0b",
        "\x0d\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01\x00\x0e\x0e",
    } });
}
