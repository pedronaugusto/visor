//! Finding the frame whose rows moved, and writing it as a scroll.
//!
//! A frame in which the text scrolled by one row differs from the last one in
//! every row, so a diff repaints the whole screen for something the terminal
//! can do in a dozen bytes. This hashes the rows of both frames, looks for the
//! one offset that explains the most of them, checks the cells rather than
//! trusting the hashes, and writes a scrolling region and a scroll.
//!
//! It is conservative by construction: the offset has to explain at least two
//! rows that really changed, the band has to be longer than the distance
//! moved, and every row in it is compared cell by cell before a byte is
//! written. When any of that fails the frame is drawn the ordinary way, which
//! is correct and only costs more.
//!
//! What this file will never do: guess. A row that matches by hash and not by
//! cells is not a match.

const std = @import("std");
const morse = @import("../dependencies.zig").morse;
const cellmod = @import("../cell.zig");
const render = @import("../render.zig");
const Caps = @import("../caps.zig").Caps;
const Screen = @import("../screen.zig").Screen;
const Renderer = render.Renderer;
const Cell = cellmod.internal.StoredCell;
const testing = std.testing;

/// A screen and a renderer that have already agreed on a first frame.
const Fixture = struct {
    gpa: std.mem.Allocator,
    screen: Screen,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,
    caps: Caps,

    fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Fixture {
        const size: geomSize = .{ .cols = cols, .rows = rows };
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit();
        s.method = .unicode;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit();
        r._shown = false;
        r._cursor = .{ .col = 0, .row = 0 };
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{ .width_method = .unicode, .osc8 = true, .scroll_detection = true },
        };
    }

    fn deinit(f: *Fixture) void {
        f.screen.deinit();
        f.renderer.deinit();
        f.out.deinit();
        f.* = undefined;
    }

    fn draw(f: *Fixture) !Renderer.Stats {
        f.out.clearRetainingCapacity();
        return f.renderer.draw(&f.out.writer, &f.screen, null, f.caps);
    }

    /// Numbers down the left of the screen, so a moved row is obvious.
    fn number(f: *Fixture) !void {
        var row: u16 = 0;
        while (row < f.screen.dimensions().rows) : (row += 1) {
            var buf: [8]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "r{d:0>2}", .{row});
            for (text, 0..) |c, i| try f.screen.write(@intCast(i), row, &.{c}, .{}, .none);
        }
    }
};

const geomSize = @import("../geom.zig").Size;

test "a whole screen scrolled up is one sequence and not a repaint" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    try f.number();
    _ = try f.draw();

    f.screen.scroll(.fromSize(f.screen.dimensions()), 1);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 12), stats.scrolled);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\x1b[1S") != null);
    // No scrolling region: the band is the whole screen.
    try testing.expect(std.mem.indexOf(u8, f.out.written(), ";12r") == null);
    try testing.expect(stats.bytes < 24);
}

test "a whole screen scrolled down is the mirror" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    try f.number();
    _ = try f.draw();

    f.screen.scroll(.fromSize(f.screen.dimensions()), -2);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 12), stats.scrolled);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\x1b[2T") != null);
    try testing.expect(stats.bytes < 24);
}

test "a band of rows scrolled inside the screen sets a region and puts it back" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    try f.number();
    _ = try f.draw();

    f.screen.scroll(.{ .col = 0, .row = 2, .cols = 10, .rows = 8 }, 1);
    const stats = try f.draw();
    try testing.expect(stats.scrolled > 0);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\x1b[3;10r") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "\x1b[1S") != null);
    try testing.expect(std.mem.endsWith(u8, f.out.written(), "\x1b[r") or
        std.mem.indexOf(u8, f.out.written(), "\x1b[r") != null);
}

test "a frame that is not a scroll is not written as one" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    try f.number();
    _ = try f.draw();

    try f.screen.write(5, 3, "x", .{}, .none);
    try f.screen.write(6, 7, "y", .{}, .none);
    try f.screen.write(7, 9, "z", .{}, .none);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.scrolled);
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "S") == null);
}

test "the detector is off unless the caller asks for it" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    f.caps.scroll_detection = false;
    try f.number();
    _ = try f.draw();

    f.screen.scroll(.fromSize(f.screen.dimensions()), 1);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.scrolled);
}

test "a scroll the rows do not really make is refused" {
    var f: Fixture = try .init(testing.allocator, 10, 12);
    defer f.deinit();
    try f.number();
    _ = try f.draw();

    // Every row changes, but not by moving.
    var row: u16 = 0;
    while (row < 12) : (row += 1) try f.screen.write(6, row, "!", .{}, .none);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.scrolled);
}

test "a region whose edge runs through tall text is refused, and the terminal keeps the text whole" {
    // Found by the round trip once its generator explored: rows moved up
    // one inside a band whose last row held the top half of text drawn two
    // rows tall, so a region ending there tore the block, and the terminal
    // cleared it.
    const gpa = testing.allocator;
    var f: Fixture = try .init(gpa, 10, 9);
    defer f.deinit();
    f.caps.scaled_text = true;
    var t: @import("../term.zig").Term = try .init(gpa, f.screen.dimensions());
    defer t.deinit();
    t.setMethod(.unicode);
    f.renderer._shown = null;
    f.renderer._cursor = null;

    for ([_]u16{ 2, 8 }) |row| try f.screen.write(1, row, "\u{4e2d}", .{}, .none);
    try f.screen.write(5, 2, "\u{4e2d}", .{}, .none);
    try testing.expect(try f.screen.writeScaled(8, 4, "\u{e9}", .{ .bold = true }, .none, 2));
    _ = try f.draw();
    try t.feed(f.out.written());

    // Rows two to five up by one, and then the row that now holds the
    // block's lower half changed as well: the rows that moved and still
    // match end at the block's head row, so a region over them would end
    // there and cut the block in two.
    f.screen.scroll(.{ .col = 0, .row = 1, .cols = 10, .rows = 5 }, 1);
    try f.screen.write(0, 4, "x", .{}, .none);
    const stats = try f.draw();
    try t.feed(f.out.written());
    try testing.expectEqual(@as(u32, 0), stats.scrolled);
    try @import("../term.zig").expectScreensEqual(&f.screen, t.screen());
}
