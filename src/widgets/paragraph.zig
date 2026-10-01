//! Lines of text, wrapped, aligned and scrolled.
//!
//! Each line is wrapped on its own and drawn in its own style, so a log with
//! a colour per severity is a slice of `Line` and not a slice of spans. The
//! wrap is the base's, so a wide cluster never straddles the right edge and
//! a word break is where the base puts it.
//!
//! Nothing is measured twice: the rows are produced one at a time from a
//! buffer on the stack. Producing rows allocates nothing; drawing them can
//! allocate for previously unseen graphemes longer than six bytes, as
//! `Window.print` does.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Align = layout.Align;
const Style = visor.Style;
const Window = visor.Window;

/// One line of a paragraph: its text, and the style and link it draws in.
pub const Line = struct {
    /// The text. A newline inside it always ends a row.
    text: []const u8,
    /// The style every cluster of it draws in.
    style: Style = .{},
    /// The OSC 8 target every cluster of it belongs to.
    link: visor.Link = .none,
};

/// Lines of text, wrapped, aligned and scrolled.
pub const Paragraph = struct {
    /// Iterate the same wrapped ranges that drawing and rowCount use.
    /// A caller laying out a transcript can retain its own per-row metadata.
    pub const Rows = RowIterator;
    /// The lines, in order.
    lines: []const Line,
    /// How a line that does not fit is broken.
    wrap: visor.Wrap = .none,
    /// Where each row sits in the window's width.
    where: Align = .left,
    /// How many rows are skipped before the first one drawn.
    scroll: usize = 0,
    /// How many columns are skipped off the left of every row. Meaningful
    /// when nothing is wrapped, which is when a row can be wider than the
    /// window.
    scroll_columns: u16 = 0,

    /// How many rows the text takes at this width.
    ///
    /// What a scrollbar's content length is, and what a caller clamps its
    /// own scroll against. Counts every row, which costs one pass over the
    /// text and no memory.
    pub fn rowCount(p: Paragraph, cols: u16, method: visor.Method) usize {
        if (cols == 0) return 0;
        var total: usize = 0;
        for (p.lines) |line| {
            var it: Rows = .init(skipColumns(line.text, p.scroll_columns, method), cols, p.wrap, method);
            while (it.next()) |_| total += 1;
        }
        return total;
    }

    /// Draws as many rows as the window has, starting at `scroll`.
    pub fn draw(p: Paragraph, win: Window) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        if (win.rect.isEmpty()) return;
        var produced: usize = 0;
        var row: u16 = 0;
        for (p.lines) |line| {
            // The columns come off before the wrap, because a row that was
            // cut to the window's width and then shifted left would be a
            // window on a window.
            const method = win.screen.method;
            const body = skipColumns(line.text, p.scroll_columns, method);
            var it: Rows = .init(body, win.cols(), p.wrap, method);
            while (it.next()) |r| {
                if (produced < p.scroll) {
                    produced += 1;
                    continue;
                }
                produced += 1;
                if (row >= win.rows()) return;
                const text = body[r.start..r.end];
                const taken = @min(visor.width(text, method), win.cols());
                _ = try win.printSegment(.{
                    .text = text,
                    .style = line.style,
                    .link = line.link,
                }, .{
                    .col = layout.offset(win.cols(), taken, p.where),
                    .row = row,
                    .wrap = .none,
                });
                row += 1;
            }
        }
    }
};

/// The rows one line's text breaks into, one at a time.
///
/// The base's `wrap` fills a caller's slice and stops when it is full, so
/// this refills from the start of the last row it was given and hands back
/// absolute ranges. A paragraph of ten thousand rows therefore costs the
/// same thirty-two rows of stack as a paragraph of two.
const RowIterator = struct {
    _text: []const u8,
    _cols: u16,
    _mode: visor.Wrap,
    _method: visor.Method,
    _base: usize = 0,
    _buf: [32]visor.Row = undefined,
    _have: usize = 0,
    _at: usize = 0,
    /// Whether the last refill saw the end of the text.
    _last: bool = false,

    /// Break `text` into rows `cols` wide, the way `Paragraph.draw` does.
    pub fn init(text: []const u8, cols: u16, mode: visor.Wrap, method: visor.Method) RowIterator {
        return .{ ._text = text, ._cols = cols, ._mode = mode, ._method = method };
    }

    /// The next row, as a range of the whole text, or null after the last.
    pub fn next(it: *RowIterator) ?visor.Row {
        if (it._at == it._have) {
            if (it._last) return null;
            it._have = visor.wrap(it._text[it._base..], it._cols, it._mode, it._method, &it._buf);
            it._at = 0;
            if (it._have == 0) return null;
            if (it._have < it._buf.len) {
                it._last = true;
            } else {
                // The last row of a full buffer is where the next refill
                // starts, so it is handed out by that refill and not by
                // this one.
                it._have -= 1;
            }
        }
        const r = it._buf[it._at];
        const out: visor.Row = .{
            .start = it._base + r.start,
            .end = it._base + r.end,
            .columns = r.columns,
        };
        it._at += 1;
        // The row that was held back is where the next refill starts.
        if (it._at == it._have and !it._last) it._base += it._buf[it._have].start;
        return out;
    }
};

/// What is left of a row after `n` columns are skipped off its left.
fn skipColumns(text: []const u8, n: u16, method: visor.Method) []const u8 {
    if (n == 0) return text;
    var used: u32 = 0;
    var it: visor.Graphemes = .init(text);
    while (it.nextAt()) |found| {
        if (used >= n) return text[found.start..];
        used += visor.graphemeWidth(found.bytes, method);
    }
    return text[text.len..];
}

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a paragraph wraps by word and stops at the last row" {
    var h: Harness = try .init(testing.allocator, 12, 3);
    defer h.deinit();
    try (Paragraph{
        .lines = &.{.{ .text = "the quick brown fox jumps over" }},
        .wrap = .word,
    }).draw(h.window());
    try h.expectFrame(
        \\the quick
        \\brown fox
        \\jumps over
        \\
    );
}

test "a paragraph scrolls by rows and counts them" {
    var h: Harness = try .init(testing.allocator, 6, 2);
    defer h.deinit();
    const p: Paragraph = .{
        .lines = &.{ .{ .text = "one" }, .{ .text = "two" }, .{ .text = "three" }, .{ .text = "four" } },
        .scroll = 2,
    };
    try testing.expectEqual(@as(usize, 4), p.rowCount(6, h.screen.method));
    try p.draw(h.window());
    try h.expectFrame(
        \\three
        \\four
        \\
    );
}

test "a paragraph aligns each row in the window's width" {
    var h: Harness = try .init(testing.allocator, 9, 2);
    defer h.deinit();
    try (Paragraph{
        .lines = &.{ .{ .text = "one" }, .{ .text = "three" } },
        .where = .right,
    }).draw(h.window());
    try h.expectFrame(
        \\      one
        \\    three
        \\
    );
}

test "a paragraph measures with its screen's width method" {
    var h: Harness = try .init(testing.allocator, 3, 1);
    defer h.deinit();
    h.screen.method = .wcwidth;
    try (Paragraph{
        .lines = &.{.{ .text = "\u{26a0}\u{fe0f}" }},
        .where = .right,
    }).draw(h.window());
    try testing.expectEqualStrings("\u{26a0}\u{fe0f}", h.screen.textAt(2, 0));
}

test "a paragraph scrolled sideways drops the columns off its left" {
    var h: Harness = try .init(testing.allocator, 5, 1);
    defer h.deinit();
    try (Paragraph{
        .lines = &.{.{ .text = "abcdefghij" }},
        .scroll_columns = 4,
    }).draw(h.window());
    try h.expectFrame(
        \\efghi
        \\
    );
}

test "a line keeps its own style and its own link" {
    var h: Harness = try .init(testing.allocator, 6, 2);
    defer h.deinit();
    const link = try h.screen.link("https://ziglang.org", "");
    try (Paragraph{ .lines = &.{
        .{ .text = "warn", .style = .{ .fg = .ansi(.red) } },
        .{ .text = "zig", .link = link },
    } }).draw(h.window());
    try h.expectFrame(
        \\warn
        \\zig
        \\
    );
    try testing.expectEqual(visor.Color.ansi(.red), h.styleAt(0, 0).fg);
    const shown = h.term.screen().readCell(0, 1).?.link;
    try testing.expect(shown != link);
    try testing.expectEqualStrings("https://ziglang.org", h.term.screen().target(shown).?.uri);
    try testing.expectEqualStrings("", h.term.screen().target(shown).?.params);
}

test "the rows of a long line come out in order whatever the buffer holds" {
    // Longer than the thirty-two rows the iterator refills from, so the
    // refill path is the one under test.
    const text = "a " ** 200;
    var it: Paragraph.Rows = .init(text, 4, .word, .unicode);
    var count: usize = 0;
    var last_end: usize = 0;
    while (it.next()) |r| {
        try testing.expect(r.start >= last_end);
        try testing.expect(r.end <= text.len);
        last_end = r.end;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 100), count);
}

test "a wide cluster never straddles the right edge of a paragraph" {
    var h: Harness = try .init(testing.allocator, 3, 2);
    defer h.deinit();
    try (Paragraph{ .lines = &.{.{ .text = "ab中" }}, .wrap = .grapheme }).draw(h.window());
    try h.expectFrame(
        \\ab
        \\中
        \\
    );
}

test "a paragraph scrolled by n shows what the whole one shows n rows down" {
    const lines = [_]Line{
        .{ .text = "the quick brown fox" },
        .{ .text = "jumps over" },
        .{ .text = "the lazy dog" },
    };
    const cols: u16 = 8;

    // The whole thing, in a window tall enough for all of it.
    const total = (Paragraph{ .lines = &lines, .wrap = .word }).rowCount(cols, .unicode);
    var whole: Harness = try .init(testing.allocator, cols, @intCast(total));
    defer whole.deinit();
    try (Paragraph{ .lines = &lines, .wrap = .word }).draw(whole.window());
    _ = try whole.frame();

    var scroll: usize = 0;
    while (scroll <= total) : (scroll += 1) {
        var window_rows: u16 = 1;
        while (window_rows <= 4) : (window_rows += 1) {
            var h: Harness = try .init(testing.allocator, cols, window_rows);
            defer h.deinit();
            try (Paragraph{ .lines = &lines, .wrap = .word, .scroll = scroll }).draw(h.window());
            _ = try h.frame();
            var row: u16 = 0;
            while (row < window_rows) : (row += 1) {
                const want = if (scroll + row < total)
                    whole.term.screen().textAt(0, @intCast(scroll + row))
                else
                    " ";
                try testing.expectEqualStrings(want, h.term.screen().textAt(0, row));
            }
        }
    }
}

test "horizontal scrolling skips a wide cluster crossing the u16 edge" {
    const text = "a" ** (std.math.maxInt(u16) - 1) ++ "一x";
    try testing.expectEqualStrings("x", skipColumns(text, std.math.maxInt(u16), .unicode));
    var h = try Harness.init(testing.allocator, 2, 1);
    defer h.deinit();
    const paragraph: Paragraph = .{ .lines = &.{.{ .text = text }}, .scroll_columns = std.math.maxInt(u16) };
    try paragraph.draw(h.window());
    try h.expectFrame("x\n");
}

test "paragraph rows and clipping treat CRLF as one line break" {
    for ([_]visor.Wrap{ .none, .word, .grapheme }) |mode| {
        const text = "long line\r\nb\r\n\r\nc";
        var rows = Paragraph.Rows.init(text, 3, mode, .unicode);
        var count: usize = 0;
        while (rows.next()) |r| {
            try testing.expect(std.mem.indexOfAny(u8, text[r.start..r.end], "\r\n") == null);
            count += 1;
        }
        const paragraph: Paragraph = .{ .lines = &.{.{ .text = text }}, .wrap = mode };
        try testing.expectEqual(count, paragraph.rowCount(3, .unicode));
        var h = try Harness.init(testing.allocator, 3, @intCast(count));
        defer h.deinit();
        try paragraph.draw(h.window());
        if (mode == .none) {
            try testing.expectEqual(@as(usize, 4), count);
            try h.expectFrame("lon\nb\n\nc\n");
        } else {
            try testing.expectEqualStrings("c", h.screen.textAt(0, @intCast(count - 1)));
        }
    }
}

test "paragraph row iterator source and refill state stay behind next" {
    inline for (.{ "text", "cols", "mode", "method", "base", "buf", "have", "at", "last" }) |field| {
        try testing.expect(!@hasField(Paragraph.Rows, field));
    }
}
