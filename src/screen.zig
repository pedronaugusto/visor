//! The grid: cells, the bytes they point at, and what changed since the last
//! frame.
//!
//! One allocator, taken at `init`. After that, `writeCell`, `fill`, `clear`
//! and `scroll` never allocate; `write` and `intern` allocate only when a
//! grapheme is longer than the seven bytes a cell holds inline and has not
//! been seen before. Resize allocates. Nothing else does.
//!
//! The grid keeps its own invariants rather than trusting a caller to. A wide
//! grapheme is a head and a tail, always adjacent and always in that order;
//! overwriting either end repairs the other; a wide grapheme with one column
//! left in the row becomes a blank rather than something the terminal would
//! wrap. The widths across a row therefore always sum to the width of the
//! row, which is what makes the renderer's cursor arithmetic provable.
//!
//! What this file will never hold: layout, widgets, a previous frame, or a
//! single byte written to a terminal. The previous frame belongs to the
//! renderer, which is the only thing that knows what the terminal was shown.

const std = @import("std");
const morse = @import("morse");

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const layer = @import("layer.zig");
const pool = @import("pool.zig");
const textmod = @import("text.zig");
const Damage = @import("damage.zig").Damage;

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Point = geom.Point;
const Rect = geom.Rect;
const Size = geom.Size;
const Style = cellmod.Style;

/// Where the terminal's cursor should end the frame, whether it shows, and
/// what shape it takes.
pub const Cursor = struct {
    /// The column, counting from zero.
    col: u16 = 0,
    /// The row, counting from zero.
    row: u16 = 0,
    /// Whether the terminal draws it.
    visible: bool = false,
    /// The shape the terminal draws it as.
    shape: morse.CursorShape = .default,
};

/// The grid.
pub const Screen = struct {
    /// The allocator `init` was given, kept because `write` may have to put a
    /// grapheme in the pool and takes no allocator of its own. Every `gpa`
    /// passed to a later call must be this one.
    gpa: Allocator,
    /// How big the grid is.
    size: Size,
    /// Every cell, row by row.
    cells: []Cell,
    /// The graphemes too long to live in a cell.
    graphemes: pool.Graphemes,
    /// Every OSC 8 target the cells point at.
    links: pool.Links,
    /// Which cells have changed since the last frame was written.
    damage: Damage,
    /// Where the cursor should end the frame.
    cursor: Cursor = .{},
    /// The shape the terminal should draw under the mouse, or null to leave
    /// it as the user set it.
    pointer: ?morse.PointerShape = null,
    /// The pictures this frame shows.
    layers: layer.Layers = .{},
    /// How this screen measures text. The caller sets it from `Caps`; this
    /// package never guesses and never reads an environment variable.
    method: textmod.Method = .wcwidth,

    /// The grid, sized once. Everything after this writes into it.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Screen {
        const cells = try gpa.alloc(Cell, size.area());
        errdefer gpa.free(cells);
        @memset(cells, .blank(.{}));
        var dmg: Damage = try .init(gpa, size.rows);
        errdefer dmg.deinit(gpa);
        return .{
            .gpa = gpa,
            .size = size,
            .cells = cells,
            .graphemes = .{},
            .links = .{},
            .damage = dmg,
        };
    }

    /// Gives the grid back.
    pub fn deinit(s: *Screen, gpa: Allocator) void {
        s.sameAllocator(gpa);
        gpa.free(s.cells);
        s.graphemes.deinit(gpa);
        s.links.deinit(gpa);
        s.damage.deinit(gpa);
        s.layers.deinit(gpa);
        s.* = undefined;
    }

    /// A new size, contents kept where they still fit, everything damaged.
    ///
    /// The grapheme pool and the link table survive, so a cell that came
    /// through the resize still names the bytes it named before.
    pub fn resize(s: *Screen, gpa: Allocator, size: Size) Allocator.Error!void {
        s.sameAllocator(gpa);
        if (std.meta.eql(s.size, size)) {
            s.damageAll();
            return;
        }
        // Before anything is committed, so that a resize either happens or
        // leaves the screen exactly as it was. The cells that survive carry
        // the new offsets with them.
        try s.compactPool(gpa);

        const cells = try gpa.alloc(Cell, size.area());
        errdefer gpa.free(cells);
        @memset(cells, .blank(.{}));
        try s.damage.resize(gpa, size.rows);

        const rows = @min(s.size.rows, size.rows);
        const cols = @min(s.size.cols, size.cols);
        for (0..rows) |r| {
            const from = s.cells[r * s.size.cols ..][0..cols];
            @memcpy(cells[r * size.cols ..][0..cols], from);
        }
        gpa.free(s.cells);
        s.cells = cells;
        s.size = size;

        // A wide grapheme that used to have room may not any more.
        if (size.cols > 0) {
            for (0..size.rows) |r| {
                const last = r * size.cols + size.cols - 1;
                if (s.cells[last].shape.kind == .wide) {
                    s.cells[last] = .blank(s.cells[last].style);
                    s.cells[last].shape.kind = .spacer_head;
                }
            }
        }
        s.clampCursor();
        s.damageAll();
    }

    /// Rebuilds the grapheme pool and the link table around what the grid
    /// still shows, giving back the bytes of everything it does not.
    ///
    /// Interning keeps a grapheme for as long as the screen lives, which is
    /// the promise that makes a cell's bytes valid for as long as the cell
    /// is — and which means a program showing a stream of different emoji,
    /// or any user-supplied text, grows the pool without bound. This is the
    /// sweep, and `resize` does it for free because it was going to allocate
    /// and damage everything anyway.
    ///
    /// It is a call, not a policy: `draw` never allocates and nothing is
    /// freed behind a live cell.
    pub fn compactPool(s: *Screen, gpa: Allocator) Allocator.Error!void {
        s.sameAllocator(gpa);
        var graphemes: pool.Graphemes = .{};
        errdefer graphemes.deinit(gpa);
        var links: pool.Links = .{};
        errdefer links.deinit(gpa);

        // Everything the grid still shows, into the new pools. Nothing is
        // written back until this has succeeded, so a failure here leaves
        // the screen exactly as it was.
        for (s.cells) |*c| {
            if (c.text.isPooled()) _ = try graphemes.intern(gpa, s.graphemes.slice(&c.text));
            if (s.links.get(c.link)) |t| _ = try links.intern(gpa, t.uri, t.params);
        }
        // And now the cells, which cannot fail: everything they name is
        // already in the new pools.
        for (s.cells) |*c| {
            if (c.text.isPooled()) {
                c.text = graphemes.intern(gpa, s.graphemes.slice(&c.text)) catch unreachable;
            }
            if (s.links.get(c.link)) |t| {
                c.link = links.intern(gpa, t.uri, t.params) catch unreachable;
            }
        }
        s.graphemes.deinit(gpa);
        s.links.deinit(gpa);
        s.graphemes = graphemes;
        s.links = links;
        s.damageAll();
    }

    /// The cell at a place, or null outside the grid.
    pub fn readCell(s: *const Screen, col: u16, row: u16) ?Cell {
        if (col >= s.size.cols or row >= s.size.rows) return null;
        return s.cells[s.index(col, row)];
    }

    /// One cell, clipped, damage marked. Never allocates.
    ///
    /// A cell two columns wide also writes its tail, and whatever the two of
    /// them covered is repaired: a half of another wide grapheme becomes a
    /// blank in the style it had. A wide grapheme with only the last column
    /// left becomes a blank, because a terminal asked to draw it there would
    /// wrap it onto the next row. A cell handed in as a tail is taken as a
    /// blank: tails are the grid's own bookkeeping.
    pub fn writeCell(s: *Screen, col: u16, row: u16, c: Cell) void {
        if (col >= s.size.cols or row >= s.size.rows) return;
        const i = s.index(col, row);

        var put = c;
        if (put.shape.kind == .spacer_tail) put = .blank(c.style);
        if (put.shape.kind == .wide and col + 1 >= s.size.cols) {
            // There is one column left and the grapheme wants two. The cell
            // is a spacer, not a space: the diff has to be able to tell it
            // from something the caller asked for.
            put = .blank(put.style);
            put.shape.kind = .spacer_head;
        }

        s.detach(col, row);
        if (put.shape.kind == .wide) {
            s.detach(col + 1, row);
            s.place(i, put);
            var tail = put;
            tail.shape.kind = .spacer_tail;
            s.place(i + 1, tail);
        } else {
            s.place(i, put);
        }
    }

    /// A grapheme measured, placed, and its tail written if it is wide.
    ///
    /// Allocates only when the grapheme is longer than seven bytes and the
    /// screen has not seen it before. A grapheme that measures zero columns,
    /// and one that is or begins with a control character, is not written:
    /// neither is something a terminal would put in a cell.
    pub fn write(
        s: *Screen,
        col: u16,
        row: u16,
        grapheme: []const u8,
        style: Style,
        to: Link,
    ) Allocator.Error!void {
        if (grapheme.len == 0) return;
        if (grapheme[0] < 0x20 or grapheme[0] == 0x7f) return;
        const w = textmod.graphemeWidth(grapheme, s.method);
        if (w == 0) return;
        const t = try s.graphemes.intern(s.gpa, grapheme);
        s.writeCell(col, row, .{
            .text = t,
            .style = cellmod.canonical(style),
            .link = to,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                // Worked out once, here, and read by the drift rule every
                // frame after: re-measuring a row costs as much as drawing
                // one.
                .drift = textmod.disagrees(grapheme),
            },
        });
    }

    /// A rectangle of one cell.
    pub fn fill(s: *Screen, rect: Rect, c: Cell) void {
        const r = rect.intersect(.fromSize(s.size));
        if (r.isEmpty()) return;
        var y = r.row;
        while (y < r.bottom()) : (y += 1) {
            var col = r.col;
            while (col < r.right()) : (col += 1) s.writeCell(col, @intCast(y), c);
        }
    }

    /// Every cell blank and default.
    pub fn clear(s: *Screen) void {
        const blank: Cell = .blank(.{});
        for (s.cells, 0..) |*c, i| {
            if (c.eql(blank)) continue;
            c.* = blank;
            s.damage.mark(@intCast(i % s.size.cols), @intCast(i / s.size.cols));
        }
    }

    /// A rectangle moved by `n` rows, the vacated rows blank.
    ///
    /// A positive `n` moves the contents up, the way a terminal scrolls when
    /// something is written past the last row; a negative `n` moves them
    /// down. A wide grapheme cut in half by the rectangle's left or right
    /// edge becomes two blanks, because half a grapheme is not a thing a cell
    /// can hold.
    pub fn scroll(s: *Screen, rect: Rect, n: i32) void {
        const r = rect.intersect(.fromSize(s.size));
        if (r.isEmpty() or n == 0) return;
        const distance: u32 = @abs(n);
        const blank: Cell = .blank(.{});

        if (distance >= r.rows) {
            s.fill(r, blank);
            return;
        }
        const shift: u16 = @intCast(distance);
        if (n > 0) {
            var y = r.row;
            while (y + shift < r.bottom()) : (y += 1) {
                s.copyRun(r.col, y + shift, r.col, y, r.cols);
            }
            while (y < r.bottom()) : (y += 1) s.blankRun(r.col, y, r.cols, blank);
        } else {
            var y = @as(u16, @intCast(r.bottom())) - 1;
            while (y >= r.row + shift) : (y -= 1) {
                s.copyRun(r.col, y - shift, r.col, y, r.cols);
            }
            var top = r.row;
            while (top < r.row + shift) : (top += 1) s.blankRun(r.col, top, r.cols, blank);
        }

        var seam = r.row;
        while (seam < r.bottom()) : (seam += 1) {
            s.healSeam(r.col, @intCast(seam));
            s.healSeam(@intCast(r.right()), @intCast(seam));
        }
    }

    /// A grapheme into the pool, deduplicated; inline when it fits.
    pub fn intern(s: *Screen, gpa: Allocator, bytes: []const u8) Allocator.Error!Cell.Text {
        s.sameAllocator(gpa);
        return s.graphemes.intern(gpa, bytes);
    }

    /// An OSC 8 target into the link table, deduplicated.
    ///
    /// `params` is the `key=value:key=value` list OSC 8 places before the
    /// URI, empty for none. It is part of the link's identity: two targets
    /// that differ only by an `id=` are two links, because a terminal treats
    /// them as two.
    pub fn link(s: *Screen, gpa: Allocator, uri: []const u8, params: []const u8) Allocator.Error!Link {
        s.sameAllocator(gpa);
        return s.links.intern(gpa, uri, params);
    }

    /// The bytes of a cell's grapheme.
    ///
    /// The cell is taken by pointer because a grapheme of seven bytes or
    /// fewer lives inside it: what comes back borrows from the cell, and a
    /// cell read out by value would be gone before the bytes were used.
    pub fn textOf(s: *const Screen, c: *const Cell) []const u8 {
        return s.graphemes.slice(&c.text);
    }

    /// The bytes of the grapheme at a place, borrowed from the grid itself,
    /// or an empty slice outside it.
    pub fn textAt(s: *const Screen, col: u16, row_n: u16) []const u8 {
        if (col >= s.size.cols or row_n >= s.size.rows) return &.{};
        return s.textOf(&s.cells[s.index(col, row_n)]);
    }

    /// The target a cell's link names, or null when it has none.
    pub fn target(s: *const Screen, l: Link) ?pool.Target {
        return s.links.get(l);
    }

    /// The whole grid as a window.
    pub fn window(s: *Screen) @import("window.zig").Window {
        return .{ .screen = s, .rect = .fromSize(s.size) };
    }

    /// Everything dirty: the next draw writes the whole grid.
    pub fn damageAll(s: *Screen) void {
        s.damage.markAll(s.size.cols);
    }

    /// One row of cells.
    pub fn rowAt(s: *const Screen, n: u16) []const Cell {
        if (n >= s.size.rows) return &.{};
        return s.cells[@as(usize, n) * s.size.cols ..][0..s.size.cols];
    }

    /// One row of cells, to write into. The caller marks its own damage.
    pub fn rowAtMut(s: *Screen, n: u16) []Cell {
        if (n >= s.size.rows) return &.{};
        return s.cells[@as(usize, n) * s.size.cols ..][0..s.size.cols];
    }

    /// Where a cell is in `cells`.
    pub fn index(s: *const Screen, col: u16, row_n: u16) usize {
        return @as(usize, row_n) * s.size.cols + col;
    }

    //=====================================================================
    // The grid's own bookkeeping.
    //=====================================================================

    /// Stores a cell and marks it changed, or does neither when it is what
    /// was already there. This is the only place damage is marked, which is
    /// what makes the map exact in both directions.
    fn place(s: *Screen, i: usize, c: Cell) void {
        if (s.cells[i].eql(c)) return;
        s.cells[i] = c;
        s.damage.mark(@intCast(i % s.size.cols), @intCast(i / s.size.cols));
    }

    /// Breaks the wide grapheme a cell is half of, if it is half of one, so
    /// that the cell can be written over without leaving an orphan.
    fn detach(s: *Screen, col: u16, row_n: u16) void {
        if (col >= s.size.cols) return;
        const i = s.index(col, row_n);
        const c = s.cells[i];
        if (c.isTail()) {
            if (col > 0) s.place(i - 1, .blank(s.cells[i - 1].style));
        } else if (c.shape.kind == .wide and col + 1 < s.size.cols) {
            s.place(i + 1, .blank(s.cells[i + 1].style));
        }
    }

    /// Blanks whichever side of a wide grapheme was left without the other
    /// across the boundary just left of `col`.
    fn healSeam(s: *Screen, col: u16, row_n: u16) void {
        if (col == 0 or col >= s.size.cols) return;
        const i = s.index(col, row_n);
        const left = s.cells[i - 1];
        const here = s.cells[i];
        const paired = left.shape.kind == .wide and here.isTail();
        if (here.isTail() and !paired) s.place(i, .blank(here.style));
        if (left.shape.kind == .wide and !paired) s.place(i - 1, .blank(left.style));
    }

    /// Copies a run of cells from one row to another, marking what changed.
    fn copyRun(s: *Screen, from_col: u16, from_row: u16, to_col: u16, to_row: u16, cols: u16) void {
        const src = s.index(from_col, from_row);
        const dst = s.index(to_col, to_row);
        for (0..cols) |k| s.place(dst + k, s.cells[src + k]);
    }

    /// Blanks a run of cells, marking what changed.
    fn blankRun(s: *Screen, col: u16, row_n: u16, cols: u16, blank: Cell) void {
        const at = s.index(col, row_n);
        for (0..cols) |k| s.place(at + k, blank);
    }

    /// Puts the cursor back inside a grid that shrank.
    fn clampCursor(s: *Screen) void {
        if (s.size.cols == 0 or s.size.rows == 0) {
            s.cursor.col = 0;
            s.cursor.row = 0;
            return;
        }
        s.cursor.col = @min(s.cursor.col, s.size.cols - 1);
        s.cursor.row = @min(s.cursor.row, s.size.rows - 1);
    }

    /// In Debug, says so when a call is handed an allocator that is not the
    /// one the screen was made with.
    fn sameAllocator(s: *const Screen, gpa: Allocator) void {
        std.debug.assert(gpa.ptr == s.gpa.ptr and gpa.vtable == s.gpa.vtable);
    }
};

const testing = std.testing;

fn made(cols: u16, rows: u16) !Screen {
    var s: Screen = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    s.method = .unicode;
    return s;
}

/// Every invariant the grid promises, checked over the whole of it.
fn checkInvariants(s: *const Screen) !void {
    for (0..s.size.rows) |r| {
        var sum: u32 = 0;
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const c = s.cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape._reserved == 0);
            if (c.isTail()) {
                // A tail never stands alone, and never in the first column.
                try testing.expect(col > 0);
                const head = s.cells[s.index(col - 1, @intCast(r))];
                try testing.expect(!head.isTail());
                try testing.expectEqual(Cell.Kind.wide, head.shape.kind);
            } else {
                sum += c.width();
                if (c.shape.kind == .wide) {
                    // A wide head is never in the last column and always has
                    // its tail.
                    try testing.expect(col + 1 < s.size.cols);
                    const tail = s.cells[s.index(col + 1, @intCast(r))];
                    try testing.expect(tail.isTail());
                }
            }
            // Every grapheme is inside the pool and every link inside the
            // table.
            if (c.text.isPooled()) {
                const off = c.text.offset().?;
                try testing.expect(off + c.text.length() <= s.graphemes.len());
            }
            if (c.link.index()) |li| try testing.expect(li < s.links.count());
        }
        try testing.expectEqual(@as(u32, s.size.cols), sum);
    }
}

test "a fresh screen is blank and clean" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 8), s.cells.len);
    for (s.cells) |c| try testing.expect(c.eql(.blank(.{})));
    try testing.expect(!s.damage.any());
    try checkInvariants(&s);
}

test "a write outside the grid changes nothing" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);

    try s.write(9, 0, "x", .{}, .none);
    try s.write(0, 9, "x", .{}, .none);
    s.writeCell(4, 0, .blank(.{ .bold = true }));
    try testing.expect(!s.damage.any());
    try testing.expectEqual(@as(?Cell, null), s.readCell(4, 0));
}

test "writing the same cell twice damages once and not at all the second time" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);

    try s.write(1, 0, "a", .{}, .none);
    try testing.expectEqual(@as(usize, 1), s.damage.count());
    s.damage.clear();
    try s.write(1, 0, "a", .{}, .none);
    try testing.expect(!s.damage.any());
}

test "a wide grapheme writes a head and a tail" {
    var s = try made(6, 1);
    defer s.deinit(testing.allocator);

    try s.write(1, 0, "\u{4e2d}", .{}, .none);
    const head = s.readCell(1, 0).?;
    const tail = s.readCell(2, 0).?;
    try testing.expectEqualStrings("\u{4e2d}", s.textAt(1, 0));
    try testing.expectEqual(Cell.Kind.wide, head.shape.kind);
    try testing.expect(!head.isTail());
    try testing.expect(tail.isTail());
    try checkInvariants(&s);
}

test "overwriting either half of a wide grapheme repairs the other" {
    var s = try made(6, 1);
    defer s.deinit(testing.allocator);

    try s.write(1, 0, "\u{4e2d}", .{}, .none);
    try s.write(1, 0, "a", .{}, .none);
    try testing.expectEqualStrings("a", s.textAt(1, 0));
    try testing.expectEqualStrings(" ", s.textAt(2, 0));
    try checkInvariants(&s);

    try s.write(3, 0, "\u{4e2d}", .{}, .none);
    try s.write(4, 0, "b", .{}, .none);
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try testing.expectEqualStrings("b", s.textAt(4, 0));
    try checkInvariants(&s);
}

test "a wide grapheme over a wide grapheme repairs both edges" {
    var s = try made(8, 1);
    defer s.deinit(testing.allocator);

    try s.write(0, 0, "\u{4e2d}", .{}, .none);
    try s.write(2, 0, "\u{4e2d}", .{}, .none);
    try s.write(1, 0, "\u{6587}", .{}, .none);
    try testing.expectEqualStrings(" ", s.textAt(0, 0));
    try testing.expectEqualStrings("\u{6587}", s.textAt(1, 0));
    try testing.expect(s.readCell(2, 0).?.isTail());
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try checkInvariants(&s);
}

test "a wide grapheme with one column left becomes a blank" {
    var s = try made(3, 1);
    defer s.deinit(testing.allocator);

    try s.write(2, 0, "\u{4e2d}", .{ .bold = true }, .none);
    const c = s.readCell(2, 0).?;
    try testing.expectEqualStrings(" ", s.textAt(2, 0));
    try testing.expect(c.style.bold);
    try checkInvariants(&s);
}

test "a caller's tail is taken as a blank" {
    var s = try made(3, 1);
    defer s.deinit(testing.allocator);
    s.writeCell(1, 0, .{ .text = .inlined("x"), .shape = .{ .kind = .spacer_tail } });
    try testing.expectEqualStrings(" ", s.textAt(1, 0));
    try checkInvariants(&s);
}

test "a control character is not something a cell holds" {
    var s = try made(4, 1);
    defer s.deinit(testing.allocator);
    try s.write(0, 0, "\n", .{}, .none);
    try s.write(1, 0, "\x1b", .{}, .none);
    try s.write(2, 0, "\x7f", .{}, .none);
    try testing.expect(!s.damage.any());
}

test "a fill covers only the rectangle and clips to the grid" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);

    s.fill(.{ .col = 1, .row = 1, .cols = 3, .rows = 2 }, .blank(.{ .bg = .ansi(.blue) }));
    try testing.expect(s.readCell(0, 1).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(3, 2).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(4, 2).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 3).?.eql(.blank(.{})));

    s.fill(.{ .col = 4, .row = 3, .cols = 99, .rows = 99 }, .blank(.{ .bold = true }));
    try testing.expect(s.readCell(5, 3).?.style.bold);
    try checkInvariants(&s);
}

test "clear puts every cell back and damages only what it moved" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);

    try s.write(2, 1, "x", .{}, .none);
    s.damage.clear();
    s.clear();
    try testing.expectEqual(@as(usize, 1), s.damage.count());
    try testing.expectEqual(@import("damage.zig").Span{ .first = 2, .last = 2 }, s.damage.row(1).?);
    for (s.cells) |c| try testing.expect(c.eql(.blank(.{})));
}

test "a scroll up moves the rows and blanks what it vacated" {
    var s = try made(3, 4);
    defer s.deinit(testing.allocator);

    for (0..4) |r| try s.write(0, @intCast(r), &.{'a' + @as(u8, @intCast(r))}, .{}, .none);
    s.scroll(.fromSize(s.size), 1);
    try testing.expectEqualStrings("b", s.textAt(0, 0));
    try testing.expectEqualStrings("c", s.textAt(0, 1));
    try testing.expectEqualStrings("d", s.textAt(0, 2));
    try testing.expectEqualStrings(" ", s.textAt(0, 3));
    try checkInvariants(&s);
}

test "a scroll down moves the rows the other way" {
    var s = try made(3, 4);
    defer s.deinit(testing.allocator);

    for (0..4) |r| try s.write(0, @intCast(r), &.{'a' + @as(u8, @intCast(r))}, .{}, .none);
    s.scroll(.fromSize(s.size), -2);
    try testing.expectEqualStrings(" ", s.textAt(0, 0));
    try testing.expectEqualStrings(" ", s.textAt(0, 1));
    try testing.expectEqualStrings("a", s.textAt(0, 2));
    try testing.expectEqualStrings("b", s.textAt(0, 3));
    try checkInvariants(&s);
}

test "a scroll further than the rectangle is tall blanks it" {
    var s = try made(3, 3);
    defer s.deinit(testing.allocator);
    try s.write(0, 0, "a", .{}, .none);
    s.scroll(.fromSize(s.size), 9);
    for (s.cells) |c| try testing.expect(c.eql(.blank(.{})));
}

test "a scroll that cuts a wide grapheme in half leaves two blanks" {
    var s = try made(6, 2);
    defer s.deinit(testing.allocator);

    // A wide grapheme straddling the rectangle's left edge on the row the
    // scroll brings up.
    try s.write(1, 1, "\u{4e2d}", .{}, .none);
    s.scroll(.{ .col = 2, .row = 0, .cols = 4, .rows = 2 }, 1);
    try checkInvariants(&s);
}

test "a resize keeps what still fits and damages everything" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);

    try s.write(0, 0, "a", .{}, .none);
    try s.write(3, 1, "b", .{}, .none);
    try s.resize(testing.allocator, .{ .cols = 6, .rows = 3 });
    try testing.expectEqualStrings("a", s.textAt(0, 0));
    try testing.expectEqualStrings("b", s.textAt(3, 1));
    try testing.expect(s.readCell(5, 2).?.eql(.blank(.{})));
    try testing.expectEqual(@as(usize, 3), s.damage.count());
    try checkInvariants(&s);
}

test "a resize that cuts a wide grapheme off the right edge blanks it" {
    var s = try made(6, 1);
    defer s.deinit(testing.allocator);

    try s.write(3, 0, "\u{4e2d}", .{}, .none);
    try s.resize(testing.allocator, .{ .cols = 4, .rows = 1 });
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try checkInvariants(&s);
}

test "a resize puts the cursor back inside" {
    var s = try made(10, 10);
    defer s.deinit(testing.allocator);
    s.cursor = .{ .col = 9, .row = 9, .visible = true };
    try s.resize(testing.allocator, .{ .cols = 4, .rows = 3 });
    try testing.expectEqual(@as(u16, 3), s.cursor.col);
    try testing.expectEqual(@as(u16, 2), s.cursor.row);
}

test "a long grapheme is pooled and read back through the screen" {
    var s = try made(4, 1);
    defer s.deinit(testing.allocator);

    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try s.write(0, 0, family, .{}, .none);
    const c = s.readCell(0, 0).?;
    try testing.expect(c.text.isPooled());
    try testing.expectEqualStrings(family, s.textAt(0, 0));
    try checkInvariants(&s);
}

test "a link is interned and reaches the cell" {
    var s = try made(4, 1);
    defer s.deinit(testing.allocator);

    const l = try s.link(testing.allocator, "https://ziglang.org", "id=1");
    try s.write(0, 0, "z", .{}, l);
    try testing.expectEqual(l, s.readCell(0, 0).?.link);
    try testing.expectEqualStrings("id=1", s.target(l).?.params);
    try checkInvariants(&s);
}

test "the screen survives every allocation failing in turn" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var s: Screen = try .init(gpa, .{ .cols = 8, .rows = 4 });
            defer s.deinit(gpa);
            s.method = .unicode;
            _ = try s.intern(gpa, "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}");
            _ = try s.link(gpa, "https://ziglang.org", "id=1");
            try s.write(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{}, .none);
            try s.resize(gpa, .{ .cols = 12, .rows = 6 });
            try s.resize(gpa, .{ .cols = 4, .rows = 2 });
        }
    }.run, .{});
}

test "compacting the pool keeps what is on screen and drops what is not" {
    var s = try made(8, 2);
    defer s.deinit(testing.allocator);

    var buf: [24]u8 = undefined;
    for (0..64) |i| {
        const long = try std.fmt.bufPrint(&buf, "\u{1f468}\u{200d}{d:0>4}", .{i});
        try s.write(0, 0, long, .{}, .none);
        _ = try s.link(testing.allocator, long, "");
    }
    const kept = "\u{1f468}\u{200d}0063";
    try testing.expectEqualStrings(kept, s.textAt(0, 0));
    try testing.expect(s.graphemes.len() > kept.len);
    try testing.expectEqual(@as(usize, 64), s.links.count());

    try s.compactPool(testing.allocator);
    try testing.expectEqualStrings(kept, s.textAt(0, 0));
    try testing.expectEqual(@as(usize, kept.len), s.graphemes.len());
    try testing.expectEqual(@as(usize, 0), s.links.count());
    try checkInvariants(&s);
}

test "compacting keeps the links cells still point at" {
    var s = try made(8, 1);
    defer s.deinit(testing.allocator);

    const stale = try s.link(testing.allocator, "https://example.invalid", "id=0");
    _ = stale;
    const live = try s.link(testing.allocator, "https://ziglang.org", "id=1");
    try s.write(0, 0, "z", .{}, live);
    try testing.expectEqual(@as(usize, 2), s.links.count());

    try s.compactPool(testing.allocator);
    try testing.expectEqual(@as(usize, 1), s.links.count());
    const now = s.readCell(0, 0).?.link;
    try testing.expectEqualStrings("https://ziglang.org", s.target(now).?.uri);
    try testing.expectEqualStrings("id=1", s.target(now).?.params);
}

test "a resize rebuilds the pool rather than growing it forever" {
    var s = try made(4, 1);
    defer s.deinit(testing.allocator);

    var buf: [24]u8 = undefined;
    for (0..32) |i| {
        const long = try std.fmt.bufPrint(&buf, "\u{1f468}\u{200d}{d:0>4}", .{i});
        try s.write(0, 0, long, .{}, .none);
    }
    const before = s.graphemes.len();
    try s.resize(testing.allocator, .{ .cols = 6, .rows = 2 });
    try testing.expect(s.graphemes.len() < before);
    try testing.expectEqualStrings("\u{1f468}\u{200d}0031", s.textAt(0, 0));
}
