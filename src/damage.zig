//! Which cells changed since the last frame was written.
//!
//! One span a row: the first and the last column touched, inclusive. A row
//! nothing touched is empty and the renderer skips it without reading a cell,
//! which is what keeps a frame that changed one cell from scanning the grid.
//!
//! The map is exact in both directions. Marking is done by `Screen` only when
//! a write actually changes a cell, so a row is dirty exactly when its
//! contents differ from what was last drawn. Under-reporting is a rendering
//! bug that shows up once a week and cannot be reproduced; over-reporting is
//! a frame that costs more than it should. Both are caught by the grid fuzz.
//!
//! This file never allocates on the write path: the spans are sized once, at
//! `init` and at `resize`.

const std = @import("std");

/// The columns of one row that changed, both ends inside the range.
pub const Span = struct {
    /// The leftmost column touched.
    first: u16,
    /// The rightmost column touched.
    last: u16,
};

/// The dirty map: per row, the first and last column touched.
pub const Damage = struct {
    /// One entry a row. `first > last` means the row is clean.
    rows: []Entry,

    /// A row's span in the form it is stored in, so that a clean row is
    /// representable without a second field.
    pub const Entry = struct {
        first: u16 = std.math.maxInt(u16),
        last: u16 = 0,
    };

    /// A clean map for a grid of `rows` rows.
    pub fn init(gpa: std.mem.Allocator, rows: u16) std.mem.Allocator.Error!Damage {
        const entries = try gpa.alloc(Entry, rows);
        @memset(entries, .{});
        return .{ .rows = entries };
    }

    /// Gives the map back.
    pub fn deinit(d: *Damage, gpa: std.mem.Allocator) void {
        gpa.free(d.rows);
        d.* = .{ .rows = &.{} };
    }

    /// A map for a new number of rows. Everything becomes clean; the caller
    /// damages what it means to keep.
    pub fn resize(d: *Damage, gpa: std.mem.Allocator, rows: u16) std.mem.Allocator.Error!void {
        const entries = try gpa.alloc(Entry, rows);
        @memset(entries, .{});
        gpa.free(d.rows);
        d.rows = entries;
    }

    /// The span of a row, or null when nothing in it changed.
    pub fn row(d: *const Damage, n: u16) ?Span {
        if (n >= d.rows.len) return null;
        const e = d.rows[n];
        if (e.first > e.last) return null;
        return .{ .first = e.first, .last = e.last };
    }

    /// Records that a cell changed.
    pub fn mark(d: *Damage, col: u16, r: u16) void {
        if (r >= d.rows.len) return;
        const e = &d.rows[r];
        if (e.first > e.last) {
            e.* = .{ .first = col, .last = col };
            return;
        }
        if (col < e.first) e.first = col;
        if (col > e.last) e.last = col;
    }

    /// Records that a range of columns in a row changed, both ends inside.
    pub fn markSpan(d: *Damage, first: u16, last: u16, r: u16) void {
        if (r >= d.rows.len or first > last) return;
        const e = &d.rows[r];
        if (first < e.first) e.first = first;
        if (last > e.last) e.last = last;
    }

    /// Records that every cell of every row changed.
    pub fn markAll(d: *Damage, cols: u16) void {
        if (cols == 0) {
            d.clear();
            return;
        }
        @memset(d.rows, .{ .first = 0, .last = cols - 1 });
    }

    /// Everything clean, which is what `draw` leaves behind.
    pub fn clear(d: *Damage) void {
        @memset(d.rows, .{});
    }

    /// Whether any row is dirty.
    pub fn any(d: *const Damage) bool {
        for (d.rows) |e| if (e.first <= e.last) return true;
        return false;
    }

    /// How many rows are dirty.
    pub fn count(d: *const Damage) usize {
        var n: usize = 0;
        for (d.rows) |e| {
            if (e.first <= e.last) n += 1;
        }
        return n;
    }
};

const testing = std.testing;

test "a fresh map is clean" {
    var d: Damage = try .init(testing.allocator, 4);
    defer d.deinit(testing.allocator);
    for (0..4) |r| try testing.expectEqual(@as(?Span, null), d.row(@intCast(r)));
    try testing.expect(!d.any());
    try testing.expectEqual(@as(usize, 0), d.count());
}

test "a mark widens the span in both directions" {
    var d: Damage = try .init(testing.allocator, 4);
    defer d.deinit(testing.allocator);

    d.mark(7, 1);
    try testing.expectEqual(Span{ .first = 7, .last = 7 }, d.row(1).?);
    d.mark(9, 1);
    try testing.expectEqual(Span{ .first = 7, .last = 9 }, d.row(1).?);
    d.mark(2, 1);
    try testing.expectEqual(Span{ .first = 2, .last = 9 }, d.row(1).?);
    try testing.expectEqual(@as(?Span, null), d.row(0));
    try testing.expectEqual(@as(usize, 1), d.count());
}

test "a mark at column zero is not mistaken for a clean row" {
    var d: Damage = try .init(testing.allocator, 2);
    defer d.deinit(testing.allocator);
    d.mark(0, 0);
    try testing.expectEqual(Span{ .first = 0, .last = 0 }, d.row(0).?);
    try testing.expect(d.any());
}

test "a span marks both ends at once" {
    var d: Damage = try .init(testing.allocator, 2);
    defer d.deinit(testing.allocator);
    d.markSpan(3, 5, 0);
    try testing.expectEqual(Span{ .first = 3, .last = 5 }, d.row(0).?);
    d.markSpan(9, 2, 0);
    try testing.expectEqual(Span{ .first = 3, .last = 5 }, d.row(0).?);
}

test "everything, then nothing" {
    var d: Damage = try .init(testing.allocator, 3);
    defer d.deinit(testing.allocator);
    d.markAll(10);
    try testing.expectEqual(@as(usize, 3), d.count());
    try testing.expectEqual(Span{ .first = 0, .last = 9 }, d.row(2).?);
    d.clear();
    try testing.expect(!d.any());
}

test "a mark outside the map is dropped rather than a crash" {
    var d: Damage = try .init(testing.allocator, 2);
    defer d.deinit(testing.allocator);
    d.mark(0, 9);
    d.markSpan(0, 1, 9);
    try testing.expect(!d.any());
    try testing.expectEqual(@as(?Span, null), d.row(9));
}

test "a resized map is clean and the right length" {
    var d: Damage = try .init(testing.allocator, 2);
    defer d.deinit(testing.allocator);
    d.markAll(4);
    try d.resize(testing.allocator, 5);
    try testing.expectEqual(@as(usize, 5), d.rows.len);
    try testing.expect(!d.any());
}
