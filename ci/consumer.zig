//! What a project that depends on visor writes, built by `zig build
//! check-consumer` with fetching off and only visor's own dependencies
//! present: visor's build.zig must compile and run without any of its CI
//! dependencies.
const std = @import("std");
const visor = @import("visor");
const widgets = visor.widgets;

pub fn main() !void {
    var screen: visor.Screen = try .init(std.heap.page_allocator, .{ .cols = 8, .rows = 1 });
    defer screen.deinit();
    const text = try screen.intern("long-cluster");
    const byte_len: visor.ByteLength = text.length();
    const offset: visor.GraphemeOffset = text.offset().?;
    const generation: visor.PoolGeneration = text.generation();
    if (!byte_len.eql(.fromRaw(12)) or !offset.eql(.fromRaw(0)) or generation.eql(.fromRaw(0))) return error.InvalidPoolDomains;
    try (widgets.Paragraph{ .lines = &.{.{ .text = "visor" }} }).draw(screen.window());
}
