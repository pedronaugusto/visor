//! Markdown read into blocks and styled runs: CommonMark with GitHub's tables, task lists,
//! strikethrough and autolinks, as datapad reads it. Owns source and rendered runs; no screen
//! or style.
const std = @import("std");
const datapad = @import("datapad");

pub const Flags = packed struct(u4) { strong: bool = false, emphasis: bool = false, code: bool = false, strikethrough: bool = false };
pub const Span = struct { start: usize, end: usize, flags: Flags, uri: []const u8 = "" };
pub const Fence = struct { char: u8, count: usize, info: []const u8 };
/// How a table column's cells sit in it, from the colons of its delimiter
/// row: `none` when it has neither.
pub const Align = enum { none, left, center, right };
/// One cell of a table: its rendered text and inline spans, as ranges of the
/// document's text and spans.
pub const TableCell = struct { start: usize, end: usize, first_span: usize, end_span: usize };
/// A table: `rows` rows of `columns` cells each, the header first, stored in
/// reading order from `first_cell`, and one alignment a column from
/// `first_align`.
pub const Table = struct { columns: u16, rows: usize, first_cell: usize, first_align: usize };
pub const Block = struct {
    /// Opening fence, or null for prose and indented code.
    fence: ?Fence = null,
    kind: enum { prose, code, heading, rule, blank, table },
    /// The table, for a `table` block.
    table: ?Table = null,
    /// For a list item that is a task: whether it is done.
    task: ?bool = null,
    /// How many block quotes the block is in.
    depth: u16 = 0,
    /// Columns before the block's marker, or before its text when it has none: the markers
    /// of the list items it is in.
    indent: u16 = 0,
    /// The list item markers the block opens, as drawn, each with a space after it: `- `,
    /// `1. `, or `- - ` for an item whose first block is in an item of its own.
    marker: []const u8 = "",
    heading: u3 = 0,
    start: usize = 0,
    end: usize = 0,
    first_span: usize = 0,
    end_span: usize = 0,
};

const documentBlock = Block;
const documentSpan = Span;
const documentFence = Fence;
const documentAlign = Align;
const documentTableCell = TableCell;
const documentTable = Table;

/// Parsed Markdown, independent of width, theme and screen. Owns all bytes.
/// Do not copy an initialized Document; deinit it once after its widgets.
pub const Document = struct {
    pub const Block = documentBlock;
    pub const Span = documentSpan;
    pub const Fence = documentFence;
    pub const Align = documentAlign;
    pub const TableCell = documentTableCell;
    pub const Table = documentTable;
    /// What `init` fails with: memory, or one of datapad's limits on what a document may
    /// hold (`datapad.Limits`'s defaults), each named.
    pub const InitError = datapad.Document.ParseError || error{ExpansionTooLarge};
    /// Private: the allocator `init` was given.
    gpa: std.mem.Allocator,
    /// Private: the copy of the source the document was read from.
    own_source: []u8,
    /// Private: the text of every block, its markup taken off.
    own_text: std.ArrayList(u8) = .empty,
    /// Private: the styled spans of the text.
    own_spans: std.ArrayList(Document.Span) = .empty,
    /// Private: the blocks, in order.
    own_blocks: std.ArrayList(Document.Block) = .empty,
    /// Private: the cells of every table, row after row.
    own_cells: std.ArrayList(Document.TableCell) = .empty,
    /// Private: each table column's alignment.
    aligns: std.ArrayList(Document.Align) = .empty,
    /// Private: the list markers blocks open, as drawn.
    own_markers: std.ArrayList(u8) = .empty,
    /// Private: every link's destination, resolved.
    uris: std.ArrayList([]u8) = .empty,

    /// Source bytes, borrowed until deinit.
    pub fn source(d: *const Document) []const u8 {
        return d.own_source;
    }
    /// Rendered bytes; block and span ranges index this slice. Borrowed until deinit.
    pub fn text(d: *const Document) []const u8 {
        return d.own_text.items;
    }
    /// Inline roles and targets, borrowed until deinit.
    pub fn spans(d: *const Document) []const Document.Span {
        return d.own_spans.items;
    }
    /// Structural blocks, borrowed until deinit.
    pub fn blocks(d: *const Document) []const Document.Block {
        return d.own_blocks.items;
    }
    /// Every table's cells, row by row, borrowed until deinit. A table
    /// block's `table` says where its own begin.
    pub fn cells(d: *const Document) []const Document.TableCell {
        return d.own_cells.items;
    }
    /// Every table's column alignments, borrowed until deinit.
    pub fn alignments(d: *const Document) []const Document.Align {
        return d.aligns.items;
    }

    /// `input` read as GitHub Flavored Markdown. A block is a paragraph, a heading, a rule,
    /// a table, one line of code, or a blank line of the source between two of them.
    pub fn init(gpa: std.mem.Allocator, input: []const u8) InitError!Document {
        var d: Document = .{ .gpa = gpa, .own_source = try gpa.dupe(u8, input) };
        errdefer d.deinit();
        if (input.len == 0) return d;
        // The text is mostly the source with its markup taken out: one allocation holds it.
        try d.own_text.ensureTotalCapacity(gpa, input.len);
        var parsed = try datapad.Document.parse(gpa, .init(d.own_source), .{ .extensions = .gfm });
        defer parsed.deinit();
        var events = try datapad.Events.init(gpa, &parsed);
        defer events.deinit();
        var reader: Reader = .{ .d = &d, .events = &events };
        defer reader.deinit();
        try reader.read();
        return d;
    }
    pub fn deinit(d: *Document) void {
        d.gpa.free(d.own_source);
        d.own_text.deinit(d.gpa);
        d.own_spans.deinit(d.gpa);
        d.own_blocks.deinit(d.gpa);
        d.own_cells.deinit(d.gpa);
        d.aligns.deinit(d.gpa);
        d.own_markers.deinit(d.gpa);
        for (d.uris.items) |bytes| d.gpa.free(bytes);
        d.uris.deinit(d.gpa);
        d.* = undefined;
    }

    fn append(d: *Document, bytes: []const u8, flags: Flags, uri: []const u8) !void {
        if (bytes.len == 0) return;
        const start = d.own_text.items.len;
        try d.own_text.appendSlice(d.gpa, bytes);
        try d.own_spans.append(d.gpa, .{ .start = start, .end = d.own_text.items.len, .flags = flags, .uri = uri });
    }
};

/// One pass over a document's events, building its blocks.
const Reader = struct {
    d: *Document,
    events: *datapad.Events,
    /// How many block quotes are open.
    depth: u16 = 0,
    /// The list items open, innermost last.
    items: std.ArrayList(Item) = .empty,
    /// Each block that opens list items, and where its markers are in `own_markers`.
    markers: std.ArrayList(struct { block: usize, start: usize, end: usize }) = .empty,
    /// The links and images open, innermost last: each one's destination.
    links: std.ArrayList([]const u8) = .empty,
    /// The block being filled, by index.
    open: ?usize = null,
    /// How long the open block's markers are.
    open_marker: usize = 0,
    /// Where the last block of the source ended in it, or null before the first.
    last_end: ?usize = null,
    strong: u32 = 0,
    emphasis: u32 = 0,
    strikethrough: u32 = 0,
    /// The code span and the inline HTML the last piece belonged to: a span's pieces, one a
    /// line, are joined by a space.
    code_span: ?datapad.Span = null,
    html_span: ?datapad.Span = null,
    /// The code block being read, whose lines are blocks of their own.
    code: ?struct { fence: ?Fence } = null,
    /// Columns of a tab the containers took part of, before the next line of code.
    spaces: u16 = 0,
    /// The table being read.
    table: ?Building = null,
    /// Whether the inlines being read are a table cell's, where `\|` is a pipe in code spans,
    /// autolinks and their targets too.
    in_cell: bool = false,

    const Item = struct { start: usize, end: usize, shown: bool = false };
    const Building = struct {
        first_cell: usize,
        first_align: usize,
        columns: u16 = 0,
        rows: usize = 0,
        head: bool = false,
        /// The cells of the row being read so far.
        row_cells: usize = 0,
        cell: TableCell = undefined,
    };

    fn deinit(r: *Reader) void {
        const gpa = r.d.gpa;
        r.items.deinit(gpa);
        r.markers.deinit(gpa);
        r.links.deinit(gpa);
    }

    fn read(r: *Reader) !void {
        const src = r.d.own_source;
        while (try r.events.next()) |e| switch (e.kind) {
            .enter => |node| try r.enter(e.span, node),
            .exit => |node| try r.exit(e.span, node),
            .text => if (r.code != null) try r.line(e.span.of(src)) else try r.literal(e.span.of(src)),
            .spaces => |n| r.spaces +|= n,
            // The span is the backslash and the character it escapes.
            .escape => try r.put(e.span.of(src)[1..]),
            .reference => |ref| {
                var buffer: [8]u8 = undefined;
                var len = std.unicode.utf8Encode(ref.first, &buffer) catch 0;
                if (ref.second != 0) len += std.unicode.utf8Encode(ref.second, buffer[len..]) catch 0;
                try r.put(buffer[0..len]);
            },
            .code => |content| {
                var code = r.flags();
                code.code = true;
                if (r.code_span) |last| if (last.start.eql(e.span.start)) try r.d.append(" ", code, r.uri());
                r.code_span = e.span;
                try r.appendLiteral(content.of(src), code);
            },
            .html => |piece| if (r.code != null) try r.line(piece.of(src)) else {
                if (r.html_span) |last| if (last.start.eql(e.span.start)) try r.put(" ");
                r.html_span = e.span;
                try r.literal(piece.of(src));
            },
            .soft_break => try r.put(" "),
            .hard_break => try r.hardBreak(),
            .rule => {
                try r.blanks(e.span.start.raw());
                try r.begin(.{ .kind = .rule, .depth = r.depth });
                r.close(e.span);
            },
            .task => |done| r.d.own_blocks.items[r.open.?].task = done,
        };
        try r.blanks(null);
        for (r.markers.items) |m| r.d.own_blocks.items[m.block].marker = r.d.own_markers.items[m.start..m.end];
    }

    fn enter(r: *Reader, span: datapad.Span, node: datapad.Node) !void {
        const src = r.d.own_source;
        const gpa = r.d.gpa;
        switch (node) {
            .paragraph => {
                try r.blanks(span.start.raw());
                try r.begin(.{ .kind = .prose, .depth = r.depth });
            },
            .heading => |h| {
                try r.blanks(span.start.raw());
                try r.begin(.{ .kind = .heading, .depth = r.depth, .heading = @intCast(h.level.widen(u8)) });
            },
            .block_quote => r.depth +|= 1,
            .list => {},
            .item => {
                // The marker as written: a bullet, or up to nine digits and their delimiter.
                const at = span.start.raw();
                var digits: usize = 0;
                while (digits < 9 and at + digits < src.len and std.ascii.isDigit(src[at + digits])) digits += 1;
                const start = r.d.own_markers.items.len;
                try r.d.own_markers.appendSlice(gpa, src[at..][0 .. digits + 1]);
                try r.d.own_markers.append(gpa, ' ');
                try r.items.append(gpa, .{ .start = start, .end = r.d.own_markers.items.len });
            },
            .code_block => |c| {
                try r.blanks(span.start.raw());
                r.code = .{ .fence = if (c.fenced) fenceAt(src, span.start.raw(), c.info.of(src)) else null };
            },
            .html_block, .front_matter => {
                try r.blanks(span.start.raw());
                r.code = .{ .fence = null };
            },
            .table => {
                try r.blanks(span.start.raw());
                try r.begin(.{ .kind = .table, .depth = r.depth });
                r.table = .{ .first_cell = r.d.own_cells.items.len, .first_align = r.d.aligns.items.len };
            },
            .table_head => r.table.?.head = true,
            .table_row => r.table.?.row_cells = 0,
            .table_cell => |alignment| {
                const t = &r.table.?;
                if (t.head and t.row_cells < std.math.maxInt(u16)) try r.d.aligns.append(gpa, switch (alignment) {
                    .none => .none,
                    .left => .left,
                    .center => .center,
                    .right => .right,
                });
                t.cell = .{ .start = r.d.own_text.items.len, .end = 0, .first_span = r.d.own_spans.items.len, .end_span = 0 };
                r.in_cell = true;
            },
            .emphasis => r.emphasis += 1,
            .strong => r.strong += 1,
            .strikethrough => r.strikethrough += 1,
            .link, .image => |link| try r.links.append(gpa, try r.destination(link)),
        }
    }

    fn exit(r: *Reader, span: datapad.Span, node: datapad.Node) !void {
        const gpa = r.d.gpa;
        switch (node) {
            .paragraph, .heading => r.close(span),
            .block_quote => r.depth -|= 1,
            .list => {},
            .item => {
                // An item with nothing in it is its marker alone.
                if (!r.items.items[r.items.items.len - 1].shown) {
                    try r.blanks(span.start.raw());
                    try r.begin(.{ .kind = .prose, .depth = r.depth });
                    r.close(span);
                }
                _ = r.items.pop();
            },
            .code_block, .html_block, .front_matter => {
                r.code = null;
                r.spaces = 0;
                r.last_end = span.end.raw();
            },
            .table => {
                const t = r.table.?;
                r.d.own_blocks.items[r.open.?].table = .{ .columns = t.columns, .rows = t.rows, .first_cell = t.first_cell, .first_align = t.first_align };
                r.table = null;
                r.close(span);
            },
            .table_head => {
                const t = &r.table.?;
                t.head = false;
                t.columns = @intCast(@min(t.row_cells, std.math.maxInt(u16)));
            },
            .table_row => {
                const t = &r.table.?;
                // Every row has as many cells as the header: the ones it lacks are empty.
                while (t.row_cells < t.columns) : (t.row_cells += 1) {
                    const at = r.d.own_text.items.len;
                    const spans_at = r.d.own_spans.items.len;
                    try r.d.own_cells.append(gpa, .{ .start = at, .end = at, .first_span = spans_at, .end_span = spans_at });
                }
                t.rows += 1;
            },
            .table_cell => {
                const t = &r.table.?;
                r.in_cell = false;
                const limit: usize = if (t.head) std.math.maxInt(u16) else t.columns;
                if (t.row_cells >= limit) {
                    // A cell past the header's is dropped.
                    r.d.own_text.shrinkRetainingCapacity(t.cell.start);
                    r.d.own_spans.shrinkRetainingCapacity(t.cell.first_span);
                } else {
                    t.cell.end = r.d.own_text.items.len;
                    t.cell.end_span = r.d.own_spans.items.len;
                    try r.d.own_cells.append(gpa, t.cell);
                }
                t.row_cells += 1;
            },
            .emphasis => r.emphasis -|= 1,
            .strong => r.strong -|= 1,
            .strikethrough => r.strikethrough -|= 1,
            .link, .image => _ = r.links.pop(),
        }
    }

    fn flags(r: *const Reader) Flags {
        return .{ .strong = r.strong > 0, .emphasis = r.emphasis > 0, .strikethrough = r.strikethrough > 0 };
    }

    fn uri(r: *const Reader) []const u8 {
        return if (r.links.items.len == 0) "" else r.links.items[r.links.items.len - 1];
    }

    /// Bytes in the open block, styled as the inlines open around them are.
    fn put(r: *Reader, bytes: []const u8) !void {
        try r.d.append(bytes, r.flags(), r.uri());
    }

    /// Bytes as written, but for a table cell's escaped pipes.
    fn literal(r: *Reader, bytes: []const u8) !void {
        try r.appendLiteral(bytes, r.flags());
    }

    /// Bytes kept as they are, but for a table cell's escaped pipes, which are pipes even in
    /// code spans and autolinks.
    fn appendLiteral(r: *Reader, bytes: []const u8, flags_: Flags) !void {
        const d = r.d;
        if (!r.in_cell or std.mem.find(u8, bytes, "\\|") == null) return d.append(bytes, flags_, r.uri());
        const start = d.own_text.items.len;
        try d.own_text.ensureUnusedCapacity(d.gpa, bytes.len);
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\\' and i + 1 < bytes.len and bytes[i + 1] == '|') continue;
            d.own_text.appendAssumeCapacity(bytes[i]);
        }
        try d.own_spans.append(d.gpa, .{ .start = start, .end = d.own_text.items.len, .flags = flags_, .uri = r.uri() });
    }

    /// A link's destination as the URL it means, owned by the document; empty when it has none.
    fn destination(r: *Reader, link: datapad.Link) ![]const u8 {
        const gpa = r.d.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        r.events.writeDestination(&out.writer, link) catch return error.OutOfMemory;
        if (out.written().len == 0) return "";
        const owned = try out.toOwnedSlice();
        r.d.uris.append(gpa, owned) catch |err| {
            gpa.free(owned);
            return err;
        };
        if (!r.in_cell) return owned;
        // An autolink's target is written as it stands, a cell's escaped pipes with it.
        var len: usize = 0;
        for (owned, 0..) |c, i| {
            if (c == '\\' and i + 1 < owned.len and owned[i + 1] == '|') continue;
            owned[len] = c;
            len += 1;
        }
        return owned[0..len];
    }

    /// Opens a block: the first since a list item opened takes that item's marker, and the
    /// markers of the items it is in that no block has shown yet.
    fn begin(r: *Reader, value: Block) !void {
        const gpa = r.d.gpa;
        var b = value;
        b.start = r.d.own_text.items.len;
        b.first_span = r.d.own_spans.items.len;
        var indent: usize = 0;
        var marker: ?struct { start: usize, end: usize } = null;
        for (r.items.items) |*item| {
            if (item.shown) {
                indent += item.end - item.start;
                continue;
            }
            item.shown = true;
            if (marker) |*m| m.end = item.end else marker = .{ .start = item.start, .end = item.end };
        }
        b.indent = @intCast(@min(indent, std.math.maxInt(u16)));
        r.open_marker = 0;
        const index = r.d.own_blocks.items.len;
        try r.d.own_blocks.append(gpa, b);
        if (marker) |m| {
            try r.markers.append(gpa, .{ .block = index, .start = m.start, .end = m.end });
            r.open_marker = m.end - m.start;
        }
        r.open = index;
    }

    /// Closes the open block, which ends at `span` in the source.
    fn close(r: *Reader, span: datapad.Span) void {
        const b = &r.d.own_blocks.items[r.open.?];
        b.end = r.d.own_text.items.len;
        b.end_span = r.d.own_spans.items.len;
        r.open = null;
        r.last_end = span.end.raw();
    }

    /// One line of a code block, HTML block or front matter: a block of its own.
    fn line(r: *Reader, bytes: []const u8) !void {
        try r.begin(.{ .kind = .code, .depth = r.depth, .fence = r.code.?.fence });
        const d = r.d;
        if (r.spaces > 0) {
            const start = d.own_text.items.len;
            try d.own_text.appendNTimes(d.gpa, ' ', r.spaces);
            try d.own_spans.append(d.gpa, .{ .start = start, .end = d.own_text.items.len, .flags = .{} });
            r.spaces = 0;
        }
        try d.append(bytes, .{}, "");
        const b = &d.own_blocks.items[r.open.?];
        b.end = d.own_text.items.len;
        b.end_span = d.own_spans.items.len;
        r.open = null;
    }

    /// A hard line break: the rest of the paragraph is a block of its own, under the text of
    /// the block it breaks.
    fn hardBreak(r: *Reader) !void {
        const d = r.d;
        const broken = d.own_blocks.items[r.open.?];
        const hang = @as(usize, broken.indent) + r.open_marker + @as(usize, if (broken.task != null) task_width else 0);
        const b = &d.own_blocks.items[r.open.?];
        b.end = d.own_text.items.len;
        b.end_span = d.own_spans.items.len;
        try d.own_blocks.append(d.gpa, .{
            .kind = broken.kind,
            .depth = broken.depth,
            .heading = broken.heading,
            .indent = @intCast(@min(hang, std.math.maxInt(u16))),
            .start = d.own_text.items.len,
            .first_span = d.own_spans.items.len,
        });
        r.open = d.own_blocks.items.len - 1;
        r.open_marker = 0;
    }

    /// A blank block for each blank line of the source after the last block and before the
    /// line `before` is on, or before the end when it is null. A line of quote markers alone
    /// is blank, as deep as its markers.
    fn blanks(r: *Reader, before: ?usize) !void {
        const src = r.d.own_source;
        // A final line break ends the last line rather than beginning one.
        const lines_end = if (std.mem.endsWith(u8, src, "\n")) src.len - 1 else src.len;
        var at: usize = if (r.last_end) |end| (std.mem.findScalarPos(u8, src, end, '\n') orelse return) + 1 else 0;
        const stop = if (before) |b| (if (std.mem.findScalarLast(u8, src[0..b], '\n')) |nl| nl + 1 else 0) else lines_end + 1;
        while (at < stop) {
            const nl = std.mem.findScalarPos(u8, src, at, '\n') orelse src.len;
            const marked = quote(std.mem.trimEnd(u8, src[at..nl], "\r"));
            if (std.mem.trim(u8, marked.rest, " \t").len == 0) {
                const start = r.d.own_text.items.len;
                const spans_at = r.d.own_spans.items.len;
                try r.d.own_blocks.append(r.d.gpa, .{ .kind = .blank, .depth = marked.depth, .start = start, .end = start, .first_span = spans_at, .end_span = spans_at });
            }
            at = nl + 1;
        }
    }
};

/// Columns a task's mark and the space after it take, as the widget draws them.
const task_width = 4;

/// The fence at the start of a fenced code block, `at` in `src`.
fn fenceAt(src: []const u8, at: usize, info: []const u8) Fence {
    var start = at;
    while (start < src.len and src[start] == ' ') start += 1;
    var count: usize = 0;
    while (start + count < src.len and src[start + count] == src[start]) count += 1;
    return .{ .char = src[start], .count = count, .info = info };
}

/// The lines of a Markdown source one at a time, each with its quotation
/// taken off and the fenced block it belongs to, if any, by rules of its own
/// for quotes and fences (CommonMark's, for a plain source), for a program
/// that shows a source line by line -- a transcript, say -- rather than as
/// the blocks `Document` makes of it.
///
/// A fence opens on a line whose quotation is followed by at most three
/// spaces and a run of three or more backticks or tildes, and closes on a
/// line at the same quote depth with a run of the same character at least as
/// long and nothing after it. Inside a fenced block a `>` is the code's own:
/// the block's depth is the depth of the line that opened it, and only that
/// many quote markers come off each line in it.
///
/// Indented code is not this iterator's to say: whether four spaces begin
/// code or continue a list item depends on the blocks before, which only
/// `Document` keeps. Borrows `source`; allocates nothing.
pub const Quoted = struct {
    /// Private: the source lines still to read.
    lines: std.mem.SplitIterator(u8, .scalar),
    /// Private: the block the lines are in, and the quote depth it opened at.
    own_fence: ?struct { fence: Fence, depth: u16 } = null,

    /// One source line, read.
    pub const Line = struct {
        /// The whole line, without its line break or a carriage return at
        /// its end.
        text: []const u8,
        /// The line with its quote markers taken off, and the spaces after
        /// them kept but one. In a fenced block, only the block's own
        /// markers come off.
        body: []const u8,
        /// How many quotes deep the line is: its own markers, or in a fenced
        /// block the block's depth.
        depth: u16,
        /// Whether the line belongs to a fenced block: the fence that opens
        /// it, a line of its code, or the fence that closes it.
        code: bool,
        /// The fence of the block the line belongs to, when `code`.
        fence: ?Fence = null,
        /// Whether this line is the fence that opens the block.
        opens: bool = false,
        /// Whether this line is the fence that closes the block.
        closes: bool = false,
    };

    /// The lines of `source`, which is split at every `\n`: a source that
    /// ends in one ends in an empty line.
    pub fn init(source: []const u8) Quoted {
        return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
    }

    /// The next line, or null after the last.
    pub fn next(q: *Quoted) ?Line {
        const raw = q.lines.next() orelse return null;
        const text = std.mem.trimEnd(u8, raw, "\r");
        const marked = quote(text);
        if (q.own_fence) |open| {
            const body = stripQuote(text, open.depth);
            const trimmed = std.mem.trimStart(u8, body, " ");
            const closes = if (fence(trimmed)) |run|
                marked.depth == open.depth and run.char == open.fence.char and run.count >= open.fence.count and
                    std.mem.trim(u8, trimmed[run.count..], " \t").len == 0
            else
                false;
            if (closes) q.own_fence = null;
            return .{ .text = text, .body = body, .depth = open.depth, .code = true, .fence = open.fence, .closes = closes };
        }
        const plain: Line = .{ .text = text, .body = marked.rest, .depth = marked.depth, .code = false };
        var indent: usize = 0;
        while (indent < marked.rest.len and marked.rest[indent] == ' ') indent += 1;
        if (indent >= 4 or std.mem.startsWith(u8, marked.rest, "\t")) return plain;
        const trimmed = std.mem.trim(u8, marked.rest, " \t");
        const run = fence(trimmed) orelse return plain;
        const opened: Fence = .{ .char = run.char, .count = run.count, .info = std.mem.trim(u8, trimmed[run.count..], " \t") };
        q.own_fence = .{ .fence = opened, .depth = marked.depth };
        return .{ .text = text, .body = marked.rest, .depth = marked.depth, .code = true, .fence = opened, .opens = true };
    }
};

fn quote(line: []const u8) struct { depth: u16, rest: []const u8 } {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    if (i >= line.len or line[i] != '>') return .{ .depth = 0, .rest = line };
    var depth: u16 = 0;
    while (i < line.len and line[i] == '>') {
        depth +|= 1;
        i += 1;
        if (i < line.len and line[i] == ' ') i += 1;
        var next = i;
        while (next < line.len and line[next] == ' ') next += 1;
        if (next < line.len and line[next] == '>') i = next;
    }
    return .{ .depth = depth, .rest = line[i..] };
}
fn fence(body: []const u8) ?struct { char: u8, count: usize } {
    if (body.len < 3 or (body[0] != '`' and body[0] != '~')) return null;
    var n: usize = 0;
    while (n < body.len and body[n] == body[0]) n += 1;
    if (n < 3) return null;
    return .{ .char = body[0], .count = n };
}

fn stripQuote(line: []const u8, depth: u16) []const u8 {
    if (depth == 0) return line;
    var rest = line;
    var level: u16 = 0;
    while (level < depth) : (level += 1) {
        var i: usize = 0;
        while (i < rest.len and i < 3 and rest[i] == ' ') i += 1;
        if (i >= rest.len or rest[i] != '>') return rest;
        i += 1;
        if (i < rest.len and rest[i] == ' ') i += 1;
        rest = rest[i..];
    }
    return rest;
}
