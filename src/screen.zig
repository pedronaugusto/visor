//! The grid: cells, the bytes they point at, and what changed since the last
//! frame.
//!
//! One allocator, taken at `init`. After that, `writeCell`, `fill`, `clear`
//! and `scroll` never allocate; `write` and `intern` allocate only when a
//! grapheme is longer than the six bytes a cell holds inline and has not
//! been seen before. Resize allocates. Nothing else does.
//!
//! The grid keeps its own invariants rather than trusting a caller to. A wide
//! grapheme is a head and a tail, always adjacent and always in that order;
//! overwriting either end repairs the other; a wide grapheme with one column
//! left in the row becomes a blank rather than something the terminal would
//! wrap. A grapheme drawn at a scale is a head and a block of tails, as many
//! rows tall as the scale and as many columns wide as the scale times its
//! width; writing into any cell of the block clears the whole of it, which is
//! what a terminal does. The widths across a row therefore always sum to the
//! width of the row, which is what makes the renderer's cursor arithmetic
//! provable.
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

        // A wide grapheme or a block that used to have room may not any
        // more, and a block may have lost its lower rows.
        if (size.rows > 0) s.heal(0, size.rows - 1);
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

    /// One cell already owned by this screen, clipped and damage marked.
    ///
    /// A cell two columns wide also writes its tail, and one drawn at a
    /// scale writes its whole block of tails; whatever any of them covered is
    /// repaired first, so a wide grapheme or a block that loses a cell loses
    /// all of it and never leaves an orphan. A wide grapheme with only the
    /// last column left becomes a blank, because a terminal asked to draw it
    /// there would wrap it onto the next row; a block that does not fit
    /// becomes a blank too. A cell handed in as a tail is taken as a blank:
    /// tails are the grid's own bookkeeping.
    pub fn writeOwnedCell(s: *Screen, col: u16, row: u16, c: Cell) void {
        if (col >= s.size.cols or row >= s.size.rows) return;
        const i = s.index(col, row);

        var put = c;
        if (put.shape.kind == .spacer_tail) put = .blank(c.style);
        if (put.shape.kind == .spacer_head) put.shape.scale = 0;
        if (put.shape.kind == .wide and put.shape.scale <= 1 and col + 1 >= s.size.cols) {
            // There is one column left and the grapheme wants two. The cell
            // is a spacer, not a space: the diff has to be able to tell it
            // from something the caller asked for.
            put = .blank(put.style);
            put.shape.kind = .spacer_head;
        }
        if (col + put.width() > s.size.cols or row + put.rows() > s.size.rows) {
            put = .blank(put.style);
        }

        // The overwhelmingly common write replaces one ordinary cell with
        // another. Neither side can own a tail, so there is no block to
        // detach or rebuild.
        if (put.shape.kind == .narrow and put.rows() == 1 and
            s.cells[i].shape.kind == .narrow and s.cells[i].rows() == 1)
        {
            if (s.cells[i].eql(put)) return;
            s.cells[i] = put;
            s.damage.mark(col, row);
            return;
        }

        const span = put.width();
        const tall = put.rows();
        var dr: u16 = 0;
        while (dr < tall) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span) : (dc += 1) s.detach(col + dc, row + dr);
        }
        s.place(i, put);
        var tail = put;
        tail.shape.kind = .spacer_tail;
        dr = 0;
        while (dr < tall) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span) : (dc += 1) {
                if (dr == 0 and dc == 0) continue;
                s.place(s.index(col + dc, row + dr), tail);
            }
        }
    }

    /// Copies a cell from another screen, re-interning every owned value.
    pub fn copyCell(s: *Screen, source: *const Screen, col: u16, row: u16, c: Cell) Allocator.Error!void {
        var put = c;
        if (c.text.isPooled()) put.text = try s.graphemes.intern(s.gpa, source.graphemes.slice(&c.text));
        if (source.links.get(c.link)) |link_target| {
            put.link = try s.links.intern(s.gpa, link_target.uri, link_target.params);
        } else {
            put.link = .none;
        }
        s.writeOwnedCell(col, row, put);
    }

    /// A grapheme measured, placed, and its tail written if it is wide.
    ///
    /// Allocates only when the grapheme is longer than six bytes and the
    /// screen has not seen it before. A grapheme that measures zero columns,
    /// and one that is or begins with a control character, is not written:
    /// neither is something a terminal would put in a cell. Bytes that are
    /// not UTF-8 are written as the replacement character, which is what a
    /// terminal would have shown for them, so the grid never holds bytes the
    /// terminal would read differently from the way they were measured.
    pub fn write(
        s: *Screen,
        col: u16,
        row: u16,
        text: []const u8,
        style: Style,
        to: Link,
    ) Allocator.Error!void {
        const grapheme = valid(text);
        if (grapheme.len == 0) return;
        if (grapheme[0] < 0x20 or grapheme[0] == 0x7f) return;
        const ascii = grapheme.len == 1 and grapheme[0] < 0x80;
        const w = if (ascii) 1 else textmod.graphemeWidth(grapheme, s.method);
        if (w == 0) return;
        const t = try s.graphemes.intern(s.gpa, grapheme);
        s.writeOwnedCell(col, row, .{
            .text = t,
            .style = cellmod.canonical(style),
            .link = to,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                // Worked out once, here, and read by the drift rule every
                // frame after: re-measuring a row costs as much as drawing
                // one.
                .drift = if (ascii) false else textmod.disagrees(grapheme),
            },
        });
    }

    /// A grapheme drawn `scale` cells tall and `scale` times its width
    /// across, through the text sizing protocol, for a terminal that has it.
    ///
    /// The block has to fit inside the grid: when it does not, nothing is
    /// written and the answer is false. A scale of zero or one is `write`.
    /// On a terminal without the protocol the renderer draws the grapheme at
    /// its own size and the rest of the block blank.
    pub fn writeScaled(
        s: *Screen,
        col: u16,
        row: u16,
        text: []const u8,
        style: Style,
        to: Link,
        scale: u3,
    ) Allocator.Error!bool {
        if (scale <= 1) {
            try s.write(col, row, text, style, to);
            return true;
        }
        const grapheme = valid(text);
        if (grapheme.len == 0) return false;
        if (grapheme[0] < 0x20 or grapheme[0] == 0x7f) return false;
        const ascii = grapheme.len == 1 and grapheme[0] < 0x80;
        const w = if (ascii) 1 else textmod.graphemeWidth(grapheme, s.method);
        if (w == 0) return false;
        if (@as(u32, col) + @as(u32, w) * scale > s.size.cols) return false;
        if (@as(u32, row) + scale > s.size.rows) return false;
        const t = try s.graphemes.intern(s.gpa, grapheme);
        s.writeOwnedCell(col, row, .{
            .text = t,
            .style = cellmod.canonical(style),
            .link = to,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                .drift = if (ascii) false else textmod.disagrees(grapheme),
                .scale = scale,
            },
        });
        return true;
    }

    /// A grapheme as it may go in a cell: itself when it is UTF-8, and the
    /// replacement character when it is not.
    fn valid(grapheme: []const u8) []const u8 {
        if (grapheme.len == 1 and grapheme[0] < 0x80) return grapheme;
        return if (std.unicode.utf8ValidateSlice(grapheme)) grapheme else "\u{fffd}";
    }

    /// A rectangle of one cell.
    pub fn fill(s: *Screen, rect: Rect, c: Cell) void {
        const r = rect.intersect(.fromSize(s.size));
        if (r.isEmpty()) return;
        var y = r.row;
        while (y < r.bottom()) : (y += 1) {
            var col = r.col;
            while (col < r.right()) : (col += 1) s.writeOwnedCell(col, @intCast(y), c);
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

        // A wide grapheme cut by the rectangle's side, and a block cut by
        // any of its edges or torn by the rows moving out from under its
        // head, are cleared; a block reaches at most six rows past the
        // rectangle, so that is how far the sweep goes.
        s.heal(r.row -| max_reach, @intCast(@min(r.bottom() - 1 + max_reach, s.size.rows - 1)));
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
    /// The cell is taken by pointer because a grapheme of six bytes or
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

    /// The head whose grapheme covers a tail: the wide grapheme to its left,
    /// or the scaled one above and to its left. Null for a cell that is not
    /// a tail, or for a tail nothing covers, which the grid never keeps.
    pub fn headOf(s: *const Screen, col: u16, row_n: u16) ?Point {
        if (col >= s.size.cols or row_n >= s.size.rows) return null;
        if (!s.cells[s.index(col, row_n)].isTail()) return null;
        // On the same row, the nearest cell that is not a tail is the only
        // candidate: heads never overlap.
        var c = col;
        while (c > 0) {
            c -= 1;
            const h = s.cells[s.index(c, row_n)];
            if (h.isTail()) continue;
            if (c + h.width() > col) return .{ .col = c, .row = row_n };
            break;
        }
        // Above it, a head drawn at a scale whose block reaches this far.
        var r = row_n;
        var up: u16 = 0;
        while (r > 0 and up < max_reach) : (up += 1) {
            r -= 1;
            c = col + 1;
            var back: u16 = 0;
            while (c > 0 and back < max_span) : (back += 1) {
                c -= 1;
                const h = s.cells[s.index(c, r)];
                if (h.isTail() or !h.isScaled()) continue;
                if (c + h.width() > col and r + h.rows() > row_n) return .{ .col = c, .row = r };
            }
        }
        return null;
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

    /// Clears the wide grapheme or the block a cell is part of, if it is part
    /// of one, so that the cell can be written over without leaving an
    /// orphan.
    fn detach(s: *Screen, col: u16, row_n: u16) void {
        if (col >= s.size.cols or row_n >= s.size.rows) return;
        const c = s.cells[s.index(col, row_n)];
        if (c.isTail()) {
            if (s.headOf(col, row_n)) |head| {
                s.clearBlock(head.col, head.row);
            } else {
                s.place(s.index(col, row_n), .blank(c.style));
            }
        } else if (c.width() > 1 or c.rows() > 1) {
            s.clearBlock(col, row_n);
        }
    }

    /// Every cell a head covers, itself included, back to a blank in the
    /// style it had.
    fn clearBlock(s: *Screen, col: u16, row_n: u16) void {
        const head = s.cells[s.index(col, row_n)];
        const span = head.width();
        const tall = head.rows();
        var dr: u16 = 0;
        while (dr < tall and row_n + dr < s.size.rows) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span and col + dc < s.size.cols) : (dc += 1) {
                const i = s.index(col + dc, row_n + dr);
                s.place(i, .blank(s.cells[i].style));
            }
        }
    }

    /// Puts rows `top` through `bottom` back inside the invariants after
    /// their cells moved without their neighbours: a head whose block is no
    /// longer whole is cleared, and a tail nothing covers is blanked.
    fn heal(s: *Screen, top: u16, bottom: u16) void {
        var row_n = top;
        while (row_n <= bottom and row_n < s.size.rows) : (row_n += 1) {
            var col: u16 = 0;
            while (col < s.size.cols) : (col += 1) {
                const i = s.index(col, row_n);
                const c = s.cells[i];
                if (c.isTail()) {
                    if (s.headOf(col, row_n) == null) s.place(i, .blank(c.style));
                    continue;
                }
                if (c.width() == 1 and c.rows() == 1) continue;
                if (c.shape.kind == .wide and !c.isScaled() and col + 1 >= s.size.cols) {
                    // The one column left is a spacer, as `writeOwnedCell`
                    // would have made it.
                    var spacer: Cell = .blank(c.style);
                    spacer.shape.kind = .spacer_head;
                    s.place(i, spacer);
                    continue;
                }
                if (!s.blockWhole(col, row_n, c)) s.clearBlock(col, row_n);
            }
        }
    }

    /// Whether every cell a head covers is a tail of its own scale, inside
    /// the grid.
    fn blockWhole(s: *const Screen, col: u16, row_n: u16, head: Cell) bool {
        const span = head.width();
        const tall = head.rows();
        if (col + span > s.size.cols or row_n + tall > s.size.rows) return false;
        var dr: u16 = 0;
        while (dr < tall) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span) : (dc += 1) {
                if (dr == 0 and dc == 0) continue;
                const t = s.cells[s.index(col + dc, row_n + dr)];
                if (!t.isTail() or t.shape.scale != head.shape.scale) return false;
            }
        }
        return true;
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

/// The most rows a block reaches below its head: the largest scale, less
/// the head's own row.
const max_reach = 6;
/// The most columns a block spans: the largest scale times a wide glyph.
const max_span = 14;

const testing = std.testing;

fn made(cols: u16, rows: u16) !Screen {
    var s: Screen = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    s.method = .unicode;
    return s;
}

/// Every invariant the grid promises, checked over the whole of it.
fn checkInvariants(s: *const Screen) !void {
    for (0..s.size.rows) |r| {
        var col: u16 = 0;
        while (col < s.size.cols) {
            const c = s.cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape._reserved == 0);
            // Every grapheme is inside the pool and every link inside the
            // table.
            if (c.text.isPooled()) {
                const off = c.text.offset().?;
                try testing.expect(off + c.text.length() <= s.graphemes.len());
            }
            if (c.link.index()) |li| try testing.expect(li < s.links.count());

            if (c.isTail()) {
                // A tail never stands alone: something covers it.
                try testing.expect(s.headOf(col, @intCast(r)) != null);
                col += 1;
                continue;
            }
            // A head's block is inside the grid and made of its own tails,
            // so the columns of a row always add up to the row.
            const span = c.width();
            try testing.expect(col + span <= s.size.cols);
            try testing.expect(r + c.rows() <= s.size.rows);
            for (0..c.rows()) |dr| {
                for (0..span) |dc| {
                    if (dr == 0 and dc == 0) continue;
                    const t = s.cells[s.index(@intCast(col + dc), @intCast(r + dr))];
                    try testing.expect(t.isTail());
                    try testing.expectEqual(c.shape.scale, t.shape.scale);
                }
            }
            col += span;
        }
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
    s.writeOwnedCell(4, 0, .blank(.{ .bold = true }));
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

test "bytes that are not UTF-8 go in as the replacement character" {
    var s: Screen = try .init(testing.allocator, .{ .cols = 4, .rows = 1 });
    defer s.deinit(testing.allocator);
    try s.write(0, 0, "\xff", .{}, .none);
    try s.write(1, 0, "\xe4\xb8", .{}, .none);
    try testing.expectEqualStrings("\u{fffd}", s.textAt(0, 0));
    try testing.expectEqualStrings("\u{fffd}", s.textAt(1, 0));
    try testing.expect(try s.writeScaled(2, 0, "\xc3", .{}, .none, 1));
    try testing.expectEqualStrings("\u{fffd}", s.textAt(2, 0));
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
    s.writeOwnedCell(1, 0, .{ .text = .inlined("x"), .shape = .{ .kind = .spacer_tail } });
    try testing.expectEqualStrings(" ", s.textAt(1, 0));
    try checkInvariants(&s);
}

test "a scaled grapheme is a head and a block of tails" {
    var s = try made(8, 4);
    defer s.deinit(testing.allocator);

    try testing.expect(try s.writeScaled(1, 1, "\u{4e2d}", .{ .bold = true }, .none, 2));
    const head = s.readCell(1, 1).?;
    try testing.expectEqual(Cell.Kind.wide, head.shape.kind);
    try testing.expectEqual(@as(u3, 2), head.shape.scale);
    try testing.expectEqual(@as(u4, 4), head.width());
    for (1..5) |col| {
        for (1..3) |row| {
            if (col == 1 and row == 1) continue;
            const tail = s.readCell(@intCast(col), @intCast(row)).?;
            try testing.expect(tail.isTail());
            try testing.expectEqual(@as(u3, 2), tail.shape.scale);
            try testing.expect(tail.style.bold);
            try testing.expectEqual(geom.Point{ .col = 1, .row = 1 }, s.headOf(@intCast(col), @intCast(row)).?);
        }
    }
    try testing.expect(s.readCell(5, 1).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 3).?.eql(.blank(.{})));
    try checkInvariants(&s);
}

test "a block that would not fit is not written" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);
    try testing.expect(!try s.writeScaled(3, 0, "a", .{}, .none, 2));
    try testing.expect(!try s.writeScaled(0, 1, "a", .{}, .none, 2));
    try testing.expect(!s.damage.any());
    // Through the owned path, it is a blank rather than half a block.
    s.writeOwnedCell(3, 0, .init(.{ .text = .inlined("a"), .shape = .{ .scale = 2 } }));
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try checkInvariants(&s);
}

test "writing into any cell of a block clears the whole block" {
    var s = try made(8, 4);
    defer s.deinit(testing.allocator);

    for ([_]geom.Point{
        .{ .col = 0, .row = 0 }, .{ .col = 2, .row = 0 }, .{ .col = 0, .row = 2 }, .{ .col = 2, .row = 2 },
    }) |at| {
        try testing.expect(try s.writeScaled(0, 0, "a", .{ .bold = true }, .none, 3));
        try s.write(at.col, at.row, "x", .{}, .none);
        try testing.expectEqualStrings("x", s.textAt(at.col, at.row));
        for (0..3) |col| {
            for (0..3) |row| {
                if (col == at.col and row == at.row) continue;
                const c = s.readCell(@intCast(col), @intCast(row)).?;
                try testing.expectEqualStrings(" ", s.textAt(@intCast(col), @intCast(row)));
                try testing.expect(!c.isTail());
                try testing.expect(c.style.bold);
            }
        }
        try checkInvariants(&s);
    }
}

test "a block written over a wide grapheme and another block takes both" {
    var s = try made(8, 3);
    defer s.deinit(testing.allocator);
    try s.write(0, 0, "\u{4e2d}", .{}, .none);
    try testing.expect(try s.writeScaled(4, 1, "b", .{}, .none, 2));
    try testing.expect(try s.writeScaled(1, 0, "a", .{}, .none, 2));
    try testing.expectEqualStrings(" ", s.textAt(0, 0));
    try testing.expectEqualStrings("a", s.textAt(1, 0));
    try testing.expectEqualStrings("b", s.textAt(4, 1));
    // The second block still stands: the first did not reach it.
    try testing.expect(s.readCell(5, 2).?.isTail());
    try testing.expect(try s.writeScaled(3, 0, "c", .{}, .none, 2));
    try testing.expectEqual(geom.Point{ .col = 3, .row = 0 }, s.headOf(4, 1).?);
    try testing.expectEqualStrings(" ", s.textAt(5, 1));
    try testing.expect(!s.readCell(5, 1).?.isTail());
    try testing.expect(!s.readCell(4, 2).?.isTail());
    try testing.expect(!s.readCell(5, 2).?.isTail());
    try checkInvariants(&s);
}

test "a scroll that tears a block clears what is left of it" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);
    try testing.expect(try s.writeScaled(1, 1, "a", .{}, .none, 2));
    // The head's row moves up and the tails' row does not.
    s.scroll(.{ .col = 0, .row = 0, .cols = 6, .rows = 2 }, 1);
    for (s.cells) |c| try testing.expect(!c.isTail() and !c.isScaled());
    try checkInvariants(&s);

    // And a block that moves whole moves whole.
    try testing.expect(try s.writeScaled(1, 2, "a", .{}, .none, 2));
    s.scroll(.fromSize(s.size), 1);
    try testing.expectEqualStrings("a", s.textAt(1, 1));
    try testing.expect(s.readCell(2, 2).?.isTail());
    try checkInvariants(&s);
}

test "a resize that cuts a block off blanks it" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);
    try testing.expect(try s.writeScaled(2, 1, "a", .{}, .none, 3));
    try s.resize(testing.allocator, .{ .cols = 6, .rows = 3 });
    for (s.cells) |c| try testing.expect(!c.isTail() and !c.isScaled());
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

test "copying a pooled cell between screens keeps its source text" {
    var a = try made(2, 1);
    defer a.deinit(testing.allocator);
    var b = try made(2, 1);
    defer b.deinit(testing.allocator);

    try a.write(0, 0, "source-long", .{}, .none);
    try b.write(1, 0, "target-long", .{}, .none);
    try b.copyCell(&a, 0, 0, a.readCell(0, 0).?);
    try testing.expectEqualStrings("source-long", b.textAt(0, 0));
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
            try s.compactPool(gpa);
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
