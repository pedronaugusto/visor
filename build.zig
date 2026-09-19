const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "grapheme_break",
            "grapheme_break_no_control",
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier_base",
            "is_emoji_vs_base",
        }),
    });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "morse", .module = morse.module("morse") },
        .{ .name = "uucode", .module = uucode.module("uucode") },
    };

    const module = b.addModule("visor", .{
        .root_source_file = b.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    _ = module;

    const tests = b.addTest(.{
        .name = "visor-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/visor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    const test_step = b.step("test", "Run the visor tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
