//! RGBA storage and bounded, antialiased terminal drawing primitives.
//! Pixels are straight alpha. No palette, glow, transport or clock lives here.
const std = @import("std");
const visor = @import("visor");

pub const Blend = enum { normal, additive };

/// A pixel stroke. Width is in output pixels, independent of plot bounds.
pub const Paint = struct {
    rgba: [4]u8 = .{ 255, 255, 255, 255 },
    blend: Blend = .normal,
    width: f64 = 1,
};

/// Owned RGBA storage. Borrow pixels until resize or deinit; drawing never reallocates.
pub const Surface = struct {
    /// Private.
    gpa: std.mem.Allocator,
    /// Private.
    width: u32,
    /// Private.
    height: u32,
    /// Private.
    own_pixels: []u8,

    /// What `init` and `resize` fail with: memory, or a size that is zero or
    /// too many bytes to address.
    pub const InitError = std.mem.Allocator.Error || error{InvalidSize};
    /// The same as `InitError`.
    pub const ResizeError = InitError;

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) InitError!Surface {
        if (width == 0 or height == 0 or @as(u64, width) * height > std.math.maxInt(usize) / 4) return error.InvalidSize;
        const storage = try gpa.alloc(u8, @as(usize, width) * height * 4);
        @memset(storage, 0);
        return .{ .gpa = gpa, .width = width, .height = height, .own_pixels = storage };
    }

    /// Dimensions copied from the geometry this allocation owns.
    pub fn dimensions(s: *const Surface) visor.Pixels {
        return .{ .width = s.width, .height = s.height };
    }

    /// Straight-alpha RGBA bytes borrowed read-only until resize or deinit.
    pub fn pixels(s: *const Surface) []const u8 {
        return s.own_pixels;
    }

    /// Straight-alpha RGBA bytes borrowed for editing until resize or deinit.
    /// The slice's descriptor is a copy; storage and bounds stay with Surface.
    pub fn pixelsMut(s: *Surface) []u8 {
        return s.own_pixels;
    }

    /// Replaces geometry and storage together with a cleared surface.
    /// An unchanged size keeps pixels and borrows; failure leaves them intact.
    pub fn resize(s: *Surface, width: u32, height: u32) ResizeError!void {
        if (s.width == width and s.height == height) return;
        const prepared = try Surface.init(s.gpa, width, height);
        s.gpa.free(s.own_pixels);
        s.* = prepared;
    }

    pub fn deinit(s: *Surface) void {
        s.gpa.free(s.own_pixels);
        s.* = undefined;
    }

    pub fn clear(s: *Surface) void {
        @memset(s.own_pixels, 0);
    }

    fn blend(s: *Surface, x: u32, y: u32, paint: Paint, coverage: f64) void {
        const a = coverage * @as(f64, @floatFromInt(paint.rgba[3])) / 255;
        if (a <= 0) return;
        const i = (@as(usize, y) * s.width + x) * 4;
        const old = @as(f64, @floatFromInt(s.own_pixels[i + 3])) / 255;
        const alpha = switch (paint.blend) {
            .normal => a + old * (1 - a),
            .additive => @min(1, a + old),
        };
        for (0..3) |k| {
            const src: f64 = @floatFromInt(paint.rgba[k]);
            const dst: f64 = @floatFromInt(s.own_pixels[i + k]);
            const value = switch (paint.blend) {
                .normal => (src * a + dst * old * (1 - a)) / alpha,
                .additive => dst + src * a,
            };
            s.own_pixels[i + k] = @intFromFloat(@round(std.math.clamp(value, 0, 255)));
        }
        s.own_pixels[i + 3] = @intFromFloat(@round(alpha * 255));
    }

    /// A round-ended stroke, clipped to the output before visiting pixels.
    pub fn line(s: *Surface, a: [2]f64, b: [2]f64, paint: Paint) void {
        if (!valid(a) or !valid(b) or !std.math.isFinite(paint.width) or paint.width <= 0) return;
        const r = paint.width / 2;
        const area = s.box(.{ @min(a[0], b[0]) - r - 0.5, @min(a[1], b[1]) - r - 0.5 }, .{ @max(a[0], b[0]) + r + 0.5, @max(a[1], b[1]) + r + 0.5 });
        if (needsWide(a) or needsWide(b) or paint.width > 1e50) {
            s.lineWide(a, b, paint, area);
            return;
        }
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
        if (needsWide(center) or needsWide(radii) or @min(radii[0], radii[1]) < 1e-50 or paint.width > 1e50) {
            s.ellipseWith(f128, center, radii, filled, paint, area);
        } else {
            s.ellipseWith(f64, center, radii, filled, paint, area);
        }
    }

    // Normal form avoids subtracting enormous endpoint-relative projections
    // to recover a small pixel distance. f128 holds every product of f64 inputs.
    fn lineWide(s: *Surface, a: [2]f64, b: [2]f64, paint: Paint, area: [4]u32) void {
        const ax: f128 = a[0];
        const ay: f128 = a[1];
        const bx: f128 = b[0];
        const by: f128 = b[1];
        const dx = bx - ax;
        const dy = by - ay;
        const length = @sqrt(dx * dx + dy * dy);
        const ux = if (length == 0) 0 else dx / length;
        const uy = if (length == 0) 0 else dy / length;
        const first = ax * ux + ay * uy;
        const last = bx * ux + by * uy;
        const offset = if (length == 0) 0 else (ax * by - ay * bx) / length;
        const r = @as(f128, paint.width) / 2;
        var y = area[1];
        while (y < area[3]) : (y += 1) {
            var x = area[0];
            while (x < area[2]) : (x += 1) {
                const px: f128 = @floatFromInt(x);
                const py: f128 = @floatFromInt(y);
                const projection = px * ux + py * uy;
                const ex = px - (if (projection <= first) ax else bx);
                const ey = py - (if (projection <= first) ay else by);
                const distance = if (length == 0 or projection <= first or projection >= last)
                    @sqrt(ex * ex + ey * ey)
                else
                    @abs(px * uy - py * ux - offset);
                s.blend(x, y, paint, @floatCast(std.math.clamp(r + 0.5 - distance, 0, 1)));
            }
        }
    }

    fn ellipseWith(s: *Surface, comptime Float: type, center: [2]f64, radii: [2]f64, filled: bool, paint: Paint, area: [4]u32) void {
        const rx: Float = radii[0];
        const ry: Float = radii[1];
        const half = if (filled) 0 else @as(Float, paint.width) / 2;
        var y = area[1];
        while (y < area[3]) : (y += 1) {
            var x = area[0];
            while (x < area[2]) : (x += 1) {
                const nx = (@as(Float, @floatFromInt(x)) - @as(Float, center[0])) / rx;
                const ny = (@as(Float, @floatFromInt(y)) - @as(Float, center[1])) / ry;
                const norm = @sqrt(nx * nx + ny * ny);
                // The gradient converts the implicit ellipse to pixel distance.
                const gx = nx / rx;
                const gy = ny / ry;
                const gradient = if (norm == 0) 1 / @min(rx, ry) else @sqrt(gx * gx + gy * gy) / norm;
                const distance = (norm - 1) / gradient;
                const coverage = if (filled) 0.5 - distance else half + 0.5 - @abs(distance);
                s.blend(x, y, paint, @floatCast(std.math.clamp(coverage, 0, 1)));
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

// Squared distances and ellipse gradients stay within f64 in this range.
fn needsWide(p: [2]f64) bool {
    return @abs(p[0]) > 1e50 or @abs(p[1]) > 1e50;
}
