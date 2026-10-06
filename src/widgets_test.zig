const std = @import("std");
const widgets = @import("widgets.zig");
test {
    _ = @import("widgets/layout.zig");
    _ = @import("widgets/block.zig");
    _ = @import("widgets/paragraph.zig");
    _ = @import("widgets/markdown.zig");
    _ = @import("widgets/markdown_test.zig");
    _ = @import("widgets/hostile_text_test.zig");
    _ = @import("widgets/markdown/gfm_test.zig");
    _ = @import("widgets/edges.zig");
    _ = @import("widgets/list.zig");
    _ = @import("widgets/table.zig");
    _ = @import("widgets/tree.zig");
    _ = @import("widgets/tabs.zig");
    _ = @import("widgets/gauge.zig");
    _ = @import("widgets/sparkline.zig");
    _ = @import("widgets/barchart.zig");
    _ = @import("widgets/chart.zig");
    _ = @import("widgets/scrollbar.zig");
    _ = @import("widgets/canvas.zig");
    _ = @import("widgets/canvas_test.zig");
    _ = @import("widgets/calendar.zig");
    _ = @import("testing/widget_harness.zig");
    _ = @import("widgets/text_input.zig");
    _ = @import("widgets/scroll.zig");
    _ = @import("widgets/keys.zig");
    _ = @import("widgets/rule.zig");
    _ = @import("widgets/sextants.zig");
    std.testing.refAllDecls(widgets);
}

/// Every field of `T` outside `public` is its owner's state, named with a
/// leading underscore: read through a method, never taken whole. Checked
/// while the tests compile, naming the field that is neither.
fn expectOwned(comptime T: type, comptime public: []const []const u8) void {
    inline for (std.meta.fields(T)) |field| {
        const listed = for (public) |name| {
            if (std.mem.eql(u8, name, field.name)) break true;
        } else false;
        if (!listed and field.name[0] != '_') @compileError(@typeName(T) ++ "." ++ field.name ++ " is neither public nor underscored");
    }
}

test "widget state outside the documented fields stays behind its owner" {
    comptime expectOwned(widgets.Markdown.Rows, &.{});
    comptime expectOwned(widgets.Markdown.Document, &.{});
    comptime expectOwned(widgets.Paragraph.Rows, &.{});
    comptime expectOwned(widgets.TextInput.Rows, &.{});
    comptime expectOwned(widgets.Canvas.Surface, &.{});
    // A picture borrows its owners and takes no allocator of its own.
    comptime expectOwned(widgets.Canvas.Picture, &.{ "surface", "layers", "writer", "image", "placement", "order", "sixel_palette" });
}
