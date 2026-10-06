//! Which cells changed since the last frame was written.
//!
//! One span a row: the first and the last column touched, inclusive. A row
//! nothing touched is empty and the renderer skips it without reading a cell,
//! which is what keeps a frame that changed one cell from scanning the grid.
//!
//! The map is conservative. Marking is done by `Screen` only when a write
//! changes a cell, but a later write that restores the displayed value cannot
//! remove the mark because the screen deliberately does not keep a previous
//! frame. The renderer owns that baseline and drops unchanged rows before it
//! writes. Under-reporting is a rendering bug; harmless over-reporting costs
//! only a row comparison. The grid fuzz checks that damage never under-reports.
//!
//! This file never allocates on the write path: the spans are sized once, at
//! `init` and at `resize`.

const std = @import("std");
const assert = std.debug.assert;

/// The columns of one row that changed, both ends inside the range.
pub const Span = struct {
    /// The leftmost column touched.
    first: u16,
    /// The rightmost column touched.
    last: u16,
};

/// The dirty map: per row, the first and last column touched.
/// Unmanaged allocation: pass the init allocator to resize and deinit.
pub const Damage = struct {
    /// One entry a row. `first > last` means the row is clean.
    _rows: []Entry,
    /// Dirty rows, kept by the same operations that widen their spans.
    _dirty: usize = 0,

    /// A row's span in the form it is stored in, so that a clean row is
    /// representable without a second field.
    pub const Entry = struct {
        first: u16 = std.math.maxInt(u16),
        last: u16 = 0,
    };

    /// The number of rows this map owns, copied rather than borrowed storage.
    pub fn rowCount(d: *const Damage) usize {
        return d._rows.len;
    }

    /// A clean map for a grid of `rows` rows.
    pub fn init(gpa: std.mem.Allocator, rows: u16) std.mem.Allocator.Error!Damage {
        const entries = try gpa.alloc(Entry, rows);
        @memset(entries, .{});
        return .{ ._rows = entries };
    }

    /// Gives the map back.
    pub fn deinit(d: *Damage, gpa: std.mem.Allocator) void {
        gpa.free(d._rows);
        d.* = undefined;
    }

    /// A map for a new number of rows. Everything becomes clean; the caller
    /// damages what it means to keep.
    pub fn resize(d: *Damage, gpa: std.mem.Allocator, rows: u16) std.mem.Allocator.Error!void {
        const entries = try gpa.alloc(Entry, rows);
        @memset(entries, .{});
        gpa.free(d._rows);
        d._rows = entries;
        d._dirty = 0;
    }

    /// The span of a row, or null when nothing in it changed.
    pub fn row(d: *const Damage, n: u16) ?Span {
        if (n >= d._rows.len) return null;
        const e = d._rows[n];
        if (e.first > e.last) return null;
        return .{ .first = e.first, .last = e.last };
    }

    /// Records that a cell changed.
    pub fn mark(d: *Damage, col: u16, r: u16) void {
        if (r >= d._rows.len) return;
        const e = &d._rows[r];
        if (e.first > e.last) {
            d._dirty += 1;
            e.* = .{ .first = col, .last = col };
            return;
        }
        if (col < e.first) e.first = col;
        if (col > e.last) e.last = col;
    }

    /// Records that a range of columns in a row changed, both ends inside.
    pub fn markSpan(d: *Damage, first: u16, last: u16, r: u16) void {
        if (r >= d._rows.len or first > last) return;
        const e = &d._rows[r];
        if (e.first > e.last) d._dirty += 1;
        if (first < e.first) e.first = first;
        if (last > e.last) e.last = last;
        assert(d._dirty <= d._rows.len);
    }

    /// Records that every cell of every row changed.
    pub fn markAll(d: *Damage, cols: u16) void {
        if (cols == 0) {
            d.clear();
            return;
        }
        @memset(d._rows, .{ .first = 0, .last = cols - 1 });
        d._dirty = d._rows.len;
    }

    /// Everything clean, which is what `draw` leaves behind.
    pub fn clear(d: *Damage) void {
        if (d._dirty == 0) {
            // The count is kept with the spans, so none dirty is every row
            // clean, and there is nothing to write.
            if (std.debug.runtime_safety) for (d._rows) |e| assert(e.first > e.last);
            return;
        }
        @memset(d._rows, .{});
        d._dirty = 0;
    }

    /// Whether any row is dirty.
    pub fn any(d: *const Damage) bool {
        return d._dirty != 0;
    }

    /// How many rows are dirty.
    pub fn count(d: *const Damage) usize {
        return d._dirty;
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
    try testing.expectEqual(@as(usize, 5), d.rowCount());
    try testing.expect(!d.any());
}

test "dirty counts follow repeated marks, clears and resizes" {
    var d: Damage = try .init(testing.allocator, 4);
    defer d.deinit(testing.allocator);
    d.mark(std.math.maxInt(u16), 3);
    d.mark(1, 3);
    d.markSpan(2, 7, 3);
    d.markSpan(3, 2, 0);
    d.mark(0, 4);
    try testing.expectEqual(@as(usize, 1), d.count());
    d.markSpan(4, 4, 1);
    try testing.expectEqual(@as(usize, 2), d.count());
    d.markAll(8);
    try testing.expectEqual(@as(usize, 4), d.count());
    d.mark(0, 0);
    d.markSpan(0, 7, 1);
    try testing.expectEqual(@as(usize, 4), d.count());
    d.clear();
    d.clear();
    try testing.expect(!d.any());
    for (0..4) |row_n| try testing.expect(d.row(@intCast(row_n)) == null);
    d.mark(0, 0);
    try d.resize(testing.allocator, 0);
    d.markAll(8);
    try testing.expectEqual(@as(usize, 0), d.count());
    try d.resize(testing.allocator, 2);
    d.markAll(8);
    d.markAll(0);
    try testing.expect(!d.any());
    try testing.expectEqual(@as(usize, 0), d.count());
}
