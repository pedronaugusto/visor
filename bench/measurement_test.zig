const std = @import("std");
const bench = @import("shakedown").bench;
const Measurement = @import("measurement.zig");
const testing = std.testing;

const Context = struct {
    units: u64 = 0,
    calls: usize = 0,
    fn run(self: *Context, units: u64) !void {
        self.units += units;
        self.calls += 1;
    }
    fn fail(_: *Context, _: u64) !void {
        return error.WorkloadFailed;
    }
};

fn measurement() Measurement {
    return .{ .allocator = testing.allocator, .io = testing.io, .name = "cell_reads/8x4", .check = false, .initial = 1000, .options = .{ .smoke = true } };
}

test "measurement smoke emits shared frame JSONL and invokes the workload once" {
    const m = measurement();
    var context: Context = .{};
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try m.write(&writer.writer, &context, Context.run);
    try testing.expectEqual(@as(usize, 1), context.calls);
    try testing.expectEqual(@as(u64, 1), context.units);
    var parsed = try bench.parse(testing.allocator, writer.written());
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.rows.items.len);
    const row = parsed.rows.items[0].value;
    try testing.expectEqualStrings(m.name, row.row);
    try testing.expectEqualStrings("frame", row.unit);
    try testing.expect(row.smoke);
    try testing.expectEqual(@as(usize, 0), row.samples.len);
}

test "measurement preserves callback and output errors" {
    const m = measurement();
    var context: Context = .{};
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try testing.expectError(error.WorkloadFailed, m.write(&writer.writer, &context, Context.fail));
    try testing.expectEqual(@as(usize, 0), writer.written().len);
    var failing = std.Io.Writer.failing;
    try testing.expectError(error.WriteFailed, m.write(&failing, &context, Context.run));
}

test "measurement check preserves requested compatibility frame count" {
    var m = measurement();
    m.check = true;
    m.initial = 3;
    var context: Context = .{};
    try m.run(&context, Context.run);
    try testing.expectEqual(@as(u64, 3), context.units);
    try testing.expectEqual(@as(usize, 1), context.calls);
}
