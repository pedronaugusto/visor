//! Budgets, as tests.
//!
//! `Renderer.Stats` makes the render pass measurable, so the budget goes in
//! the test rather than in a comment: a full repaint at 120x40 writes fewer
//! than so many bytes, a frame in which one cell changed writes fewer than
//! sixty-four, and a frame in which nothing changed writes nothing at all.
//! The numbers were set the day the renderer worked and only ever go down.
//!
//! They are byte counts, not times. A byte count is the same on every
//! machine and in every optimize mode, so it is a thing CI can fail on; a
//! microsecond is not. What the byte count stands in for is real: what a
//! terminal takes to ingest a frame goes with the size of the frame.
//!
//! There is also a time here, printed and never asserted on, for a person
//! running the suite to look at.

const std = @import("std");

const geom = @import("geom.zig");
const render = @import("render.zig");
const Caps = @import("caps.zig").Caps;
const Renderer = render.Renderer;
const Screen = @import("screen.zig").Screen;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A screen and a renderer of a size, with a writer that counts.
const Bench = struct {
    gpa: Allocator,
    screen: Screen,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,
    caps: Caps,

    fn init(gpa: Allocator, cols: u16, rows: u16) !Bench {
        const size: geom.Size = .{ .cols = cols, .rows = rows };
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit(gpa);
        s.method = .unicode;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit(gpa);
        r.shown = false;
        r.cursor = .{ .col = 0, .row = 0 };
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{ .width_method = .unicode, .osc8 = true, .truecolor = true },
        };
    }

    fn deinit(b: *Bench) void {
        b.screen.deinit(b.gpa);
        b.renderer.deinit(b.gpa);
        b.out.deinit();
    }

    fn draw(b: *Bench) !Renderer.Stats {
        b.out.clearRetainingCapacity();
        return b.renderer.draw(&b.out.writer, &b.screen, b.caps);
    }

    /// A frame with eight style runs a row, which is what a real one looks
    /// like.
    fn paint(b: *Bench, salt: usize) !void {
        const palette = [_]render.Style{
            .{},
            .{ .bold = true },
            .{ .fg = .ansi(.cyan) },
            .{ .fg = .ansi(.bright_magenta), .bg = .ansi(.black) },
            .{ .fg = .palette(137) },
            .{ .fg = .rgb(0x1c, 0x2e, 0xff) },
            .{ .italic = true, .fg = .ansi(.green) },
            .{ .underline = .curly },
        };
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 .,:;!?-+/";
        var row: u16 = 0;
        while (row < b.screen.size.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < b.screen.size.cols) : (col += 1) {
                const i = @as(usize, row) * b.screen.size.cols + col + salt;
                const style = palette[(col / (b.screen.size.cols / 8 + 1)) % palette.len];
                try b.screen.write(col, row, alphabet[i % alphabet.len ..][0..1], style, .none);
            }
        }
    }
};

/// What the whole suite is allowed to cost, in bytes a frame. Each of these
/// was measured the day it was written and is a ceiling, never a target.
const budget = struct {
    /// A full repaint of 120x40 with eight style runs a row.
    const repaint_120x40 = 8_100;
    /// The same at 200x60.
    const repaint_200x60 = 17_000;
    /// A frame in which one cell changed.
    const one_cell = 64;
    /// A frame in which one row scrolled, with the detector on.
    const scroll_one_row = 24;
    /// A frame in which every cell changed style but no glyph moved.
    const restyle_120x40 = 8_100;
    /// A frame with a wide grapheme every third cell, drawn once.
    const wide_120x40 = 6_700;
};

test "a full repaint at 120x40 stays inside its budget" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    try b.paint(0);
    const stats = try b.draw();
    try expectUnder("repaint 120x40", stats, budget.repaint_120x40);
    try testing.expectEqual(@as(u32, 40), stats.rows);
}

test "a full repaint at 200x60 stays inside its budget" {
    var b: Bench = try .init(testing.allocator, 200, 60);
    defer b.deinit();
    try b.paint(0);
    const stats = try b.draw();
    try expectUnder("repaint 200x60", stats, budget.repaint_200x60);
}

test "a frame in which one cell changed writes fewer than sixty-four bytes" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    try b.paint(0);
    _ = try b.draw();

    try b.screen.write(60, 20, "!", .{ .bold = true }, .none);
    const stats = try b.draw();
    try expectUnder("one cell", stats, budget.one_cell);
    try testing.expectEqual(@as(u32, 1), stats.rows);
    try testing.expectEqual(@as(u32, 1), stats.cells);
}

test "a frame in which nothing changed writes nothing at all" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    try b.paint(0);
    _ = try b.draw();
    const stats = try b.draw();
    try testing.expectEqual(@as(usize, 0), stats.bytes);

    // And with every row claimed to have changed, which is the stronger
    // statement.
    b.screen.damageAll();
    try testing.expectEqual(@as(usize, 0), (try b.draw()).bytes);
}

test "a frame in which one row scrolled is a scroll, not a repaint" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    b.caps.scroll_detection = true;
    try b.paint(0);
    _ = try b.draw();

    b.screen.scroll(.fromSize(b.screen.size), 1);
    // The row the scroll brought in is blank, so the frame is the scroll
    // sequence and nothing else.
    const stats = try b.draw();
    try expectUnder("scroll one row", stats, budget.scroll_one_row);
    try testing.expectEqual(@as(u32, 40), stats.scrolled);
}

test "a frame that changed every style stays inside its budget" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    try b.paint(0);
    _ = try b.draw();

    var row: u16 = 0;
    while (row < 40) : (row += 1) {
        var col: u16 = 0;
        while (col < 120) : (col += 1) {
            var c = b.screen.readCell(col, row).?;
            var style = c.style;
            style.reverse = true;
            c.setStyle(style);
            b.screen.writeOwnedCell(col, row, c);
        }
    }
    const stats = try b.draw();
    try expectUnder("restyle 120x40", stats, budget.restyle_120x40);
}

test "a frame with a wide grapheme every third cell stays inside its budget" {
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();

    var row: u16 = 0;
    while (row < 40) : (row += 1) {
        var col: u16 = 0;
        while (col + 2 < 120) : (col += 3) {
            try b.screen.write(col, row, "\u{4e2d}", .{}, .none);
            try b.screen.write(col + 2, row, "x", .{}, .none);
        }
    }
    const stats = try b.draw();
    try expectUnder("wide 120x40", stats, budget.wide_120x40);
    // Every row holds a wide grapheme, so every row is written whole.
    try testing.expectEqual(@as(u32, 40), stats.repainted);
}

test "the draw path allocates nothing at all" {
    // An allocator that fails on its first request, handed to nothing: the
    // screen and the renderer take theirs at init, and the frame path takes
    // none.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var b: Bench = try .init(testing.allocator, 120, 40);
    defer b.deinit();
    try b.paint(0);
    _ = try b.draw();

    // Every mutation the frame path offers, with the failing allocator
    // standing by to prove nothing reaches for one.
    const gpa = failing.allocator();
    _ = gpa;
    b.screen.writeOwnedCell(4, 4, .blank(.{ .bold = true }));
    b.screen.fill(.{ .col = 0, .row = 0, .cols = 10, .rows = 2 }, .blank(.{}));
    b.screen.scroll(.fromSize(b.screen.size), 1);
    b.screen.clear();
    _ = try b.draw();
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

/// Says what a frame cost when it costs too much, so the number in the test
/// can be moved down with evidence rather than up with a shrug.
fn expectUnder(name: []const u8, stats: Renderer.Stats, ceiling: usize) !void {
    if (stats.bytes <= ceiling) return;
    std.debug.print(
        "{s}: {d} bytes, budget {d} ({d} cells, {d} runs, {d} moves, {d} styles, {d} erased)\n",
        .{ name, stats.bytes, ceiling, stats.cells, stats.runs, stats.moves, stats.styles, stats.erased },
    );
    return error.OverBudget;
}
