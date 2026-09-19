//! What a grid holds: one cell, its grapheme, its style, its link.
//!
//! A cell is thirty-two bytes, has no padding and no indeterminate byte in
//! it, and is therefore compared — a cell, or a whole row — with one
//! `memcmp`. The grapheme lives in the cell when it is seven bytes or fewer,
//! which covers every single-codepoint cluster, and in the screen's pool when
//! it is longer; the link is an index into the screen's link table. Both are
//! interned, so two cells showing the same thing hold the same bytes.
//!
//! The style is stored as `Style.Bits`, a mirror of `Style` with an `extern`
//! layout and no union in it. The public type a caller writes and reads is
//! always `Style`, which is morse's; the mirror exists because a union's
//! unused payload bytes are not defined, so a comparison of the memory of a
//! cell holding one would be a question about padding. `Cell.style()` and
//! `Cell.setStyle` are the one conversion, and the mirror goes away the day
//! morse's own style is `extern`.
//!
//! This file never allocates, never writes a byte to a terminal, and never
//! looks at a pool: it is the value type and nothing else. Resolving a
//! pooled grapheme or a link needs the screen that owns it.

const std = @import("std");
const morse = @import("morse");

/// Everything SGR can say about a cell. There is no second style type in
/// this package's API.
pub const Style = morse.Style;
/// A colour, in the forms SGR can spell.
pub const Color = morse.Color;
/// Which underline a cell carries.
pub const Underline = morse.Underline;

/// An OSC 8 target, as an index into the screen's link table.
///
/// `.none` is zero, so a zeroed cell carries no link. The payload counts from
/// one; `index` gives the table position back.
pub const Link = enum(u16) {
    /// No link. What almost every cell carries.
    none = 0,
    _,

    /// The link table position, or null for `.none`.
    pub fn index(l: Link) ?u16 {
        return if (l == .none) null else @intFromEnum(l) - 1;
    }

    /// The link for table position `i`.
    pub fn at(i: u16) Link {
        return @enumFromInt(i + 1);
    }
};

/// A colour with every byte defined: the form a cell stores.
///
/// `Color` is a tagged union and the bytes its payload does not use are not
/// specified, so two cells showing the same colour need not hold the same
/// memory. Here the tag is a byte and the three payload bytes are zero
/// wherever the form does not use them.
pub const ColorBits = extern struct {
    /// Which form the colour takes.
    tag: Tag = .default,
    /// The palette index for `.ansi` and `.palette`, red for `.rgb`.
    a: u8 = 0,
    /// Green for `.rgb`, zero otherwise.
    b: u8 = 0,
    /// Blue for `.rgb`, zero otherwise.
    c: u8 = 0,

    /// The forms SGR can spell.
    pub const Tag = enum(u8) { default = 0, ansi = 1, palette = 2, rgb = 3 };

    /// The terminal's own colour.
    pub const default: ColorBits = .{};

    /// A colour packed into its defined form.
    pub fn from(color: Color) ColorBits {
        return switch (color) {
            .default => .{ .tag = .default },
            .ansi => |v| .{ .tag = .ansi, .a = @intFromEnum(v) },
            .palette => |n| .{ .tag = .palette, .a = n },
            .rgb => |v| .{ .tag = .rgb, .a = v.r, .b = v.g, .c = v.b },
        };
    }

    /// The colour back in the form the API speaks.
    pub fn to(bits: ColorBits) Color {
        return switch (bits.tag) {
            .default => .default,
            .ansi => .{ .ansi = @enumFromInt(bits.a & 0x0f) },
            .palette => .{ .palette = bits.a },
            .rgb => .{ .rgb = .{ .r = bits.a, .g = bits.b, .b = bits.c } },
        };
    }
};

/// One cell: its grapheme, its style, its link, its width and its kind.
pub const Cell = extern struct {
    /// The OSC 8 target the cell belongs to. First, because it is the only
    /// field that wants two-byte alignment and the cell must have no hole in
    /// it.
    link: Link = .none,
    /// The grapheme, inline or pooled.
    text: Text = .space,
    /// The style, in its defined form. Read it with `style()`.
    bits: Bits = .{},
    /// How wide the grapheme is, whether this cell draws it, and whether the
    /// two width models disagree about it.
    shape: Shape = .{},
    /// Zero, always. Room for what the text sizing protocol and the layers
    /// will want, and the reason a cell compares as memory.
    _reserved: [7]u8 = @splat(0),

    /// The grapheme: up to seven bytes stored in the cell, an offset into the
    /// screen's pool beyond.
    ///
    /// `len` is the byte length when the grapheme is inline and `pooled` when
    /// it is not; in the pooled case `buf` carries a `u32` offset and a `u16`
    /// length, little-endian. Unused bytes are always zero, so two `Text`
    /// values are equal exactly when the graphemes they name are.
    pub const Text = extern struct {
        /// The grapheme's bytes, or the offset and length of its place in the
        /// pool.
        buf: [7]u8,
        /// The inline byte length, or `pooled`.
        len: u8,

        /// The most bytes a grapheme can occupy inside a cell.
        pub const max_inline = 7;
        /// The `len` value that says `buf` is an offset and a length.
        pub const pooled = std.math.maxInt(u8);

        /// A single space: what a blank cell holds.
        pub const space: Text = .{ .buf = .{ ' ', 0, 0, 0, 0, 0, 0 }, .len = 1 };

        /// A grapheme short enough to live in the cell. Asserts it fits.
        pub fn inlined(bytes: []const u8) Text {
            std.debug.assert(bytes.len <= max_inline);
            var t: Text = .{ .buf = @splat(0), .len = @intCast(bytes.len) };
            @memcpy(t.buf[0..bytes.len], bytes);
            return t;
        }

        /// A grapheme that lives in the screen's pool.
        pub fn atOffset(pool_offset: u32, byte_len: u16) Text {
            var t: Text = .{ .buf = @splat(0), .len = pooled };
            std.mem.writeInt(u32, t.buf[0..4], pool_offset, .little);
            std.mem.writeInt(u16, t.buf[4..6], byte_len, .little);
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

        /// The grapheme's bytes, read out of `pool` when it is not inline.
        ///
        /// Taken by pointer: a short grapheme lives in the `Text` itself, so
        /// what comes back borrows from whatever holds it.
        pub fn slice(t: *const Text, pool: []const u8) []const u8 {
            if (!t.isPooled()) return t.buf[0..t.len];
            const off = std.mem.readInt(u32, t.buf[0..4], .little);
            const n = std.mem.readInt(u16, t.buf[4..6], .little);
            return pool[off..][0..n];
        }

        /// Whether the grapheme is one printable ASCII byte, which every
        /// width model measures the same way. The drift scan asks this first.
        pub fn isAscii(t: Text) bool {
            return t.len == 1 and t.buf[0] >= 0x20 and t.buf[0] < 0x7f;
        }

        /// Whether two `Text` values name the same grapheme. True by
        /// construction: both forms are canonical and the spare bytes zero.
        pub fn eql(a: Text, b: Text) bool {
            return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
        }
    };

    /// A style with every byte defined: what a cell stores.
    ///
    /// The same information as `Style`, laid out so that a cell can be
    /// compared as memory. `Style` stays the type the API speaks.
    pub const Bits = extern struct {
        /// The colour of the glyphs.
        fg: ColorBits = .{},
        /// The colour of the cell behind them.
        bg: ColorBits = .{},
        /// The colour of the underline, independent of `fg`.
        underline_color: ColorBits = .{},
        /// The SGR flags in the low eight bits and the underline style in
        /// the next three.
        attrs: u16 = 0,

        const bold: u16 = 1 << 0;
        const dim: u16 = 1 << 1;
        const italic: u16 = 1 << 2;
        const blink: u16 = 1 << 3;
        const reverse: u16 = 1 << 4;
        const hidden: u16 = 1 << 5;
        const strikethrough: u16 = 1 << 6;
        const overline: u16 = 1 << 7;
        const underline_shift: u4 = 8;

        /// The attributes a blank cell can still show, so that erasing a
        /// wide grapheme has to repaint the column it covered rather than
        /// leaving whatever was under it.
        const visible_on_blank: u16 = reverse | hidden | blink | strikethrough |
            (0b111 << underline_shift);

        /// A style packed into its defined form.
        pub fn from(from_style: Style) Bits {
            var attrs: u16 = 0;
            if (from_style.bold) attrs |= bold;
            if (from_style.dim) attrs |= dim;
            if (from_style.italic) attrs |= italic;
            if (from_style.blink) attrs |= blink;
            if (from_style.reverse) attrs |= reverse;
            if (from_style.hidden) attrs |= hidden;
            if (from_style.strikethrough) attrs |= strikethrough;
            if (from_style.overline) attrs |= overline;
            attrs |= @as(u16, @intFromEnum(from_style.underline)) << underline_shift;
            return .{
                .fg = .from(from_style.fg),
                .bg = .from(from_style.bg),
                .underline_color = .from(from_style.underline_color),
                .attrs = attrs,
            };
        }

        /// The style back in the form the API speaks.
        pub fn to(b: Bits) Style {
            return .{
                .fg = b.fg.to(),
                .bg = b.bg.to(),
                .underline_color = b.underline_color.to(),
                .bold = b.attrs & bold != 0,
                .dim = b.attrs & dim != 0,
                .italic = b.attrs & italic != 0,
                .underline = @enumFromInt(@as(u3, @truncate(b.attrs >> underline_shift))),
                .blink = b.attrs & blink != 0,
                .reverse = b.attrs & reverse != 0,
                .hidden = b.attrs & hidden != 0,
                .strikethrough = b.attrs & strikethrough != 0,
                .overline = b.attrs & overline != 0,
            };
        }

        /// Whether anything about this style is still visible on a cell with
        /// no glyph in it: a background, a reverse, a line through it. What
        /// decides whether a column a wide grapheme vacated has to be
        /// written or can be left.
        pub fn showsOnBlank(b: Bits) bool {
            return b.bg.tag != .default or b.attrs & visible_on_blank != 0;
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
    pub const Kind = enum(u2) {
        /// One column, and it draws.
        narrow = 0,
        /// Two columns, and this is the one the grapheme is written in.
        wide = 1,
        /// The covered column of a wide grapheme. Never draws.
        spacer_tail = 2,
        /// The column a wide grapheme was too late in the row to use.
        spacer_head = 3,
    };

    /// How wide the grapheme is, whether this cell draws it, and whether the
    /// two width models disagree about it.
    pub const Shape = packed struct(u8) {
        /// What the cell is.
        kind: Kind = .narrow,
        /// Whether measuring this cluster by codepoint and by cluster give
        /// different answers. Worked out once, when the cell is written, and
        /// read by the drift rule every frame.
        drift: bool = false,
        /// Zero, always: the cell is compared as memory.
        _reserved: u5 = 0,
    };

    /// A space in a style. What erasing writes.
    pub fn blank(in: Style) Cell {
        return .{ .text = .space, .bits = .from(in), .link = .none, .shape = .{} };
    }

    /// A cell holding a grapheme.
    pub fn init(args: struct {
        text: Text = .space,
        style: Style = .{},
        link: Link = .none,
        shape: Shape = .{},
    }) Cell {
        return .{
            .text = args.text,
            .bits = .from(args.style),
            .link = args.link,
            .shape = args.shape,
        };
    }

    /// The style the cell draws in.
    pub fn style(c: Cell) Style {
        return c.bits.to();
    }

    /// Puts a style on the cell.
    pub fn setStyle(c: *Cell, to: Style) void {
        c.bits = .from(to);
    }

    /// Equality as the renderer means it: same glyph, same style, same link,
    /// same shape. Both graphemes and links are interned by the screen, so
    /// this is a comparison of indices and not of strings, and the cell has
    /// no undefined byte in it, so it is a comparison of memory.
    pub fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }

    /// The columns the cell's grapheme occupies.
    pub fn width(c: Cell) u2 {
        return switch (c.shape.kind) {
            .narrow, .spacer_head => 1,
            .wide, .spacer_tail => 2,
        };
    }

    /// Whether the cell is the covered column of a wide grapheme.
    pub fn isTail(c: Cell) bool {
        return c.shape.kind == .spacer_tail;
    }

    /// Whether the cell is the one a grapheme is written in.
    pub fn isHead(c: Cell) bool {
        return c.shape.kind == .narrow or c.shape.kind == .wide;
    }

    /// Whether the cell draws a space in `in` and nothing else.
    ///
    /// A `spacer_head` counts: it is a space on the terminal, and the only
    /// thing that knows it was left by a wrap rather than asked for is this
    /// package. What can be erased is decided by what the terminal shows.
    pub fn isBlankIn(c: Cell, in: Style) bool {
        if (c.link != .none) return false;
        if (c.shape.kind != .narrow and c.shape.kind != .spacer_head) return false;
        if (!Text.eql(c.text, .space)) return false;
        return std.mem.eql(u8, std.mem.asBytes(&c.bits), std.mem.asBytes(&Bits.from(in)));
    }
};

/// Whether two rows hold the same thing. One `memcmp`, which is what the
/// whole layout of `Cell` is for.
pub fn rowsEqual(a: []const Cell, b: []const Cell) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

comptime {
    // The whole point of the two-tier grapheme and the mirrored style: a
    // cell that fits in a cache line four times over, is copied rather than
    // pointed at, and is compared without reading a byte no one wrote.
    std.debug.assert(@sizeOf(Cell) == 32);
    std.debug.assert(@bitSizeOf(Cell) == 32 * 8);
    std.debug.assert(@sizeOf(Cell.Text) == 8);
    std.debug.assert(@sizeOf(Cell.Bits) == 14);
    std.debug.assert(@sizeOf(Cell.Shape) == 1);
    std.debug.assert(@sizeOf(ColorBits) == 4);
}

const testing = std.testing;

test "a cell is thirty-two bytes with no padding in it" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Cell));
    try testing.expectEqual(@as(usize, 32 * 8), @bitSizeOf(Cell));
}

test "two cells built the same way are the same memory" {
    const a: Cell = .init(.{
        .text = .inlined("x"),
        .style = .{ .fg = .{ .ansi = .red }, .bold = true },
    });
    const b: Cell = .init(.{
        .text = .inlined("x"),
        .style = .{ .fg = .{ .ansi = .red }, .bold = true },
    });
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    try testing.expect(a.eql(b));
}

test "a style survives the trip through the cell's own form" {
    const cases = [_]Style{
        .{},
        .{ .bold = true, .dim = true, .italic = true, .blink = true },
        .{ .reverse = true, .hidden = true, .strikethrough = true, .overline = true },
        .{ .fg = .{ .ansi = .bright_magenta }, .bg = .{ .palette = 231 } },
        .{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
        .{ .underline = .curly, .underline_color = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } } },
        .{ .underline = .dashed, .underline_color = .{ .ansi = .green } },
    };
    for (cases) |style| {
        var c: Cell = .blank(style);
        try testing.expectEqual(style, c.style());
        c.setStyle(style);
        try testing.expectEqual(style, c.style());
    }
}

test "colours that differ only by their form are different cells" {
    const d: Cell = .blank(.{ .fg = .default });
    const p: Cell = .blank(.{ .fg = .{ .palette = 0 } });
    const n: Cell = .blank(.{ .fg = .{ .ansi = .black } });
    try testing.expect(!d.eql(p));
    try testing.expect(!d.eql(n));
    try testing.expect(!p.eql(n));
}

test "a short grapheme lives in the cell and a long one in the pool" {
    const short: Cell.Text = .inlined("é");
    try testing.expect(!short.isPooled());
    try testing.expectEqual(@as(u16, 2), short.length());
    try testing.expectEqualStrings("é", short.slice(""));

    const astronaut = "\u{1f469}\u{200d}\u{1f680} in the pool";
    const long: Cell.Text = .atOffset(11, astronaut.len);
    try testing.expect(long.isPooled());
    try testing.expectEqual(@as(?u32, 11), long.offset());
    try testing.expectEqual(@as(u16, astronaut.len), long.length());

    var pool: [64]u8 = @splat('x');
    @memcpy(pool[11..][0..astronaut.len], astronaut);
    try testing.expectEqualStrings(astronaut, long.slice(&pool));
}

test "text of the same grapheme is equal and of different graphemes is not" {
    try testing.expect(Cell.Text.eql(.inlined("a"), .inlined("a")));
    try testing.expect(!Cell.Text.eql(.inlined("a"), .inlined("b")));
    try testing.expect(!Cell.Text.eql(.inlined("a"), .atOffset(0, 1)));
    try testing.expect(Cell.Text.eql(.atOffset(3, 4), .atOffset(3, 4)));
    try testing.expect(!Cell.Text.eql(.atOffset(3, 4), .atOffset(3, 5)));
}

test "one printable ascii byte is the fast path and nothing else is" {
    try testing.expect(Cell.Text.inlined("a").isAscii());
    try testing.expect(Cell.Text.inlined(" ").isAscii());
    try testing.expect(!Cell.Text.inlined("\u{e9}").isAscii());
    try testing.expect(!Cell.Text.atOffset(0, 9).isAscii());
}

test "a link is an index and none is the zero value" {
    const c: Cell = .{};
    try testing.expectEqual(Link.none, c.link);
    try testing.expectEqual(@as(?u16, null), Link.none.index());
    try testing.expectEqual(@as(?u16, 0), Link.at(0).index());
    try testing.expectEqual(@as(?u16, 41), Link.at(41).index());
}

test "a blank is a space in the style it was given" {
    const c: Cell = .blank(.{ .bg = .{ .ansi = .blue } });
    try testing.expectEqualStrings(" ", c.text.slice(""));
    try testing.expectEqual(@as(u2, 1), c.width());
    try testing.expect(!c.isTail());
    try testing.expect(c.isHead());
    try testing.expect(c.eql(.blank(.{ .bg = .{ .ansi = .blue } })));
    try testing.expect(!c.eql(.blank(.{})));
}

test "width comes from the kind and needs no field of its own" {
    try testing.expectEqual(@as(u2, 1), (Cell{ .shape = .{ .kind = .narrow } }).width());
    try testing.expectEqual(@as(u2, 2), (Cell{ .shape = .{ .kind = .wide } }).width());
    try testing.expectEqual(@as(u2, 2), (Cell{ .shape = .{ .kind = .spacer_tail } }).width());
    try testing.expectEqual(@as(u2, 1), (Cell{ .shape = .{ .kind = .spacer_head } }).width());
}

test "what is still visible on a cell with no glyph in it" {
    const plain: Cell.Bits = .from(.{});
    try testing.expect(!plain.showsOnBlank());
    try testing.expect(!(Cell.Bits.from(.{ .bold = true })).showsOnBlank());
    try testing.expect(!(Cell.Bits.from(.{ .italic = true })).showsOnBlank());
    try testing.expect(!(Cell.Bits.from(.{ .fg = .{ .ansi = .red } })).showsOnBlank());
    try testing.expect((Cell.Bits.from(.{ .bg = .{ .ansi = .red } })).showsOnBlank());
    try testing.expect((Cell.Bits.from(.{ .reverse = true })).showsOnBlank());
    try testing.expect((Cell.Bits.from(.{ .underline = .single })).showsOnBlank());
    try testing.expect((Cell.Bits.from(.{ .strikethrough = true })).showsOnBlank());
    try testing.expect((Cell.Bits.from(.{ .blink = true })).showsOnBlank());
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
