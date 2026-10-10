//! visor's benchmark pass: the drawing core of `draw.zig` and the operations
//! of `ops.zig`, every workload checked and then measured.
//!
//!     visor-bench [--smoke] [--row <name prefix>] [--samples <n>]
//!
//! `zig build bench` builds this program in ReleaseFast under zig-out/bench and
//! runs it. It generates the inputs in `corpus/` under its working directory,
//! then checks every workload untimed at 8x4, 80x24, 120x40 and 200x60: each
//! in a process of its own, this program again (`visor-bench draw|ops <task>
//! check <cols> <rows> <frames>`), its evidence replayed by the decoder in
//! `terminal.zig` or checked by `ops_check.zig`. Then it measures each workload
//! at 80x24, 120x40 and 200x60 with shakedown's `bench`, again in a process of
//! its own (`visor-bench measure <draw|ops> <task> <cols> <rows> <samples>
//! <full|smoke>`), so that no workload meets the heap another left: a row a
//! workload and size, `<task>/<cols>x<rows>`, one JSON line each on standard
//! output, every sample in nanoseconds a frame. What the pass says of its
//! checks goes to standard error. `--smoke` checks every workload at 8x4 alone
//! and runs each once there, reading no clock: `zig build test` runs it so.

const std = @import("std");
const bench = @import("shakedown").bench;
const corpus = @import("corpus.zig");
const terminal = @import("terminal.zig");
const ops_check = @import("ops_check.zig");
const harness = @import("harness.zig");
const draw = @import("draw.zig");
const ops = @import("ops.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Size = struct { cols: u16, rows: u16 };
const check_sizes = [_]Size{ .{ .cols = 8, .rows = 4 }, .{ .cols = 80, .rows = 24 }, .{ .cols = 120, .rows = 40 }, .{ .cols = 200, .rows = 60 } };
const measured_sizes: []const Size = check_sizes[1..];
const smoke_sizes: []const Size = check_sizes[0..1];
const check_frames = 3;

/// The workloads of each family, as `.{ name, type }`.
const families = .{ .{ "draw", draw.workloads }, .{ "ops", ops.workloads } };
const WorkloadError = harness.ErrorOf(draw.workloads ++ ops.workloads);
comptime {
    std.debug.assert(WorkloadError != anyerror);
}

const Options = struct {
    smoke: bool = false,
    samples: usize = 31,
    prefix: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    // One workload, checked, in the process the pass below started for it.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "draw")) return harness.checked(init, draw.workloads, 4, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "ops")) return harness.checked(init, ops.workloads, 8, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "measure")) return measureOne(init, args[2..]);
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--smoke")) {
            options.smoke = true;
        } else if (std.mem.eql(u8, arg, "--samples") and index + 1 < args.len) {
            index += 1;
            options.samples = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--row") and index + 1 < args.len) {
            index += 1;
            options.prefix = args[index];
        } else {
            std.log.err("usage: visor-bench [--smoke] [--row NAME-PREFIX] [--samples N], or visor-bench draw|ops <task> check <cols> <rows> <frames>", .{});
            return error.Usage;
        }
    }

    // Each workload is checked in a process of its own: this program again.
    const self = try std.process.executablePathAlloc(io, a);
    const checked: []const Size = if (options.smoke) smoke_sizes else &check_sizes;
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const corpus_root = try std.Io.Dir.path.join(a, &.{ here, "corpus" });
    for (checked) |size| try corpus.generate(init.gpa, io, corpus_root, size.cols, size.rows);
    var env = try init.environ_map.clone(a);
    try env.put("VISOR_BENCH_CORPUS", corpus_root);

    var selected = false;
    inline for (families) |family| {
        inline for (family[1]) |entry| selected = selected or wanted(options.prefix, entry[0]);
    }
    if (!selected) return error.UnknownRow;

    for (checked) |size| {
        inline for (families) |family| {
            inline for (family[1]) |entry| {
                const task: []const u8 = entry[0];
                if (wanted(options.prefix, task)) {
                    const run = try check(a, io, &env, self, family[0], task, size);
                    const failed = if (comptime std.mem.eql(u8, family[0], "draw"))
                        terminal.verifyFrames(a, task, size.cols, size.rows, run.lines, run.result)
                    else
                        ops_check.verify(a, io, task, size.cols, size.rows, corpus_root, run.lines);
                    _ = failed catch |err| {
                        std.log.err("{s} {d}x{d} failed its check: {s}", .{ task, size.cols, size.rows, @errorName(err) });
                        return err;
                    };
                }
            }
        }
        std.log.info("checked {d}x{d}", .{ size.cols, size.rows });
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const sizes: []const Size = if (options.smoke) smoke_sizes else measured_sizes;
    for (sizes) |size| {
        inline for (families) |family| {
            inline for (family[1]) |entry| {
                const task: []const u8 = entry[0];
                const name = try a.print("{s}/{d}x{d}", .{ task, size.cols, size.rows });
                if (std.mem.startsWith(u8, name, options.prefix)) {
                    const rows = try measure(a, io, &env, self, family[0], task, size, options);
                    try stdout.interface.writeAll(rows);
                    try stdout.interface.flush();
                }
            }
        }
    }
}

/// One workload at one size, measured in a process of its own: its rows, as
/// that process printed them.
fn measure(a: Allocator, io: Io, env: *const std.process.Environ.Map, program: []const u8, family: []const u8, task: []const u8, size: Size, options: Options) ![]const u8 {
    const argv = [_][]const u8{
        program,
        "measure",
        family,
        task,
        try a.print("{d}", .{size.cols}),
        try a.print("{d}", .{size.rows}),
        try a.print("{d}", .{options.samples}),
        if (options.smoke) "smoke" else "full",
        options.prefix,
    };
    const ran = try std.process.run(a, io, .{ .argv = &argv, .environ_map = env });
    if (!ran.term.success()) {
        std.log.err("{s} {s} {d}x{d} ended {f}\n{s}", .{ family, task, size.cols, size.rows, ran.term, ran.stderr });
        return error.ProgramFailed;
    }
    return ran.stdout;
}

/// The process `measure` starts: `<draw|ops> <task> <cols> <rows> <samples>
/// <full|smoke> <name prefix>`. The workload is one row of shakedown's `bench`.
/// Most are batched: `run` does as many frames as it takes to read. A workload
/// with work the clock must not see in each frame has a sample of one frame,
/// its fixture restaged before it.
fn measureOne(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 7) return error.Arguments;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const cols = try std.fmt.parseInt(u16, args[2], 10);
    const rows = try std.fmt.parseInt(u16, args[3], 10);
    const samples = try std.fmt.parseInt(usize, args[4], 10);
    const smoke = std.mem.eql(u8, args[5], "smoke");
    var context: harness.Bench = .{
        .ctx = .{
            .gpa = init.gpa,
            .fixture = undefined,
            .io = init.io,
            .cols = cols,
            .rows = rows,
            .corpus = init.environ_map.get("VISOR_BENCH_CORPUS") orelse return error.NoCorpus,
        },
        .arena = undefined,
    };
    const name = try arena.allocator().print("{s}/{d}x{d}", .{ args[1], cols, rows });
    const metadata: bench.Metadata = .{ .commit = @import("preflight_bench_options").commit };
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    inline for (families) |family| {
        inline for (family[1]) |entry| {
            if (std.mem.eql(u8, args[0], family[0]) and std.mem.eql(u8, args[1], entry[0])) {
                // A sample here is at least ten milliseconds of frames, where
                // a workload is quicker than that. A staged workload's sample
                // is one frame and is read at ten clock ticks: a frame
                // shorter than that is an error, not a longer batch.
                var options: bench.Options = .{ .smoke = smoke, .prefix = args[6], .samples = samples, .minimum = .fromMilliseconds(10) };
                if (comptime harness.sampled(entry[1])) options.resolution_multiple = 10;
                try bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &context, &.{harness.row(entry[1], WorkloadError, name)}, metadata, options);
                try stdout.interface.flush();
                return;
            }
        }
    }
    return error.UnknownTask;
}

/// Whether a row of `task` is selected: the prefix names the task, or is
/// inside the names of its rows.
fn wanted(prefix: []const u8, task: []const u8) bool {
    if (std.mem.startsWith(u8, task, prefix)) return true;
    return std.mem.startsWith(u8, prefix, task) and prefix.len > task.len and prefix[task.len] == '/';
}

const Check = struct {
    /// Every line before the result line: check frames or evidence.
    lines: []const []const u8,
    result: terminal.Result,
};

/// One checked workload: `<draw|ops> <task> check <cols> <rows> <frames>`, its
/// last line `result\t<frames>\t<native count>\t<bytes>`.
fn check(a: Allocator, io: Io, env: *const std.process.Environ.Map, program: []const u8, family: []const u8, task: []const u8, size: Size) !Check {
    const argv = [_][]const u8{
        program,
        family,
        task,
        "check",
        try a.print("{d}", .{size.cols}),
        try a.print("{d}", .{size.rows}),
        try a.print("{d}", .{check_frames}),
    };
    const ran = try std.process.run(a, io, .{ .argv = &argv, .environ_map = env });
    if (!ran.term.success()) {
        std.log.err("{s} {s} {d}x{d} ended {f}\n{s}", .{ family, task, size.cols, size.rows, ran.term, ran.stderr });
        return error.ProgramFailed;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, ran.stdout, "\n"), '\n');
    while (it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));
    const last = if (lines.items.len > 0) lines.items[lines.items.len - 1] else "";
    if (!std.mem.startsWith(u8, last, "result\t")) {
        std.log.err("{s} {s}: no result line", .{ family, task });
        return error.NoResult;
    }
    var fields = std.mem.splitScalar(u8, last["result\t".len..], '\t');
    var numbers: [3]i64 = undefined;
    for (&numbers) |*n| n.* = std.fmt.parseInt(i64, fields.next() orelse return error.NoResult, 10) catch return error.NoResult;
    if (numbers[0] != check_frames) return error.WrongCount;
    return .{
        .lines = lines.items[0 .. lines.items.len - 1],
        .result = .{
            .units = @intCast(numbers[0]),
            .native_count = if (numbers[1] >= 0) @intCast(numbers[1]) else null,
            .output_bytes = @intCast(numbers[2]),
        },
    };
}

test "the workloads: 55 operations, 8 drawing-core workloads, each named once" {
    try std.testing.expectEqual(@as(usize, 55), ops.workloads.len);
    try std.testing.expectEqual(@as(usize, 8), draw.workloads.len);
    const all = draw.workloads ++ ops.workloads;
    @setEvalBranchQuota(20_000);
    inline for (all, 0..) |one, i| {
        inline for (all, 0..) |other, j| {
            if (i < j) try std.testing.expect(!std.mem.eql(u8, one[0], other[0]));
        }
    }
}

test "a staged workload's row takes one frame a sample and keeps its fixture, as every other row does" {
    const all = draw.workloads ++ ops.workloads;
    @setEvalBranchQuota(20_000);
    inline for (all) |entry| {
        const row = harness.row(entry[1], WorkloadError, entry[0]);
        const staged = harness.sampled(entry[1]);
        try std.testing.expectEqual(!staged, row.grow);
        try std.testing.expect((row.stage != null) == staged and (row.settle != null) == staged);
        try std.testing.expectEqual(bench.Lifetime.row, row.fixture.?.lifetime);
    }
    // The one staged workload is the one whose every frame restyles every cell.
    try std.testing.expectEqualStrings("style_heavy", draw.workloads[4][0]);
    try std.testing.expect(harness.sampled(draw.workloads[4][1]));
}

test "a prefix selects the tasks it names, or begins" {
    try std.testing.expect(wanted("", "tree"));
    try std.testing.expect(wanted("text", "text_wrap"));
    try std.testing.expect(wanted("tree/80x24", "tree"));
    try std.testing.expect(!wanted("tree_", "tree"));
    try std.testing.expect(!wanted("tre/80x24", "tree"));
}

test {
    _ = @import("unicode.zig");
    _ = corpus;
    _ = terminal;
    _ = @import("pictures.zig");
    _ = ops_check;
}
