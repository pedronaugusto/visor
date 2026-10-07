const std = @import("std");
const NoResize = @import("shakedown").alloc.NoResize;
const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const StoredCell = cellmod.internal.StoredCell;
const Link = cellmod.Link;
const Point = geom.Point;
const Rect = geom.Rect;
const Size = geom.Size;
const Style = cellmod.Style;
const Screen = @import("screen.zig").Screen;
const Renderer = @import("render.zig").Renderer;
const testing = std.testing;
const made = @import("screen.zig").test_access.made;
test "managed screens and renderers use their captured allocator through every operation" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var s = try Screen.init(gpa, .{ .cols = 4, .rows = 1 });
            defer s.deinit();
            var r = try Renderer.init(gpa, s.dimensions());
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
    try testing.expect(@sizeOf(@TypeOf(s.own_cells[0])) <= 32);
    var renderer = try Renderer.init(testing.allocator, s.dimensions());
    defer renderer.deinit();
    try testing.expect(@sizeOf(@TypeOf(renderer.prev[0])) <= 32);
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
    var s = try made(1, 1);
    defer s.deinit();
    const text = try s.intern("a\u{301}\u{302}\u{303}");
    const link = try s.link("https://checked.invalid", "");
    try s.writeOwnedCell(0, 0, .{ .text = text, .link = link });
    const exported = s.readCell(0, 0).?;
    try testing.expectEqual(s.pool_generation, exported.text.generation());
    try testing.expectEqual(s.pool_generation, exported.link.generation());
}

test "screen and renderer geometry and allocation metadata have one owner" {
    var screen = try Screen.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer screen.deinit();
    var renderer = try Renderer.init(testing.allocator, screen.dimensions());
    defer renderer.deinit();
    try screen.resize(.{ .cols = 7, .rows = 3 });
    try renderer.resize(screen.dimensions());
    try testing.expectEqual(screen.dimensions(), renderer.dimensions());
}

fn expectDiffAgreement(a: *const Screen, b: *const Screen) !void {
    var changes = a.diff(b);
    for (0..@max(a.dimensions().rows, b.dimensions().rows)) |y| {
        const ar = a.rowAt(@intCast(y));
        const br = b.rowAt(@intCast(y));
        var columns = ar.diff(br);
        var equal = ar.len() == br.len();
        for (0..@max(ar.len(), br.len())) |x| {
            const ac = ar.get(x);
            const bc = br.get(x);
            const same = if (ac != null and bc != null) ac.?.eql(bc.?) else false;
            if (same) continue;
            equal = false;
            try testing.expectEqual(x, columns.next().?);
            try testing.expectEqual(Point{ .col = @intCast(x), .row = @intCast(y) }, changes.next().?);
        }
        try testing.expect(columns.next() == null);
        try testing.expectEqual(equal, ar.eql(br));
    }
    try testing.expect(changes.next() == null);
    try testing.expect(changes.next() == null);
}

test "screen diff compares compact cells with checked pool identities" {
    var a = try made(6, 2);
    defer a.deinit();
    var b = try made(6, 2);
    defer b.deinit();
    try testing.expect(a.rowAt(0).eql(b.rowAt(0)));
    try a.write(0, 0, "x", .{ .bold = true }, .none);
    try b.write(0, 0, "x", .{ .bold = true }, .none);
    try testing.expect(a.rowAt(0).eql(b.rowAt(0)));
    try b.write(1, 0, "y", .{}, .none);
    try a.write(0, 1, "a\u{301}\u{302}\u{303}", .{}, .none);
    try b.write(0, 1, "a\u{301}\u{302}\u{303}", .{}, .none);
    try a.write(2, 1, "z", .{}, try a.link("https://same.invalid", ""));
    try b.write(2, 1, "z", .{}, try b.link("https://same.invalid", ""));
    try testing.expect(!a.rowAt(1).eql(b.rowAt(1)));
    const foreign = a.readCell(0, 1).?;
    try testing.expectError(error.InvalidHandle, b.writeOwnedCell(0, 1, foreign));
    try testing.expectError(error.InvalidHandle, b.writeOwnedCell(2, 1, a.readCell(2, 1).?));
    try expectDiffAgreement(&a, &b);
    try expectDiffAgreement(&a, &a);
    try a.compactPool();
    try testing.expectError(error.InvalidHandle, a.writeOwnedCell(0, 1, foreign));
    try expectDiffAgreement(&a, &b);
    try expectDiffAgreement(&a, &a);
    try a.resize(.{ .cols = 8, .rows = 3 });
    try expectDiffAgreement(&a, &b);
    try expectDiffAgreement(&b, &a);
    try b.resize(a.dimensions());
    try expectDiffAgreement(&a, &b);
}

test "screen diff agrees with checked reads on random screens" {
    var a = try made(17, 5);
    defer a.deinit();
    var b = try made(17, 5);
    defer b.deinit();
    var prng: std.Random.DefaultPrng = .init(173);
    const random = prng.random();
    const glyphs = [_][]const u8{ " ", "x", "界", "a\u{301}\u{302}\u{303}" };
    for (0..20) |round| {
        for (0..100) |_| {
            const x = random.uintLessThan(u16, 17);
            const y = random.uintLessThan(u16, 5);
            const glyph = glyphs[random.uintLessThan(usize, glyphs.len)];
            const style: Style = .{ .bold = random.boolean(), .fg = .rgb(random.int(u8), 13, 41) };
            const owner = if (random.boolean()) &a else &b;
            const link_id = if (random.boolean()) try owner.link("https://random.invalid", "id=one") else .none;
            try owner.write(x, y, glyph, style, link_id);
        }
        if (round % 4 == 0) try a.compactPool();
        try expectDiffAgreement(&a, &b);
        try expectDiffAgreement(&b, &a);
        try expectDiffAgreement(&a, &a);
    }
}
