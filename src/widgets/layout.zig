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
    pub fn apply(p: Padding, area: visor.Rect) visor.Rect {
        return p.applyLogical(bounded(area)).clipped();
    }

    fn applyLogical(p: Padding, r: visor.Rect) LogicalRect {
        const cols = r.cols -| p.left -| p.right;
        const rows = r.rows -| p.top -| p.bottom;
        if (cols == 0 or rows == 0) return .{ .col = r.col, .row = r.row };
        return .{
            .col = @as(u32, r.col) + @min(p.left, r.cols),
            .row = @as(u32, r.row) + @min(p.top, r.rows),
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
    pub fn split(l: Layout, area: visor.Rect, out: []visor.Rect) []visor.Rect {
        const n = @min(l.constraints.len, out.len);
        if (n == 0) return out[0..0];
        // Divide the requested area before clipping its parts.
        const inner = l.margin.applyLogical(area);
        const axis = switch (l.direction) {
            .horizontal => inner.cols,
            .vertical => inner.rows,
        };
        const gaps: u16 = @intCast(@min(
            @as(u128, l.spacing) * (n - 1),
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
        var taken: u128 = 0;
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
        l.shareOut(l.constraints[0..n], out[0..n], @intCast(total - taken));
        // The parts never take more than the axis holds after the gaps.
        if (std.debug.runtime_safety) {
            var sum: u128 = 0;
            for (out[0..n]) |r| sum += l.axisOf(r);
            std.debug.assert(sum <= total);
        }

        // And where each part starts.
        //
        // Clamped to the end of the area, because the spacing between the
        // parts is charged whether or not there was room for it: a split
        // into four with three cells between them, in two cells, has
        // nothing left for any part and must not put one past the edge.
        const coordinate_end: u32 = @as(u32, std.math.maxInt(u16)) + 1;
        const limit: u32 = switch (l.direction) {
            .horizontal => @min(inner.right(), coordinate_end),
            .vertical => @min(inner.bottom(), coordinate_end),
        };
        var at: u32 = switch (l.direction) {
            .horizontal => inner.col,
            .vertical => inner.row,
        };
        for (out[0..n]) |*r| {
            const start = @min(at, limit);
            const size: u16 = @intCast(@min(l.axisOf(r.*), limit - start));
            const coordinate: u16 = @intCast(@min(start, std.math.maxInt(u16)));
            switch (l.direction) {
                .horizontal => {
                    r.col = coordinate;
                    r.cols = size;
                    r.row = @intCast(@min(inner.row, std.math.maxInt(u16)));
                    r.rows = inner.clipped().rows;
                },
                .vertical => {
                    r.row = coordinate;
                    r.rows = size;
                    r.col = @intCast(@min(inner.col, std.math.maxInt(u16)));
                    r.cols = inner.clipped().cols;
                },
            }
            at = start + size + l.spacing;
            if (r.cols == 0 or r.rows == 0) {
                r.cols = 0;
                r.rows = 0;
            }
        }
        return out[0..n];
    }

    /// What is left after every part took what it asked for, shared among
    /// the parts that asked for a share, by weight and up to their caps.
    fn shareOut(l: Layout, constraints: []const Constraint, parts: []visor.Rect, room: u16) void {
        const before = l.axisSum(parts);
        var left = room;
        while (left > 0) {
            var denom: u128 = 0;
            for (constraints, parts) |c, r| {
                if (l.axisOf(r) < capOf(c)) denom += weightOf(c);
            }
            if (denom == 0) break;

            var granted: u16 = 0;
            for (constraints, parts) |c, *r| {
                const have = l.axisOf(r.*);
                const cap = capOf(c);
                if (have >= cap) continue;
                const w = weightOf(c);
                if (w == 0) continue;
                const share: u16 = @intCast(@as(u128, left) * w / denom);
                const grant = @min(share, cap - have);
                l.setAxis(r, have + grant);
                granted += grant;
            }
            left -= granted;

            // The cells that would not divide, to the earlier parts.
            var spare = left;
            for (constraints, parts) |c, *r| {
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
        // The parts gained what was handed out, and no more than the room.
        std.debug.assert(l.axisSum(parts) == before + (room - left));
    }

    /// How much of the axis the parts take between them.
    fn axisSum(l: Layout, parts: []const visor.Rect) u128 {
        var sum: u128 = 0;
        for (parts) |r| sum += l.axisOf(r);
        return sum;
    }

    /// The parts as an array, for the common case of a split whose shape is
    /// known where it is written.
    ///
    /// Asserts there are exactly `n` constraints, which a `comptime` length
    /// makes a compile-time-known mistake at every call site that has one.
    pub fn splitFixed(l: Layout, comptime n: usize, area: visor.Rect) [n]visor.Rect {
        std.debug.assert(l.constraints.len == n);
        var out: [n]visor.Rect = @splat(.{});
        _ = l.split(area, &out);
        return out;
    }

    /// How many parts of at least `min` cells fit along an axis of `axis`
    /// cells with `spacing` between each two. What a row of columns that
    /// must each hold something readable asks before it decides how many to
    /// show; a program that always shows one clamps the answer itself.
    pub fn fitCount(axis: u16, min: u16, spacing: u16) u16 {
        const per: u32 = @as(u32, min) + spacing;
        if (per == 0) return axis;
        return @intCast((@as(u32, axis) + spacing) / per);
    }

    /// `out.len` parts of one size along `area`, `spacing` between each two,
    /// from the start of it. The cells that do not divide evenly are left
    /// over at the end rather than given to some parts, so every part is
    /// the same size and a grid of them lines up whatever their number.
    pub fn repeat(direction: Direction, requested: visor.Rect, spacing: u16, out: []visor.Rect) []visor.Rect {
        const area = bounded(requested);
        const n = out.len;
        if (n == 0) return out;
        const axis: u32 = switch (direction) {
            .horizontal => area.cols,
            .vertical => area.rows,
        };
        const gaps: u128 = @as(u128, spacing) * (n - 1);
        const size: u128 = if (gaps >= axis) 0 else (axis - gaps) / n;
        for (out, 0..) |*r, i| {
            const at: u32 = @intCast(@min(axis, @as(u128, i) * (size + spacing)));
            const len: u16 = @intCast(@min(size, axis - at));
            r.* = switch (direction) {
                .horizontal => .{ .col = area.col +| @as(u16, @intCast(at)), .row = area.row, .cols = len, .rows = area.rows },
                .vertical => .{ .col = area.col, .row = area.row +| @as(u16, @intCast(at)), .cols = area.cols, .rows = len },
            };
            if (r.cols == 0 or r.rows == 0) {
                r.cols = 0;
                r.rows = 0;
            }
        }
        return out;
    }

    /// How long a rectangle is along the split's axis.
    fn axisOf(l: Layout, r: visor.Rect) u16 {
        return switch (l.direction) {
            .horizontal => r.cols,
            .vertical => r.rows,
        };
    }

    /// Makes a rectangle that long along the split's axis.
    fn setAxis(l: Layout, r: *visor.Rect, n: u16) void {
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
pub fn place(requested: visor.Rect, size: visor.Size, horizontal_align: Align, vertical_align: Align) visor.Rect {
    const area = bounded(requested);
    const cols = @min(size.cols, area.cols);
    const rows = @min(size.rows, area.rows);
    const col: u16 = @intCast(@min(@as(u32, area.col) + offset(area.cols, cols, horizontal_align), std.math.maxInt(u16)));
    const row: u16 = @intCast(@min(@as(u32, area.row) + offset(area.rows, rows, vertical_align), std.math.maxInt(u16)));
    return .{ .col = col, .row = row, .cols = cols, .rows = rows };
}

// A split plans on the requested area, then clips its parts. Its margin
// may start outside u16 coordinates, so keep that position until clipping.
const LogicalRect = struct {
    col: u32,
    row: u32,
    cols: u16 = 0,
    rows: u16 = 0,

    fn right(r: LogicalRect) u32 {
        return r.col + r.cols;
    }

    fn bottom(r: LogicalRect) u32 {
        return r.row + r.rows;
    }

    fn clipped(r: LogicalRect) visor.Rect {
        const end = @as(u32, std.math.maxInt(u16)) + 1;
        const cols: u16 = @intCast(@min(r.cols, end -| r.col));
        const rows: u16 = @intCast(@min(r.rows, end -| r.row));
        return .{
            .col = @intCast(@min(r.col, std.math.maxInt(u16))),
            .row = @intCast(@min(r.row, std.math.maxInt(u16))),
            .cols = if (rows == 0) 0 else cols,
            .rows = if (cols == 0) 0 else rows,
        };
    }
};

// The part of an area whose coordinates can be represented.
fn bounded(area: visor.Rect) visor.Rect {
    return (LogicalRect{ .col = area.col, .row = area.row, .cols = area.cols, .rows = area.rows }).clipped();
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
const corpus = @import("corpus");

/// The whole grid as a rectangle, for the tests below.
fn grid(cols: u16, rows: u16) visor.Rect {
    return .{ .col = 0, .row = 0, .cols = cols, .rows = rows };
}

test "fixed parts take what they asked for and a fill takes the rest" {
    const parts = (Layout.horizontal(&.{
        .{ .fixed = 3 },
        .{ .fill = 1 },
        .{ .fixed = 2 },
    })).splitFixed(3, grid(10, 4));
    try std_testing.expectEqual(visor.Rect{ .col = 0, .row = 0, .cols = 3, .rows = 4 }, parts[0]);
    try std_testing.expectEqual(visor.Rect{ .col = 3, .row = 0, .cols = 5, .rows = 4 }, parts[1]);
    try std_testing.expectEqual(visor.Rect{ .col = 8, .row = 0, .cols = 2, .rows = 4 }, parts[2]);
}

test "a split clips at the u16 coordinate edge" {
    const parts = (Layout.horizontal(&.{ .{ .fill = 1 }, .{ .fill = 1 } })).splitFixed(2, .{
        .col = std.math.maxInt(u16) - 1,
        .row = 0,
        .cols = 4,
        .rows = 1,
    });
    try std_testing.expectEqual(visor.Rect{
        .col = std.math.maxInt(u16) - 1,
        .row = 0,
        .cols = 2,
        .rows = 1,
    }, parts[0]);
    try std_testing.expectEqual(visor.Rect{
        .col = std.math.maxInt(u16),
        .row = 0,
        .cols = 0,
        .rows = 0,
    }, parts[1]);
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
    try std_testing.expectEqual(visor.Rect{ .col = 1, .row = 1, .cols = 8, .rows = 4 }, parts[0]);
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
    try std_testing.expectEqual(visor.Rect{ .col = 0, .row = 1, .cols = 10, .rows = 9 }, columns[0]);
    try std_testing.expectEqual(visor.Rect{ .col = 10, .row = 1, .cols = 10, .rows = 9 }, columns[1]);
}

test "padding never gives back more than it was given" {
    const r = (Padding.all(9)).apply(grid(4, 4));
    try std_testing.expect(r.isEmpty());
    try std_testing.expectEqual(
        visor.Rect{ .col = 2, .row = 0, .cols = 6, .rows = 4 },
        (Padding.horizontal(2)).apply(grid(10, 4)),
    );
}

test "a rectangle is placed where the alignment says" {
    const r = place(grid(10, 4), .{ .cols = 4, .rows = 2 }, .center, .right);
    try std_testing.expectEqual(visor.Rect{ .col = 3, .row = 2, .cols = 4, .rows = 2 }, r);
    try std_testing.expectEqual(@as(u16, 0), offset(10, 20, .right));
}

/// What the split property drew over the corpus, for the test that proves
/// it explores.
const Tally = struct {
    /// How many parts a split had.
    parts: corpus.Spread = .{},
    /// Which kind of constraint each part took.
    kinds: corpus.Spread = .{},
    /// How long the axis was.
    axis: corpus.Spread = .{},
    /// Which way the split ran, down (0) or across (1).
    direction: corpus.Spread = .{},
};

/// Every split, whatever the constraints: the parts are in order, none
/// overlaps another, none leaves the area, and together with the spacing
/// they never claim more of the axis than there is.
fn splitHolds(smith: *std.testing.Smith, tally: ?*Tally) !void {
    var dice: corpus.Dice = .init(smith);
    var constraints: [8]Constraint = undefined;
    const n = dice.valueRangeAtMost(u8, 1, 8);
    for (constraints[0..n]) |*c| {
        const kind = dice.valueRangeAtMost(u8, 0, 4);
        if (tally) |t| t.kinds.add(kind);
        c.* = switch (kind) {
            0 => .{ .fixed = dice.valueRangeAtMost(u16, 0, 40) },
            1 => .{ .percent = dice.valueRangeAtMost(u8, 0, 120) },
            2 => .{ .min = dice.valueRangeAtMost(u16, 0, 40) },
            3 => .{ .max = dice.valueRangeAtMost(u16, 0, 40) },
            else => .{ .fill = dice.valueRangeAtMost(u16, 0, 4) },
        };
    }
    const whole: visor.Rect = .{
        .col = dice.valueRangeAtMost(u16, 0, 5),
        .row = dice.valueRangeAtMost(u16, 0, 5),
        .cols = dice.valueRangeAtMost(u16, 0, 40),
        .rows = dice.valueRangeAtMost(u16, 0, 20),
    };
    const l: Layout = .{
        .direction = if (dice.value(bool)) .horizontal else .vertical,
        .constraints = constraints[0..n],
        .spacing = dice.valueRangeAtMost(u16, 0, 3),
        .margin = .all(dice.valueRangeAtMost(u16, 0, 2)),
    };
    if (tally) |t| {
        t.parts.add(n);
        t.direction.add(@intFromBool(l.direction == .horizontal));
        t.axis.add(if (l.direction == .horizontal) whole.cols else whole.rows);
    }

    var out: [8]visor.Rect = @splat(.{});
    const parts = l.split(whole, out[0..n]);
    if (parts.len != n) return error.WrongNumberOfParts;

    var claimed: u32 = 0;
    var edge: u32 = switch (l.direction) {
        .horizontal => whole.col,
        .vertical => whole.row,
    };
    for (parts) |r| {
        if (r.right() > whole.right() or r.bottom() > whole.bottom()) {
            return error.PartLeftTheArea;
        }
        const start = switch (l.direction) {
            .horizontal => @as(u32, r.col),
            .vertical => @as(u32, r.row),
        };
        if (start < edge) return error.PartsOverlap;
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
    if (claimed > axis) return error.PartsClaimedMoreThanTheAxis;
}

test "a split of anything by anything stays inside what it was given" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            try splitHolds(smith, null);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the split's corpus draws every count, every kind of constraint and both ways" {
    var t: Tally = .{};
    for (corpus.entries) |entry| {
        var smith: std.testing.Smith = .{ .in = entry };
        try splitHolds(&smith, &t);
    }
    try std_testing.expect(t.parts.covers(1, 8));
    try std_testing.expect(t.kinds.covers(0, 4));
    try std_testing.expect(t.direction.covers(0, 1));
    try std_testing.expect(t.axis.least == 0 and t.axis.most >= 30);
}

test "spacing that does not fit leaves no part outside the area" {
    const parts = (Layout{
        .direction = .vertical,
        .constraints = &.{ .{ .fill = 1 }, .{ .fill = 1 }, .{ .fill = 1 }, .{ .fill = 1 } },
        .spacing = 3,
    }).splitFixed(4, grid(4, 2));
    for (parts) |r| {
        try std_testing.expect(r.bottom() <= 2);
        try std_testing.expect(r.isEmpty());
    }
}

test "as many columns as fit, each at least so wide, with the spacing between" {
    // 24 wide with 3 between: 51 holds two, 78 three, 23 none.
    try std_testing.expectEqual(@as(u16, 2), Layout.fitCount(51, 24, 3));
    try std_testing.expectEqual(@as(u16, 2), Layout.fitCount(77, 24, 3));
    try std_testing.expectEqual(@as(u16, 3), Layout.fitCount(78, 24, 3));
    try std_testing.expectEqual(@as(u16, 0), Layout.fitCount(23, 24, 3));
    try std_testing.expectEqual(@as(u16, 7), Layout.fitCount(7, 0, 0));
}

test "repeated parts are one size, the spacing between them, the rest left at the end" {
    var out: [3]visor.Rect = undefined;
    const parts = Layout.repeat(.horizontal, .{ .col = 2, .row = 1, .cols = 80, .rows = 5 }, 3, &out);
    // (80 - 6) / 3 = 24, two cells over.
    try std_testing.expectEqual(visor.Rect{ .col = 2, .row = 1, .cols = 24, .rows = 5 }, parts[0]);
    try std_testing.expectEqual(visor.Rect{ .col = 29, .row = 1, .cols = 24, .rows = 5 }, parts[1]);
    try std_testing.expectEqual(visor.Rect{ .col = 56, .row = 1, .cols = 24, .rows = 5 }, parts[2]);

    // Whatever the area, the count and the spacing, every part is inside
    // the area, the same size as the others, and after the one before.
    var area_cols: u16 = 0;
    while (area_cols <= 30) : (area_cols += 1) {
        for (1..6) |n| {
            for (0..4) |spacing| {
                var many: [5]visor.Rect = undefined;
                const area: visor.Rect = .{ .col = 3, .row = 0, .cols = area_cols, .rows = 2 };
                const got = Layout.repeat(.horizontal, area, @intCast(spacing), many[0..n]);
                var edge: u32 = area.col;
                for (got) |r| {
                    try std_testing.expectEqual(got[0].cols, r.cols);
                    if (r.cols == 0) continue;
                    try std_testing.expect(r.col >= edge and r.right() <= area.right());
                    edge = r.right() + @as(u32, @intCast(spacing));
                }
            }
        }
    }
    // And down, the same.
    const rows = Layout.repeat(.vertical, .{ .rows = 7, .cols = 4 }, 1, out[0..2]);
    try std_testing.expectEqual(visor.Rect{ .row = 4, .cols = 4, .rows = 3 }, rows[1]);
}

test "placing and repeating rectangles clip at the u16 coordinate edge" {
    const edge = std.math.maxInt(u16);
    const area: visor.Rect = .{ .col = edge - 2, .row = edge - 2, .cols = 20, .rows = 20 };
    const aligned = place(area, .{ .cols = 2, .rows = 2 }, .right, .right);
    try std.testing.expectEqual(visor.Rect{ .col = edge - 1, .row = edge - 1, .cols = 2, .rows = 2 }, aligned);
    var out: [2]visor.Rect = undefined;
    _ = Layout.repeat(.horizontal, area, 1, &out);
    for (out) |r| {
        try std.testing.expect(r.right() <= @as(u32, edge) + 1);
        try std.testing.expect(r.bottom() <= @as(u32, edge) + 1);
        try std.testing.expect(r.cols <= 1);
    }
    _ = Layout.repeat(.vertical, area, 1, &out);
    for (out) |r| {
        try std.testing.expect(r.right() <= @as(u32, edge) + 1);
        try std.testing.expect(r.bottom() <= @as(u32, edge) + 1);
        try std.testing.expect(r.rows <= 1);
    }
    const padded = Padding.all(1).apply(area);
    try std.testing.expectEqual(visor.Rect{ .col = edge - 1, .row = edge - 1, .cols = 1, .rows = 1 }, padded);
}

test "layout part counts stay wide until the available cells are divided" {
    const n = @as(usize, std.math.maxInt(u16)) + 3;
    const constraints = try std.testing.allocator.alloc(Constraint, n);
    defer std.testing.allocator.free(constraints);
    const out = try std.testing.allocator.alloc(visor.Rect, n);
    defer std.testing.allocator.free(out);
    const area: visor.Rect = .{ .cols = 8, .rows = 1 };
    for ([_]Constraint{ .{ .fill = std.math.maxInt(u16) }, .{ .fixed = std.math.maxInt(u16) } }) |constraint| {
        @memset(constraints, constraint);
        _ = Layout.horizontal(constraints).split(area, out);
        var total: usize = 0;
        for (out) |r| {
            try std.testing.expect(r.right() <= area.right());
            total += r.cols;
        }
        try std.testing.expectEqual(@as(usize, 8), total);
    }
    _ = Layout.repeat(.horizontal, area, std.math.maxInt(u16), out);
    for (out) |r| try std.testing.expect(r.isEmpty());
}

test "split margins do not move off-grid content back onto the last coordinate" {
    const edge = std.math.maxInt(u16);
    const layout: Layout = .{ .direction = .horizontal, .constraints = &.{.{ .fill = 1 }}, .margin = .{ .left = 3 } };
    const out = layout.splitFixed(1, .{ .col = edge - 1, .cols = 4, .rows = 1 });
    try std.testing.expect(out[0].isEmpty());
    const vertical: Layout = .{ .constraints = &.{.{ .fill = 1 }}, .margin = .{ .top = 3 } };
    const down = vertical.splitFixed(1, .{ .row = edge - 1, .rows = 4, .cols = 1 });
    try std.testing.expect(down[0].isEmpty());
}
