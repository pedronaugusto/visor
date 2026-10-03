const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    inline for (.{ "before", "after" }) |side| {
        const package = b.dependency(side, .{ .target = target, .optimize = optimize });
        const options = b.addOptions();
        options.addOption(bool, "before", std.mem.eql(u8, side, "before"));
        const exe = b.addExecutable(.{
            .name = "visor-" ++ side,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/visor.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "visor", .module = package.module("visor") },
                    .{ .name = "options", .module = options.createModule() },
                },
            }),
        });
        b.installArtifact(exe);
        const ops = b.addExecutable(.{
            .name = "visor-ops-" ++ side,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ops.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "visor", .module = package.module("visor") },
                    .{ .name = "widgets", .module = package.module("visor.widgets") },
                    .{ .name = "options", .module = options.createModule() },
                },
            }),
        });
        b.installArtifact(ops);
    }
}
