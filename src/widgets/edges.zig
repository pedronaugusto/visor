//! Styled items at the two edges of one row. The right side keeps its
//! room; the left is clipped before it, with a caller-selected gap.
const std = @import("std");
const visor = @import("visor");

pub const Edges = struct {
    /// Drawn from the left edge, in order, and clipped where the right
    /// side and the gap begin.
    left: []const visor.Window.Segment = &.{},
    /// Drawn flush against the right edge. It keeps its whole width, up to
    /// the window's.
    right: []const visor.Window.Segment = &.{},
    /// Blank columns kept between the two sides. No gap is kept when the
    /// right side is empty.
    gap: u16 = 1,

    /// The columns `items` take on screen under `method`, saturating.
    pub fn width(items: []const visor.Window.Segment, method: visor.Method) u16 {
        var total: u16 = 0;
        for (items) |item| total +|= visor.width(item.text, method);
        return total;
    }

    /// Draw the row on the window's first line. Cells the items do not
    /// cover are left as they were.
    pub fn draw(r: Edges, win: visor.Window) (std.mem.Allocator.Error || error{InvalidHandle})!void {
        if (win.rect.isEmpty()) return;
        const right_w = @min(width(r.right, win.screen.method), win.cols());
        const right_col = win.cols() - right_w;
        const left_w = right_col -| (if (right_w > 0) r.gap else @as(u16, 0));
        try drawItems(r.left, win.child(.{ .cols = left_w, .rows = 1 }));
        try drawItems(r.right, win.child(.{ .col = right_col, .cols = right_w, .rows = 1 }));
    }

    fn drawItems(items: []const visor.Window.Segment, win: visor.Window) !void {
        var col: u16 = 0;
        for (items) |item| {
            if (col >= win.cols()) break;
            _ = try win.printSegment(item, .{ .col = col, .wrap = .none });
            col +|= visor.width(item.text, win.screen.method);
        }
    }
};

const Harness = @import("harness.zig").Harness;

test "edges keep both sides and clips the left before the right" {
    var h: Harness = try .init(std.testing.allocator, 12, 1);
    defer h.deinit();
    try (Edges{ .left = &.{.{ .text = "long left text" }}, .right = &.{.{ .text = "end", .style = .{ .bold = true } }} }).draw(h.window());
    try h.expectFrame("long lef end\n");
    try std.testing.expect(h.styleAt(11, 0).bold);
}

test "edges measure wide text and an empty right consumes no gap" {
    var h: Harness = try .init(std.testing.allocator, 6, 1);
    defer h.deinit();
    try (Edges{ .left = &.{.{ .text = "abcdef" }} }).draw(h.window());
    try h.expectFrame("abcdef\n");
    h.window().clear();
    try (Edges{ .left = &.{.{ .text = "abc" }}, .right = &.{.{ .text = "界" }} }).draw(h.window());
    try std.testing.expectEqual(@as(u16, 2), Edges.width(&.{.{ .text = "界" }}, .unicode));
    try h.expectFrame("abc 界\n");
}
