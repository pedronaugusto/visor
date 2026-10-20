const std = @import("std");

/// What a project that depends on visor builds: the `visor` module, and
/// morse's, for a consumer who wants the writers separately.
pub fn build(b: *std.Build) void {
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
    // against. `xenoglyph` segments text into grapheme clusters and measures
    // them: Unicode 18 tables, committed in the package, so nothing is
    // generated at build time.
    //=====================================================================

    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    const xenoglyph = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize });
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const reactor = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const warp = b.dependency("warp", .{ .target = target, .optimize = optimize });
    const imports = dependencies(morse, conduit, xenoglyph, aegis, reactor, warp);

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

    _ = b.addModule("visor", .{
        .root_source_file = b.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    // A consumer who wants the writers separately gets them from here
    // rather than fetching morse a second time.
    b.modules.put(b.allocator, b.graph.dupeString("morse"), morse.module("morse")) catch @panic("OOM");
}

/// visor's development: its tests, examples, conformance run and benchmarks,
/// under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const preflight = tools.preflight;
    const package = b.dependency("visor", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("visor");
    const morse = p.dependency("morse", .{ .target = target, .optimize = optimize });
    const conduit = p.dependency("conduit", .{ .target = target, .optimize = optimize });
    const xenoglyph = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize });
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const reactor = p.dependency("reactor", .{ .target = target, .optimize = optimize });
    const warp = p.dependency("warp", .{ .target = target, .optimize = optimize });
    const imports = dependencies(morse, conduit, xenoglyph, aegis, reactor, warp);

    // What the round-trip properties count of their draws. Its own module
    // because the suite inside the package and the conformance build outside
    // it count the same way, and a file belongs to one module. It is test
    // support, so it is not published: the conformance build makes its own
    // module from the same file.
    const spread = b.createModule(.{ .root_source_file = p.path("src/testing/spread.zig"), .target = target, .optimize = optimize });

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // test block is what pulls every file in.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const tests = b.addTest(.{
        .name = "visor-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &(imports ++ [_]std.Build.Module.Import{
                .{ .name = "spread", .module = spread },
                .{ .name = "conduit", .module = conduit.module("conduit") },
            }),
        }),
    });
    const test_step = b.step("test", "Run the visor tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Compiling without running is what a target this host cannot execute can
    // still be held to, and it is also the default step, so a bare
    // `bay install -Dtarget=...` is the same check under another name. Both
    // test binaries and every example are in it; the conformance build under
    // `conformance/` is not, being a build of its own with an emulator to
    // fetch.
    const check_step = b.step("check", "Compile the tests and the examples without running them");
    check_step.dependOn(&tests.step);
    // A consumer's build links libc or does not, and the package's code
    // branches on it (shared memory through `shm_open`, or the system's own
    // calls, or not at all): the check compiles the suite both ways, so every
    // target is held to what either kind of consumer reaches.
    const libc_tests = b.addTest(.{
        .name = "visor-tests-libc",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &(imports ++ [_]std.Build.Module.Import{
                .{ .name = "spread", .module = spread },
                .{ .name = "conduit", .module = conduit.module("conduit") },
            }),
        }),
    });
    check_step.dependOn(&libc_tests.step);

    // The spread is a separate module: name its own test artifact so its
    // tests are reached without depending on incidental member uses.
    const spread_tests = b.addTest(.{ .name = "visor-spread-tests", .root_module = spread, .filters = filters });
    test_step.dependOn(&b.addRunArtifact(spread_tests).step);
    check_step.dependOn(&spread_tests.step);
    // Compilation must reject byte addresses and byte counts as link positions.
    const domains = b.step("check-domains", "Reject mixed pool scalar domains");
    for ([_][]const u8{ "index", "bytes" }, [_][]const u8{ "u32,false)'", "found 'units.Bytes(u16)'" }) |name, diagnostic| {
        const rejected = b.addObject(.{ .name = b.fmt("domain-{s}", .{name}), .root_module = b.createModule(.{
            .root_source_file = p.path(b.fmt("ci/domain_{s}.zig", .{name})),
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

    // The benchmark's checks hold visor to a decoder, a corpus and a plan
    // of their own, and those have tests of their own.
    const bench_tests = b.addTest(.{
        .name = "visor-bench-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("bench/run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = benchImports(b, target, optimize),
        }),
    });
    // As preflight gives the benchmark program itself: the shakedown visor declares.
    bench_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    check_step.dependOn(&bench_tests.step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the bytes are still the bytes. examples/usage.zig is also
    // where README.md's Usage block comes from -- see bay docs -- usage --
    // so the snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
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
    // cache holds it. That manifest is written from visor's own before the
    // run: shakedown at the revision visor pins, so the two cannot drift,
    // and the emulator, which only this build names.
    //=====================================================================

    const conformance_step = b.step(
        "conformance",
        "Run the round trip against a second terminal emulator",
    );
    const conformance = preflight.addNestedBuild(b, p, .{
        .directory = "conformance",
        .name = "visor_conformance",
        .fingerprint = 0x34e8282c84d67783,
        .paths = &.{ "build.zig", "build.zig.zon", "conformance.zig" },
        .path_dependencies = &.{.{ .name = "visor", .path = ".." }},
        .shared = &.{"shakedown"},
        // The head of ghostty's `zig-0.17` branch (ghostty-org/ghostty#14519)
        // until that port reaches its main; morse's conformance pins the same.
        .pins = &.{.{
            .name = "ghostty",
            .url = "git+https://github.com/ghostty-org/ghostty#5147c0a503cdeed7615cce245cdd815ed7a6b692",
            .hash = "ghostty-1.3.2-dev-5UdBC-lZeAVJbemF7Fz8y5ApP0uA6wTc2uzECn3c6Z_Y",
        }},
        .args = if (test_filter) |f| &.{ "test", b.fmt("-Doptimize={s}", .{@tagName(optimize)}), b.fmt("-Dtest-filter={s}", .{f}) } else &.{ "test", b.fmt("-Doptimize={s}", .{@tagName(optimize)}) },
    });
    conformance_step.dependOn(conformance);

    //=====================================================================
    // CI wiring, and the test doubles
    //=====================================================================

    // Both suites' clocks, fault plans and allocators.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    tests.root_module.addImport("shakedown", shakedown);
    libc_tests.root_module.addImport("shakedown", shakedown);
    preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The release tier fuzzes the properties and runs the suites under
        // ThreadSanitizer. Input is read by a task beside the caller's,
        // handed over through a queue, and stopped by a cancel; a race at
        // that crossing is a claim a detector checks and a reader cannot
        // (`bay hardened-tsan` on Linux).
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
        // visor's own measurements, in bench/: `bay bench` builds
        // the pass in ReleaseFast under zig-out/bench and runs it, and
        // `bay test` runs it once with `--smoke`.
        .bench = .{
            .programs = &.{.{ .name = "visor-bench", .source = "bench/run.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on visor by path, built with fetching off
    // and only morse, conduit and xenoglyph beside it, so nothing visor
    // fetches for its own CI can be reached. It is the build a consumer
    // gets.
    preflight.addConsumerCheck(b, p, .{
        .package = "visor",
        .program = p.path("ci/consumer.zig"),
        .modules = &.{"visor"},
        // conduit waits through reactor, and visor listens for a resize through it.
        .packages = &.{ morse, conduit, reactor, warp, xenoglyph, aegis },
    });
}

/// The modules visor imports.
fn dependencies(morse: *std.Build.Dependency, conduit: *std.Build.Dependency, xenoglyph: *std.Build.Dependency, aegis: *std.Build.Dependency, reactor: *std.Build.Dependency, warp: *std.Build.Dependency) [6]std.Build.Module.Import {
    return .{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "morse", .module = morse.module("morse") },
        .{ .name = "xenoglyph", .module = xenoglyph.module("xenoglyph") },
        .{ .name = "conduit.tty", .module = conduit.module("conduit.tty") },
        .{ .name = "reactor", .module = reactor.module("reactor") },
        .{ .name = "warp", .module = warp.module("warp") },
    };
}

/// visor (widgets included) and the Unicode properties the checks read, in the
/// mode a benchmark builds in: an imported module keeps its own mode, so a
/// ReleaseFast benchmark over the Debug module would time the Debug module.
/// The checks read the Unicode properties visor measures by (East Asian
/// width, general category, combining class) from xenoglyph directly.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("visor", .{ .target = target, .optimize = optimize }).builder;
    const xenoglyph = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize });
    const morse = p.dependency("morse", .{ .target = target, .optimize = optimize });
    const conduit = p.dependency("conduit", .{ .target = target, .optimize = optimize });
    const visor = b.createModule(.{
        .root_source_file = p.path("src/visor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &dependencies(morse, conduit, xenoglyph, p.dependency("aegis", .{ .target = target, .optimize = optimize }), p.dependency("reactor", .{ .target = target, .optimize = optimize }), p.dependency("warp", .{ .target = target, .optimize = optimize })),
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "visor", .module = visor },
        .{ .name = "xenoglyph", .module = xenoglyph.module("xenoglyph") },
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
