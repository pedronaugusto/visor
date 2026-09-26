//! Titles in a row, one of them chosen.
//!
//! The arithmetic that places the titles is public as `spanOf`, because a
//! program that draws tabs also has to answer which one the mouse landed on,
//! and working that out twice in two places is how the two drift apart.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

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
    pub fn spanOf(t: Tabs, which: usize, method: visor.Method) struct { col: u16, cols: u16 } {
        var col: u16 = 0;
        const divider = visor.width(t.divider, method);
        for (t.titles, 0..) |title, i| {
            const cols = visor.width(title, method) + t.padding * 2;
            if (i == which) return .{ .col = col, .cols = cols };
            col +|= cols +| divider;
        }
        return .{ .col = col, .cols = 0 };
    }

    /// Which title a column falls in, or null between or beyond them.
    pub fn indexAt(t: Tabs, col: u16, method: visor.Method) ?usize {
        for (t.titles, 0..) |_, i| {
            const span = t.spanOf(i, method);
            if (col >= span.col and col < span.col + span.cols) return i;
        }
        return null;
    }

    /// How many columns every title and divider takes together.
    pub fn width(t: Tabs, method: visor.Method) u16 {
        if (t.titles.len == 0) return 0;
        const last = t.spanOf(t.titles.len - 1, method);
        return last.col +| last.cols;
    }

    /// Draws the titles on the window's first row.
    pub fn draw(t: Tabs, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const method = win.screen.method;
        const divider = win.width(t.divider);
        for (t.titles, 0..) |title, i| {
            const span = t.spanOf(i, method);
            if (span.col >= win.cols()) return;
            const style = if (i == t.selected) t.selected_style else t.style;
            win.fill(
                .{ .col = span.col, .row = 0, .cols = span.cols, .rows = 1 },
                .blank(style),
            );
            _ = try win.printSegment(
                .{ .text = title, .style = style },
                .{ .col = span.col + t.padding, .row = 0, .wrap = .none },
            );
            if (divider != 0 and i + 1 < t.titles.len) {
                const divider_style = t.divider_style orelse continue;
                _ = try win.printSegment(
                    .{ .text = t.divider, .style = divider_style },
                    .{ .col = span.col + span.cols, .row = 0, .wrap = .none },
                );
            }
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

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
    h.window().fill(.fromSize(h.window().size()), .init(.{ .text = .inlined("."), .style = .{ .italic = true } }));
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
