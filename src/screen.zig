//! The grid: cells, the bytes they point at, and what changed since the last
//! frame.
//!
//! One allocator, taken at `init`. After that, `writeOwnedCell`, `fill`, `clear`
//! and `scroll` never allocate; `write` and `intern` allocate only when a
//! grapheme is longer than the six bytes a cell holds inline and has not
//! been seen before. Interning new links, compaction and resize can allocate;
//! owned-copy helpers allocate through the copy's allocator.
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
//! What this file will never hold: layout, widgets, pictures, a previous
//! frame, or a single byte written to a terminal. The pictures are `Layers`,
//! which a program keeps beside its screen and hands the renderer with it.
//! The previous frame belongs to the renderer, which is the only thing that knows what the terminal was shown.

const std = @import("std");
const builtin = @import("builtin");
const morse = @import("dependencies.zig").morse;

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const pool = @import("pool.zig");
const textmod = @import("text.zig");
const damage_mod = @import("damage.zig");
const window = @import("window.zig");
const Damage = damage_mod.Damage;

const Allocator = std.mem.Allocator;
const Cell = cellmod.Cell;
const StoredCell = cellmod.internal.StoredCell;
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

// Cooperation inside the package; this namespace is not exported by visor.
pub const internal = struct {
    pub fn printable(text: []const u8, method: textmod.Method) Screen.PrintableError!?[]const u8 {
        return Screen.printable(text, method);
    }
    pub fn placeCell(s: *Screen, col: u16, row_n: u16, checked: Cell) void {
        s.placeOwnedCell(col, row_n, cellmod.internal.store(checked));
    }
    pub fn row(s: *const Screen, n: u16) []const StoredCell {
        if (n >= s.dimensions().rows) return &.{};
        return s.own_cells[@as(usize, n) * s.dimensions().cols ..][0..s.dimensions().cols];
    }
    pub fn rowMut(s: *Screen, n: u16) []StoredCell {
        if (n >= s.dimensions().rows) return &.{};
        return s.own_cells[@as(usize, n) * s.dimensions().cols ..][0..s.dimensions().cols];
    }
    pub fn textOf(s: *const Screen, c: *const StoredCell) []const u8 {
        if (!c.text.isPooled()) return c.text.inlineSlice().?;
        return s.graphemes.bytes.items[c.text.offset().?..][0..c.text.length()];
    }
    pub fn target(s: *const Screen, link: @TypeOf(@as(StoredCell, .{}).link)) ?pool.Target {
        return s.links.get(link);
    }

    pub fn resizeKeepingLink(s: *Screen, size: Size, link: *Link) Allocator.Error!void {
        try s.resizeKeepingLink(size, link);
    }
    /// One cluster of a stream as a terminal reads it: null for a control
    /// (C0, DEL or C1), the replacement character for bytes that are not
    /// UTF-8 or too long for the pool, and the bytes themselves otherwise.
    /// Width is the caller's: a terminal may have been told it.
    pub fn sanitized(text: []const u8) ?[]const u8 {
        if (text.len == 0) return null;
        const grapheme = Screen.valid(text);
        if (grapheme.len == 1 and grapheme[0] >= 0x20 and grapheme[0] < 0x7f) return grapheme;
        if (Screen.hasControl(grapheme)) return null;
        return grapheme;
    }
    /// `intern` for bytes the caller has already bounded by `pool.max_len`.
    pub fn internShort(s: *Screen, bytes: []const u8) Allocator.Error!Cell.Text {
        std.debug.assert(bytes.len <= pool.max_len);
        return s.internShort(bytes);
    }
};

/// The grid.
pub const window_api = window.WindowApi(@This());

pub const Screen = struct {
    /// A cell this screen refuses: `InvalidHandle` for a text or link
    /// handle that is stale, foreign or out of bounds, `InvalidCell` for a
    /// glyph or shape that does not describe one printable cluster here.
    pub const CellError = error{ InvalidHandle, InvalidCell };
    /// What drawing into a screen, or into a window of one, can fail with:
    /// `CellError`, and the allocation interning a new grapheme can need.
    pub const DrawError = Allocator.Error || CellError;
    /// A pooled handle this screen's pools did not issue, or one a
    /// compaction or resize has since invalidated.
    pub const HandleError = error{InvalidHandle};
    /// Text that is more than one cluster where one cell was asked for.
    pub const PrintableError = error{InvalidCell};
    /// What `intern` fails with: memory, or more than 65535 bytes.
    pub const InternError = Allocator.Error || error{TooLong};
    /// What `dupeTextOf` fails with.
    pub const DupeTextError = Allocator.Error || HandleError;

    /// What interning a link target can fail with.
    pub const LinkError = Allocator.Error || error{ ControlInText, TooLong };

    // Fields documented Private: belong to the owner; change geometry through resize.
    /// The current grid dimensions, copied rather than borrowed storage.
    pub fn dimensions(owner: *const Screen) Size {
        return owner.size;
    }

    /// Private: the allocator `init` was given, used by every operation this grid owns.
    gpa: Allocator,
    /// Private: how big the grid is.
    size: Size,
    /// Private: every cell, row by row.
    own_cells: []StoredCell,
    /// Private: the graphemes too long to live in a cell.
    graphemes: pool.Graphemes,
    /// Private: every OSC 8 target the cells point at.
    links: pool.Links,
    /// Private: the identity of this pair of pools, changed whenever they are replaced.
    pool_generation: u64 = 0,
    /// Private: which cells have changed since the last frame was written.
    damage: Damage,
    /// Where the cursor should end the frame.
    cursor: Cursor = .{},
    /// The shape the terminal should draw under the mouse, or null to leave
    /// it as the user set it.
    pointer: ?morse.PointerShape = null,
    /// How this screen measures text. The caller sets it from `Caps`; this
    /// package never guesses and never reads an environment variable.
    method: textmod.Method = .wcwidth,

    /// The grid, sized once. Everything after this writes into it.
    pub fn init(gpa: Allocator, size: Size) Allocator.Error!Screen {
        const cells = try gpa.alloc(StoredCell, size.area());
        errdefer gpa.free(cells);
        @memset(cells, .blank(.{}));
        var dmg: Damage = try .init(gpa, size.rows);
        errdefer dmg.deinit();
        return .{
            .gpa = gpa,
            .size = size,
            .own_cells = cells,
            .graphemes = .init(gpa),
            .links = .init(gpa),
            .pool_generation = pool.nextGeneration(),
            .damage = dmg,
        };
    }

    /// Gives the grid back.
    pub fn deinit(s: *Screen) void {
        const gpa = s.gpa;
        gpa.free(s.own_cells);
        s.graphemes.deinit();
        s.links.deinit();
        s.damage.deinit();
        s.* = undefined;
    }

    /// A new size, contents kept where they still fit, everything damaged.
    ///
    /// A different size compacts the pools; surviving cells keep their text
    /// and targets, with identities rewritten to name the new pools, and the
    /// next draw repaints every cell. The same size only damages the grid
    /// and keeps the pools. Borrowed slices must not be retained across
    /// resize.
    pub fn resize(s: *Screen, size: Size) Allocator.Error!void {
        try s.resizeKeepingLink(size, null);
    }

    fn resizeKeepingLink(s: *Screen, size: Size, retained: ?*Link) Allocator.Error!void {
        const gpa = s.gpa;
        if (std.meta.eql(s.dimensions(), size)) {
            s.damageAll();
            return;
        }
        // Prepare the grid and damage map before committing new pool
        // identities. Nothing fallible follows a successful preparation, so
        // any allocation failure preserves cells, pools, borrows and damage.
        const cells = try gpa.alloc(StoredCell, size.area());
        errdefer gpa.free(cells);
        @memset(cells, .blank(.{}));
        var damage = try Damage.init(gpa, size.rows);
        errdefer damage.deinit();
        const rows = @min(s.dimensions().rows, size.rows);
        const cols = @min(s.dimensions().cols, size.cols);
        for (0..rows) |r| {
            const from = s.own_cells[r * s.dimensions().cols ..][0..cols];
            @memcpy(cells[r * size.cols ..][0..cols], from);
        }
        // This view borrows only the new grid and damage map. Healing needs
        // geometry, never pools; it must finish before choosing the live roots.
        var resized: Screen = .{
            .gpa = gpa,
            .size = size,
            .own_cells = cells,
            .graphemes = .init(gpa),
            .links = .init(gpa),
            .damage = damage,
        };
        if (size.rows > 0) resized.heal(0, size.rows - 1);
        const prepared = try s.preparePools(cells, retained);
        s.commitPools(cells, prepared, retained);
        gpa.free(s.own_cells);
        s.own_cells = cells;
        s.damage.deinit();
        s.damage = resized.damage;
        s.size = size;
        // One cell and one damage span for every place on the new grid.
        std.debug.assert(s.own_cells.len == size.area());
        std.debug.assert(s.damage.rowCount() == size.rows);

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
    /// freed behind a live grid cell. Retained handles are refused after the
    /// sweep. The pools' identity changes, so the next draw repaints every
    /// cell: compact between bursts of new text, not every frame.
    pub fn compactPool(s: *Screen) Allocator.Error!void {
        try s.compactKeepingLink(null);
    }

    fn compactKeepingLink(s: *Screen, retained: ?*Link) Allocator.Error!void {
        const prepared = try s.preparePools(s.own_cells, retained);
        s.commitPools(s.own_cells, prepared, retained);
        s.damageAll();
    }

    const PreparedPools = struct {
        graphemes: pool.Graphemes,
        links: pool.Links,
        kept: @TypeOf(@as(StoredCell, .{}).link),
    };

    fn preparePools(s: *const Screen, cells: []const StoredCell, retained: ?*Link) Allocator.Error!PreparedPools {
        const gpa = s.gpa;
        var graphemes: pool.Graphemes = .init(gpa);
        errdefer graphemes.deinit();
        var links: pool.Links = .init(gpa);
        errdefer links.deinit();

        // Everything the grid still shows, into the new pools. Nothing is
        // written back until this has succeeded, so a failure here leaves
        // the screen exactly as it was.
        for (cells) |*c| {
            if (c.text.isPooled()) _ = try graphemes.intern(internal.textOf(s, c));
            if (internal.target(s, c.link)) |t| _ = try links.intern(t.uri, t.params);
        }
        // The emulator's open OSC 8 target is live even before any cell
        // uses it. Prepare its new handle with the grid's, so neither an
        // allocation failure nor the commit can leave it naming an old pool.
        const kept: @TypeOf(@as(StoredCell, .{}).link) = if (retained) |slot| kept: {
            if (slot.* == .none) break :kept .none;
            const link_target = s.target(slot.*) orelse @panic("invalid retained link");
            break :kept try links.intern(link_target.uri, link_target.params);
        } else .none;
        return .{ .graphemes = graphemes, .links = links, .kept = kept };
    }

    fn commitPools(s: *Screen, cells: []StoredCell, prepared: PreparedPools, retained: ?*Link) void {
        var graphemes = prepared.graphemes;
        var links = prepared.links;
        // And now the cells, which cannot fail: everything they name is
        // already in the new pools.
        for (cells) |*c| {
            if (c.text.isPooled()) {
                // unreachable: preparePools interned it, so this finds it and allocates nothing
                c.text = graphemes.intern(internal.textOf(s, c)) catch unreachable;
            }
            if (internal.target(s, c.link)) |t| {
                // unreachable: preparePools interned it, so this finds it and allocates nothing
                c.link = links.intern(t.uri, t.params) catch unreachable;
            }
        }
        s.graphemes.deinit();
        s.links.deinit();
        s.graphemes = graphemes;
        s.links = links;
        s.pool_generation = pool.nextGeneration();
        if (retained) |slot| slot.* = cellmod.internal.exportLink(prepared.kept, s.pool_generation);
    }

    /// The cell at a place, or null outside the grid.
    pub fn readCell(s: *const Screen, col: u16, row: u16) ?Cell {
        return s.readCheckedCell(col, row);
    }

    inline fn readCheckedCell(s: *const Screen, col: u16, row: u16) ?Cell {
        if (col >= s.dimensions().cols or row >= s.dimensions().rows) return null;
        return cellmod.internal.exportCell(&s.own_cells[s.index(col, row)], s.pool_generation);
    }

    /// Changed positions between two screens, in row order, without exporting
    /// cells. Equality is Cell.eql: inline text compares by value; pooled text
    /// and links compare handles and issuing pool generations, even when their
    /// contents match across pools. A position present in only one screen is
    /// changed. Cursor, damage and width method are not compared.
    /// The iterator borrows both screens; do not change, compact, resize or
    /// destroy either screen until iteration ends. Returned points are copies.
    pub fn diff(s: *const Screen, other: *const Screen) Diff {
        return .{ .a = s, .b = other };
    }

    pub const Diff = struct {
        /// Private: the first screen compared.
        a: *const Screen,
        /// Private: the second screen compared.
        b: *const Screen,
        /// Private: the row the walk is on.
        own_row: u16 = 0,
        /// Private: the column the walk is on.
        col: u16 = 0,

        pub fn next(d: *Diff) ?Point {
            const rows = @max(d.a.dimensions().rows, d.b.dimensions().rows);
            while (d.own_row < rows) {
                const a = d.a.rowAt(d.own_row);
                const b = d.b.rowAt(d.own_row);
                var columns: Row.Diff = .{ .a = a, .b = b, .col = d.col };
                if (columns.next()) |col| {
                    d.col = @intCast(col + 1);
                    return .{ .col = @intCast(col), .row = d.own_row };
                }
                d.col = 0;
                d.own_row += 1;
            }
            return null;
        }
    };

    /// One cell checked against this screen, clipped and damage marked.
    /// Stale or foreign text and link handles return `InvalidHandle` before any change.
    /// Malformed glyphs and shapes return `InvalidCell`.
    ///
    /// A cell two columns wide also writes its tail, and one drawn at a
    /// scale writes its whole block of tails; whatever any of them covered is
    /// repaired first, so a wide grapheme or a block that loses a cell loses
    /// all of it and never leaves an orphan. A wide grapheme with only the
    /// last column left becomes a blank, because a terminal asked to draw it
    /// there would wrap it onto the next row; a block that does not fit
    /// becomes a blank too. A cell handed in as a tail is taken as a blank:
    /// tails are the grid's own bookkeeping.
    pub fn writeOwnedCell(s: *Screen, col: u16, row: u16, c: Cell) CellError!void {
        const checked = try s.cell(c);
        s.placeOwnedCell(col, row, cellmod.internal.store(checked));
    }

    /// Checks an imported value and canonicalizes its style and drift flag.
    /// InvalidCell means the bytes are not one printable cluster, the shape
    /// does not describe it in this screen's width method, or reserved bytes
    /// are set. InvalidHandle means a pool handle is stale, foreign or out of bounds.
    pub fn cell(s: *const Screen, c: Cell) CellError!Cell {
        const bytes = try s.checkedText(&c);
        return validateCell(c, bytes, s.method);
    }

    fn validateCell(c: Cell, bytes: []const u8, method: textmod.Method) error{InvalidCell}!Cell {
        try checkGlyph(bytes, method);
        if (c.shape.reserved != 0 or !std.mem.allEqual(u8, &c.reserved, 0)) return error.InvalidCell;
        if (!c.text.isPooled()) {
            if (c.text.generation() != 0 or !std.mem.allEqual(u8, c.text.buf[c.text.len..], 0)) return error.InvalidCell;
        } else if (c.text.length() <= Cell.Text.max_inline) return error.InvalidCell;
        if (c.shape.kind == .spacer_head) {
            if (!Cell.Text.eql(c.text, .space) or c.link != .none or c.shape.scale != 0 or c.shape.drift) return error.InvalidCell;
        } else if (c.isHead() and textmod.graphemeWidth(bytes, method) != c.glyphWidth()) return error.InvalidCell;
        var checked = c;
        checked.setStyle(c.style);
        if (c.shape.kind != .spacer_head) checked.shape.drift = textmod.disagrees(bytes);
        return checked;
    }

    fn checkedText(s: *const Screen, c: *const Cell) CellError![]const u8 {
        // Pool identity checks precede glyph checks even for malformed input.
        if (c.link != .none and s.target(c.link) == null) return error.InvalidHandle;
        if (!c.text.isPooled() and c.text.len > Cell.Text.max_inline) return error.InvalidCell;
        return s.textOf(c);
    }

    /// Imports a cell measured by another terminal. Pool handles are still
    /// checked. The caller guarantees one printable UTF-8 cluster, a valid
    /// shape and canonical text bytes; its width may differ from Screen.method.
    /// Used by terminal bridges that must retain the source terminal's width.
    pub fn writeOwnedCellUnchecked(s: *Screen, col: u16, row: u16, c: Cell) HandleError!void {
        _ = try s.textOf(&c);
        if (c.link != .none and s.target(c.link) == null) return error.InvalidHandle;
        s.placeOwnedCell(col, row, cellmod.internal.store(c));
    }

    /// Whether `bytes` are one cluster a terminal measuring by `method`
    /// draws in at least one column: UTF-8, no control (C0, DEL or C1), and
    /// not a cluster that takes no column, which is a different set of
    /// clusters under each method.
    fn checkGlyph(bytes: []const u8, method: textmod.Method) error{InvalidCell}!void {
        if (bytes.len == 1 and bytes[0] >= 0x20 and bytes[0] < 0x7f) return;
        if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidCell;
        if (hasControl(bytes)) return error.InvalidCell;
        var clusters = textmod.Graphemes.init(bytes);
        if ((clusters.next() orelse return error.InvalidCell).len != bytes.len or
            textmod.graphemeWidth(bytes, method) == 0) return error.InvalidCell;
    }

    fn hasControl(bytes: []const u8) bool {
        var codepoints = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        while (codepoints.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return true;
        return false;
    }

    /// What `write` puts in a cell for one cluster of the caller's text, or
    /// null for text a terminal would draw nothing for.
    ///
    /// Text is content, not a programmer's claim about a cell, so whatever
    /// it holds is drawn the way a terminal would or skipped: bytes that are
    /// not UTF-8, and a cluster too long for the pool to name, become the
    /// replacement character; a control (C0, DEL or C1) and a cluster that
    /// takes no column under `method` -- a combining mark that begins a
    /// segment, a zero-width space -- are skipped. Only text that is more
    /// than one cluster is the caller's mistake, and returns `InvalidCell`.
    fn printable(text: []const u8, method: textmod.Method) PrintableError!?[]const u8 {
        if (text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return null;
        const grapheme = valid(text);
        if (grapheme.len == 1 and grapheme[0] < 0x80) return grapheme;
        var clusters = textmod.Graphemes.init(grapheme);
        if (clusters.next().?.len != grapheme.len) return error.InvalidCell;
        // UTF-8 and one cluster by now, so a refusal is a control or no width.
        checkGlyph(grapheme, method) catch return null;
        return grapheme;
    }

    // The grid's own cells have already passed the handle checks.
    fn placeOwnedCell(s: *Screen, col: u16, row: u16, c: StoredCell) void {
        if (col >= s.dimensions().cols or row >= s.dimensions().rows) return;
        const i = s.index(col, row);

        var put = c;
        if (put.shape.kind == .spacer_tail) put = .blank(c.style);
        if (put.shape.kind == .spacer_head) put.shape.scale = 0;
        if (put.shape.kind == .wide and put.shape.scale <= 1 and col + 1 >= s.dimensions().cols) {
            // There is one column left and the grapheme wants two. The cell
            // is a spacer, not a space: the diff has to be able to tell it
            // from something the caller asked for.
            put = .blank(put.style);
            put.shape.kind = .spacer_head;
        }
        if (@as(u32, col) + put.width() > s.dimensions().cols or @as(u32, row) + put.rows() > s.dimensions().rows) {
            put = .blank(put.style);
        }

        // The overwhelmingly common write replaces one ordinary cell with
        // another. Neither side can own a tail, so there is no block to
        // detach or rebuild.
        if (put.shape.kind == .narrow and put.rows() == 1 and
            s.own_cells[i].shape.kind == .narrow and s.own_cells[i].rows() == 1)
        {
            if (s.own_cells[i].eql(put)) return;
            s.own_cells[i] = put;
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
    /// Stale handles or a cell belonging to a different source return `InvalidHandle`.
    pub fn copyCell(s: *Screen, source: *const Screen, col: u16, row: u16, c: Cell) DrawError!void {
        const checked = try source.cell(c);
        var put = try validateCell(checked, try source.textOf(&c), s.method);
        if (c.text.isPooled()) put.text = try s.internShort(try source.textOf(&c));
        if (source.target(c.link)) |link_target| {
            put.link = cellmod.internal.exportLink(try s.links.intern(link_target.uri, link_target.params), s.pool_generation);
        } else {
            put.link = .none;
        }
        s.placeOwnedCell(col, row, cellmod.internal.store(put));
    }

    /// A grapheme measured, placed, and its tail written if it is wide.
    ///
    /// Allocates only when the grapheme is longer than six bytes and the
    /// screen has not seen it before. Empty input, controls (C0, DEL and
    /// C1, the cluster that begins with one) and a cluster that takes no
    /// column by this screen's `method` are skipped: they are text a
    /// terminal draws nothing for. Bytes that are not UTF-8, and a cluster
    /// longer than the pool names (65535 bytes), are written as the
    /// replacement character, which is what a terminal would have shown for
    /// them, so the grid never holds bytes the terminal would read
    /// differently from the way they were measured. Text of more than one
    /// cluster returns InvalidCell before the grid changes.
    ///
    /// Measured by codepoint, a cluster of more than one codepoint that
    /// takes columns goes in the cells a terminal measuring that way gives
    /// it, one after another along the row (`textmod.Parts`), as far as the
    /// row reaches: the astronaut that is a woman, a joiner and a rocket is
    /// the woman and the joiner in two columns and the rocket in the next
    /// two, which is what such a terminal shows.
    pub fn write(
        s: *Screen,
        col: u16,
        row: u16,
        text: []const u8,
        style: Style,
        to: Link,
    ) DrawError!void {
        if (to != .none and s.target(to) == null) return error.InvalidHandle;
        const grapheme = (try printable(text, s.method)) orelse return;
        const ascii = grapheme.len == 1 and grapheme[0] < 0x80;
        if (!ascii and s.method == .wcwidth and !textmod.combinesOnly(grapheme)) {
            var parts: textmod.Parts = .init(grapheme);
            var at: u32 = col;
            while (parts.next()) |part| {
                if (part.cols == 0) continue;
                if (at >= s.dimensions().cols) break;
                try s.writeOne(@intCast(at), row, part.bytes, part.cols, style, to);
                at += part.cols;
            }
            return;
        }
        const w = if (ascii) 1 else textmod.graphemeWidth(grapheme, s.method);
        std.debug.assert(w > 0);
        return s.writeOne(col, row, grapheme, @intCast(w), style, to);
    }

    /// One cell's worth of text, already measured at one or two columns.
    fn writeOne(s: *Screen, col: u16, row: u16, grapheme: []const u8, w: u2, style: Style, to: Link) Allocator.Error!void {
        const ascii = grapheme.len == 1 and grapheme[0] < 0x80;
        const t = try s.internShort(grapheme);
        s.placeOwnedCell(col, row, cellmod.internal.store(.{
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
        }));
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
    ) DrawError!bool {
        if (to != .none and s.target(to) == null) return error.InvalidHandle;
        if (scale <= 1) {
            try s.write(col, row, text, style, to);
            return true;
        }
        const grapheme = (try printable(text, s.method)) orelse return false;
        const ascii = grapheme.len == 1 and grapheme[0] < 0x80;
        // A cluster a terminal measuring by codepoint splits across cells
        // is not one glyph to scale.
        if (!ascii and s.method == .wcwidth and !textmod.combinesOnly(grapheme)) return false;
        const w = if (ascii) 1 else textmod.graphemeWidth(grapheme, s.method);
        std.debug.assert(w > 0);
        if (@as(u32, col) + @as(u32, w) * scale > s.dimensions().cols) return false;
        if (@as(u32, row) + scale > s.dimensions().rows) return false;
        const t = try s.internShort(grapheme);
        s.placeOwnedCell(col, row, cellmod.internal.store(.{
            .text = t,
            .style = cellmod.canonical(style),
            .link = to,
            .shape = .{
                .kind = if (w == 2) .wide else .narrow,
                .drift = if (ascii) false else textmod.disagrees(grapheme),
                .scale = scale,
            },
        }));
        return true;
    }

    /// A grapheme as it may go in a cell: itself when it is UTF-8 the pool
    /// can name, and the replacement character when it is not.
    fn valid(grapheme: []const u8) []const u8 {
        if (grapheme.len == 1 and grapheme[0] < 0x80) return grapheme;
        if (grapheme.len > pool.max_len) return "\u{fffd}";
        return if (std.unicode.utf8ValidateSlice(grapheme)) grapheme else "\u{fffd}";
    }

    /// A rectangle of one cell. A wide or scaled cell is laid side by side
    /// and row under row, one whole block after another; a block that would
    /// cross the rectangle's edge is not written.
    pub fn fill(s: *Screen, rect: Rect, c: Cell) CellError!void {
        const checked = try s.cell(c);
        const r = rect.intersect(.fromSize(s.dimensions()));
        if (r.isEmpty()) return;
        const step = cellmod.internal.footprint(checked);
        var y = r.row;
        while (y < r.bottom()) : (y +|= step.rows) {
            var col = r.col;
            while (col < r.right()) : (col +|= step.cols) {
                if (cellmod.internal.fits(checked, col - r.col, y - r.row, r.size()))
                    s.placeOwnedCell(col, y, cellmod.internal.store(checked));
            }
        }
    }

    /// Every cell blank and default.
    pub fn clear(s: *Screen) void {
        const blank: StoredCell = .blank(.{});
        for (s.own_cells, 0..) |*c, i| {
            if (c.eql(blank)) continue;
            c.* = blank;
            s.damage.mark(@intCast(i % s.dimensions().cols), @intCast(i / s.dimensions().cols));
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
        const r = rect.intersect(.fromSize(s.dimensions()));
        if (r.isEmpty() or n == 0) return;
        const distance: u32 = @abs(n);
        const blank: StoredCell = .blank(.{});

        if (distance >= r.rows) {
            // unreachable: a default blank holds no handle and a space, which fill never refuses
            s.fill(r, .blank(.{})) catch unreachable;
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
        s.heal(r.row -| max_reach, @intCast(@min(r.bottom() - 1 + max_reach, s.dimensions().rows - 1)));
    }

    /// Bytes into the pool, deduplicated; inline when they fit.
    /// A cell using them is validated by `cell` or checked placement.
    /// Pooled handles belong to this generation; compaction and resize invalidate them.
    /// More than 65535 bytes return `TooLong`: a pooled length is sixteen bits.
    pub fn intern(s: *Screen, bytes: []const u8) InternError!Cell.Text {
        if (bytes.len > pool.max_len) return error.TooLong;
        return s.internShort(bytes);
    }

    fn internShort(s: *Screen, bytes: []const u8) Allocator.Error!Cell.Text {
        const t = try s.graphemes.intern(bytes);
        return cellmod.internal.exportCell(&.{ .text = t }, s.pool_generation).text;
    }

    /// An OSC 8 target into the link table, deduplicated.
    ///
    /// `params` is the `key=value:key=value` list OSC 8 places before the
    /// URI, empty for none. It is part of the link's identity: two targets
    /// that differ only by an `id=` are two links, because a terminal treats
    /// them as two.
    /// C0 controls and DEL in either field return `ControlInText` before
    /// the table changes, by the same rule morse applies when writing OSC.
    /// A field longer than 65535 bytes returns `TooLong`, and a table
    /// already holding 65534 links `OutOfMemory`; compaction gives back
    /// the ones no cell uses.
    pub fn link(s: *Screen, uri: []const u8, params: []const u8) LinkError!Link {
        try morse.checkText(uri);
        try morse.checkText(params);
        if (uri.len > pool.max_len or params.len > pool.max_len) return error.TooLong;
        return cellmod.internal.exportLink(try s.links.intern(uri, params), s.pool_generation);
    }

    /// The bytes of a cell's grapheme, or `InvalidHandle` for stale or foreign text.
    ///
    /// The cell is taken by pointer because a grapheme of six bytes or
    /// fewer lives inside it: what comes back borrows from the cell, and a
    /// cell read out by value would be gone before the bytes were used.
    /// Inline bytes live until that cell changes or goes away. Pooled bytes
    /// borrow from a growable pool: interning unrelated text can invalidate
    /// them even when this cell is unchanged. Compaction, resize and
    /// deinitialization can also invalidate them. Use `dupeTextOf` to retain
    /// the bytes across drawing.
    pub fn textOf(s: *const Screen, c: *const Cell) HandleError![]const u8 {
        if (!c.text.isPooled()) return c.text.inlineSlice() orelse error.InvalidHandle;
        if (c.text.generation() != s.pool_generation) return error.InvalidHandle;
        const t: StoredCell.Text = .{ .buf = c.text.buf, .len = c.text.len };
        return s.graphemes.slice(&t);
    }

    /// The bytes of the grapheme at a place, borrowed from the grid itself,
    /// or an empty slice outside it. Inline bytes are invalidated by a cell
    /// change, resize or deinitialization; pooled bytes also by pool growth
    /// or compaction. Use `dupeTextAt` to retain them.
    pub fn textAt(s: *const Screen, col: u16, row_n: u16) []const u8 {
        if (col >= s.dimensions().cols or row_n >= s.dimensions().rows) return &.{};
        return internal.textOf(s, &s.own_cells[s.index(col, row_n)]);
    }

    /// The target a cell's link names, or null for no link, a stale handle
    /// or a foreign handle. Both slices
    /// borrow from the growable link pool: interning unrelated links,
    /// compaction, resize or deinitialization can invalidate them. Use
    /// `dupeTarget` to retain the target across drawing.
    pub fn target(s: *const Screen, l: Link) ?pool.Target {
        if (l == .none or l.generation() != s.pool_generation) return null;
        return s.links.get(@fromBackingInt(@intCast(@as(u16, @truncate(@backingInt(l))))));
    }

    /// Copies a cell's text for retention. The caller owns the result and
    /// frees it with `gpa`, which belongs to the copy, not to this screen.
    pub fn dupeTextOf(s: *const Screen, gpa: Allocator, c: *const Cell) DupeTextError![]u8 {
        return gpa.dupe(u8, try s.textOf(c));
    }

    /// Copies text at a place for retention, empty outside the grid. The
    /// caller owns the result and frees it with the copy's allocator `gpa`.
    pub fn dupeTextAt(s: *const Screen, gpa: Allocator, col: u16, row_n: u16) Allocator.Error![]u8 {
        return gpa.dupe(u8, s.textAt(col, row_n));
    }

    /// Copies a target for retention, or null for no link. The returned
    /// owner keeps the copy's allocator `gpa`; call its `deinit` to free it.
    pub fn dupeTarget(s: *const Screen, gpa: Allocator, l: Link) Allocator.Error!?pool.OwnedTarget {
        const t = s.target(l) orelse return null;
        const owned = try pool.OwnedTarget.init(gpa, t);
        return owned;
    }

    /// The head whose grapheme covers a tail: the wide grapheme to its left,
    /// or the scaled one above and to its left. Null for a cell that is not
    /// a tail, or for a tail nothing covers, which the grid never keeps.
    pub fn headOf(s: *const Screen, col: u16, row_n: u16) ?Point {
        if (col >= s.dimensions().cols or row_n >= s.dimensions().rows) return null;
        if (!s.own_cells[s.index(col, row_n)].isTail()) return null;
        // On the same row, the nearest cell that is not a tail is the only
        // candidate: heads never overlap.
        var c = col;
        while (c > 0) {
            c -= 1;
            const h = s.own_cells[s.index(c, row_n)];
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
                const h = s.own_cells[s.index(c, r)];
                if (h.isTail() or !h.isScaled()) continue;
                if (@as(u32, c) + h.width() > col and @as(u32, r) + h.rows() > row_n) return .{ .col = c, .row = r };
            }
        }
        return null;
    }

    /// The whole grid as a window.
    pub fn window(s: *Screen) window_api.Window {
        return .{ .own_screen = s, .own_rect = .fromSize(s.dimensions()) };
    }

    /// Everything dirty: the next draw writes the whole grid.
    pub fn damageAll(s: *Screen) void {
        s.damage.markAll(s.dimensions().cols);
    }

    /// A borrowed row. Cells returned by `get` carry this row's pool identity.
    /// The row expires on resize or destruction; compaction makes its handles stale.
    pub fn rowAt(s: *const Screen, n: u16) Row {
        return .{ .own_cells = internal.row(s, n), .generation = s.pool_generation };
    }

    pub const Row = struct {
        /// Private: the row's cells, borrowed from its screen.
        own_cells: []const StoredCell,
        /// Private: the screen's pool generation the cells belong to.
        generation: u64,

        /// Cell.eql over the row, including its length and checked pool
        /// identities. Equal pooled contents in different generations differ.
        /// Both rows borrow their screens and must still be current.
        pub fn eql(row: Screen.Row, other: Screen.Row) bool {
            if (row.len() != other.len()) return false;
            var changes = row.diff(other);
            return changes.next() == null;
        }

        /// Changed columns, including columns present in only one row.
        /// Uses the same checked identity semantics as Screen.diff. The view
        /// borrows both rows: no cell changes, compaction, resize or destruction
        /// of either screen until iteration ends. Returned columns are copies.
        pub fn diff(row: Screen.Row, other: Screen.Row) Screen.Row.Diff {
            return .{ .a = row, .b = other };
        }

        pub const Diff = struct {
            /// Private: the first row compared.
            a: Row,
            /// Private: the second row compared.
            b: Row,
            /// Private: the column the walk is on.
            col: usize = 0,

            pub fn next(d: *Row.Diff) ?usize {
                while (d.col < @max(d.a.len(), d.b.len())) {
                    const col = d.col;
                    d.col += 1;
                    if (col >= @min(d.a.len(), d.b.len())) return col;
                    const a = &d.a.own_cells[col];
                    const b = &d.b.own_cells[col];
                    if (!cellmod.sameBytes(StoredCell, a, b) or (d.a.generation != d.b.generation and
                        (a.text.isPooled() or a.link != .none))) return col;
                }
                return null;
            }
        };

        pub fn len(row: Screen.Row) usize {
            return row.own_cells.len;
        }
        pub fn get(row: Screen.Row, col: usize) ?Cell {
            if (col >= row.own_cells.len) return null;
            return cellmod.internal.exportCell(&row.own_cells[col], row.generation);
        }
    };

    /// Where a cell is in `cells`.
    pub fn index(s: *const Screen, col: u16, row_n: u16) usize {
        std.debug.assert(col < s.dimensions().cols);
        std.debug.assert(row_n < s.dimensions().rows);
        return @as(usize, row_n) * s.dimensions().cols + col;
    }

    //=====================================================================
    // The grid's own bookkeeping.
    //=====================================================================

    /// Stores a cell and marks it changed, or does neither when it is what
    /// was already there. This is the only place damage is marked, which is
    /// what makes the map exact in both directions.
    fn place(s: *Screen, i: usize, c: StoredCell) void {
        if (s.own_cells[i].eql(c)) return;
        s.own_cells[i] = c;
        s.damage.mark(@intCast(i % s.dimensions().cols), @intCast(i / s.dimensions().cols));
    }

    /// Clears the wide grapheme or the block a cell is part of, if it is part
    /// of one, so that the cell can be written over without leaving an
    /// orphan.
    fn detach(s: *Screen, col: u16, row_n: u16) void {
        if (col >= s.dimensions().cols or row_n >= s.dimensions().rows) return;
        const c = s.own_cells[s.index(col, row_n)];
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
        const head = s.own_cells[s.index(col, row_n)];
        const span = head.width();
        const tall = head.rows();
        var dr: u16 = 0;
        while (dr < tall and row_n + dr < s.dimensions().rows) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span and col + dc < s.dimensions().cols) : (dc += 1) {
                const i = s.index(col + dc, row_n + dr);
                s.place(i, .blank(s.own_cells[i].style));
            }
        }
    }

    /// Puts rows `top` through `bottom` back inside the invariants after
    /// their cells moved without their neighbours: a head whose block is no
    /// longer whole is cleared, a tail nothing covers is blanked, and a tail
    /// a head does cover is made that head's, whichever grapheme left it
    /// there -- as a terminal makes the cell after a wide character its own.
    ///
    /// Heads are decided in reading order, and a cell belongs to the first
    /// head that keeps it. Two blocks a move left overlapping are one kept
    /// and one cleared, and clearing the second gives back only its head:
    /// its tails are then either the first block's, or nobody's and blank.
    /// Clearing the second block's whole rectangle would blank the first
    /// block's cells inside it and leave that block torn.
    fn heal(s: *Screen, top: u16, bottom: u16) void {
        var row_n = top;
        while (row_n <= bottom and row_n < s.dimensions().rows) : (row_n += 1) {
            var col: u16 = 0;
            while (col < s.dimensions().cols) : (col += 1) {
                const i = s.index(col, row_n);
                const c = s.own_cells[i];
                if (c.isTail()) {
                    s.adoptTail(col, row_n);
                    continue;
                }
                if (c.width() == 1 and c.rows() == 1) continue;
                if (c.shape.kind == .wide and !c.isScaled() and col + 1 >= s.dimensions().cols) {
                    // The one column left is a spacer, as `writeOwnedCell`
                    // would have made it.
                    var spacer: StoredCell = .blank(c.style);
                    spacer.shape.kind = .spacer_head;
                    s.place(i, spacer);
                    continue;
                }
                if (s.blockWhole(col, row_n, c)) continue;
                // The head goes. Its tails inside the sweep are met later
                // and settled there; the ones below it are settled now,
                // because the sweep will not reach them.
                s.place(i, .blank(c.style));
                const span = c.width();
                const tall = c.rows();
                var dr: u16 = 1;
                while (dr < tall and row_n + dr < s.dimensions().rows) : (dr += 1) {
                    if (row_n + dr <= bottom) continue;
                    var dc: u16 = 0;
                    while (dc < span and col + dc < s.dimensions().cols) : (dc += 1) {
                        if (s.own_cells[s.index(col + dc, row_n + dr)].isTail()) s.adoptTail(col + dc, row_n + dr);
                    }
                }
            }
        }
    }

    /// A tail made the cell of the head that covers it, or a blank when
    /// none does. Every head before it in reading order has been decided,
    /// so a head found here is one whose block was kept.
    fn adoptTail(s: *Screen, col: u16, row_n: u16) void {
        const i = s.index(col, row_n);
        if (s.headOf(col, row_n)) |head| {
            var own = s.own_cells[s.index(head.col, head.row)];
            own.shape.kind = .spacer_tail;
            s.place(i, own);
        } else s.place(i, .blank(s.own_cells[i].style));
    }

    /// Whether every cell a head covers is a tail of its own scale, inside
    /// the grid, that no head before it in reading order already covers.
    fn blockWhole(s: *const Screen, col: u16, row_n: u16, head: StoredCell) bool {
        const span = head.width();
        const tall = head.rows();
        if (@as(u32, col) + span > s.dimensions().cols or @as(u32, row_n) + tall > s.dimensions().rows) return false;
        var dr: u16 = 0;
        while (dr < tall) : (dr += 1) {
            var dc: u16 = 0;
            while (dc < span) : (dc += 1) {
                if (dr == 0 and dc == 0) continue;
                const t = s.own_cells[s.index(col + dc, row_n + dr)];
                if (!t.isTail() or t.shape.scale != head.shape.scale) return false;
                if (s.coveredBefore(col + dc, row_n + dr, .{ .col = col, .row = row_n })) return false;
            }
        }
        return true;
    }

    /// Whether a head that comes before `head` in reading order covers the
    /// cell. Only a head up to `max_reach` rows above and `max_span`
    /// columns to the left can.
    fn coveredBefore(s: *const Screen, col: u16, row_n: u16, head: Point) bool {
        var r = row_n -| max_reach;
        while (r <= row_n) : (r += 1) {
            var c = col -| max_span;
            while (c <= col) : (c += 1) {
                if (r > head.row or (r == head.row and c >= head.col)) break;
                const h = s.own_cells[s.index(c, r)];
                if (h.isTail()) continue;
                if (@as(u32, c) + h.width() > col and @as(u32, r) + h.rows() > row_n) return true;
            }
        }
        return false;
    }

    /// Copies a run of cells from one row to another, marking what changed.
    fn copyRun(s: *Screen, from_col: u16, from_row: u16, to_col: u16, to_row: u16, cols: u16) void {
        const src = s.index(from_col, from_row);
        const dst = s.index(to_col, to_row);
        for (0..cols) |k| s.place(dst + k, s.own_cells[src + k]);
    }

    /// Blanks a run of cells, marking what changed.
    fn blankRun(s: *Screen, col: u16, row_n: u16, cols: u16, blank: StoredCell) void {
        const at = s.index(col, row_n);
        for (0..cols) |k| s.place(at + k, blank);
    }

    /// Puts the cursor back inside a grid that shrank.
    fn clampCursor(s: *Screen) void {
        if (s.dimensions().cols == 0 or s.dimensions().rows == 0) {
            s.cursor.col = 0;
            s.cursor.row = 0;
            return;
        }
        s.cursor.col = @min(s.cursor.col, s.dimensions().cols - 1);
        s.cursor.row = @min(s.cursor.row, s.dimensions().rows - 1);
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
    for (0..s.dimensions().rows) |r| {
        var col: u16 = 0;
        while (col < s.dimensions().cols) {
            const c = s.own_cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape.reserved == 0);
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
            try testing.expect(col + span <= s.dimensions().cols);
            try testing.expect(r + c.rows() <= s.dimensions().rows);
            for (0..c.rows()) |dr| {
                for (0..span) |dc| {
                    if (dr == 0 and dc == 0) continue;
                    const t = s.own_cells[s.index(@intCast(col + dc), @intCast(r + dr))];
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
    defer s.deinit();

    try testing.expectEqual(@as(usize, 8), s.own_cells.len);
    for (s.own_cells) |c| try testing.expect(c.eql(.blank(.{})));
    try testing.expect(!s.damage.any());
    try checkInvariants(&s);
}

test "a write outside the grid changes nothing" {
    var s = try made(4, 2);
    defer s.deinit();

    try s.write(9, 0, "x", .{}, .none);
    try s.write(0, 9, "x", .{}, .none);
    try s.writeOwnedCell(4, 0, .blank(.{ .bold = true }));
    try testing.expect(!s.damage.any());
    try testing.expectEqual(@as(?Cell, null), s.readCell(4, 0));
}

test "writing the same cell twice damages once and not at all the second time" {
    var s = try made(4, 2);
    defer s.deinit();

    try s.write(1, 0, "a", .{}, .none);
    try testing.expectEqual(@as(usize, 1), s.damage.count());
    s.damage.clear();
    try s.write(1, 0, "a", .{}, .none);
    try testing.expect(!s.damage.any());
}

test "bytes that are not UTF-8 go in as the replacement character" {
    var s: Screen = try .init(testing.allocator, .{ .cols = 4, .rows = 1 });
    defer s.deinit();
    try s.write(0, 0, "\xff", .{}, .none);
    try s.write(1, 0, "\xe4\xb8", .{}, .none);
    try testing.expectEqualStrings("\u{fffd}", s.textAt(0, 0));
    try testing.expectEqualStrings("\u{fffd}", s.textAt(1, 0));
    try testing.expect(try s.writeScaled(2, 0, "\xc3", .{}, .none, 1));
    try testing.expectEqualStrings("\u{fffd}", s.textAt(2, 0));
}

test "a wide grapheme writes a head and a tail" {
    var s = try made(6, 1);
    defer s.deinit();

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
    defer s.deinit();

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
    defer s.deinit();

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
    defer s.deinit();

    try s.write(2, 0, "\u{4e2d}", .{ .bold = true }, .none);
    const c = s.readCell(2, 0).?;
    try testing.expectEqualStrings(" ", s.textAt(2, 0));
    try testing.expect(c.style.bold);
    try checkInvariants(&s);
}

test "measured by codepoint, a cluster of wide codepoints takes a cell each, as far as the row goes" {
    var s: Screen = try .init(testing.allocator, .{ .cols = 7, .rows = 1 });
    defer s.deinit();
    s.method = .wcwidth;
    try s.write(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{ .bold = true }, .none);
    try testing.expectEqualStrings("\u{1f469}\u{200d}", s.textAt(0, 0));
    try testing.expect(s.readCell(1, 0).?.isTail());
    try testing.expectEqualStrings("\u{1f680}", s.textAt(2, 0));
    try testing.expect(s.readCell(2, 0).?.style.bold);
    try testing.expect(s.readCell(3, 0).?.isTail());
    // Three wide codepoints from the fourth column: two fit, the third is
    // past the row's end, and the second has one column left and is a
    // spacer, as any wide cell there is.
    try s.write(4, 0, "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}", .{}, .none);
    try testing.expectEqualStrings("\u{1f468}\u{200d}", s.textAt(4, 0));
    try testing.expectEqual(Cell.Kind.spacer_head, s.readCell(6, 0).?.shape.kind);
    try checkInvariants(&s);
    // And a cluster measured whole is one cell, and not one to draw at a
    // scale measured by codepoint.
    try testing.expect(!try s.writeScaled(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{}, .none, 2));
    s.method = .unicode;
    try s.write(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{}, .none);
    try testing.expectEqualStrings("\u{1f469}\u{200d}\u{1f680}", s.textAt(0, 0));
    try testing.expect(s.readCell(1, 0).?.isTail());
    try checkInvariants(&s);
}

test "a caller's tail is taken as a blank" {
    var s = try made(3, 1);
    defer s.deinit();
    try s.writeOwnedCell(1, 0, .{ .text = .inlined("x"), .shape = .{ .kind = .spacer_tail } });
    try testing.expectEqualStrings(" ", s.textAt(1, 0));
    try checkInvariants(&s);
}

test "a scaled grapheme is a head and a block of tails" {
    var s = try made(8, 4);
    defer s.deinit();

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
    defer s.deinit();
    try testing.expect(!try s.writeScaled(3, 0, "a", .{}, .none, 2));
    try testing.expect(!try s.writeScaled(0, 1, "a", .{}, .none, 2));
    try testing.expect(!s.damage.any());
    // Through the owned path, it is a blank rather than half a block.
    try s.writeOwnedCell(3, 0, .init(.{ .text = .inlined("a"), .shape = .{ .scale = 2 } }));
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try checkInvariants(&s);
}

test "writing into any cell of a block clears the whole block" {
    var s = try made(8, 4);
    defer s.deinit();

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
    defer s.deinit();
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
    defer s.deinit();
    try testing.expect(try s.writeScaled(1, 1, "a", .{}, .none, 2));
    // The head's row moves up and the tails' row does not.
    s.scroll(.{ .col = 0, .row = 0, .cols = 6, .rows = 2 }, 1);
    for (s.own_cells) |c| try testing.expect(!c.isTail() and !c.isScaled());
    try checkInvariants(&s);

    // And a block that moves whole moves whole.
    try testing.expect(try s.writeScaled(1, 2, "a", .{}, .none, 2));
    s.scroll(.fromSize(s.dimensions()), 1);
    try testing.expectEqualStrings("a", s.textAt(1, 1));
    try testing.expect(s.readCell(2, 2).?.isTail());
    try checkInvariants(&s);
}

test "a scroll that moves a block's head into another block clears the moved one and keeps the other" {
    // Found by the round trip once its generator explored: the head of a
    // block three tall, lifted a row by a scroll one column wide, landed
    // beside the lower half of a block two tall, and clearing the torn
    // block took that half with it.
    var s = try made(7, 11);
    defer s.deinit();
    try testing.expect(try s.writeScaled(3, 4, "a", .{}, .none, 2));
    try testing.expect(try s.writeScaled(2, 6, "~", .{ .bold = true }, .none, 3));
    s.scroll(.{ .col = 2, .row = 0, .cols = 1, .rows = 8 }, 1);
    try checkInvariants(&s);
    // The block that did not move is whole.
    try testing.expectEqualStrings("a", s.textAt(3, 4));
    try testing.expectEqual(@as(u3, 2), s.readCell(3, 4).?.shape.scale);
    for ([_]Point{ .{ .col = 4, .row = 4 }, .{ .col = 3, .row = 5 }, .{ .col = 4, .row = 5 } }) |at| {
        try testing.expectEqual(Point{ .col = 3, .row = 4 }, s.headOf(at.col, at.row).?);
    }
    // And nothing is left of the one that did.
    for (s.own_cells) |c| try testing.expect(c.shape.scale != 3);
}

test "two blocks a scroll leaves overlapping are one block, the first in reading order" {
    var s = try made(8, 6);
    defer s.deinit();
    // One block high on the left, one lower down beside it; lifting the
    // lower block's column by a row lays its head over the first block's
    // lower half.
    try testing.expect(try s.writeScaled(0, 0, "a", .{}, .none, 2));
    try testing.expect(try s.writeScaled(1, 2, "b", .{}, .none, 2));
    s.scroll(.{ .col = 1, .row = 0, .cols = 1, .rows = 4 }, 1);
    try checkInvariants(&s);
}

test "a resize that cuts a block off blanks it" {
    var s = try made(6, 4);
    defer s.deinit();
    try testing.expect(try s.writeScaled(2, 1, "a", .{}, .none, 3));
    try s.resize(.{ .cols = 6, .rows = 3 });
    for (s.own_cells) |c| try testing.expect(!c.isTail() and !c.isScaled());
    try checkInvariants(&s);
}

test "a control character is not something a cell holds" {
    var s = try made(4, 1);
    defer s.deinit();
    try s.write(0, 0, "\n", .{}, .none);
    try s.write(1, 0, "\x1b", .{}, .none);
    try s.write(2, 0, "\x7f", .{}, .none);
    try testing.expect(!s.damage.any());
}

test "a fill covers only the rectangle and clips to the grid" {
    var s = try made(6, 4);
    defer s.deinit();

    try s.fill(.{ .col = 1, .row = 1, .cols = 3, .rows = 2 }, .blank(.{ .bg = .ansi(.blue) }));
    try testing.expect(s.readCell(0, 1).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(3, 2).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(4, 2).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 3).?.eql(.blank(.{})));

    try s.fill(.{ .col = 4, .row = 3, .cols = 99, .rows = 99 }, .blank(.{ .bold = true }));
    try testing.expect(s.readCell(5, 3).?.style.bold);
    try checkInvariants(&s);
}

test "clear puts every cell back and damages only what it moved" {
    var s = try made(4, 2);
    defer s.deinit();

    try s.write(2, 1, "x", .{}, .none);
    s.damage.clear();
    s.clear();
    try testing.expectEqual(@as(usize, 1), s.damage.count());
    try testing.expectEqual(damage_mod.Span{ .first = 2, .last = 2 }, s.damage.row(1).?);
    for (s.own_cells) |c| try testing.expect(c.eql(.blank(.{})));
}

test "a scroll up moves the rows and blanks what it vacated" {
    var s = try made(3, 4);
    defer s.deinit();

    for (0..4) |r| try s.write(0, @intCast(r), &.{'a' + @as(u8, @intCast(r))}, .{}, .none);
    s.scroll(.fromSize(s.dimensions()), 1);
    try testing.expectEqualStrings("b", s.textAt(0, 0));
    try testing.expectEqualStrings("c", s.textAt(0, 1));
    try testing.expectEqualStrings("d", s.textAt(0, 2));
    try testing.expectEqualStrings(" ", s.textAt(0, 3));
    try checkInvariants(&s);
}

test "a scroll down moves the rows the other way" {
    var s = try made(3, 4);
    defer s.deinit();

    for (0..4) |r| try s.write(0, @intCast(r), &.{'a' + @as(u8, @intCast(r))}, .{}, .none);
    s.scroll(.fromSize(s.dimensions()), -2);
    try testing.expectEqualStrings(" ", s.textAt(0, 0));
    try testing.expectEqualStrings(" ", s.textAt(0, 1));
    try testing.expectEqualStrings("a", s.textAt(0, 2));
    try testing.expectEqualStrings("b", s.textAt(0, 3));
    try checkInvariants(&s);
}

test "a scroll further than the rectangle is tall blanks it" {
    var s = try made(3, 3);
    defer s.deinit();
    try s.write(0, 0, "a", .{}, .none);
    s.scroll(.fromSize(s.dimensions()), 9);
    for (s.own_cells) |c| try testing.expect(c.eql(.blank(.{})));
}

test "a scroll that cuts a wide grapheme in half leaves two blanks" {
    var s = try made(6, 2);
    defer s.deinit();

    // A wide grapheme straddling the rectangle's left edge on the row the
    // scroll brings up.
    try s.write(1, 1, "\u{4e2d}", .{}, .none);
    s.scroll(.{ .col = 2, .row = 0, .cols = 4, .rows = 2 }, 1);
    try checkInvariants(&s);
}

test "a wide grapheme moved beside another's covered column takes that column as its own" {
    var s: Screen = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    s.method = .unicode;
    try s.write(1, 0, "\u{4e2d}", .{ .bold = true }, .none);
    try s.write(1, 1, "\u{ff21}", .{ .italic = true }, .none);

    // The rectangle holds the heads and not the columns they cover, so the
    // second head arrives beside the first one's covered column.
    s.scroll(.{ .col = 0, .row = 0, .cols = 2, .rows = 2 }, 1);
    var own = s.readCell(1, 0).?;
    try testing.expectEqualStrings("\u{ff21}", s.textAt(1, 0));
    own.shape.kind = .spacer_tail;
    try testing.expect(s.readCell(2, 0).?.eql(own));
    // And the column it left, with nothing over it now, is blank.
    try testing.expect(s.readCell(2, 1).?.isBlankIn(.{ .italic = true }));
}

test "a resize keeps what still fits and damages everything" {
    var s = try made(4, 2);
    defer s.deinit();

    try s.write(0, 0, "a", .{}, .none);
    try s.write(3, 1, "b", .{}, .none);
    try s.resize(.{ .cols = 6, .rows = 3 });
    try testing.expectEqualStrings("a", s.textAt(0, 0));
    try testing.expectEqualStrings("b", s.textAt(3, 1));
    try testing.expect(s.readCell(5, 2).?.eql(.blank(.{})));
    try testing.expectEqual(@as(usize, 3), s.damage.count());
    try checkInvariants(&s);
}

test "a resize that cuts a wide grapheme off the right edge blanks it" {
    var s = try made(6, 1);
    defer s.deinit();

    try s.write(3, 0, "\u{4e2d}", .{}, .none);
    try s.resize(.{ .cols = 4, .rows = 1 });
    try testing.expectEqualStrings(" ", s.textAt(3, 0));
    try checkInvariants(&s);
}

test "a resize puts the cursor back inside" {
    var s = try made(10, 10);
    defer s.deinit();
    s.cursor = .{ .col = 9, .row = 9, .visible = true };
    try s.resize(.{ .cols = 4, .rows = 3 });
    try testing.expectEqual(@as(u16, 3), s.cursor.col);
    try testing.expectEqual(@as(u16, 2), s.cursor.row);
}

test "a long grapheme is pooled and read back through the screen" {
    var s = try made(4, 1);
    defer s.deinit();

    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try s.write(0, 0, family, .{}, .none);
    const c = s.readCell(0, 0).?;
    try testing.expect(c.text.isPooled());
    try testing.expectEqualStrings(family, s.textAt(0, 0));
    try checkInvariants(&s);
}

test "copying a pooled cell between screens keeps its source text" {
    var a = try made(2, 1);
    defer a.deinit();
    var b = try made(2, 1);
    defer b.deinit();

    try a.write(0, 0, "a\u{301}\u{302}\u{303}", .{}, .none);
    try b.write(1, 0, "b\u{301}\u{302}\u{303}", .{}, .none);
    try b.copyCell(&a, 0, 0, a.readCell(0, 0).?);
    try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", b.textAt(0, 0));
}

test "a link is interned and reaches the cell" {
    var s = try made(4, 1);
    defer s.deinit();

    const l = try s.link("https://ziglang.org", "id=1");
    try s.write(0, 0, "z", .{}, l);
    try testing.expectEqual(l, s.readCell(0, 0).?.link);
    try testing.expectEqualStrings("id=1", s.target(l).?.params);
    try checkInvariants(&s);
}

/// Tests only. Every allocation-failure check runs over it: each growth is then an
/// allocation in every run, so the count of allocations to fail repeats.
const NoResize = @import("shakedown").alloc.NoResize;

test "the screen survives every allocation failing in turn" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var s: Screen = try .init(gpa, .{ .cols = 8, .rows = 4 });
            defer s.deinit();
            s.method = .unicode;
            _ = try s.intern("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}");
            _ = try s.link("https://ziglang.org", "id=1");
            try s.write(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{}, .none);
            try s.resize(.{ .cols = 12, .rows = 6 });
            try s.compactPool();
            try s.resize(.{ .cols = 4, .rows = 2 });
        }
    }.run, .{});
}

test "compacting the pool keeps what is on screen and drops what is not" {
    var s = try made(8, 2);
    defer s.deinit();

    var buf: [24]u8 = undefined;
    for (0..64) |i| {
        const long = try std.mem.print(&buf, "a\u{301}\u{302}{u}", .{@as(u21, @intCast(0x300 + i))});
        try s.write(0, 0, long, .{}, .none);
        _ = try s.link(long, "");
    }
    const kept = "a\u{301}\u{302}\u{33f}";
    try testing.expectEqualStrings(kept, s.textAt(0, 0));
    try testing.expect(s.graphemes.len() > kept.len);
    try testing.expectEqual(@as(usize, 64), s.links.count());

    try s.compactPool();
    try testing.expectEqualStrings(kept, s.textAt(0, 0));
    try testing.expectEqual(@as(usize, kept.len), s.graphemes.len());
    try testing.expectEqual(@as(usize, 0), s.links.count());
    try checkInvariants(&s);
}

test "compacting keeps the links cells still point at" {
    var s = try made(8, 1);
    defer s.deinit();

    const stale = try s.link("https://example.invalid", "id=0");
    _ = stale;
    const live = try s.link("https://ziglang.org", "id=1");
    try s.write(0, 0, "z", .{}, live);
    try testing.expectEqual(@as(usize, 2), s.links.count());

    try s.compactPool();
    try testing.expectEqual(@as(usize, 1), s.links.count());
    const now = s.readCell(0, 0).?.link;
    try testing.expectEqualStrings("https://ziglang.org", s.target(now).?.uri);
    try testing.expectEqualStrings("id=1", s.target(now).?.params);
}

test "a resize rebuilds the pool rather than growing it forever" {
    var s = try made(4, 1);
    defer s.deinit();

    var buf: [24]u8 = undefined;
    for (0..32) |i| {
        const long = try std.mem.print(&buf, "a\u{301}\u{302}{u}", .{@as(u21, @intCast(0x300 + i))});
        try s.write(0, 0, long, .{}, .none);
    }
    const before = s.graphemes.len();
    try s.resize(.{ .cols = 6, .rows = 2 });
    try testing.expect(s.graphemes.len() < before);
    try testing.expectEqualStrings("a\u{301}\u{302}\u{31f}", s.textAt(0, 0));
}

test "Screen.link refuses controls in either field before interning and preserves UTF-8" {
    var s = try made(4, 1);
    defer s.deinit();
    const first = try s.link("https://example.com/café", "id=🐈");
    for (0..128) |n| {
        if (n >= 32 and n != 127) continue;
        const bad = [_]u8{ 'a', @intCast(n), 'b' };
        try testing.expectError(error.ControlInText, s.link(&bad, ""));
        try testing.expectError(error.ControlInText, s.link("uri", &bad));
    }
    const target = s.target(first).?;
    try testing.expectEqualStrings("https://example.com/café", target.uri);
    try testing.expectEqualStrings("id=🐈", target.params);
    const second = try s.link("uri", "");
    try testing.expectEqual(@backingInt(first) + 1, @backingInt(second));
}

test "owned text and targets survive drawing, compaction, resize and destruction" {
    var s = try made(4, 1);
    var live = true;
    defer if (live) s.deinit();
    const long = "a\u{301}\u{302}\u{303}";
    const link_id = try s.link("https://kept.invalid", "id=kept");
    try s.write(0, 0, long, .{}, link_id);
    try s.write(1, 0, "x", .{}, .none);
    const text = try s.dupeTextAt(testing.allocator, 0, 0);
    defer testing.allocator.free(text);
    const inline_text = try s.dupeTextOf(testing.allocator, &s.readCell(1, 0).?);
    defer testing.allocator.free(inline_text);
    var target_copy = (try s.dupeTarget(testing.allocator, link_id)).?;
    defer target_copy.deinit();
    try testing.expect((try s.dupeTarget(testing.allocator, .none)) == null);
    var buf: [64]u8 = undefined;
    for (0..128) |i| {
        const unrelated = try std.mem.print(&buf, "unrelated-{d}", .{i});
        _ = try s.intern(unrelated);
        _ = try s.link(unrelated, "");
    }
    s.clear();
    try s.compactPool();
    try s.resize(.{ .cols = 8, .rows = 2 });
    s.deinit();
    live = false;
    try testing.expectEqualStrings(long, text);
    try testing.expectEqualStrings("x", inline_text);
    try testing.expectEqualStrings("https://kept.invalid", target_copy.target().uri);
    try testing.expectEqualStrings("id=kept", target_copy.target().params);
}

test "an owned target releases its first copy when the second allocation fails" {
    var s = try made(4, 1);
    defer s.deinit();
    const id = try s.link("https://kept.invalid", "id=kept");
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator, screen: *const Screen, link_id: Link) !void {
            var copy = (try screen.dupeTarget(gpa, link_id)).?;
            defer copy.deinit();
            try testing.expectEqualStrings("id=kept", copy.target().params);
        }
    }.run, .{ &s, id });
}

test "a failed resize leaves cells, pool identities, borrows and damage untouched" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var s = try Screen.init(gpa, .{ .cols = 4, .rows = 1 });
            defer s.deinit();
            s.method = .unicode;
            _ = try s.intern("a\u{301}\u{302}\u{303}");
            _ = try s.link("https://stale.invalid", "");
            const live = try s.link("https://live.invalid", "id=live");
            try s.write(0, 0, "b\u{301}\u{302}\u{303}", .{}, live);
            s.damage.clear();
            const before = s.own_cells[0];
            const cells = s.own_cells;
            const graphemes = s.graphemes.bytes.items;
            const links = s.links.bytes.items;
            const generation = s.pool_generation;
            s.resize(.{ .cols = 8, .rows = 2 }) catch |err| {
                try testing.expectEqual(generation, s.pool_generation);
                try testing.expectEqual(Size{ .cols = 4, .rows = 1 }, s.dimensions());
                try testing.expect(s.own_cells.ptr == cells.ptr);
                try testing.expect(before.eql(s.own_cells[0]));
                try testing.expect(s.graphemes.bytes.items.ptr == graphemes.ptr);
                try testing.expect(s.links.bytes.items.ptr == links.ptr);
                try testing.expect(!s.damage.any());
                return err;
            };
            try testing.expectEqualStrings("b\u{301}\u{302}\u{303}", s.textAt(0, 0));
            try testing.expectEqualStrings("https://live.invalid", s.target(s.readCell(0, 0).?.link).?.uri);
        }
    }.run, .{});
}

test "cell extents clip safely at the u16 coordinate edge" {
    var s = try Screen.init(testing.allocator, .{ .cols = std.math.maxInt(u16), .rows = 1 });
    defer s.deinit();
    const last = s.dimensions().cols - 1;
    try s.writeOwnedCell(last, 0, .{ .text = .inlined("x"), .shape = .{ .scale = 7 } });
    try testing.expect(s.own_cells[last].eql(.blank(.{})));
    // Measured by codepoint, a two-column part at the last column becomes
    // a spacer; stepping past it must not narrow an out-of-grid endpoint.
    try s.write(last, 0, "\u{1f680}", .{}, .none);
    try testing.expectEqual(Cell.Kind.spacer_head, s.own_cells[last].shape.kind);
}

test "retained handles cannot name foreign or compacted content" {
    var a = try Screen.init(testing.allocator, .{ .cols = 2, .rows = 1 });
    defer a.deinit();
    var b = try Screen.init(testing.allocator, a.dimensions());
    defer b.deinit();
    const old_text = try a.intern("a\u{301}\u{302}\u{303}");
    const old_link = try a.link("https://old.invalid", "");
    const foreign_text = try b.intern("b\u{301}\u{302}\u{303}");
    _ = try b.link("https://new.invalid", "");
    try testing.expect(b.target(old_link) == null);
    try testing.expect(!Cell.Text.eql(old_text, foreign_text));
    try a.compactPool();
    const new_text = try a.intern("b\u{301}\u{302}\u{303}");
    _ = try a.link("https://new.invalid", "");
    try testing.expect(a.target(old_link) == null);
    try testing.expect(!Cell.Text.eql(old_text, new_text));
}

test "checked cell operations refuse stale and foreign handles before changing the grid" {
    var a = try Screen.init(testing.allocator, .{ .cols = 3, .rows = 1 });
    defer a.deinit();
    var b = try Screen.init(testing.allocator, a.dimensions());
    defer b.deinit();
    const retained: Cell = .{ .text = try a.intern("a\u{301}\u{302}\u{303}"), .link = try a.link("https://old.invalid", "") };
    try a.writeOwnedCell(0, 0, retained);
    _ = try b.intern("b\u{301}\u{302}\u{303}");
    _ = try b.link("https://new.invalid", "");
    const blank = b.own_cells[0];
    const link_only: Cell = .{ .link = retained.link };
    try testing.expectError(error.InvalidHandle, b.writeOwnedCell(0, 0, link_only));
    try testing.expectError(error.InvalidHandle, b.fill(.fromSize(b.dimensions()), link_only));
    try testing.expectError(error.InvalidHandle, b.copyCell(&b, 0, 0, link_only));
    try testing.expectError(error.InvalidHandle, b.textOf(&retained));
    try testing.expectError(error.InvalidHandle, b.writeOwnedCell(0, 0, retained));
    try testing.expectError(error.InvalidHandle, b.fill(.fromSize(b.dimensions()), retained));
    try testing.expectError(error.InvalidHandle, b.write(0, 0, "x", .{}, retained.link));
    try testing.expectError(error.InvalidHandle, b.writeScaled(0, 0, "x", .{}, retained.link, 2));
    try testing.expectError(error.InvalidHandle, b.copyCell(&b, 0, 0, retained));
    try testing.expectError(error.InvalidHandle, b.dupeTextOf(testing.allocator, &retained));
    try testing.expect(blank.eql(b.own_cells[0]));
    try b.copyCell(&a, 0, 0, retained);
    try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", b.textAt(0, 0));
    try testing.expectEqualStrings("https://old.invalid", b.target(b.readCell(0, 0).?.link).?.uri);

    try a.compactPool();
    try testing.expectError(error.InvalidHandle, a.textOf(&retained));
    try testing.expectError(error.InvalidHandle, a.writeOwnedCell(1, 0, retained));
    try testing.expectError(error.InvalidHandle, b.copyCell(&a, 1, 0, retained));
    try testing.expect(a.target(retained.link) == null);
    try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", a.textAt(0, 0));
    const after_compaction = a.readCell(0, 0).?;
    try a.resize(.{ .cols = 4, .rows = 1 });
    try testing.expectError(error.InvalidHandle, a.textOf(&after_compaction));
    try testing.expect(a.target(after_compaction.link) == null);
    try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", a.textAt(0, 0));
    const portable: Cell = .{ .text = .inlined("x") };
    try a.writeOwnedCell(2, 0, portable);
    try b.writeOwnedCell(2, 0, portable);
}

test "cell imports reject malformed glyphs and shapes before changing the grid" {
    var s = try made(4, 2);
    defer s.deinit();
    var source = try made(4, 2);
    defer source.deinit();
    s.damage.clear();
    const bad = [_]Cell{
        .{ .text = .inlined("") },
        .{ .text = .inlined("ab") },
        .{ .text = .inlined("\x1b") },
        .{ .text = .inlined("\xff") },
        .{ .text = .inlined("\u{85}") },
        .{ .text = .inlined("\u{200b}") },
        .{ .text = .inlined("\u{301}") },
        .{ .text = .inlined("x"), .shape = .{ .kind = .wide } },
        .{ .text = .inlined("中") },
        .{ .shape = .{ .reserved = 1 } },
        .{ .shape = .{ .kind = .spacer_head, .scale = 2 } },
    };
    for (bad) |cell| {
        try testing.expectError(error.InvalidCell, s.cell(cell));
        try testing.expectError(error.InvalidCell, s.writeOwnedCell(0, 0, cell));
        try testing.expectError(error.InvalidCell, s.fill(.fromSize(s.dimensions()), cell));
        try testing.expectError(error.InvalidCell, s.copyCell(&source, 0, 0, cell));
        try testing.expect(!s.damage.any());
        try testing.expectEqualStrings(" ", s.textAt(0, 0));
    }
    // Text is refused only when it is more than one cluster.
    for ([_][]const u8{ "ab", "a\u{85}", "\u{301}x" }) |bytes| {
        try testing.expectError(error.InvalidCell, internal.printable(bytes, s.method));
        try testing.expectError(error.InvalidCell, s.write(0, 0, bytes, .{}, .none));
        try testing.expectError(error.InvalidCell, s.writeScaled(0, 0, bytes, .{}, .none, 2));
    }
    try testing.expect(!s.damage.any());
    const multi: Cell = .{ .text = try s.intern("pooled-multiple-clusters") };
    try testing.expectError(error.InvalidCell, s.writeOwnedCell(0, 0, multi));
    var noncanonical: Cell = .{ .text = .inlined("x") };
    noncanonical.text.buf[5] = 1;
    try testing.expectError(error.InvalidCell, s.writeOwnedCell(0, 0, noncanonical));
    try s.writeOwnedCell(0, 0, .{ .text = .inlined("a\u{301}") });
    try s.writeOwnedCell(1, 0, .{ .text = .inlined("中"), .shape = .{ .kind = .wide } });
    try testing.expect(s.readCell(2, 0).?.isTail());
}

test "a terminal bridge keeps stated widths and still checks pool identities" {
    var s = try made(4, 1);
    defer s.deinit();
    const foreign: Cell = .{ .text = .inlined("x"), .shape = .{ .kind = .wide }, .link = try s.link("https://bridge.invalid", "") };
    try testing.expectError(error.InvalidCell, s.cell(foreign));
    try s.writeOwnedCellUnchecked(0, 0, foreign);
    try testing.expectEqual(@as(u4, 2), s.readCell(0, 0).?.width());
    try testing.expect(s.readCell(1, 0).?.isTail());
    var other = try made(4, 1);
    defer other.deinit();
    try testing.expectError(error.InvalidHandle, other.writeOwnedCellUnchecked(0, 0, foreign));
    try s.compactPool();
    try testing.expectError(error.InvalidHandle, s.writeOwnedCellUnchecked(0, 0, foreign));
}

test "copying a cell checks destination shape before allocating its pools" {
    var source = try made(4, 1);
    defer source.deinit();
    try source.write(0, 0, "👩‍🚀", .{}, try source.link("https://source.invalid", ""));
    var dest = try Screen.init(testing.allocator, source.dimensions());
    defer dest.deinit();
    dest.damage.clear();
    try testing.expectError(error.InvalidCell, dest.copyCell(&source, 0, 0, source.readCell(0, 0).?));
    try testing.expectEqual(@as(usize, 0), dest.graphemes.len());
    try testing.expectEqual(@as(usize, 0), dest.links.count());
    try testing.expect(!dest.damage.any());
}

test "shrinking a screen sweeps text and links that no cell keeps" {
    var s = try Screen.init(testing.allocator, .{ .cols = 2, .rows = 1 });
    defer s.deinit();
    const link = try s.link("https://removed.example", "");
    const glyph = "a\u{301}\u{302}\u{303}";
    try s.write(1, 0, glyph, .{}, link);
    try s.resize(.{ .cols = 1, .rows = 1 });
    try testing.expectEqual(@as(usize, 0), s.graphemes.len());
    try testing.expectEqual(@as(usize, 0), s.links.count());

    // A head can survive the rectangle but lose the room its block needs.
    try s.resize(.{ .cols = 2, .rows = 1 });
    const wide_link = try s.link("https://clipped.example", "");
    try s.write(0, 0, "界\u{301}\u{302}", .{}, wide_link);
    try s.resize(.{ .cols = 1, .rows = 1 });
    try testing.expectEqual(@as(usize, 0), s.graphemes.len());
    try testing.expectEqual(@as(usize, 0), s.links.count());
    try testing.expectEqualStrings(" ", s.textAt(0, 0));
}

test "screen fills keep whole glyph extents inside their rectangle" {
    for ([_]u3{ 1, 3 }) |scale| {
        var s = try made(8, 5);
        defer s.deinit();
        var source = try made(8, 5);
        defer source.deinit();
        if (scale == 1) try source.write(0, 0, "中", .{}, .none) else _ = try source.writeScaled(0, 0, "x", .{}, .none, scale);
        const glyph = source.readCell(0, 0).?;
        try s.write(3, 1, "R", .{}, .none);
        try s.write(1, 3, "B", .{}, .none);
        const rect: Rect = .{ .col = 1, .row = 1, .cols = 2, .rows = 2 };
        try s.fill(rect, glyph);
        try testing.expectEqualStrings("R", s.textAt(3, 1));
        try testing.expectEqualStrings("B", s.textAt(1, 3));
        var via_window = try made(8, 5);
        defer via_window.deinit();
        try via_window.write(3, 1, "R", .{}, .none);
        try via_window.write(1, 3, "B", .{}, .none);
        try via_window.window().fill(rect, glyph);
        for (0..5) |row| for (0..8) |col| {
            try testing.expectEqualDeep(via_window.readCell(@intCast(col), @intCast(row)), s.readCell(@intCast(col), @intCast(row)));
        };
    }
}

test "a cell's glyph is printable by the screen's own width method" {
    // A Hangul vowel takes a column measured whole and none measured by
    // codepoint.
    var s = try made(2, 1);
    defer s.deinit();
    const c: Cell = .{ .text = .inlined("\u{1161}") };
    try s.writeOwnedCell(0, 0, c);
    try testing.expectEqualStrings("\u{1161}", s.textAt(0, 0));
    s.method = .wcwidth;
    try testing.expectError(error.InvalidCell, s.writeOwnedCell(1, 0, c));
    // A lone combining mark is a column only when the terminal was told
    // it: measured whole it joins the cell to its left.
    const mark: Cell = .{ .text = .inlined("\u{301}") };
    s.method = .explicit;
    try s.writeOwnedCell(1, 0, mark);
    s.method = .unicode;
    try testing.expectError(error.InvalidCell, s.writeOwnedCell(1, 0, mark));
}

test "text a terminal draws nothing for is skipped, under every width method" {
    const methods = [_]textmod.Method{ .wcwidth, .unicode, .explicit };
    for (methods) |method| {
        var s = try made(4, 2);
        defer s.deinit();
        s.method = method;
        for (0..2) |row| for (0..4) |col| try s.write(@intCast(col), @intCast(row), "z", .{}, .none);
        s.damage.clear();
        for ([_][]const u8{ "\x1b", "\u{85}", "\u{9b}", "\u{200b}", "\u{feff}", "\r\n" }) |bytes| {
            try s.write(0, 0, bytes, .{}, .none);
            try testing.expect(!try s.writeScaled(0, 0, bytes, .{}, .none, 2));
            try s.window().write(0, 0, bytes, .{}, .none);
            try testing.expect(!try s.window().writeScaled(0, 0, bytes, .{}, .none, 2));
        }
        try testing.expect(!s.damage.any());
        // A mark that begins a segment is a column only where the terminal
        // is told it; either way it is no error.
        try s.write(1, 0, "\u{301}", .{}, .none);
        try testing.expectEqualStrings(if (method == .explicit) "\u{301}" else "z", s.textAt(1, 0));
        // Bytes that are not UTF-8, and a cluster too long for the pool,
        // are the replacement character.
        try s.write(2, 0, "\xff", .{}, .none);
        try testing.expectEqualStrings("\u{fffd}", s.textAt(2, 0));
        const long = try testing.allocator.alloc(u8, 1 + 2 * 40_000);
        defer testing.allocator.free(long);
        long[0] = 'e';
        for (0..40_000) |i| @memcpy(long[1 + 2 * i ..][0..2], "\u{301}");
        try s.write(3, 0, long, .{}, .none);
        try testing.expectEqualStrings("\u{fffd}", s.textAt(3, 0));
        try testing.expectError(error.TooLong, s.intern(long));
        try checkInvariants(&s);

        // Printing measures what it draws: a control and a mark that takes
        // no column take none, and the rest of the text is where it would be.
        var printed = try made(8, 2);
        defer printed.deinit();
        printed.method = method;
        _ = try printed.window().print(&.{.{ .text = "caf\n\u{301}x" }}, .{});
        _ = try printed.window().print(&.{.{ .text = "a\u{85}b" }}, .{ .col = 4 });
        try testing.expectEqualStrings("x", printed.textAt(if (method == .explicit) 1 else 0, 1));
        try testing.expectEqualStrings("b", printed.textAt(5, 0));
        try checkInvariants(&printed);
    }
}

test "a link target or parameters too long for the table are refused by name" {
    var s = try made(2, 1);
    defer s.deinit();
    const long = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    try testing.expectError(error.TooLong, s.link(long, ""));
    try testing.expectError(error.TooLong, s.link("https://ziglang.org", long));
    try testing.expectEqual(@as(usize, 0), s.links.count());
}

test "filling with a wide or scaled cell lays whole blocks side by side" {
    var source = try made(6, 4);
    defer source.deinit();
    try source.write(0, 0, "\u{4e2d}", .{}, .none);
    _ = try source.writeScaled(0, 1, "x", .{}, .none, 2);
    const wide = source.readCell(0, 0).?;
    const scaled = source.readCell(0, 1).?;
    for ([_]bool{ false, true }) |through_window| {
        var s = try made(7, 5);
        defer s.deinit();
        if (through_window) try s.window().fill(.fromSize(s.dimensions()), wide) else try s.fill(.fromSize(s.dimensions()), wide);
        for (0..5) |row| {
            for ([_]u16{ 0, 2, 4 }) |col| {
                try testing.expectEqualStrings("\u{4e2d}", s.textAt(col, @intCast(row)));
                try testing.expect(s.readCell(col + 1, @intCast(row)).?.isTail());
            }
            // The last column has no room for a block and keeps what it had.
            try testing.expectEqualStrings(" ", s.textAt(6, @intCast(row)));
        }
        try checkInvariants(&s);

        if (through_window) try s.window().fill(.fromSize(s.dimensions()), scaled) else try s.fill(.fromSize(s.dimensions()), scaled);
        for ([_]u16{ 0, 2 }) |row| for ([_]u16{ 0, 2, 4 }) |col| {
            const head = s.readCell(col, row).?;
            try testing.expectEqualStrings("x", s.textAt(col, row));
            try testing.expectEqual(@as(u3, 2), head.rows());
        };
        try checkInvariants(&s);
    }
}

pub const test_access = if (builtin.is_test) struct {
    pub const made = madeFixture;
    pub const checkInvariants = invariantsFixture;
} else struct {};
const madeFixture = made;
const invariantsFixture = checkInvariants;
