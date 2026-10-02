//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/corpus.zig",
        "src/damage.zig",
        "src/dependencies.zig",
        "src/geom.zig",
        "src/shm.zig",
        "src/widgets/markdown_reader.zig",
        "src/widgets/selection.zig",
    } },
    .{ .name = "text and geometry", .patterns = &.{
        "src/cell.zig",
        "src/palette.zig",
        "src/text.zig",
        "src/winsize.zig",
    } },
    .{ .name = "capabilities and pools", .patterns = &.{
        "src/caps.zig",
        "src/pool.zig",
    } },
    .{ .name = "drawing policy", .patterns = &.{
        "src/layer.zig",
        "src/window_impl.zig",
    } },
    .{ .name = "screen", .patterns = &.{
        "src/screen.zig",
    } },
    .{ .name = "views and terminal", .patterns = &.{
        "src/moved_rows_impl.zig",
        "src/term.zig",
        "src/window.zig",
    } },
    .{ .name = "rendering", .patterns = &.{
        "src/render.zig",
        "src/window_test.zig",
    } },
    .{ .name = "session and scenarios", .patterns = &.{
        "src/bench.zig",
        "src/layer_test.zig",
        "src/moved_rows.zig",
        "src/roundtrip.zig",
        "src/screen_test.zig",
        "src/session.zig",
        "src/tty.zig",
    } },
    .{ .name = "input", .patterns = &.{
        "src/input.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/visor.zig",
    } },
    .{ .name = "widget geometry", .patterns = &.{
        "src/widgets/harness.zig",
        "src/widgets/layout.zig",
        "src/widgets/raster.zig",
    } },
    .{ .name = "widget views", .patterns = &.{
        "src/widgets/barchart.zig",
        "src/widgets/block.zig",
        "src/widgets/calendar.zig",
        "src/widgets/edges.zig",
        "src/widgets/gauge.zig",
        "src/widgets/keys.zig",
        "src/widgets/list.zig",
        "src/widgets/paragraph.zig",
        "src/widgets/rule.zig",
        "src/widgets/scrollbar.zig",
        "src/widgets/sextants.zig",
        "src/widgets/sparkline.zig",
        "src/widgets/table.zig",
        "src/widgets/tabs.zig",
        "src/widgets/text_input.zig",
    } },
    .{ .name = "composed widgets", .patterns = &.{
        "src/widgets/canvas.zig",
        "src/widgets/markdown.zig",
        "src/widgets/scroll.zig",
    } },
    .{ .name = "widget scenarios", .patterns = &.{
        "src/widgets/canvas_test.zig",
        "src/widgets/chart.zig",
    } },
    .{ .name = "widgets", .patterns = &.{
        "src/widgets.zig",
    } },
    .{ .name = "markdown scenarios", .patterns = &.{
        "src/widgets/markdown_test.zig",
    } },
    .{ .name = "widget tests", .patterns = &.{
        "src/widget_tests.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "visor", .path = "src/visor.zig", .from = "src/**" },
    .{ .name = "corpus", .path = "src/corpus.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "conduit",
        "conduit.tty",
        "manifest",
        "morse",
        "std",
        "uucode",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "conduit owner", .target = "conduit", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "conduit.tty owner", .target = "conduit.tty", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "morse owner", .target = "morse", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "uucode owner", .target = "uucode", .except_from = &.{"src/dependencies.zig"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
