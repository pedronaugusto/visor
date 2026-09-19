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
    /// The style the divider draws in.
    divider_style: Style = .{ .dim = true },
    /// Cells of space each side of every title.
    padding: u16 = 1,

    /// Where one title sits in the row, in the window's own columns.
    ///
    /// The padding is part of the span, so a click on the space beside a
    /// title chooses it, which is what a person aiming at a tab means.
    pub fn spanOf(t: Tabs, which: usize) struct { col: u16, cols: u16 } {
        var col: u16 = 0;
        const divider = visor.width(t.divider, .unicode);
        for (t.titles, 0..) |title, i| {
            const cols = visor.width(title, .unicode) + t.padding * 2;
            if (i == which) return .{ .col = col, .cols = cols };
            col +|= cols +| divider;
        }
        return .{ .col = col, .cols = 0 };
    }

    /// Which title a column falls in, or null between or beyond them.
    pub fn indexAt(t: Tabs, col: u16) ?usize {
        for (t.titles, 0..) |_, i| {
            const span = t.spanOf(i);
            if (col >= span.col and col < span.col + span.cols) return i;
        }
        return null;
    }

    /// How many columns every title and divider takes together.
    pub fn width(t: Tabs) u16 {
        if (t.titles.len == 0) return 0;
        const last = t.spanOf(t.titles.len - 1);
        return last.col +| last.cols;
    }

    /// Draws the titles on the window's first row.
    pub fn draw(t: Tabs, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const divider = visor.width(t.divider, .unicode);
        for (t.titles, 0..) |title, i| {
            const span = t.spanOf(i);
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
                _ = try win.printSegment(
                    .{ .text = t.divider, .style = t.divider_style },
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
    try testing.expectEqual(@as(?usize, 0), t.indexAt(0));
    try testing.expectEqual(@as(?usize, 0), t.indexAt(4));
    try testing.expectEqual(@as(?usize, null), t.indexAt(5));
    try testing.expectEqual(@as(?usize, 1), t.indexAt(6));
    try testing.expectEqual(@as(?usize, 2), t.indexAt(12));
    try testing.expectEqual(@as(?usize, null), t.indexAt(99));
    try testing.expectEqual(@as(u16, 19), t.width());
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
