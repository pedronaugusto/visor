const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // Dependencies.
    //
    // `morse` writes every escape sequence this package emits and parses
    // every reply it reads. `conduit` owns the terminal's own calls -- raw
    // mode and the way back, the size, the device's name -- for this package
    // and for programs that run a child on a pseudo-terminal alike. Only its
    // `conduit.tty` module is imported, which on Linux links no C library;
    // the suite also takes `conduit` whole for the pseudo-terminal it tests
    // against. `uucode` is configured with the six fields this package uses
    // and no others: the field list is printed in the README so a consumer
    // who configures uucode themselves knows which to keep.
    //=====================================================================

    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &uucode_fields),
    });
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const reactor = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const warp = b.dependency("warp", .{ .target = target, .optimize = optimize });
    const imports = dependencies(morse, conduit, uucode, aegis, reactor, warp);

    //=====================================================================
    // The module.
    //
    // One: `visor`, with the widgets as `visor.widgets` inside it. A widget
    // brings no dependency and links nothing the base does not, so a second
    // module would buy a consumer nothing that Zig's lazy analysis does not
    // already give: a program that never names a widget compiles none. The
    // base never imports the widgets, which gantry's layer check enforces
    // on the files (ci/layers.zig).
    //=====================================================================

    const module = b.addModule("visor", .{
        .root_source_file = b.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    // A consumer who wants the writers separately gets them from here
    // rather than fetching morse a second time.
    b.modules.put(b.allocator, b.graph.dupeString("morse"), morse.module("morse")) catch @panic("OOM");

    // Everything below is visor's own tree: a program that depends on visor
    // builds the module above and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;

    // The inputs the round-trip properties replay. Its own module because
    // the suite inside the package and the conformance build outside it
    // have to replay the same bytes, and a file belongs to one module. It is
    // test data, so it is not published: the conformance build makes its
    // own module from the same file.
    const corpus = b.createModule(.{ .root_source_file = b.path("src/testing/corpus.zig"), .target = target, .optimize = optimize });

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // test block is what pulls every file in.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    // Input is read by a task beside the caller's, handed over through a
    // queue, and stopped by a cancel; a race at that crossing is a claim a
    // detector can check and a reader cannot: `zig build test
    // -Dthread-sanitizer`. The detector is an LLVM pass.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;
    const sanitize: ?bool = if (thread_sanitizer) true else null;

    const tests = b.addTest(.{
        .name = "visor-tests",
        .filters = filters,
        .use_llvm = if (thread_sanitizer) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize,
            .imports = &(imports ++ [_]std.Build.Module.Import{
                .{ .name = "corpus", .module = corpus },
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

    // The corpus is a separate module: name its own test artifact so its
    // tests are reached without depending on incidental member uses.
    const corpus_tests = b.addTest(.{ .name = "visor-corpus-tests", .root_module = corpus, .filters = filters });
    test_step.dependOn(&b.addRunArtifact(corpus_tests).step);
    check_step.dependOn(&corpus_tests.step);
    // Compilation must reject byte addresses and byte counts as link positions.
    const domains = b.step("check-domains", "Reject mixed pool scalar domains");
    for ([_][]const u8{ "index", "bytes" }, [_][]const u8{ "u32,false)'", "found 'units.Bytes(u16)'" }) |name, diagnostic| {
        const rejected = b.addObject(.{ .name = b.fmt("domain-{s}", .{name}), .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("ci/domain_{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "visor", .module = module }},
        }) });
        rejected.expect_errors = .{ .contains = diagnostic };
        domains.dependOn(&rejected.step);
    }
    test_step.dependOn(domains);
    check_step.dependOn(domains);
    b.getInstallStep().dependOn(check_step);

    // The widgets get a test binary of their own, so it compiles beside the
    // base's; for a consumer they are the same module. Every widget's test
    // draws it into a real grid, renders the frame, feeds the bytes to the
    // emulator and compares the picture -- so the suite proves the widget
    // and the renderer together, which is the only combination a user ever
    // runs.
    const widget_tests = b.addTest(.{
        .name = "visor-widget-tests",
        .filters = filters,
        .use_llvm = if (thread_sanitizer) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/widgets_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize,
            .imports = &(imports ++ [_]std.Build.Module.Import{
                .{ .name = "corpus", .module = corpus },
            }),
        }),
    });
    test_step.dependOn(&b.addRunArtifact(widget_tests).step);
    check_step.dependOn(&widget_tests.step);

    // The benchmark's checks hold visor to a decoder, a corpus and a plan
    // of their own, and those have tests of their own.
    const bench_tests = b.addTest(.{
        .name = "visor-bench-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = benchImports(b, target, optimize),
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    check_step.dependOn(&bench_tests.step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the bytes are still the bytes. examples/usage.zig is also
    // where README.md's Usage block comes from -- see zig build docs -- usage --
    // so the snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "visor", .module = module }},
            }),
        });
        const run_example = b.addRunArtifact(example);
        if (std.mem.eql(u8, source, "examples/live.zig")) {
            run_example.addArg("--check");
            const live_step = b.step("live", "Run the session example in a terminal");
            live_step.dependOn(&b.addRunArtifact(example).step);
        }
        examples_step.dependOn(&run_example.step);
        check_step.dependOn(&example.step);
    }
    if (test_filter == null) test_step.dependOn(examples_step);

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
    // own manifest pinning it by commit. Zig compiles the build script of
    // every package a manifest names once it is in the package cache, asked
    // for or not, so an emulator named in this package's manifest, even
    // lazily, would be compiled by every build of a program on visor whose
    // cache holds it.
    //=====================================================================

    const conformance_step = b.step(
        "conformance",
        "Run the round trip against a second terminal emulator",
    );
    const conformance = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    conformance.setCwd(b.path("conformance"));
    conformance.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    if (test_filter) |f| conformance.addArg(b.fmt("-Dtest-filter={s}", .{f}));
    conformance.has_side_effects = true;
    conformance_step.dependOn(&conformance.step);

    //=====================================================================
    // CI wiring, and the test doubles
    //
    // preflight and shakedown are lazy, and only visor's own tree asks for
    // them, both in one configure pass. A lazy package's build.zig can only
    // be reached through `lazyImport`: a plain `@import` of it fails to
    // compile in any project that depends on visor and has not fetched
    // preflight, which is every such project.
    //=====================================================================

    const ci = b.lazyImport(@This(), "preflight");
    // Both suites' clocks, fault plans and allocators.
    const shakedown = (try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })).module("shakedown");
    tests.root_module.addImport("shakedown", shakedown);
    widget_tests.root_module.addImport("shakedown", shakedown);
    bench_tests.root_module.addImport("shakedown", shakedown);
    if (ci) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            // visor's own measurements, in bench/: `zig build bench` builds
            // the pass in ReleaseFast under zig-out/bench and runs it, and
            // `zig build test` runs it once with `--smoke`.
            .bench = .{
                .programs = &.{.{ .name = "visor-bench", .source = "bench/run.zig" }},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on visor by path, built with fetching off
        // and only morse, conduit and uucode beside it, so nothing visor
        // fetches for its own CI can be reached. It is the build a consumer
        // gets.
        preflight.addConsumerCheck(b, .{
            .package = "visor",
            .program = b.path("ci/consumer.zig"),
            .modules = &.{"visor"},
            // conduit waits through reactor, and visor listens for a resize through it.
            .packages = &.{ morse, conduit, reactor, warp, uucode, aegis },
        });
    }
}

/// The modules visor imports.
fn dependencies(morse: *std.Build.Dependency, conduit: *std.Build.Dependency, uucode: *std.Build.Dependency, aegis: *std.Build.Dependency, reactor: *std.Build.Dependency, warp: *std.Build.Dependency) [6]std.Build.Module.Import {
    return .{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "morse", .module = morse.module("morse") },
        .{ .name = "uucode", .module = uucode.module("uucode") },
        .{ .name = "conduit.tty", .module = conduit.module("conduit.tty") },
        .{ .name = "reactor", .module = reactor.module("reactor") },
        .{ .name = "warp", .module = warp.module("warp") },
    };
}

/// visor (widgets included) and the Unicode properties the checks read, in the
/// mode a benchmark builds in: an imported module keeps its own mode, so a
/// ReleaseFast benchmark over the Debug module would time the Debug module.
/// The checks read properties of their own, independent of the rule visor
/// measures by, from a second uucode table: one program holds one uucode,
/// and visor's table is the one a consumer builds, field for field.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields_0 = @as([]const []const u8, &uucode_fields),
        .fields_1 = @as([]const []const u8, &.{ "east_asian_width", "general_category", "canonical_combining_class" }),
    });
    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    const visor = b.createModule(.{
        .root_source_file = b.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &dependencies(morse, conduit, uucode, b.dependency("aegis", .{ .target = target, .optimize = optimize }), b.dependency("reactor", .{ .target = target, .optimize = optimize }), b.dependency("warp", .{ .target = target, .optimize = optimize })),
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "visor", .module = visor },
        .{ .name = "uucode", .module = uucode.module("uucode") },
    }) catch @panic("OOM");
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/viewer.zig",
    "examples/gallery.zig",
    "examples/progress.zig",
    "examples/live.zig",
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
