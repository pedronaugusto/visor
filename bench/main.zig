//! Visor's workload fixtures and independent compatibility checks.
//! Measuring, statistics, JSONL and comparison belong to shakedown.bench.
const std = @import("std");
const bench = @import("shakedown").bench;
const corpus = @import("corpus.zig");
const terminal = @import("terminal.zig");
const ops_check = @import("ops_check.zig");
const workloads = @import("workloads.zig");
const draw = @import("draw.zig");
const ops = @import("ops.zig");
const Io = std.Io;
const Size = struct { cols: usize, rows: usize };
const sizes = [_]Size{ .{ .cols = 8, .rows = 4 }, .{ .cols = 80, .rows = 24 }, .{ .cols = 120, .rows = 40 }, .{ .cols = 200, .rows = 60 } };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "draw")) return draw.run(init, args[2..]);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "ops")) return ops.run(init, args[2..]);
    var smoke = false;
    var prefix: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, args[i], "--row") and i + 1 < args.len) {
            i += 1;
            prefix = args[i];
        } else return error.Arguments;
    }
    const self = try std.process.executablePathAlloc(init.io, a);
    const here = try Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
    const root = try Io.Dir.path.join(a, &.{ here, "corpus" });
    var env = try init.environ_map.clone(a);
    try env.put("VISOR_BENCH_CORPUS", root);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);
    const checked = if (smoke) sizes[0..1] else &sizes;
    var selected = false;
    for (checked) |size| {
        try corpus.generate(init.gpa, init.io, root, size.cols, size.rows);
        for ([_]struct { family: []const u8, tasks: []const []const u8 }{
            .{ .family = "draw", .tasks = &workloads.core },
            .{ .family = "ops", .tasks = &workloads.ops },
        }) |family| for (family.tasks) |task| {
            const name = try a.print("{s}/{d}x{d}", .{ task, size.cols, size.rows });
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            selected = true;
            const checked_run = try invoke(a, init.io, &env, self, family.family, task, "check", size, 3);
            const check = try evidence(a, checked_run.stdout, 3);
            if (std.mem.eql(u8, family.family, "draw")) {
                _ = try terminal.verifyFrames(a, task, size.cols, size.rows, check.lines, check.result);
            } else {
                _ = try ops_check.verify(a, init.io, task, size.cols, size.rows, root, check.lines);
            }
            if (!smoke and size.cols == sizes[0].cols) continue;
            const measured = try invoke(a, init.io, &env, self, family.family, task, if (smoke) "smoke" else "full", size, workloads.iterations(task, if (smoke) 1 else 1000));
            var parsed = try bench.parse(init.gpa, measured.stdout);
            defer parsed.deinit();
            if (parsed.rows.items.len != 1 or parsed.rows.items[0].value.smoke != smoke or !std.mem.eql(u8, parsed.rows.items[0].value.row, name)) return error.WrongRow;
            try stdout.interface.writeAll(measured.stdout);
            try stdout.interface.flush();
        };
    }
    if (!selected) return error.UnknownRow;
}

fn invoke(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, self: []const u8, family: []const u8, task: []const u8, mode: []const u8, size: Size, iterations: usize) !std.process.RunResult {
    const argv = [_][]const u8{ self, family, task, mode, try a.print("{d}", .{size.cols}), try a.print("{d}", .{size.rows}), try a.print("{d}", .{iterations}) };
    const result = try std.process.run(a, io, .{
        .argv = &argv,
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(32768),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
    });
    if (successful(result.term)) |_| {} else |err| {
        try Io.File.stderr().writeStreamingAll(io, result.stderr);
        return err;
    }
    return result;
}

fn successful(term: std.process.Child.Term) !void {
    if (!term.success()) return error.ProgramFailed;
}

const Evidence = struct { lines: []const []const u8, result: terminal.Result };
fn evidence(a: std.mem.Allocator, bytes: []const u8, iterations: usize) !Evidence {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(a);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\r\n"), '\n');
    while (it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));
    const last = lines.items[lines.items.len - 1];
    if (!std.mem.startsWith(u8, last, "result\t")) return error.NoResult;
    var fields = std.mem.splitScalar(u8, last[7..], '\t');
    var numbers: [4]u64 = undefined;
    for (&numbers) |*n| n.* = std.fmt.parseInt(u64, fields.next() orelse return error.NoResult, 10) catch return error.NoResult;
    if (fields.next() != null) return error.NoResult;
    if (numbers[0] != iterations) return error.WrongCount;
    if (numbers[3] != 0) return error.ClockReadUntimed;
    return .{ .lines = lines.items[0 .. lines.items.len - 1], .result = .{ .units = numbers[0], .native_count = numbers[1], .output_bytes = numbers[2], .ns = 0 } };
}

test {
    _ = @import("unicode.zig");
    _ = corpus;
    _ = terminal;
    _ = @import("pictures.zig");
    _ = ops_check;
    _ = workloads;
    _ = @import("measurement_test.zig");
}

test "measurement workload termination and malformed evidence fail" {
    const testing = std.testing;
    try successful(.{ .exited = 0 });
    try testing.expectError(error.ProgramFailed, successful(.{ .exited = 7 }));
    try testing.expectError(error.ProgramFailed, successful(.{ .signal = .KILL }));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NoResult, evidence(a, "", 3));
    try testing.expectError(error.NoResult, evidence(a, "result\t3\t0\t0\t0\textra\n", 3));
    try testing.expectError(error.WrongCount, evidence(a, "result\t2\t0\t0\t0\n", 3));
    try testing.expectError(error.ClockReadUntimed, evidence(a, "result\t3\t0\t0\t1\n", 3));
    const checked = try evidence(a, "frame\nresult\t3\t4\t5\t0\n", 3);
    try testing.expectEqual(@as(usize, 1), checked.lines.len);
    try testing.expectEqual(@as(u64, 4), checked.result.native_count.?);
}
