//! RGBA storage and bounded, antialiased terminal drawing primitives.
//! Pixels are straight alpha. No palette, glow, transport or clock lives here.
const std = @import("std");

pub const Blend = enum { normal, additive };

/// A pixel stroke. Width is in output pixels, independent of plot bounds.
pub const Paint = struct {
    rgba: [4]u8 = .{ 255, 255, 255, 255 },
    blend: Blend = .normal,
    width: f64 = 1,
};

/// Caller-owned RGBA storage. Borrow `pixels` until deinit; drawing never reallocates.
pub const Surface = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) (std.mem.Allocator.Error || error{InvalidSize})!Surface {
        if (width == 0 or height == 0 or @as(u64, width) * height > std.math.maxInt(usize) / 4) return error.InvalidSize;
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        @memset(pixels, 0);
        return .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(s: *Surface) void {
        s.allocator.free(s.pixels);
        s.* = undefined;
    }

    pub fn clear(s: *Surface) void {
        @memset(s.pixels, 0);
    }

    fn blend(s: *Surface, x: u32, y: u32, paint: Paint, coverage: f64) void {
        const a = coverage * @as(f64, @floatFromInt(paint.rgba[3])) / 255;
        if (a <= 0) return;
        const i = (@as(usize, y) * s.width + x) * 4;
        const old = @as(f64, @floatFromInt(s.pixels[i + 3])) / 255;
        const alpha = switch (paint.blend) {
            .normal => a + old * (1 - a),
            .additive => @min(1, a + old),
        };
        for (0..3) |k| {
            const src: f64 = @floatFromInt(paint.rgba[k]);
            const dst: f64 = @floatFromInt(s.pixels[i + k]);
            const value = switch (paint.blend) {
                .normal => (src * a + dst * old * (1 - a)) / alpha,
                .additive => dst + src * a,
            };
            s.pixels[i + k] = @intFromFloat(@round(std.math.clamp(value, 0, 255)));
        }
        s.pixels[i + 3] = @intFromFloat(@round(alpha * 255));
    }

    /// A round-ended stroke, clipped to the output before visiting pixels.
    pub fn line(s: *Surface, a: [2]f64, b: [2]f64, paint: Paint) void {
        if (!valid(a) or !valid(b) or !std.math.isFinite(paint.width) or paint.width <= 0) return;
        const r = paint.width / 2;
        const area = s.box(.{ @min(a[0], b[0]) - r - 0.5, @min(a[1], b[1]) - r - 0.5 }, .{ @max(a[0], b[0]) + r + 0.5, @max(a[1], b[1]) + r + 0.5 });
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const length = dx * dx + dy * dy;
        var y = area[1];
        while (y < area[3]) : (y += 1) {
            var x = area[0];
            while (x < area[2]) : (x += 1) {
                const px: f64 = @floatFromInt(x);
                const py: f64 = @floatFromInt(y);
                const t = if (length == 0) 0 else std.math.clamp(((px - a[0]) * dx + (py - a[1]) * dy) / length, 0, 1);
                const ex = px - a[0] - t * dx;
                const ey = py - a[1] - t * dy;
                s.blend(x, y, paint, std.math.clamp(r + 0.5 - @sqrt(ex * ex + ey * ey), 0, 1));
            }
        }
    }

    /// A circle transformed into an ellipse by the plot's axes.
    pub fn ellipse(s: *Surface, center: [2]f64, radii: [2]f64, filled: bool, paint: Paint) void {
        if (!valid(center) or !valid(radii) or radii[0] <= 0 or radii[1] <= 0 or !std.math.isFinite(paint.width) or paint.width <= 0) return;
        const half = if (filled) 0 else paint.width / 2;
        const area = s.box(.{ center[0] - radii[0] - half - 0.5, center[1] - radii[1] - half - 0.5 }, .{ center[0] + radii[0] + half + 0.5, center[1] + radii[1] + half + 0.5 });
        var y = area[1];
        while (y < area[3]) : (y += 1) {
            var x = area[0];
            while (x < area[2]) : (x += 1) {
                const nx = (@as(f64, @floatFromInt(x)) - center[0]) / radii[0];
                const ny = (@as(f64, @floatFromInt(y)) - center[1]) / radii[1];
                const norm = @sqrt(nx * nx + ny * ny);
                // The gradient converts the implicit ellipse to pixel distance.
                const gradient = if (norm == 0) 1 / @min(radii[0], radii[1]) else @sqrt((nx / radii[0]) * (nx / radii[0]) + (ny / radii[1]) * (ny / radii[1])) / norm;
                const distance = (norm - 1) / gradient;
                const coverage = if (filled) 0.5 - distance else half + 0.5 - @abs(distance);
                s.blend(x, y, paint, std.math.clamp(coverage, 0, 1));
            }
        }
    }

    fn box(s: Surface, low: [2]f64, high: [2]f64) [4]u32 {
        return .{
            edge(@ceil(low[0]), s.width),       edge(@ceil(low[1]), s.height),
            edge(@floor(high[0]) + 1, s.width), edge(@floor(high[1]) + 1, s.height),
        };
    }
};

fn edge(v: f64, limit: u32) u32 {
    return @intFromFloat(std.math.clamp(v, 0, @as(f64, @floatFromInt(limit))));
}
fn valid(p: [2]f64) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]);
}
