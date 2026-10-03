const std = @import("std");
const widgets = @import("widgets.zig");
test {
    _ = @import("widgets/layout.zig");
    _ = @import("widgets/block.zig");
    _ = @import("widgets/paragraph.zig");
    _ = @import("widgets/markdown_test.zig");
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
    _ = @import("widgets/harness.zig");
    _ = @import("widgets/text_input.zig");
    _ = @import("widgets/scroll.zig");
    _ = @import("widgets/keys.zig");
    _ = @import("widgets/rule.zig");
    _ = @import("widgets/sextants.zig");
    std.testing.refAllDecls(widgets);
}
