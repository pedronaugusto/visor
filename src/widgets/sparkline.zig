//! A series as blocks, one column a point.
//!
//! The whole of a sparkline is that it costs one row and says the shape of
//! a series anyway. Taller windows are drawn as a column of blocks, so the
//! same widget is a sparkline at one row and a bar chart of one-column bars
//! at ten.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

/// The eight heights a cell of a vertical bar can be drawn at, an eighth to
/// a whole.
const eighths = [8][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

/// A series as one column a point.
pub const Sparkline = struct {
    /// The points, oldest first.
    data: []const u64,
    /// What the top of the window is worth. Null takes the largest point.
    max: ?u64 = null,
    /// The style the blocks draw in.
    style: Style = .{},
    /// Which end of the data the window's right edge holds.
    direction: Direction = .left_to_right,
    /// How a point becomes a height.
    mode: Mode = .fill,

    /// How a point becomes a height.
    pub const Mode = enum {
        /// In eighths of the window's height, rounded down: a zero point is
        /// no block at all, and the largest fills the window.
        fill,
        /// The nearest of the heights, and never nothing: a zero point is
        /// the lowest eighth and the largest the full height. One row tall,
        /// it is one of eight glyphs a point, which is what a sparkline
        /// written into a line of text wants.
        level,
    };

    /// Which way the series runs across the window.
    pub const Direction = enum {
        /// The oldest point on the left. A series longer than the window
        /// loses its oldest points.
        left_to_right,
        /// The newest point on the left. A series longer than the window
        /// loses its oldest points here too.
        right_to_left,
    };

    /// Draws one column a point, bottom-aligned.
    pub fn draw(s: Sparkline, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty() or s.data.len == 0) return;
        const cols = win.cols();
        const rows = win.rows();

        // A series longer than the window keeps its newest points.
        const shown = s.data[s.data.len -| cols..];
        var top = s.max orelse 0;
        if (s.max == null) for (shown) |v| {
            top = @max(top, v);
        };
        if (top == 0) top = 1;

        for (shown, 0..) |value, i| {
            const col: u16 = switch (s.direction) {
                .left_to_right => @intCast(i),
                .right_to_left => @intCast(shown.len - 1 - i),
            };
            const scaled: u64 = switch (s.mode) {
                .fill => @intCast(@as(u128, @min(value, top)) * rows * 8 / top),
                .level => blk: {
                    const t = @as(f64, @floatFromInt(@min(value, top))) / @as(f64, @floatFromInt(top));
                    const steps: f64 = @floatFromInt(@as(u64, rows) * 8 - 1);
                    break :blk @as(u64, @intFromFloat(@round(t * steps))) + 1;
                },
            };
            var row: u16 = rows;
            var left = scaled;
            while (row > 0) : (row -= 1) {
                const here = @min(left, 8);
                if (here == 0) break;
                try win.write(col, row - 1, eighths[here - 1], s.style, .none);
                left -= here;
            }
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a sparkline scales its points against the largest of them" {
    var h: Harness = try .init(testing.allocator, 5, 1);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 0, 2, 4, 6, 8 } }).draw(h.window());
    try h.expectFrame(
        \\ ▂▄▆█
        \\
    );
}

test "a sparkline given a maximum scales against that instead" {
    var h: Harness = try .init(testing.allocator, 4, 1);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 8, 8, 8, 8 }, .max = 16 }).draw(h.window());
    try h.expectFrame(
        \\▄▄▄▄
        \\
    );
}

test "a taller window draws each point as a column of blocks" {
    var h: Harness = try .init(testing.allocator, 3, 2);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 4, 8, 16 }, .max = 16 }).draw(h.window());
    try h.expectFrame(
        \\  █
        \\▄██
        \\
    );
}

test "a maximum u64 point scales without overflow" {
    var h: Harness = try .init(testing.allocator, 1, 2);
    defer h.deinit();
    try (Sparkline{ .data = &.{std.math.maxInt(u64)} }).draw(h.window());
    try h.expectFrame(
        \\█
        \\█
        \\
    );
}

test "a series longer than the window keeps its newest points" {
    var h: Harness = try .init(testing.allocator, 3, 1);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 8, 8, 0, 4, 8 }, .max = 8 }).draw(h.window());
    try h.expectFrame(
        \\ ▄█
        \\
    );
}

test "a sparkline can run the other way" {
    var h: Harness = try .init(testing.allocator, 3, 1);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 0, 4, 8 }, .max = 8, .direction = .right_to_left }).draw(h.window());
    try h.expectFrame(
        \\█▄
        \\
    );
}

test "by level every point is one of eight glyphs, and a zero is the lowest" {
    var h: Harness = try .init(testing.allocator, 5, 1);
    defer h.deinit();
    try (Sparkline{ .data = &.{ 0, 1, 50, 99, 100 }, .mode = .level }).draw(h.window());
    // round(t * 7): 0, 0, 4 (3.5 rounds up), 7, 7.
    try h.expectFrame(
        \\▁▁▅██
        \\
    );
    h.window().clear();
    try (Sparkline{ .data = &.{ 0, 0 }, .mode = .level }).draw(h.window());
    try h.expectFrame(
        \\▁▁
        \\
    );
}
