//! A picture drawn in cells, two by three pixels a cell, for a terminal that
//! draws no pictures.
//!
//! Each cell is one of the sixty-four block sextants: a pixel counts as lit
//! when it is bright enough, the cell's glyph is the pattern of its lit
//! pixels, and its colour is the brightest of them. It is a blunt picture —
//! one colour a cell — and it is the one every terminal with a font of the
//! last decade can show.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

/// The glyph for a pattern of lit sextants: bit 0 the top left, bit 1 the
/// top right, then the middle pair and the bottom pair. Zero is a space and
/// sixty-three the full block.
pub fn sextant(mask: u6) []const u8 {
    return table[mask];
}

/// The pattern a glyph stands for, or null for anything that is not a
/// sextant, a half block, a full block or a space.
pub fn maskOf(glyph: []const u8) ?u6 {
    for (table, 0..) |g, m| {
        if (std.mem.eql(u8, g, glyph)) return @intCast(m);
    }
    return null;
}

/// U+1FB00 onwards covers the sixty patterns that have no older glyph: the
/// left half (21), the right half (42) and the full block (63) were in the
/// block elements already, and the empty cell is a space.
const table: [64][]const u8 = blk: {
    var t: [64][]const u8 = undefined;
    t[0] = " ";
    var cp: u21 = 0x1FB00;
    var m: usize = 1;
    while (m < 64) : (m += 1) {
        switch (m) {
            21 => t[m] = "\u{258C}",
            42 => t[m] = "\u{2590}",
            63 => t[m] = "\u{2588}",
            else => {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                const bytes: [n]u8 = buf[0..n].*;
                t[m] = &bytes;
                cp += 1;
            },
        }
    }
    break :blk t;
};

/// A picture drawn in sextants.
pub const Sextants = struct {
    /// The pixels, RGBA, row by row, four bytes each.
    pixels: []const u8,
    /// How many pixels across.
    width: usize,
    /// How many down.
    height: usize,
    /// How bright a pixel must be to count as lit, as the sum of its red,
    /// green and blue.
    threshold: u16 = 60,
    /// What every drawn cell starts from. Its foreground becomes the
    /// brightest lit pixel in the cell.
    style: Style = .{},

    /// Draws the picture from the window's top-left, pixel (2c, 3r) in cell
    /// (c, r). A cell with nothing lit in it is left as it is.
    pub fn draw(s: Sextants, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const need = s.width * s.height * 4;
        if (s.pixels.len < need) return;
        var row: u16 = 0;
        while (row < win.rows()) : (row += 1) {
            var col: u16 = 0;
            while (col < win.cols()) : (col += 1) {
                var mask: u6 = 0;
                var best: [3]u8 = .{ 0, 0, 0 };
                var best_light: u32 = 0;
                for (0..3) |sy| for (0..2) |sx| {
                    const px = @as(usize, col) * 2 + sx;
                    const py = @as(usize, row) * 3 + sy;
                    if (px >= s.width or py >= s.height) continue;
                    const i = (py * s.width + px) * 4;
                    const light: u32 = @as(u32, s.pixels[i]) + s.pixels[i + 1] + s.pixels[i + 2];
                    if (light <= s.threshold) continue;
                    mask |= @as(u6, 1) << @intCast(sy * 2 + sx);
                    if (light > best_light) {
                        best_light = light;
                        best = .{ s.pixels[i], s.pixels[i + 1], s.pixels[i + 2] };
                    }
                };
                if (mask == 0) continue;
                var style = s.style;
                style.fg = .rgb(best[0], best[1], best[2]);
                try win.write(col, row, sextant(mask), style, .none);
            }
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "the three patterns with older glyphs, and the order of the rest" {
    try testing.expectEqualStrings(" ", sextant(0));
    try testing.expectEqualStrings("\u{1FB00}", sextant(1));
    try testing.expectEqualStrings("\u{258C}", sextant(21));
    try testing.expectEqualStrings("\u{2590}", sextant(42));
    try testing.expectEqualStrings("\u{2588}", sextant(63));
    try testing.expectEqualStrings("\u{1FB3B}", sextant(62));
    for (0..64) |m| try testing.expectEqual(@as(?u6, @intCast(m)), maskOf(sextant(@intCast(m))));
    try testing.expectEqual(@as(?u6, null), maskOf("x"));
}

test "a cell is the pattern of its lit pixels, in the brightest of their colours" {
    var h: Harness = try .init(testing.allocator, 2, 1);
    defer h.deinit();
    // Four pixels across, three down. The first cell's left column lit, one
    // pixel brighter than the other two; the second cell dark.
    var px: [4 * 3 * 4]u8 = @splat(0);
    const lit = [_]usize{ 0, 4, 8 };
    for (lit) |p| px[p * 4 ..][0..4].* = .{ 100, 0, 0, 255 };
    px[4 * 4 ..][0..4].* = .{ 0, 200, 50, 255 };
    try (Sextants{ .pixels = &px, .width = 4, .height = 3, .style = .{ .bold = true } }).draw(h.window());
    try h.expectFrame(
        \\▌
        \\
    );
    const style = h.styleAt(0, 0);
    try testing.expect(style.bold);
    try testing.expectEqual(visor.Color.rgb(0, 200, 50), style.fg);
}

test "a picture smaller than the window leaves the rest alone" {
    var h: Harness = try .init(testing.allocator, 3, 2);
    defer h.deinit();
    _ = try h.window().printSegment(.{ .text = "abcdef" }, .{});
    const px = [_]u8{ 255, 255, 255, 255 };
    try (Sextants{ .pixels = &px, .width = 1, .height = 1 }).draw(h.window());
    try h.expectFrame(
        "\u{1FB00}bc\ndef\n",
    );
}
