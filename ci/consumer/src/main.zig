const std = @import("std");
const visor = @import("visor");
const widgets = @import("visor.widgets");

pub fn main() !void {
    var screen: visor.Screen = try .init(std.heap.page_allocator, .{ .cols = 8, .rows = 1 });
    defer screen.deinit();
    try (widgets.Paragraph{ .lines = &.{.{ .text = "visor" }} }).draw(screen.window());
}
