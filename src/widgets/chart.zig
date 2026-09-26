//! Datasets on axes, as lines or as points.
//!
//! A chart is a canvas with a gutter round it: the plot is drawn in the
//! caller's own numbers through `Canvas`, and this places the axes, the
//! labels and the legend around it. The axes are drawn whether or not there
//! are labels, because an unlabelled plot with no axes is a smudge.
//!
//! The labels are the caller's strings, not a formatter's: a chart of
//! seconds and a chart of bytes want different words and neither wants this
//! file to have an opinion about them.

const std = @import("std");
const visor = @import("visor");

const canvas_mod = @import("canvas.zig");
const layout = @import("layout.zig");
const Align = layout.Align;
const Canvas = canvas_mod.Canvas;
const Marker = canvas_mod.Marker;
const Style = visor.Style;
const Window = visor.Window;

/// One side of a chart: what it spans, what it is called, and how it is
/// marked.
pub const Axis = struct {
    /// The lowest and highest value the side spans.
    bounds: [2]f64 = .{ 0, 1 },
    /// The marks along it, from the lowest value to the highest. The first
    /// sits at the low end and the last at the high end, and any in between
    /// are spread evenly.
    labels: []const []const u8 = &.{},
    /// A name for the side, drawn at its high end.
    title: ?[]const u8 = null,
    /// The style the axis line draws in.
    style: Style = .{ .dim = true },
    /// The style the labels and the title draw in.
    label_style: Style = .{},
};

/// A dataset on a chart, and how it is drawn.
pub const Dataset = struct {
    /// What it is called, for the legend.
    name: []const u8 = "",
    /// The points, as x and y in the axes' own numbers.
    points: []const [2]f64,
    /// Whether the points are joined.
    graph: Graph = .line,
    /// What the marks are drawn with.
    marker: Marker = .braille,
    /// The style they draw in.
    style: Style = .{},

    /// Whether a dataset's points are joined or left alone.
    pub const Graph = enum {
        /// Each point joined to the next.
        line,
        /// One mark a point.
        scatter,
    };
};

/// Datasets on axes.
pub const Chart = struct {
    /// The datasets, drawn in order, so the last is on top.
    datasets: []const Dataset,
    /// The side along the bottom.
    x: Axis = .{},
    /// The side up the left.
    y: Axis = .{},
    /// Whether the dataset names are listed in the top-right corner.
    legend: bool = true,

    /// Draws the axes, the labels, the datasets and the legend.
    pub fn draw(c: Chart, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;

        var gutter: u16 = 0;
        for (c.y.labels) |l| gutter = @max(gutter, win.width(l));
        const label_row: u16 = if (c.x.labels.len != 0) 1 else 0;

        // The axis lines, and the plot inside them.
        const axis_col = gutter;
        if (win.cols() <= axis_col + 1 or win.rows() <= label_row + 1) return;
        const axis_row = win.rows() - 1 - label_row;
        const plot = win.child(.{
            .col = axis_col + 1,
            .row = 0,
            .cols = win.cols() - axis_col - 1,
            .rows = axis_row,
        });

        var row: u16 = 0;
        while (row < axis_row) : (row += 1) {
            try win.write(axis_col, row, "\u{2502}", c.y.style, .none);
        }
        try win.write(axis_col, axis_row, "\u{2514}", c.x.style, .none);
        var col: u16 = axis_col + 1;
        while (col < win.cols()) : (col += 1) {
            try win.write(col, axis_row, "\u{2500}", c.x.style, .none);
        }

        try c.drawYLabels(win, gutter, axis_row);
        try c.drawXLabels(win, axis_col + 1, axis_row + 1, label_row);

        for (c.datasets) |d| {
            const p = (Canvas{
                .x_bounds = c.x.bounds,
                .y_bounds = c.y.bounds,
                .marker = d.marker,
            }).painter(plot);
            switch (d.graph) {
                .line => try p.polyline(d.points, d.style),
                .scatter => for (d.points) |pt| try p.point(pt[0], pt[1], d.style),
            }
        }

        if (c.legend) try c.drawLegend(plot);
    }

    /// The y labels, right-aligned in the gutter, the first at the bottom.
    fn drawYLabels(c: Chart, win: Window, gutter: u16, axis_row: u16) std.mem.Allocator.Error!void {
        if (gutter == 0 or c.y.labels.len == 0) return;
        for (c.y.labels, 0..) |text, i| {
            const row = rowFor(i, c.y.labels.len, axis_row);
            const taken = @min(win.width(text), gutter);
            _ = try win.printSegment(
                .{ .text = text, .style = c.y.label_style },
                .{ .col = gutter - taken, .row = row, .wrap = .none },
            );
        }
        if (c.y.title) |t| {
            const taken = @min(win.width(t), gutter);
            _ = try win.printSegment(
                .{ .text = t, .style = c.y.label_style },
                .{ .col = gutter - taken, .row = 0, .wrap = .none },
            );
        }
    }

    /// The x labels on the row under the axis, the first at the left.
    fn drawXLabels(
        c: Chart,
        win: Window,
        from: u16,
        row: u16,
        rows: u16,
    ) std.mem.Allocator.Error!void {
        if (rows == 0 or row >= win.rows()) return;
        const room = win.cols() -| from;
        if (room == 0) return;
        for (c.x.labels, 0..) |text, i| {
            const taken = @min(win.width(text), room);
            const where: Align = if (i == 0)
                .left
            else if (i + 1 == c.x.labels.len)
                .right
            else
                .center;
            const span = room -| 1;
            const at: u16 = switch (where) {
                .left => 0,
                .right => room -| taken,
                .center => @intCast(@as(u32, span) * i / (c.x.labels.len - 1) -| taken / 2),
            };
            _ = try win.printSegment(
                .{ .text = text, .style = c.x.label_style },
                .{ .col = from + at, .row = row, .wrap = .none },
            );
        }
    }

    /// The dataset names, in the plot's top-right corner.
    fn drawLegend(c: Chart, plot: Window) std.mem.Allocator.Error!void {
        var widest: u16 = 0;
        var named: u16 = 0;
        for (c.datasets) |d| {
            if (d.name.len == 0) continue;
            widest = @max(widest, plot.width(d.name));
            named += 1;
        }
        if (named == 0 or widest + 2 > plot.cols() or named + 2 > plot.rows()) return;
        const box = plot.child(.{
            .col = plot.cols() - widest - 2,
            .row = 0,
            .cols = widest + 2,
            .rows = named + 2,
            .border = .{ .where = .all },
        });
        var row: u16 = 0;
        for (c.datasets) |d| {
            if (d.name.len == 0) continue;
            _ = try box.printSegment(
                .{ .text = d.name, .style = d.style },
                .{ .row = row, .wrap = .none },
            );
            row += 1;
        }
    }

    /// Which row the `i`th of `n` y labels sits on, counting up from the
    /// axis.
    fn rowFor(i: usize, n: usize, axis_row: u16) u16 {
        if (n <= 1) return axis_row -| 1;
        const span: u32 = axis_row -| 1;
        const up: u32 = span * @as(u32, @intCast(i)) / @as(u32, @intCast(n - 1));
        return @intCast(span - up);
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a chart draws its axes and its labels around the plot" {
    var h: Harness = try .init(testing.allocator, 12, 5);
    defer h.deinit();
    try (Chart{
        .datasets = &.{},
        .x = .{ .bounds = .{ 0, 10 }, .labels = &.{ "0", "10" } },
        .y = .{ .bounds = .{ 0, 4 }, .labels = &.{ "0", "4" } },
        .legend = false,
    }).draw(h.window());
    try h.expectFrame(
        \\4│
        \\ │
        \\0│
        \\ └──────────
        \\  0       10
        \\
    );
}

test "a line dataset joins its points" {
    var h: Harness = try .init(testing.allocator, 4, 2);
    defer h.deinit();
    try (Chart{
        .datasets = &.{.{
            .points = &.{ .{ 0, 0 }, .{ 2.9, 0.9 } },
            .marker = .block,
        }},
        .x = .{ .bounds = .{ 0, 3 } },
        .y = .{ .bounds = .{ 0, 1 } },
        .legend = false,
    }).draw(h.window());
    try h.expectFrame(
        \\│███
        \\└───
        \\
    );
}

test "a scatter dataset leaves its points alone" {
    var h: Harness = try .init(testing.allocator, 5, 3);
    defer h.deinit();
    try (Chart{
        .datasets = &.{.{
            .points = &.{ .{ 0, 0 }, .{ 3.5, 1.5 } },
            .marker = .block,
            .graph = .scatter,
        }},
        .x = .{ .bounds = .{ 0, 4 } },
        .y = .{ .bounds = .{ 0, 2 } },
        .legend = false,
    }).draw(h.window());
    try h.expectFrame(
        \\│   █
        \\│█
        \\└────
        \\
    );
}

test "the legend names the datasets in the plot's corner" {
    var h: Harness = try .init(testing.allocator, 12, 6);
    defer h.deinit();
    try (Chart{
        .datasets = &.{.{ .name = "rate", .points = &.{} }},
        .x = .{ .bounds = .{ 0, 1 } },
        .y = .{ .bounds = .{ 0, 1 } },
    }).draw(h.window());
    try h.expectFrame(
        \\│     ┌────┐
        \\│     │rate│
        \\│     └────┘
        \\│
        \\│
        \\└───────────
        \\
    );
}

test "a chart in a window too small for its gutter draws nothing" {
    var h: Harness = try .init(testing.allocator, 2, 1);
    defer h.deinit();
    try (Chart{
        .datasets = &.{},
        .y = .{ .labels = &.{"1000"} },
        .x = .{ .labels = &.{"0"} },
    }).draw(h.window());
    try h.expectFrame("\n");
}

test "the gutter is as wide as the widest label, measured the way the screen measures" {
    var h: Harness = try .initMeasured(testing.allocator, 8, 4, .wcwidth);
    defer h.deinit();
    try (Chart{
        .datasets = &.{},
        .x = .{ .bounds = .{ 0, 1 } },
        .y = .{ .bounds = .{ 0, 1 }, .labels = &.{ "0", sign } },
        .legend = false,
    }).draw(h.window());
    _ = try h.frame();
    // One column of gutter, then the axis.
    try testing.expectEqualStrings("\u{2502}", h.term.screen().textAt(1, 0));
}

const sign = "\u{26a0}\u{fe0f}";
