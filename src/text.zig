//! Measuring and breaking text: how many columns a string takes, where its
//! grapheme clusters are, and where a line can be broken.
//!
//! The tables come from `uucode`, configured at build time with the fields
//! this package uses and no others. Nothing here allocates, nothing here
//! holds state, and nothing here reads an environment variable: a caller who
//! knows the terminal measures by codepoint rather than by cluster says so in
//! `Caps.width_method` and this file obeys it.
//!
//! What this file will never hold: a line-breaking algorithm with a
//! dictionary, bidirectional reordering, or shaping. A program drawing into
//! cells does not need them, and a terminal that does has its own.

const std = @import("std");
const uucode = @import("uucode");

/// How the terminal measures text.
pub const Method = enum {
    /// One width per codepoint, the oldest rule, and what a terminal that has
    /// not said otherwise is assumed to use.
    wcwidth,
    /// One width per grapheme cluster, which is mode 2027 and what a terminal
    /// that answered for it does.
    unicode,
    /// The terminal was told the width, so it is whatever it was told. The
    /// caller measures; this returns the cluster's cell count unchanged.
    explicit,
};

/// How a line that does not fit is broken.
pub const Wrap = enum {
    /// Not at all: what does not fit is dropped.
    none,
    /// Anywhere between two grapheme clusters.
    grapheme,
    /// At a space where there is one, and between clusters where there is not.
    word,
};

/// The codepoints of a string of UTF-8, decoded the way a terminal decodes
/// them: each maximal subpart of an ill-formed sequence is one replacement
/// character and consumes only its own bytes (Unicode's "substitution of
/// maximal subparts"). A byte that ends an ill-formed sequence by not
/// continuing it is where the next codepoint starts, so `"\xe4\xb8"` before
/// a flag is one replacement character and the flag is still a flag.
const Utf8 = struct {
    /// Where the next codepoint starts, which the grapheme iterator reads.
    i: usize = 0,
    bytes: []const u8,

    fn init(bytes: []const u8) Utf8 {
        return .{ .bytes = bytes };
    }

    pub fn next(it: *Utf8) ?u21 {
        const bytes = it.bytes;
        if (it.i >= bytes.len) return null;
        const start = it.i;
        const lead = bytes[start];
        if (lead < 0x80) {
            it.i += 1;
            return lead;
        }
        // How many bytes follow, and the range the first of them must be
        // in: the ranges past the lead are what rule out overlong forms,
        // surrogates and codepoints past U+10FFFF.
        const shape: struct { more: u8, lo: u8, hi: u8, bits: u8 } = switch (lead) {
            0xc2...0xdf => .{ .more = 1, .lo = 0x80, .hi = 0xbf, .bits = 0x1f },
            0xe0 => .{ .more = 2, .lo = 0xa0, .hi = 0xbf, .bits = 0x0f },
            0xe1...0xec, 0xee, 0xef => .{ .more = 2, .lo = 0x80, .hi = 0xbf, .bits = 0x0f },
            0xed => .{ .more = 2, .lo = 0x80, .hi = 0x9f, .bits = 0x0f },
            0xf0 => .{ .more = 3, .lo = 0x90, .hi = 0xbf, .bits = 0x07 },
            0xf1...0xf3 => .{ .more = 3, .lo = 0x80, .hi = 0xbf, .bits = 0x07 },
            0xf4 => .{ .more = 3, .lo = 0x80, .hi = 0x8f, .bits = 0x07 },
            else => {
                it.i += 1;
                return replacement;
            },
        };
        var cp: u21 = lead & shape.bits;
        var k: usize = 1;
        while (k <= shape.more) : (k += 1) {
            const at = start + k;
            if (at >= bytes.len) {
                it.i = at;
                return replacement;
            }
            const b = bytes[at];
            const lo: u8 = if (k == 1) shape.lo else 0x80;
            const hi: u8 = if (k == 1) shape.hi else 0xbf;
            if (b < lo or b > hi) {
                it.i = at;
                return replacement;
            }
            cp = (cp << 6) | (b & 0x3f);
        }
        it.i = start + 1 + shape.more;
        return cp;
    }

    const replacement: u21 = 0xfffd;
};

/// An iterator over the grapheme clusters of a string.
///
/// Bytes that are not UTF-8 are clusters of their own, one a maximal
/// subpart, which is what a terminal draws a replacement character for.
pub const Graphemes = struct {
    bytes: []const u8,
    inner: uucode.grapheme.Iterator(Utf8),
    ascii_at: ?usize = null,

    /// The clusters of `bytes`, in order.
    pub fn init(bytes: []const u8) Graphemes {
        return .{
            .bytes = bytes,
            .inner = .init(.init(bytes)),
            .ascii_at = if (printableAscii(bytes)) 0 else null,
        };
    }

    /// The next cluster, or null at the end.
    pub fn next(g: *Graphemes) ?[]const u8 {
        if (g.ascii_at) |at| {
            if (at == g.bytes.len) return null;
            g.ascii_at = at + 1;
            return g.bytes[at .. at + 1];
        }
        const found = g.inner.nextGrapheme() orelse return null;
        return g.bytes[found.start..found.end];
    }

    /// The next cluster and where it starts, or null at the end.
    pub fn nextAt(g: *Graphemes) ?struct { bytes: []const u8, start: usize } {
        if (g.ascii_at) |at| {
            if (at == g.bytes.len) return null;
            g.ascii_at = at + 1;
            return .{ .bytes = g.bytes[at .. at + 1], .start = at };
        }
        const found = g.inner.nextGrapheme() orelse return null;
        return .{ .bytes = g.bytes[found.start..found.end], .start = found.start };
    }
};

/// The columns one grapheme cluster takes.
///
/// Measured whole (`.unicode`, `.explicit`) that is 0, 1 or 2, which is what
/// puts a flag or a family emoji in two columns instead of eight. Measured
/// by codepoint (`.wcwidth`) it is the sum of what `wcwidth(3)` gives each
/// codepoint, because a terminal that measures that way places every
/// codepoint that takes columns in cells of its own: a mark that combines, a
/// variation selector and a joiner take none and stay with the codepoint
/// before them, and the astronaut that is a woman, a joiner and a rocket is a
/// woman in two columns and a rocket in the next two. `Parts` says where
/// those cells begin.
pub fn graphemeWidth(grapheme: []const u8, method: Method) u16 {
    if (grapheme.len == 1 and grapheme[0] >= 0x20 and grapheme[0] < 0x7f) return 1;
    switch (method) {
        .wcwidth => {
            var total: usize = 0;
            var it: Utf8 = .init(grapheme);
            while (it.next()) |cp| total += codepointWidth(cp);
            return @intCast(@min(total, std.math.maxInt(u16)));
        },
        .unicode, .explicit => return @intCast(@min(uucode.grapheme.utf8Wcwidth(grapheme), 2)),
    }
}

/// The cells a terminal measuring by codepoint puts one grapheme cluster
/// in: each codepoint that takes columns begins one, and the codepoints that
/// take none go with it. A cluster of one such codepoint, which is nearly
/// every cluster, is one part.
pub const Parts = struct {
    it: Utf8,

    /// The parts of `grapheme`, in order.
    pub fn init(grapheme: []const u8) Parts {
        return .{ .it = .init(grapheme) };
    }

    /// The next part and the columns it takes (0, 1 or 2), or null at the
    /// end. A part of no columns is only ever the first, when the cluster
    /// begins with a codepoint that takes none.
    pub fn next(p: *Parts) ?struct { bytes: []const u8, cols: u2 } {
        const bytes = p.it.bytes;
        const start = p.it.i;
        const first = p.it.next() orelse return null;
        const cols = codepointWidth(first);
        while (true) {
            const at = p.it.i;
            const cp = p.it.next() orelse break;
            if (codepointWidth(cp) != 0) {
                p.it.i = at;
                break;
            }
        }
        return .{ .bytes = bytes[start..p.it.i], .cols = @intCast(@min(cols, 2)) };
    }
};

/// Whether every codepoint of a cluster after its first takes no column of
/// its own when measured by codepoint: a base and the marks, selectors and
/// joiners that combine with it, and nothing that a terminal measuring by
/// codepoint would put in a cell of its own.
pub fn combinesOnly(grapheme: []const u8) bool {
    var it: Utf8 = .init(grapheme);
    _ = it.next() orelse return true;
    while (it.next()) |cp| if (codepointWidth(cp) != 0) return false;
    return true;
}

/// One codepoint's columns as `wcwidth(3)` counts them. uucode's
/// zero-in-cluster set is the marks, the selectors, the joiner and the
/// Hangul vowels and finals, which `wcwidth(3)` counts as nothing even
/// alone; the emoji modifiers are in it too, and `wcwidth(3)` counts
/// those as the emoji they are.
fn codepointWidth(cp: u21) usize {
    return switch (cp) {
        // the five skin tones
        0x1f3fb...0x1f3ff => uucode.get(.wcwidth_standalone, cp),
        else => if (uucode.get(.wcwidth_zero_in_grapheme, cp)) 0 else uucode.get(.wcwidth_standalone, cp),
    };
}

/// The columns a string takes, by `method`.
pub fn width(str: []const u8, method: Method) u16 {
    if (printableAscii(str)) {
        return @intCast(@min(str.len, std.math.maxInt(u16)));
    }
    return @intCast(@min(widthWide(str, method), std.math.maxInt(u16)));
}

fn printableAscii(str: []const u8) bool {
    for (str) |b| if (b < 0x20 or b >= 0x7f) return false;
    return true;
}

fn widthWide(str: []const u8, method: Method) usize {
    var total: usize = 0;
    var it: Graphemes = .init(str);
    while (it.next()) |g| total += graphemeWidth(g, method);
    return total;
}

/// One row a wrap produced: the byte range of the string it covers, and the
/// columns it takes.
pub const Row = struct {
    /// Where the row starts in the string handed to `wrap`.
    start: usize,
    /// Where it ends, exclusive. Trailing spaces a word break ate are not in
    /// the range.
    end: usize,
    /// The columns the row occupies.
    columns: u16,
};

/// Breaks `str` into rows of at most `cols` columns, writing them into
/// `rows_out` and returning how many it wrote.
///
/// Stops when `rows_out` is full, so a caller that wants every row sizes the
/// slice from `str.len`, which is the most rows there can be. A newline in
/// `str` always ends a row, whatever the mode.
pub fn wrap(str: []const u8, cols: u16, mode: Wrap, method: Method, rows_out: []Row) usize {
    if (rows_out.len == 0 or cols == 0) return 0;
    var written: usize = 0;
    var row: Row = .{ .start = 0, .end = 0, .columns = 0 };
    // Where the row could be cut instead of here, and how wide it was there.
    var break_at: ?usize = null;
    var break_columns: u16 = 0;
    var it: Graphemes = .init(str);

    while (it.nextAt()) |found| {
        const g = found.bytes;
        const at = found.start;
        if (g.len == 1 and g[0] == '\n') {
            rows_out[written] = .{ .start = row.start, .end = at, .columns = row.columns };
            written += 1;
            if (written == rows_out.len) return written;
            row = .{ .start = at + 1, .end = at + 1, .columns = 0 };
            break_at = null;
            continue;
        }
        const w = graphemeWidth(g, method);
        if (@as(u32, row.columns) + w > cols) {
            if (mode == .none) {
                // Everything to the end of this line is dropped, but a
                // newline still starts a row.
                while (it.nextAt()) |skip| {
                    if (skip.bytes.len == 1 and skip.bytes[0] == '\n') {
                        rows_out[written] = .{ .start = row.start, .end = at, .columns = row.columns };
                        written += 1;
                        if (written == rows_out.len) return written;
                        row = .{ .start = skip.start + 1, .end = skip.start + 1, .columns = 0 };
                        break;
                    }
                } else {
                    rows_out[written] = .{ .start = row.start, .end = at, .columns = row.columns };
                    return written + 1;
                }
                break_at = null;
                continue;
            }
            // A cluster wider than the whole row takes a row of its own
            // rather than leave an empty one before it.
            if (row.end == row.start) {
                row.columns = w;
                row.end = at + g.len;
                continue;
            }
            // A space that crosses the edge is itself the break: the word
            // before it filled the row exactly.
            if (mode == .word and g.len == 1 and g[0] == ' ') {
                break_at = at;
                break_columns = row.columns;
            }
            const cut = if (mode == .word) break_at orelse at else at;
            const cut_columns = if (mode == .word and break_at != null) break_columns else row.columns;
            rows_out[written] = .{ .start = row.start, .end = cut, .columns = cut_columns };
            written += 1;
            if (written == rows_out.len) return written;
            // A word break swallows the spaces it broke at.
            var resume_at = cut;
            while (resume_at < str.len and str[resume_at] == ' ') resume_at += 1;
            row = .{ .start = resume_at, .end = resume_at, .columns = 0 };
            break_at = null;
            if (resume_at > at) continue;
            // The iterator has already consumed the word prefix between the
            // earlier break and this overflowing cluster. It belongs to the
            // new row and must be measured with the cluster.
            row.columns = width(str[resume_at .. at + g.len], method);
            row.end = at + g.len;
            continue;
        }
        if (mode == .word and g.len == 1 and g[0] == ' ') {
            break_at = at;
            break_columns = row.columns;
        }
        row.columns += w;
        row.end = at + g.len;
    }
    rows_out[written] = .{ .start = row.start, .end = str.len, .columns = row.columns };
    return written + 1;
}

/// The prefix of `str` that fits in `cols` columns, with `ellipsis` written
/// in the last columns when something had to be dropped.
///
/// Returns a slice of `str` when everything fits and a slice of `str` cut at
/// a cluster boundary when it does not; the caller writes `ellipsis` itself,
/// because this allocates nothing and joins nothing.
pub fn fit(str: []const u8, cols: u16, ellipsis: []const u8, method: Method) []const u8 {
    if (widthWide(str, method) <= cols) return str;
    const room = cols -| width(ellipsis, method);
    var used: u16 = 0;
    var end: usize = 0;
    var it: Graphemes = .init(str);
    while (it.nextAt()) |found| {
        const w = graphemeWidth(found.bytes, method);
        if (@as(u32, used) + w > room) break;
        used += w;
        end = found.start + found.bytes.len;
    }
    return str[0..end];
}

const testing = std.testing;

test "ascii is one column a byte" {
    try testing.expectEqual(@as(u16, 5), width("hello", .wcwidth));
    try testing.expectEqual(@as(u16, 5), width("hello", .unicode));
}

test "a cluster measured whole is two columns and measured per codepoint is not" {
    const astronaut = "\u{1f469}\u{200d}\u{1f680}";
    try testing.expectEqual(@as(u16, 2), graphemeWidth(astronaut, .unicode));
    // A terminal that measures by codepoint gives the woman two columns and
    // the rocket the next two, the joiner none: four in all, and the grid
    // has to hold them where the terminal does.
    try testing.expectEqual(@as(u16, 4), graphemeWidth(astronaut, .wcwidth));
    try testing.expectEqual(@as(u16, 2), graphemeWidth("\u{4e2d}", .unicode));
    try testing.expectEqual(@as(u16, 1), graphemeWidth("a", .unicode));
    try testing.expectEqual(@as(u16, 1), graphemeWidth("\u{e9}", .unicode));
}

test "the parts of a cluster measured by codepoint are the cells a terminal gives it" {
    const cases = [_]struct { cluster: []const u8, parts: []const []const u8, cols: []const u2 }{
        .{ .cluster = "\u{1f469}\u{200d}\u{1f680}", .parts = &.{ "\u{1f469}\u{200d}", "\u{1f680}" }, .cols = &.{ 2, 2 } },
        .{ .cluster = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}", .parts = &.{ "\u{1f468}\u{200d}", "\u{1f469}\u{200d}", "\u{1f467}" }, .cols = &.{ 2, 2, 2 } },
        .{ .cluster = "e\u{301}", .parts = &.{"e\u{301}"}, .cols = &.{1} },
        .{ .cluster = "\u{26a0}\u{fe0f}", .parts = &.{"\u{26a0}\u{fe0f}"}, .cols = &.{1} },
        .{ .cluster = "\u{1f44b}\u{1f3fd}", .parts = &.{ "\u{1f44b}", "\u{1f3fd}" }, .cols = &.{ 2, 2 } },
        .{ .cluster = "\u{301}", .parts = &.{"\u{301}"}, .cols = &.{0} },
    };
    for (cases) |case| {
        var parts: Parts = .init(case.cluster);
        var total: u16 = 0;
        for (case.parts, case.cols) |want, cols| {
            const got = parts.next().?;
            try testing.expectEqualStrings(want, got.bytes);
            try testing.expectEqual(cols, got.cols);
            total += got.cols;
        }
        try testing.expect(parts.next() == null);
        try testing.expectEqual(graphemeWidth(case.cluster, .wcwidth), total);
    }
    try testing.expect(combinesOnly("e\u{301}\u{302}"));
    try testing.expect(combinesOnly("a"));
    try testing.expect(!combinesOnly("\u{1f469}\u{200d}\u{1f680}"));
}

test "a combining mark adds no columns to the cluster it joins" {
    // e followed by a combining acute is one cluster of one column.
    try testing.expectEqual(@as(u16, 1), graphemeWidth("e\u{301}", .unicode));
    try testing.expectEqual(@as(u16, 1), width("e\u{301}", .unicode));
}

test "measured per codepoint, a mark, a selector and a joiner take no column" {
    // wcwidth(3) counts a nonspacing mark as nothing, even with no base.
    try testing.expectEqual(@as(u16, 1), graphemeWidth("e\u{301}", .wcwidth));
    try testing.expectEqual(@as(u16, 1), width("c\u{30e}", .wcwidth));
    try testing.expectEqual(@as(u16, 0), graphemeWidth("\u{301}", .wcwidth));
    try testing.expectEqual(@as(u16, 1), graphemeWidth("\u{2764}\u{fe0f}", .wcwidth));
    // a skin tone is an emoji of its own to wcwidth(3)
    try testing.expectEqual(@as(u16, 2), graphemeWidth("\u{1f3fd}", .wcwidth));
    try testing.expectEqual(@as(u16, 4), graphemeWidth("\u{1f44b}\u{1f3fd}", .wcwidth));
}

test "the clusters come out whole" {
    var it: Graphemes = .init("a\u{e9}\u{1f469}\u{200d}\u{1f680}\u{4e2d}");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("\u{e9}", it.next().?);
    try testing.expectEqualStrings("\u{1f469}\u{200d}\u{1f680}", it.next().?);
    try testing.expectEqualStrings("\u{4e2d}", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "bytes that are not UTF-8 are a replacement each maximal subpart, and the next codepoint is whole" {
    // A three-byte sequence cut after two bytes, then a flag: the cut
    // sequence is one cluster and the flag is still a flag. Found by the
    // text input's fuzz, where the decoder took the flag's first byte into
    // the bad sequence and left three stray continuation bytes.
    const cases = [_]struct { text: []const u8, clusters: []const []const u8 }{
        .{ .text = "\xe4\xb8\u{1f1e6}\u{1f1e7}", .clusters = &.{ "\xe4\xb8", "\u{1f1e6}\u{1f1e7}" } },
        .{ .text = "a\xffb", .clusters = &.{ "a", "\xff", "b" } },
        .{ .text = "\xc3", .clusters = &.{"\xc3"} },
        .{ .text = "\xf0\x9f\x87e\u{301}", .clusters = &.{ "\xf0\x9f\x87", "e\u{301}" } },
        // An overlong lead and a surrogate are one byte and one subpart.
        .{ .text = "\xc0\xaf", .clusters = &.{ "\xc0", "\xaf" } },
        .{ .text = "\xed\xa0\x80x", .clusters = &.{ "\xed", "\xa0", "\x80", "x" } },
        .{ .text = "\xf4\x90\x80\x80", .clusters = &.{ "\xf4", "\x90", "\x80", "\x80" } },
    };
    for (cases) |case| {
        var it: Graphemes = .init(case.text);
        for (case.clusters) |want| try testing.expectEqualStrings(want, it.next().?);
        try testing.expectEqual(@as(?[]const u8, null), it.next());
    }
    // A cut sequence is the one column its replacement takes, whatever the
    // measure, and what follows it is measured as itself.
    for ([_]Method{ .wcwidth, .unicode }) |m| {
        try testing.expectEqual(1 + width("\u{1f1e6}\u{1f1e7}", m), width("\xe4\xb8\u{1f1e6}\u{1f1e7}", m));
    }
}

test "wrapping by grapheme cuts wherever it must" {
    var rows: [8]Row = undefined;
    const n = wrap("abcdefgh", 3, .grapheme, .unicode, &rows);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("abc", "abcdefgh"[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("def", "abcdefgh"[rows[1].start..rows[1].end]);
    try testing.expectEqualStrings("gh", "abcdefgh"[rows[2].start..rows[2].end]);
}

test "wrapping by word cuts at a space and eats it" {
    const str = "the quick brown fox";
    var rows: [8]Row = undefined;
    const n = wrap(str, 10, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("the quick", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("brown fox", str[rows[1].start..rows[1].end]);
}

test "a word that fills the row exactly breaks at the space after it" {
    const str = "ab cd efg";
    var rows: [8]Row = undefined;
    const n = wrap(str, 5, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("ab cd", str[rows[0].start..rows[0].end]);
    try testing.expectEqual(@as(u16, 5), rows[0].columns);
    try testing.expectEqualStrings("efg", str[rows[1].start..rows[1].end]);
    // and several spaces at the edge are all eaten
    const spaced = "abcde   fg";
    const m = wrap(spaced, 5, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 2), m);
    try testing.expectEqualStrings("abcde", spaced[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("fg", spaced[rows[1].start..rows[1].end]);
}

test "a cluster wider than the row takes a row of its own" {
    const str = "\u{1f680}\u{1f680}";
    var rows: [8]Row = undefined;
    for ([_]Wrap{ .grapheme, .word }) |mode| {
        const n = wrap(str, 1, mode, .unicode, &rows);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqualStrings("\u{1f680}", str[rows[0].start..rows[0].end]);
        try testing.expectEqual(@as(u16, 2), rows[0].columns);
        try testing.expectEqualStrings("\u{1f680}", str[rows[1].start..rows[1].end]);
    }
}

test "a word longer than the row is cut anyway" {
    const str = "aaaaaaaaaaaa b";
    var rows: [8]Row = undefined;
    const n = wrap(str, 5, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("aaaaa", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("aaaaa", str[rows[1].start..rows[1].end]);
    try testing.expectEqualStrings("aa b", str[rows[2].start..rows[2].end]);
}

test "word wrapping measures the prefix consumed past the previous break" {
    const str = "a abcdef";
    var rows: [8]Row = undefined;
    const n = wrap(str, 5, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("a", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("abcde", str[rows[1].start..rows[1].end]);
    try testing.expectEqual(@as(u16, 5), rows[1].columns);
    try testing.expectEqualStrings("f", str[rows[2].start..rows[2].end]);
    try testing.expectEqual(@as(u16, 1), rows[2].columns);
}

test "a newline ends a row in every mode" {
    const str = "ab\ncd";
    var rows: [8]Row = undefined;
    for ([_]Wrap{ .none, .grapheme, .word }) |mode| {
        const n = wrap(str, 10, mode, .unicode, &rows);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqualStrings("ab", str[rows[0].start..rows[0].end]);
        try testing.expectEqualStrings("cd", str[rows[1].start..rows[1].end]);
    }
}

test "no wrapping drops the rest of the line and keeps the next" {
    const str = "abcdef\ngh";
    var rows: [8]Row = undefined;
    const n = wrap(str, 3, .none, .unicode, &rows);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abc", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("gh", str[rows[1].start..rows[1].end]);
}

test "a wide grapheme never straddles the end of a row" {
    const str = "a\u{4e2d}b";
    var rows: [8]Row = undefined;
    const n = wrap(str, 2, .grapheme, .unicode, &rows);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("a", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("\u{4e2d}", str[rows[1].start..rows[1].end]);
    try testing.expectEqual(@as(u16, 2), rows[1].columns);
    try testing.expectEqualStrings("b", str[rows[2].start..rows[2].end]);
}

test "fit keeps what fits and leaves room for the ellipsis" {
    try testing.expectEqualStrings("hello", fit("hello", 5, "\u{2026}", .unicode));
    try testing.expectEqualStrings("hel", fit("hello", 4, "\u{2026}", .unicode));
    try testing.expectEqualStrings("", fit("hello", 1, "\u{2026}", .unicode));
}

test "width never overflows on a very long string" {
    const long = "a" ** 1024;
    try testing.expectEqual(@as(u16, 1024), width(long, .wcwidth));
}

test "saturated width does not make fit or wrap accept an overlong string" {
    const long = "a" ** 65536;
    try testing.expectEqual(std.math.maxInt(u16), width(long, .unicode));
    try testing.expectEqual(@as(usize, 65534), fit(long, std.math.maxInt(u16), "…", .unicode).len);

    var rows: [2]Row = undefined;
    const n = wrap(long, std.math.maxInt(u16), .grapheme, .unicode, &rows);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), rows[0].columns);
    try testing.expectEqual(@as(u16, 1), rows[1].columns);
}

/// Whether the two width models disagree about a cluster.
///
/// One printable ASCII byte is one column under every model, which is the
/// fast path and almost every cell. Beyond it, measuring by codepoint and
/// measuring by cluster are compared: a cluster they disagree about is a
/// cluster the terminal and this package may put in different columns, and a
/// row holding one is repainted rather than diffed.
pub fn disagrees(grapheme: []const u8) bool {
    if (grapheme.len == 1 and grapheme[0] >= 0x20 and grapheme[0] < 0x7f) return false;
    return graphemeWidth(grapheme, .wcwidth) != graphemeWidth(grapheme, .unicode);
}

test "the canonical disagreement is the warning sign with a presentation selector" {
    // U+26A0 followed by VS16: a narrow dingbat and a zero-width combiner to
    // one model, a wide emoji to the other.
    try testing.expect(disagrees("\u{26a0}\u{fe0f}"));
    try testing.expect(!disagrees("a"));
    try testing.expect(!disagrees("\u{4e2d}"));
}
