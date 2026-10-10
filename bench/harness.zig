//! What every workload shares: the context it runs in, the lines it prints
//! when it is checked, and the adapter that turns a workload into rows for
//! shakedown's `bench`.
//!
//! A workload is a type, in `draw.zig` or `ops.zig`, with
//!
//!     pub fn init(f: *F, c: *Ctx) !void       // the fixture, before any clock
//!     pub fn frame(f: *F, c: *Ctx, n: usize) !void   // frame n, what is timed
//!     pub fn evidence(f: *F, c: *Ctx) void    // check lines about the last run
//!     pub fn deinit(f: *F, c: *Ctx) void
//!
//! A workload whose frame has work that must stay out of the clock, as
//! `style_heavy` restyles every cell, has `stage`, `shot` and `settle` in
//! place of `frame`: `stage` is the untimed part of one frame, `shot` the
//! timed part and `settle` what is done with its result. Its sample is one
//! frame, since the stage of the next cannot come inside a batch.
//!
//! The check path (`visor-bench draw|ops <task> check ...`, in a process of
//! its own) runs a few frames and prints what they made. The benchmark path
//! is one row of shakedown's `bench`: the fixture is built once, before the
//! row's first batch, and every batch of `frame`s (or every `stage`, `shot`
//! and `settle`) meets it; it is freed after the last. Neither reads a clock
//! itself.
const std = @import("std");
const bench = @import("shakedown").bench;
const v = @import("visor");

/// The Io the check lines go out through, set once by the check entry points:
/// unbuffered, so every line is out before anything that stops the program.
pub var stdout_io: std.Io = undefined;

pub fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.mem.print(&buf, fmt, args) catch @panic("report too long");
    raw(s);
}

pub fn raw(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(stdout_io, s) catch @panic("write failed");
}

/// A tagged line of evidence: the tag, a tab, the bytes in hex.
pub fn line(tag: []const u8, bytes: []const u8) void {
    raw(tag);
    raw("\t");
    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < bytes.len) {
        const take = @min(bytes.len - i, buf.len / 2);
        const hexed = std.mem.print(&buf, "{x}", .{bytes[i..][0..take]}) catch unreachable; // unreachable: take is half the buffer
        raw(hexed);
        i += take;
    }
    raw("\n");
}

/// Unwraps an error union or passes a plain value: the two revisions differ
/// only in which calls became fallible.
fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |e| e.payload,
        else => T,
    };
}

pub inline fn must(x: anytype) Payload(@TypeOf(x)) {
    return switch (@typeInfo(@TypeOf(x))) {
        .error_union => x catch |err| std.debug.panic("{s}", .{@errorName(err)}),
        else => x,
    };
}

/// Rows as text: each head cell's grapheme, covered columns skipped, rows
/// right-trimmed, joined by newlines. The same canonical form every library
/// prints, so grids compare across implementations.
pub fn dumpGrid(gpa: std.mem.Allocator, s: *const v.Screen) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const size = s.dimensions();
    for (0..size.rows) |y| {
        const start = out.items.len;
        for (0..size.cols) |x| {
            const c = s.readCell(@intCast(x), @intCast(y)).?;
            if (c.isTail()) continue;
            const t = s.textAt(@intCast(x), @intCast(y));
            out.appendSlice(gpa, if (t.len == 0) " " else t) catch @panic("oom");
        }
        while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (y + 1 < size.rows) out.append(gpa, '\n') catch @panic("oom");
    }
    line("grid", out.items);
}

pub const Ctx = struct {
    /// What the library under test allocates from, in a frame as in a fixture.
    gpa: std.mem.Allocator,
    /// What a fixture's own data is built in (the corpus text, pixel buffers),
    /// all freed together when the run ends.
    fixture: std.mem.Allocator,
    io: std.Io,
    cols: u16,
    rows: u16,
    corpus: []const u8,
    /// Whether the run prints its evidence.
    check: bool = false,
    /// The frames of a check run, for the evidence that names them.
    frames: usize = 0,
    /// What the frames counted and wrote, kept so the work is not optimized
    /// away and so the check can read it.
    count: usize = 0,
    bytes: usize = 0,

    pub fn file(c: *Ctx, name: []const u8) []const u8 {
        const path = c.fixture.print("{s}/{d}x{d}/{s}", .{ c.corpus, c.cols, c.rows, name }) catch @panic("oom");
        return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.fixture, .unlimited) catch |err| std.debug.panic("corpus {s}: {s}", .{ path, @errorName(err) });
    }

    pub fn lines(c: *Ctx, name: []const u8) [][]const u8 {
        const data = c.file(name);
        var found: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
        while (it.next()) |l| found.append(c.fixture, l) catch @panic("oom");
        return found.items;
    }

    pub fn screen(c: *Ctx) v.Screen {
        var s = must(v.Screen.init(c.gpa, c.size()));
        s.method = .unicode;
        return s;
    }

    pub fn size(c: *const Ctx) v.Size {
        return .{ .cols = c.cols, .rows = c.rows };
    }
};

/// One workload, checked: `frames` frames, then its evidence, then the line
/// `run.zig` reads.
pub fn check(comptime F: type, c: *Ctx) !void {
    var f: F = undefined;
    try F.init(&f, c);
    defer F.deinit(&f, c);
    for (0..c.frames) |n| {
        if (comptime @hasDecl(F, "shot")) {
            try F.stage(&f, c, n);
            try F.shot(&f, c);
            try F.settle(&f, c);
        } else try F.frame(&f, c, n);
    }
    F.evidence(&f, c);
    emit("result\t{d}\t{d}\t{d}\n", .{ c.frames, c.count, c.bytes });
}

/// One checked workload in a process of its own: `args` are
/// `<task> check <cols> <rows> <frames>`, or `list-tasks`. Its lines of
/// evidence go to standard output, and the last is `result\t<frames>\t<count>\t<bytes>`.
pub fn checked(init: std.process.Init, comptime workloads: anytype, min_cols: u16, args: []const []const u8) !void {
    stdout_io = init.io;
    if (args.len == 1 and std.mem.eql(u8, args[0], "list-tasks")) {
        inline for (workloads) |entry| emit("{s}\n", .{entry[0]});
        return;
    }
    if (args.len != 5 or !std.mem.eql(u8, args[1], "check")) return error.Arguments;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var c: Ctx = .{
        .gpa = init.gpa,
        .fixture = arena.allocator(),
        .io = init.io,
        .cols = try std.fmt.parseInt(u16, args[2], 10),
        .rows = try std.fmt.parseInt(u16, args[3], 10),
        .frames = try std.fmt.parseInt(usize, args[4], 10),
        .corpus = init.environ_map.get("VISOR_BENCH_CORPUS") orelse return error.NoCorpus,
        .check = true,
    };
    if (c.cols < min_cols or c.rows < 4 or c.frames == 0) return error.InvalidSize;
    inline for (workloads) |entry| {
        if (std.mem.eql(u8, args[0], entry[0])) return check(entry[1], &c);
    }
    return error.UnknownTask;
}

/// The context shakedown's rows run in: one workload at a time, at the size
/// the pass is at.
pub const Bench = struct {
    ctx: Ctx,
    arena: std.heap.ArenaAllocator,
    slot: ?*anyopaque = null,
    /// The frames staged so far, for a workload whose frames differ.
    staged: usize = 0,
};

/// The error set of a callback that returns an error union.
fn ErrorsOf(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
}

/// `F` as the fixture, run and stages of a row. The fixture lives as long as
/// the row, so every batch meets the one a workload built before any clock.
pub fn Hooks(comptime F: type) type {
    return struct {
        pub fn setup(x: *Bench) !void {
            x.arena = .init(x.ctx.gpa);
            errdefer x.arena.deinit();
            x.ctx.fixture = x.arena.allocator();
            x.ctx.count = 0;
            x.ctx.bytes = 0;
            x.staged = 0;
            const f = try x.ctx.gpa.create(F);
            errdefer x.ctx.gpa.destroy(f);
            try F.init(f, &x.ctx);
            x.slot = f;
        }

        /// Where the frame has work the clock must not see, it is done here,
        /// so the sample is the timed part alone.
        pub fn stage(x: *Bench, _: u64) !void {
            try F.stage(fixture(x), &x.ctx, x.staged);
            x.staged += 1;
        }

        pub fn run(x: *Bench, units: u64) !void {
            const f = fixture(x);
            if (comptime sampled(F)) return F.shot(f, &x.ctx);
            for (0..units) |n| try F.frame(f, &x.ctx, n);
        }

        pub fn settle(x: *Bench, _: u64) !void {
            try F.settle(fixture(x), &x.ctx);
        }

        pub fn teardown(x: *Bench) !void {
            const f = fixture(x);
            F.deinit(f, &x.ctx);
            x.ctx.gpa.destroy(f);
            x.arena.deinit();
            x.slot = null;
            std.mem.doNotOptimizeAway(x.ctx.count + x.ctx.bytes);
        }

        fn fixture(x: *Bench) *F {
            return @ptrCast(@alignCast(x.slot.?)); // safe: this same F's setup stored it
        }
    };
}

/// The row of workload `F`, named `name`. A workload whose frame has work the
/// clock must not see is staged before each frame and settled after it, and its
/// sample is one frame, since the stage of the next cannot come inside a batch;
/// the others are batched until a sample can be read.
pub fn row(comptime F: type, comptime WorkloadError: type, name: []const u8) bench.Row(Bench, WorkloadError) {
    const H = Hooks(F);
    return .{
        .name = name,
        .unit = "frame",
        .fixture = .{ .lifetime = .row, .setup = H.setup, .teardown = H.teardown },
        .run = H.run,
        .grow = !sampled(F),
        .stage = if (comptime sampled(F)) H.stage else null,
        .settle = if (comptime sampled(F)) H.settle else null,
    };
}

/// The error set of every callback of `workloads`, a tuple of `.{ name, F }`.
pub fn ErrorOf(comptime workloads: anytype) type {
    var set: type = error{};
    inline for (workloads) |entry| {
        const H = Hooks(entry[1]);
        set = set || ErrorsOf(H.setup) || ErrorsOf(H.run) || ErrorsOf(H.teardown);
        if (sampled(entry[1])) set = set || ErrorsOf(H.stage) || ErrorsOf(H.settle);
    }
    return set;
}

/// Whether a workload's sample is one frame.
pub fn sampled(comptime F: type) bool {
    return @hasDecl(F, "shot");
}
