//! What a property drew, counted.
//!
//! A property that draws its sizes and operations from the source of a
//! `shakedown.check` case could, if its generator were wrong, draw the same
//! small case every time and pass. `Spread` is how a suite proves it does
//! not: each property keeps one per question and a test asserts the cases
//! drew the whole range.
//!
//! This file is its own module so that the suite inside the package and the
//! conformance build outside it count the same way.

const std = @import("std");

/// What a property drew for one question, over every case it was given:
/// the least and the most, and which of the first sixty-four values came
/// up. A suite asserts on it that the cases explore.
pub const Spread = struct {
    /// The least value drawn.
    least: i64 = std.math.maxInt(i64),
    /// The most.
    most: i64 = std.math.minInt(i64),
    /// Which values from `base` to `base + 63` were drawn.
    seen: u64 = 0,
    /// Where `seen` counts from.
    base: i64 = 0,
    /// How many were drawn.
    count: u64 = 0,

    /// One draw.
    pub fn add(s: *Spread, v: anytype) void {
        const x: i64 = @intCast(v);
        s.least = @min(s.least, x);
        s.most = @max(s.most, x);
        s.count += 1;
        const at = x - s.base;
        if (at >= 0 and at < 64) s.seen |= @as(u64, 1) << @intCast(at);
    }

    /// Whether every value from `lo` to `hi` came up, both included.
    pub fn covers(s: Spread, lo: i64, hi: i64) bool {
        std.debug.assert(lo >= s.base);
        std.debug.assert(hi - s.base < 64);
        std.debug.assert(lo <= hi);
        var v = lo;
        while (v <= hi) : (v += 1) {
            if (s.seen & (@as(u64, 1) << @intCast(v - s.base)) == 0) return false;
        }
        return true;
    }
};

const testing = std.testing;

test "a spread remembers the least, the most and which small values came up" {
    var spread: Spread = .{};
    for ([_]u8{ 3, 5, 3, 9 }) |v| spread.add(v);
    try testing.expectEqual(@as(i64, 3), spread.least);
    try testing.expectEqual(@as(i64, 9), spread.most);
    try testing.expectEqual(@as(u64, 4), spread.count);
    try testing.expect(spread.covers(3, 3));
    try testing.expect(spread.covers(5, 5));
    try testing.expect(!spread.covers(3, 5));
    try testing.expect(!spread.covers(6, 8));
    try testing.expect(spread.covers(9, 9));
}
