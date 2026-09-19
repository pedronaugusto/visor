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

/// An iterator over the grapheme clusters of a string.
pub const Graphemes = struct {
    bytes: []const u8,
    inner: uucode.grapheme.Iterator(uucode.utf8.Iterator),

    /// The clusters of `bytes`, in order.
    pub fn init(bytes: []const u8) Graphemes {
        return .{ .bytes = bytes, .inner = uucode.grapheme.utf8Iterator(bytes) };
    }

    /// The next cluster, or null at the end.
    pub fn next(g: *Graphemes) ?[]const u8 {
        const found = g.inner.nextGrapheme() orelse return null;
        return g.bytes[found.start..found.end];
    }

    /// The next cluster and where it starts, or null at the end.
    pub fn nextAt(g: *Graphemes) ?struct { bytes: []const u8, start: usize } {
        const found = g.inner.nextGrapheme() orelse return null;
        return .{ .bytes = g.bytes[found.start..found.end], .start = found.start };
    }
};

/// The columns one grapheme cluster takes: 0, 1 or 2.
///
/// `.wcwidth` sums its codepoints the way a terminal with no cluster support
/// does, and clamps at two; `.unicode` and `.explicit` measure the cluster
/// whole, which is what puts a flag or a family emoji in two columns instead
/// of eight.
pub fn graphemeWidth(grapheme: []const u8, method: Method) u2 {
    switch (method) {
        .wcwidth => {
            var total: usize = 0;
            var it: uucode.utf8.Iterator = .init(grapheme);
            while (it.next()) |cp| total += uucode.get(.wcwidth_standalone, cp);
            return @intCast(@min(total, 2));
        },
        .unicode, .explicit => return @intCast(@min(uucode.grapheme.utf8Wcwidth(grapheme), 2)),
    }
}

/// The columns a string takes, by `method`.
pub fn width(str: []const u8, method: Method) u16 {
    var total: usize = 0;
    var it: Graphemes = .init(str);
    while (it.next()) |g| total += graphemeWidth(g, method);
    return std.math.cast(u16, total) orelse std.math.maxInt(u16);
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
        if (row.columns + w > cols) {
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
            // Re-measure this cluster at the start of the new row.
            row.columns = w;
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
    if (width(str, method) <= cols) return str;
    const room = cols -| width(ellipsis, method);
    var used: u16 = 0;
    var end: usize = 0;
    var it: Graphemes = .init(str);
    while (it.nextAt()) |found| {
        const w = graphemeWidth(found.bytes, method);
        if (used + w > room) break;
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
    const family = "\u{1f469}\u{200d}\u{1f680}";
    try testing.expectEqual(@as(u2, 2), graphemeWidth(family, .unicode));
    // Summed per codepoint the two emoji are two each, clamped at the cell
    // pair a terminal will actually draw.
    try testing.expectEqual(@as(u2, 2), graphemeWidth(family, .wcwidth));
    try testing.expectEqual(@as(u2, 2), graphemeWidth("\u{4e2d}", .unicode));
    try testing.expectEqual(@as(u2, 1), graphemeWidth("a", .unicode));
    try testing.expectEqual(@as(u2, 1), graphemeWidth("\u{e9}", .unicode));
}

test "a combining mark adds no columns to the cluster it joins" {
    // e followed by a combining acute is one cluster of one column.
    try testing.expectEqual(@as(u2, 1), graphemeWidth("e\u{301}", .unicode));
    try testing.expectEqual(@as(u16, 1), width("e\u{301}", .unicode));
}

test "the clusters come out whole" {
    var it: Graphemes = .init("a\u{e9}\u{1f469}\u{200d}\u{1f680}\u{4e2d}");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("\u{e9}", it.next().?);
    try testing.expectEqualStrings("\u{1f469}\u{200d}\u{1f680}", it.next().?);
    try testing.expectEqualStrings("\u{4e2d}", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
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

test "a word longer than the row is cut anyway" {
    const str = "aaaaaaaaaaaa b";
    var rows: [8]Row = undefined;
    const n = wrap(str, 5, .word, .unicode, &rows);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("aaaaa", str[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("aaaaa", str[rows[1].start..rows[1].end]);
    try testing.expectEqualStrings("aa b", str[rows[2].start..rows[2].end]);
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
