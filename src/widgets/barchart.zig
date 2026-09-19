//! Named values as bars, standing up or lying down.
//!
//! The bars are blocks, an eighth of a cell at a time, so a value a twentieth
//! of the largest is still visible. A bar chart with no labels and a width of
//! one is a sparkline with a scale; the difference is that this one names
//! what each bar is.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Direction = layout.Direction;
const Style = visor.Style;
const Window = visor.Window;

/// The eight heights a cell of a standing bar can be drawn at.
const heights = [8][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

/// The eight widths a cell of a lying bar can be drawn at.
const widths = [8][]const u8{
    "\u{258f}", "\u{258e}", "\u{258d}", "\u{258c}",
    "\u{258b}", "\u{258a}", "\u{2589}", "\u{2588}",
};

/// One bar: what it is worth, what it is called, and what it says.
pub const Bar = struct {
    /// How tall or how long the bar is.
    value: u64,
    /// The name under it, or beside it when the bars lie down.
    label: []const u8 = "",
    /// Text drawn on the bar itself. Null draws the value in decimal.
    text: ?[]const u8 = null,
    /// The style the bar draws in.
    style: Style = .{},
};

/// Named values as bars.
pub const BarChart = struct {
    /// The bars, in order.
    bars: []const Bar,
    /// What a full-length bar is worth. Null takes the largest bar.
    max: ?u64 = null,
    /// How thick a bar is, across the axis it grows along.
    bar_width: u16 = 1,
    /// Cells left empty between two bars.
    bar_gap: u16 = 1,
    /// Which way the bars grow.
    direction: Direction = .vertical,
    /// The style the labels draw in.
    label_style: Style = .{},
    /// The style the text on a bar draws in.
    text_style: Style = .{ .reverse = true },
    /// Whether a bar carries its value. Off leaves the bars plain.
    show_values: bool = true,

    /// Draws every bar that fits.
    pub fn draw(c: BarChart, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty() or c.bars.len == 0) return;
        var top = c.max orelse 0;
        if (c.max == null) for (c.bars) |b| {
            top = @max(top, b.value);
        };
        if (top == 0) top = 1;
        switch (c.direction) {
            .vertical => try c.drawStanding(win, top),
            .horizontal => try c.drawLying(win, top),
        }
    }

    /// Bars that grow upward from the bottom row, their labels under them.
    fn drawStanding(c: BarChart, win: Window, top: u64) std.mem.Allocator.Error!void {
        var labelled = false;
        for (c.bars) |b| {
            if (b.label.len != 0) labelled = true;
        }
        const label_row: ?u16 = if (labelled and win.rows() > 1) win.rows() - 1 else null;
        const rows = if (label_row) |r| r else win.rows();
        if (rows == 0) return;

        var col: u16 = 0;
        for (c.bars) |b| {
            if (col >= win.cols()) return;
            const scaled = @min(b.value, top) * rows * 8 / top;
            var thick: u16 = 0;
            while (thick < c.bar_width and col + thick < win.cols()) : (thick += 1) {
                var row: u16 = rows;
                var left = scaled;
                while (row > 0) : (row -= 1) {
                    const here = @min(left, 8);
                    if (here == 0) break;
                    try win.write(col + thick, row - 1, heights[here - 1], b.style, .none);
                    left -= here;
                }
            }
            if (c.show_values) try c.drawValue(win, b, col, rows - 1);
            if (label_row) |r| try c.drawLabel(win, b.label, col, r, c.bar_width);
            col +|= c.bar_width +| c.bar_gap;
        }
    }

    /// Bars that grow rightward, one row each, their labels to the left.
    fn drawLying(c: BarChart, win: Window, top: u64) std.mem.Allocator.Error!void {
        var label_width: u16 = 0;
        for (c.bars) |b| label_width = @max(label_width, visor.width(b.label, .unicode));
        if (label_width != 0) label_width += 1;
        const cols = win.cols() -| label_width;
        if (cols == 0) return;

        var row: u16 = 0;
        for (c.bars) |b| {
            if (row >= win.rows()) return;
            const scaled = @min(b.value, top) * cols * 8 / top;
            const whole: u16 = @intCast(@min(scaled / 8, cols));
            const part: u16 = @intCast(scaled % 8);
            var thick: u16 = 0;
            while (thick < c.bar_width and row + thick < win.rows()) : (thick += 1) {
                var col: u16 = 0;
                while (col < whole) : (col += 1) {
                    try win.write(label_width + col, row + thick, widths[7], b.style, .none);
                }
                if (part != 0 and whole < cols) {
                    try win.write(label_width + whole, row + thick, widths[part - 1], b.style, .none);
                }
            }
            if (label_width != 0) {
                _ = try win.printSegment(
                    .{ .text = b.label, .style = c.label_style },
                    .{ .col = 0, .row = row, .wrap = .none },
                );
            }
            if (c.show_values) try c.drawValue(win, b, label_width, row);
            row +|= c.bar_width +| c.bar_gap;
        }
    }

    /// What a bar says about itself, on the bar.
    fn drawValue(c: BarChart, win: Window, b: Bar, col: u16, row: u16) std.mem.Allocator.Error!void {
        var digits: [20]u8 = undefined;
        const text = b.text orelse std.fmt.bufPrint(&digits, "{d}", .{b.value}) catch return;
        if (text.len == 0) return;
        _ = try win.printSegment(
            .{ .text = text, .style = c.text_style },
            .{ .col = col, .row = row, .wrap = .none },
        );
    }

    /// A bar's name, centred under it.
    fn drawLabel(
        c: BarChart,
        win: Window,
        text: []const u8,
        col: u16,
        row: u16,
        room: u16,
    ) std.mem.Allocator.Error!void {
        if (text.len == 0) return;
        const taken = @min(visor.width(text, .unicode), room);
        _ = try win.printSegment(
            .{ .text = text, .style = c.label_style },
            .{ .col = col + layout.offset(room, taken, .center), .row = row, .wrap = .none },
        );
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "standing bars grow from the bottom row with their labels under them" {
    var h: Harness = try .init(testing.allocator, 8, 4);
    defer h.deinit();
    try (BarChart{
        .bars = &.{
            .{ .value = 8, .label = "a" },
            .{ .value = 16, .label = "b" },
            .{ .value = 24, .label = "c" },
        },
        .max = 24,
        .show_values = false,
    }).draw(h.window());
    try h.expectFrame(
        \\    █
        \\  █ █
        \\█ █ █
        \\a b c
        \\
    );
}

test "a bar wider than one cell is drawn as many" {
    var h: Harness = try .init(testing.allocator, 8, 2);
    defer h.deinit();
    try (BarChart{
        .bars = &.{ .{ .value = 1 }, .{ .value = 1 } },
        .bar_width = 3,
        .show_values = false,
    }).draw(h.window());
    try h.expectFrame(
        \\███ ███
        \\███ ███
        \\
    );
}

test "lying bars run rightward from their labels" {
    var h: Harness = try .init(testing.allocator, 10, 3);
    defer h.deinit();
    try (BarChart{
        .bars = &.{
            .{ .value = 3, .label = "one" },
            .{ .value = 6, .label = "two" },
        },
        .max = 6,
        .direction = .horizontal,
        .bar_gap = 1,
        .show_values = false,
    }).draw(h.window());
    try h.expectFrame(
        \\one ███
        \\
        \\two ██████
        \\
    );
}

test "a bar carries its value unless told not to" {
    var h: Harness = try .init(testing.allocator, 4, 2);
    defer h.deinit();
    try (BarChart{ .bars = &.{.{ .value = 42 }}, .bar_width = 2 }).draw(h.window());
    try h.expectFrame(
        \\██
        \\42
        \\
    );
}
