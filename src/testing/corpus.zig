//! The inputs the round-trip properties replay on every run, and the
//! generator they are read through.
//!
//! `std.testing.fuzz` runs its corpus on every ordinary test run and searches
//! beyond it only under `zig build test --fuzz`, so a corpus of one would
//! make the property a spot check rather than a gate. These are generated at
//! compile time from a fixed seed rather than kept as files: the same inputs
//! run in every optimize mode, on every machine, and in the conformance
//! build against the second emulator, which is what makes a disagreement
//! between the two emulators reproducible from the seed alone.
//!
//! This file is its own module so that the suite inside the package and the
//! conformance build outside it replay the same bytes. Add to it rather than
//! pruning it: every entry that ever failed is worth keeping.
//!
//! Every property reads its input through `Dice`, never through
//! `std.testing.Smith` directly. On a replayed entry `Smith` reads eight
//! bytes for every value it is asked for and answers the lowest value in
//! range whenever those eight bytes are out of it, which random bytes almost
//! always are, and it ends a loop at the first byte that is not zero: a
//! property asking the input for a size got one column and one row, and for
//! an operation got the first, every entry. `Dice` answers a replayed entry
//! from a generator seeded by it, over the whole range of every question,
//! and hands every question to the fuzzer when the fuzzer is the one asking.
//! `Spread` is how a suite proves that it does: each property keeps one per
//! question and a test asserts the corpus drew the whole range.

const std = @import("std");

const Smith = std.testing.Smith;

/// How many inputs there are.
pub const len = 256;
/// How many bytes each of them steers the generator with.
pub const entry_len = 192;

/// The inputs themselves.
pub const entries: [len][]const u8 = blk: {
    @setEvalBranchQuota(1 << 22);
    var data: [len][entry_len]u8 = undefined;
    var x: u64 = 0x9e3779b97f4a7c15;
    for (&data) |*entry| {
        for (entry) |*b| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            b.* = @truncate(x);
        }
    }
    const frozen = data;
    var slices: [len][]const u8 = undefined;
    for (&slices, 0..) |*s, i| s.* = frozen[i][0..];
    break :blk slices;
};

/// A property's questions, answered over their whole range.
///
/// It answers the questions `std.testing.Smith` does, by the same names, so
/// a generator written against one takes the other. Under the fuzzer every
/// answer is the fuzzer's own, so coverage steers each choice rather than
/// one seed; on a replayed entry the answers come from a generator seeded by
/// the entry, and each entry is a different run over the whole range of
/// every question.
pub const Dice = struct {
    /// The fuzzer, when it is the one asking.
    smith: ?*Smith,
    /// The generator a replayed entry seeds.
    prng: std.Random.DefaultPrng,

    /// How often, on a replayed entry, `eos` says the input is over: one
    /// answer in this many.
    pub const eos_one_in = 8;

    /// Over the fuzzer's input, or seeded from the first eight bytes of a
    /// replayed one.
    pub fn init(smith: *Smith) Dice {
        if (smith.in == null) return .{ .smith = smith, .prng = .init(0) };
        return .{ .smith = null, .prng = .init(smith.value(u64)) };
    }

    /// Seeded directly, for a test that wants one run it can name.
    pub fn seeded(seed: u64) Dice {
        return .{ .smith = null, .prng = .init(seed) };
    }

    fn random(d: *Dice) std.Random {
        return d.prng.random();
    }

    /// A value from `at_least` to `at_most`, both included.
    pub fn valueRangeAtMost(d: *Dice, comptime T: type, at_least: T, at_most: T) T {
        if (d.smith) |s| return s.valueRangeAtMost(T, at_least, at_most);
        return d.random().intRangeAtMost(T, at_least, at_most);
    }

    /// An index below `count`, which must not be zero.
    pub fn index(d: *Dice, count: usize) usize {
        if (d.smith) |s| return s.index(count);
        return d.random().uintLessThan(usize, count);
    }

    /// Any value of `T`: a coin for `bool`, any integer for an integer type.
    pub fn value(d: *Dice, comptime T: type) T {
        if (d.smith) |s| return s.value(T);
        return switch (@typeInfo(T)) {
            .bool => d.random().boolean(),
            .int => d.random().int(T),
            else => @compileError("Dice answers booleans and integers, not " ++ @typeName(T)),
        };
    }

    /// Whether the input is over: a loop that asks it runs a few times and
    /// then stops, rather than never or always.
    pub fn eos(d: *Dice) bool {
        if (d.smith) |s| return s.eos();
        return d.random().uintLessThan(u8, eos_one_in) == 0;
    }

    /// Bytes of any value, as many as `buf` holds or fewer; how many.
    pub fn slice(d: *Dice, buf: []u8) u32 {
        if (d.smith) |s| return s.slice(buf);
        const n = d.random().uintAtMost(usize, buf.len);
        d.random().bytes(buf[0..n]);
        return @intCast(n);
    }
};

/// What a property drew for one question, over every input it was given:
/// the least and the most, and which of the first sixty-four values came
/// up. A suite asserts on it that the corpus explores.
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
        std.debug.assert(lo >= s.base and hi - s.base < 64 and lo <= hi);
        var v = lo;
        while (v <= hi) : (v += 1) {
            if (s.seen & (@as(u64, 1) << @intCast(v - s.base)) == 0) return false;
        }
        return true;
    }
};

const testing = std.testing;

test "a replayed entry is answered over the whole range, not at its lowest" {
    var cols: Spread = .{};
    var coin: Spread = .{};
    var ended: Spread = .{};
    for (entries) |entry| {
        var smith: Smith = .{ .in = entry };
        var dice: Dice = .init(&smith);
        cols.add(dice.valueRangeAtMost(u16, 1, 24));
        coin.add(@intFromBool(dice.value(bool)));
        var runs: u32 = 0;
        while (runs < 64 and !dice.eos()) runs += 1;
        ended.add(@min(runs, 63));
    }
    try testing.expect(cols.covers(1, 24));
    try testing.expect(coin.covers(0, 1));
    // A loop that asks whether the input is over runs more than once and
    // stops before long.
    try testing.expect(ended.covers(0, 8));
    try testing.expect(ended.most < 63);

    // The standard generator itself, on the same entries: one value, every
    // time. This is the reason for the file.
    var smith_cols: Spread = .{};
    for (entries) |entry| {
        var smith: Smith = .{ .in = entry };
        smith_cols.add(smith.valueRangeAtMost(u16, 1, 24));
    }
    try testing.expectEqual(@as(i64, 1), smith_cols.most);
}

test "the same entry is the same run" {
    var a_smith: Smith = .{ .in = entries[7] };
    var b_smith: Smith = .{ .in = entries[7] };
    var a: Dice = .init(&a_smith);
    var b: Dice = .init(&b_smith);
    for (0..100) |_| try testing.expectEqual(a.valueRangeAtMost(u32, 0, 1000), b.valueRangeAtMost(u32, 0, 1000));
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;
    const n = a.slice(&buf_a);
    try testing.expectEqual(n, b.slice(&buf_b));
    try testing.expectEqualSlices(u8, buf_a[0..n], buf_b[0..n]);
}
