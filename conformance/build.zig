//! The conformance build: the round trip against a terminal emulator that
//! is not ours.
//!
//! Separate from the package's own build on purpose. The emulator is a
//! large dependency with C and C++ in it, and nothing that builds a program
//! on `visor` should ever fetch one -- which is what a lazy dependency in
//! `visor`'s manifest would not achieve, because a lazy dependency is
//! fetched by whoever builds the file that names it. `zig build
//! conformance` in the package root runs this.

const std = @import("std");

/// The package's own build file, for the one decision both builds have to
/// make the same way.
const visor_build = @import("visor");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const visor = b.dependency("visor", .{ .target = target, .optimize = optimize });
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });

    const tests = b.addTest(.{
        .name = "visor-conformance",
        // The package's own build makes this call for its test binaries,
        // and this one compiles the same package: without it, Zig 0.16's
        // self-hosted x86_64 backend takes the whole compilation down with
        // SIGSEGV on Linux in Debug. See `needsLlvm` in ../build.zig.
        .use_llvm = visor_build.needsLlvm(target, optimize),
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance.zig"),
            .target = target,
            .optimize = optimize,
            // Off for the same reason as the package's own test modules:
            // Zig 0.16.0's test runner cannot compile a fuzzing binary with
            // error tracing on, so `zig build test --fuzz` in this directory
            // would not build. Delete this the release it is fixed.
            .error_tracing = false,
            .imports = &.{
                .{ .name = "visor", .module = visor.module("visor") },
                .{ .name = "corpus", .module = visor.module("corpus") },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            },
        }),
    });

    const test_step = b.step("test", "Run the conformance properties");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    b.getInstallStep().dependOn(&tests.step);
}
