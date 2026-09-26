//! Every widget in the module, drawn once, with no terminal involved.
//!
//! The viewer example is a program; this one is a page of samples, and it
//! exists so that each widget is drawn by something `zig build examples`
//! runs. Where the viewer shows how the pieces fit together, this shows what
//! each of them looks like on its own.

const std = @import("std");
const visor = @import("visor");
const widgets = @import("visor.widgets");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const size: visor.Size = .{ .cols = 80, .rows = 33 };
    var screen: visor.Screen = try .init(gpa, size);
    defer screen.deinit(gpa);
    screen.method = .unicode;
    var renderer: visor.Renderer = try .init(gpa, size);
    defer renderer.deinit(gpa);

    try draw(screen.window());

    const caps: visor.Caps = .{ .width_method = .unicode, .truecolor = true, .osc8 = true };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const stats = try renderer.draw(&out.writer, &screen, null, caps);

    var term: visor.Term = try .init(gpa, size);
    defer term.deinit();
    term.setMethod(caps.width_method);
    try term.feed(out.written());
    try visor.expectScreensEqual(&screen, term.screen());

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try visor.dumpScreen(term.screen(), &text.writer);
    std.debug.print("{s}\nthe page: {d} bytes, {d} cells in {d} runs\n", .{
        text.written(),
        stats.bytes,
        stats.cells,
        stats.runs,
    });
}

/// The page: rows of panels, each one widget, and a key strip at the foot.
fn draw(win: visor.Window) !void {
    const rows = (widgets.Layout.vertical(&.{
        .{ .fixed = 9 },
        .{ .fixed = 8 },
        .{ .fixed = 9 },
        .{ .fill = 1 },
    })).splitFixed(4, .fromSize(win.size()));

    const top = (widgets.Layout.horizontal(&.{
        .{ .fixed = 26 },
        .{ .fixed = 30 },
        .{ .fill = 1 },
    })).splitFixed(3, rows[0]);
    try drawTable(child(win, top[0]));
    try drawChart(child(win, top[1]));
    try drawCanvas(child(win, top[2]));

    const middle = (widgets.Layout.horizontal(&.{
        .{ .fixed = 24 },
        .{ .fixed = 26 },
        .{ .fill = 1 },
    })).splitFixed(3, rows[1]);
    try drawCalendar(child(win, middle[0]));
    try drawBars(child(win, middle[1]));
    try drawMeters(child(win, middle[2]));

    try drawSpark(child(win, rows[2]));

    const bottom = (widgets.Layout.horizontal(&.{
        .{ .fill = 1 },
        .{ .fixed = 24 },
    })).splitFixed(2, rows[3]);
    try drawInput(child(win, bottom[0]));
    try drawSextants(child(win, bottom[1]));
}

fn drawInput(win: visor.Window) !void {
    const inside = try panel(win, " text input, rule, keys ");
    const rows = (widgets.Layout.vertical(&.{
        .{ .fixed = 2 },
        .{ .fixed = 1 },
        .{ .fill = 1 },
    })).splitFixed(3, .fromSize(inside.size()));
    const draft = "a draft that wraps at a word and keeps its cursor in view";
    var state: widgets.TextInput.State = .{};
    try (widgets.TextInput{
        .text = draft,
        .cursor = draft.len,
        .show_cursor = false,
    }).draw(child(inside, rows[0]), &state);
    try (widgets.Rule{ .glyph = widgets.Rule.dashed, .style = .{ .dim = true } }).draw(child(inside, rows[1]));
    try (widgets.Keys{
        .keys = &.{
            .{ .key = "\u{21b5}", .label = "send" },
            .{ .key = "esc", .label = "back" },
        },
        .key_style = .{ .fg = .ansi(.yellow), .bold = true },
        .label_style = .{ .dim = true },
    }).draw(child(inside, rows[2]));
}

fn drawSextants(win: visor.Window) !void {
    const inside = (try (widgets.Block{
        .corners = .all,
        .border_style = .{ .dim = true },
        .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
    }).draw(win));
    // A lit disc, two by three pixels a cell.
    const w = 40;
    const h = 12;
    var pixels: [w * h * 4]u8 = @splat(0);
    for (0..h) |y| for (0..w) |x| {
        const dx = (@as(f32, @floatFromInt(x)) - 20) / 20;
        const dy = (@as(f32, @floatFromInt(y)) - 6) / 6;
        const d = dx * dx + dy * dy;
        if (d > 1) continue;
        const v: u8 = @intFromFloat(255 * (1 - d * 0.7));
        pixels[(y * w + x) * 4 ..][0..4].* = .{ v / 3, v, v, 255 };
    };
    try (widgets.Sextants{ .pixels = &pixels, .width = w, .height = h }).draw(inside);
}

/// A window over one of the split's rectangles.
fn child(win: visor.Window, rect: visor.Rect) visor.Window {
    return win.child(.{
        .col = rect.col,
        .row = rect.row,
        .cols = rect.cols,
        .rows = rect.rows,
    });
}

/// A panel with a title, and the window inside it.
fn panel(win: visor.Window, title: []const u8) !visor.Window {
    return (widgets.Block{
        .borders = .all,
        .border_style = .{ .dim = true },
        .title = .{ .text = title, .style = .{ .bold = true } },
        .padding = .horizontal(1),
    }).draw(win);
}

fn drawTable(win: visor.Window) !void {
    const inside = try panel(win, " table ");
    var state: widgets.Table.State = .{ .selected = 1 };
    try (widgets.Table{
        .header = .{ .cells = &.{ "package", "tests" } },
        .rows = &.{
            .{ .cells = &.{ "morse", "425" } },
            .{ .cells = &.{ "visor", "260" } },
            .{ .cells = &.{ "relic", "191" } },
            .{ .cells = &.{ "strand", "124" } },
        },
        .widths = &.{ .{ .fill = 1 }, .{ .fixed = 5 } },
        .selected_style = .{ .fg = .ansi(.cyan), .bold = true },
        .marker = "\u{25b8} ",
        .where = .left,
    }).draw(inside, &state);
}

fn drawChart(win: visor.Window) !void {
    const inside = try panel(win, " chart ");
    var line: [48][2]f64 = undefined;
    for (&line, 0..) |*p, i| {
        const x: f64 = @floatFromInt(i);
        p.* = .{ x, 4 + 3 * @sin(x / 6) };
    }
    try (widgets.Chart{
        .datasets = &.{
            .{ .name = "rate", .points = &line, .style = .{ .fg = .ansi(.cyan) } },
            .{
                .name = "peak",
                .points = &.{ .{ 6, 7 }, .{ 18, 1 }, .{ 30, 7 }, .{ 42, 1 } },
                .graph = .scatter,
                .marker = .dot,
                .style = .{ .fg = .ansi(.magenta) },
            },
        },
        .x = .{ .bounds = .{ 0, 47 }, .labels = &.{ "0", "24", "47" } },
        .y = .{ .bounds = .{ 0, 8 }, .labels = &.{ "0", "8" } },
    }).draw(inside);
}

fn drawCanvas(win: visor.Window) !void {
    const inside = try panel(win, " canvas ");
    const p = (widgets.Canvas{
        .x_bounds = .{ 0, 100 },
        .y_bounds = .{ 0, 100 },
        .marker = .braille,
    }).painter(inside);
    try p.rect(4, 4, 92, 92, .{ .fg = .ansi(.blue) });
    try p.line(4, 4, 96, 96, .{ .fg = .ansi(.green) });
    try p.line(4, 96, 96, 4, .{ .fg = .ansi(.green) });
    var circle: [64][2]f64 = undefined;
    for (&circle, 0..) |*point, i| {
        const t = @as(f64, @floatFromInt(i)) / 63 * std.math.tau;
        point.* = .{ 50 + 30 * @cos(t), 50 + 30 * @sin(t) };
    }
    try p.polyline(&circle, .{ .fg = .ansi(.yellow) });
}

fn drawCalendar(win: visor.Window) !void {
    const inside = try panel(win, " calendar ");
    try (widgets.Calendar{
        .year = 2026,
        .month = 9,
        .today = .{ .year = 2026, .month = 9, .day = 19 },
        .selected = &.{
            .{ .year = 2026, .month = 9, .day = 5 },
            .{ .year = 2026, .month = 9, .day = 26 },
        },
    }).draw(inside);
}

fn drawBars(win: visor.Window) !void {
    const inside = try panel(win, " bar chart ");
    try (widgets.BarChart{
        .bars = &.{
            .{ .value = 18, .label = "mo" },
            .{ .value = 31, .label = "tu" },
            .{ .value = 12, .label = "we" },
            .{ .value = 44, .label = "th" },
            .{ .value = 27, .label = "fr" },
        },
        .bar_width = 3,
        .show_values = false,
        .label_style = .{ .dim = true },
    }).draw(inside);
}

fn drawMeters(win: visor.Window) !void {
    const inside = try panel(win, " gauges ");
    const rows = (widgets.Layout.vertical(&.{
        .{ .fixed = 1 },
        .{ .fixed = 1 },
        .{ .fixed = 1 },
        .{ .fill = 1 },
    })).splitFixed(4, .fromSize(inside.size()));

    try (widgets.Gauge{
        .ratio = 0.62,
        .label = "62%",
        .filled_style = .{ .fg = .ansi(.green) },
    }).draw(child(inside, rows[0]));
    try (widgets.LineGauge{
        .ratio = 0.35,
        .label = "disk",
        .filled_style = .{ .fg = .ansi(.yellow) },
    }).draw(child(inside, rows[1]));
    try (widgets.LineGauge{
        .ratio = 0.88,
        .label = "heap",
        .filled_style = .{ .fg = .ansi(.red) },
    }).draw(child(inside, rows[2]));

    var state: widgets.List.State = .{ .selected = 2 };
    try (widgets.List{
        .items = &.{
            .{ .text = "bridge" },
            .{ .text = "holomap" },
            .{ .text = "watch" },
        },
        .marker = "\u{25b8} ",
        .selected_style = .{ .reverse = true },
    }).draw(child(inside, rows[3]), &state);
}

fn drawSpark(win: visor.Window) !void {
    const inside = try panel(win, " sparkline, tabs, paragraph, scrollbar ");
    const rows = (widgets.Layout.vertical(&.{
        .{ .fixed = 1 },
        .{ .fixed = 2 },
        .{ .fill = 1 },
    })).splitFixed(3, .fromSize(inside.size()));

    try (widgets.Tabs{
        .titles = &.{ "day", "week", "month" },
        .selected = 1,
    }).draw(child(inside, rows[0]));

    var series: [72]u64 = undefined;
    for (&series, 0..) |*v, i| {
        const x: f64 = @floatFromInt(i);
        v.* = @intFromFloat(16 + 15 * @sin(x / 5) + 8 * @sin(x / 17));
    }
    try (widgets.Sparkline{
        .data = &series,
        .style = .{ .fg = .ansi(.cyan) },
    }).draw(child(inside, rows[1]));

    const text = child(inside, rows[2]);
    const columns = (widgets.Layout.horizontal(&.{
        .{ .fill = 1 },
        .{ .fixed = 1 },
    })).splitFixed(2, .fromSize(text.size()));
    const body =
        \\Every widget on this page is a value built where it is drawn and gone by the end of the call. The selection a list keeps and the offset a scrollbar shows are structs this program owns; the widgets read them, move them when they must, and forget them.
    ;
    const paragraph: widgets.Paragraph = .{
        .lines = &.{.{ .text = body }},
        .wrap = .word,
    };
    try paragraph.draw(child(text, columns[0]));
    try (widgets.Scrollbar{}).draw(child(text, columns[1]), .{
        .content = paragraph.rowCount(columns[0].cols, text.screen.method),
        .viewport = columns[0].rows,
        .position = 0,
    });
}
