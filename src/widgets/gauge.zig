//! A proportion, as a bar across a rectangle or as a line one row tall.
//!
//! Both draw the part of a cell a fraction lands inside rather than rounding
//! it away, so a gauge at one per cent of a twenty-column window shows
//! something. The eighths are glyphs in the bar's own style, not a
//! background, so a gauge reads the same on a terminal with no colour.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Align = layout.Align;
const Style = visor.Style;
const Window = visor.Window;

/// The eight widths a cell of a horizontal bar can be drawn at, an eighth
/// to a whole.
const eighths = [8][]const u8{
    "\u{258f}", "\u{258e}", "\u{258d}", "\u{258c}",
    "\u{258b}", "\u{258a}", "\u{2589}", "\u{2588}",
};

/// A proportion, as a bar across a rectangle.
pub const Gauge = struct {
    /// How full, from zero to one. Clamped.
    ratio: f64,
    /// Text drawn over the middle row. Null for none.
    label: ?[]const u8 = null,
    /// The style the empty part draws in.
    style: Style = .{},
    /// The style the bar draws in.
    filled_style: Style = .{},
    /// The style the label draws in. Null follows the bar's.
    label_style: ?Style = null,
    /// Whether a fraction of a cell is drawn as a part-width block. Off
    /// rounds to whole cells, which is what a terminal with no block glyphs
    /// wants.
    partial_cells: bool = true,

    /// Draws the bar over every row of the window.
    pub fn draw(g: Gauge, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const cols = win.cols();
        const clamped = @min(@max(g.ratio, 0), 1);
        const scaled = clamped * @as(f64, @floatFromInt(cols)) * 8;
        const total: u32 = @intFromFloat(@round(scaled));
        const whole: u16 = @intCast(@min(total / 8, cols));
        const part: u16 = if (g.partial_cells) @intCast(total % 8) else 0;

        win.fill(.fromSize(win.size()), .blank(g.style));
        var row: u16 = 0;
        while (row < win.rows()) : (row += 1) {
            var col: u16 = 0;
            while (col < whole) : (col += 1) {
                try win.write(col, row, eighths[7], g.filled_style, .none);
            }
            if (part != 0 and whole < cols) {
                try win.write(whole, row, eighths[part - 1], g.filled_style, .none);
            }
        }

        if (g.label) |text| {
            const taken = @min(visor.width(text, .unicode), cols);
            _ = try win.printSegment(
                .{ .text = text, .style = g.label_style orelse g.filled_style },
                .{
                    .col = layout.offset(cols, taken, .center),
                    .row = win.rows() / 2,
                    .wrap = .none,
                },
            );
        }
    }
};

/// A proportion, as a line one row tall.
pub const LineGauge = struct {
    /// How full, from zero to one. Clamped.
    ratio: f64,
    /// Text drawn to the left of the line. Null for none.
    label: ?[]const u8 = null,
    /// The glyph the full part is drawn with.
    filled: []const u8 = "\u{2501}",
    /// The glyph the empty part is drawn with.
    unfilled: []const u8 = "\u{2500}",
    /// The style the full part draws in.
    filled_style: Style = .{},
    /// The style the empty part draws in.
    unfilled_style: Style = .{ .dim = true },
    /// The style the label draws in.
    label_style: Style = .{},

    /// Draws the label and the line on the window's first row.
    pub fn draw(g: LineGauge, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        var col: u16 = 0;
        if (g.label) |text| {
            const at = try win.printSegment(
                .{ .text = text, .style = g.label_style },
                .{ .wrap = .none },
            );
            col = @min(at.col + 1, win.cols());
        }
        const room = win.cols() -| col;
        const clamped = @min(@max(g.ratio, 0), 1);
        const full: u16 = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(room))));
        var i: u16 = 0;
        while (i < room) : (i += 1) {
            const glyph = if (i < full) g.filled else g.unfilled;
            const style = if (i < full) g.filled_style else g.unfilled_style;
            try win.write(col + i, 0, glyph, style, .none);
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a gauge fills whole cells and draws the eighth that is left over" {
    var h: Harness = try .init(testing.allocator, 8, 1);
    defer h.deinit();
    // Five and a half cells of eight.
    try (Gauge{ .ratio = 5.5 / 8.0 }).draw(h.window());
    try h.expectFrame(
        \\█████▌
        \\
    );
}

test "a gauge told not to draw partial cells rounds to whole ones" {
    var h: Harness = try .init(testing.allocator, 8, 1);
    defer h.deinit();
    try (Gauge{ .ratio = 5.5 / 8.0, .partial_cells = false }).draw(h.window());
    try h.expectFrame(
        \\█████
        \\
    );
}

test "a gauge at nothing and at everything" {
    var h: Harness = try .init(testing.allocator, 4, 1);
    defer h.deinit();
    try (Gauge{ .ratio = -1 }).draw(h.window());
    try h.expectFrame("\n");
    try (Gauge{ .ratio = 2 }).draw(h.window());
    try h.expectFrame(
        \\████
        \\
    );
}

test "a gauge's label sits in the middle of its rows" {
    var h: Harness = try .init(testing.allocator, 8, 3);
    defer h.deinit();
    try (Gauge{ .ratio = 1, .label = "50%" }).draw(h.window());
    try h.expectFrame(
        \\████████
        \\██50%███
        \\████████
        \\
    );
}

test "a line gauge puts its label first and the line after it" {
    var h: Harness = try .init(testing.allocator, 12, 1);
    defer h.deinit();
    try (LineGauge{ .ratio = 0.5, .label = "cpu" }).draw(h.window());
    try h.expectFrame(
        \\cpu ━━━━────
        \\
    );
}
