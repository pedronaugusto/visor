//! Splitting a rectangle, and the constraints that decide how.
//!
//! Splits are arithmetic, not a solver. A constraint system with a general
//! solver is a package of its own, and the libraries that ship one end up
//! defending it with a cache because constructing it costs more than drawing
//! the frame it was for. What a screen layer owes is this: fixed sizes,
//! percentages, floors, ceilings and shares of what is left, nested as deep
//! as the caller likes. Every split here is one pass over the constraints
//! and allocates nothing.
//!
//! The rules, so that a surprising result can be read off rather than
//! guessed at:
//!
//! - `fixed` and `percent` take their size before anything else.
//! - `min` takes its floor first and then shares what is left.
//! - `max` takes nothing first and then shares what is left, up to its
//!   ceiling.
//! - `fill` takes nothing first and then shares what is left, in proportion
//!   to its weight.
//! - A split that asks for more than there is loses it from the last part
//!   first.
//! - Cells that cannot be divided evenly go to the earlier parts.

const std = @import("std");
const visor = @import("visor");

const Rect = visor.Rect;

/// Which way a split runs.
pub const Direction = enum {
    /// Into columns, left to right.
    horizontal,
    /// Into rows, top to bottom.
    vertical,
};

/// Where something sits in the space it was given.
pub const Align = enum {
    /// Against the left edge.
    left,
    /// In the middle, the odd column to the left.
    center,
    /// Against the right edge.
    right,
};

/// How much of an axis one part of a split takes.
pub const Constraint = union(enum) {
    /// Exactly this many cells.
    fixed: u16,
    /// This many hundredths of the axis, before anything is shared out.
    percent: u8,
    /// At least this many cells, and a share of whatever is left.
    min: u16,
    /// A share of whatever is left, but never more than this many cells.
    max: u16,
    /// A share of whatever is left, weighted against the other fills. A
    /// weight of zero takes nothing.
    fill: u16,
};

/// Cells taken off the four sides of a rectangle.
pub const Padding = struct {
    /// Cells off the left.
    left: u16 = 0,
    /// Cells off the right.
    right: u16 = 0,
    /// Cells off the top.
    top: u16 = 0,
    /// Cells off the bottom.
    bottom: u16 = 0,

    /// The same number of cells off every side.
    pub fn all(n: u16) Padding {
        return .{ .left = n, .right = n, .top = n, .bottom = n };
    }

    /// `n` off the left and right, nothing above or below.
    pub fn horizontal(n: u16) Padding {
        return .{ .left = n, .right = n };
    }

    /// `n` above and below, nothing left or right.
    pub fn vertical(n: u16) Padding {
        return .{ .top = n, .bottom = n };
    }

    /// What is left of `r` after the padding is taken off. Never wider or
    /// taller than `r`, and empty rather than negative.
    pub fn apply(p: Padding, r: Rect) Rect {
        const cols = r.cols -| p.left -| p.right;
        const rows = r.rows -| p.top -| p.bottom;
        if (cols == 0 or rows == 0) return .{ .col = r.col, .row = r.row };
        return .{
            .col = r.col +| @min(p.left, r.cols),
            .row = r.row +| @min(p.top, r.rows),
            .cols = cols,
            .rows = rows,
        };
    }
};

/// A rectangle split into parts along one axis.
pub const Layout = struct {
    /// Which way the parts run.
    direction: Direction = .vertical,
    /// One per part.
    constraints: []const Constraint,
    /// Cells left empty between two parts.
    spacing: u16 = 0,
    /// Cells taken off every side before the split.
    margin: Padding = .{},

    /// Columns, left to right.
    pub fn horizontal(constraints: []const Constraint) Layout {
        return .{ .direction = .horizontal, .constraints = constraints };
    }

    /// Rows, top to bottom.
    pub fn vertical(constraints: []const Constraint) Layout {
        return .{ .direction = .vertical, .constraints = constraints };
    }

    /// The parts, written into `out` and returned as a slice of it.
    ///
    /// Writes one rectangle per constraint, or as many as `out` holds. The
    /// parts are in order, never overlap, and together with the spacing
    /// between them cover the whole of `area` unless the constraints asked
    /// for less than there is.
    pub fn split(l: Layout, area: Rect, out: []Rect) []Rect {
        const n = @min(l.constraints.len, out.len);
        if (n == 0) return out[0..0];
        const inner = l.margin.apply(area);
        const axis = switch (l.direction) {
            .horizontal => inner.cols,
            .vertical => inner.rows,
        };
        const gaps: u16 = @intCast(@min(
            @as(u32, l.spacing) * (n - 1),
            @as(u32, std.math.maxInt(u16)),
        ));
        const total = axis -| gaps;

        // What each part takes before anything is shared out.
        for (l.constraints[0..n], out[0..n]) |c, *r| {
            const want: u16 = switch (c) {
                .fixed => |v| v,
                .percent => |p| @intCast(@as(u32, axis) * @min(p, 100) / 100),
                .min => |v| v,
                .max, .fill => 0,
            };
            l.setAxis(r, want);
        }

        // More than there is: the last parts lose it.
        var taken: u32 = 0;
        for (out[0..n]) |r| taken += l.axisOf(r);
        if (taken > total) {
            var over = taken - total;
            var i = n;
            while (i > 0 and over > 0) {
                i -= 1;
                const have = l.axisOf(out[i]);
                const drop: u16 = @intCast(@min(over, have));
                l.setAxis(&out[i], have - drop);
                over -= drop;
            }
            taken = total;
        }

        // What is left, shared among the parts that asked for a share.
        var left: u16 = @intCast(total - taken);
        while (left > 0) {
            var denom: u32 = 0;
            for (l.constraints[0..n], out[0..n]) |c, r| {
                if (l.axisOf(r) < capOf(c)) denom += weightOf(c);
            }
            if (denom == 0) break;

            var granted: u16 = 0;
            for (l.constraints[0..n], out[0..n]) |c, *r| {
                const have = l.axisOf(r.*);
                const cap = capOf(c);
                if (have >= cap) continue;
                const w = weightOf(c);
                if (w == 0) continue;
                const share: u16 = @intCast(@as(u32, left) * w / denom);
                const grant = @min(share, cap - have);
                l.setAxis(r, have + grant);
                granted += grant;
            }
            left -= granted;

            // The cells that would not divide, to the earlier parts.
            var spare = left;
            for (l.constraints[0..n], out[0..n]) |c, *r| {
                if (spare == 0) break;
                const have = l.axisOf(r.*);
                const cap = capOf(c);
                if (have >= cap or weightOf(c) == 0) continue;
                l.setAxis(r, have + 1);
                spare -= 1;
            }
            if (granted == 0 and spare == left) break;
            left = spare;
        }

        // And where each part starts.
        var at: u16 = switch (l.direction) {
            .horizontal => inner.col,
            .vertical => inner.row,
        };
        for (out[0..n]) |*r| {
            switch (l.direction) {
                .horizontal => {
                    r.col = at;
                    r.row = inner.row;
                    r.rows = inner.rows;
                },
                .vertical => {
                    r.row = at;
                    r.col = inner.col;
                    r.cols = inner.cols;
                },
            }
            at +|= l.axisOf(r.*) +| l.spacing;
            if (r.cols == 0 or r.rows == 0) {
                r.cols = 0;
                r.rows = 0;
            }
        }
        return out[0..n];
    }

    /// The parts as an array, for the common case of a split whose shape is
    /// known where it is written.
    ///
    /// Asserts there are exactly `n` constraints, which a `comptime` length
    /// makes a compile-time-known mistake at every call site that has one.
    pub fn splitFixed(l: Layout, comptime n: usize, area: Rect) [n]Rect {
        std.debug.assert(l.constraints.len == n);
        var out: [n]Rect = @splat(.{});
        _ = l.split(area, &out);
        return out;
    }

    /// How long a rectangle is along the split's axis.
    fn axisOf(l: Layout, r: Rect) u16 {
        return switch (l.direction) {
            .horizontal => r.cols,
            .vertical => r.rows,
        };
    }

    /// Makes a rectangle that long along the split's axis.
    fn setAxis(l: Layout, r: *Rect, n: u16) void {
        switch (l.direction) {
            .horizontal => r.cols = n,
            .vertical => r.rows = n,
        }
    }

    /// How much of what is left a constraint asks for, against the others.
    fn weightOf(c: Constraint) u16 {
        return switch (c) {
            .fixed, .percent => 0,
            .min, .max => 1,
            .fill => |w| w,
        };
    }

    /// The most a constraint can grow to.
    fn capOf(c: Constraint) u16 {
        return switch (c) {
            .fixed => |v| v,
            .percent, .min, .fill => std.math.maxInt(u16),
            .max => |v| v,
        };
    }
};

/// A rectangle of `size` placed in `area`, aligned along one axis.
///
/// What a title, a label or a centred dialogue needs: the caller says how
/// big and where, and gets back the rectangle to draw in, clipped to the
/// area it was given.
pub fn place(area: Rect, size: visor.Size, horizontal_align: Align, vertical_align: Align) Rect {
    const cols = @min(size.cols, area.cols);
    const rows = @min(size.rows, area.rows);
    const col = area.col + offset(area.cols, cols, horizontal_align);
    const row = area.row + offset(area.rows, rows, vertical_align);
    return .{ .col = col, .row = row, .cols = cols, .rows = rows };
}

/// How far into `outer` something `inner` long starts.
pub fn offset(outer: u16, inner: u16, how: Align) u16 {
    return switch (how) {
        .left => 0,
        .center => (outer -| inner) / 2,
        .right => outer -| inner,
    };
}

const std_testing = std.testing;

/// The whole grid as a rectangle, for the tests below.
fn grid(cols: u16, rows: u16) Rect {
    return .{ .col = 0, .row = 0, .cols = cols, .rows = rows };
}

test "fixed parts take what they asked for and a fill takes the rest" {
    const parts = (Layout.horizontal(&.{
        .{ .fixed = 3 },
        .{ .fill = 1 },
        .{ .fixed = 2 },
    })).splitFixed(3, grid(10, 4));
    try std_testing.expectEqual(Rect{ .col = 0, .row = 0, .cols = 3, .rows = 4 }, parts[0]);
    try std_testing.expectEqual(Rect{ .col = 3, .row = 0, .cols = 5, .rows = 4 }, parts[1]);
    try std_testing.expectEqual(Rect{ .col = 8, .row = 0, .cols = 2, .rows = 4 }, parts[2]);
}

test "two fills share what is left in proportion to their weights" {
    const parts = (Layout.vertical(&.{
        .{ .fill = 1 },
        .{ .fill = 3 },
    })).splitFixed(2, grid(6, 12));
    try std_testing.expectEqual(@as(u16, 3), parts[0].rows);
    try std_testing.expectEqual(@as(u16, 9), parts[1].rows);
    try std_testing.expectEqual(@as(u16, 3), parts[1].row);
}

test "a percentage is of the whole axis, before anything is shared" {
    const parts = (Layout.horizontal(&.{
        .{ .percent = 25 },
        .{ .fill = 1 },
    })).splitFixed(2, grid(20, 1));
    try std_testing.expectEqual(@as(u16, 5), parts[0].cols);
    try std_testing.expectEqual(@as(u16, 15), parts[1].cols);
}

test "a floor is taken first and then shares what is left" {
    const parts = (Layout.horizontal(&.{
        .{ .min = 4 },
        .{ .fill = 1 },
    })).splitFixed(2, grid(10, 1));
    try std_testing.expectEqual(@as(u16, 7), parts[0].cols);
    try std_testing.expectEqual(@as(u16, 3), parts[1].cols);
}

test "a ceiling shares what is left and stops at its own number" {
    const parts = (Layout.horizontal(&.{
        .{ .max = 3 },
        .{ .fill = 1 },
    })).splitFixed(2, grid(10, 1));
    try std_testing.expectEqual(@as(u16, 3), parts[0].cols);
    try std_testing.expectEqual(@as(u16, 7), parts[1].cols);
}

test "spacing is taken out of the axis before the parts are sized" {
    const parts = (Layout{
        .direction = .horizontal,
        .constraints = &.{ .{ .fill = 1 }, .{ .fill = 1 } },
        .spacing = 2,
    }).splitFixed(2, grid(12, 1));
    try std_testing.expectEqual(@as(u16, 5), parts[0].cols);
    try std_testing.expectEqual(@as(u16, 0), parts[0].col);
    try std_testing.expectEqual(@as(u16, 5), parts[1].cols);
    try std_testing.expectEqual(@as(u16, 7), parts[1].col);
}

test "a split that asks for more than there is loses it from the last part" {
    const parts = (Layout.horizontal(&.{
        .{ .fixed = 6 },
        .{ .fixed = 6 },
        .{ .fixed = 6 },
    })).splitFixed(3, grid(8, 1));
    try std_testing.expectEqual(@as(u16, 6), parts[0].cols);
    try std_testing.expectEqual(@as(u16, 2), parts[1].cols);
    try std_testing.expectEqual(@as(u16, 0), parts[2].cols);
}

test "the cells that will not divide go to the earlier parts" {
    const parts = (Layout.vertical(&.{
        .{ .fill = 1 },
        .{ .fill = 1 },
        .{ .fill = 1 },
    })).splitFixed(3, grid(1, 8));
    try std_testing.expectEqual(@as(u16, 3), parts[0].rows);
    try std_testing.expectEqual(@as(u16, 3), parts[1].rows);
    try std_testing.expectEqual(@as(u16, 2), parts[2].rows);
}

test "a margin comes off every side before the split" {
    const parts = (Layout{
        .direction = .vertical,
        .constraints = &.{.{ .fill = 1 }},
        .margin = .all(1),
    }).splitFixed(1, grid(10, 6));
    try std_testing.expectEqual(Rect{ .col = 1, .row = 1, .cols = 8, .rows = 4 }, parts[0]);
}

test "splits nest, because a part is a rectangle like any other" {
    const rows = (Layout.vertical(&.{
        .{ .fixed = 1 },
        .{ .fill = 1 },
    })).splitFixed(2, grid(20, 10));
    const columns = (Layout.horizontal(&.{
        .{ .percent = 50 },
        .{ .fill = 1 },
    })).splitFixed(2, rows[1]);
    try std_testing.expectEqual(Rect{ .col = 0, .row = 1, .cols = 10, .rows = 9 }, columns[0]);
    try std_testing.expectEqual(Rect{ .col = 10, .row = 1, .cols = 10, .rows = 9 }, columns[1]);
}

test "padding never gives back more than it was given" {
    const r = (Padding.all(9)).apply(grid(4, 4));
    try std_testing.expect(r.isEmpty());
    try std_testing.expectEqual(
        Rect{ .col = 2, .row = 0, .cols = 6, .rows = 4 },
        (Padding.horizontal(2)).apply(grid(10, 4)),
    );
}

test "a rectangle is placed where the alignment says" {
    const r = place(grid(10, 4), .{ .cols = 4, .rows = 2 }, .center, .right);
    try std_testing.expectEqual(Rect{ .col = 3, .row = 2, .cols = 4, .rows = 2 }, r);
    try std_testing.expectEqual(@as(u16, 0), offset(10, 20, .right));
}

/// Every split, whatever the constraints: the parts are in order, none
/// overlaps another, none leaves the area, and together with the spacing
/// they never claim more of the axis than there is.
fn splitHolds(smith: *std.testing.Smith) !void {
    var constraints: [8]Constraint = undefined;
    const n = smith.valueRangeAtMost(u8, 1, 8);
    for (constraints[0..n]) |*c| {
        c.* = switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0 => .{ .fixed = smith.valueRangeAtMost(u16, 0, 40) },
            1 => .{ .percent = smith.valueRangeAtMost(u8, 0, 120) },
            2 => .{ .min = smith.valueRangeAtMost(u16, 0, 40) },
            3 => .{ .max = smith.valueRangeAtMost(u16, 0, 40) },
            else => .{ .fill = smith.valueRangeAtMost(u16, 0, 4) },
        };
    }
    const whole: Rect = .{
        .col = smith.valueRangeAtMost(u16, 0, 5),
        .row = smith.valueRangeAtMost(u16, 0, 5),
        .cols = smith.valueRangeAtMost(u16, 0, 40),
        .rows = smith.valueRangeAtMost(u16, 0, 20),
    };
    const l: Layout = .{
        .direction = if (smith.value(bool)) .horizontal else .vertical,
        .constraints = constraints[0..n],
        .spacing = smith.valueRangeAtMost(u16, 0, 3),
        .margin = .all(smith.valueRangeAtMost(u16, 0, 2)),
    };

    var out: [8]Rect = @splat(.{});
    const parts = l.split(whole, out[0..n]);
    try std_testing.expectEqual(@as(usize, n), parts.len);

    var claimed: u32 = 0;
    var edge: u32 = switch (l.direction) {
        .horizontal => whole.col,
        .vertical => whole.row,
    };
    for (parts) |r| {
        try std_testing.expect(r.right() <= whole.right());
        try std_testing.expect(r.bottom() <= whole.bottom());
        const start = switch (l.direction) {
            .horizontal => @as(u32, r.col),
            .vertical => @as(u32, r.row),
        };
        try std_testing.expect(start >= edge);
        edge = switch (l.direction) {
            .horizontal => r.right(),
            .vertical => r.bottom(),
        };
        claimed += l.axisOf(r);
    }
    const axis: u32 = switch (l.direction) {
        .horizontal => l.margin.apply(whole).cols,
        .vertical => l.margin.apply(whole).rows,
    };
    try std_testing.expect(claimed <= axis);
}

test "a split of anything by anything stays inside what it was given" {
    try std.testing.fuzz(void{}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try splitHolds(smith);
        }
    }.one, .{ .corpus = &corpus });
}

/// Deterministic inputs for the split property, generated rather than kept
/// as files so that every optimize mode and every machine runs the same
/// ones.
const corpus: [128][]const u8 = blk: {
    @setEvalBranchQuota(1 << 20);
    var data: [128][48]u8 = undefined;
    var x: u64 = 0x2545f4914f6cdd1d;
    for (&data) |*entry| {
        for (entry) |*b| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            b.* = @truncate(x);
        }
    }
    const frozen = data;
    var slices: [128][]const u8 = undefined;
    for (&slices, 0..) |*s, i| s.* = frozen[i][0..];
    break :blk slices;
};
