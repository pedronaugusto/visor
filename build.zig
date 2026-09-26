const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // Dependencies.
    //
    // `morse` writes every escape sequence this package emits and parses
    // every reply it reads. `uucode` is configured here with the six fields
    // this package uses and no others: the field list is printed in the
    // README so a consumer who configures uucode themselves knows which to
    // keep.
    //=====================================================================

    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    // `conduit` owns the terminal's own calls -- raw mode and the way back,
    // the size, the device's name -- for this package and for programs that
    // run a child on a pseudo-terminal alike. Only its `conduit.tty` module
    // is imported, which on Linux links no C library; the suite also takes
    // `conduit` whole for the pseudo-terminal it tests against.
    const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &uucode_fields),
    });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "morse", .module = morse.module("morse") },
        .{ .name = "uucode", .module = uucode.module("uucode") },
        .{ .name = "conduit.tty", .module = conduit.module("conduit.tty") },
    };

    //=====================================================================
    // The modules.
    //
    // Two, in one repository and one fetch: the base, and the widgets that
    // will be written on it. The base never imports the widgets, which is
    // what keeps it a base.
    //=====================================================================

    const module = b.addModule("visor", .{
        .root_source_file = b.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const widgets = b.addModule("visor.widgets", .{
        .root_source_file = b.path("src/widgets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "visor", .module = module }},
    });

    // A consumer who wants the writers separately gets them from here
    // rather than fetching morse a second time.
    b.modules.put(b.allocator, b.dupe("morse"), morse.module("morse")) catch @panic("OOM");

    // The inputs the round-trip properties replay. Its own module because
    // the suite inside the package and the conformance build outside it
    // have to replay the same bytes, and a file belongs to one module.
    const corpus = b.addModule("corpus", .{ .root_source_file = b.path("src/corpus.zig") });

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // test block is what pulls every file in.
    //
    // `error_tracing` is off on the test modules because Zig 0.16.0's test
    // runner cannot build a fuzzing binary with it on: it hands
    // `@errorReturnTrace()` to `std.debug.writeStackTrace`, and the two
    // `StackTrace` types do not match. The ordinary suite passes either way;
    // with it on, `zig build test --fuzz` fails to compile after the suite
    // has already run, which is a fuzz target nobody can reach. Delete this
    // the release it is fixed.
    //=====================================================================

    const fuzzable = false;

    // The manifest's version, handed to the suite so the exported constant
    // is compared with the released one and not with a literal beside it.
    const manifest_options = b.addOptions();
    manifest_options.addOption([]const u8, "version", manifest.version);

    const tests = b.addTest(.{
        .name = "visor-tests",
        .use_llvm = needsLlvm(target, optimize),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/visor.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = fuzzable,
            .imports = &(imports ++ [_]std.Build.Module.Import{
                .{ .name = "corpus", .module = corpus },
                .{ .name = "manifest", .module = manifest_options.createModule() },
                .{ .name = "conduit", .module = conduit.module("conduit") },
            }),
        }),
    });
    const test_step = b.step("test", "Run the visor tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Compiling without running is what a target this host cannot execute can
    // still be held to, and it is also the default step, so a bare
    // `zig build -Dtarget=...` is the same check under another name. Both
    // test binaries and every example are in it; the conformance build under
    // `conformance/` is not, being a build of its own with an emulator to
    // fetch.
    const check_step = b.step("check", "Compile the tests and the examples without running them");
    check_step.dependOn(&tests.step);
    b.getInstallStep().dependOn(check_step);

    // The widgets are a second module and get a second test binary. Every
    // widget's test draws it into a real grid, renders the frame, feeds the
    // bytes to the emulator and compares the picture -- so the suite proves
    // the widget and the renderer together, which is the only combination a
    // user ever runs.
    const widget_tests = b.addTest(.{
        .name = "visor-widget-tests",
        .use_llvm = needsLlvm(target, optimize),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/widgets.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = fuzzable,
            .imports = &.{
                .{ .name = "visor", .module = module },
                .{ .name = "corpus", .module = corpus },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(widget_tests).step);
    check_step.dependOn(&widget_tests.step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the bytes are still the bytes. examples/usage.zig is also
    // where README.md's Usage block comes from -- see ci/readme_usage.sh --
    // so the snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .use_llvm = needsLlvm(target, optimize),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "visor", .module = module },
                    .{ .name = "visor.widgets", .module = widgets },
                },
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(example).step);
        check_step.dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // Conformance against an emulator that is not ours.
    //
    // `Term` ships with this package, so a property that compares the
    // renderer with it compares two readings of the same specifications by
    // the same hand. This step runs the same four properties over the same
    // committed corpus against the terminal inside a shipping emulator,
    // read through its own grid. Where the two disagree, the emulator is
    // right.
    //
    // The emulator is a build of its own, under `conformance/`, with its
    // own manifest pinning it by commit. It is out of this package's
    // dependency tree entirely, so a consumer of `visor` never fetches a
    // terminal emulator to build a program -- which a lazy dependency here
    // would not achieve, because a lazy dependency named in this file is
    // fetched by whoever builds this file.
    //=====================================================================

    const conformance_step = b.step(
        "conformance",
        "Run the round trip against a second terminal emulator",
    );
    const conformance = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    conformance.setCwd(b.path("conformance"));
    conformance.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    conformance.has_side_effects = true;
    conformance_step.dependOn(&conformance.step);
}

/// Whether to hand this compilation to LLVM rather than to Zig's own
/// backend.
///
/// Zig 0.16's self-hosted x86_64 backend dies with SIGSEGV -- no message,
/// no stack -- compiling this package in Debug. The smallest program that
/// reproduces it is one `uucode.get` call and nothing else: the tables
/// uucode generates are three stages of arrays indexed one into the next,
/// and lowering a read through them is what the backend cannot do. Every
/// file that reaches `text.zig` goes down with it, which is every file
/// here. Nothing in this package can avoid it -- measuring a cluster is
/// what the tables are for. The release modes are unaffected because they
/// use LLVM already, and so is the aarch64 backend, which compiles the
/// same call. So the one case that trips takes the other path. Delete this
/// the release it is fixed.
///
/// `conformance/build.zig` builds the same package under the same backend
/// and calls this too, which is why it is public.
pub fn needsLlvm(target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?bool {
    if (optimize != .Debug) return null;
    const result = target.result;
    if (result.cpu.arch == .x86_64 and result.os.tag == .linux) return true;
    return null;
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/viewer.zig",
    "examples/gallery.zig",
    "examples/progress.zig",
};

/// The `uucode` fields this package builds into its tables.
///
/// Grapheme segmentation needs the first two; measuring a cluster needs the
/// rest. Nothing else is built, which is what keeps the tables small. A
/// consumer configuring uucode themselves keeps these and adds their own.
const uucode_fields = [_][]const u8{
    "grapheme_break",
    "grapheme_break_no_control",
    "wcwidth_standalone",
    "wcwidth_zero_in_grapheme",
    "is_emoji_modifier_base",
    "is_emoji_vs_base",
};
