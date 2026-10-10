//! Text widgets fed text no one cleaned: marks that begin a segment, C1
//! controls, bytes that are not UTF-8, zero-width codepoints, wide and
//! joining clusters. Every draw succeeds, under every width method, and the
//! frame round-trips through the emulator as every widget frame does.

const std = @import("std");
const widgets = @import("../widgets.zig");
const visor = @import("base.zig");
const Harness = @import("../testing/widget_harness.zig").Harness;
const t = std.testing;

const pieces = [_][]const u8{
    "a",                "b",        " ",         "  ",       "\n",        "\r\n",     "\t",
    "\u{301}",          "\u{85}",   "\u{9b}",    "\xff",     "\xe4\xb8",  "\u{200b}", "\u{feff}",
    "\u{1161}",         "\u{4e2d}", "\u{1f1e6}", "\u{200d}", "\u{1f469}", "\u{600}",  "\u{903}",
    "\u{26a0}\u{fe0f}", "**",       "*",         "`",        "[x](h)",    "# ",       "> ",
    "- ",               "|",        "\x1b[31m",
};

fn hostile(random: std.Random, buf: []u8) []const u8 {
    var n: usize = 0;
    while (true) {
        const piece: []const u8 = if (random.uintLessThan(u8, 8) == 0) &.{random.int(u8)} else pieces[random.uintLessThan(usize, pieces.len)];
        if (n + piece.len > buf.len) return buf[0..n];
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
    }
}

test "text widgets draw any text under every width method" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..150) |_| {
        var buf: [72]u8 = undefined;
        const text = hostile(random, buf[0..random.uintAtMost(usize, buf.len)]);
        for ([_]visor.Method{ .wcwidth, .unicode, .explicit }) |method| {
            var h = try Harness.initMeasured(t.allocator, 9, 5, method);
            defer h.deinit();
            // Measuring by what the terminal was told needs it told.
            h.caps.explicit_width = method == .explicit;

            const wrap: visor.Wrap = switch (random.uintLessThan(u8, 3)) {
                0 => .none,
                1 => .grapheme,
                else => .word,
            };
            try (widgets.Paragraph{ .lines = &.{.{ .text = text }}, .wrap = wrap }).draw(h.window());
            _ = try h.frame();

            h.screen.clear();
            var doc = try widgets.Markdown.Document.init(t.allocator, text);
            defer doc.deinit();
            try (widgets.Markdown{ .document = &doc, .theme = .{} }).draw(h.window());
            _ = try h.frame();

            h.screen.clear();
            var list_state: widgets.List.State = .{ .selected = 0 };
            try (widgets.List{ .items = &.{ .{ .text = text }, .{ .text = "x" } } }).draw(h.window(), &list_state);
            _ = try h.frame();

            h.screen.clear();
            const a = random.uintAtMost(usize, text.len);
            const b = random.uintAtMost(usize, text.len);
            var input_state: widgets.TextInput.State = .{};
            try (widgets.TextInput{
                .text = text,
                .cursor = random.uintAtMost(usize, text.len),
                .selection = .{ .start = @min(a, b), .end = @max(a, b) },
            }).draw(h.window(), &input_state);
            _ = try h.frame();
        }
    }
}

test "a markdown link too long for the link table stays text" {
    const gpa = t.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "[ab](h");
    try source.appendNTimes(gpa, 'x', 70_000);
    try source.appendSlice(gpa, ")");
    var doc = try widgets.Markdown.Document.init(gpa, source.items);
    defer doc.deinit();
    var h = try Harness.init(gpa, 4, 1);
    defer h.deinit();
    try (widgets.Markdown{ .document = &doc, .theme = .{} }).draw(h.window());
    try h.expectFrame("ab\n");
    try t.expectEqual(visor.Link.none, h.screen.readCell(0, 0).?.link);
}
