const std = @import("std");
const NoResize = @import("shakedown").alloc.NoResize;
const widgets = @import("../widgets.zig");
const visor = @import("visor");
const Harness = @import("../testing/widget_harness.zig").Harness;
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
    for (0..h.screen.dimensions().rows) |row| {
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
            try t.expect(std.mem.startsWith(u8, doc.source(), "# heading"));
        }
    };
    var no_resize: NoResize = .init(t.allocator);
    try t.checkAllAllocationFailures(no_resize.allocator(), Check.parse, .{});
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

test "markdown document exposes only borrowed const parsing ranges" {
    const Document = widgets.Markdown.Document;
    var doc = try Document.init(t.allocator, "**label** [link](https://x)");
    defer doc.deinit();
    const source: []const u8 = doc.source();
    const text: []const u8 = doc.text();
    try t.expectEqualStrings("**label** [link](https://x)", source);
    try t.expectEqualStrings("label link", text);
    try t.expectEqual(@as(usize, 1), doc.blocks().len);
    for (doc.spans()) |span| try t.expect(span.end <= text.len);
}

test "markdown borrowed rows match drawing and preserve block structure" {
    var doc = try widgets.Markdown.Document.init(t.allocator, "# title\n\n> - one two three four\n> ~~~zig\n> a\tb\n> ~~~\n    code\n---\n中 中 中");
    defer doc.deinit();
    for ([_]visor.Method{ .unicode, .wcwidth }) |method| {
        for ([_]u16{ 0, 1, 4, 9, 20 }) |cols| {
            const md: widgets.Markdown = .{ .document = &doc, .theme = .{} };
            var rows = widgets.Markdown.Rows.init(&doc, cols, method);
            var whole = try Harness.init(t.allocator, cols, @intCast(md.rowCount(cols, method)));
            defer whole.deinit();
            whole.screen.method = method;
            try md.draw(whole.window());
            var count: usize = 0;
            while (rows.next()) |row| : (count += 1) {
                try t.expectEqualStrings(doc.text()[row.start..row.end], row.text);
                try t.expectEqual(@intFromPtr(doc.text().ptr) + row.start, @intFromPtr(row.text.ptr));
                try t.expectEqualDeep(doc.blocks()[row.block_index], row.block);
                if (row.block.fence) |f| {
                    try t.expectEqual(@as(u8, '~'), f.char);
                    try t.expectEqual(@as(usize, 3), f.count);
                    try t.expectEqualStrings("zig", f.info);
                }
                var one = try Harness.init(t.allocator, cols, 1);
                defer one.deinit();
                one.screen.method = method;
                // An application renders the borrowed row with its own annotations.
                const b = row.block;
                const prefix: u16 = @intCast(@min(@as(u32, b.depth) * 2 + b.indent, cols));
                var bar: u32 = 0;
                while (bar < b.depth and bar * 2 < cols) : (bar += 1) try one.window().write(@intCast(bar * 2), 0, "│", .{}, .none);
                if (b.kind == .rule) {
                    for (prefix..cols) |x| try one.window().write(@intCast(x), 0, "─", .{}, .none);
                } else {
                    if (row.first) _ = try one.window().printSegment(.{ .text = b.marker }, .{ .col = prefix });
                    var x: u32 = @intCast(@min(@as(usize, prefix) + b.marker.len, cols));
                    var column: u32 = 0;
                    var glyphs = visor.Graphemes.init(row.text);
                    while (glyphs.next()) |g| {
                        const tab = b.kind == .code and std.mem.eql(u8, g, "\t");
                        const width: u32 = if (tab) 4 - column % 4 else visor.graphemeWidth(g, method);
                        column += width;
                        if (x + width > cols) break;
                        if (tab) {
                            for (0..width) |offset| try one.window().write(@intCast(x + offset), 0, " ", .{}, .none);
                        } else try one.window().write(@intCast(x), 0, g, .{}, .none);
                        x += width;
                    }
                }
                for (0..cols) |x| try t.expectEqualDeep(whole.screen.readCell(@intCast(x), @intCast(count)), one.screen.readCell(@intCast(x), 0));
            }
            try t.expectEqual(md.rowCount(cols, method), count);
            try t.expectEqual(null, rows.next());
        }
    }
}

/// Every line `Quoted` reads off `source`, as `depth|body|code`.
fn quotedLines(source: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    var lines: widgets.Markdown.Quoted = .init(source);
    while (lines.next()) |line| try out.writer.print("{d}|{s}|{}\n", .{ line.depth, line.body, line.code });
    return out.toOwnedSlice();
}

test "quoted lines take the quotation off and keep a fence's own markers" {
    const got = try quotedLines("say\n> one\n  > >  two\n> ```\n> > prompt\n> ```\n>\n    > code\r\nend\n");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\0|say|false
        \\1|one|false
        \\2| two|false
        \\1|```|true
        \\1|> prompt|true
        \\1|```|true
        \\1||false
        \\0|    > code|false
        \\0|end|false
        \\0||false
        \\
    , got);
}

test "quoted lines close a fence only with its own character, at least as long, at its depth" {
    const got = try quotedLines("````\n```\n~~~~\n```` x\n> ````\n`````\n    ```\n```\n~~~\n");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\0|````|true
        \\0|```|true
        \\0|~~~~|true
        \\0|```` x|true
        \\0|> ````|true
        \\0|`````|true
        \\0|    ```|false
        \\0|```|true
        \\0|~~~|true
        \\0||true
        \\
    , got);
}

test "quoted lines say which line opens and which closes, and the fence's info" {
    var lines: widgets.Markdown.Quoted = .init("   ~~~ zig \nx\n~~~");
    const open = lines.next().?;
    try t.expect(open.opens and !open.closes);
    try t.expectEqualStrings("zig", open.fence.?.info);
    try t.expectEqual(@as(u8, '~'), open.fence.?.char);
    const inside = lines.next().?;
    try t.expect(inside.code and !inside.opens and !inside.closes);
    try t.expectEqualStrings("x", inside.text);
    const close = lines.next().?;
    try t.expect(close.closes);
    try t.expect(lines.next() == null);
}

test "a document's fenced blocks are the ones quoted lines find" {
    const source = "> ```\n> > prompt\n> ```\n    ```\n> x\n~~~\n```\n> y\n~~~\nz";
    var doc = try widgets.Markdown.Document.init(t.allocator, source);
    defer doc.deinit();
    var at: usize = 0;
    var matched: usize = 0;
    var lines: widgets.Markdown.Quoted = .init(source);
    while (lines.next()) |line| {
        if (!line.code or line.opens or line.closes) continue;
        while (doc.blocks()[at].fence == null) at += 1;
        const block = doc.blocks()[at];
        try t.expectEqual(line.depth, block.depth);
        try t.expectEqualStrings(line.body, doc.text()[block.start..block.end]);
        at += 1;
        matched += 1;
    }
    try t.expectEqual(@as(usize, 3), matched);
    for (doc.blocks()[at..]) |block| try t.expect(block.fence == null);
}
