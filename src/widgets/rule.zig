//! A line across a window or down it.
//!
//! The rule under a heading, the dashed one above a prompt, the bar between
//! two columns. A rule is one glyph repeated; which glyph and which style are
//! the caller's, and the renderer writes a run of one glyph as the glyph and
//! a count where the terminal can take it.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Direction = layout.Direction;
const Style = visor.Style;
const Window = visor.Window;

/// A line across a window or down it.
pub const Rule = struct {
    /// Which way it runs.
    direction: Direction = .horizontal,
    /// The glyph it is made of. Null takes `solid` across and `vertical`
    /// down.
    glyph: ?[]const u8 = null,
    /// The style it draws in.
    style: Style = .{},
    /// Cells left as they are between two glyphs: a spaced rule, one that
    /// reads as broken rather than drawn.
    gap: u16 = 0,

    /// A thin line across.
    pub const solid = "\u{2500}";
    /// A quieter line across, in dashes.
    pub const dashed = "\u{254c}";
    /// A heavy line across.
    pub const heavy = "\u{2501}";
    /// A double line across.
    pub const double = "\u{2550}";
    /// A thin line down.
    pub const vertical = "\u{2502}";

    /// Draws the rule along the window's first row, or down its first
    /// column, the whole length of the window.
    pub fn draw(r: Rule, win: Window) (std.mem.Allocator.Error || error{InvalidHandle})!void {
        if (win.rect.isEmpty()) return;
        switch (r.direction) {
            .horizontal => {
                const glyph = r.glyph orelse solid;
                const step = @max(visor.graphemeWidth(glyph, win.screen.method), 1);
                var col: u16 = 0;
                while (@as(u32, col) + step <= win.cols()) : (col +|= step +| r.gap) try win.write(col, 0, glyph, r.style, .none);
            },
            .vertical => {
                const glyph = r.glyph orelse vertical;
                var row: u16 = 0;
                while (row < win.rows()) : (row +|= 1 +| r.gap) try win.write(0, row, glyph, r.style, .none);
            },
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a rule runs the width of its window, in the glyph it was given" {
    var h: Harness = try .init(testing.allocator, 8, 3);
    defer h.deinit();
    try (Rule{}).draw(h.window().child(.{ .col = 1, .cols = 5, .rows = 1 }));
    try (Rule{ .glyph = Rule.dashed, .style = .{ .dim = true } }).draw(h.window().child(.{ .row = 1, .cols = 3 }));
    try (Rule{ .direction = .vertical }).draw(h.window().child(.{ .col = 7 }));
    try h.expectFrame(
        \\ ───── │
        \\╌╌╌    │
        \\       │
        \\
    );
    try testing.expect(h.styleAt(0, 1).dim);
}

test "a wide glyph is repeated whole, never half" {
    var h: Harness = try .init(testing.allocator, 5, 1);
    defer h.deinit();
    try (Rule{ .glyph = "\u{4e00}" }).draw(h.window());
    try h.expectFrame(
        \\一一
        \\
    );
}

test "a spaced rule leaves the cells between its glyphs as they were" {
    var h: Harness = try .init(testing.allocator, 7, 4);
    defer h.deinit();
    try h.window().write(1, 0, "x", .{}, .none);
    try (Rule{ .glyph = Rule.dashed, .gap = 1 }).draw(h.window().child(.{ .rows = 1 }));
    try (Rule{ .direction = .vertical, .gap = 2 }).draw(h.window().child(.{ .col = 6, .row = 1 }));
    try h.expectFrame(
        \\╌x╌ ╌ ╌
        \\      │
        \\
        \\
        \\
    );
}

test "a wide rule stops before crossing the u16 column edge" {
    var screen = try visor.Screen.init(testing.allocator, .{ .cols = std.math.maxInt(u16), .rows = 1 });
    defer screen.deinit();
    try (Rule{ .glyph = "一" }).draw(screen.window());
    try testing.expectEqualStrings("一", screen.textAt(std.math.maxInt(u16) - 3, 0));
    try testing.expectEqualStrings(" ", screen.textAt(std.math.maxInt(u16) - 1, 0));
}
