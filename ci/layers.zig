//! Production source layers, lowest first. Every production source has one
//! explicit place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/damage.zig",
        "src/dependencies.zig",
        "src/geom.zig",
        "src/intake.zig",
        "src/system.zig",
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
    // The widgets, on the base. They look down at the base through one file,
    // and the root names them last, so the base never reaches them. What
    // several widgets share sits under the widgets; the widgets are peers in
    // one layer, where one may build on another (a tree on a list, a chart on
    // a canvas) and the cycle rule keeps them a DAG.
    .{ .name = "widget base", .patterns = &.{
        "src/widgets/base.zig",
    } },
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
    .{ .name = "widgets namespace", .patterns = &.{
        "src/widgets.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/visor.zig",
    } },
    // `visor.markdown`, a module of its own on `visor` and datapad: it reaches
    // visor by the module's name, never by a path into its files.
    .{ .name = "markdown reader", .patterns = &.{
        "src/markdown/reader.zig",
    } },
    .{ .name = "markdown widget", .patterns = &.{
        "src/markdown/markdown.zig",
    } },
    // `visor.pictures`, a module of its own on `visor` and aperture.
    .{ .name = "pictures", .patterns = &.{
        "src/pictures/pictures.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "spread", .path = "src/testing/spread.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis",
        "aperture",
        "builtin",
        "conduit",
        "conduit.tty",
        "datapad",
        "morse",
        "reactor",
        "warp",
        "shakedown",
        "std",
        "visor",
        "xenoglyph",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "aegis owner", .target = "aegis", .except_from = &.{ "src/dependencies.zig", "src/pictures/pictures.zig" } },
    .{ .name = "conduit owner", .target = "conduit", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "conduit.tty owner", .target = "conduit.tty", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "morse owner", .target = "morse", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "xenoglyph owner", .target = "xenoglyph", .except_from = &.{"src/dependencies.zig"} },
    .{ .name = "datapad owner", .target = "datapad", .except_from = &.{"src/markdown/reader.zig"} },
    .{ .name = "aperture owner", .target = "aperture", .except_from = &.{"src/pictures/pictures.zig"} },
};

/// The roots the builds compile, the conformance build's included, and the
/// one seam to the dependencies.
pub const required = [_][]const u8{
    "src/visor.zig",
    "src/dependencies.zig",
    "src/tests.zig",
    "src/testing/spread.zig",
    "src/markdown/markdown.zig",
    "src/markdown/tests.zig",
    "src/pictures/pictures.zig",
    "src/pictures/tests.zig",
};

/// Tokens only their owners may spell. The console and the terminal's
/// modes are conduit's: visor reaches them through `conduit.tty`. kernel32
/// is named only by the shared memory seam, for the named file mapping a
/// picture goes through on Windows; nothing of the console is in it.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "console owner", .tokens = &.{ "CreateFileW", "ReadConsoleInputW", "GetConsoleMode", "SetConsoleMode" } },
    .{ .name = "console owner", .kind = .string, .tokens = &.{ "CONIN$", "CONOUT$" } },
    .{ .name = "kernel32 owner", .kind = .string, .tokens = &.{"kernel32"}, .owners = &.{"src/layer/shm.zig"} },
    .{ .name = "terminal mode owner", .tokens = &.{ "tcsetattr", "ioctl" } },
};
