//! Tables and task lists: the GitHub Flavored Markdown spec's own examples,
//! and how the widget draws what the reader makes of them.
//!
//! The examples are the spec's verbatim, input and HTML: GitHub Flavored
//! Markdown Spec version 0.29-gfm (2019-04-06), examples 198 to 205 (tables)
//! and 279 to 280 (task list items), as published in
//! github/cmark-gfm `test/spec.txt` at commit 27d942c8. The document is
//! written back as the HTML cmark-gfm writes for those constructs, and the
//! two compared; a soft line break inside a paragraph, which a terminal
//! shows as a space, is the one difference allowed for.

const std = @import("std");
const widgets = @import("../../widgets.zig");
const visor = @import("visor");
const Harness = @import("../../testing/widget_harness.zig").Harness;
const corpus = @import("corpus");
const t = std.testing;

const Document = widgets.Markdown.Document;

const Example = struct { number: u16, markdown: []const u8, html: []const u8 };

const examples = [_]Example{
    .{ .number = 198, .markdown =
    \\| foo | bar |
    \\| --- | --- |
    \\| baz | bim |
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>foo</th>
    \\<th>bar</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>baz</td>
    \\<td>bim</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\
    },
    .{ .number = 199, .markdown =
    \\| abc | defghi |
    \\:-: | -----------:
    \\bar | baz
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th align="center">abc</th>
    \\<th align="right">defghi</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td align="center">bar</td>
    \\<td align="right">baz</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\
    },
    .{ .number = 200, .markdown =
    \\| f\|oo  |
    \\| ------ |
    \\| b `\|` az |
    \\| b **\|** im |
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>f|oo</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>b <code>|</code> az</td>
    \\</tr>
    \\<tr>
    \\<td>b <strong>|</strong> im</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\
    },
    .{ .number = 201, .markdown =
    \\| abc | def |
    \\| --- | --- |
    \\| bar | baz |
    \\> bar
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>abc</th>
    \\<th>def</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>bar</td>
    \\<td>baz</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\<blockquote>
    \\<p>bar</p>
    \\</blockquote>
    \\
    },
    .{ .number = 202, .markdown =
    \\| abc | def |
    \\| --- | --- |
    \\| bar | baz |
    \\bar
    \\
    \\bar
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>abc</th>
    \\<th>def</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>bar</td>
    \\<td>baz</td>
    \\</tr>
    \\<tr>
    \\<td>bar</td>
    \\<td></td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\<p>bar</p>
    \\
    },
    .{ .number = 203, .markdown =
    \\| abc | def |
    \\| --- |
    \\| bar |
    \\
    , .html =
    \\<p>| abc | def |
    \\| --- |
    \\| bar |</p>
    \\
    },
    .{ .number = 204, .markdown =
    \\| abc | def |
    \\| --- | --- |
    \\| bar |
    \\| bar | baz | boo |
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>abc</th>
    \\<th>def</th>
    \\</tr>
    \\</thead>
    \\<tbody>
    \\<tr>
    \\<td>bar</td>
    \\<td></td>
    \\</tr>
    \\<tr>
    \\<td>bar</td>
    \\<td>baz</td>
    \\</tr>
    \\</tbody>
    \\</table>
    \\
    },
    .{ .number = 205, .markdown =
    \\| abc | def |
    \\| --- | --- |
    \\
    , .html =
    \\<table>
    \\<thead>
    \\<tr>
    \\<th>abc</th>
    \\<th>def</th>
    \\</tr>
    \\</thead>
    \\</table>
    \\
    },
    .{ .number = 279, .markdown =
    \\- [ ] foo
    \\- [x] bar
    \\
    , .html =
    \\<ul>
    \\<li><input disabled="" type="checkbox"> foo</li>
    \\<li><input checked="" disabled="" type="checkbox"> bar</li>
    \\</ul>
    \\
    },
    .{ .number = 280, .markdown =
    \\- [x] foo
    \\  - [ ] bar
    \\  - [x] baz
    \\- [ ] bim
    \\
    , .html =
    \\<ul>
    \\<li><input checked="" disabled="" type="checkbox"> foo
    \\<ul>
    \\<li><input disabled="" type="checkbox"> bar</li>
    \\<li><input checked="" disabled="" type="checkbox"> baz</li>
    \\</ul>
    \\</li>
    \\<li><input disabled="" type="checkbox"> bim</li>
    \\</ul>
    \\
    },
};

/// Text and its inline spans as cmark writes them.
fn inlineHtml(w: *std.Io.Writer, doc: *const Document, start: usize, end: usize, spans: []const Document.Span) !void {
    var flags: @FieldType(Document.Span, "flags") = .{};
    var at = start;
    for (spans) |span| {
        if (span.end <= start or span.start >= end) continue;
        try w.writeAll(doc.text()[at..span.start]);
        if (!std.meta.eql(flags, span.flags)) {
            if (flags.code) try w.writeAll("</code>");
            if (flags.emphasis) try w.writeAll("</em>");
            if (flags.strong) try w.writeAll("</strong>");
            if (span.flags.strong) try w.writeAll("<strong>");
            if (span.flags.emphasis) try w.writeAll("<em>");
            if (span.flags.code) try w.writeAll("<code>");
            flags = span.flags;
        }
        try w.writeAll(doc.text()[span.start..span.end]);
        at = span.end;
    }
    if (flags.code) try w.writeAll("</code>");
    if (flags.emphasis) try w.writeAll("</em>");
    if (flags.strong) try w.writeAll("</strong>");
    try w.writeAll(doc.text()[at..end]);
}

fn blockInline(w: *std.Io.Writer, doc: *const Document, b: Document.Block) !void {
    try inlineHtml(w, doc, b.start, b.end, doc.spans()[b.first_span..b.end_span]);
}

/// The list items from `at` at `indent` and the ones nested under them.
fn listHtml(w: *std.Io.Writer, doc: *const Document, blocks: []const Document.Block, at: *usize, indent: u16) !void {
    try w.writeAll("<ul>\n");
    while (at.* < blocks.len and blocks[at.*].marker.len > 0 and blocks[at.*].indent == indent) {
        const b = blocks[at.*];
        try w.writeAll("<li>");
        if (b.task) |done| try w.writeAll(if (done) "<input checked=\"\" disabled=\"\" type=\"checkbox\"> " else "<input disabled=\"\" type=\"checkbox\"> ");
        try blockInline(w, doc, b);
        at.* += 1;
        if (at.* < blocks.len and blocks[at.*].marker.len > 0 and blocks[at.*].indent > indent) {
            try w.writeAll("\n");
            try listHtml(w, doc, blocks, at, blocks[at.*].indent);
        }
        try w.writeAll("</li>\n");
    }
    try w.writeAll("</ul>\n");
}

/// The document as the HTML cmark-gfm writes for the blocks these examples
/// have.
fn toHtml(doc: *const Document) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const blocks = doc.blocks();
    var i: usize = 0;
    while (i < blocks.len) {
        const b = blocks[i];
        if (b.kind == .blank) {
            i += 1;
            continue;
        }
        if (b.marker.len > 0) {
            try listHtml(w, doc, blocks, &i, b.indent);
            continue;
        }
        if (b.depth > 0) try w.writeAll("<blockquote>\n");
        switch (b.kind) {
            .table => {
                const table = b.table.?;
                try w.writeAll("<table>\n<thead>\n");
                for (0..table.rows) |r| {
                    if (r == 1) try w.writeAll("<tbody>\n");
                    try w.writeAll("<tr>\n");
                    const tag = if (r == 0) "th" else "td";
                    for (0..table.columns) |c| {
                        const cell = doc.cells()[table.first_cell + r * table.columns + c];
                        try w.print("<{s}", .{tag});
                        switch (doc.alignments()[table.first_align + c]) {
                            .none => {},
                            inline else => |a| try w.print(" align=\"{s}\"", .{@tagName(a)}),
                        }
                        try w.writeAll(">");
                        try inlineHtml(w, doc, cell.start, cell.end, doc.spans()[cell.first_span..cell.end_span]);
                        try w.print("</{s}>\n", .{tag});
                    }
                    try w.writeAll("</tr>\n");
                    if (r == 0) try w.writeAll("</thead>\n");
                }
                if (table.rows > 1) try w.writeAll("</tbody>\n");
                try w.writeAll("</table>\n");
            },
            else => {
                try w.writeAll("<p>");
                try blockInline(w, doc, b);
                try w.writeAll("</p>\n");
            },
        }
        if (b.depth > 0) try w.writeAll("</blockquote>\n");
        i += 1;
    }
    return out.toOwnedSlice();
}

/// The spec's HTML with a paragraph's soft line breaks as the spaces a
/// terminal shows them as.
fn softBreaksAsSpaces(html: []const u8) ![]u8 {
    const out = try t.allocator.dupe(u8, html);
    var inside = false;
    for (out, 0..) |*c, i| {
        if (std.mem.startsWith(u8, html[i..], "<p>")) inside = true;
        if (std.mem.startsWith(u8, html[i..], "</p>")) inside = false;
        if (inside and c.* == '\n') c.* = ' ';
    }
    return out;
}

test "the GFM spec's table and task list examples read as cmark-gfm reads them" {
    for (examples) |example| {
        var doc = try Document.init(t.allocator, example.markdown);
        defer doc.deinit();
        const got = try toHtml(&doc);
        defer t.allocator.free(got);
        const want = try softBreaksAsSpaces(example.html);
        defer t.allocator.free(want);
        t.expectEqualStrings(want, got) catch |err| {
            std.debug.print("GFM example {d}\n", .{example.number});
            return err;
        };
    }
}

fn md(doc: *const Document) widgets.Markdown {
    return .{ .document = doc, .theme = .{} };
}

test "a table draws its columns side by side, the header ruled off, each cell aligned" {
    var doc = try Document.init(t.allocator,
        \\| name | size | kind |
        \\| :--- | ---: | :--: |
        \\| visor | 12k | zig |
        \\| a | 3 | b |
    );
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 24, 5);
    defer h.deinit();
    const m: widgets.Markdown = .{ .document = &doc, .theme = .{ .table_header = .{ .bold = true }, .table_border = .{ .dim = true } } };
    try m.draw(h.window());
    try h.expectFrame(
        \\name  │ size │ kind
        \\──────┼──────┼─────
        \\visor │  12k │ zig
        \\a     │    3 │  b
        \\
        \\
    );
    try t.expectEqual(@as(usize, 4), m.rowCount(24, .unicode));
    try t.expect(h.styleAt(0, 0).bold);
    try t.expect(!h.styleAt(0, 2).bold);
    try t.expect(h.styleAt(6, 0).dim);
    try t.expect(h.styleAt(0, 1).dim);
}

test "a table too wide for the window shares the room out and wraps its cells" {
    var doc = try Document.init(t.allocator,
        \\| id | description of the thing |
        \\| -- | --- |
        \\| 1 | a fairly long sentence that wraps |
        \\| 2 | short |
    );
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 18, 8);
    defer h.deinit();
    try md(&doc).draw(h.window());
    // The narrow column keeps its width; the wide one takes what is left
    // and its cells wrap, every row as tall as its tallest cell.
    try h.expectFrame(
        \\id │ description
        \\   │ of the thing
        \\───┼──────────────
        \\1  │ a fairly long
        \\   │ sentence that
        \\   │ wraps
        \\2  │ short
        \\
        \\
    );
    try t.expectEqual(@as(usize, 7), md(&doc).rowCount(18, .unicode));
}

test "a task list draws its marks and hangs wrapped text under the item's text" {
    var doc = try Document.init(t.allocator, "- [ ] write the parser\n- [x] read the spec\n  - [X] nested done\n- [y] not a task");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 16, 6);
    defer h.deinit();
    const m: widgets.Markdown = .{ .document = &doc, .theme = .{ .task_done = .{ .dim = true } } };
    try m.draw(h.window());
    try h.expectFrame(
        \\- [ ] write the
        \\      parser
        \\- [x] read the
        \\      spec
        \\  - [x] nested
        \\        done
        \\
    );
    try t.expect(h.styleAt(2, 2).dim);
    try t.expect(!h.styleAt(2, 0).dim);
    try t.expectEqual(@as(?bool, false), doc.blocks()[0].task);
    try t.expectEqual(@as(?bool, true), doc.blocks()[2].task);
    try t.expectEqual(@as(?bool, null), doc.blocks()[3].task);
    try t.expectEqualStrings("[y] not a task", doc.text()[doc.blocks()[3].start..doc.blocks()[3].end]);
}

test "a table in a quote, with inline styles and a link in its cells, and the rows a program reads" {
    var doc = try Document.init(t.allocator, "> | a | b |\n> |---|---|\n> | **x** | [y](https://example.org/) |\nafter");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 14, 5);
    defer h.deinit();
    const m: widgets.Markdown = .{ .document = &doc, .theme = .{ .strong = .{ .bold = true } } };
    try m.draw(h.window());
    try h.expectFrame(
        \\│ a │ b
        \\│ ──┼──
        \\│ x │ y
        \\after
        \\
        \\
    );
    try t.expect(h.styleAt(2, 2).bold);
    const cell = h.term.screen().readCell(6, 2).?;
    try t.expectEqualStrings("https://example.org/", h.term.screen().target(cell.link).?.uri);

    var rows = widgets.Markdown.Rows.init(&doc, 14, .unicode);
    const header = rows.next().?;
    try t.expectEqual(widgets.Markdown.TableLine{ .row = 0, .line = 0 }, header.table.?);
    try t.expect(header.first);
    try t.expectEqualSlices(u16, &.{ 1, 1 }, rows.columns());
    try t.expect(rows.next().?.table.?.rule);
    const body = rows.next().?;
    try t.expectEqual(@as(usize, 1), body.table.?.row);
    try t.expectEqualSlices(u16, &.{ 1, 1 }, rows.columns());
    try t.expectEqual(@as(?widgets.Markdown.TableLine, null), rows.next().?.table);
    try t.expectEqual(@as(usize, 0), rows.columns().len);
}

test "two tables one after the other are measured each on its own" {
    // Without a blank line between them, the second header is a row of the
    // first table, as GFM reads it.
    var doc = try Document.init(t.allocator, "| a |\n|-|\n| long cell |\n\n| bb | c |\n|--|--|\n| d |");
    defer doc.deinit();
    var h = try Harness.init(t.allocator, 12, 7);
    defer h.deinit();
    try md(&doc).draw(h.window());
    try h.expectFrame(
        \\a
        \\─────────
        \\long cell
        \\
        \\bb │ c
        \\───┼──
        \\d  │
        \\
    );
}

/// Pieces Markdown sources are made of, tables and tasks in particular.
const pieces = [_][]const u8{
    "|",              " | ", "---", ":--", "--:",  ":-:",  "\\|", "`",        "**",       "a", "word ",
    "\n",             "\n",  "> ",  "- ",  "[ ] ", "[x] ", "  ",  "\u{4e2d}", "e\u{301}", "#", "```",
    "[l](https://x)",
};

fn readerHolds(gpa: std.mem.Allocator, smith: *std.testing.Smith) !void {
    var dice: corpus.Dice = .init(smith);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    for (0..dice.valueRangeAtMost(u8, 0, 80)) |_| try source.appendSlice(gpa, pieces[dice.index(pieces.len)]);
    var doc = try Document.init(gpa, source.items);
    defer doc.deinit();

    // Every range is inside what it indexes, and a table has its cells.
    for (doc.spans()) |span| try t.expect(span.start <= span.end and span.end <= doc.text().len);
    for (doc.blocks()) |b| {
        try t.expect(b.start <= b.end and b.end <= doc.text().len);
        try t.expect(b.first_span <= b.end_span and b.end_span <= doc.spans().len);
        if (b.table) |table| {
            try t.expect(table.columns > 0 and table.rows > 0);
            try t.expect(table.first_cell + table.rows * table.columns <= doc.cells().len);
            try t.expect(table.first_align + table.columns <= doc.alignments().len);
            for (doc.cells()[table.first_cell..][0 .. table.rows * table.columns]) |cell| {
                try t.expect(b.start <= cell.start and cell.start <= cell.end and cell.end <= b.end);
            }
        }
    }

    // Drawn at any width, the rows counted are the rows drawn, and the
    // frame reads back.
    const cols = dice.valueRangeAtMost(u16, 0, 30);
    const m = md(&doc);
    const count = m.rowCount(cols, .unicode);
    var rows = widgets.Markdown.Rows.init(&doc, cols, .unicode);
    var n: usize = 0;
    while (rows.next()) |row| : (n += 1) {
        if (row.table != null) {
            try t.expect(rows.columns().len > 0);
            try t.expect(rows.columns().len <= widgets.Markdown.table_columns);
        }
    }
    try t.expectEqual(count, n);
    if (cols == 0) return;
    var h = try Harness.init(gpa, cols, @intCast(@min(count, 40) + 1));
    defer h.deinit();
    try m.draw(h.window());
    _ = try h.frame();
}

test "whatever the source, the reader's ranges hold and the rows counted are drawn" {
    try std.testing.fuzz(t.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try readerHolds(gpa, smith);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the reader releases every allocation when a table or a task fails to read" {
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn parse(a: std.mem.Allocator) !void {
            var doc = try Document.init(a, "- [x] done\n| a \\| b | c |\n|:-|-:|\n| `\\|` | [l](https://x) |\n");
            defer doc.deinit();
        }
    }.parse, .{});
}

test "an escaped pipe in a cell is a pipe in its code, its link target and its text" {
    var doc = try Document.init(t.allocator, "| a |\n|-|\n| `x\\|y` [l\\|m](https://e/a\\|b) <https://e/c\\|d> p\\|q |\n\n`x\\|y`");
    defer doc.deinit();
    const table = doc.blocks()[0].table.?;
    const cell = doc.cells()[table.first_cell + 1];
    try t.expectEqualStrings("x|y l|m https://e/c|d p|q", doc.text()[cell.start..cell.end]);
    var uris: [2][]const u8 = undefined;
    var n: usize = 0;
    for (doc.spans()[cell.first_span..cell.end_span]) |span| {
        if (span.uri.len == 0) continue;
        if (n == 0 or !std.mem.eql(u8, uris[n - 1], span.uri)) {
            uris[n] = span.uri;
            n += 1;
        }
    }
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqualStrings("https://e/a|b", uris[0]);
    try t.expectEqualStrings("https://e/c|d", uris[1]);
    // Outside a table a code span keeps its backslash.
    const after = doc.blocks()[doc.blocks().len - 1];
    try t.expectEqualStrings("x\\|y", doc.text()[after.start..after.end]);
}
