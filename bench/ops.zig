//! Public operation workloads, with prepared fixtures outside shared callbacks.
//! `check` retains the independent evidence protocol; smoke and full measurement
//! emit shakedown JSONL. Text inputs come from VISOR_BENCH_CORPUS.
const std = @import("std");
const v = @import("visor");
const w = @import("visor.widgets");
const workloads = @import("workloads.zig");
const Measurement = @import("measurement.zig");

/// The Io the lines go out through, set once by `run`: unbuffered, so every
/// line a check prints is out before anything that stops the program.
var stdout_io: std.Io = undefined;

fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.mem.print(&buf, fmt, args) catch @panic("report too long");
    raw(s);
}
fn raw(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(stdout_io, s) catch @panic("write failed");
}
fn line(tag: []const u8, bytes: []const u8) void {
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
inline fn must(x: anytype) Payload(@TypeOf(x)) {
    return switch (@typeInfo(@TypeOf(x))) {
        .error_union => x catch |err| std.debug.panic("{s}", .{@errorName(err)}),
        else => x,
    };
}

fn fill(s: *v.Screen, rect: v.Rect, c: v.Cell) void {
    must(s.fill(rect, c));
}

/// Rows as text: each head cell's grapheme, covered columns skipped, rows
/// right-trimmed, joined by newlines. The same canonical form every library
/// prints, so grids compare across implementations.
fn dumpGrid(gpa: std.mem.Allocator, s: *const v.Screen) void {
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

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cols: u16,
    rows: u16,
    iterations: usize,
    check: bool,
    measurement: Measurement,
    corpus: []const u8,
    count: usize = 0,
    bytes: usize = 0,

    fn file(c: *Ctx, name: []const u8) []const u8 {
        const path = c.gpa.print("{s}/{d}x{d}/{s}", .{ c.corpus, c.cols, c.rows, name }) catch @panic("oom");
        defer c.gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch |err| std.debug.panic("corpus {s}: {s}", .{ path, @errorName(err) });
    }
    fn lines(c: *Ctx, name: []const u8) [][]const u8 {
        const data = c.file(name);
        var found: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
        while (it.next()) |l| found.append(c.gpa, l) catch @panic("oom");
        return found.items;
    }
    fn screen(c: *Ctx) v.Screen {
        var s = must(v.Screen.init(c.gpa, .{ .cols = c.cols, .rows = c.rows }));
        s.method = .unicode;
        return s;
    }
    fn size(c: *const Ctx) v.Size {
        return .{ .cols = c.cols, .rows = c.rows };
    }
};

const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
const caps: v.Caps = .{ .width_method = .unicode, .truecolor = true };

fn rgb(i: usize, salt: usize) v.Color {
    return .rgb(@truncate(i *% 13 +% salt *% 17), @truncate(i *% 7 +% 31), @truncate(i *% 3 +% 53));
}

// ---------------------------------------------------------------- the grid

fn cellWrites(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    var prepared = .{ .c = c, .s = &s, .alphabet = &alphabet };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                for (0..context.c.rows) |y| for (0..context.c.cols) |x| {
                    const i = y * context.c.cols + x;
                    must(context.s.*.write(@intCast(x), @intCast(y), context.alphabet.*[(i + n) % context.alphabet.*.len ..][0..1], .{ .fg = rgb(i, n % 2), .bold = (i + n) % 2 == 0 }, .none));
                };
                context.c.count += @as(usize, context.c.cols) * context.c.rows;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
}

fn printRows(c: *Ctx, name: []const u8) void {
    var s = c.screen();
    defer s.deinit();
    const src = c.lines(name);
    const win = s.window();
    var prepared = .{ .c = c, .src = &src, .win = &win };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                for (0..context.c.rows) |y| {
                    const text = context.src.*[(y + n) % context.src.*.len];
                    _ = must(context.win.*.printSegment(.{ .text = text, .style = .{ .fg = rgb(y, n % 2) } }, .{ .row = @intCast(y), .wrap = .none }));
                }
                context.c.count += context.c.rows;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
}

fn widePrintRepaint(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    var r = must(v.Renderer.init(c.gpa, c.size()));
    defer r.deinit();
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    const src = c.lines("wide.txt");
    const win = s.window();
    for (0..c.rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
    must(out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 64 + 8192));
    var prepared = .{ .c = c, .s = &s, .r = &r, .out = &out };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.r.*.repaint();
                context.out.*.clearRetainingCapacity();
                const stats = must(context.r.*.draw(&context.out.*.writer, &context.s.*, null, caps));
                context.c.count += stats.cells;
                context.c.bytes += context.out.*.written().len;
                std.mem.doNotOptimizeAway(context.out.*.written());
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        dumpGrid(c.gpa, &s);
        line("wire", out.written());
    }
}

fn fillClear(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    const all: v.Rect = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
    var prepared = .{ .c = c, .s = &s, .all = &all };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                fill(&context.s.*, context.all.*, .blank(.{ .bg = rgb(n, 1) }));
                context.s.*.clear();
                context.c.count += 2 * @as(usize, context.c.cols) * context.c.rows;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        fill(&s, all, .blank(.{ .bg = rgb(1, 1) }));
        dumpGrid(c.gpa, &s);
    }
}

fn scrollRows(c: *Ctx, render: bool) void {
    var s = c.screen();
    defer s.deinit();
    var r = must(v.Renderer.init(c.gpa, c.size()));
    defer r.deinit();
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    must(out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 64 + 8192));
    const src = c.lines("log.txt");
    const win = s.window();
    for (0..c.rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
    // A terminal profile with scrolling regions: the caller's caps say so.
    const scrolling: v.Caps = .{ .width_method = .unicode, .truecolor = true, .decstbm = true, .su = true, .scroll_detection = true };
    if (render) {
        _ = must(r.draw(&out.writer, &s, null, scrolling));
        if (c.check) line("wire", out.written());
    }
    const all: v.Rect = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
    // The whole frame of a scrolling log is the job: the scroll, the new
    // row and, for scroll_repaint, the draw. Every library is clocked so.
    var prepared = .{ .c = c, .render = &render, .s = &s, .r = &r, .out = &out, .src = &src, .win = &win, .scrolling = &scrolling, .all = &all };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                context.s.*.scroll(context.all.*, 1);
                _ = must(context.win.*.printSegment(.{ .text = context.src.*[(context.c.rows + n) % context.src.*.len] }, .{ .row = context.c.rows - 1, .wrap = .none }));
                context.c.count += 1;
                if (context.render.*) {
                    context.out.*.clearRetainingCapacity();
                    const stats = must(context.r.*.draw(&context.out.*.writer, &context.s.*, null, context.scrolling.*));
                    context.c.bytes += context.out.*.written().len;
                    context.c.count += stats.cells;
                    if (context.c.check) line("wire", context.out.*.written());
                }
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
}

fn resizeGrid(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    const src = c.lines("ascii.txt");
    const win = s.window();
    for (0..c.rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
    const small: v.Size = .{ .cols = c.cols - 3, .rows = c.rows - 2 };
    var prepared = .{ .c = c, .s = &s, .small = &small };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                must(context.s.*.resize(context.small.*));
                must(context.s.*.resize(context.c.size()));
                context.c.count += 2;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
}

fn copyCells(c: *Ctx) void {
    var src_screen = c.screen();
    defer src_screen.deinit();
    var dst = c.screen();
    defer dst.deinit();
    const src = c.lines("wide.txt");
    const win = src_screen.window();
    for (0..c.rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
    var prepared = .{ .c = c, .src_screen = &src_screen, .dst = &dst };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                for (0..context.c.rows) |y| for (0..context.c.cols) |x| {
                    const cell = context.src_screen.*.readCell(@intCast(x), @intCast(y)).?;
                    if (cell.isTail()) continue;
                    must(context.dst.*.copyCell(&context.src_screen.*, @intCast(x), @intCast(y), cell));
                };
                context.c.count += @as(usize, context.c.cols) * context.c.rows;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &dst);
}

fn copyText(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    const src = c.lines("wide.txt");
    const win = s.window();
    for (0..c.rows) |y| _ = must(win.printSegment(.{ .text = src[y % src.len] }, .{ .row = @intCast(y), .wrap = .none }));
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    must(out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 8));
    var prepared = .{ .c = c, .win = &win, .out = &out };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.out.*.clearRetainingCapacity();
                for (0..context.c.rows) |y| {
                    must(context.win.*.copyText(&context.out.*.writer, @intCast(y), 0, context.c.cols));
                    must(context.out.*.writer.writeByte('\n'));
                }
                context.c.bytes += context.out.*.written().len;
                context.c.count += context.c.rows;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) line("text", out.written());
}

fn links(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    var r = must(v.Renderer.init(c.gpa, c.size()));
    defer r.deinit();
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    must(out.ensureTotalCapacity(@as(usize, c.cols) * c.rows * 64 + 8192));
    const src = c.lines("ascii.txt");
    var uri_buf: [64]u8 = undefined;
    const linked: v.Caps = .{ .width_method = .unicode, .truecolor = true, .osc8 = true };
    // Interning and linked writes are frame construction; the measured job
    // is a frame whose every row carries its own OSC 8 target.
    for (0..c.rows) |y| {
        const uri = std.mem.print(&uri_buf, "https://example.com/row/{d}", .{y}) catch unreachable; // unreachable: a row number fits
        const l = must(s.link(uri, ""));
        _ = must(s.window().printSegment(.{ .text = src[y % src.len], .link = l }, .{ .row = @intCast(y), .wrap = .none }));
    }
    var prepared = .{ .c = c, .s = &s, .r = &r, .out = &out, .linked = &linked };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.r.*.repaint();
                context.out.*.clearRetainingCapacity();
                const stats = must(context.r.*.draw(&context.out.*.writer, &context.s.*, null, context.linked.*));
                context.c.count += stats.cells;
                context.c.bytes += context.out.*.written().len;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        dumpGrid(c.gpa, &s);
        line("wire", out.written());
    }
}

fn graphemePool(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    const clusters = c.lines("pool.txt");
    var prepared = .{ .c = c, .s = &s, .clusters = &clusters };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                for (0..context.c.rows) |y| {
                    var x: u16 = 0;
                    var k: usize = 0;
                    while (x + 2 <= context.c.cols) : (x += 2) {
                        const g = context.clusters.*[(n * 7 + y * context.c.cols + k) % context.clusters.*.len];
                        must(context.s.*.write(x, @intCast(y), g, .{}, .none));
                        k += 1;
                    }
                }
                must(context.s.*.compactPool());
                context.c.count += 1;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
}

fn modes(c: *Ctx) void {
    var r = must(v.Renderer.init(c.gpa, c.size()));
    defer r.deinit();
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    must(out.ensureTotalCapacity(4096));
    const wanted: v.Modes = .{ .mouse = .{ .motion = .any }, .focus = true, .paste = true };
    var prepared = .{ .c = c, .r = &r, .out = &out, .wanted = &wanted };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.out.*.clearRetainingCapacity();
                must(context.r.*.enter(&context.out.*.writer, caps, .alt, context.wanted.*));
                must(context.r.*.leave(&context.out.*.writer));
                context.c.bytes += context.out.*.written().len;
                context.c.count += 1;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) line("wire", out.written());
}

// ---------------------------------------------------------------- text

fn textWidth(c: *Ctx) void {
    const src = c.lines("wide.txt");
    var total: usize = 0;
    var prepared = .{ .c = c, .src = &src, .total = &total };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.total.* = 0;
                for (context.src.*) |l| context.total.* += v.width(l, .unicode);
                std.mem.doNotOptimizeAway(context.total.*);
                context.c.count += context.src.*.len;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("value\twidth={d}\n", .{total});
}

fn graphemes(c: *Ctx) void {
    const src = c.lines("emoji.txt");
    var clusters: usize = 0;
    var cols: usize = 0;
    var prepared = .{ .c = c, .src = &src, .clusters = &clusters, .cols = &cols };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.clusters.* = 0;
                context.cols.* = 0;
                for (context.src.*) |l| {
                    var it: v.Graphemes = .init(l);
                    while (it.next()) |g| {
                        context.clusters.* += 1;
                        context.cols.* += v.graphemeWidth(g, .unicode);
                    }
                }
                std.mem.doNotOptimizeAway(context.cols.*);
                context.c.count += context.clusters.*;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("value\tclusters={d}\n", .{clusters});
    if (c.check) emit("info\tcolumns={d}\n", .{cols});
}

fn widthModels(c: *Ctx) void {
    const src = c.lines("emoji.txt");
    var disagree: usize = 0;
    var parts: usize = 0;
    var combining: usize = 0;
    var prepared = .{ .c = c, .src = &src, .disagree = &disagree, .parts = &parts, .combining = &combining };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.disagree.* = 0;
                context.parts.* = 0;
                context.combining.* = 0;
                for (context.src.*) |l| {
                    var it: v.Graphemes = .init(l);
                    while (it.next()) |g| {
                        if (v.disagrees(g)) context.disagree.* += 1;
                        if (v.combinesOnly(g)) context.combining.* += 1;
                        var p: v.Parts = .init(g);
                        while (p.next()) |_| context.parts.* += 1;
                    }
                }
                std.mem.doNotOptimizeAway(context.parts.*);
                context.c.count += context.parts.*;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("value\tdisagree={d} combining={d} parts={d}\n", .{ disagree, combining, parts });
}

fn textWrap(c: *Ctx) void {
    const text = c.file("prose.txt");
    const rows = c.gpa.alloc(v.Row, text.len + 1) catch @panic("oom");
    var n: usize = 0;
    var prepared = .{ .c = c, .text = &text, .rows = &rows, .n = &n };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.n.* = v.wrap(context.text.*, context.c.cols, .word, .unicode, context.rows.*);
                std.mem.doNotOptimizeAway(context.rows.*[0..context.n.*]);
                context.c.count += context.n.*;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        emit("value\trows={d}\n", .{n});
        var out: std.ArrayList(u8) = .empty;
        for (rows[0..n]) |row| {
            out.appendSlice(c.gpa, text[row.start..row.end]) catch @panic("oom");
            out.append(c.gpa, '\n') catch @panic("oom");
        }
        line("text", out.items);
    }
}

fn textFit(c: *Ctx, end: bool) void {
    const src = c.lines("wide.txt");
    var kept: usize = 0;
    var prepared = .{ .c = c, .end = &end, .src = &src, .kept = &kept };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.kept.* = 0;
                for (context.src.*, 0..) |l, i| {
                    const cols: u16 = @intCast(@max(4, (context.c.cols * (i % 7 + 3)) / 10));
                    if (context.end.*) {
                        context.kept.* += v.fitEnd(l, cols, "…", .unicode).len;
                    } else context.kept.* += v.fit(l, cols, "…", .unicode).len;
                }
                std.mem.doNotOptimizeAway(context.kept.*);
                context.c.count += context.src.*.len;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("value\tkept={d}\n", .{kept});
}

// ---------------------------------------------------------------- layout

const outer_constraints = [_]w.Constraint{ .{ .fixed = 3 }, .{ .percent = 20 }, .{ .min = 5 }, .{ .max = 10 }, .{ .fill = 1 }, .{ .fill = 2 } };
const inner_constraints = [_]w.Constraint{ .{ .fixed = 12 }, .{ .percent = 25 }, .{ .min = 8 }, .{ .max = 30 }, .{ .fill = 1 } };

fn layoutSplit(c: *Ctx) void {
    var outer: [outer_constraints.len]v.Rect = undefined;
    var inner: [inner_constraints.len]v.Rect = undefined;
    const area: v.Rect = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
    var report: std.ArrayList(u8) = .empty;
    var prepared = .{ .c = c, .outer = &outer, .inner = &inner, .area = &area, .report = &report };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                var l = w.Layout.vertical(&outer_constraints);
                l.spacing = 1;
                const rows = l.split(context.area.*, &context.outer.*);
                for (rows) |row| {
                    var h = w.Layout.horizontal(&inner_constraints);
                    h.spacing = 1;
                    const cells = h.split(row, &context.inner.*);
                    std.mem.doNotOptimizeAway(cells);
                    context.c.count += cells.len;
                    if (context.c.check and n == 0) for (cells) |r| {
                        context.report.*.print(context.c.gpa, "{d},{d},{d},{d};", .{ r.col, r.row, r.cols, r.rows }) catch @panic("oom");
                    };
                }
                if (context.c.check and n == 0) {
                    for (rows) |r| context.report.*.print(context.c.gpa, "R{d},{d},{d},{d};", .{ r.col, r.row, r.cols, r.rows }) catch @panic("oom");
                }
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("rects\t{s}\n", .{report.items});
}

fn layoutRepeat(c: *Ctx) void {
    const out = c.gpa.alloc(v.Rect, @as(usize, c.cols) * c.rows) catch @panic("oom");
    const area: v.Rect = .{ .col = 0, .row = 0, .cols = c.cols, .rows = c.rows };
    var got: []v.Rect = &.{};
    var prepared = .{ .c = c, .out = &out, .area = &area, .got = &got };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.got.* = w.Layout.repeat(.horizontal, .{ .col = 0, .row = 0, .cols = 6, .rows = 3 }, 1, context.out.*);
                std.mem.doNotOptimizeAway(context.got.*);
                _ = context.area.*;
                context.c.count += context.got.*.len;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) emit("value\ttiles={d}\n", .{got.len});
}

// ---------------------------------------------------------------- widgets

fn child(win: v.Window, r: v.Rect) v.Window {
    return win.child(.{ .col = r.col, .row = r.row, .cols = r.cols, .rows = r.rows });
}

fn widget(c: *Ctx, comptime draw: fn (*Ctx, v.Window, usize) void) void {
    var s = c.screen();
    defer s.deinit();
    const win = s.window();
    var prepared = .{ .c = c, .win = &win };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |n| {
                draw(context.c, context.win.*, n);
                context.c.count += 1;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) dumpGrid(c.gpa, &s);
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
    const gpa = c.gpa;
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

fn markdownParse(c: *Ctx) void {
    {
        const source = c.file("doc.md");
        var blocks_n: usize = 0;
        var prepared = .{ .c = c, .source = &source, .blocks_n = &blocks_n };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |_| {
                    var doc = must(w.Markdown.Document.init(context.c.gpa, context.source.*));
                    context.blocks_n.* = doc.blocks().len;
                    context.c.count += doc.spans().len;
                    doc.deinit();
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) emit("value\tblocks={d}\n", .{blocks_n});
    }
}

fn markdownTableParse(c: *Ctx) void {
    {
        const source = c.file("tables.md");
        var tables: usize = 0;
        var cells: usize = 0;
        var tasks: usize = 0;
        var prepared = .{ .c = c, .source = &source, .tables = &tables, .cells = &cells, .tasks = &tasks };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |_| {
                    var doc = must(w.Markdown.Document.init(context.c.gpa, context.source.*));
                    context.tables.* = 0;
                    context.cells.* = 0;
                    context.tasks.* = 0;
                    for (doc.blocks()) |b| {
                        if (b.table) |t| {
                            context.tables.* += 1;
                            context.cells.* += t.rows * t.columns;
                        }
                        if (b.task != null) context.tasks.* += 1;
                    }
                    context.c.count += doc.spans().len;
                    doc.deinit();
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) emit("value\ttables={d} cells={d} tasks={d}\n", .{ tables, cells, tasks });
    }
}

/// Two log lines a frame, printed above an inline view a quarter of the
/// terminal tall that is redrawn under them: the bytes of each frame are
/// the evidence, replayed by the independent decoder.
fn printAbove(c: *Ctx) void {
    {
        const gpa = c.gpa;
        const view_rows: u16 = @max(2, c.rows / 4);
        const size: v.Size = .{ .cols = c.cols, .rows = view_rows };
        var view = must(v.Screen.init(gpa, size));
        defer view.deinit();
        view.method = .unicode;
        var r = must(v.Renderer.init(gpa, size));
        defer r.deinit();
        var lines = must(v.Screen.init(gpa, .{ .cols = c.cols, .rows = 2 }));
        defer lines.deinit();
        lines.method = .unicode;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        must(r.enter(&out.writer, caps, .@"inline", .{}));
        drawView(&view, 0);
        _ = must(r.draw(&out.writer, &view, null, caps));
        if (c.check) line("wire", out.written());
        var prepared = .{ .c = c, .view = &view, .r = &r, .lines = &lines, .out = &out };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |n| {
                    context.out.*.clearRetainingCapacity();
                    context.lines.*.clear();
                    var buf: [64]u8 = undefined;
                    for (0..2) |k| {
                        const text = std.mem.print(&buf, "log {d:0>6} {s} {s}", .{ 2 * n + k, words[(2 * n + k) % words.len], words[(2 * n + k + 3) % words.len] }) catch unreachable; // unreachable: two corpus words fit
                        _ = must(context.lines.*.window().printSegment(.{ .text = text }, .{ .row = @intCast(k), .wrap = .none }));
                    }
                    drawView(&context.view.*, n + 1);
                    const stats = must(context.r.*.printAbove(&context.out.*.writer, &context.lines.*, &context.view.*, null, caps));
                    context.c.bytes += stats.bytes;
                    context.c.count += 2;
                    if (context.c.check) line("wire", context.out.*.written());
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
    }
}

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
fn textEdit(c: *Ctx) void {
    {
        const prose = c.file("prose.txt");
        const typed = prose[0..@min(prose.len, @as(usize, c.cols) * 2)];
        var final: u64 = 0;
        var final_len: usize = 0;
        var undone_len: usize = 0;
        var prepared = .{ .c = c, .typed = &typed, .final = &final, .final_len = &final_len, .undone_len = &undone_len };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |_| {
                    var b: w.TextInput.Buffer = .init(context.c.gpa);
                    for (context.typed.*) |ch| must(b.insert(&.{ch}));
                    for (0..4) |_| must(b.delete(.word_left));
                    for (0..3) |_| b.move(.word_left, false);
                    for (0..5) |_| must(b.delete(.right));
                    b.move(.end, false);
                    for (0..3) |_| must(b.delete(.left));
                    while (must(b.undo())) {}
                    context.undone_len.* = b.text().len;
                    while (must(b.redo())) {}
                    context.final.* = std.hash.Fnv1a_64.hash(b.text());
                    context.final_len.* = b.text().len;
                    context.c.count += context.typed.*.len;
                    b.deinit();
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) emit("value\tfinal={d}:{x} undone={d}\n", .{ final_len, final, undone_len });
    }
}

// ---------------------------------------------------------------- input, emulator, pictures

fn inputEvents(c: *Ctx) void {
    const path = c.gpa.print("{s}/{d}x{d}/input.bin", .{ c.corpus, c.cols, c.rows }) catch @panic("oom");
    const file = std.Io.Dir.cwd().openFile(c.io, path, .{}) catch @panic("input corpus");
    var tty = v.Tty.adopt(file);
    const parser_buffer = c.gpa.alloc(u8, 1 << 16) catch @panic("oom");
    const read_buffer = c.gpa.alloc(u8, 1 << 20) catch @panic("oom");
    var kinds: [32]usize = @splat(0);
    var events: usize = 0;
    var prepared = .{ .c = c, .file = &file, .tty = &tty, .parser_buffer = &parser_buffer, .read_buffer = &read_buffer, .kinds = &kinds, .events = &events };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                // Back to the start of the input, as lseek does: the descriptor's own
                // offset, which is what the Tty reads from.
                context.c.io.vtable.fileSeekTo(context.c.io.userdata, context.file.*, 0) catch @panic("rewind");
                var in = must(v.Input.init(&context.tty.*, .{ .parser_buffer = context.parser_buffer.*, .read_buffer = context.read_buffer.*, .escape = .fromMilliseconds(50) }));
                context.events.* = 0;
                context.kinds.* = @splat(0);
                while (true) {
                    const e = in.next(context.c.io) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => std.debug.panic("{s}", .{@errorName(err)}),
                    };
                    context.events.* += 1;
                    context.kinds.*[@backingInt(std.meta.activeTag(e)) % context.kinds.*.len] += 1;
                }
                context.c.count += context.events.*;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        emit("value\tevents={d}", .{events});
        for (kinds) |k| emit(" {d}", .{k});
        emit("\n", .{});
    }
}

fn termFeed(c: *Ctx) void {
    var s = c.screen();
    defer s.deinit();
    var r = must(v.Renderer.init(c.gpa, c.size()));
    defer r.deinit();
    var frame: std.Io.Writer.Allocating = .init(c.gpa);
    defer frame.deinit();
    const src = c.lines("wide.txt");
    for (0..c.rows) |y| _ = must(s.window().printSegment(.{ .text = src[y % src.len], .style = .{ .fg = rgb(y, 0), .bold = y % 2 == 0 } }, .{ .row = @intCast(y), .wrap = .none }));
    _ = must(r.draw(&frame.writer, &s, null, caps));
    var term = must(v.Term.init(c.gpa, c.size()));
    defer term.deinit();
    term.setMethod(.unicode);
    var dump: std.Io.Writer.Allocating = .init(c.gpa);
    defer dump.deinit();
    var prepared = .{ .c = c, .frame = &frame, .term = &term, .dump = &dump };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                must(context.term.*.feed("\x1b[H\x1b[2J"));
                must(context.term.*.feed(context.frame.*.written()));
                context.dump.*.clearRetainingCapacity();
                must(v.dumpScreen(context.term.*.screen(), &context.dump.*.writer, .{}));
                context.c.bytes += context.frame.*.written().len;
                context.c.count += 1;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        dumpGrid(c.gpa, &s);
        line("text", dump.written());
        if (v.firstDifference(&s, term.screen()) != null) @panic("emulator differs from the drawn screen");
    }
}

fn pictureTransmit(c: *Ctx) void {
    var layers: v.Layers = .init(c.gpa);
    defer layers.deinit();
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    const pw: u32 = @as(u32, c.cols) * 4;
    const ph: u32 = @as(u32, c.rows) * 8;
    const pixels = c.gpa.alloc(u8, @as(usize, pw) * ph * 4) catch @panic("oom");
    for (pixels, 0..) |*p, i| p.* = @truncate(i *% 31 +% i / 4096);
    must(out.ensureTotalCapacity(pixels.len * 2 + 8192));
    var prepared = .{ .c = c, .layers = &layers, .out = &out, .pw = &pw, .ph = &ph, .pixels = &pixels };
    const Callback = struct {
        fn run(context: *@TypeOf(prepared), units: u64) !void {
            for (0..units) |_| {
                context.out.*.clearRetainingCapacity();
                const n = must(context.layers.*.transmit(&context.out.*.writer, 7, context.pixels.*, .{ .width = context.pw.*, .height = context.ph.*, .compress = false }));
                context.c.bytes += context.out.*.written().len;
                context.c.count += n;
            }
        }
    };
    must(c.measurement.run(&prepared, Callback.run));
    if (c.check) {
        const digest = digestOf(out.written());
        emit("value\tbytes={d} sha256={x}\n", .{ out.written().len, digest });
    }
}

fn digestOf(bytes: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return d;
}

fn pictureFrame(c: *Ctx, comptime protocol: enum { kitty, sixel, iterm, cells }) void {
    {
        var screen = c.screen();
        defer screen.deinit();
        var renderer = must(v.Renderer.init(c.gpa, c.size()));
        defer renderer.deinit();
        var layers: v.Layers = .init(c.gpa);
        defer layers.deinit();
        layers.configureSize(.{ .cells = c.size(), .cell = .{ .width = 8, .height = 16 } });
        var out: std.Io.Writer.Allocating = .init(c.gpa);
        defer out.deinit();
        const width: u32 = (@as(u32, c.cols) - 1) * 8;
        const height: u32 = (@as(u32, c.rows) - 1) * 16;
        const pixels = c.gpa.alloc(u8, @as(usize, width) * height * 4) catch @panic("oom");
        for (0..@as(usize, width) * height) |i| @memcpy(pixels[i * 4 ..][0..4], &[_]u8{ 255, 0, 0, 255 });
        const policy: v.Caps = .{ .width_method = .unicode, .truecolor = true, .picture_protocol = switch (protocol) {
            .kitty => .kitty,
            .sixel => .sixel,
            .iterm => .iterm,
            .cells => .cells,
        } };
        switch (protocol) {
            .kitty => _ = must(layers.transmit(&out.writer, 7, pixels, .{ .width = width, .height = height, .compress = false })),
            .sixel => must(layers.storeSixel(7, .{ .width = width, .height = height, .pixels = .{ .rgba = pixels }, .palette = &.{.{ .r = 255, .g = 0, .b = 0 }} })),
            .iterm => must(layers.storeIterm(7, c.file("picture.png"), 0)),
            .cells => {},
        }
        if (c.check and protocol == .kitty) line("setup", out.written());
        must(out.ensureTotalCapacity(pixels.len * 2 + 8192));
        _ = must(renderer.draw(&out.writer, &screen, null, policy));
        var prepared = .{ .c = c, .screen = &screen, .renderer = &renderer, .layers = &layers, .out = &out, .width = &width, .height = &height, .pixels = &pixels, .policy = &policy };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |n| {
                    context.out.*.clearRetainingCapacity();
                    const col: u16 = @intCast(n % 2);
                    if (protocol == .cells) {
                        context.screen.*.clear();
                        must((w.Sextants{ .width = context.width.*, .height = context.height.*, .pixels = context.pixels.* }).draw(context.screen.*.window().sub(.{ .col = col, .row = 0, .cols = context.c.cols - 1, .rows = context.c.rows - 1 })));
                    } else must(context.layers.*.declare(.{ .image = 7, .rect = .{ .col = col, .row = 0, .cols = context.c.cols - 1, .rows = context.c.rows - 1 } }));
                    const stats = must(context.renderer.*.draw(&context.out.*.writer, &context.screen.*, if (protocol == .cells) null else &context.layers.*, context.policy.*));
                    context.c.count += stats.placements;
                    context.c.bytes += stats.bytes;
                    if (context.c.check) line("wire", context.out.*.written());
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) emit("value\twidth={d} height={d} frames={d}\n", .{ width, height, c.iterations });
    }
}

fn pictureReplace(c: *Ctx) void {
    {
        var s = c.screen();
        defer s.deinit();
        var r = must(v.Renderer.init(c.gpa, c.size()));
        defer r.deinit();
        var layers: v.Layers = .init(c.gpa);
        defer layers.deinit();
        var out: std.Io.Writer.Allocating = .init(c.gpa);
        defer out.deinit();
        var ids = must(v.ImageIds.init(100, 107, 0));
        var replacement: v.Replacement = .{};
        var pixels: [16 * 16 * 4]u8 = undefined;
        for (0..16 * 16) |i| pixels[i * 4 ..][0..4].* = .{ 31, 63, 127, 255 };
        const pic: v.Caps = .{ .width_method = .unicode, .truecolor = true, .kitty_graphics = true };
        var swaps: usize = 0;
        var prepared = .{ .c = c, .s = &s, .r = &r, .layers = &layers, .out = &out, .ids = &ids, .replacement = &replacement, .pixels = &pixels, .pic = &pic, .swaps = &swaps };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |n| {
                    context.out.*.clearRetainingCapacity();
                    // A clock that moves 100 ms a frame, so every grace period runs out.
                    const now: std.Io.Timestamp = .{ .nanoseconds = @as(i96, @intCast(n)) * 100 * std.time.ns_per_ms };
                    if (context.replacement.*.canSend()) _ = must(context.replacement.*.send(&context.layers.*, &context.out.*.writer, &context.ids.*, &context.pixels.*, .{ .width = 16, .height = 16, .compress = false, .now = now }));
                    _ = must(context.replacement.*.declare(&context.layers.*, .{ .image = 0, .rect = .{ .col = @intCast(n % 2), .row = 0, .cols = 2, .rows = 2 } }, now.addDuration(.fromMilliseconds(60)), .fromMilliseconds(50)));
                    _ = must(context.r.*.draw(&context.out.*.writer, &context.s.*, &context.layers.*, context.pic.*));
                    if (context.replacement.*.current() != null) context.swaps.* += 1;
                    context.c.bytes += context.out.*.written().len;
                    context.c.count += 1;
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) emit("value\tcurrent={d} swaps={d} images={d}\n", .{ replacement.current() orelse 0, swaps, layers.images().len });
    }
}

fn canvasRaster(c: *Ctx) void {
    {
        var surface = must(w.Canvas.Surface.init(c.gpa, @as(u32, c.cols) * 8, @as(u32, c.rows) * 16));
        defer surface.deinit();
        prepareWidgets(c, "canvas");
        const p = (w.Canvas{ .x_bounds = .{ 0, 100 }, .y_bounds = .{ 0, 100 } }).raster(&surface);
        var prepared = .{ .c = c, .surface = &surface, .p = &p };
        const Callback = struct {
            fn run(context: *@TypeOf(prepared), units: u64) !void {
                for (0..units) |_| {
                    context.surface.*.clear();
                    for (0..32) |i| {
                        const a = @as(f64, @floatFromInt(i)) * std.math.pi / 16;
                        context.p.*.line(50, 50, 50 + 45 * @cos(a), 50 + 45 * @sin(a), .{});
                    }
                    for (0..8) |i| {
                        const d: f64 = @floatFromInt(i * 5);
                        context.p.*.rect(5 + d, 5 + d, 90 - 2 * d, 90 - 2 * d, .{});
                    }
                    context.p.*.circle(50, 50, 30, .{ .rgba = .{ 255, 200, 0, 255 } });
                    context.p.*.disc(25, 25, 10, .{ .rgba = .{ 0, 200, 255, 255 } });
                    context.p.*.polyline(State.wave, .{});
                    context.c.count += 1;
                }
            }
        };
        must(c.measurement.run(&prepared, Callback.run));
        if (c.check) {
            const digest = digestOf(surface.pixels());
            emit("value\tsha256={x}\n", .{digest});
        }
    }
}

/// One workload: `args` are `<task> <check|smoke|full> <cols> <rows>
/// <iterations>`, or `list-tasks`.
pub fn run(init: std.process.Init, args: []const []const u8) !void {
    stdout_io = init.io;
    if (args.len == 1 and std.mem.eql(u8, args[0], "list-tasks")) {
        for (workloads.ops) |name| emit("{s}\n", .{name});
        return;
    }
    if (args.len != 5) return error.Arguments;
    const task = args[0];
    const cols = try std.fmt.parseInt(u16, args[2], 10);
    const rows = try std.fmt.parseInt(u16, args[3], 10);
    const iterations = try std.fmt.parseInt(usize, args[4], 10);
    if (cols < 8 or rows < 4 or iterations == 0) return error.InvalidSize;
    var c: Ctx = .{
        .gpa = init.gpa,
        .io = init.io,
        .cols = cols,
        .rows = rows,
        .iterations = iterations,
        .check = std.mem.eql(u8, args[1], "check"),
        .measurement = try .init(init, task, args[1], cols, rows, iterations),
        .corpus = init.environ_map.get("VISOR_BENCH_CORPUS") orelse return error.NoCorpus,
    };
    // Fixture construction for widgets happens before the measured callback.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var fixture = c;
    fixture.gpa = arena.allocator();
    prepareWidgets(&fixture, task);
    c.corpus = fixture.corpus;

    const Run = struct { name: []const u8, run: *const fn (*Ctx) void };
    const S = struct {
        fn printAscii(x: *Ctx) void {
            printRows(x, "ascii.txt");
        }
        fn printWide(x: *Ctx) void {
            printRows(x, "wide.txt");
        }
        fn scrollModel(x: *Ctx) void {
            scrollRows(x, false);
        }
        fn scrollRender(x: *Ctx) void {
            scrollRows(x, true);
        }
        fn fitStart(x: *Ctx) void {
            textFit(x, false);
        }
        fn fitEnd(x: *Ctx) void {
            textFit(x, true);
        }
        fn W(comptime f: fn (*Ctx, v.Window, usize) void) *const fn (*Ctx) void {
            return struct {
                fn run(x: *Ctx) void {
                    widget(x, f);
                }
            }.run;
        }
    };
    const runs = [_]Run{
        .{ .name = "cell_writes", .run = cellWrites },
        .{ .name = "print_rows", .run = S.printAscii },
        .{ .name = "wide_print", .run = S.printWide },
        .{ .name = "wide_repaint", .run = widePrintRepaint },
        .{ .name = "fill_clear", .run = fillClear },
        .{ .name = "scroll_rows", .run = S.scrollModel },
        .{ .name = "scroll_repaint", .run = S.scrollRender },
        .{ .name = "resize", .run = resizeGrid },
        .{ .name = "copy_cells", .run = copyCells },
        .{ .name = "copy_text", .run = copyText },
        .{ .name = "links", .run = links },
        .{ .name = "grapheme_pool", .run = graphemePool },
        .{ .name = "modes", .run = modes },
        .{ .name = "text_width", .run = textWidth },
        .{ .name = "graphemes", .run = graphemes },
        .{ .name = "width_models", .run = widthModels },
        .{ .name = "text_wrap", .run = textWrap },
        .{ .name = "text_fit", .run = S.fitStart },
        .{ .name = "text_fit_end", .run = S.fitEnd },
        .{ .name = "layout_split", .run = layoutSplit },
        .{ .name = "layout_repeat", .run = layoutRepeat },
        .{ .name = "block", .run = S.W(blocks) },
        .{ .name = "paragraph", .run = S.W(paragraph) },
        .{ .name = "markdown_parse", .run = markdownParse },
        .{ .name = "markdown_draw", .run = S.W(markdownDraw) },
        .{ .name = "markdown_table_parse", .run = markdownTableParse },
        .{ .name = "markdown_table_draw", .run = S.W(markdownTableDraw) },
        .{ .name = "tree", .run = S.W(tree) },
        .{ .name = "print_above", .run = printAbove },
        .{ .name = "text_edit", .run = textEdit },
        .{ .name = "list", .run = S.W(list) },
        .{ .name = "table", .run = S.W(table) },
        .{ .name = "tabs", .run = S.W(tabs) },
        .{ .name = "gauge", .run = S.W(gauge) },
        .{ .name = "line_gauge", .run = S.W(lineGauge) },
        .{ .name = "sparkline", .run = S.W(sparkline) },
        .{ .name = "barchart", .run = S.W(barchart) },
        .{ .name = "chart", .run = S.W(chart) },
        .{ .name = "scrollbar", .run = S.W(scrollbar) },
        .{ .name = "canvas", .run = S.W(canvas) },
        .{ .name = "canvas_raster", .run = canvasRaster },
        .{ .name = "calendar", .run = S.W(calendar) },
        .{ .name = "text_input", .run = S.W(textInput) },
        .{ .name = "keys", .run = S.W(keys) },
        .{ .name = "rule", .run = S.W(rule) },
        .{ .name = "edges", .run = S.W(edges) },
        .{ .name = "sextants", .run = S.W(sextants) },
        .{ .name = "input_events", .run = inputEvents },
        .{ .name = "term_feed", .run = termFeed },
        .{ .name = "picture_transmit", .run = pictureTransmit },
        .{ .name = "picture_frame_kitty", .run = struct {
            fn run(x: *Ctx) void {
                pictureFrame(x, .kitty);
            }
        }.run },
        .{ .name = "picture_frame_sixel", .run = struct {
            fn run(x: *Ctx) void {
                pictureFrame(x, .sixel);
            }
        }.run },
        .{ .name = "picture_frame_iterm", .run = struct {
            fn run(x: *Ctx) void {
                pictureFrame(x, .iterm);
            }
        }.run },
        .{ .name = "picture_frame_cells", .run = struct {
            fn run(x: *Ctx) void {
                pictureFrame(x, .cells);
            }
        }.run },
        .{ .name = "picture_replace", .run = pictureReplace },
    };
    inline for (runs) |r| {
        if (std.mem.eql(u8, task, r.name)) {
            r.run(&c);
            if (c.check) emit("result\t{d}\t{d}\t{d}\t0\n", .{ iterations, c.count, c.bytes });
            return;
        }
    }
    return error.UnknownTask;
}
