//! A plane to draw shapes on, in the caller's own coordinates.
//!
//! A canvas is a window plus two ranges: the caller says what the left and
//! right edges are worth and what the top and bottom are worth, and draws in
//! those numbers. How many marks fit in a cell is the marker's business —
//! eight for braille, one for a block — so the same drawing is sharper or
//! blunter without the code that made it changing.
//!
//! Nothing is buffered. A mark is read out of the cell it lands in, combined
//! with what is already there, and written back, so a canvas costs no memory
//! at all and two shapes that cross share the cell they cross in.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

/// What a canvas draws its marks with.
pub const Marker = enum {
    /// Eight marks a cell, two across and four down. The sharpest, and the
    /// one that needs a font with braille in it.
    braille,
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
            .braille => 2,
            .block, .half_block, .dot, .bar => 1,
        };
    }

    /// How many marks fit down a cell.
    pub fn down(m: Marker) u8 {
        return switch (m) {
            .braille => 4,
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
    /// What the left and right edges of the window are worth.
    x_bounds: [2]f64 = .{ 0, 1 },
    /// What the bottom and top edges are worth. The first is the bottom,
    /// because a plot's y axis counts upward and a grid's rows count down,
    /// and one of the two has to say so.
    y_bounds: [2]f64 = .{ 0, 1 },
    /// What marks are drawn with.
    marker: Marker = .braille,

    /// A canvas bound to a window, which is what shapes are drawn through.
    pub fn painter(c: Canvas, win: Window) Painter {
        return .{ .canvas = c, .win = win };
    }
};

/// A canvas bound to a window.
pub const Painter = struct {
    /// The plane's coordinates and marker.
    canvas: Canvas,
    /// The window the marks land in.
    win: Window,

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
    pub fn point(p: Painter, x: f64, y: f64, style: Style) std.mem.Allocator.Error!void {
        const at = p.locate(x, y) orelse return;
        try p.mark(at.x, at.y, style);
    }

    /// A straight line between two places, by the oldest algorithm there is.
    pub fn line(p: Painter, x1: f64, y1: f64, x2: f64, y2: f64, style: Style) std.mem.Allocator.Error!void {
        const a = p.locate(x1, y1);
        const b = p.locate(x2, y2);
        if (a == null or b == null) {
            // A line with an end outside the plane is still drawn, by
            // stepping along it and dropping the marks that fall off.
            return p.lineByPoints(x1, y1, x2, y2, style);
        }
        var x: i64 = a.?.x;
        var y: i64 = a.?.y;
        const tx: i64 = b.?.x;
        const ty: i64 = b.?.y;
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
        style: Style,
    ) std.mem.Allocator.Error!void {
        try p.line(x, y, x + cols, y, style);
        try p.line(x + cols, y, x + cols, y + rows, style);
        try p.line(x + cols, y + rows, x, y + rows, style);
        try p.line(x, y + rows, x, y, style);
    }

    /// Every point of a series, joined.
    pub fn polyline(p: Painter, points: []const [2]f64, style: Style) std.mem.Allocator.Error!void {
        if (points.len == 0) return;
        if (points.len == 1) return p.point(points[0][0], points[0][1], style);
        for (points[1..], 0..) |b, i| {
            const a = points[i];
            try p.line(a[0], a[1], b[0], b[1], style);
        }
    }

    /// A line stepped in the plane's own numbers, for a line that leaves it.
    fn lineByPoints(
        p: Painter,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        style: Style,
    ) std.mem.Allocator.Error!void {
        const across: f64 = @floatFromInt(@as(u32, p.win.cols()) * p.canvas.marker.across());
        const down: f64 = @floatFromInt(@as(u32, p.win.rows()) * p.canvas.marker.down());
        const steps: usize = @intFromFloat(@max(across, down) * 2 + 2);
        var i: usize = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            try p.point(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, style);
        }
    }

    /// One mark on the grid, combined with whatever is already in its cell.
    fn mark(p: Painter, gx: u32, gy: u32, style: Style) std.mem.Allocator.Error!void {
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
    fn existing(win: Window, col: u16, row: u16) []const u8 {
        if (col >= win.cols() or row >= win.rows()) return " ";
        return win.screen.textAt(win.rect.col + col, win.rect.row + row);
    }
};

/// Where a number falls in a range, as a mark index, or null outside it.
fn place(value: f64, bounds: [2]f64, marks: u32) ?u32 {
    const lo = @min(bounds[0], bounds[1]);
    const hi = @max(bounds[0], bounds[1]);
    if (hi <= lo) return null;
    if (value < lo or value > hi) return null;
    const t = (value - lo) / (hi - lo);
    const scaled: u32 = @intFromFloat(t * @as(f64, @floatFromInt(marks)));
    return @min(scaled, marks - 1);
}

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

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

test "the marks a cell holds are the marker's own" {
    try testing.expectEqual(@as(u8, 2), Marker.braille.across());
    try testing.expectEqual(@as(u8, 4), Marker.braille.down());
    try testing.expectEqual(@as(u8, 1), Marker.block.across());
    try testing.expectEqual(@as(u8, 2), Marker.half_block.down());
}

test "every point that locates to a mark puts one in that mark's cell" {
    for ([_]Marker{ .braille, .block, .half_block, .dot, .bar }) |marker| {
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
