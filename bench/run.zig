//! visor's benchmark pass: the drawing core of `draw.zig` and the operations
//! of `ops.zig`, every workload checked and then timed.
//!
//! `zig build bench` builds this program in ReleaseFast under zig-out/bench
//! and runs it. Each workload runs in a process of its own, this program
//! again: `visor-bench draw <task> ...` or `visor-bench ops <task> ...`.
//! With no arguments it generates the inputs in `corpus/` under its working
//! directory, then checks every workload untimed at 8x4, 80x24, 120x40 and
//! 200x60: every drawing-core frame replayed by the decoder in
//! `terminal.zig`, every operation's evidence checked by `ops_check.zig`.
//! Then it times each workload, `--runs` rounds (seven by default) at 80x24,
//! 120x40 and 200x60, 1,000 frames a sample, and prints the median time a
//! frame. `--smoke` checks every workload at 8x4 alone and runs it once
//! there, reading no clock: `zig build test` runs it so. `--only <name>`
//! limits the pass to one workload.

const std = @import("std");
const corpus = @import("corpus.zig");
const terminal = @import("terminal.zig");
const ops_check = @import("ops_check.zig");
const plan = @import("plan.zig");
const draw = @import("draw.zig");
const ops = @import("ops.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Size = struct { cols: usize, rows: usize };
const check_sizes = [_]Size{ .{ .cols = 8, .rows = 4 }, .{ .cols = 80, .rows = 24 }, .{ .cols = 120, .rows = 40 }, .{ .cols = 200, .rows = 60 } };
const full_sizes = check_sizes[1..];
const smoke_sizes = check_sizes[0..1];
const check_iterations = 3;
const full_iterations = 1000;

const Options = struct {
    smoke: bool = false,
    runs: usize = 7,
    only: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    // One workload, in the process the pass below started for it.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "draw")) return draw.run(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "ops")) return ops.run(init, args[2..]);
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--smoke")) {
            options.smoke = true;
        } else if (std.mem.eql(u8, arg, "--runs") and index + 1 < args.len) {
            index += 1;
            options.runs = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--only") and index + 1 < args.len) {
            index += 1;
            options.only = args[index];
        } else {
            std.log.err("usage: visor-bench [--smoke] [--runs N] [--only WORKLOAD], or visor-bench draw|ops <task> <check|smoke|full> <cols> <rows> <iterations>", .{});
            return error.Usage;
        }
    }

    // Each workload runs in a process of its own: this program again.
    const self = try std.process.executablePathAlloc(io, a);
    const checked: []const Size = if (options.smoke) smoke_sizes else &check_sizes;
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const corpus_root = try std.Io.Dir.path.join(a, &.{ here, "corpus" });
    for (checked) |size| try corpus.generate(init.gpa, io, corpus_root, size.cols, size.rows);
    var env = try init.environ_map.clone(a);
    try env.put("VISOR_BENCH_CORPUS", corpus_root);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    for (checked) |size| {
        for (plan.core) |task| {
            if (!selected(options, task)) continue;
            const run = try invoke(a, io, &env, self, "draw", task, "check", size, check_iterations);
            _ = terminal.verifyFrames(a, task, size.cols, size.rows, run.lines, run.result) catch |err| {
                std.log.err("{s} {d}x{d} failed its check: {s}", .{ task, size.cols, size.rows, @errorName(err) });
                return err;
            };
        }
        for (plan.ops) |task| {
            if (!selected(options, task)) continue;
            const run = try invoke(a, io, &env, self, "ops", task, "check", size, check_iterations);
            _ = ops_check.verify(a, io, task, size.cols, size.rows, corpus_root, run.lines) catch |err| {
                std.log.err("{s} {d}x{d} failed its check: {s}", .{ task, size.cols, size.rows, @errorName(err) });
                return err;
            };
        }
        try out.print("checked {d}x{d}\n", .{ size.cols, size.rows });
        try out.flush();
    }

    const sizes: []const Size = if (options.smoke) smoke_sizes else full_sizes;
    const iterations: usize = if (options.smoke) 1 else full_iterations;
    const mode = if (options.smoke) "smoke" else "full";
    const rounds: usize = if (options.smoke) 1 else options.runs;
    const samples = try a.alloc(u64, rounds);
    for (sizes) |size| {
        for ([_]struct { []const u8, []const []const u8 }{ .{ "draw", &plan.core }, .{ "ops", &plan.ops } }) |family| {
            for (family[1]) |task| {
                if (!selected(options, task)) continue;
                const n = plan.iterations(task, iterations);
                var bytes: u64 = 0;
                for (samples) |*sample| {
                    const run = try invoke(a, io, &env, self, family[0], task, mode, size, n);
                    sample.* = run.result.ns / n;
                    bytes = run.result.output_bytes / n;
                }
                std.mem.sortUnstable(u64, samples, {}, std.sort.asc(u64));
                if (options.smoke) {
                    try out.print("{s} {d}x{d}: ran\n", .{ task, size.cols, size.rows });
                } else {
                    try out.print("{s} {d}x{d}: {d} ns a frame (median of {d}), {d} bytes\n", .{
                        task, size.cols, size.rows, samples[samples.len / 2], samples.len, bytes,
                    });
                }
                try out.flush();
            }
        }
    }
}

fn selected(options: Options, task: []const u8) bool {
    const only = options.only orelse return true;
    return std.mem.eql(u8, only, task);
}

const Run = struct {
    /// Every line before the result line: check frames or evidence.
    lines: []const []const u8,
    result: terminal.Result,
};

/// One invocation: `<draw|ops> <task> <check|smoke|full> <cols> <rows>
/// <iterations>`, its last line `result\t<units>\t<native count>\t<bytes>\t<ns>`.
fn invoke(a: Allocator, io: Io, env: *const std.process.Environ.Map, program: []const u8, family: []const u8, task: []const u8, mode: []const u8, size: Size, iterations: usize) !Run {
    const argv = [_][]const u8{
        program,
        family,
        task,
        mode,
        try a.print("{d}", .{size.cols}),
        try a.print("{d}", .{size.rows}),
        try a.print("{d}", .{iterations}),
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
    var numbers: [4]i64 = undefined;
    for (&numbers) |*n| n.* = std.fmt.parseInt(i64, fields.next() orelse return error.NoResult, 10) catch return error.NoResult;
    if (numbers[0] != iterations) return error.WrongCount;
    if (!std.mem.eql(u8, mode, "full") and numbers[3] != 0) return error.ClockReadUntimed;
    return .{
        .lines = lines.items[0 .. lines.items.len - 1],
        .result = .{
            .units = @intCast(numbers[0]),
            .native_count = if (numbers[1] >= 0) @intCast(numbers[1]) else null,
            .output_bytes = @intCast(numbers[2]),
            .ns = @intCast(numbers[3]),
        },
    };
}

test {
    _ = @import("unicode.zig");
    _ = corpus;
    _ = terminal;
    _ = @import("pictures.zig");
    _ = ops_check;
    _ = plan;
}
