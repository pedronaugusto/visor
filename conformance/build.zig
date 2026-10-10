//! The conformance build: the round trip against a terminal emulator that
//! is not ours.
//!
//! Separate from the package's own build on purpose. The emulator is a
//! large dependency with C and C++ in it, and nothing that builds a program
//! on `visor` should ever fetch or compile one. Zig compiles the build
//! script of every package a manifest names once it is in the package
//! cache, asked for or not, so a lazy dependency in `visor`'s manifest would
//! not achieve that, and neither would one behind an option. `zig build
//! conformance` in the package root runs this.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const visor = b.dependency("visor", .{ .target = target, .optimize = optimize });
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    // The properties run under shakedown's `check`, on the aegis visor links.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    @import("shakedown").useAegis(shakedown, visor.builder.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const tests = b.addTest(.{
        .name = "visor-conformance",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "visor", .module = visor.module("visor") },
                // visor's test support, not a module it publishes: the same
                // file the package's own suite counts with.
                .{ .name = "spread", .module = b.createModule(.{ .root_source_file = visor.path("src/testing/spread.zig") }) },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            },
        }),
    });

    const test_step = b.step("test", "Run the conformance properties");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    b.getInstallStep().dependOn(&tests.step);
}
