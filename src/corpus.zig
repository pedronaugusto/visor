//! The inputs the round-trip properties replay on every run.
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
//! One caution about what the entries do. `std.testing.Smith` reads eight
//! bytes for every value it is asked for and answers the lowest value in
//! range whenever those eight bytes are out of it, which random bytes almost
//! always are: a property that asks the input for a size gets one column and
//! one row, every entry. `Dice` is the way round it -- a generator seeded
//! from the input, which answers from the whole range.

const std = @import("std");

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

/// A property's questions answered by a generator seeded from the input,
/// rather than by the input itself.
///
/// It answers the same questions `std.testing.Smith` does, by the same
/// names, so a generator written against one takes the other. Each corpus
/// entry is then a different run over the whole range of every question,
/// and under `--fuzz` the fuzzer steers the seed.
pub const Dice = struct {
    prng: std.Random.DefaultPrng,

    /// Seeded from the next eight bytes of the input.
    pub fn init(smith: *std.testing.Smith) Dice {
        return .{ .prng = .init(smith.value(u64)) };
    }

    /// A value from `at_least` to `at_most`, both included.
    pub fn valueRangeAtMost(d: *Dice, comptime T: type, at_least: T, at_most: T) T {
        return d.prng.random().intRangeAtMost(T, at_least, at_most);
    }

    /// An index below `count`, which must not be zero.
    pub fn index(d: *Dice, count: usize) usize {
        return d.prng.random().uintLessThan(usize, count);
    }

    /// A coin. `T` is `bool`, the one type the properties ask for whole.
    pub fn value(d: *Dice, comptime T: type) T {
        comptime std.debug.assert(T == bool);
        return d.prng.random().boolean();
    }
};
