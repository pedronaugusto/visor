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
