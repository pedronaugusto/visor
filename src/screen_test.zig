const std = @import("std");
const morse = @import("dependencies.zig").morse;
const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const pool = @import("pool.zig");
const textmod = @import("text.zig");
const Damage = @import("damage.zig").Damage;
const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const StoredCell = cellmod.internal.StoredCell;
const Link = cellmod.Link;
const Point = geom.Point;
const Rect = geom.Rect;
const Size = geom.Size;
const Style = cellmod.Style;
const Screen = @import("screen.zig").Screen;
const Cursor = @import("screen.zig").Cursor;
const testing = std.testing;
const made = @import("screen.zig").test_access.made;
const checkInvariants = @import("screen.zig").test_access.checkInvariants;
test "managed screens and renderers use their captured allocator through every operation" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var s = try Screen.init(gpa, .{ .cols = 4, .rows = 1 });
            defer s.deinit();
            var r = try @import("render.zig").Renderer.init(gpa, s.dimensions());
            defer r.deinit();
            const text = try s.intern("a\u{301}\u{302}\u{303}");
            const link_id = try s.link("https://kept.invalid", "id=kept");
            try s.writeOwnedCell(0, 0, .{ .text = text, .link = link_id });
            try s.compactPool();
            try s.resize(.{ .cols = 8, .rows = 2 });
            try r.resize(s.dimensions());
            var out: std.Io.Writer.Discarding = .init(&.{});
            _ = try r.draw(&out.writer, &s, null, .{});
        }
    }.run, .{});
}

test "the grid and renderer store compact cells while exported handles stay checked" {
    var s = try made(3, 1);
    defer s.deinit();
    try testing.expect(@sizeOf(@TypeOf(s._cells[0])) <= 32);
    var renderer = try @import("render.zig").Renderer.init(testing.allocator, s.dimensions());
    defer renderer.deinit();
    try testing.expect(@sizeOf(@TypeOf(renderer._prev[0])) <= 32);
    const glyph = "👩‍🚀";
    try s.write(0, 0, glyph, .{}, try s.link("https://checked.invalid", ""));
    const read: *const fn (*const Screen, u16, u16) ?Cell = &Screen.readCell;
    const exported = read(&s, 0, 0).?;
    const borrowed_row = s.rowAt(0);
    try testing.expectEqual(@as(usize, 3), borrowed_row.len());
    try testing.expect(exported.eql(borrowed_row.get(0).?));
    try testing.expect(borrowed_row.get(3) == null);
    try testing.expectEqualStrings(glyph, try s.textOf(&exported));
    try s.compactPool();
    try testing.expectError(error.InvalidHandle, s.writeOwnedCell(0, 0, exported));
    const stale_row_cell = borrowed_row.get(0).?;
    try testing.expectError(error.InvalidHandle, s.writeOwnedCell(0, 0, stale_row_cell));
    const current = s.readCell(0, 0).?;
    try testing.expectEqualStrings(glyph, try s.textOf(&current));
    try testing.expectEqualStrings("https://checked.invalid", s.target(current.link).?.uri);
}

test "raw pools and renderer storage stay behind the checked boundary" {
    const Renderer = @import("render.zig").Renderer;
    try testing.expect(!@hasField(Screen, "graphemes"));
    try testing.expect(!@hasField(Screen, "links"));
    try testing.expect(!@hasField(Renderer, "prev"));
    try testing.expect(!@hasField(Renderer, "link"));
    var s = try made(1, 1);
    defer s.deinit();
    const text = try s.intern("a\u{301}\u{302}\u{303}");
    const link = try s.link("https://checked.invalid", "");
    try s.writeOwnedCell(0, 0, .{ .text = text, .link = link });
    const exported = s.readCell(0, 0).?;
    try testing.expectEqual(s._pool_generation, exported.text.generation());
    try testing.expectEqual(s._pool_generation, exported.link.generation());
}

test "screen and renderer geometry and allocation metadata have one owner" {
    const Renderer = @import("render.zig").Renderer;
    inline for (.{ Screen, Renderer }) |Owner| {
        inline for (.{ "gpa", "size", "pool_generation" }) |field| try testing.expect(!@hasField(Owner, field));
    }
    try testing.expect(!@hasField(Screen, "damage"));
    inline for (.{ "force", "drifted", "untrusted", "hashes", "buf", "style_sequences", "region" }) |field| try testing.expect(!@hasField(Renderer, field));
    var screen = try Screen.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer screen.deinit();
    var renderer = try Renderer.init(testing.allocator, screen.dimensions());
    defer renderer.deinit();
    try screen.resize(.{ .cols = 7, .rows = 3 });
    try renderer.resize(screen.dimensions());
    try testing.expectEqual(screen.dimensions(), renderer.dimensions());
}
