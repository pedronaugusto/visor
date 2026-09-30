const std = @import("std");
const widgets = @import("../widgets.zig");
const visor = @import("visor");
const Harness = @import("harness.zig").Harness;
const t = std.testing;

test "markdown wrapping keeps nested quote bars and list hanging indents" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "> one two three\n> > four five six\n\n- alpha beta gamma\n  continuation\n  - nested item");
    defer doc.deinit();
    const md: widgets.Markdown = .{ .document = &doc, .theme = .{} };
    var h = try Harness.init(t.allocator, 12, 10);
    defer h.deinit();
    try md.draw(h.window());
    try h.expectFrame("│ one two\n│ three\n│ │ four\n│ │ five six\n\n- alpha beta\n  gamma\n  continuati\n  on\n  - nested\n");
    try t.expectEqual(@as(usize, 11), md.rowCount(12, .unicode));
    h.screen.clear();
    try (widgets.Markdown{ .document = &doc, .theme = .{}, .scroll = 9 }).draw(h.window());
    try t.expectEqualStrings("  - nested", std.mem.trimEnd(u8, (try h.frame())[0..12], " "));
}

test "markdown fences and indented code stay verbatim and never wrap" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "~~~zig\n> **literal** long\n```\n~~~~\n    x  y\n> ```\n> > prompt\n> ```\nafter");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 12, 5);
    defer h.deinit();
    const md: widgets.Markdown = .{ .document = &doc, .theme = .{ .code = .{ .dim = true } } };
    try md.draw(h.window());
    try h.expectFrame("> **literal*\n```\nx  y\n│ > prompt\nafter\n");
    try t.expectEqual(@as(usize, 5), md.rowCount(12, .unicode));
    try t.expect(h.styleAt(0, 0).dim);
}

test "markdown inline styles and links survive wide character wrapping" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "# Title\n**bold** *slant* `x * y` [中中 ok](https://example.org/a)\n---");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 10, 6);
    defer h.deinit();
    const md: widgets.Markdown = .{ .document = &doc, .theme = .{ .heading = @splat(.{ .bold = true }), .strong = .{ .bold = true }, .emphasis = .{ .italic = true }, .inline_code = .{ .reverse = true }, .link = .{ .underline = .single } } };
    try md.draw(h.window());
    try h.expectFrame("Title\nbold slant\nx * y 中中\nok\n──────────\n\n");
    try t.expect(h.styleAt(0, 0).bold);
    try t.expect(h.styleAt(0, 1).bold);
    try t.expect(h.styleAt(5, 1).italic);
    try t.expect(h.styleAt(0, 2).reverse);
    const cell = h.term.screen().readCell(6, 2).?;
    try t.expectEqualStrings("https://example.org/a", h.term.screen().target(cell.link).?.uri);
    try t.expectEqualStrings("https://example.org/a", h.term.screen().target(h.term.screen().readCell(0, 3).?.link).?.uri);
}

test "markdown edges handle empty widths literal delimiters and unsafe targets" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "> > > 中\n[ok](https://x/\x1b)\n*open `span\n\\*escaped\\*\n````\n~~~\n");
    defer doc.deinit();
    const md: widgets.Markdown = .{ .document = &doc, .theme = .{} };
    try t.expectEqual(@as(usize, 0), md.rowCount(0, .unicode));
    var h = try Harness.init(t.allocator, 1, 8);
    defer h.deinit();
    try md.draw(h.window());
    _ = try h.frame();
    try t.expectEqualStrings("│", h.screen.textAt(0, 0));
    for (0..h.screen.size.rows) |row| {
        const cells = h.screen.rowAt(@intCast(row));
        for (0..cells.len()) |col| try t.expectEqual(visor.Link.none, cells.get(col).?.link);
    }
    var empty = try widgets.Markdown.Document.init(t.allocator, "");
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), (widgets.Markdown{ .document = &empty, .theme = .{} }).rowCount(10, .unicode));
}

test "markdown owns its input and releases every failed parse allocation" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    const Check = struct {
        fn parse(a: std.mem.Allocator) !void {
            const source = try a.dupe(u8, "# heading\n> [**label**](https://x/(a))\n\n- item\n  more\n~~~\n\tcode\n~~~");
            defer a.free(source);
            var doc = try widgets.Markdown.Document.init(a, source);
            defer doc.deinit();
            @memset(source, 'x');
            const md: widgets.Markdown = .{ .document = &doc, .theme = .{} };
            try t.expect(md.rowCount(20, .unicode) > 0);
            try t.expect(std.mem.startsWith(u8, doc.source, "# heading"));
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Check.parse, .{});
}

test "markdown inline nesting escapes and exact code delimiters" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "**bold *both*** and snake_case_here\n``a ` b`` and `open\n\\*plain\\* [*label*](https://x/(a))");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 40, 3);
    defer h.deinit();
    try (widgets.Markdown{ .document = &doc, .theme = .{ .strong = .{ .bold = true }, .emphasis = .{ .italic = true } } }).draw(h.window());
    try h.expectFrame("bold both and snake_case_here a ` b and\n`open *plain* label\n\n");
    try t.expect(h.styleAt(5, 0).bold and h.styleAt(5, 0).italic);
    const cell = h.term.screen().readCell(14, 1).?;
    try t.expectEqualStrings("https://x/(a)", h.term.screen().target(cell.link).?.uri);
}

test "markdown code scrolling tabs and clipped windows agree with row counts" {
    if (comptime !@hasDecl(widgets, "Markdown")) return t.expect(false);
    var doc = try widgets.Markdown.Document.init(t.allocator, "    \t中x\n\n> > > > > words\n1. 中 中\n2) tail");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 8, 5);
    defer h.deinit();
    const md: widgets.Markdown = .{ .document = &doc, .theme = .{}, .scroll_columns = 5 };
    try md.draw(h.window().child(.{ .col = 1, .cols = 6 }));
    try h.expectFrame(" x\n\n │ │ │\n 1. 中\n    中\n");
    try t.expectEqual(@as(usize, 7), md.rowCount(6, .unicode));
}
