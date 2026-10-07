//! Production source layers, lowest first. Every production source has one
//! explicit place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/damage.zig",
        "src/dependencies.zig",
        "src/geom.zig",
        "src/layer/**",
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
        "src/window.zig",
    } },
    .{ .name = "screen", .patterns = &.{
        "src/screen.zig",
    } },
    .{ .name = "views and terminal", .patterns = &.{
        "src/render/moved_rows.zig",
        "src/term.zig",
    } },
    .{ .name = "rendering", .patterns = &.{
        "src/render.zig",
    } },
    .{ .name = "session and terminal", .patterns = &.{
        "src/session.zig",
        "src/tty.zig",
    } },
    .{ .name = "input", .patterns = &.{
        "src/input.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/visor.zig",
    } },
    // The second module, on the first. What several widgets share sits
    // under the widgets; the widgets are peers in one layer, where one may
    // build on another (a tree on a list, a chart on a canvas) and the cycle
    // rule keeps them a DAG.
    .{ .name = "widget geometry", .patterns = &.{
        "src/widgets/layout.zig",
        "src/widgets/selection.zig",
    } },
    .{ .name = "widgets", .patterns = &.{
        "src/widgets/barchart.zig",
        "src/widgets/block.zig",
        "src/widgets/calendar.zig",
        "src/widgets/canvas.zig",
        "src/widgets/canvas/**",
        "src/widgets/chart.zig",
        "src/widgets/edges.zig",
        "src/widgets/gauge.zig",
        "src/widgets/keys.zig",
        "src/widgets/list.zig",
        "src/widgets/markdown.zig",
        "src/widgets/markdown/reader.zig",
        "src/widgets/paragraph.zig",
        "src/widgets/rule.zig",
        "src/widgets/scroll.zig",
        "src/widgets/scrollbar.zig",
        "src/widgets/sextants.zig",
        "src/widgets/sparkline.zig",
        "src/widgets/table.zig",
        "src/widgets/tabs.zig",
        "src/widgets/text_input.zig",
        "src/widgets/tree.zig",
    } },
    .{ .name = "widgets module", .patterns = &.{
        "src/widgets.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "visor", .path = "src/visor.zig", .from = "src/**" },
    .{ .name = "corpus", .path = "src/testing/corpus.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "conduit",
        "conduit.tty",
        "morse",
        "shakedown",
        "std",
        "uucode",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "conduit owner", .target = "conduit", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "conduit.tty owner", .target = "conduit.tty", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "morse owner", .target = "morse", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "uucode owner", .target = "uucode", .except_from = &.{"src/dependencies.zig"} },
};

/// The roots the builds compile, the conformance build's included, and the
/// one seam to the dependencies.
pub const required = [_][]const u8{
    "src/visor.zig",
    "src/widgets.zig",
    "src/dependencies.zig",
    "src/tests.zig",
    "src/widgets_test.zig",
    "src/testing/corpus.zig",
};

/// Tokens only their owners may spell. The console and the terminal's
/// modes are conduit's: visor reaches them through `conduit.tty`.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "console owner", .tokens = &.{ "CreateFileW", "ReadConsoleInputW", "GetConsoleMode", "SetConsoleMode" } },
    .{ .name = "console owner", .kind = .string, .tokens = &.{ "CONIN$", "CONOUT$", "kernel32" } },
    .{ .name = "terminal mode owner", .tokens = &.{ "tcsetattr", "ioctl" } },
};
