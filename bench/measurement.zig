//! The workload's boundary and configuration; shakedown owns all measurement.
const std = @import("std");
const bench = @import("shakedown").bench;
const provenance = @import("preflight_bench_options");
const Measurement = @This();

allocator: std.mem.Allocator,
io: std.Io,
name: []const u8,
check: bool,
initial: u64,
options: bench.Options,

pub fn init(process: std.process.Init, task: []const u8, mode: []const u8, cols: u16, rows: u16, iterations: usize) !Measurement {
    const check = std.mem.eql(u8, mode, "check");
    const smoke = std.mem.eql(u8, mode, "smoke");
    if (!check and !smoke and !std.mem.eql(u8, mode, "full")) return error.UnknownMode;
    return .{
        .allocator = process.arena.allocator(),
        .io = process.io,
        .name = try process.arena.allocator().print("{s}/{d}x{d}", .{ task, cols, rows }),
        .check = check,
        .initial = iterations,
        .options = .{ .smoke = smoke, .samples = 7 },
    };
}

pub fn run(self: *const Measurement, context: anytype, callback: *const fn (@TypeOf(context), u64) anyerror!void) !void {
    if (self.check) return callback(context, self.initial);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(self.io, &buffer);
    try self.write(&stdout.interface, context, callback);
    try stdout.interface.flush();
}

pub fn write(self: *const Measurement, writer: *std.Io.Writer, context: anytype, callback: *const fn (@TypeOf(context), u64) anyerror!void) !void {
    const Context = std.meta.Child(@TypeOf(context));
    const row: bench.Row(Context) = .{ .name = self.name, .unit = "frame", .initial = self.initial, .run = callback };
    try bench.run(self.allocator, self.io, writer, context, &.{row}, .{
        .commit = provenance.commit,
        .cpu = provenance.cpu,
        .os = provenance.os,
    }, self.options);
}
