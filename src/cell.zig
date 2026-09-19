//! What a grid holds: one cell, its grapheme, its style, its link.
//!
//! A cell is thirty-two bytes and is compared by value. The grapheme lives in
//! the cell when it is seven bytes or fewer, which covers every
//! single-codepoint cluster, and in the screen's pool when it is longer; the
//! link is an index into the screen's link table. Both are interned, so two
//! cells showing the same thing hold the same bytes, and equality is a fixed
//! size comparison rather than a string comparison.
//!
//! This file never allocates, never writes a byte to a terminal, and never
//! looks at a pool: it is the value type and nothing else. Resolving a
//! pooled grapheme or a link needs the screen that owns it.

const std = @import("std");
const morse = @import("morse");

/// Everything SGR can say about a cell. There is no second style type in this
/// package.
pub const Style = morse.Style;
/// A colour, in the forms SGR can spell.
pub const Color = morse.Color;

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

/// One cell: its grapheme, its style, its link, its width and its kind.
pub const Cell = struct {
    /// The grapheme, inline or pooled.
    text: Text = .space,
    /// The style the grapheme draws in.
    style: Style = .{},
    /// The OSC 8 target the cell belongs to.
    link: Link = .none,
    /// How wide the grapheme is and whether this cell draws it. The two share
    /// a byte because the cell is thirty-two bytes and they do not fit in one
    /// byte each.
    shape: Shape = .{},

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

        /// Whether two `Text` values name the same grapheme. True by
        /// construction: both forms are canonical and the spare bytes zero.
        pub fn eql(a: Text, b: Text) bool {
            return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
        }
    };

    /// Whether a cell draws.
    pub const Kind = enum(u1) {
        /// The cell the grapheme is written in.
        head = 0,
        /// The covered column of a wide grapheme, which never draws.
        tail = 1,
    };

    /// How wide the grapheme is, and whether this cell draws it.
    pub const Shape = packed struct(u8) {
        /// The columns the grapheme occupies: one, or two for a wide one.
        /// A tail carries the width of the head it belongs to.
        width: u2 = 1,
        /// Whether this is the cell that draws.
        kind: Kind = .head,
        /// Zero, always: the cell is compared by value.
        _reserved: u5 = 0,
    };

    /// A space in a style. What erasing writes.
    pub fn blank(style: Style) Cell {
        return .{ .text = .space, .style = style, .link = .none, .shape = .{} };
    }

    /// The cell's content with no indeterminate bytes in it: what equality
    /// and the renderer's row hash are both computed from.
    ///
    /// A `Style` holds three `Color` unions, and the bytes a union does not
    /// use are not defined. Comparing or hashing a cell's memory would
    /// therefore be answering a question about padding, so both go through
    /// this instead.
    pub const Key = extern struct {
        text: [8]u8,
        fg: u32,
        bg: u32,
        underline_color: u32,
        attrs: u16,
        link: u16,
        shape: u8,
        _pad: [3]u8,
    };

    /// The cell as a `Key`.
    pub fn key(c: Cell) Key {
        return .{
            .text = @bitCast(c.text),
            .fg = colorKey(c.style.fg),
            .bg = colorKey(c.style.bg),
            .underline_color = colorKey(c.style.underline_color),
            .attrs = attrKey(c.style),
            .link = @intFromEnum(c.link),
            .shape = @bitCast(c.shape),
            ._pad = @splat(0),
        };
    }

    /// Equality as the renderer means it: same glyph, same style, same link,
    /// same width and kind. Both graphemes and links are interned by the
    /// screen, so this is a comparison of indices and not of strings.
    pub fn eql(a: Cell, b: Cell) bool {
        const ka = a.key();
        const kb = b.key();
        return std.mem.eql(u8, std.mem.asBytes(&ka), std.mem.asBytes(&kb));
    }

    /// The columns the cell's grapheme occupies.
    pub fn width(c: Cell) u2 {
        return c.shape.width;
    }

    /// Whether the cell is the covered column of a wide grapheme.
    pub fn isTail(c: Cell) bool {
        return c.shape.kind == .tail;
    }
};

/// A colour as an integer with no indeterminate bytes: the tag in the top
/// byte, the payload under it.
fn colorKey(c: Color) u32 {
    return switch (c) {
        .default => 0,
        .ansi => |a| (1 << 24) | @as(u32, @intFromEnum(a)),
        .palette => |n| (2 << 24) | @as(u32, n),
        .rgb => |v| (3 << 24) | (@as(u32, v.r) << 16) | (@as(u32, v.g) << 8) | @as(u32, v.b),
    };
}

/// Every SGR flag of a style in one integer, the underline style in the top
/// three bits.
fn attrKey(s: Style) u16 {
    var bits: u16 = 0;
    if (s.bold) bits |= 1 << 0;
    if (s.dim) bits |= 1 << 1;
    if (s.italic) bits |= 1 << 2;
    if (s.blink) bits |= 1 << 3;
    if (s.reverse) bits |= 1 << 4;
    if (s.hidden) bits |= 1 << 5;
    if (s.strikethrough) bits |= 1 << 6;
    if (s.overline) bits |= 1 << 7;
    bits |= @as(u16, @intFromEnum(s.underline)) << 8;
    return bits;
}

comptime {
    // The whole point of the two-tier grapheme: a cell that fits in a cache
    // line four times over and is copied rather than pointed at.
    std.debug.assert(@sizeOf(Cell) == 32);
    std.debug.assert(@sizeOf(Cell.Text) == 8);
    std.debug.assert(@sizeOf(Cell.Shape) == 1);
    std.debug.assert(@sizeOf(Cell.Key) == 28);
}

test "a cell is thirty-two bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Cell));
}

test "a short grapheme lives in the cell and a long one in the pool" {
    const short: Cell.Text = .inlined("é");
    try std.testing.expect(!short.isPooled());
    try std.testing.expectEqual(@as(u16, 2), short.length());
    try std.testing.expectEqualStrings("é", short.slice(""));

    const astronaut = "\u{1f469}\u{200d}\u{1f680} in the pool";
    const long: Cell.Text = .atOffset(11, astronaut.len);
    try std.testing.expect(long.isPooled());
    try std.testing.expectEqual(@as(?u32, 11), long.offset());
    try std.testing.expectEqual(@as(u16, astronaut.len), long.length());

    var pool: [64]u8 = @splat('x');
    @memcpy(pool[11..][0..astronaut.len], astronaut);
    try std.testing.expectEqualStrings(astronaut, long.slice(&pool));
}

test "text of the same grapheme is equal and of different graphemes is not" {
    try std.testing.expect(Cell.Text.eql(.inlined("a"), .inlined("a")));
    try std.testing.expect(!Cell.Text.eql(.inlined("a"), .inlined("b")));
    try std.testing.expect(!Cell.Text.eql(.inlined("a"), .atOffset(0, 1)));
    try std.testing.expect(Cell.Text.eql(.atOffset(3, 4), .atOffset(3, 4)));
    try std.testing.expect(!Cell.Text.eql(.atOffset(3, 4), .atOffset(3, 5)));
}

test "equality reads the style through the tag and never through padding" {
    const a: Cell = .{ .text = .inlined("a"), .style = .{ .fg = .{ .ansi = .red } } };
    const b: Cell = .{ .text = .inlined("a"), .style = .{ .fg = .{ .ansi = .red } } };
    try std.testing.expect(a.eql(b));

    // `.default` and `.palette = 0` differ only by their tag, and an
    // `.ansi = .black` is a third colour again with the same payload byte.
    const d: Cell = .{ .text = .inlined("a"), .style = .{ .fg = .default } };
    const p: Cell = .{ .text = .inlined("a"), .style = .{ .fg = .{ .palette = 0 } } };
    const n: Cell = .{ .text = .inlined("a"), .style = .{ .fg = .{ .ansi = .black } } };
    try std.testing.expect(!d.eql(p));
    try std.testing.expect(!d.eql(n));
    try std.testing.expect(!p.eql(n));
}

test "a link is an index and none is the zero value" {
    const c: Cell = .{};
    try std.testing.expectEqual(Link.none, c.link);
    try std.testing.expectEqual(@as(?u16, null), Link.none.index());
    try std.testing.expectEqual(@as(?u16, 0), Link.at(0).index());
    try std.testing.expectEqual(@as(?u16, 41), Link.at(41).index());
}

test "a blank is a space in the style it was given" {
    const c: Cell = .blank(.{ .bg = .{ .ansi = .blue } });
    try std.testing.expectEqualStrings(" ", c.text.slice(""));
    try std.testing.expectEqual(@as(u2, 1), c.width());
    try std.testing.expect(!c.isTail());
    try std.testing.expect(c.eql(.blank(.{ .bg = .{ .ansi = .blue } })));
    try std.testing.expect(!c.eql(.blank(.{})));
}
