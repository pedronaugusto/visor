const std = @import("std");
const v = @import("visor");
const before = @import("options").before;
extern "c" fn write(c_int, [*]const u8, usize) isize;
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch @panic("report too long");
    var n: usize = 0;
    while (n < s.len) {
        const got = write(1, s.ptr + n, s.len - n);
        if (got <= 0) @panic("write failed");
        n += @intCast(got);
    }
}
fn hex(bytes: []const u8) void {
    for (bytes) |b| emit("{x:0>2}", .{b});
    emit("\n", .{});
}
fn deinitScreen(s: *v.Screen, gpa: std.mem.Allocator) void {
    if (before) s.deinit(gpa) else s.deinit();
}
fn deinitRenderer(r: *v.Renderer, gpa: std.mem.Allocator) void {
    if (before) r.deinit(gpa) else r.deinit();
}
fn deinitLayers(l: *v.Layers, gpa: std.mem.Allocator) void {
    if (before) l.deinit(gpa) else l.deinit();
}
fn declare(l: *v.Layers, gpa: std.mem.Allocator, layer: v.Layer) !void {
    if (before) try l.declare(gpa, layer) else try l.declare(layer);
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
        if (before) s.writeOwnedCell(@intCast(x), @intCast(y), c) else try s.writeOwnedCell(@intCast(x), @intCast(y), c);
    };
}
fn equal(a: v.Cell, b: v.Cell) bool {
    return v.Cell.eql(a, b);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.Arguments;
    const task = args[1];
    const check = std.mem.eql(u8, args[2], "check");
    const timed = std.mem.eql(u8, args[2], "full");
    const cols = try std.fmt.parseInt(u16, args[3], 10);
    const rows = try std.fmt.parseInt(u16, args[4], 10);
    const iterations = try std.fmt.parseInt(usize, args[5], 10);
    if (cols < 4 or rows < 4 or iterations == 0) return error.InvalidSize;
    const gpa = init.gpa;
    const size: v.Size = .{ .cols = cols, .rows = rows };
    var screens = [_]v.Screen{ try .init(gpa, size), try .init(gpa, size) };
    defer for (&screens) |*s| deinitScreen(s, gpa);
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
    defer deinitRenderer(&renderer, gpa);
    var layers: v.Layers = if (before) .{} else .init(gpa);
    defer deinitLayers(&layers, gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const caps: v.Caps = .{ .width_method = .unicode, .truecolor = true, .kitty_graphics = picture };
    if (picture) {
        const pixels = [_]u8{ 31, 63, 127, 255 } ** (16 * 16);
        if (before) {
            _ = try layers.transmit(gpa, &out.writer, 7, &pixels, .{ .width = 16, .height = 16, .compress = false });
        } else {
            _ = try layers.transmit(&out.writer, 7, &pixels, .{ .width = 16, .height = 16, .compress = false });
        }
        if (check) hex(out.written());
        try declare(&layers, gpa, .{ .image = 7, .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 } });
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
    var style_elapsed: i96 = 0;
    const start = if (timed and !heavy) std.Io.Clock.now(.awake, init.io).toNanoseconds() else 0;
    for (0..iterations) |n| {
        if (diff) {
            var changed: usize = 0;
            if (!before and !cell_reads) {
                var changes = screens[0].diff(&screens[1]);
                while (changes.next()) |point| {
                    std.mem.doNotOptimizeAway(point);
                    changed += 1;
                }
            } else for (0..rows) |y| for (0..cols) |x| {
                const a = screens[0].readCell(@intCast(x), @intCast(y)).?;
                const b = screens[1].readCell(@intCast(x), @intCast(y)).?;
                if (!equal(a, b)) changed += 1;
            };
            std.mem.doNotOptimizeAway(changed);
            count += changed;
        } else {
            const s = &screens[0];
            // Keep one screen owner: switching unrelated screens invalidates
            // current-main handles and would measure an artificial repaint.
            // Frame construction is outside the style-heavy draw interval.
            if (heavy) try restyle(s, cols, rows, (n + 1) % 2);
            if (std.mem.eql(u8, task, "full_repaint")) renderer.repaint();
            if (heavy or std.mem.eql(u8, task, "unchanged_diff")) s.damageAll();
            if (picture) try declare(&layers, gpa, .{ .image = 7, .rect = .{
                .col = if (std.mem.eql(u8, task, "picture_layers")) @intCast((n + 1) % 2) else 0,
                .row = 0,
                .cols = 2,
                .rows = 2,
            } });
            out.clearRetainingCapacity();
            const draw_start = if (timed and heavy) std.Io.Clock.now(.awake, init.io).toNanoseconds() else 0;
            const stats = try renderer.draw(&out.writer, s, if (picture) &layers else null, caps);
            if (timed and heavy) style_elapsed += std.Io.Clock.now(.awake, init.io).toNanoseconds() - draw_start;
            bytes += out.written().len;
            count += stats.cells;
            std.mem.doNotOptimizeAway(out.written());
            if (check) hex(out.written());
        }
    }
    const elapsed = if (timed and heavy) style_elapsed else if (timed) std.Io.Clock.now(.awake, init.io).toNanoseconds() - start else 0;
    emit("result\t{d}\t{d}\t{d}\t{d}\n", .{ iterations, count, bytes, elapsed });
}
