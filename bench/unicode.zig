//! The few Unicode properties the corpus and the decoder measure by, read
//! from uucode's tables of the Unicode Character Database: never from visor's
//! own width rule, which is what the checks hold visor to.

const std = @import("std");
const uucode = @import("uucode");

/// East Asian Wide or Fullwidth: two columns.
pub fn wide(cp: u21) bool {
    return switch (uucode.get(.east_asian_width, cp)) {
        .wide, .fullwidth => true,
        else => false,
    };
}

/// A combining mark (nonzero combining class, Mn or Me): it joins the cell
/// before it and takes no column of its own.
pub fn mark(cp: u21) bool {
    if (uucode.get(.canonical_combining_class, cp) != 0) return true;
    return switch (uucode.get(.general_category, cp)) {
        .mark_nonspacing, .mark_enclosing => true,
        else => false,
    };
}

/// A format character (Cf), such as the zero-width joiner.
pub fn format(cp: u21) bool {
    return uucode.get(.general_category, cp) == .other_format;
}

/// A regular-expression word character: a letter, a number or `_`.
pub fn word(cp: u21) bool {
    if (cp == '_') return true;
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other => true,
        .number_decimal_digit, .number_letter, .number_other => true,
        else => false,
    };
}

/// The columns a piece of text takes by the corpus rule: marks none, wide
/// two, everything else one.
pub fn columns(text: []const u8) usize {
    var total: usize = 0;
    // unreachable: every caller measures text it generated or decoded as UTF-8
    var it = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| {
        if (mark(cp)) continue;
        total += if (wide(cp)) 2 else 1;
    }
    return total;
}

/// The codepoints of UTF-8 `text`, for code that counts as Python's `str`
/// does. Invalid UTF-8 is an error, as Python's strict decode is.
pub fn codepoints(a: std.mem.Allocator, text: []const u8) ![]u21 {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var out: std.ArrayList(u21) = .empty;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(a, cp);
    return out.items;
}

test "properties the corpus relies on" {
    try std.testing.expect(wide(0x6f22) and wide(0xd55c) and wide(0x1f600) and wide(0x1f3fb));
    try std.testing.expect(!wide('a') and !wide(0x2764) and !wide(0x1f1ef) and !wide(0x2500));
    try std.testing.expect(mark(0x301) and mark(0x20e3) and mark(0xfe0f) and !mark(0x200d));
    try std.testing.expect(format(0x200d) and !format('a'));
    try std.testing.expect(word('r') and word('7') and word(0x6f22) and !word(0x2502) and !word(' '));
    try std.testing.expectEqual(@as(usize, 4), columns("\u{6f22}\u{5b57}"));
    try std.testing.expectEqual(@as(usize, 1), columns("e\u{301}"));
    // A ZWJ family: four wide people and three joiners, by this rule.
    try std.testing.expectEqual(@as(usize, 11), columns("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}"));
}

/// The codepoint a whole UTF-8 sequence of one to four bytes spells.
pub fn decode(bytes: []const u8) error{InvalidUtf8}!u21 {
    return switch (bytes.len) {
        1 => if (bytes[0] < 0x80) bytes[0] else error.InvalidUtf8,
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch error.InvalidUtf8,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch error.InvalidUtf8,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch error.InvalidUtf8,
        else => error.InvalidUtf8,
    };
}
