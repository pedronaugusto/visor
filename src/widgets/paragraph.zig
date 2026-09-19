//! Lines of text, wrapped, aligned and scrolled.
//!
//! Each line is wrapped on its own and drawn in its own style, so a log with
//! a colour per severity is a slice of `Line` and not a slice of spans. The
//! wrap is the base's, so a wide cluster never straddles the right edge and
//! a word break is where the base puts it.
//!
//! Nothing is measured twice: the rows are produced one at a time from a
//! buffer on the stack, so a paragraph of any length scrolled to any row
//! allocates nothing.

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
    pub fn rowCount(p: Paragraph, cols: u16) usize {
        if (cols == 0) return 0;
        var total: usize = 0;
        for (p.lines) |line| {
            var it: Rows = .init(skipColumns(line.text, p.scroll_columns), cols, p.wrap);
            while (it.next()) |_| total += 1;
        }
        return total;
    }

    /// Draws as many rows as the window has, starting at `scroll`.
    pub fn draw(p: Paragraph, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        var produced: usize = 0;
        var row: u16 = 0;
        for (p.lines) |line| {
            // The columns come off before the wrap, because a row that was
            // cut to the window's width and then shifted left would be a
            // window on a window.
            const body = skipColumns(line.text, p.scroll_columns);
            var it: Rows = .init(body, win.cols(), p.wrap);
            while (it.next()) |r| {
                if (produced < p.scroll) {
                    produced += 1;
                    continue;
                }
                produced += 1;
                if (row >= win.rows()) return;
                const text = body[r.start..r.end];
                const taken = @min(visor.width(text, .unicode), win.cols());
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
const Rows = struct {
    text: []const u8,
    cols: u16,
    mode: visor.Wrap,
    base: usize = 0,
    buf: [32]visor.Row = undefined,
    have: usize = 0,
    at: usize = 0,
    /// Whether the last refill saw the end of the text.
    last: bool = false,

    fn init(text: []const u8, cols: u16, mode: visor.Wrap) Rows {
        return .{ .text = text, .cols = cols, .mode = mode };
    }

    fn next(it: *Rows) ?visor.Row {
        if (it.at == it.have) {
            if (it.last) return null;
            it.have = visor.wrap(it.text[it.base..], it.cols, it.mode, .unicode, &it.buf);
            it.at = 0;
            if (it.have == 0) return null;
            if (it.have < it.buf.len) {
                it.last = true;
            } else {
                // The last row of a full buffer is where the next refill
                // starts, so it is handed out by that refill and not by
                // this one.
                it.have -= 1;
            }
        }
        const r = it.buf[it.at];
        const out: visor.Row = .{
            .start = it.base + r.start,
            .end = it.base + r.end,
            .columns = r.columns,
        };
        it.at += 1;
        // The row that was held back is where the next refill starts.
        if (it.at == it.have and !it.last) it.base += it.buf[it.have].start;
        return out;
    }
};

/// What is left of a row after `n` columns are skipped off its left.
fn skipColumns(text: []const u8, n: u16) []const u8 {
    if (n == 0) return text;
    var used: u16 = 0;
    var it: visor.Graphemes = .init(text);
    while (it.nextAt()) |found| {
        if (used >= n) return text[found.start..];
        used += visor.graphemeWidth(found.bytes, .unicode);
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
    try testing.expectEqual(@as(usize, 4), p.rowCount(6));
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
    const link = try h.screen.link(testing.allocator, "https://ziglang.org", "");
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
    try testing.expectEqual(link, h.term.screen().readCell(0, 1).?.link);
}

test "the rows of a long line come out in order whatever the buffer holds" {
    // Longer than the thirty-two rows the iterator refills from, so the
    // refill path is the one under test.
    const text = "a " ** 200;
    var it: Rows = .init(text, 4, .word);
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
    const total = (Paragraph{ .lines = &lines, .wrap = .word }).rowCount(cols);
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
