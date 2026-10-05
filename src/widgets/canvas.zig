//! Shapes in plot coordinates, drawn into cells or a caller-owned RGBA surface.
//! The cell painter writes immediately. The raster painter allocates nothing;
//! Layers owns transmission and placement of its pixels.

const std = @import("std");
const visor = @import("visor");

const sextants = @import("sextants.zig");

/// What a canvas draws its marks with.
pub const Marker = enum {
    /// Eight marks a cell, two across and four down. The sharpest, and the
    /// one that needs a font with braille in it.
    braille,
    /// Six marks a cell, two across and three down, as block sextants: solid
    /// where braille is dotted, so a filled shape reads as filled.
    sextant,
    /// One mark a cell, a full block.
    block,
    /// Two marks a cell, one above the other.
    half_block,
    /// One mark a cell, a round dot.
    dot,
    /// One mark a cell, a bar along the bottom.
    bar,

    /// How many marks fit across a cell.
    pub fn across(m: Marker) u8 {
        return switch (m) {
            .braille, .sextant => 2,
            .block, .half_block, .dot, .bar => 1,
        };
    }

    /// How many marks fit down a cell.
    pub fn down(m: Marker) u8 {
        return switch (m) {
            .braille => 4,
            .sextant => 3,
            .half_block => 2,
            .block, .dot, .bar => 1,
        };
    }
};

/// Which braille dot a place inside a cell is, as the bit that turns it on.
const braille_bits = [4][2]u8{
    .{ 0x01, 0x08 },
    .{ 0x02, 0x10 },
    .{ 0x04, 0x20 },
    .{ 0x40, 0x80 },
};

/// The first braille cell, the one with no dots in it.
const braille_base: u21 = 0x2800;

/// A plane to draw shapes on, in the caller's own coordinates.
pub const Canvas = struct {
    pub const Surface = @import("canvas/raster.zig").Surface;
    pub const Paint = @import("canvas/raster.zig").Paint;
    pub const Blend = @import("canvas/raster.zig").Blend;

    /// One terminal plotting shape. Maps borrow separate contours in plot
    /// coordinates; longitude and latitude fit bounds [-180,180], [-90,90].
    pub const Shape = struct {
        geometry: union(enum) {
            point: [2]f64,
            line: [4]f64,
            rectangle: [4]f64,
            circle: [3]f64,
            disc: [3]f64,
            points: []const [2]f64,
            polyline: []const [2]f64,
            map: []const []const [2]f64,
        },
        paint: Paint = .{},
        /// Cell attributes; foreground comes from paint.rgba.
        style: visor.Style = .{},
    };

    /// Borrowed picture resources. The caller chooses ids and retires them
    /// through Layers, or uses Replacement with raster() for animated scenes.
    pub const Picture = struct {
        surface: *Surface,
        layers: *visor.Layers,
        writer: *std.Io.Writer,
        image: u32,
        placement: u32 = 1,
        order: visor.Layer.Order = .{},
        /// Palette for sixel output. The caller chooses the quantization.
        sixel_palette: []const visor.morse.Rgb = &.{},
    };
    pub const DrawOptions = struct {
        caps: visor.Caps = .{},
        picture: ?Picture = null,
    };

    /// Paint to pictures when supported and supplied; otherwise use marker.
    /// A picture surface is cleared and fitted to the window. Pixels use
    /// straight alpha; empty cell marks leave the window's contents alone.
    pub fn draw(c: Canvas, win: visor.Window, shapes: []const Shape, options: DrawOptions) !void {
        if (win.rect().isEmpty()) return;
        const protocol = options.caps.pictures();
        if (protocol == .kitty or protocol == .sixel) {
            if (options.picture) |pic| {
                pic.surface.clear();
                const p = c.raster(pic.surface);
                for (shapes) |shape| drawShape(p, shape.geometry, shape.paint);
                if (protocol == .kitty) {
                    _ = try pic.layers.transmit(pic.writer, pic.image, pic.surface.pixels(), .{ .width = pic.surface.dimensions().width, .height = pic.surface.dimensions().height });
                } else {
                    try pic.layers.storeSixel(pic.image, .{ .width = pic.surface.dimensions().width, .height = pic.surface.dimensions().height, .pixels = .{ .rgba = pic.surface.pixels() }, .palette = pic.sixel_palette });
                }
                try pic.layers.declare(.{ .image = pic.image, .placement = pic.placement, .rect = win.rect(), .order = pic.order });
                return;
            }
        }
        const p = c.painter(win);
        for (shapes) |shape| {
            if (shape.paint.rgba[3] == 0) continue;
            var style = shape.style;
            style.fg = .rgb(shape.paint.rgba[0], shape.paint.rgba[1], shape.paint.rgba[2]);
            try drawShape(p, shape.geometry, style);
        }
    }

    /// The same plot bound to RGBA storage. Borrowed for the painter's life.
    pub fn raster(c: Canvas, surface: *Surface) Raster {
        return .{ .canvas = c, .surface = surface };
    }

    /// What the left and right edges of the window are worth.
    x_bounds: [2]f64 = .{ 0, 1 },
    /// What the bottom and top edges are worth. The first is the bottom,
    /// because a plot's y axis counts upward and a grid's rows count down,
    /// and one of the two has to say so.
    y_bounds: [2]f64 = .{ 0, 1 },
    /// What marks are drawn with.
    marker: Marker = .braille,

    /// A canvas bound to a window, which is what shapes are drawn through.
    pub fn painter(c: Canvas, win: visor.Window) Painter {
        return .{ .canvas = c, .win = win };
    }
};

/// A canvas bound to a window.
pub const Painter = struct {
    /// The plane's coordinates and marker.
    canvas: Canvas,
    /// The window the marks land in.
    win: visor.Window,

    /// A place on the plane as a place on the mark grid, or null when it
    /// falls outside.
    pub fn locate(p: Painter, x: f64, y: f64) ?struct { x: u32, y: u32 } {
        const across = @as(u32, p.win.cols()) * p.canvas.marker.across();
        const down = @as(u32, p.win.rows()) * p.canvas.marker.down();
        if (across == 0 or down == 0) return null;

        const gx = place(x, p.canvas.x_bounds, across) orelse return null;
        const gy = place(y, p.canvas.y_bounds, down) orelse return null;
        // The plane counts upward and the grid counts down.
        return .{ .x = gx, .y = down - 1 - gy };
    }

    /// One mark.
    pub fn point(p: Painter, x: f64, y: f64, style: visor.Style) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        const at = p.locate(x, y) orelse return;
        try p.mark(at.x, at.y, style);
    }

    /// A straight line between two places, by the oldest algorithm there is.
    pub fn line(p: Painter, x1: f64, y1: f64, x2: f64, y2: f64, style: visor.Style) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        const clipped = clipSegment(x1, y1, x2, y2, p.canvas.x_bounds, p.canvas.y_bounds) orelse return;
        const a = p.locate(clipped[0], clipped[1]) orelse return;
        const b = p.locate(clipped[2], clipped[3]) orelse return;
        var x: i64 = a.x;
        var y: i64 = a.y;
        const tx: i64 = b.x;
        const ty: i64 = b.y;
        const dx = @abs(tx - x);
        const dy = @abs(ty - y);
        const sx: i64 = if (x < tx) 1 else -1;
        const sy: i64 = if (y < ty) 1 else -1;
        var err: i64 = @as(i64, @intCast(dx)) - @as(i64, @intCast(dy));
        while (true) {
            try p.mark(@intCast(x), @intCast(y), style);
            if (x == tx and y == ty) break;
            const e2 = err * 2;
            if (e2 > -@as(i64, @intCast(dy))) {
                err -= @intCast(dy);
                x += sx;
            }
            if (e2 < @as(i64, @intCast(dx))) {
                err += @intCast(dx);
                y += sy;
            }
        }
    }

    /// The outline of a rectangle, in the plane's coordinates.
    pub fn rect(
        p: Painter,
        x: f64,
        y: f64,
        cols: f64,
        rows: f64,
        style: visor.Style,
    ) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        try p.line(x, y, x + cols, y, style);
        try p.line(x + cols, y, x + cols, y + rows, style);
        try p.line(x + cols, y + rows, x, y + rows, style);
        try p.line(x, y + rows, x, y, style);
    }

    /// Every point of a series, joined.
    pub fn polyline(p: Painter, coords: []const [2]f64, style: visor.Style) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        if (coords.len == 0) return;
        if (coords.len == 1) return p.point(coords[0][0], coords[0][1], style);
        for (coords[1..], 0..) |b, i| {
            const a = coords[i];
            try p.line(a[0], a[1], b[0], b[1], style);
        }
    }

    /// Every point independently, for a scatter plot.
    pub fn points(p: Painter, coords: []const [2]f64, style: visor.Style) !void {
        for (coords) |at| try p.point(at[0], at[1], style);
    }

    /// Separate contours, with no line joining one contour to the next.
    pub fn map(p: Painter, contours: []const []const [2]f64, style: visor.Style) !void {
        for (contours) |path| try p.polyline(path, style);
    }

    pub fn circle(p: Painter, x: f64, y: f64, radius: f64, style: visor.Style) !void {
        try p.round(x, y, radius, false, style);
    }

    pub fn disc(p: Painter, x: f64, y: f64, radius: f64, style: visor.Style) !void {
        try p.round(x, y, radius, true, style);
    }

    fn round(p: Painter, x: f64, y: f64, radius: f64, filled: bool, style: visor.Style) !void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(radius) or radius < 0) return;
        if (radius == 0) return p.point(x, y, style);
        const across = @as(u32, p.win.cols()) * p.canvas.marker.across();
        const down = @as(u32, p.win.rows()) * p.canvas.marker.down();
        if (!boundsValid(p.canvas) or across == 0 or down == 0) return;
        const center = project(p.canvas, x, y, across, down);
        const radii = projectRadius(p.canvas, radius, across, down);
        // Cell marks are binary, so visit the finite mark grid and test the
        // ellipse there. No coordinate-dependent iteration or scratch grid.
        var gy: u32 = 0;
        while (gy < down) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < across) : (gx += 1) {
                const nx = (@as(f64, @floatFromInt(gx)) - center[0]) / radii[0];
                const ny = (@as(f64, @floatFromInt(gy)) - center[1]) / radii[1];
                const norm = @sqrt(nx * nx + ny * ny);
                if (if (filled) norm <= 1 else @abs(norm - 1) * @min(radii[0], radii[1]) <= 0.5) try p.mark(gx, gy, style);
            }
        }
    }

    /// One mark on the grid, combined with whatever is already in its cell.
    fn mark(p: Painter, gx: u32, gy: u32, style: visor.Style) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        const across = p.canvas.marker.across();
        const down = p.canvas.marker.down();
        const col: u16 = @intCast(gx / across);
        const row: u16 = @intCast(gy / down);
        if (col >= p.win.cols() or row >= p.win.rows()) return;

        switch (p.canvas.marker) {
            .braille => {
                const bit = braille_bits[gy % down][gx % across];
                var bytes: [4]u8 = undefined;
                const now = existing(p.win, col, row);
                const cp = std.unicode.utf8Decode(now) catch braille_base;
                const had: u8 = if (cp >= braille_base and cp <= braille_base + 0xff)
                    @intCast(cp - braille_base)
                else
                    0;
                const n = std.unicode.utf8Encode(braille_base + (had | bit), &bytes) catch return;
                try p.win.write(col, row, bytes[0..n], style, .none);
            },
            .sextant => {
                const bit: u6 = @as(u6, 1) << @intCast((gy % down) * 2 + gx % across);
                const had = sextants.maskOf(existing(p.win, col, row)) orelse 0;
                try p.win.write(col, row, sextants.sextant(had | bit), style, .none);
            },
            .half_block => {
                const now = existing(p.win, col, row);
                const top = std.mem.eql(u8, now, "\u{2580}") or std.mem.eql(u8, now, "\u{2588}");
                const bottom = std.mem.eql(u8, now, "\u{2584}") or std.mem.eql(u8, now, "\u{2588}");
                const wants_top = gy % down == 0;
                const glyph = glyphFor(top or wants_top, bottom or !wants_top);
                try p.win.write(col, row, glyph, style, .none);
            },
            .block => try p.win.write(col, row, "\u{2588}", style, .none),
            .dot => try p.win.write(col, row, "\u{2022}", style, .none),
            .bar => try p.win.write(col, row, "\u{2584}", style, .none),
        }
    }

    /// The half-block glyph for a cell with those halves lit.
    fn glyphFor(top: bool, bottom: bool) []const u8 {
        if (top and bottom) return "\u{2588}";
        if (top) return "\u{2580}";
        return "\u{2584}";
    }

    /// What is in a cell now, or a space when there is nothing there.
    ///
    /// Read out of the screen rather than out of a copy of the cell: a
    /// grapheme short enough to live in the cell is a slice of the cell, so
    /// a copy's bytes are gone by the time the caller looks at them.
    fn existing(win: visor.Window, col: u16, row: u16) []const u8 {
        if (col >= win.cols() or row >= win.rows()) return " ";
        return win.screen().textAt(win.rect().col + col, win.rect().row + row);
    }
};

/// Plot coordinates mapped to an antialiased pixel painter.
pub const Raster = struct {
    canvas: Canvas,
    surface: *Canvas.Surface,

    pub fn point(p: Raster, x: f64, y: f64, paint: Canvas.Paint) void {
        if (!boundsValid(p.canvas) or !std.math.isFinite(x) or !std.math.isFinite(y)) return;
        const at = project(p.canvas, x, y, p.surface.dimensions().width, p.surface.dimensions().height);
        p.surface.line(at, at, paint);
    }
    pub fn line(p: Raster, x1: f64, y1: f64, x2: f64, y2: f64, paint: Canvas.Paint) void {
        if (!boundsValid(p.canvas) or !std.math.isFinite(x1) or !std.math.isFinite(y1) or !std.math.isFinite(x2) or !std.math.isFinite(y2) or !std.math.isFinite(paint.width) or paint.width <= 0) return;
        const a = project(p.canvas, x1, y1, p.surface.dimensions().width, p.surface.dimensions().height);
        const b = project(p.canvas, x2, y2, p.surface.dimensions().width, p.surface.dimensions().height);
        const margin = paint.width / 2 + 0.5;
        const seg = clipSegment(a[0], a[1], b[0], b[1], .{ -margin, @as(f64, @floatFromInt(p.surface.dimensions().width - 1)) + margin }, .{ -margin, @as(f64, @floatFromInt(p.surface.dimensions().height - 1)) + margin }) orelse return;
        p.surface.line(.{ seg[0], seg[1] }, .{ seg[2], seg[3] }, paint);
    }
    pub fn rect(p: Raster, x: f64, y: f64, width: f64, height: f64, paint: Canvas.Paint) void {
        p.line(x, y, x + width, y, paint);
        p.line(x + width, y, x + width, y + height, paint);
        p.line(x + width, y + height, x, y + height, paint);
        p.line(x, y + height, x, y, paint);
    }
    pub fn circle(p: Raster, x: f64, y: f64, radius: f64, paint: Canvas.Paint) void {
        p.round(x, y, radius, false, paint);
    }
    pub fn disc(p: Raster, x: f64, y: f64, radius: f64, paint: Canvas.Paint) void {
        p.round(x, y, radius, true, paint);
    }
    fn round(p: Raster, x: f64, y: f64, radius: f64, filled: bool, paint: Canvas.Paint) void {
        if (!boundsValid(p.canvas) or !std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(radius) or radius < 0) return;
        if (radius == 0) return p.point(x, y, paint);
        p.surface.ellipse(project(p.canvas, x, y, p.surface.dimensions().width, p.surface.dimensions().height), projectRadius(p.canvas, radius, p.surface.dimensions().width, p.surface.dimensions().height), filled, paint);
    }
    pub fn points(p: Raster, coords: []const [2]f64, paint: Canvas.Paint) void {
        for (coords) |at| p.point(at[0], at[1], paint);
    }
    pub fn polyline(p: Raster, coords: []const [2]f64, paint: Canvas.Paint) void {
        if (coords.len == 1) p.point(coords[0][0], coords[0][1], paint);
        if (coords.len < 2) return;
        for (coords[1..], 0..) |b, i| p.line(coords[i][0], coords[i][1], b[0], b[1], paint);
    }
    pub fn map(p: Raster, contours: []const []const [2]f64, paint: Canvas.Paint) void {
        for (contours) |path| p.polyline(path, paint);
    }
};

fn drawShape(p: anytype, geometry: @FieldType(Canvas.Shape, "geometry"), paint: anytype) if (@TypeOf(p) == Raster) void else anyerror!void {
    switch (geometry) {
        .point => |v| return p.point(v[0], v[1], paint),
        .line => |v| return p.line(v[0], v[1], v[2], v[3], paint),
        .rectangle => |v| return p.rect(v[0], v[1], v[2], v[3], paint),
        .circle => |v| return p.circle(v[0], v[1], v[2], paint),
        .disc => |v| return p.disc(v[0], v[1], v[2], paint),
        .points => |v| return p.points(v, paint),
        .polyline => |v| return p.polyline(v, paint),
        .map => |v| return p.map(v, paint),
    }
}

fn boundsValid(c: Canvas) bool {
    return std.math.isFinite(c.x_bounds[0]) and std.math.isFinite(c.x_bounds[1]) and c.x_bounds[0] != c.x_bounds[1] and
        std.math.isFinite(c.y_bounds[0]) and std.math.isFinite(c.y_bounds[1]) and c.y_bounds[0] != c.y_bounds[1];
}
fn bounded(v: f128) f64 {
    // Keep squared distances finite even for finite f64 extremes.
    return @floatCast(std.math.clamp(v, -1e100, 1e100));
}
fn project(c: Canvas, x: f64, y: f64, width: u32, height: u32) [2]f64 {
    const xmin: f128 = @min(c.x_bounds[0], c.x_bounds[1]);
    const ymin: f128 = @min(c.y_bounds[0], c.y_bounds[1]);
    const xs = @as(f128, @max(c.x_bounds[0], c.x_bounds[1])) - xmin;
    const ys = @as(f128, @max(c.y_bounds[0], c.y_bounds[1])) - ymin;
    return .{ bounded((@as(f128, x) - xmin) / xs * @as(f128, @floatFromInt(width - 1))), bounded((1 - (@as(f128, y) - ymin) / ys) * @as(f128, @floatFromInt(height - 1))) };
}
fn projectRadius(c: Canvas, radius: f64, width: u32, height: u32) [2]f64 {
    return .{ @max(1e-100, bounded(@as(f128, radius) / @abs(@as(f128, c.x_bounds[1]) - c.x_bounds[0]) * @as(f128, @floatFromInt(width - 1)))), @max(1e-100, bounded(@as(f128, radius) / @abs(@as(f128, c.y_bounds[1]) - c.y_bounds[0]) * @as(f128, @floatFromInt(height - 1)))) };
}

/// Clips a segment to the canvas rectangle before it is quantized to marks.
fn clipSegment(x1: f64, y1: f64, x2: f64, y2: f64, xb: [2]f64, yb: [2]f64) ?[4]f64 {
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1) or
        !std.math.isFinite(x2) or !std.math.isFinite(y2) or
        !std.math.isFinite(xb[0]) or !std.math.isFinite(xb[1]) or
        !std.math.isFinite(yb[0]) or !std.math.isFinite(yb[1])) return null;
    const xmin = @min(xb[0], xb[1]);
    const xmax = @max(xb[0], xb[1]);
    const ymin = @min(yb[0], yb[1]);
    const ymax = @max(yb[0], yb[1]);
    if (xmax <= xmin or ymax <= ymin) return null;
    // Intermediates must hold the difference of any two finite f64 values.
    const dx = @as(f128, x2) - x1;
    const dy = @as(f128, y2) - y1;
    var interval: [2]f128 = .{ 0, 1 };
    if (!clipEdge(-dx, @as(f128, x1) - xmin, &interval)) return null;
    if (!clipEdge(dx, @as(f128, xmax) - x1, &interval)) return null;
    if (!clipEdge(-dy, @as(f128, y1) - ymin, &interval)) return null;
    if (!clipEdge(dy, @as(f128, ymax) - y1, &interval)) return null;
    return .{
        @floatCast(std.math.clamp(@as(f128, x1) + interval[0] * dx, xmin, xmax)),
        @floatCast(std.math.clamp(@as(f128, y1) + interval[0] * dy, ymin, ymax)),
        @floatCast(std.math.clamp(@as(f128, x1) + interval[1] * dx, xmin, xmax)),
        @floatCast(std.math.clamp(@as(f128, y1) + interval[1] * dy, ymin, ymax)),
    };
}

fn clipEdge(p: f128, q: f128, interval: *[2]f128) bool {
    if (p == 0) return q >= 0;
    const r = q / p;
    if (p < 0) {
        if (r > interval[1]) return false;
        interval[0] = @max(interval[0], r);
    } else {
        if (r < interval[0]) return false;
        interval[1] = @min(interval[1], r);
    }
    return true;
}

/// Where a number falls in a range, as a mark index, or null outside it.
fn place(value: f64, bounds: [2]f64, marks: u32) ?u32 {
    if (marks == 0 or !std.math.isFinite(value) or
        !std.math.isFinite(bounds[0]) or !std.math.isFinite(bounds[1])) return null;
    const lo = @min(bounds[0], bounds[1]);
    const hi = @max(bounds[0], bounds[1]);
    if (hi <= lo) return null;
    if (value < lo or value > hi) return null;
    const span = hi - lo;
    const t = if (std.math.isFinite(span)) (value - lo) / span else (value / 2 - lo / 2) / (hi / 2 - lo / 2);
    const scaled: u32 = @intFromFloat(t * @as(f64, @floatFromInt(marks)));
    return @min(scaled, marks - 1);
}

const testing = std.testing;
const Harness = @import("../testing/widget_harness.zig").Harness;

test "a braille cell gathers every dot that lands in it" {
    var h: Harness = try .init(testing.allocator, 1, 1);
    defer h.deinit();
    const p = (Canvas{ .x_bounds = .{ 0, 2 }, .y_bounds = .{ 0, 4 } }).painter(h.window());
    // The bottom-left and the top-right dots of the one cell.
    try p.point(0, 0, .{});
    try p.point(1.5, 3.5, .{});
    try h.expectFrame(
        \\⡈
        \\
    );
}

test "a line between two corners is drawn across the cells between them" {
    var h: Harness = try .init(testing.allocator, 4, 2);
    defer h.deinit();
    const p = (Canvas{
        .x_bounds = .{ 0, 4 },
        .y_bounds = .{ 0, 2 },
        .marker = .block,
    }).painter(h.window());
    try p.line(0, 0, 3.9, 1.9, .{});
    try h.expectFrame(
        \\  ██
        \\██
        \\
    );
}

test "a rectangle is drawn as its four sides and nothing inside" {
    var h: Harness = try .init(testing.allocator, 5, 3);
    defer h.deinit();
    const p = (Canvas{
        .x_bounds = .{ 0, 5 },
        .y_bounds = .{ 0, 3 },
        .marker = .block,
    }).painter(h.window());
    try p.rect(0.5, 0.5, 3, 2, .{});
    try h.expectFrame(
        \\████
        \\█  █
        \\████
        \\
    );
}

test "half blocks put two marks in one cell" {
    var h: Harness = try .init(testing.allocator, 2, 1);
    defer h.deinit();
    const p = (Canvas{
        .x_bounds = .{ 0, 2 },
        .y_bounds = .{ 0, 2 },
        .marker = .half_block,
    }).painter(h.window());
    try p.point(0.5, 1.5, .{});
    try p.point(1.5, 0.5, .{});
    try h.expectFrame(
        \\▀▄
        \\
    );
    try p.point(0.5, 0.5, .{});
    try h.expectFrame(
        \\█▄
        \\
    );
}

test "a place outside the plane draws nothing" {
    var h: Harness = try .init(testing.allocator, 2, 1);
    defer h.deinit();
    const p = (Canvas{ .marker = .dot }).painter(h.window());
    try p.point(-1, 0.5, .{});
    try p.point(0.5, 9, .{});
    try h.expectFrame("\n");
    try testing.expectEqual(@as(?@TypeOf(p.locate(0, 0).?), null), p.locate(2, 2));
}

test "a line with one end off the plane still draws the part that is on it" {
    var h: Harness = try .init(testing.allocator, 4, 1);
    defer h.deinit();
    const p = (Canvas{
        .x_bounds = .{ 0, 4 },
        .y_bounds = .{ 0, 1 },
        .marker = .block,
    }).painter(h.window());
    try p.line(-10, 0.5, 1.5, 0.5, .{});
    try h.expectFrame(
        \\██
        \\
    );
}

test "a very long line is clipped before every visible mark is rasterized" {
    var h: Harness = try .init(testing.allocator, 4, 1);
    defer h.deinit();
    const p = (Canvas{
        .x_bounds = .{ 0, 4 },
        .y_bounds = .{ 0, 1 },
        .marker = .block,
    }).painter(h.window());
    try p.line(-1e9, 0.5, 1e9, 0.5, .{});
    try h.expectFrame(
        \\████
        \\
    );
}

test "the marks a cell holds are the marker's own" {
    try testing.expectEqual(@as(u8, 2), Marker.braille.across());
    try testing.expectEqual(@as(u8, 4), Marker.braille.down());
    try testing.expectEqual(@as(u8, 1), Marker.block.across());
    try testing.expectEqual(@as(u8, 2), Marker.half_block.down());
    try testing.expectEqual(@as(u8, 2), Marker.sextant.across());
    try testing.expectEqual(@as(u8, 3), Marker.sextant.down());
}

test "a sextant cell gathers every mark that lands in it" {
    var h: Harness = try .init(testing.allocator, 2, 1);
    defer h.deinit();
    const p = (Canvas{ .x_bounds = .{ 0, 4 }, .y_bounds = .{ 0, 3 }, .marker = .sextant }).painter(h.window());
    // The top-left and the bottom-right of the first cell.
    try p.point(0.5, 2.5, .{});
    try p.point(1.5, 0.5, .{});
    // The whole left column of the second: the left half block.
    try p.line(2.5, 0.2, 2.5, 2.8, .{});
    try h.expectFrame("\u{1fb1f}\u{258c}\n");
}

test "every point that locates to a mark puts one in that mark's cell" {
    for ([_]Marker{ .braille, .sextant, .block, .half_block, .dot, .bar }) |marker| {
        var h: Harness = try .init(testing.allocator, 4, 3);
        defer h.deinit();
        const c: Canvas = .{ .x_bounds = .{ 0, 8 }, .y_bounds = .{ 0, 12 }, .marker = marker };
        const p = c.painter(h.window());

        var x: f64 = 0;
        while (x < 8) : (x += 0.25) {
            var y: f64 = 0;
            while (y < 12) : (y += 0.25) {
                h.screen.clear();
                const at = p.locate(x, y).?;
                try p.point(x, y, .{});
                _ = try h.frame();

                const col: u16 = @intCast(at.x / marker.across());
                const row: u16 = @intCast(at.y / marker.down());
                const drawn = h.term.screen().textAt(col, row);
                try testing.expect(!std.mem.eql(u8, drawn, " "));
                if (marker == .braille) {
                    const cp = try std.unicode.utf8Decode(drawn);
                    try testing.expect(cp > braille_base and cp <= braille_base + 0xff);
                }
            }
        }
    }
}

test "canvas coordinates reject nonfinite values and retain finite extremes" {
    var h = try Harness.init(testing.allocator, 4, 2);
    defer h.deinit();
    const ordinary = (Canvas{ .marker = .block }).painter(h.window());
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| {
        try testing.expect(ordinary.locate(bad, 0) == null);
        try testing.expect(ordinary.locate(0, bad) == null);
        const invalid = (Canvas{ .x_bounds = .{ 0, bad } }).painter(h.window());
        try testing.expect(invalid.locate(0, 0) == null);
        try invalid.line(0, 0, 1, 1, .{});
    }
    const extreme = std.math.floatMax(f64);
    const wide = (Canvas{ .marker = .block, .x_bounds = .{ -extreme, extreme }, .y_bounds = .{ -extreme, extreme } }).painter(h.window());
    try testing.expectEqual(@as(u32, 0), wide.locate(-extreme, 0).?.x);
    try testing.expectEqual(@as(u32, 2), wide.locate(0, 0).?.x);
    try testing.expectEqual(@as(u32, 3), wide.locate(extreme, 0).?.x);
    try wide.line(-extreme, 0, extreme, 0, .{});
    try h.expectFrame("████\n\n");
}
