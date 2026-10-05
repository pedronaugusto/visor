//! Titles in a row, one of them chosen.
//!
//! The arithmetic that places the titles is public as `spanOf`, because a
//! program that draws tabs also has to answer which one the mouse landed on,
//! and working that out twice in two places is how the two drift apart.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;

/// Titles in a row, one of them chosen.
pub const Tabs = struct {
    /// The titles, left to right.
    titles: []const []const u8,
    /// Which one is chosen.
    selected: usize = 0,
    /// The style the others draw in.
    style: Style = .{},
    /// The style the chosen one draws in.
    selected_style: Style = .{ .bold = true, .reverse = true },
    /// Drawn between two titles. Empty for none.
    divider: []const u8 = "\u{2502}",
    /// The style the divider draws in, or null to leave the columns between
    /// two titles as they are: spacing the tabs apart without drawing over
    /// what is under them.
    divider_style: ?Style = .{ .dim = true },
    /// Cells of space each side of every title.
    padding: u16 = 1,

    /// Where one title sits in the row, in the window's own columns, with
    /// the titles measured the way the screen they are drawn on measures
    /// (`Screen.method`).
    ///
    /// The padding is part of the span, so a click on the space beside a
    /// title chooses it, which is what a person aiming at a tab means.
    /// Spans are clipped to the largest window width; indexAt uses the
    /// complete logical spans even when their endpoints do not fit in u16.
    pub fn spanOf(t: Tabs, which: usize, method: visor.Method) struct { col: u16, cols: u16 } {
        var spans = t.spanIterator(method);
        while (spans.next()) |span| {
            if (span.which == which) return .{
                .col = @intCast(@min(span.col, std.math.maxInt(u16))),
                .cols = @intCast(@min(span.cols, std.math.maxInt(u16) - @min(span.col, std.math.maxInt(u16)))),
            };
        }
        return .{ .col = @intCast(@min(spans.col, std.math.maxInt(u16))), .cols = 0 };
    }

    /// Which title a column falls in, or null between or beyond them.
    pub fn indexAt(t: Tabs, col: u16, method: visor.Method) ?usize {
        var spans = t.spanIterator(method);
        while (spans.next()) |span| {
            if (col >= span.col and col < span.col + span.cols) return span.which;
        }
        return null;
    }

    /// How many columns every title and divider takes together, saturated
    /// at the largest window width.
    pub fn width(t: Tabs, method: visor.Method) u16 {
        var end: u128 = 0;
        var spans = t.spanIterator(method);
        while (spans.next()) |span| end = span.col + span.cols;
        return @intCast(@min(end, std.math.maxInt(u16)));
    }

    /// Draws the titles on the window's first row.
    pub fn draw(t: Tabs, win: visor.Window) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        if (win.rect().isEmpty()) return;
        var spans = t.spanIterator(win.screen().method);
        while (spans.next()) |span| {
            if (span.col >= win.cols()) return;
            const style = if (span.which == t.selected) t.selected_style else t.style;
            try win.fill(
                .{ .col = @intCast(span.col), .row = 0, .cols = @intCast(@min(span.cols, win.cols() - span.col)), .rows = 1 },
                .blank(style),
            );
            const label_col = span.col + t.padding;
            if (label_col < win.cols()) _ = try win.printSegment(
                .{ .text = t.titles[span.which], .style = style },
                .{ .col = @intCast(label_col), .row = 0, .wrap = .none },
            );
            const divider_col = span.col + span.cols;
            if (spans.divider != 0 and span.which + 1 < t.titles.len and divider_col < win.cols()) {
                const divider_style = t.divider_style orelse continue;
                _ = try win.printSegment(
                    .{ .text = t.divider, .style = divider_style },
                    .{ .col = @intCast(divider_col), .row = 0, .wrap = .none },
                );
            }
        }
    }

    // Drawing, measuring and hit testing consume the same logical spans.
    // Keep them wide until a coordinate is known to fit in the window.
    fn spanIterator(t: Tabs, method: visor.Method) Spans {
        return .{ .tabs = t, .method = method, .divider = visor.width(t.divider, method) };
    }

    const Spans = struct {
        tabs: Tabs,
        method: visor.Method,
        divider: u16,
        which: usize = 0,
        col: u128 = 0,

        const Span = struct { which: usize, col: u128, cols: u32 };

        fn next(it: *Spans) ?Span {
            if (it.which == it.tabs.titles.len) return null;
            const cols = @as(u32, visor.width(it.tabs.titles[it.which], it.method)) + @as(u32, it.tabs.padding) * 2;
            const result: Span = .{ .which = it.which, .col = it.col, .cols = cols };
            it.which += 1;
            it.col += cols + it.divider;
            return result;
        }
    };
};

const testing = std.testing;
const Harness = @import("../testing/widget_harness.zig").Harness;

const titles = [_][]const u8{ "one", "two", "three" };

test "tabs draw with a divider between them" {
    var h: Harness = try .init(testing.allocator, 22, 1);
    defer h.deinit();
    try (Tabs{ .titles = &titles, .selected = 1 }).draw(h.window());
    try h.expectFrame(
        \\ one │ two │ three
        \\
    );
    try testing.expect(h.styleAt(7, 0).reverse);
    try testing.expect(!h.styleAt(1, 0).reverse);
}

test "a column falls in the tab it is under, padding included" {
    const t: Tabs = .{ .titles = &titles };
    try testing.expectEqual(@as(?usize, 0), t.indexAt(0, .unicode));
    try testing.expectEqual(@as(?usize, 0), t.indexAt(4, .unicode));
    try testing.expectEqual(@as(?usize, null), t.indexAt(5, .unicode));
    try testing.expectEqual(@as(?usize, 1), t.indexAt(6, .unicode));
    try testing.expectEqual(@as(?usize, 2), t.indexAt(12, .unicode));
    try testing.expectEqual(@as(?usize, null), t.indexAt(99, .unicode));
    try testing.expectEqual(@as(u16, 19), t.width(.unicode));
}

test "tabs wider than the window stop at its edge" {
    var h: Harness = try .init(testing.allocator, 9, 1);
    defer h.deinit();
    try (Tabs{ .titles = &titles, .divider = "", .padding = 0 }).draw(h.window());
    try h.expectFrame(
        \\onetwothr
        \\
    );
}

test "titles are measured the way the screen measures" {
    const t: Tabs = .{ .titles = &.{ sign, "b" }, .padding = 0, .divider = "|" };
    try testing.expectEqual(@as(u16, 3), t.width(.wcwidth));
    try testing.expectEqual(@as(u16, 4), t.width(.unicode));
    try testing.expectEqual(@as(?usize, 1), t.indexAt(2, .wcwidth));
    var h: Harness = try .initMeasured(testing.allocator, 5, 1, .wcwidth);
    defer h.deinit();
    try t.draw(h.window());
    _ = try h.frame();
    try testing.expectEqualStrings("b", h.term.screen().textAt(2, 0));
}

const sign = "\u{26a0}\u{fe0f}";

test "a divider with no style is a gap left as it was" {
    var h: Harness = try .init(testing.allocator, 8, 1);
    defer h.deinit();
    try h.window().fill(.fromSize(h.window().size()), .init(.{ .text = .inlined("."), .style = .{ .italic = true } }));
    const t: Tabs = .{ .titles = &.{ "a", "b" }, .padding = 0, .divider = "  ", .divider_style = null };
    try t.draw(h.window());
    try h.expectFrame(
        \\a..b....
        \\
    );
    try testing.expect(h.styleAt(1, 0).italic);
    // The gap still counts: the second title is past it, and a column in
    // it chooses nothing.
    try testing.expectEqual(@as(?usize, null), t.indexAt(1, .unicode));
    try testing.expectEqual(@as(?usize, 1), t.indexAt(3, .unicode));
}

test "tabs share wide span arithmetic between drawing and hit testing" {
    const edge = std.math.maxInt(u16);
    const t: Tabs = .{ .titles = &.{ "a", "b" }, .padding = edge };
    try testing.expectEqual(edge, t.width(.unicode));
    try testing.expectEqual(@as(?usize, 0), t.indexAt(edge, .unicode));
    try testing.expectEqual(@as(u16, 0), t.spanOf(1, .unicode).cols);
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    try t.draw(h.window());
    try h.expectFrame("\n");
    try testing.expect(h.styleAt(0, 0).reverse);
    const crossing: Tabs = .{ .titles = &.{ "a" ** (edge - 1), "b" }, .padding = 0, .divider = "||" };
    try testing.expectEqual(@as(?usize, null), crossing.indexAt(edge, .unicode));
    try testing.expectEqual(@as(u16, 0), crossing.spanOf(1, .unicode).cols);
}
