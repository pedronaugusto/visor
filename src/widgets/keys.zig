//! The keys that work here, each beside what it does, in one row.
//!
//! The strip is the one widget nearly every full-screen program draws and
//! every one draws by hand. Its arithmetic is public — how wide it is — so a
//! program can decide what to drop when the row is short before it draws;
//! which keys go first is the program's call, not this file's.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Align = layout.Align;
const Style = visor.Style;
const Window = visor.Window;

/// The keys that work here, in one row.
pub const Keys = struct {
    /// The keys, in the order they are drawn.
    keys: []const Key,
    /// The style a key draws in.
    key_style: Style = .{ .bold = true },
    /// The style what it does draws in.
    label_style: Style = .{},
    /// Columns between a key and what it does.
    space: u16 = 1,
    /// Columns between one key and the next.
    gap: u16 = 3,
    /// Where the strip sits in the row.
    where: Align = .right,
    /// Columns kept clear between the strip and the edge it is aligned to.
    margin: u16 = 1,

    /// One key and what it does.
    pub const Key = struct {
        /// The key, as the program spells it: `q`, `esc`, `\u{21b5}`.
        key: []const u8,
        /// What it does.
        label: []const u8,
    };

    /// How many columns the strip takes, gaps included, margin not.
    pub fn width(k: Keys, method: visor.Method) u16 {
        var total: u32 = 0;
        for (k.keys, 0..) |key, i| {
            total += visor.width(key.key, method) + k.space + visor.width(key.label, method);
            if (i + 1 < k.keys.len) total += k.gap;
        }
        return @intCast(@min(total, std.math.maxInt(u16)));
    }

    /// Draws the strip on the window's first row. The columns between the
    /// keys are left as they are, so a strip drawn over a background keeps
    /// it.
    pub fn draw(k: Keys, win: Window) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const method = win.screen.method;
        const w = k.width(method);
        var col: u16 = switch (k.where) {
            .left => k.margin,
            .right => win.cols() -| w -| k.margin,
            .center => layout.offset(win.cols(), w, .center),
        };
        for (k.keys, 0..) |key, i| {
            _ = try win.printSegment(.{ .text = key.key, .style = k.key_style }, .{ .col = col, .wrap = .none });
            col +|= visor.width(key.key, method) + k.space;
            _ = try win.printSegment(.{ .text = key.label, .style = k.label_style }, .{ .col = col, .wrap = .none });
            col +|= visor.width(key.label, method);
            if (i + 1 < k.keys.len) col +|= k.gap;
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "the strip sits against the right edge, a margin in, gaps undrawn" {
    var h: Harness = try .init(testing.allocator, 24, 1);
    defer h.deinit();
    const strip: Keys = .{ .keys = &.{
        .{ .key = "q", .label = "quit" },
        .{ .key = "\u{21b5}", .label = "open" },
    } };
    try testing.expectEqual(@as(u16, 15), strip.width(.unicode));
    try strip.draw(h.window());
    try h.expectFrame(
        \\        q quit   ↵ open
        \\
    );
    try testing.expect(h.styleAt(8, 0).bold);
    try testing.expect(!h.styleAt(10, 0).bold);
}

test "a strip wider than the row starts at the left and is cut at the right" {
    var h: Harness = try .init(testing.allocator, 10, 1);
    defer h.deinit();
    const strip: Keys = .{ .keys = &.{
        .{ .key = "a", .label = "alpha" },
        .{ .key = "b", .label = "beta" },
    }, .gap = 1 };
    try strip.draw(h.window());
    try h.expectFrame(
        \\a alpha b
        \\
    );
}

test "the strip can sit on the left or in the middle" {
    var h: Harness = try .init(testing.allocator, 12, 1);
    defer h.deinit();
    const keys = [_]Keys.Key{.{ .key = "x", .label = "go" }};
    try (Keys{ .keys = &keys, .where = .left, .margin = 0 }).draw(h.window());
    try h.expectFrame(
        \\x go
        \\
    );
    h.window().clear();
    try (Keys{ .keys = &keys, .where = .center }).draw(h.window());
    try h.expectFrame(
        \\    x go
        \\
    );
}
