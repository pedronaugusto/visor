const std = @import("std");
const visor = @import("visor");
const Canvas = @import("canvas.zig").Canvas;
const Harness = @import("harness.zig").Harness;
const t = std.testing;

test "canvas pixels blend straight alpha and additive light" {
    if (comptime !@hasDecl(Canvas, "Surface")) return t.expect(false);
    var s = try Canvas.Surface.init(t.allocator, 3, 3);
    defer s.deinit();
    const p = (Canvas{ .x_bounds = .{ 0, 2 }, .y_bounds = .{ 0, 2 } }).raster(&s);
    p.point(1, 1, .{ .rgba = .{ 200, 100, 0, 128 } });
    try t.expectEqualSlices(u8, &.{ 200, 100, 0, 128 }, s.pixels[16..20]);
    p.point(1, 1, .{ .rgba = .{ 0, 100, 200, 128 } });
    try t.expectEqualSlices(u8, &.{ 66, 100, 134, 192 }, s.pixels[16..20]);
    s.clear();
    p.point(1, 1, .{ .rgba = .{ 100, 0, 0, 255 }, .blend = .additive });
    p.point(1, 1, .{ .rgba = .{ 100, 0, 0, 255 }, .blend = .additive });
    try t.expectEqualSlices(u8, &.{ 200, 0, 0, 255 }, s.pixels[16..20]);
}

test "canvas pixel golden covers shapes and clipped antialiasing" {
    if (comptime !@hasDecl(Canvas, "Surface")) return t.expect(false);
    var s = try Canvas.Surface.init(t.allocator, 5, 5);
    defer s.deinit();
    const p = (Canvas{ .x_bounds = .{ 0, 4 }, .y_bounds = .{ 0, 4 } }).raster(&s);
    p.line(-100, 2, 100, 2, .{ .rgba = .{ 255, 0, 0, 255 } });
    const alpha = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (alpha, 0..) |a, i| try t.expectEqual(a, s.pixels[i * 4 + 3]);
    s.clear();
    p.line(-100, 4.25, 100, 4.25, .{});
    try t.expectEqual(@as(u8, 191), s.pixels[3]);
    s.clear();
    p.line(0, 0, 4, 4, .{});
    try t.expect(s.pixels[(3 * 5 + 0) * 4 + 3] > 0);
    try t.expect(s.pixels[(3 * 5 + 0) * 4 + 3] < 255);
    s.clear();
    p.disc(2, 2, 1, .{});
    try t.expectEqual(@as(u8, 255), s.pixels[(2 * 5 + 2) * 4 + 3]);
    try t.expectEqual(@as(u8, 128), s.pixels[(2 * 5 + 3) * 4 + 3]);
    try t.expectEqual(@as(u8, 0), s.pixels[3]);
    s.clear();
    p.circle(2, 2, 1, .{});
    try t.expectEqual(@as(u8, 0), s.pixels[(2 * 5 + 2) * 4 + 3]);
    try t.expectEqual(@as(u8, 255), s.pixels[(2 * 5 + 3) * 4 + 3]);
    p.rect(0, 0, 4, 4, .{});
    p.points(&.{.{ 2, 2 }}, .{});
    p.map(&.{&.{ .{ 0, 0 }, .{ 1, 1 } }}, .{});
    for ([_]f64{ std.math.inf(f64), std.math.nan(f64) }) |bad| {
        const before = std.hash.Wyhash.hash(0, s.pixels);
        p.line(bad, 0, 1, 1, .{});
        p.circle(0, 0, bad, .{});
        try t.expectEqual(before, std.hash.Wyhash.hash(0, s.pixels));
    }
    try t.expectError(error.InvalidSize, Canvas.Surface.init(t.allocator, std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "canvas shapes use sextant and braille fallback or the picture owner" {
    if (comptime !@hasDecl(Canvas, "Surface")) return t.expect(false);
    var h = try Harness.init(t.allocator, 2, 1);
    defer h.deinit();
    const shapes: []const Canvas.Shape = &.{.{ .geometry = .{ .line = .{ 0, 0.5, 1, 0.5 } } }};
    try (Canvas{ .marker = .sextant }).draw(h.window(), shapes, .{});
    try h.expectFrame("🬋🬋\n");
    h.screen.clear();
    try (Canvas{}).draw(h.window(), shapes, .{});
    try h.expectFrame("⠒⠒\n");
    var surface = try Canvas.Surface.init(t.allocator, 8, 8);
    defer surface.deinit();
    var layers: visor.Layers = .init(t.allocator);
    defer layers.deinit();
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    h.screen.clear();
    try (Canvas{}).draw(h.window(), shapes, .{ .caps = .{ .kitty_graphics = true }, .picture = .{ .surface = &surface, .layers = &layers, .writer = &out.writer, .allocator = t.allocator, .image = 10 } });
    try t.expectEqual(@as(u32, 8), layers.image(10).?.width);
    _ = try layers.commitFrame(&out.writer, .{ .kitty_graphics = true });
    try t.expectEqual(@as(usize, 1), layers.count());
    try h.expectFrame("\n");
    const cells = (Canvas{ .marker = .block, .x_bounds = .{ 0, 4 }, .y_bounds = .{ 0, 2 } }).painter(h.window());
    try cells.circle(2, 1, 1, .{});
    try cells.disc(2, 1, 0.1, .{});
    try cells.points(&.{.{ 0, 0 }}, .{});
    try cells.map(&.{&.{ .{ -100, 2 }, .{ 100, 2 } }}, .{});
    _ = try h.frame();
}

test "raster lines keep finite extreme coordinates through their arithmetic" {
    var surface = try Canvas.Surface.init(t.allocator, 3, 3);
    defer surface.deinit();
    const extreme = std.math.floatMax(f64);
    surface.line(.{ -extreme, -extreme }, .{ extreme, extreme }, .{});
    const alpha = [_]u8{ 255, 75, 0, 75, 255, 75, 0, 75, 255 };
    for (alpha, 0..) |expected, i| try t.expectEqual(expected, surface.pixels[i * 4 + 3]);
}

test "raster ellipses keep tiny finite radii through their arithmetic" {
    var surface = try Canvas.Surface.init(t.allocator, 3, 3);
    defer surface.deinit();
    surface.ellipse(.{ 0, 0 }, .{ std.math.floatMin(f64), 1 }, false, .{ .width = 2 });
    try t.expectEqual(@as(u8, 255), surface.pixels[3]);
    try t.expectEqual(@as(u8, 128), surface.pixels[7]);
    try t.expectEqual(@as(u8, 0), surface.pixels[11]);
}
