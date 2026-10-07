const std = @import("std");
const corpus = @import("shakedown").corpus;
const morse = @import("dependencies.zig").morse;

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const textmod = @import("text.zig");
const Screen = @import("screen.zig").Screen;
const screen_internal = @import("screen.zig").internal;

const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Style = cellmod.Style;

const Rect = geom.Rect;
const Point = geom.Point;
const Size = geom.Size;
const Window = @import("screen.zig").window_api.Window;
const testing = std.testing;

fn made(cols: u16, rows: u16) !Screen {
    var s: Screen = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    s.method = .unicode;
    return s;
}

/// A press at a place, counting from one as a mouse report does.
fn mouseAt(x: u32, y: u32) morse.MouseEvent {
    return .{ .button = .left, .press = true, .x = x, .y = y };
}

fn rowText(s: *const Screen, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var col: u16 = 0;
    while (col < s.dimensions().cols) : (col += 1) {
        const g = s.textAt(col, row);
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

test "the whole grid is a window and a child is inside it" {
    var s = try made(10, 4);
    defer s.deinit();

    const root = s.window();
    try testing.expectEqual(@as(u16, 10), root.cols());
    try testing.expectEqual(@as(u16, 4), root.rows());

    const c = root.child(.{ .col = 2, .row = 1, .cols = 4, .rows = 2 });
    try testing.expectEqual(Rect{ .col = 2, .row = 1, .cols = 4, .rows = 2 }, c.rect());
    try c.writeOwnedCell(0, 0, .init(.{ .text = .inlined("x") }));
    try testing.expectEqualStrings("x", s.textAt(2, 1));
}

test "a child asked for outside its parent comes back empty" {
    var s = try made(10, 4);
    defer s.deinit();
    const c = s.window().child(.{ .col = 20, .row = 20, .cols = 4, .rows = 4 });
    try testing.expect(c.rect().isEmpty());
    try c.writeOwnedCell(0, 0, .init(.{ .text = .inlined("x") }));
    try testing.expect(!s.damage.any());
}

test "a child with no size given is the rest of the parent" {
    var s = try made(10, 4);
    defer s.deinit();
    const c = s.window().child(.{ .col = 3, .row = 1 });
    try testing.expectEqual(@as(u16, 7), c.cols());
    try testing.expectEqual(@as(u16, 3), c.rows());
}

test "a write past the window's edge writes nothing at all" {
    var s = try made(6, 2);
    defer s.deinit();
    const c = s.window().child(.{ .col = 1, .row = 0, .cols = 2, .rows = 1 });
    try c.writeOwnedCell(5, 0, .init(.{ .text = .inlined("x") }));
    try c.writeOwnedCell(0, 5, .init(.{ .text = .inlined("x") }));
    try testing.expect(!s.damage.any());
    try testing.expectEqual(@as(?Cell, null), c.readCell(2, 0));
}

test "a bordered child draws its frame and names the inside" {
    var s = try made(6, 4);
    defer s.deinit();
    const inside = s.window().child(.{ .border = .{ .where = .all } });
    try testing.expectEqual(Rect{ .col = 1, .row = 1, .cols = 4, .rows = 2 }, inside.rect());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\u{250c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("\u{2502}    \u{2502}", rowText(&s, 1, &buf));
    try testing.expectEqualStrings("\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}", rowText(&s, 3, &buf));
}

test "a border on one side takes one row from that side only" {
    var s = try made(6, 4);
    defer s.deinit();
    const inside = s.window().child(.{ .border = .{ .where = .{ .top = true } } });
    try testing.expectEqual(Rect{ .col = 0, .row = 1, .cols = 6, .rows = 3 }, inside.rect());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(corpus.repeat("\u{2500}", 6), rowText(&s, 0, &buf));
}

test "print lays text out and says where it stopped" {
    var s = try made(10, 2);
    defer s.deinit();
    const at = try s.window().print(&.{
        .{ .text = "ab", .style = .{ .bold = true } },
        .{ .text = "cd" },
    }, .{});
    try testing.expectEqual(@as(u16, 4), at.col);
    try testing.expectEqual(@as(u16, 0), at.row);
    try testing.expect(!at.overflow);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd      ", rowText(&s, 0, &buf));
    try testing.expect(s.readCell(1, 0).?.style.bold);
    try testing.expect(!s.readCell(2, 0).?.style.bold);
}

test "print wrapping by grapheme fills each row before the next" {
    var s = try made(3, 3);
    defer s.deinit();
    const at = try s.window().printSegment(.{ .text = "abcdefg" }, .{ .wrap = .grapheme });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("def", rowText(&s, 1, &buf));
    try testing.expectEqualStrings("g  ", rowText(&s, 2, &buf));
    try testing.expectEqual(@as(u16, 1), at.col);
    try testing.expectEqual(@as(u16, 2), at.row);
}

test "print wrapping by word breaks at a space" {
    var s = try made(10, 3);
    defer s.deinit();
    _ = try s.window().printSegment(.{ .text = "the quick brown fox" }, .{ .wrap = .word });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("the quick ", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("brown fox ", rowText(&s, 1, &buf));
}

test "print not wrapping drops what does not fit and says so" {
    var s = try made(4, 2);
    defer s.deinit();
    const at = try s.window().printSegment(.{ .text = "abcdefg" }, .{ .wrap = .none });
    try testing.expect(at.overflow);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("    ", rowText(&s, 1, &buf));
}

test "print measuring only writes nothing" {
    var s = try made(10, 2);
    defer s.deinit();
    const at = try s.window().printSegment(.{ .text = "abcd" }, .{ .commit = false });
    try testing.expectEqual(@as(u16, 4), at.col);
    try testing.expect(!s.damage.any());
}

test "a newline in a segment ends the row whatever the wrap is" {
    var s = try made(6, 3);
    defer s.deinit();
    _ = try s.window().printSegment(.{ .text = "ab\ncd" }, .{ .wrap = .none });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ab    ", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("cd    ", rowText(&s, 1, &buf));
}

test "a wide grapheme never straddles the window's right edge" {
    var s = try made(3, 2);
    defer s.deinit();
    _ = try s.window().printSegment(.{ .text = "ab\u{4e2d}" }, .{ .wrap = .grapheme });
    try testing.expectEqualStrings("\u{4e2d}", s.textAt(0, 1));
    try testing.expectEqual(Cell.Kind.spacer_tail, s.readCell(1, 1).?.shape.kind);
}

test "a link on a segment reaches every cell of it" {
    var s = try made(8, 1);
    defer s.deinit();
    const l = try s.link("https://ziglang.org", "");
    _ = try s.window().printSegment(.{ .text = "zig", .link = l }, .{});
    for (0..3) |col| try testing.expectEqual(l, s.readCell(@intCast(col), 0).?.link);
    try testing.expectEqual(Link.none, s.readCell(3, 0).?.link);
}

test "width measures by the screen's own method" {
    var s = try made(8, 1);
    defer s.deinit();
    const w = s.window();
    try testing.expectEqual(@as(u16, 3), w.width("abc"));
    try testing.expectEqual(@as(u16, 2), w.width("\u{4e2d}"));
    try testing.expectEqual(@as(u16, 1), w.width("e\u{301}"));
}

test "a mouse report lands in the window's own coordinates or nowhere" {
    var s = try made(20, 10);
    defer s.deinit();
    const c = s.window().child(.{ .col = 4, .row = 2, .cols = 6, .rows = 3 });

    // Mouse reports count from one.
    try testing.expectEqual(Point{ .col = 0, .row = 0 }, c.hit(mouseAt(5, 3)).?);
    try testing.expectEqual(Point{ .col = 5, .row = 2 }, c.hit(mouseAt(10, 5)).?);
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(4, 3)));
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(11, 3)));
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(5, 6)));
}

test "a mouse report in pixels is refused rather than divided" {
    var s = try made(20, 10);
    defer s.deinit();
    var event = mouseAt(5, 3);
    event.pixels = true;
    try testing.expectEqual(@as(?Point, null), s.window().hit(event));
}

test "the cursor is set in the window's coordinates" {
    var s = try made(20, 10);
    defer s.deinit();
    const c = s.window().child(.{ .col = 4, .row = 2, .cols = 6, .rows = 3 });
    c.showCursor(1, 1);
    try testing.expectEqual(@as(u16, 5), s.cursor.col);
    try testing.expectEqual(@as(u16, 3), s.cursor.row);
    try testing.expect(s.cursor.visible);
    c.setCursorShape(.bar);
    try testing.expectEqual(morse.CursorShape.bar, s.cursor.shape);
    c.hideCursor();
    try testing.expect(!s.cursor.visible);
    c.showCursor(99, 0);
    try testing.expect(!s.cursor.visible);
}

test "fill and clear stay inside the window" {
    var s = try made(6, 3);
    defer s.deinit();
    const c = s.window().child(.{ .col = 1, .row = 1, .cols = 3, .rows = 1 });
    try c.fill(.fromSize(c.size()), .blank(.{ .bg = .ansi(.blue) }));
    try testing.expect(s.readCell(0, 1).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(4, 1).?.eql(.blank(.{})));
    c.clear();
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{})));
}

test "a window scrolls only its own rectangle" {
    var s = try made(6, 4);
    defer s.deinit();
    const c = s.window().child(.{ .col = 0, .row = 1, .cols = 6, .rows = 2 });
    try s.write(0, 0, "a", .{}, .none);
    try s.write(0, 1, "b", .{}, .none);
    try s.write(0, 2, "c", .{}, .none);
    try s.write(0, 3, "d", .{}, .none);
    c.scroll(1);
    try testing.expectEqualStrings("a", s.textAt(0, 0));
    try testing.expectEqualStrings("c", s.textAt(0, 1));
    try testing.expectEqualStrings(" ", s.textAt(0, 2));
    try testing.expectEqualStrings("d", s.textAt(0, 3));
}

test "the link under a cell is what a click there opens, a wide grapheme's in both its columns" {
    var sc: Screen = try .init(testing.allocator, .{ .cols = 10, .rows = 2 });
    defer sc.deinit();
    const win = sc.window().child(.{ .col = 2, .row = 1 });
    const link = try sc.link("file:///tmp/a.log", "");
    _ = try win.print(&.{
        .{ .text = "see " },
        .{ .text = "a\u{4e2d}", .link = link },
    }, .{ .wrap = .none });
    try testing.expect(win.linkAt(0, 0) == null);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(4, 0).?.uri);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(5, 0).?.uri);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(6, 0).?.uri);
    try testing.expect(win.linkAt(7, 0) == null);
    try testing.expect(win.linkAt(40, 0) == null);
}

test "a row's text comes back as the terminal shows it, trailing blanks left off" {
    var sc: Screen = try .init(testing.allocator, .{ .cols = 12, .rows = 1 });
    defer sc.deinit();
    const win = sc.window();
    _ = try win.printSegment(.{ .text = "a b\u{4e2d}c" }, .{ .wrap = .none });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try win.copyText(&out.writer, 0, 0, 12);
    try testing.expectEqualStrings("a b\u{4e2d}c", out.written());
    // Starting on the covered column takes the grapheme whole.
    out.clearRetainingCapacity();
    try win.copyText(&out.writer, 0, 4, 6);
    try testing.expectEqualStrings("\u{4e2d}c", out.written());
    // A range ending on the head's first column takes it once.
    out.clearRetainingCapacity();
    try win.copyText(&out.writer, 0, 1, 4);
    try testing.expectEqualStrings(" b\u{4e2d}", out.written());
}

/// A look for the tests: every odd row of the screen dimmed, and every
/// stroke that carries a glyph counted, as a program lighting what it drew
/// would count them.
const Dimmer = struct {
    glyphs: usize = 0,
    strokes: usize = 0,
    last: Point = .{},

    fn ink(d: *Dimmer) Window.Ink {
        return .{ .ctx = d, .apply = apply };
    }

    fn apply(ctx: *anyopaque, stroke: Window.Ink.Stroke) Style {
        const d: *Dimmer = @ptrCast(@alignCast(ctx)); // safe: ink hands apply out with a Dimmer as its ctx
        d.strokes += 1;
        if (!std.mem.eql(u8, stroke.text, " ")) d.glyphs += 1;
        d.last = .{ .col = stroke.col, .row = stroke.row };
        var out = stroke.style;
        if (stroke.row % 2 == 1) out.dim = true;
        return out;
    }
};

test "an ink draws every cell a window writes, where it lands on the screen, and a child inherits it" {
    var s = try made(10, 4);
    defer s.deinit();
    var d: Dimmer = .{};
    const ink = d.ink();
    const root = s.window().inked(&ink);
    const inner = root.child(.{ .col = 2, .row = 1, .cols = 6, .rows = 2, .border = .{ .where = .{ .left = true } } });
    try testing.expect(inner.ink() != null);
    _ = try inner.printSegment(.{ .text = "ab", .style = .{ .bold = true } }, .{});
    // In screen coordinates: the border took column 2, so "b" is at 4,1.
    try testing.expectEqual(Point{ .col = 4, .row = 1 }, d.last);
    try testing.expect(s.readCell(3, 1).?.style.dim and s.readCell(3, 1).?.style.bold);
    // The border's own cells went through it too.
    try testing.expect(s.readCell(2, 1).?.style.dim);
    try testing.expect(!s.readCell(2, 2).?.style.dim);
    try testing.expectEqual(@as(usize, 4), d.glyphs);

    // A fill is cell by cell: a style that depends on the row lands row by
    // row, and each blank is a stroke with no glyph.
    const strokes = d.strokes;
    try root.fill(.{ .col = 0, .row = 0, .cols = 3, .rows = 2 }, .blank(.{ .italic = true }));
    try testing.expectEqual(strokes + 6, d.strokes);
    try testing.expect(!s.readCell(0, 0).?.style.dim);
    try testing.expect(s.readCell(0, 1).?.style.dim and s.readCell(0, 1).?.style.italic);

    // Without one, the style is the style asked for.
    _ = try s.window().printSegment(.{ .text = "c", .style = .{ .bold = true } }, .{ .row = 3 });
    try testing.expect(!s.readCell(0, 3).?.style.dim);
}

test "a widget drawn through an ink is the widget drawn plain with the look applied after" {
    // What a program without an ink has to do: draw on a scratch screen,
    // then carry every cell over in its look. The ink gives the same cells
    // with no scratch screen.
    var plain = try made(12, 5);
    defer plain.deinit();
    const panel: Window.ChildOptions = .{ .cols = 12, .rows = 5, .border = .{ .where = .all, .glyphs = .rounded, .style = .{ .bold = true } } };
    _ = try plain.window().child(panel).print(&.{
        .{ .text = "one two ", .style = .{ .italic = true } },
        .{ .text = "\u{4e2d} three four", .style = .{ .fg = .ansi(.cyan) } },
    }, .{ .wrap = .word });
    for (0..plain.dimensions().rows) |r| {
        if (r % 2 == 0) continue;
        for (screen_internal.rowMut(&plain, @intCast(r))) |*c| {
            if (!c.eql(.blank(.{}))) c.style.dim = true;
        }
    }

    var inked = try made(12, 5);
    defer inked.deinit();
    var d: Dimmer = .{};
    const ink = d.ink();
    _ = try inked.window().inked(&ink).child(panel).print(&.{
        .{ .text = "one two ", .style = .{ .italic = true } },
        .{ .text = "\u{4e2d} three four", .style = .{ .fg = .ansi(.cyan) } },
    }, .{ .wrap = .word });

    for (plain.own_cells, inked.own_cells) |a, b| try testing.expect(a.eql(b));
}

test "a rectangle of the window's own cells is the child over it, clipped" {
    var s = try Screen.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer s.deinit();
    const outer = s.window().child(.{ .col = 2, .row = 1 });
    const inner = outer.sub(.{ .col = 3, .row = 1, .cols = 20, .rows = 1 });
    try testing.expectEqual(Rect{ .col = 5, .row = 2, .cols = 5, .rows = 1 }, inner.rect());
    try testing.expectEqual(outer.ink(), inner.ink());
}

test "printing measures without allocating and commits only unseen pooled text with allocation" {
    var fail = testing.FailingAllocator.init(testing.allocator, .{});
    var s = try Screen.init(fail.allocator(), .{ .cols = 8, .rows = 2 });
    defer s.deinit();
    s.method = .unicode;
    const long = "a\u{301}\u{302}\u{303}";
    fail.fail_index = fail.alloc_index;
    const measured = try s.window().printSegment(.{ .text = long }, .{ .commit = false });
    try testing.expectEqual(@as(u16, 1), measured.col);
    try testing.expectEqual(@as(usize, 0), s.graphemes.len());
    _ = try s.window().printSegment(.{ .text = "inline" }, .{});
    try testing.expectError(error.OutOfMemory, s.window().printSegment(.{ .text = long }, .{}));
    fail.fail_index = std.math.maxInt(usize);
    _ = try s.window().printSegment(.{ .text = long }, .{});
    const grown = fail.alloc_index;
    fail.fail_index = grown;
    s.clear();
    _ = try s.window().printSegment(.{ .text = long }, .{});
    try testing.expectEqual(grown, fail.alloc_index);
    try testing.expectEqualStrings(long, s.textAt(0, 0));
}

test "printing clips word widths and starting rows at the u16 coordinate edge" {
    var s = try Screen.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    const word = try testing.allocator.alloc(u8, std.math.maxInt(u16));
    defer testing.allocator.free(word);
    @memset(word, 'x');
    const result = try s.window().printSegment(.{ .text = word }, .{ .col = 1, .wrap = .word, .commit = false });
    try testing.expect(result.overflow);
    const outside = try s.window().printSegment(.{ .text = "\n" }, .{ .row = std.math.maxInt(u16), .commit = false });
    try testing.expect(outside.overflow);
    try testing.expectEqual(std.math.maxInt(u16), outside.row);
}

test "window placement clips every glyph extent before touching a neighbour" {
    for ([_]textmod.Method{ .unicode, .wcwidth, .explicit }) |method| {
        var s = try made(8, 4);
        defer s.deinit();
        s.method = method;
        var source = try made(8, 4);
        defer source.deinit();
        source.method = method;
        try source.write(0, 0, "中", .{}, .none);
        _ = try source.writeScaled(0, 1, "X", .{}, .none, 3);
        const wide = source.readCell(0, 0).?;
        const scaled = source.readCell(0, 1).?;
        const win = s.window().child(.{ .col = 1, .row = 1, .cols = 3, .rows = 2 });
        try s.write(4, 1, "R", .{}, .none);
        try s.write(1, 3, "B", .{}, .none);
        try win.write(2, 0, "中", .{}, .none);
        try testing.expectEqualStrings("R", s.textAt(4, 1));
        try testing.expectEqualStrings(" ", s.textAt(3, 1));
        try win.writeOwnedCell(2, 0, wide);
        try testing.expectEqualStrings("R", s.textAt(4, 1));
        try win.copyCell(&source, 2, 0, wide);
        try testing.expectEqualStrings("R", s.textAt(4, 1));
        try win.writeOwnedCell(0, 1, scaled);
        try testing.expectEqualStrings("B", s.textAt(1, 3));
        try win.copyCell(&source, 0, 1, scaled);
        try testing.expectEqualStrings("B", s.textAt(1, 3));
        try win.fill(.fromSize(win.size()), scaled);
        try testing.expectEqualStrings("R", s.textAt(4, 1));
        try testing.expectEqualStrings("B", s.textAt(1, 3));
        try win.write(1, 0, "中", .{}, .none);
        try testing.expectEqualStrings("中", s.textAt(2, 1));
    }
}

test "printing and measurement treat CRLF as one line break" {
    for ([_]textmod.Wrap{ .none, .word, .grapheme }) |mode| {
        var screen = try made(6, 3);
        defer screen.deinit();
        const win = screen.window();
        const measured = try win.printSegment(.{ .text = "a\r\nb\r\nc" }, .{ .wrap = mode, .commit = false });
        try testing.expectEqual(@as(u16, 2), measured.row);
        const drawn = try win.printSegment(.{ .text = "a\r\nb\r\nc" }, .{ .wrap = mode });
        try testing.expectEqualDeep(measured, drawn);
        try testing.expectEqualStrings("a", screen.textAt(0, 0));
        try testing.expectEqualStrings("b", screen.textAt(0, 1));
        try testing.expectEqualStrings("c", screen.textAt(0, 2));
    }
}

test "custom borders refuse malformed glyphs without changing the grid" {
    var s = try made(4, 3);
    defer s.deinit();
    _ = s.window().child(.{ .border = .{ .where = .{ .top = true }, .glyphs = .{ .horizontal = "ab" } } });
    for (0..4) |col| try testing.expectEqualStrings(" ", s.textAt(@intCast(col), 0));
}

test "window geometry stays with the screen that clipped it" {
    var s = try Screen.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    const w = s.window().sub(.{ .col = 3, .row = 1, .cols = 20, .rows = 20 });
    try testing.expect(w.screen() == &s);
    var rectangle = w.rect();
    rectangle.cols = 0;
    try testing.expectEqual(Rect{ .col = 3, .row = 1, .cols = 1, .rows = 1 }, w.rect());
    try testing.expect(w.ink() == null);
}
