const std = @import("std");
// visor's own build script, which a consumer can import like any
// dependency's: `needsLlvm` routes around the Zig 0.16 backend crash that
// compiling visor in Debug on x86_64 Linux hits, for this program as for visor.
const visor_build = @import("visor");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const visor = b.dependency("visor", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .use_llvm = visor_build.needsLlvm(target, optimize),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "visor", .module = visor.module("visor") },
                .{ .name = "visor.widgets", .module = visor.module("visor.widgets") },
            },
        }),
    });
    b.installArtifact(exe);
}
