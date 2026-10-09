//! Drawing-core workloads: legacy check evidence, shared smoke and measurement rows.
//! Setup and output capacity remain outside each measured callback.
const std = @import("std");
const v = @import("visor");
const Measurement = @import("measurement.zig");

/// The Io the lines go out through, set once by `run`: unbuffered, so every
/// line a check prints is out before anything that stops the program.
var stdout_io: std.Io = undefined;
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.mem.print(&buf, fmt, args) catch @panic("report too long");
    std.Io.File.stdout().writeStreamingAll(stdout_io, s) catch @panic("write failed");
}
fn hex(bytes: []const u8) void {
    for (bytes) |b| emit("{x:0>2}", .{b});
    emit("\n", .{});
}
fn paint(s: *v.Screen, cols: u16, rows: u16, salt: usize, heavy: bool) !void {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (0..rows) |y| for (0..cols) |x| {
        const i = y * cols + x;
        const style: v.Style = if (heavy) .{
            .fg = .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53)),
            .bold = (i + salt) % 2 == 0,
        } else .{};
        try s.write(@intCast(x), @intCast(y), alphabet[(i + (if (heavy) @as(usize, 0) else salt)) % alphabet.len ..][0..1], style, .none);
    };
}
fn restyle(s: *v.Screen, cols: u16, rows: u16, salt: usize) !void {
    for (0..rows) |y| for (0..cols) |x| {
        const i = y * cols + x;
        var c = s.readCell(@intCast(x), @intCast(y)).?;
        c.setStyle(.{
            .fg = .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53)),
            .bold = (i + salt) % 2 == 0,
        });
        try s.writeOwnedCell(@intCast(x), @intCast(y), c);
    };
}
fn equal(a: v.Cell, b: v.Cell) bool {
    return v.Cell.eql(a, b);
}

// The two diff workloads' frames, each a function of its own that is never
// inlined: what the compiler makes of the timed loop then depends on visor
// and on nothing in this harness around it.

/// One `buffer_diff` frame: the cells `Screen.diff` reports changed.
noinline fn diffCells(screens: *const [2]v.Screen) usize {
    var changed: usize = 0;
    var changes = screens[0].diff(&screens[1]);
    while (changes.next()) |point| {
        std.mem.doNotOptimizeAway(point);
        changed += 1;
    }
    std.mem.doNotOptimizeAway(changed);
    return changed;
}

/// One `cell_reads` frame: every cell of both screens read and compared.
noinline fn readCells(screens: *const [2]v.Screen) usize {
    var changed: usize = 0;
    const size = screens[0].dimensions();
    for (0..size.rows) |y| for (0..size.cols) |x| {
        const a = screens[0].readCell(@intCast(x), @intCast(y)).?;
        const b = screens[1].readCell(@intCast(x), @intCast(y)).?;
        if (!equal(a, b)) changed += 1;
    };
    std.mem.doNotOptimizeAway(changed);
    return changed;
}
/// One workload: `args` are `<task> <check|smoke|full> <cols> <rows> <iterations>`.
pub fn run(init: std.process.Init, args: []const []const u8) !void {
    stdout_io = init.io;
    if (args.len != 5) return error.Arguments;
    const task = args[0];
    const check = std.mem.eql(u8, args[1], "check");
    const cols = try std.fmt.parseInt(u16, args[2], 10);
    const rows = try std.fmt.parseInt(u16, args[3], 10);
    const iterations = try std.fmt.parseInt(usize, args[4], 10);
    if (cols < 4 or rows < 4 or iterations == 0) return error.InvalidSize;
    const gpa = init.gpa;
    const size: v.Size = .{ .cols = cols, .rows = rows };
    var screens = [_]v.Screen{ try .init(gpa, size), try .init(gpa, size) };
    defer for (&screens) |*s| s.deinit();
    for (&screens) |*s| s.method = .unicode;
    const heavy = std.mem.eql(u8, task, "style_heavy");
    const cell_reads = std.mem.eql(u8, task, "cell_reads");
    const diff = std.mem.eql(u8, task, "buffer_diff") or cell_reads;
    const picture = std.mem.startsWith(u8, task, "picture_");
    try paint(&screens[0], cols, rows, 0, heavy);
    try paint(&screens[1], cols, rows, if (heavy) 1 else 0, heavy);
    if (diff) for (0..size.area()) |i| {
        if (i % 97 == 0) try screens[1].write(@intCast(i % cols), @intCast(i / cols), "!", .{}, .none);
    };
    var renderer: v.Renderer = try .init(gpa, size);
    defer renderer.deinit();
    var layers: v.Layers = .init(gpa);
    defer layers.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const caps: v.Caps = .{ .width_method = .unicode, .truecolor = true, .kitty_graphics = picture };
    if (picture) {
        var pixels: [16 * 16 * 4]u8 = undefined;
        for (0..16 * 16) |i| pixels[i * 4 ..][0..4].* = .{ 31, 63, 127, 255 };
        _ = try layers.transmit(&out.writer, 7, &pixels, .{ .width = 16, .height = 16, .compress = false });
        if (check) hex(out.written());
        try layers.declare(.{ .image = 7, .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 } });
    }
    if (!diff) {
        out.clearRetainingCapacity();
        _ = try renderer.draw(&out.writer, &screens[0], if (picture) &layers else null, caps);
        if (check) hex(out.written());
    }
    // Reserve the maximum output outside the interval; no terminal is opened.
    try out.ensureTotalCapacity(@as(usize, size.area()) * 64 + 8192);
    out.clearRetainingCapacity();
    var count: usize = 0;
    var bytes: usize = 0;
    var measurement = try Measurement.init(init, task, args[1], cols, rows, iterations);
    // The published callback API cannot exclude restyling between draws.
    if (heavy and !check and !measurement.options.smoke) return error.StyleHeavyBoundaryUnavailable;
    var prepared = .{ .screens = &screens, .renderer = &renderer, .layers = &layers, .out = &out, .count = &count, .bytes = &bytes, .task = task, .cols = cols, .rows = rows, .heavy = heavy, .cell_reads = cell_reads, .diff = diff, .picture = picture, .caps = caps, .check = check };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                if (context.diff) {
                    context.count.* += if (context.cell_reads) readCells(&context.screens.*) else diffCells(&context.screens.*);
                } else {
                    const s = &context.screens.*[0];
                    // Keep one screen owner: switching unrelated screens invalidates
                    // current-main handles and would measure an artificial repaint.
                    // Style preparation is retained for untimed check and smoke only.
                    if (context.heavy) try restyle(s, context.cols, context.rows, (n + 1) % 2);
                    if (std.mem.eql(u8, context.task, "full_repaint")) context.renderer.*.repaint();
                    if (context.heavy or std.mem.eql(u8, context.task, "unchanged_diff")) s.damageAll();
                    if (context.picture) try context.layers.*.declare(.{ .image = 7, .rect = .{
                        .col = if (std.mem.eql(u8, context.task, "picture_layers")) @intCast((n + 1) % 2) else 0,
                        .row = 0,
                        .cols = 2,
                        .rows = 2,
                    } });
                    context.out.*.clearRetainingCapacity();
                    const stats = try context.renderer.*.draw(&context.out.*.writer, s, if (context.picture) &context.layers.* else null, context.caps);
                    context.bytes.* += context.out.*.written().len;
                    context.count.* += stats.cells;
                    std.mem.doNotOptimizeAway(context.out.*.written());
                    if (context.check) hex(context.out.*.written());
                }
            }
        }
    };
    try measurement.run(&prepared, Callback.run);
    if (check) emit("result\t{d}\t{d}\t{d}\t0\n", .{ iterations, count, bytes });
}
