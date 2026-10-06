const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const visor = b.dependency("visor", .{ .target = target });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "visor", .module = visor.module("visor") },
            .{ .name = "visor.widgets", .module = visor.module("visor.widgets") },
        },
    }) });
    b.installArtifact(exe);
}
