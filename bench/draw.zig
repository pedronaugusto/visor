//! The drawing core: eight workloads over two screens and a renderer. A
//! frame is what the clock reads, except in `style_heavy`, whose frame is
//! restyled in full before the draw and whose clock reads the draw alone.
//! `harness.zig` says how a workload is run and checked.
const std = @import("std");
const v = @import("visor");
const harness = @import("harness.zig");
const Ctx = harness.Ctx;

fn hex(bytes: []const u8) void {
    for (bytes) |b| harness.emit("{x:0>2}", .{b});
    harness.emit("\n", .{});
}

fn paint(s: *v.Screen, cols: u16, rows: u16, salt: usize, heavy: bool) !void {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (0..rows) |y| for (0..cols) |x| {
        const i = y * cols + x;
        const style: v.Style = if (heavy) .{
            .fg = .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53)),
            .bold = (i + salt) % 2 == 0,
        } else .{};
        try s.write(@intCast(x), @intCast(y), alphabet[(i + (if (heavy) @as(usize, 0) else salt)) % alphabet.len ..][0..1], style, .none);
    };
}

fn restyle(s: *v.Screen, cols: u16, rows: u16, salt: usize) !void {
    for (0..rows) |y| for (0..cols) |x| {
        const i = y * cols + x;
        var c = s.readCell(@intCast(x), @intCast(y)).?;
        c.setStyle(.{
            .fg = .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53)),
            .bold = (i + salt) % 2 == 0,
        });
        try s.writeOwnedCell(@intCast(x), @intCast(y), c);
    };
}

fn equal(a: v.Cell, b: v.Cell) bool {
    return v.Cell.eql(a, b);
}

// The two diff workloads' frames, each a function of its own that is never
// inlined: what the compiler makes of the timed loop then depends on visor
// and on nothing in this harness around it.

/// One `buffer_diff` frame: the cells `Screen.diff` reports changed.
noinline fn diffCells(screens: *const [2]v.Screen) usize {
    var changed: usize = 0;
    var changes = screens[0].diff(&screens[1]);
    while (changes.next()) |point| {
        std.mem.doNotOptimizeAway(point);
        changed += 1;
    }
    std.mem.doNotOptimizeAway(changed);
    return changed;
}

/// One `cell_reads` frame: every cell of both screens read and compared.
noinline fn readCells(screens: *const [2]v.Screen) usize {
    var changed: usize = 0;
    const size = screens[0].dimensions();
    for (0..size.rows) |y| for (0..size.cols) |x| {
        const a = screens[0].readCell(@intCast(x), @intCast(y)).?;
        const b = screens[1].readCell(@intCast(x), @intCast(y)).?;
        if (!equal(a, b)) changed += 1;
    };
    std.mem.doNotOptimizeAway(changed);
    return changed;
}

const Kind = enum {
    cell_reads,
    buffer_diff,
    full_repaint,
    unchanged_diff,
    style_heavy,
    unchanged_idle,
    picture_layers,
    picture_unchanged,
};

/// The two screens, the renderer and the output every workload draws with.
fn Fixture(comptime kind: Kind) type {
    const heavy = kind == .style_heavy;
    const diff = kind == .buffer_diff or kind == .cell_reads;
    const picture = kind == .picture_layers or kind == .picture_unchanged;
    return struct {
        const Self = @This();

        screens: [2]v.Screen,
        renderer: v.Renderer,
        layers: v.Layers,
        out: std.Io.Writer.Allocating,
        caps: v.Caps,
        /// The cells the last draw reported, between a shot and its settling.
        cells: usize = 0,

        fn init(f: *Self, c: *Ctx) !void {
            const gpa = c.gpa;
            if (c.cols < 4 or c.rows < 4) return error.InvalidSize;
            const size = c.size();
            f.screens[0] = try .init(gpa, size);
            errdefer f.screens[0].deinit();
            f.screens[1] = try .init(gpa, size);
            errdefer f.screens[1].deinit();
            for (&f.screens) |*s| s.method = .unicode;
            try paint(&f.screens[0], c.cols, c.rows, 0, heavy);
            try paint(&f.screens[1], c.cols, c.rows, if (heavy) 1 else 0, heavy);
            if (diff) for (0..size.area()) |i| {
                if (i % 97 == 0) try f.screens[1].write(@intCast(i % c.cols), @intCast(i / c.cols), "!", .{}, .none);
            };
            f.renderer = try .init(gpa, size);
            errdefer f.renderer.deinit();
            f.layers = .init(gpa);
            errdefer f.layers.deinit();
            f.out = .init(gpa);
            errdefer f.out.deinit();
            f.cells = 0;
            f.caps = .{ .width_method = .unicode, .truecolor = true, .kitty_graphics = picture };
            if (picture) {
                var pixels: [16 * 16 * 4]u8 = undefined;
                for (0..16 * 16) |i| pixels[i * 4 ..][0..4].* = .{ 31, 63, 127, 255 };
                _ = try f.layers.transmit(&f.out.writer, 7, &pixels, .{ .width = 16, .height = 16, .compress = false });
                if (c.check) hex(f.out.written());
                try f.layers.declare(.{ .image = 7, .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 } });
            }
            if (!diff) {
                f.out.clearRetainingCapacity();
                _ = try f.renderer.draw(&f.out.writer, &f.screens[0], if (picture) &f.layers else null, f.caps);
                if (c.check) hex(f.out.written());
            }
            // Reserve the maximum output outside the interval; no terminal is opened.
            try f.out.ensureTotalCapacity(@as(usize, size.area()) * 64 + 8192);
            f.out.clearRetainingCapacity();
        }

        fn deinit(f: *Self) void {
            f.out.deinit();
            f.layers.deinit();
            f.renderer.deinit();
            for (&f.screens) |*s| s.deinit();
        }
    };
}

/// The workload `kind` names, all but `style_heavy`: its frame is timed whole.
fn Core(comptime kind: Kind) type {
    const diff = kind == .buffer_diff or kind == .cell_reads;
    const picture = kind == .picture_layers or kind == .picture_unchanged;
    const Fx = Fixture(kind);
    return struct {
        const Self = @This();

        fx: Fx,

        pub fn init(f: *Self, c: *Ctx) !void {
            try Fx.init(&f.fx, c);
        }

        pub fn deinit(f: *Self, _: *Ctx) void {
            f.fx.deinit();
        }

        pub fn evidence(_: *Self, _: *Ctx) void {}

        pub fn frame(f: *Self, c: *Ctx, n: usize) !void {
            const fx = &f.fx;
            if (diff) {
                c.count += if (kind == .cell_reads) readCells(&fx.screens) else diffCells(&fx.screens);
                return;
            }
            // Keep one screen owner: switching unrelated screens invalidates
            // current-main handles and would measure an artificial repaint.
            const s = &fx.screens[0];
            if (kind == .full_repaint) fx.renderer.repaint();
            if (kind == .unchanged_diff) s.damageAll();
            if (picture) try fx.layers.declare(.{ .image = 7, .rect = .{
                .col = if (kind == .picture_layers) @intCast((n + 1) % 2) else 0,
                .row = 0,
                .cols = 2,
                .rows = 2,
            } });
            fx.out.clearRetainingCapacity();
            const stats = try fx.renderer.draw(&fx.out.writer, s, if (picture) &fx.layers else null, fx.caps);
            c.bytes += fx.out.written().len;
            c.count += stats.cells;
            std.mem.doNotOptimizeAway(fx.out.written());
            if (c.check) hex(fx.out.written());
        }
    };
}

/// `style_heavy`: every cell restyled and damaged before each draw, which is
/// all the clock reads. The restyle is the stage of a frame, the draw its
/// shot, and the bookkeeping after it the settling.
const StyleHeavy = struct {
    fx: Fixture(.style_heavy),

    pub fn init(f: *StyleHeavy, c: *Ctx) !void {
        try @TypeOf(f.fx).init(&f.fx, c);
    }

    pub fn deinit(f: *StyleHeavy, _: *Ctx) void {
        f.fx.deinit();
    }

    pub fn evidence(_: *StyleHeavy, _: *Ctx) void {}

    pub fn stage(f: *StyleHeavy, c: *Ctx, n: usize) !void {
        const s = &f.fx.screens[0];
        try restyle(s, c.cols, c.rows, (n + 1) % 2);
        s.damageAll();
        f.fx.out.clearRetainingCapacity();
    }

    pub fn shot(f: *StyleHeavy, _: *Ctx) !void {
        const stats = try f.fx.renderer.draw(&f.fx.out.writer, &f.fx.screens[0], null, f.fx.caps);
        f.fx.cells = stats.cells;
    }

    pub fn settle(f: *StyleHeavy, c: *Ctx) !void {
        c.bytes += f.fx.out.written().len;
        c.count += f.fx.cells;
        std.mem.doNotOptimizeAway(f.fx.out.written());
        if (c.check) hex(f.fx.out.written());
    }
};

/// The workloads, in the order a pass runs them.
pub const workloads = .{
    .{ "cell_reads", Core(.cell_reads) },
    .{ "buffer_diff", Core(.buffer_diff) },
    .{ "full_repaint", Core(.full_repaint) },
    .{ "unchanged_diff", Core(.unchanged_diff) },
    .{ "style_heavy", StyleHeavy },
    .{ "unchanged_idle", Core(.unchanged_idle) },
    .{ "picture_layers", Core(.picture_layers) },
    .{ "picture_unchanged", Core(.picture_unchanged) },
};
