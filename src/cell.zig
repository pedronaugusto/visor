//! What a grid holds: one cell, its grapheme, its style, its link.
//!
//! A checked cell is forty-eight bytes; its stored form is thirty-two. Both
//! have no padding or indeterminate bytes. Stored cells and rows compare
//! with one `memcmp`; checked cells compare six words, including their
//! handle identities. That is what `morse.Style` being an `extern` struct
//! with a defined layout buys.
//!
//! The grapheme lives in the cell when it is six bytes or fewer, which
//! covers every single-codepoint cluster and every base-and-mark pair up to
//! two three-byte codepoints, and in the screen's pool when it is longer.
//! Pooled text and links carry the issuing pool generation, so retained
//! handles cannot name content in a different pool. Both are interned, so
//! cells showing the same thing within one generation hold the same bytes.
//!
//! This file never allocates, never writes a byte to a terminal, and never
//! looks at a pool: it is the value type and nothing else. Resolving a
//! pooled grapheme or a link needs the screen that owns it.

const std = @import("std");
const morse = @import("dependencies.zig").morse;

/// Everything SGR can say about a cell. There is no second style type here.
pub const Style = morse.Style;
/// A colour, in the forms SGR can spell.
pub const Color = morse.Color;
/// Which underline a cell carries.
pub const Underline = morse.Underline;

/// An OSC 8 handle bound to the link pool that issued it.
/// `.none` is portable; every other handle is valid only in its pool generation.
fn LinkType(comptime checked: bool) type {
    return enum(if (checked) u64 else u16) {
        none = 0,
        _,

        const Self = @This();

        /// The table position, or null for `.none`.
        pub fn index(l: Self) ?u16 {
            const payload: u16 = @truncate(@intFromEnum(l));
            return if (payload == 0) null else payload - 1;
        }

        /// The identity of the pool that issued this handle.
        pub fn generation(l: Self) u64 {
            return if (checked) @intFromEnum(l) >> 16 else 0;
        }
    };
}
pub const Link = LinkType(true);

/// The attributes a cell with no glyph in it can still show.
///
/// What decides whether a column a wide grapheme vacated has to be written
/// or can be left: a background, a reverse, a line through it or under it.
/// A bold space and a plain space are the same space.
pub fn showsOnBlank(style: Style) bool {
    return style.bg.kind != .default or style.reverse or style.blink or
        style.strikethrough or style.underline != .none;
}

/// A style whose colours hold nothing in the channels their form does not
/// use, so that two styles are equal exactly when their memory is.
///
/// `Color.eql` is field by field and forgiving: a hand-written
/// `.{ .kind = .default, .r = 9 }` is still the default colour. A cell
/// compared as memory cannot be that forgiving, so every style that goes
/// into a cell comes through here first.
pub fn canonical(style: Style) Style {
    var out = style;
    out.fg = canonicalColor(style.fg);
    out.bg = canonicalColor(style.bg);
    out.underline_color = canonicalColor(style.underline_color);
    return out;
}

/// One colour with its unused channels zeroed.
fn canonicalColor(color: Color) Color {
    return switch (color.kind) {
        .default => .default,
        .ansi => .ansi(color.toAnsi()),
        .palette => .palette(color.index()),
        .rgb => .fromRgb(color.toRgb()),
    };
}

const CellKind = enum(u2) {
    /// One column, and it draws.
    narrow = 0,
    /// Two columns, and this is the one the grapheme is written in.
    wide = 1,
    /// The covered column of a wide grapheme. Never draws.
    spacer_tail = 2,
    /// The column a wide grapheme was too late in the row to use.
    spacer_head = 3,
};

/// How wide the grapheme is, whether this cell draws it, whether the two
/// width models disagree about it, and how many cells tall it is drawn.
const CellShape = packed struct(u8) {
    /// What the cell is.
    kind: CellKind = .narrow,
    /// Whether measuring this cluster by codepoint and by cluster give
    /// different answers. Worked out once, when the cell is written, and
    /// read by the drift rule every frame.
    drift: bool = false,
    /// How many cells tall the grapheme is drawn, through the text
    /// sizing protocol. Zero and one both mean one cell. A head drawn at
    /// a scale covers that many rows and that many times its width in
    /// columns; every covered cell is a `spacer_tail` carrying the same
    /// scale, so the two kinds of tail can be told apart.
    scale: u3 = 0,
    /// Zero, always: the cell is compared as memory.
    _reserved: u2 = 0,
};

fn CellType(comptime checked: bool) type {
    return extern struct {
        const Self = @This();
        const CellLink = LinkType(checked);
        /// The OSC 8 target the cell belongs to. First, because it is the only
        /// field with the strongest alignment and the cell must have no hole in
        /// it.
        link: CellLink = .none,
        /// The grapheme, inline or pooled.
        text: Text = .space,
        /// The style the grapheme draws in, canonical: build a cell with `init`
        /// or `blank` and it is, and write one by hand and it must be.
        style: Style = .{},
        /// How wide the grapheme is, whether this cell draws it, and whether the
        /// two width models disagree about it.
        shape: Shape = .{},
        /// Zeroed tail bytes keep whole-cell memory comparison defined.
        _reserved: [if (checked) 4 else 0]u8 = @splat(0),

        /// The grapheme: up to six bytes stored in the cell, an offset into the
        /// screen's pool beyond.
        ///
        /// `len` is the byte length when the grapheme is inline and `pooled`
        /// when it is not; in the pooled case `buf` carries a `u32` offset and a
        /// `u16` length, little-endian, which is exactly the six bytes. Unused
        /// bytes are always zero. Pooled text also carries its pool generation;
        /// equality compares handles within that generation, not content across pools.
        ///
        /// Six inline bytes keep the common graphemes inside the cell while
        /// leaving room for checked handles. Six covers every single-codepoint cluster,
        /// and a base and a combining mark of three bytes each -- the warning
        /// sign with its presentation selector, which is the cluster this
        /// package cares most about, is exactly six.
        pub const Text = extern struct {
            /// The grapheme's bytes, or the offset and length of its place in
            /// the pool.
            buf: [6]u8,
            /// The issuing pool identity, zero for inline text.
            pool_generation: [if (checked) 6 else 0]u8 = @splat(0),
            /// The inline byte length, or `pooled`.
            len: u8,

            /// The most bytes a grapheme can occupy inside a cell.
            pub const max_inline = 6;
            /// The `len` value that says `buf` is an offset and a length.
            pub const pooled = std.math.maxInt(u8);

            /// A single space: what a blank cell holds.
            pub const space: Text = .{ .buf = .{ ' ', 0, 0, 0, 0, 0 }, .len = 1 };

            /// A grapheme short enough to live in the cell. Asserts it fits.
            pub fn inlined(bytes: []const u8) Text {
                std.debug.assert(bytes.len <= max_inline);
                var t: Text = .{ .buf = @splat(0), .len = @intCast(bytes.len) };
                @memcpy(t.buf[0..bytes.len], bytes);
                return t;
            }

            /// Whether the grapheme is in the pool rather than in the cell.
            pub fn isPooled(t: Text) bool {
                return t.len == pooled;
            }

            /// Where in the pool the grapheme starts, or null when it is inline.
            pub fn offset(t: Text) ?u32 {
                if (!t.isPooled()) return null;
                return std.mem.readInt(u32, t.buf[0..4], .little);
            }

            /// How many bytes the grapheme is.
            pub fn length(t: Text) u16 {
                if (!t.isPooled()) return t.len;
                return std.mem.readInt(u16, t.buf[4..6], .little);
            }

            /// Inline bytes, or null when resolving needs the issuing screen.
            pub fn inlineSlice(t: *const Text) ?[]const u8 {
                if (t.isPooled() or t.len > max_inline) return null;
                return t.buf[0..t.len];
            }

            /// The issuing pool identity, zero for inline text.
            pub fn generation(t: Text) u64 {
                return if (checked) std.mem.readInt(u48, &t.pool_generation, .little) else 0;
            }

            /// Whether the grapheme is one printable ASCII byte, which every
            /// width model measures the same way.
            pub fn isAscii(t: Text) bool {
                return t.len == 1 and t.buf[0] >= 0x20 and t.buf[0] < 0x7f;
            }

            /// Whether two texts are the same inline value or the same pooled
            /// handle. Texts from different generations are different handles.
            pub fn eql(a: Text, b: Text) bool {
                return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            }
        };

        /// What a cell is: how wide the grapheme is and whether this cell is the
        /// one that draws it.
        ///
        /// `spacer_tail` is the covered second column of a wide grapheme.
        /// `spacer_head` is the blank a wrap leaves at the end of a row when the
        /// wide grapheme that would have gone there did not fit and went to the
        /// next row instead: it is not a space anyone asked for, and the diff
        /// and the drift repaint both have to be able to tell it from one.
        pub const Kind = CellKind;
        pub const Shape = CellShape;

        /// A space in a style. What erasing writes.
        pub fn blank(in: Style) Self {
            return .{ .text = .space, .style = canonical(in), .link = .none, .shape = .{} };
        }

        /// A value holding a grapheme. This canonicalizes style; Screen.cell or
        /// placement checks glyph, shape and handles before importing it.
        pub fn init(args: struct {
            text: Text = .space,
            style: Style = .{},
            link: CellLink = .none,
            shape: Shape = .{},
        }) Self {
            return .{
                .text = args.text,
                .style = canonical(args.style),
                .link = args.link,
                .shape = args.shape,
            };
        }

        /// Puts a style on the cell.
        pub fn setStyle(c: *Self, to: Style) void {
            c.style = canonical(to);
        }

        /// Equality as the renderer means it: same glyph, same style, same link,
        /// same shape. Both graphemes and links are interned by the screen, so
        /// this is a comparison of indices and not of strings, and the cell has
        /// no undefined byte in it, so every byte participates in equality.
        /// Checked values compare words without assembling a byte vector;
        /// compact stored values keep the renderer's memory comparison.
        pub fn eql(a: Self, b: Self) bool {
            return equalValue(a, b);
        }

        inline fn equalValue(a: Self, b: Self) bool {
            if (!checked) return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            const aw: [6]u64 = @bitCast(a);
            const bw: [6]u64 = @bitCast(b);
            inline for (aw, bw) |av, bv| if (av != bv) return false;
            return true;
        }

        /// The columns the cell's grapheme takes before any scaling: one or two.
        pub fn glyphWidth(c: Self) u2 {
            return switch (c.shape.kind) {
                .narrow, .spacer_head => 1,
                .wide, .spacer_tail => 2,
            };
        }

        /// The columns the cell covers on its own row: the grapheme's width,
        /// times the scale it is drawn at.
        pub fn width(c: Self) u4 {
            return @as(u4, c.glyphWidth()) * c.rows();
        }

        /// The rows the cell covers: one, or the scale it is drawn at.
        pub fn rows(c: Self) u3 {
            return @max(c.shape.scale, 1);
        }

        /// Whether the cell is drawn at more than one cell's size, or is covered
        /// by one that is.
        pub fn isScaled(c: Self) bool {
            return c.shape.scale > 1;
        }

        /// Whether the cell is the covered column of a wide grapheme.
        pub fn isTail(c: Self) bool {
            return c.shape.kind == .spacer_tail;
        }

        /// Whether the cell is the one a grapheme is written in.
        pub fn isHead(c: Self) bool {
            return c.shape.kind == .narrow or c.shape.kind == .wide;
        }

        /// Whether the cell draws a space in `in` and nothing else.
        ///
        /// A `spacer_head` counts: it is a space on the terminal, and the only
        /// thing that knows it was left by a wrap rather than asked for is this
        /// package. What can be erased is decided by what the terminal shows.
        pub fn isBlankIn(c: Self, in: Style) bool {
            if (c.link != .none) return false;
            if (c.shape.kind != .narrow and c.shape.kind != .spacer_head) return false;
            if (!Text.eql(c.text, .space)) return false;
            const want = canonical(in);
            return std.mem.eql(u8, std.mem.asBytes(&c.style), std.mem.asBytes(&want));
        }
    };
}
/// A checked cell value. Screen exports its handles and checks imported values.
pub const Cell = CellType(true);

// Package storage, never exported by visor. Pool identities live on Screen.
pub const internal = struct {
    pub const StoredCell = CellType(false);

    // Clipping uses the full head extent; imported continuation cells
    // become one blank cell when placed independently.
    pub fn fits(c: Cell, col: u16, row: u16, size: @import("geom.zig").Size) bool {
        const span: u16 = if (c.isTail() or c.shape.kind == .spacer_head) 1 else c.width();
        const height: u16 = if (c.isTail() or c.shape.kind == .spacer_head) 1 else c.rows();
        return col < size.cols and row < size.rows and @as(u32, col) + span <= size.cols and @as(u32, row) + height <= size.rows;
    }

    pub fn store(c: Cell) StoredCell {
        return .{ .text = .{ .buf = c.text.buf, .len = c.text.len }, .link = @enumFromInt(@as(u16, @truncate(@intFromEnum(c.link)))), .style = canonical(c.style), .shape = c.shape };
    }
    pub inline fn exportCell(c: *const StoredCell, generation: u64) Cell {
        // Copy the contiguous payload before adding checked handle identities.
        // Keeping these as byte ranges avoids rebuilding each style byte in
        // a vector when a caller immediately compares the exported value.
        const checked_text = @offsetOf(Cell, "text");
        const stored_text = @offsetOf(StoredCell, "text");
        const checked_len = checked_text + @offsetOf(Cell.Text, "len");
        const stored_len = stored_text + @offsetOf(StoredCell.Text, "len");
        const payload_len = @sizeOf(StoredCell) - stored_len;
        comptime {
            std.debug.assert(@offsetOf(Cell, "style") == checked_len + 1);
            std.debug.assert(@offsetOf(StoredCell, "style") == stored_len + 1);
            std.debug.assert(@offsetOf(Cell, "shape") == checked_len + payload_len - 1);
            std.debug.assert(@offsetOf(StoredCell, "shape") == @sizeOf(StoredCell) - 1);
        }
        var bytes: [@sizeOf(Cell)]u8 = @splat(0);
        const raw = std.mem.asBytes(c);
        const link = exportLink(c.link, generation);
        @memcpy(bytes[@offsetOf(Cell, "link")..][0..@sizeOf(Link)], std.mem.asBytes(&link));
        @memcpy(bytes[checked_text..][0..Cell.Text.max_inline], raw[stored_text..][0..Cell.Text.max_inline]);
        @memcpy(bytes[checked_len..][0..payload_len], raw[stored_len..][0..payload_len]);
        if (c.text.isPooled()) {
            const identity = checked_text + @offsetOf(Cell.Text, "pool_generation");
            std.mem.writeInt(u48, bytes[identity..][0..6], @intCast(generation), .little);
        }
        return @bitCast(bytes);
    }
    pub fn exportLink(link: LinkType(false), generation: u64) Link {
        return if (link == .none) .none else @enumFromInt((generation << 16) | @intFromEnum(link));
    }
};

/// Whether two rows hold the same thing. One `memcmp`, which is what the
/// whole layout of `Cell` is for.
pub fn rowsEqual(a: []const Cell, b: []const Cell) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

comptime {
    // The whole point of the two-tier grapheme and morse's defined style
    // layout: a value carrying checked handles, compared without reading
    // a byte no one wrote.
    std.debug.assert(@sizeOf(internal.StoredCell) == 32);
    std.debug.assert(@bitSizeOf(internal.StoredCell) == 256);
    std.debug.assert(@sizeOf(Cell) == 48);
    std.debug.assert(@bitSizeOf(Cell) == 48 * 8);
    std.debug.assert(@sizeOf(Cell.Text) == 13);
    std.debug.assert(@sizeOf(Style) == 22);
    std.debug.assert(@sizeOf(Cell.Shape) == 1);
}

const testing = std.testing;

test "a cell is forty-eight bytes with no padding in it" {
    try testing.expectEqual(@as(usize, 48), @sizeOf(Cell));
    try testing.expectEqual(@as(usize, 48 * 8), @bitSizeOf(Cell));
}

test "two cells built the same way are the same memory" {
    const a: Cell = .init(.{
        .text = .inlined("x"),
        .style = .{ .fg = .ansi(.red), .bold = true },
    });
    const b: Cell = .init(.{
        .text = .inlined("x"),
        .style = .{ .fg = .ansi(.red), .bold = true },
    });
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    try testing.expect(a.eql(b));
}

test "a style survives the trip through the cell's own form" {
    const cases = [_]Style{
        .{},
        .{ .bold = true, .dim = true, .italic = true, .blink = true },
        .{ .reverse = true, .hidden = true, .strikethrough = true, .overline = true },
        .{ .fg = .ansi(.bright_magenta), .bg = .palette(231) },
        .{ .fg = .rgb(1, 2, 3) },
        .{ .underline = .curly, .underline_color = .rgb(9, 8, 7) },
        .{ .underline = .dashed, .underline_color = .ansi(.green) },
    };
    for (cases) |style| {
        var c: Cell = .blank(style);
        try testing.expectEqual(style, c.style);
        c.setStyle(style);
        try testing.expectEqual(style, c.style);
    }
}

test "colours that differ only by their form are different cells" {
    const d: Cell = .blank(.{ .fg = .default });
    const p: Cell = .blank(.{ .fg = .palette(0) });
    const n: Cell = .blank(.{ .fg = .ansi(.black) });
    try testing.expect(!d.eql(p));
    try testing.expect(!d.eql(n));
    try testing.expect(!p.eql(n));
}

test "inline text is portable and canonical" {
    const short: Cell.Text = .inlined("é");
    try testing.expect(!short.isPooled());
    try testing.expectEqual(@as(u16, 2), short.length());
    try testing.expectEqualStrings("é", short.inlineSlice().?);
    try testing.expect(Cell.Text.eql(.inlined("a"), .inlined("a")));
    try testing.expect(!Cell.Text.eql(.inlined("a"), .inlined("b")));
}

test "one printable ascii byte is the fast path and nothing else is" {
    try testing.expect(Cell.Text.inlined("a").isAscii());
    try testing.expect(Cell.Text.inlined(" ").isAscii());
    try testing.expect(!Cell.Text.inlined("\u{e9}").isAscii());
}

test "a link is an index and none is the zero value" {
    const c: Cell = .{};
    try testing.expectEqual(Link.none, c.link);
    try testing.expectEqual(@as(?u16, null), Link.none.index());
}

test "a blank is a space in the style it was given" {
    const c: Cell = .blank(.{ .bg = .ansi(.blue) });
    try testing.expectEqualStrings(" ", c.text.inlineSlice().?);
    try testing.expectEqual(@as(u4, 1), c.width());
    try testing.expect(!c.isTail());
    try testing.expect(c.isHead());
    try testing.expect(c.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(!c.eql(.blank(.{})));
}

test "width comes from the kind and needs no field of its own" {
    try testing.expectEqual(@as(u4, 1), (Cell{ .shape = .{ .kind = .narrow } }).width());
    try testing.expectEqual(@as(u4, 2), (Cell{ .shape = .{ .kind = .wide } }).width());
    try testing.expectEqual(@as(u4, 2), (Cell{ .shape = .{ .kind = .spacer_tail } }).width());
    try testing.expectEqual(@as(u4, 1), (Cell{ .shape = .{ .kind = .spacer_head } }).width());
    // A scale multiplies the columns and is the rows.
    const big: Cell = .{ .shape = .{ .kind = .wide, .scale = 3 } };
    try testing.expectEqual(@as(u4, 6), big.width());
    try testing.expectEqual(@as(u3, 3), big.rows());
    try testing.expectEqual(@as(u2, 2), big.glyphWidth());
    try testing.expect(big.isScaled());
    try testing.expect(!(Cell{ .shape = .{ .scale = 1 } }).isScaled());
}

test "what is still visible on a cell with no glyph in it" {
    try testing.expect(!showsOnBlank(.{}));
    try testing.expect(!showsOnBlank(.{ .bold = true }));
    try testing.expect(!showsOnBlank(.{ .italic = true }));
    try testing.expect(!showsOnBlank(.{ .fg = .ansi(.red) }));
    try testing.expect(showsOnBlank(.{ .bg = .ansi(.red) }));
    try testing.expect(showsOnBlank(.{ .reverse = true }));
    try testing.expect(showsOnBlank(.{ .underline = .single }));
    try testing.expect(showsOnBlank(.{ .strikethrough = true }));
    try testing.expect(showsOnBlank(.{ .blink = true }));
}

test "a style with rubbish in the channels a colour does not use is still that colour" {
    const odd: Style = .{ .fg = .{ .kind = .default, .r = 9, .g = 8, .b = 7 } };
    const plain: Cell = .blank(.{});
    try testing.expect(plain.eql(.blank(odd)));
    try testing.expect(plain.isBlankIn(odd));
}

test "a row is compared with one memcmp" {
    var a: [8]Cell = @splat(.blank(.{}));
    var b: [8]Cell = @splat(.blank(.{}));
    try testing.expect(rowsEqual(&a, &b));
    a[5] = .init(.{ .text = .inlined("q") });
    try testing.expect(!rowsEqual(&a, &b));
    b[5] = .init(.{ .text = .inlined("q") });
    try testing.expect(rowsEqual(&a, &b));
    try testing.expect(!rowsEqual(a[0..4], b[0..5]));
}

test "cell equality includes every checked and compact byte" {
    inline for (.{ Cell, internal.StoredCell }) |Value| {
        const a: Value = .blank(.{});
        const eql: *const fn (Value, Value) bool = &Value.eql;
        try testing.expect(eql(a, a));
        for (0..@sizeOf(Value)) |i| {
            var b = a;
            std.mem.asBytes(&b)[i] ^= 1;
            try testing.expect(!a.eql(b));
            try testing.expect(!b.eql(a));
        }
    }
}
