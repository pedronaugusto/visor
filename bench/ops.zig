//! Every other public visor operation, as workloads: `harness.zig` says how
//! one is run and checked, and `visor-bench ops list-tasks` names them.
//! Text inputs come from the generated corpus directory, identical for every
//! library. Corpus reads and fixture construction are the setup of a
//! workload; its frames are what the clock reads.
const std = @import("std");
const v = @import("visor");
const w = v.widgets;
const harness = @import("harness.zig");
const Ctx = harness.Ctx;
const emit = harness.emit;
const line = harness.line;
const must = harness.must;
const dumpGrid = harness.dumpGrid;

fn fill(s: *v.Screen, rect: v.Rect, c: v.Cell) void {
    must(s.fill(rect, c));
}

const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
const caps: v.Caps = .{ .width_method = .unicode, .truecolor = true };

fn rgb(i: usize, salt: usize) v.Color {
    return .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53));
}

fn digestOf(bytes: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return d;
}

/// A frame's output, for the renderer to write to: room reserved for the
/// whole grid before the clock.
fn output(c: *Ctx) std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    must(out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 64 + 8192));
    return out;
}

/// The rows of `name` printed down a window, as the fixture of the workloads
/// that start from a full screen.
fn printDown(win: v.Window, src: []const []const u8, rows: u16) void {
    for (0..rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
}

// ---------------------------------------------------------------- the grid

const CellWrites = struct {
    s: v.Screen,

    pub fn init(f: *CellWrites, c: *Ctx) !void {
        f.s = c.screen();
    }

    pub fn deinit(f: *CellWrites, _: *Ctx) void {
        f.s.deinit();
    }

    pub fn frame(f: *CellWrites, c: *Ctx, n: usize) !void {
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
        for (0..c.rows) |y| for (0..c.cols) |x| {
            const i = y * c.cols + x;
            must(f.s.write(@intCast(x), @intCast(y), alphabet[(i + n) % alphabet.len ..][0..1], .{ .fg = rgb(i, n % 2), .bold = (i + n) % 2 == 0 }, .none));
        };
        c.count += @as(usize, c.cols) * c.rows;
    }

    pub fn evidence(f: *CellWrites, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
    }
};

fn PrintRows(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        s: v.Screen,
        src: [][]const u8,
        win: v.Window,

        pub fn init(f: *Self, c: *Ctx) !void {
            f.s = c.screen();
            f.src = c.lines(name);
            f.win = f.s.window();
        }

        pub fn deinit(f: *Self, _: *Ctx) void {
            f.s.deinit();
        }

        pub fn frame(f: *Self, c: *Ctx, n: usize) !void {
            for (0..c.rows) |y| {
                const text = f.src[(y + n) % f.src.len];
                _ = must(f.win.printSegment(.{ .text = text, .style = .{ .fg = rgb(y, n % 2) } }, .{ .row = @intCast(y), .wrap = .none }));
            }
            c.count += c.rows;
        }

        pub fn evidence(f: *Self, c: *Ctx) void {
            dumpGrid(c.gpa, &f.s);
        }
    };
}

const WideRepaint = struct {
    s: v.Screen,
    r: v.Renderer,
    out: std.Io.Writer.Allocating,

    pub fn init(f: *WideRepaint, c: *Ctx) !void {
        f.s = c.screen();
        f.r = must(v.Renderer.init(c.gpa, c.size()));
        f.out = output(c);
        printDown(f.s.window(), c.lines("wide.txt"), c.rows);
    }

    pub fn deinit(f: *WideRepaint, _: *Ctx) void {
        f.out.deinit();
        f.r.deinit();
        f.s.deinit();
    }

    pub fn frame(f: *WideRepaint, c: *Ctx, _: usize) !void {
        f.r.repaint();
        f.out.clearRetainingCapacity();
        const stats = must(f.r.draw(&f.out.writer, &f.s, null, caps));
        c.count += stats.cells;
        c.bytes += f.out.written().len;
        std.mem.doNotOptimizeAway(f.out.written());
    }

    pub fn evidence(f: *WideRepaint, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
        line("wire", f.out.written());
    }
};

const FillClear = struct {
    s: v.Screen,
    all: v.Rect,

    pub fn init(f: *FillClear, c: *Ctx) !void {
        f.s = c.screen();
        f.all = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
    }

    pub fn deinit(f: *FillClear, _: *Ctx) void {
        f.s.deinit();
    }

    pub fn frame(f: *FillClear, c: *Ctx, n: usize) !void {
        fill(&f.s, f.all, .blank(.{ .bg = rgb(n, 1) }));
        f.s.clear();
        c.count += 2 * @as(usize, c.cols) * c.rows;
    }

    pub fn evidence(f: *FillClear, c: *Ctx) void {
        fill(&f.s, f.all, .blank(.{ .bg = rgb(1, 1) }));
        dumpGrid(c.gpa, &f.s);
    }
};

/// A terminal profile with scrolling regions: the caller's caps say so.
const scrolling: v.Caps = .{ .width_method = .unicode, .truecolor = true, .decstbm = true, .su = true, .scroll_detection = true };

/// The whole frame of a scrolling log is the job: the scroll, the new row and,
/// for `scroll_repaint`, the draw. Every library is clocked so.
fn ScrollRows(comptime render: bool) type {
    return struct {
        const Self = @This();

        s: v.Screen,
        r: v.Renderer,
        out: std.Io.Writer.Allocating,
        src: [][]const u8,
        win: v.Window,
        all: v.Rect,

        pub fn init(f: *Self, c: *Ctx) !void {
            f.s = c.screen();
            f.r = must(v.Renderer.init(c.gpa, c.size()));
            f.out = output(c);
            f.src = c.lines("log.txt");
            f.win = f.s.window();
            printDown(f.win, f.src, c.rows);
            if (render) {
                _ = must(f.r.draw(&f.out.writer, &f.s, null, scrolling));
                if (c.check) line("wire", f.out.written());
            }
            f.all = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
        }

        pub fn deinit(f: *Self, _: *Ctx) void {
            f.out.deinit();
            f.r.deinit();
            f.s.deinit();
        }

        pub fn frame(f: *Self, c: *Ctx, n: usize) !void {
            f.s.scroll(f.all, 1);
            _ = must(f.win.printSegment(.{ .text = f.src[(c.rows + n) % f.src.len] }, .{ .row = c.rows - 1, .wrap = .none }));
            c.count += 1;
            if (render) {
                f.out.clearRetainingCapacity();
                const stats = must(f.r.draw(&f.out.writer, &f.s, null, scrolling));
                c.bytes += f.out.written().len;
                c.count += stats.cells;
                if (c.check) line("wire", f.out.written());
            }
        }

        pub fn evidence(f: *Self, c: *Ctx) void {
            dumpGrid(c.gpa, &f.s);
        }
    };
}

const ResizeGrid = struct {
    s: v.Screen,
    small: v.Size,

    pub fn init(f: *ResizeGrid, c: *Ctx) !void {
        f.s = c.screen();
        printDown(f.s.window(), c.lines("ascii.txt"), c.rows);
        f.small = .{ .cols = c.cols - 3, .rows = c.rows - 2 };
    }

    pub fn deinit(f: *ResizeGrid, _: *Ctx) void {
        f.s.deinit();
    }

    pub fn frame(f: *ResizeGrid, c: *Ctx, _: usize) !void {
        must(f.s.resize(f.small));
        must(f.s.resize(c.size()));
        c.count += 2;
    }

    pub fn evidence(f: *ResizeGrid, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
    }
};

const CopyCells = struct {
    src: v.Screen,
    dst: v.Screen,

    pub fn init(f: *CopyCells, c: *Ctx) !void {
        f.src = c.screen();
        f.dst = c.screen();
        printDown(f.src.window(), c.lines("wide.txt"), c.rows);
    }

    pub fn deinit(f: *CopyCells, _: *Ctx) void {
        f.dst.deinit();
        f.src.deinit();
    }

    pub fn frame(f: *CopyCells, c: *Ctx, _: usize) !void {
        for (0..c.rows) |y| for (0..c.cols) |x| {
            const cell = f.src.readCell(@intCast(x), @intCast(y)).?;
            if (cell.isTail()) continue;
            must(f.dst.copyCell(&f.src, @intCast(x), @intCast(y), cell));
        };
        c.count += @as(usize, c.cols) * c.rows;
    }

    pub fn evidence(f: *CopyCells, c: *Ctx) void {
        dumpGrid(c.gpa, &f.dst);
    }
};

const CopyText = struct {
    s: v.Screen,
    win: v.Window,
    out: std.Io.Writer.Allocating,

    pub fn init(f: *CopyText, c: *Ctx) !void {
        f.s = c.screen();
        f.win = f.s.window();
        printDown(f.win, c.lines("wide.txt"), c.rows);
        f.out = .init(c.gpa);
        must(f.out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 8));
    }

    pub fn deinit(f: *CopyText, _: *Ctx) void {
        f.out.deinit();
        f.s.deinit();
    }

    pub fn frame(f: *CopyText, c: *Ctx, _: usize) !void {
        f.out.clearRetainingCapacity();
        for (0..c.rows) |y| {
            must(f.win.copyText(&f.out.writer, @intCast(y), 0, c.cols));
            must(f.out.writer.writeByte('\n'));
        }
        c.bytes += f.out.written().len;
        c.count += c.rows;
    }

    pub fn evidence(f: *CopyText, _: *Ctx) void {
        line("text", f.out.written());
    }
};

/// Interning and linked writes are frame construction; the measured job is a
/// frame whose every row carries its own OSC 8 target.
const Links = struct {
    s: v.Screen,
    r: v.Renderer,
    out: std.Io.Writer.Allocating,

    const linked: v.Caps = .{ .width_method = .unicode, .truecolor = true, .osc8 = true };

    pub fn init(f: *Links, c: *Ctx) !void {
        f.s = c.screen();
        f.r = must(v.Renderer.init(c.gpa, c.size()));
        f.out = output(c);
        const src = c.lines("ascii.txt");
        var uri_buf: [64]u8 = undefined;
        for (0..c.rows) |y| {
            const uri = std.mem.print(&uri_buf, "https://example.com/row/{d}", .{y}) catch unreachable; // unreachable: a row number fits
            const l = must(f.s.link(uri, ""));
            _ = must(f.s.window().printSegment(.{ .text = src[y % src.len], .link = l }, .{ .row = @intCast(y), .wrap = .none }));
        }
    }

    pub fn deinit(f: *Links, _: *Ctx) void {
        f.out.deinit();
        f.r.deinit();
        f.s.deinit();
    }

    pub fn frame(f: *Links, c: *Ctx, _: usize) !void {
        f.r.repaint();
        f.out.clearRetainingCapacity();
        const stats = must(f.r.draw(&f.out.writer, &f.s, null, linked));
        c.count += stats.cells;
        c.bytes += f.out.written().len;
    }

    pub fn evidence(f: *Links, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
        line("wire", f.out.written());
    }
};

const GraphemePool = struct {
    s: v.Screen,
    clusters: [][]const u8,

    pub fn init(f: *GraphemePool, c: *Ctx) !void {
        f.s = c.screen();
        f.clusters = c.lines("pool.txt");
    }

    pub fn deinit(f: *GraphemePool, _: *Ctx) void {
        f.s.deinit();
    }

    pub fn frame(f: *GraphemePool, c: *Ctx, n: usize) !void {
        for (0..c.rows) |y| {
            var x: u16 = 0;
            var k: usize = 0;
            while (x + 2 <= c.cols) : (x += 2) {
                const g = f.clusters[(n * 7 + y * c.cols + k) % f.clusters.len];
                must(f.s.write(x, @intCast(y), g, .{}, .none));
                k += 1;
            }
        }
        must(f.s.compactPool());
        c.count += 1;
    }

    pub fn evidence(f: *GraphemePool, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
    }
};

const Modes = struct {
    r: v.Renderer,
    out: std.Io.Writer.Allocating,

    const wanted: v.Modes = .{ .mouse = .{ .motion = .any }, .focus = true, .paste = true };

    pub fn init(f: *Modes, c: *Ctx) !void {
        f.r = must(v.Renderer.init(c.gpa, c.size()));
        f.out = .init(c.gpa);
        must(f.out.ensureTotalCapacity(4096));
    }

    pub fn deinit(f: *Modes, _: *Ctx) void {
        f.out.deinit();
        f.r.deinit();
    }

    pub fn frame(f: *Modes, c: *Ctx, _: usize) !void {
        f.out.clearRetainingCapacity();
        must(f.r.enter(&f.out.writer, caps, .alt, wanted));
        must(f.r.leave(&f.out.writer));
        c.bytes += f.out.written().len;
        c.count += 1;
    }

    pub fn evidence(f: *Modes, _: *Ctx) void {
        line("wire", f.out.written());
    }
};

// ---------------------------------------------------------------- text

const TextWidth = struct {
    src: [][]const u8,
    total: usize = 0,

    pub fn init(f: *TextWidth, c: *Ctx) !void {
        f.* = .{ .src = c.lines("wide.txt") };
    }

    pub fn deinit(_: *TextWidth, _: *Ctx) void {}

    pub fn frame(f: *TextWidth, c: *Ctx, _: usize) !void {
        f.total = 0;
        for (f.src) |l| f.total += v.width(l, .unicode);
        std.mem.doNotOptimizeAway(f.total);
        c.count += f.src.len;
    }

    pub fn evidence(f: *TextWidth, _: *Ctx) void {
        emit("value\twidth={d}\n", .{f.total});
    }
};

const Graphemes = struct {
    src: [][]const u8,
    clusters: usize = 0,
    cols: usize = 0,

    pub fn init(f: *Graphemes, c: *Ctx) !void {
        f.* = .{ .src = c.lines("emoji.txt") };
    }

    pub fn deinit(_: *Graphemes, _: *Ctx) void {}

    pub fn frame(f: *Graphemes, c: *Ctx, _: usize) !void {
        f.clusters = 0;
        f.cols = 0;
        for (f.src) |l| {
            var it: v.Graphemes = .init(l);
            while (it.next()) |g| {
                f.clusters += 1;
                f.cols += v.graphemeWidth(g, .unicode);
            }
        }
        std.mem.doNotOptimizeAway(f.cols);
        c.count += f.clusters;
    }

    pub fn evidence(f: *Graphemes, _: *Ctx) void {
        emit("value\tclusters={d}\n", .{f.clusters});
        emit("info\tcolumns={d}\n", .{f.cols});
    }
};

const WidthModels = struct {
    src: [][]const u8,
    disagree: usize = 0,
    parts: usize = 0,
    combining: usize = 0,

    pub fn init(f: *WidthModels, c: *Ctx) !void {
        f.* = .{ .src = c.lines("emoji.txt") };
    }

    pub fn deinit(_: *WidthModels, _: *Ctx) void {}

    pub fn frame(f: *WidthModels, c: *Ctx, _: usize) !void {
        f.disagree = 0;
        f.parts = 0;
        f.combining = 0;
        for (f.src) |l| {
            var it: v.Graphemes = .init(l);
            while (it.next()) |g| {
                if (v.disagrees(g)) f.disagree += 1;
                if (v.combinesOnly(g)) f.combining += 1;
                var p: v.Parts = .init(g);
                while (p.next()) |_| f.parts += 1;
            }
        }
        std.mem.doNotOptimizeAway(f.parts);
        c.count += f.parts;
    }

    pub fn evidence(f: *WidthModels, _: *Ctx) void {
        emit("value\tdisagree={d} combining={d} parts={d}\n", .{ f.disagree, f.combining, f.parts });
    }
};

const TextWrap = struct {
    text: []const u8,
    rows: []v.Row,
    n: usize = 0,

    pub fn init(f: *TextWrap, c: *Ctx) !void {
        const text = c.file("prose.txt");
        f.* = .{ .text = text, .rows = c.fixture.alloc(v.Row, text.len + 1) catch @panic("oom") };
    }

    pub fn deinit(_: *TextWrap, _: *Ctx) void {}

    pub fn frame(f: *TextWrap, c: *Ctx, _: usize) !void {
        f.n = v.wrap(f.text, c.cols, .word, .unicode, f.rows);
        std.mem.doNotOptimizeAway(f.rows[0..f.n]);
        c.count += f.n;
    }

    pub fn evidence(f: *TextWrap, c: *Ctx) void {
        emit("value\trows={d}\n", .{f.n});
        var out: std.ArrayList(u8) = .empty;
        for (f.rows[0..f.n]) |row| {
            out.appendSlice(c.fixture, f.text[row.start..row.end]) catch @panic("oom");
            out.append(c.fixture, '\n') catch @panic("oom");
        }
        line("text", out.items);
    }
};

fn TextFit(comptime end: bool) type {
    return struct {
        const Self = @This();

        src: [][]const u8,
        /// Which of the two the frame calls, read at run time, as one function
        /// that takes it would: the compiler inlines `fitEnd` into the loop
        /// less well when the loop is made for it alone.
        from_end: bool,
        kept: usize = 0,

        pub fn init(f: *Self, c: *Ctx) !void {
            f.* = .{ .src = c.lines("wide.txt"), .from_end = end };
        }

        pub fn deinit(_: *Self, _: *Ctx) void {}

        pub fn frame(f: *Self, c: *Ctx, _: usize) !void {
            f.kept = 0;
            for (f.src, 0..) |l, i| {
                const cols: u16 = @intCast(@max(4, (c.cols * (i % 7 + 3)) / 10));
                if (f.from_end) {
                    f.kept += v.fitEnd(l, cols, "…", .unicode).len;
                } else f.kept += v.fit(l, cols, "…", .unicode).len;
            }
            std.mem.doNotOptimizeAway(f.kept);
            c.count += f.src.len;
        }

        pub fn evidence(f: *Self, _: *Ctx) void {
            emit("value\tkept={d}\n", .{f.kept});
        }
    };
}

// ---------------------------------------------------------------- layout

const outer_constraints = [_]w.Constraint{ .{ .fixed = 3 }, .{ .percent = 20 }, .{ .min = 5 }, .{ .max = 10 }, .{ .fill = 1 }, .{ .fill = 2 } };
const inner_constraints = [_]w.Constraint{ .{ .fixed = 12 }, .{ .percent = 25 }, .{ .min = 8 }, .{ .max = 30 }, .{ .fill = 1 } };

const LayoutSplit = struct {
    outer: [outer_constraints.len]v.Rect,
    inner: [inner_constraints.len]v.Rect,
    area: v.Rect,
    report: std.ArrayList(u8),

    pub fn init(f: *LayoutSplit, c: *Ctx) !void {
        f.area = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
        f.report = .empty;
    }

    pub fn deinit(f: *LayoutSplit, c: *Ctx) void {
        f.report.deinit(c.gpa);
    }

    pub fn frame(f: *LayoutSplit, c: *Ctx, n: usize) !void {
        var l = w.Layout.vertical(&outer_constraints);
        l.spacing = 1;
        const rows = l.split(f.area, &f.outer);
        for (rows) |row| {
            var h = w.Layout.horizontal(&inner_constraints);
            h.spacing = 1;
            const cells = h.split(row, &f.inner);
            std.mem.doNotOptimizeAway(cells);
            c.count += cells.len;
            if (c.check and n == 0) for (cells) |r| {
                f.report.print(c.gpa, "{d},{d},{d},{d};", .{ r.col, r.row, r.cols, r.rows }) catch @panic("oom");
            };
        }
        if (c.check and n == 0) {
            for (rows) |r| f.report.print(c.gpa, "R{d},{d},{d},{d};", .{ r.col, r.row, r.cols, r.rows }) catch @panic("oom");
        }
    }

    pub fn evidence(f: *LayoutSplit, _: *Ctx) void {
        emit("rects\t{s}\n", .{f.report.items});
    }
};

const LayoutRepeat = struct {
    out: []v.Rect,
    got: []v.Rect = &.{},

    pub fn init(f: *LayoutRepeat, c: *Ctx) !void {
        f.* = .{ .out = c.fixture.alloc(v.Rect, @as(usize, c.cols) * c.rows) catch @panic("oom") };
    }

    pub fn deinit(_: *LayoutRepeat, _: *Ctx) void {}

    pub fn frame(f: *LayoutRepeat, c: *Ctx, _: usize) !void {
        f.got = w.Layout.repeat(.horizontal, .{ .col = 0, .row = 0, .cols = 6, .rows = 3 }, 1, f.out);
        std.mem.doNotOptimizeAway(f.got);
        c.count += f.got.len;
    }

    pub fn evidence(f: *LayoutRepeat, _: *Ctx) void {
        emit("value\ttiles={d}\n", .{f.got.len});
    }
};

// ---------------------------------------------------------------- widgets

fn child(win: v.Window, r: v.Rect) v.Window {
    return win.child(.{ .col = r.col, .row = r.row, .cols = r.cols, .rows = r.rows });
}

/// A widget drawn into a window on every frame. What it draws from is built
/// before the clock, by `prepareWidgets`.
fn Widget(comptime task: []const u8, comptime draw: fn (*Ctx, v.Window, usize) void) type {
    return struct {
        const Self = @This();

        s: v.Screen,
        win: v.Window,

        pub fn init(f: *Self, c: *Ctx) !void {
            prepareWidgets(c, task);
            f.s = c.screen();
            f.win = f.s.window();
        }

        pub fn deinit(f: *Self, _: *Ctx) void {
            f.s.deinit();
        }

        pub fn frame(f: *Self, c: *Ctx, n: usize) !void {
            draw(c, f.win, n);
            c.count += 1;
        }

        pub fn evidence(f: *Self, c: *Ctx) void {
            dumpGrid(c.gpa, &f.s);
        }
    };
}

const State = struct {
    var items: []w.Item = &.{};
    var item_text: [][]u8 = &.{};
    var table_rows: []w.Table.Row = &.{};
    var prose: []const u8 = "";
    var series: []u64 = &.{};
    var bars: []w.Bar = &.{};
    var wave: [][2]f64 = &.{};
    var scatter: [][2]f64 = &.{};
    var pixels: []u8 = &.{};
    var document: w.Markdown.Document = undefined;
    var tree_nodes: []w.Tree.Node = undefined;
    var tree_state: w.Tree.State = undefined;
};

/// The shape of the file tree the `tree` workload draws, fixed so another
/// program can draw the same tree: groups of ten, a folder (open), a folder
/// (open in even groups) of four files, a folder (open) of three files.
const tree_depths = [_]u16{ 0, 1, 2, 2, 2, 2, 1, 2, 2, 2 };
fn treeOpen(i: usize) ?bool {
    return switch (i % 10) {
        0, 6 => true,
        1 => (i / 10) % 2 == 0,
        else => null,
    };
}

fn tree(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Tree{
        .nodes = State.tree_nodes,
        .guides = null,
        .symbols = .{ .open = "\u{25bc} ", .closed = "\u{25b6} ", .leaf = "  " },
    }).draw(win, &State.tree_state));
}

fn markdownTableDraw(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Markdown{ .document = &State.document, .theme = .{
        .strong = .{ .bold = true },
        .inline_code = .{ .reverse = true },
        .table_header = .{ .bold = true },
    } }).draw(win));
}

fn blocks(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y + 6 <= win.rows()) : (y += 6) {
        var x: u16 = 0;
        while (x + 20 <= win.cols()) : (x += 20) {
            _ = must((w.Block{ .borders = .all, .title = .{ .text = "title" }, .padding = .horizontal(1) }).draw(win.child(.{ .col = x, .row = y, .cols = 20, .rows = 6 })));
        }
    }
}

fn paragraph(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Paragraph{ .lines = &.{.{ .text = State.prose }}, .wrap = .word }).draw(win));
}

fn markdownDraw(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Markdown{ .document = &State.document, .theme = .{
        .heading = @splat(.{ .bold = true }),
        .strong = .{ .bold = true },
        .emphasis = .{ .italic = true },
        .code = .{ .dim = true },
        .inline_code = .{ .reverse = true },
        .link = .{ .underline = .single },
        .quote = .{ .dim = true },
    } }).draw(win));
}

fn list(c: *Ctx, win: v.Window, _: usize) void {
    var state: w.List.State = .{ .selected = State.items.len / 2 };
    _ = c;
    must((w.List{ .items = State.items, .marker = "> ", .blank_marker = "  " }).draw(win, &state));
}

fn table(_: *Ctx, win: v.Window, _: usize) void {
    var state: w.Table.State = .{ .selected = State.table_rows.len / 2 };
    must((w.Table{
        .header = .{ .cells = &.{ "id", "name", "value", "state" } },
        .rows = State.table_rows,
        .widths = &.{ .{ .fixed = 8 }, .{ .fill = 1 }, .{ .fixed = 7 }, .{ .percent = 20 } },
        .marker = "> ",
    }).draw(win, &state));
}

const tab_titles = [_][]const u8{ "tab0", "tab1", "tab2", "tab3", "tab4", "tab5", "tab6", "tab7", "tab8", "tab9", "tab10", "tab11" };
fn tabs(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y < win.rows()) : (y += 1) {
        must((w.Tabs{ .titles = &tab_titles, .selected = 5 }).draw(win.child(.{ .row = y, .rows = 1 })));
    }
}

fn gauge(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Gauge{ .ratio = 0.6180339887, .label = "61.8%" }).draw(win));
}

fn lineGauge(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y < win.rows()) : (y += 1) {
        const ratio = @as(f64, @floatFromInt(y + 1)) / @as(f64, @floatFromInt(win.rows()));
        must((w.LineGauge{ .ratio = ratio, .label = "disk" }).draw(win.child(.{ .row = y, .rows = 1 })));
    }
}

fn sparkline(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Sparkline{ .data = State.series }).draw(win));
}

fn barchart(_: *Ctx, win: v.Window, _: usize) void {
    must((w.BarChart{ .bars = State.bars, .bar_width = 3, .bar_gap = 1 }).draw(win));
}

fn chart(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Chart{
        .datasets = &.{
            .{ .name = "wave", .points = State.wave },
            .{ .name = "dots", .points = State.scatter, .graph = .scatter, .marker = .dot },
        },
        .x = .{ .bounds = .{ 0, 100 }, .labels = &.{ "0", "50", "100" }, .title = "x" },
        .y = .{ .bounds = .{ -1, 1 }, .labels = &.{ "-1", "0", "1" }, .title = "y" },
    }).draw(win));
}

fn scrollbar(_: *Ctx, win: v.Window, n: usize) void {
    const content: usize = @as(usize, win.rows()) * 10;
    must((w.Scrollbar{}).draw(win.child(.{ .col = win.cols() - 1, .cols = 1 }), .{ .content = content, .viewport = win.rows(), .position = (n * 7) % content }));
    must((w.Scrollbar{ .direction = .horizontal }).draw(win.child(.{ .row = win.rows() - 1, .rows = 1, .cols = win.cols() - 1 }), .{ .content = content, .viewport = win.cols(), .position = (n * 7) % content }));
}

fn canvas(_: *Ctx, win: v.Window, _: usize) void {
    const p = (w.Canvas{ .x_bounds = .{ 0, 100 }, .y_bounds = .{ 0, 100 }, .marker = .braille }).painter(win);
    for (0..32) |i| {
        const a = @as(f64, @floatFromInt(i)) * std.math.pi / 16;
        must(p.line(50, 50, 50 + 45 * @cos(a), 50 + 45 * @sin(a), .{}));
    }
    for (0..8) |i| {
        const d: f64 = @floatFromInt(i * 5);
        must(p.rect(5 + d, 5 + d, 90 - 2 * d, 90 - 2 * d, .{}));
    }
    must(p.polyline(State.wave, .{}));
    for (State.scatter) |pt| must(p.point(pt[0], (pt[1] + 1) * 50, .{}));
}

fn calendar(_: *Ctx, win: v.Window, _: usize) void {
    var month: u8 = 1;
    var year: i32 = 2026;
    var y: u16 = 0;
    while (y + 8 <= win.rows()) : (y += 9) {
        var x: u16 = 0;
        while (x + 20 <= win.cols()) : (x += 22) {
            must((w.Calendar{ .year = year, .month = month, .starts_on = .sunday }).draw(win.child(.{ .col = x, .row = y, .cols = 20, .rows = 8 })));
            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
        }
    }
}

fn textInput(_: *Ctx, win: v.Window, _: usize) void {
    var state: w.TextInput.State = .{};
    must((w.TextInput{ .text = State.prose, .cursor = State.prose.len, .show_cursor = false }).draw(win, &state));
}

const key_list = [_]w.Keys.Key{
    .{ .key = "q", .label = "quit" },   .{ .key = "j", .label = "down" }, .{ .key = "k", .label = "up" },
    .{ .key = "/", .label = "search" }, .{ .key = "n", .label = "next" }, .{ .key = "?", .label = "help" },
};
fn keys(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y < win.rows()) : (y += 1) must((w.Keys{ .keys = &key_list }).draw(win.child(.{ .row = y, .rows = 1 })));
}

fn rule(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y < win.rows()) : (y += 1) must((w.Rule{}).draw(win.child(.{ .row = y, .rows = 1 })));
}

fn edges(_: *Ctx, win: v.Window, _: usize) void {
    var y: u16 = 0;
    while (y < win.rows()) : (y += 1) must((w.Edges{
        .left = &.{ .{ .text = "left side" }, .{ .text = " status", .style = .{ .bold = true } } },
        .right = &.{.{ .text = "right side" }},
    }).draw(win.child(.{ .row = y, .rows = 1 })));
}

fn sextants(_: *Ctx, win: v.Window, _: usize) void {
    must((w.Sextants{ .pixels = State.pixels, .width = @as(usize, win.cols()) * 2, .height = @as(usize, win.rows()) * 3 }).draw(win));
}

fn prepareWidgets(c: *Ctx, task: []const u8) void {
    const gpa = c.fixture;
    const n_items = @as(usize, c.rows) * 8;
    if (std.mem.eql(u8, task, "list")) {
        State.items = gpa.alloc(w.Item, n_items) catch @panic("oom");
        for (State.items, 0..) |*it, i| it.* = .{ .text = gpa.print("item {d:0>5} {s}", .{ i, words[i % words.len] }) catch @panic("oom") };
    }
    if (std.mem.eql(u8, task, "table")) {
        State.table_rows = gpa.alloc(w.Table.Row, n_items) catch @panic("oom");
        for (State.table_rows, 0..) |*row, i| {
            const cells = gpa.alloc([]const u8, 4) catch @panic("oom");
            cells[0] = gpa.print("r{d}", .{i}) catch @panic("oom");
            cells[1] = gpa.print("name-{d}", .{i % 97}) catch @panic("oom");
            cells[2] = gpa.print("{d}", .{(i * 7919) % 100000}) catch @panic("oom");
            cells[3] = gpa.print("state{d}", .{i % 5}) catch @panic("oom");
            row.* = .{ .cells = cells };
        }
    }
    if (std.mem.eql(u8, task, "paragraph") or std.mem.eql(u8, task, "text_input")) State.prose = c.file("prose.txt");
    if (std.mem.eql(u8, task, "sparkline")) {
        State.series = gpa.alloc(u64, @as(usize, c.cols) * 2) catch @panic("oom");
        for (State.series, 0..) |*x, i| x.* = (i * 37) % 101;
    }
    if (std.mem.eql(u8, task, "barchart")) {
        State.bars = gpa.alloc(w.Bar, c.cols / 4) catch @panic("oom");
        for (State.bars, 0..) |*b, i| b.* = .{ .value = (i * 37) % 101, .label = gpa.print("b{d}", .{i % 100}) catch @panic("oom") };
    }
    if (std.mem.eql(u8, task, "chart") or std.mem.eql(u8, task, "canvas")) {
        State.wave = gpa.alloc([2]f64, @as(usize, c.cols) * 2) catch @panic("oom");
        for (State.wave, 0..) |*p, i| {
            const x = @as(f64, @floatFromInt(i)) * 100 / @as(f64, @floatFromInt(State.wave.len - 1));
            p.* = .{ x, @sin(x / 8) };
        }
        if (std.mem.eql(u8, task, "canvas")) for (State.wave) |*p| {
            p[1] = (p[1] + 1) * 50;
        };
        State.scatter = gpa.alloc([2]f64, 256) catch @panic("oom");
        for (State.scatter, 0..) |*p, i| p.* = .{ @as(f64, @floatFromInt((i * 37) % 101)), @as(f64, @floatFromInt((i * 53) % 201)) / 100 - 1 };
    }
    if (std.mem.eql(u8, task, "sextants")) {
        const pw = @as(usize, c.cols) * 2;
        const ph = @as(usize, c.rows) * 3;
        State.pixels = gpa.alloc(u8, pw * ph * 4) catch @panic("oom");
        for (0..ph) |y| for (0..pw) |x| {
            const dx = (@as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(pw)) / 2) / (@as(f64, @floatFromInt(pw)) / 2);
            const dy = (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(ph)) / 2) / (@as(f64, @floatFromInt(ph)) / 2);
            const d = dx * dx + dy * dy;
            const lit: u8 = if (d < 1 and ((x / 3 + y / 2) % 3 != 0)) 255 else 0;
            State.pixels[(y * pw + x) * 4 ..][0..4].* = .{ lit, lit, lit, 255 };
        };
    }
    {
        if (std.mem.eql(u8, task, "markdown_draw")) State.document = must(w.Markdown.Document.init(gpa, c.file("doc.md")));
        if (std.mem.eql(u8, task, "markdown_table_draw")) State.document = must(w.Markdown.Document.init(gpa, c.file("tables.md")));
        if (std.mem.eql(u8, task, "tree")) {
            State.tree_nodes = gpa.alloc(w.Tree.Node, n_items) catch @panic("oom");
            for (State.tree_nodes, 0..) |*node, i| node.* = .{
                .depth = tree_depths[i % 10],
                .open = treeOpen(i),
                .text = gpa.print("node {d:0>5} {s}", .{ i, words[i % words.len] }) catch @panic("oom"),
            };
            const tree_value: w.Tree = .{ .nodes = State.tree_nodes };
            // The first node shown at or after the middle is selected.
            var selected = tree_value.shownAncestor(n_items / 2);
            if (selected < n_items / 2) selected = tree_value.nextShown(selected) orelse selected;
            State.tree_state = .{ .selected = selected };
        }
    }
}

const MarkdownParse = struct {
    source: []const u8,
    blocks_n: usize = 0,

    pub fn init(f: *MarkdownParse, c: *Ctx) !void {
        f.* = .{ .source = c.file("doc.md") };
    }

    pub fn deinit(_: *MarkdownParse, _: *Ctx) void {}

    pub fn frame(f: *MarkdownParse, c: *Ctx, _: usize) !void {
        var doc = must(w.Markdown.Document.init(c.gpa, f.source));
        f.blocks_n = doc.blocks().len;
        c.count += doc.spans().len;
        doc.deinit();
    }

    pub fn evidence(f: *MarkdownParse, _: *Ctx) void {
        emit("value\tblocks={d}\n", .{f.blocks_n});
    }
};

const MarkdownTableParse = struct {
    source: []const u8,
    tables: usize = 0,
    cells: usize = 0,
    tasks: usize = 0,

    pub fn init(f: *MarkdownTableParse, c: *Ctx) !void {
        f.* = .{ .source = c.file("tables.md") };
    }

    pub fn deinit(_: *MarkdownTableParse, _: *Ctx) void {}

    pub fn frame(f: *MarkdownTableParse, c: *Ctx, _: usize) !void {
        var doc = must(w.Markdown.Document.init(c.gpa, f.source));
        f.tables = 0;
        f.cells = 0;
        f.tasks = 0;
        for (doc.blocks()) |b| {
            if (b.table) |t| {
                f.tables += 1;
                f.cells += t.rows * t.columns;
            }
            if (b.task != null) f.tasks += 1;
        }
        c.count += doc.spans().len;
        doc.deinit();
    }

    pub fn evidence(f: *MarkdownTableParse, _: *Ctx) void {
        emit("value\ttables={d} cells={d} tasks={d}\n", .{ f.tables, f.cells, f.tasks });
    }
};

/// Two log lines a frame, printed above an inline view a quarter of the
/// terminal tall that is redrawn under them: the bytes of each frame are the
/// evidence, replayed by the independent decoder.
const PrintAbove = struct {
    view: v.Screen,
    r: v.Renderer,
    lines: v.Screen,
    out: std.Io.Writer.Allocating,

    pub fn init(f: *PrintAbove, c: *Ctx) !void {
        const gpa = c.gpa;
        const view_rows: u16 = @max(2, c.rows / 4);
        const size: v.Size = .{ .cols = c.cols, .rows = view_rows };
        f.view = must(v.Screen.init(gpa, size));
        f.view.method = .unicode;
        f.r = must(v.Renderer.init(gpa, size));
        f.lines = must(v.Screen.init(gpa, .{ .cols = c.cols, .rows = 2 }));
        f.lines.method = .unicode;
        f.out = .init(gpa);
        must(f.r.enter(&f.out.writer, caps, .@"inline", .{}));
        drawView(&f.view, 0);
        _ = must(f.r.draw(&f.out.writer, &f.view, null, caps));
        if (c.check) line("wire", f.out.written());
    }

    pub fn deinit(f: *PrintAbove, _: *Ctx) void {
        f.out.deinit();
        f.lines.deinit();
        f.r.deinit();
        f.view.deinit();
    }

    pub fn frame(f: *PrintAbove, c: *Ctx, n: usize) !void {
        f.out.clearRetainingCapacity();
        f.lines.clear();
        var buf: [64]u8 = undefined;
        for (0..2) |k| {
            const text = std.mem.print(&buf, "log {d:0>6} {s} {s}", .{ 2 * n + k, words[(2 * n + k) % words.len], words[(2 * n + k + 3) % words.len] }) catch unreachable; // unreachable: two corpus words fit
            _ = must(f.lines.window().printSegment(.{ .text = text }, .{ .row = @intCast(k), .wrap = .none }));
        }
        drawView(&f.view, n + 1);
        const stats = must(f.r.printAbove(&f.out.writer, &f.lines, &f.view, null, caps));
        c.bytes += stats.bytes;
        c.count += 2;
        if (c.check) line("wire", f.out.written());
    }

    pub fn evidence(_: *PrintAbove, _: *Ctx) void {}
};

/// The live view: a title row and bars of `#` under it.
fn drawView(view: *v.Screen, n: usize) void {
    view.clear();
    const win = view.window();
    var buf: [32]u8 = undefined;
    // unreachable: a frame number fits
    _ = must(win.printSegment(.{ .text = std.mem.print(&buf, "working {d:0>6}", .{n}) catch unreachable, .style = .{ .bold = true } }, .{ .wrap = .none }));
    const bar: [512]u8 = @splat('#');
    var y: u16 = 1;
    while (y < win.rows()) : (y += 1) {
        const filled = (n + y) % (@as(usize, win.cols()) + 1);
        _ = must(win.printSegment(.{ .text = bar[0..filled] }, .{ .row = y, .wrap = .none }));
    }
}

/// Typing, word and character deletes, word motions, then every edit undone
/// and redone, on the first `cols * 2` bytes of the prose.
const TextEdit = struct {
    typed: []const u8,
    final: u64 = 0,
    final_len: usize = 0,
    undone_len: usize = 0,

    pub fn init(f: *TextEdit, c: *Ctx) !void {
        const prose = c.file("prose.txt");
        f.* = .{ .typed = prose[0..@min(prose.len, @as(usize, c.cols) * 2)] };
    }

    pub fn deinit(_: *TextEdit, _: *Ctx) void {}

    pub fn frame(f: *TextEdit, c: *Ctx, _: usize) !void {
        var b: w.TextInput.Buffer = .init(c.gpa);
        for (f.typed) |ch| must(b.insert(&.{ch}));
        for (0..4) |_| must(b.delete(.word_left));
        for (0..3) |_| b.move(.word_left, false);
        for (0..5) |_| must(b.delete(.right));
        b.move(.end, false);
        for (0..3) |_| must(b.delete(.left));
        while (must(b.undo())) {}
        f.undone_len = b.text().len;
        while (must(b.redo())) {}
        f.final = std.hash.Fnv1a_64.hash(b.text());
        f.final_len = b.text().len;
        c.count += f.typed.len;
        b.deinit();
    }

    pub fn evidence(f: *TextEdit, _: *Ctx) void {
        emit("value\tfinal={d}:{x} undone={d}\n", .{ f.final_len, f.final, f.undone_len });
    }
};

// ---------------------------------------------------------------- input, emulator, pictures

const InputEvents = struct {
    file: std.Io.File,
    tty: v.Tty,
    parser_buffer: []u8,
    read_buffer: []u8,
    kinds: [32]usize = @splat(0),
    events: usize = 0,

    pub fn init(f: *InputEvents, c: *Ctx) !void {
        const path = c.fixture.print("{s}/{d}x{d}/input.bin", .{ c.corpus, c.cols, c.rows }) catch @panic("oom");
        f.file = std.Io.Dir.cwd().openFile(c.io, path, .{}) catch @panic("input corpus");
        f.tty = v.Tty.adopt(f.file);
        f.parser_buffer = c.fixture.alloc(u8, 1 << 16) catch @panic("oom");
        f.read_buffer = c.fixture.alloc(u8, 1 << 20) catch @panic("oom");
        f.kinds = @splat(0);
        f.events = 0;
    }

    pub fn deinit(f: *InputEvents, c: *Ctx) void {
        f.file.close(c.io);
    }

    pub fn frame(f: *InputEvents, c: *Ctx, _: usize) !void {
        // Back to the start of the input, as lseek does: the descriptor's own
        // offset, which is what the Tty reads from.
        c.io.vtable.fileSeekTo(c.io.userdata, f.file, 0) catch @panic("rewind");
        var in = must(v.Input.init(&f.tty, .{ .parser_buffer = f.parser_buffer, .read_buffer = f.read_buffer, .escape = .fromMilliseconds(50) }));
        f.events = 0;
        f.kinds = @splat(0);
        while (true) {
            const e = in.next(c.io) catch |err| switch (err) {
                error.EndOfStream => break,
                else => std.debug.panic("{s}", .{@errorName(err)}),
            };
            f.events += 1;
            f.kinds[@backingInt(std.meta.activeTag(e)) % f.kinds.len] += 1;
        }
        c.count += f.events;
    }

    pub fn evidence(f: *InputEvents, _: *Ctx) void {
        emit("value\tevents={d}", .{f.events});
        for (f.kinds) |k| emit(" {d}", .{k});
        emit("\n", .{});
    }
};

const TermFeed = struct {
    s: v.Screen,
    r: v.Renderer,
    drawn: std.Io.Writer.Allocating,
    term: v.Term,
    dump: std.Io.Writer.Allocating,

    pub fn init(f: *TermFeed, c: *Ctx) !void {
        f.s = c.screen();
        f.r = must(v.Renderer.init(c.gpa, c.size()));
        f.drawn = .init(c.gpa);
        const src = c.lines("wide.txt");
        for (0..c.rows) |y| _ = must(f.s.window().printSegment(.{ .text = src[y % src.len], .style = .{ .fg = rgb(y, 0), .bold = y % 2 == 0 } }, .{ .row = @intCast(y), .wrap = .none }));
        _ = must(f.r.draw(&f.drawn.writer, &f.s, null, caps));
        f.term = must(v.Term.init(c.gpa, c.size()));
        f.term.setMethod(.unicode);
        f.dump = .init(c.gpa);
    }

    pub fn deinit(f: *TermFeed, _: *Ctx) void {
        f.dump.deinit();
        f.term.deinit();
        f.drawn.deinit();
        f.r.deinit();
        f.s.deinit();
    }

    pub fn frame(f: *TermFeed, c: *Ctx, _: usize) !void {
        must(f.term.feed("\x1b[H\x1b[2J"));
        must(f.term.feed(f.drawn.written()));
        f.dump.clearRetainingCapacity();
        must(v.dumpScreen(f.term.screen(), &f.dump.writer, .{}));
        c.bytes += f.drawn.written().len;
        c.count += 1;
    }

    pub fn evidence(f: *TermFeed, c: *Ctx) void {
        dumpGrid(c.gpa, &f.s);
        line("text", f.dump.written());
        if (v.firstDifference(&f.s, f.term.screen()) != null) @panic("emulator differs from the drawn screen");
    }
};

const PictureTransmit = struct {
    layers: v.Layers,
    out: std.Io.Writer.Allocating,
    pixels: []u8,
    pw: u32,
    ph: u32,

    pub fn init(f: *PictureTransmit, c: *Ctx) !void {
        f.layers = .init(c.gpa);
        f.out = .init(c.gpa);
        f.pw = @as(u32, c.cols) * 4;
        f.ph = @as(u32, c.rows) * 8;
        f.pixels = c.fixture.alloc(u8, @as(usize, f.pw) * f.ph * 4) catch @panic("oom");
        for (f.pixels, 0..) |*p, i| p.* = @truncate(i *% 31 +% i / 4096);
        must(f.out.ensureTotalCapacity(f.pixels.len * 2 + 8192));
    }

    pub fn deinit(f: *PictureTransmit, _: *Ctx) void {
        f.out.deinit();
        f.layers.deinit();
    }

    pub fn frame(f: *PictureTransmit, c: *Ctx, _: usize) !void {
        f.out.clearRetainingCapacity();
        const n = must(f.layers.transmit(&f.out.writer, 7, f.pixels, .{ .width = f.pw, .height = f.ph, .compress = false }));
        c.bytes += f.out.written().len;
        c.count += n;
    }

    pub fn evidence(f: *PictureTransmit, _: *Ctx) void {
        const digest = digestOf(f.out.written());
        emit("value\tbytes={d} sha256={x}\n", .{ f.out.written().len, digest });
    }
};

const Protocol = enum { kitty, sixel, iterm, cells };

fn PictureFrame(comptime protocol: Protocol) type {
    return struct {
        const Self = @This();

        screen: v.Screen,
        renderer: v.Renderer,
        layers: v.Layers,
        out: std.Io.Writer.Allocating,
        pixels: []u8,
        width: u32,
        height: u32,
        policy: v.Caps,

        pub fn init(f: *Self, c: *Ctx) !void {
            f.screen = c.screen();
            f.renderer = must(v.Renderer.init(c.gpa, c.size()));
            f.layers = .init(c.gpa);
            f.layers.configureSize(.{ .cells = c.size(), .cell = .{ .width = 8, .height = 16 } });
            f.out = .init(c.gpa);
            f.width = (@as(u32, c.cols) - 1) * 8;
            f.height = (@as(u32, c.rows) - 1) * 16;
            f.pixels = c.fixture.alloc(u8, @as(usize, f.width) * f.height * 4) catch @panic("oom");
            for (0..@as(usize, f.width) * f.height) |i| @memcpy(f.pixels[i * 4 ..][0..4], &[_]u8{ 255, 0, 0, 255 });
            f.policy = .{ .width_method = .unicode, .truecolor = true, .picture_protocol = switch (protocol) {
                .kitty => .kitty,
                .sixel => .sixel,
                .iterm => .iterm,
                .cells => .cells,
            } };
            switch (protocol) {
                .kitty => _ = must(f.layers.transmit(&f.out.writer, 7, f.pixels, .{ .width = f.width, .height = f.height, .compress = false })),
                .sixel => must(f.layers.storeSixel(7, .{ .width = f.width, .height = f.height, .pixels = .{ .rgba = f.pixels }, .palette = &.{.{ .r = 255, .g = 0, .b = 0 }} })),
                .iterm => must(f.layers.storeIterm(7, c.file("picture.png"), 0)),
                .cells => {},
            }
            if (c.check and protocol == .kitty) line("setup", f.out.written());
            must(f.out.ensureTotalCapacity(f.pixels.len * 2 + 8192));
            _ = must(f.renderer.draw(&f.out.writer, &f.screen, null, f.policy));
        }

        pub fn deinit(f: *Self, _: *Ctx) void {
            f.out.deinit();
            f.layers.deinit();
            f.renderer.deinit();
            f.screen.deinit();
        }

        pub fn frame(f: *Self, c: *Ctx, n: usize) !void {
            f.out.clearRetainingCapacity();
            const col: u16 = @intCast(n % 2);
            if (protocol == .cells) {
                f.screen.clear();
                must((w.Sextants{ .width = f.width, .height = f.height, .pixels = f.pixels }).draw(f.screen.window().sub(.{ .col = col, .row = 0, .cols = c.cols - 1, .rows = c.rows - 1 })));
            } else must(f.layers.declare(.{ .image = 7, .rect = .{ .col = col, .row = 0, .cols = c.cols - 1, .rows = c.rows - 1 } }));
            const stats = must(f.renderer.draw(&f.out.writer, &f.screen, if (protocol == .cells) null else &f.layers, f.policy));
            c.count += stats.placements;
            c.bytes += stats.bytes;
            if (c.check) line("wire", f.out.written());
        }

        pub fn evidence(f: *Self, c: *Ctx) void {
            emit("value\twidth={d} height={d} frames={d}\n", .{ f.width, f.height, c.frames });
        }
    };
}

const PictureReplace = struct {
    s: v.Screen,
    r: v.Renderer,
    layers: v.Layers,
    out: std.Io.Writer.Allocating,
    ids: v.ImageIds,
    replacement: v.Replacement,
    pixels: [16 * 16 * 4]u8,
    swaps: usize,

    const pic: v.Caps = .{ .width_method = .unicode, .truecolor = true, .kitty_graphics = true };

    pub fn init(f: *PictureReplace, c: *Ctx) !void {
        f.s = c.screen();
        f.r = must(v.Renderer.init(c.gpa, c.size()));
        f.layers = .init(c.gpa);
        f.out = .init(c.gpa);
        f.ids = must(v.ImageIds.init(100, 107, 0));
        f.replacement = .{};
        for (0..16 * 16) |i| f.pixels[i * 4 ..][0..4].* = .{ 31, 63, 127, 255 };
        f.swaps = 0;
    }

    pub fn deinit(f: *PictureReplace, _: *Ctx) void {
        f.out.deinit();
        f.layers.deinit();
        f.r.deinit();
        f.s.deinit();
    }

    pub fn frame(f: *PictureReplace, c: *Ctx, n: usize) !void {
        f.out.clearRetainingCapacity();
        // A clock that moves 100 ms a frame, so every grace period runs out.
        const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, @intCast(n)) * 100 * std.time.ns_per_ms };
        if (f.replacement.canSend()) _ = must(f.replacement.send(&f.layers, &f.out.writer, &f.ids, &f.pixels, .{ .width = 16, .height = 16, .compress = false, .now = now }));
        _ = must(f.replacement.declare(&f.layers, .{ .image = 0, .rect = .{ .col = @intCast(n % 2), .row = 0, .cols = 2, .rows = 2 } }, now.addDuration(.fromMilliseconds(60)), .fromMilliseconds(50)));
        _ = must(f.r.draw(&f.out.writer, &f.s, &f.layers, pic));
        if (f.replacement.current() != null) f.swaps += 1;
        c.bytes += f.out.written().len;
        c.count += 1;
    }

    pub fn evidence(f: *PictureReplace, _: *Ctx) void {
        emit("value\tcurrent={d} swaps={d} images={d}\n", .{ f.replacement.current() orelse 0, f.swaps, f.layers.images().len });
    }
};

const CanvasRaster = struct {
    surface: w.Canvas.Surface,
    p: Painter,

    const Painter = @TypeOf((w.Canvas{ .x_bounds = .{ 0, 100 }, .y_bounds = .{ 0, 100 } }).raster(undefined));

    pub fn init(f: *CanvasRaster, c: *Ctx) !void {
        f.surface = must(w.Canvas.Surface.init(c.gpa, @as(u32, c.cols) * 8, @as(u32, c.rows) * 16));
        prepareWidgets(c, "canvas");
        f.p = (w.Canvas{ .x_bounds = .{ 0, 100 }, .y_bounds = .{ 0, 100 } }).raster(&f.surface);
    }

    pub fn deinit(f: *CanvasRaster, _: *Ctx) void {
        f.surface.deinit();
    }

    pub fn frame(f: *CanvasRaster, c: *Ctx, _: usize) !void {
        f.surface.clear();
        for (0..32) |i| {
            const a = @as(f64, @floatFromInt(i)) * std.math.pi / 16;
            f.p.line(50, 50, 50 + 45 * @cos(a), 50 + 45 * @sin(a), .{});
        }
        for (0..8) |i| {
            const d: f64 = @floatFromInt(i * 5);
            f.p.rect(5 + d, 5 + d, 90 - 2 * d, 90 - 2 * d, .{});
        }
        f.p.circle(50, 50, 30, .{ .rgba = .{ 255, 200, 0, 255 } });
        f.p.disc(25, 25, 10, .{ .rgba = .{ 0, 200, 255, 255 } });
        f.p.polyline(State.wave, .{});
        c.count += 1;
    }

    pub fn evidence(f: *CanvasRaster, _: *Ctx) void {
        const digest = digestOf(f.surface.pixels());
        emit("value\tsha256={x}\n", .{digest});
    }
};

/// The workloads, in the order a pass runs them.
pub const workloads = .{
    .{ "cell_writes", CellWrites },
    .{ "print_rows", PrintRows("ascii.txt") },
    .{ "wide_print", PrintRows("wide.txt") },
    .{ "wide_repaint", WideRepaint },
    .{ "fill_clear", FillClear },
    .{ "scroll_rows", ScrollRows(false) },
    .{ "scroll_repaint", ScrollRows(true) },
    .{ "resize", ResizeGrid },
    .{ "copy_cells", CopyCells },
    .{ "copy_text", CopyText },
    .{ "links", Links },
    .{ "grapheme_pool", GraphemePool },
    .{ "modes", Modes },
    .{ "text_width", TextWidth },
    .{ "graphemes", Graphemes },
    .{ "width_models", WidthModels },
    .{ "text_wrap", TextWrap },
    .{ "text_fit", TextFit(false) },
    .{ "text_fit_end", TextFit(true) },
    .{ "layout_split", LayoutSplit },
    .{ "layout_repeat", LayoutRepeat },
    .{ "block", Widget("block", blocks) },
    .{ "paragraph", Widget("paragraph", paragraph) },
    .{ "markdown_parse", MarkdownParse },
    .{ "markdown_draw", Widget("markdown_draw", markdownDraw) },
    .{ "markdown_table_parse", MarkdownTableParse },
    .{ "markdown_table_draw", Widget("markdown_table_draw", markdownTableDraw) },
    .{ "tree", Widget("tree", tree) },
    .{ "print_above", PrintAbove },
    .{ "text_edit", TextEdit },
    .{ "list", Widget("list", list) },
    .{ "table", Widget("table", table) },
    .{ "tabs", Widget("tabs", tabs) },
    .{ "gauge", Widget("gauge", gauge) },
    .{ "line_gauge", Widget("line_gauge", lineGauge) },
    .{ "sparkline", Widget("sparkline", sparkline) },
    .{ "barchart", Widget("barchart", barchart) },
    .{ "chart", Widget("chart", chart) },
    .{ "scrollbar", Widget("scrollbar", scrollbar) },
    .{ "canvas", Widget("canvas", canvas) },
    .{ "canvas_raster", CanvasRaster },
    .{ "calendar", Widget("calendar", calendar) },
    .{ "text_input", Widget("text_input", textInput) },
    .{ "keys", Widget("keys", keys) },
    .{ "rule", Widget("rule", rule) },
    .{ "edges", Widget("edges", edges) },
    .{ "sextants", Widget("sextants", sextants) },
    .{ "input_events", InputEvents },
    .{ "term_feed", TermFeed },
    .{ "picture_transmit", PictureTransmit },
    .{ "picture_frame_kitty", PictureFrame(.kitty) },
    .{ "picture_frame_sixel", PictureFrame(.sixel) },
    .{ "picture_frame_iterm", PictureFrame(.iterm) },
    .{ "picture_frame_cells", PictureFrame(.cells) },
    .{ "picture_replace", PictureReplace },
};
