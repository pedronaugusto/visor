//! A place, a size and a rectangle, all in cells.
//!
//! Every coordinate in this package counts from zero and is a `u16`, which is
//! the largest grid a terminal has any business handing out. Nothing here
//! allocates and nothing here clips against a screen: clipping is the
//! window's job, because only a window knows what it is inside of.

const std = @import("std");

/// A place on the grid, counted from the top-left at zero.
pub const Point = struct {
    /// The column.
    col: u16 = 0,
    /// The row.
    row: u16 = 0,
};

/// How big something is, in cells.
pub const Size = struct {
    /// How many columns.
    cols: u16 = 0,
    /// How many rows.
    rows: u16 = 0,

    /// How many cells a grid this size holds.
    pub fn area(s: Size) usize {
        return @as(usize, s.cols) * @as(usize, s.rows);
    }

    /// Whether either side is zero, in which case there is nothing to draw.
    pub fn isEmpty(s: Size) bool {
        return s.cols == 0 or s.rows == 0;
    }
};

/// A rectangle of cells: where it starts and how big it is.
pub const Rect = struct {
    /// The leftmost column.
    col: u16 = 0,
    /// The topmost row.
    row: u16 = 0,
    /// How many columns wide.
    cols: u16 = 0,
    /// How many rows tall.
    rows: u16 = 0,

    /// The rectangle covering a whole grid of this size.
    pub fn fromSize(s: Size) Rect {
        return .{ .col = 0, .row = 0, .cols = s.cols, .rows = s.rows };
    }

    /// One past the rightmost column.
    pub fn right(r: Rect) u32 {
        return @as(u32, r.col) + r.cols;
    }

    /// One past the bottom row.
    pub fn bottom(r: Rect) u32 {
        return @as(u32, r.row) + r.rows;
    }

    /// Whether the rectangle holds no cells.
    pub fn isEmpty(r: Rect) bool {
        return r.cols == 0 or r.rows == 0;
    }

    /// Whether a place is inside.
    pub fn contains(r: Rect, p: Point) bool {
        return p.col >= r.col and p.row >= r.row and p.col < r.right() and p.row < r.bottom();
    }

    /// The part of this rectangle that is also inside `other`.
    pub fn intersect(r: Rect, other: Rect) Rect {
        const col = @max(r.col, other.col);
        const row = @max(r.row, other.row);
        const right_edge = @min(r.right(), other.right());
        const bottom_edge = @min(r.bottom(), other.bottom());
        if (right_edge <= col or bottom_edge <= row) return .{ .col = col, .row = row };
        return .{
            .col = col,
            .row = row,
            .cols = @intCast(right_edge - col),
            .rows = @intCast(bottom_edge - row),
        };
    }

    /// How big the rectangle is.
    pub fn size(r: Rect) Size {
        return .{ .cols = r.cols, .rows = r.rows };
    }
};

const testing = std.testing;

test "a size knows how many cells it holds" {
    try testing.expectEqual(@as(usize, 4800), (Size{ .cols = 120, .rows = 40 }).area());
    try testing.expect((Size{ .cols = 0, .rows = 40 }).isEmpty());
    try testing.expect(!(Size{ .cols = 1, .rows = 1 }).isEmpty());
}

test "a rectangle's edges are one past its last cell" {
    const r: Rect = .{ .col = 3, .row = 4, .cols = 5, .rows = 6 };
    try testing.expectEqual(@as(u32, 8), r.right());
    try testing.expectEqual(@as(u32, 10), r.bottom());
    try testing.expect(r.contains(.{ .col = 3, .row = 4 }));
    try testing.expect(r.contains(.{ .col = 7, .row = 9 }));
    try testing.expect(!r.contains(.{ .col = 8, .row = 9 }));
    try testing.expect(!r.contains(.{ .col = 2, .row = 4 }));
}

test "two rectangles that overlap intersect in the overlap" {
    const a: Rect = .{ .col = 0, .row = 0, .cols = 10, .rows = 10 };
    const b: Rect = .{ .col = 5, .row = 5, .cols = 10, .rows = 10 };
    try testing.expectEqual(Rect{ .col = 5, .row = 5, .cols = 5, .rows = 5 }, a.intersect(b));
}

test "two rectangles that miss each other intersect in nothing" {
    const a: Rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 4 };
    const b: Rect = .{ .col = 9, .row = 9, .cols = 4, .rows = 4 };
    try testing.expect(a.intersect(b).isEmpty());
    try testing.expect(b.intersect(a).isEmpty());
}

test "a rectangle at the far edge of the grid does not overflow" {
    const max = std.math.maxInt(u16);
    const r: Rect = .{ .col = max - 1, .row = max - 1, .cols = 4, .rows = 4 };
    try testing.expectEqual(@as(u32, max + 3), r.right());
    const clipped = r.intersect(.fromSize(.{ .cols = max, .rows = max }));
    try testing.expectEqual(@as(u16, 1), clipped.cols);
    try testing.expectEqual(@as(u16, 1), clipped.rows);
}
