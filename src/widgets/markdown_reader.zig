//! A small Markdown reader. Owns source and rendered runs; no screen or style.
const std = @import("std");

pub const Flags = packed struct(u3) { strong: bool = false, emphasis: bool = false, code: bool = false };
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
    depth: u16 = 0,
    indent: u16 = 0,
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
    _allocator: std.mem.Allocator,
    _source: []u8,
    _text: std.ArrayList(u8) = .empty,
    _spans: std.ArrayList(Document.Span) = .empty,
    _blocks: std.ArrayList(Document.Block) = .empty,
    _cells: std.ArrayList(Document.TableCell) = .empty,
    _aligns: std.ArrayList(Document.Align) = .empty,
    /// Cell sources with their escaped pipes taken out, which link targets
    /// in them borrow.
    _unescaped: std.ArrayList([]u8) = .empty,

    /// Source bytes, borrowed until deinit.
    pub fn source(d: *const Document) []const u8 {
        return d._source;
    }
    /// Rendered bytes; block and span ranges index this slice. Borrowed until deinit.
    pub fn text(d: *const Document) []const u8 {
        return d._text.items;
    }
    /// Inline roles and targets, borrowed until deinit.
    pub fn spans(d: *const Document) []const Document.Span {
        return d._spans.items;
    }
    /// Structural blocks, borrowed until deinit.
    pub fn blocks(d: *const Document) []const Document.Block {
        return d._blocks.items;
    }
    /// Every table's cells, row by row, borrowed until deinit. A table
    /// block's `table` says where its own begin.
    pub fn cells(d: *const Document) []const Document.TableCell {
        return d._cells.items;
    }
    /// Every table's column alignments, borrowed until deinit.
    pub fn alignments(d: *const Document) []const Document.Align {
        return d._aligns.items;
    }

    pub fn init(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!Document {
        var d: Document = .{ ._allocator = allocator, ._source = try allocator.dupe(u8, input) };
        errdefer d.deinit();
        try d.read();
        return d;
    }
    pub fn deinit(d: *Document) void {
        d._allocator.free(d._source);
        d._text.deinit(d._allocator);
        d._spans.deinit(d._allocator);
        d._blocks.deinit(d._allocator);
        d._cells.deinit(d._allocator);
        d._aligns.deinit(d._allocator);
        for (d._unescaped.items) |bytes| d._allocator.free(bytes);
        d._unescaped.deinit(d._allocator);
        d.* = undefined;
    }

    fn append(d: *Document, bytes: []const u8, flags: Flags, uri: []const u8) !void {
        if (bytes.len == 0) return;
        const start = d._text.items.len;
        try d._text.appendSlice(d._allocator, bytes);
        try d._spans.append(d._allocator, .{ .start = start, .end = d._text.items.len, .flags = flags, .uri = uri });
    }

    fn read(d: *Document) !void {
        if (d._source.len == 0) return;
        // A final line break ends the last line rather than beginning one.
        const lines_of = if (std.mem.endsWith(u8, d._source, "\n")) d._source[0 .. d._source.len - 1] else d._source;
        var lines: Quoted = .init(lines_of);
        var may_join = false;
        while (lines.next()) |q| {
            if (q.fence) |f| {
                if (!q.opens and !q.closes) try d.block(.{ .kind = .code, .depth = q.depth, .fence = f }, q.body, true);
                may_join = false;
                continue;
            }
            var body = q.body;
            var indent: usize = 0;
            while (indent < body.len and body[indent] == ' ') indent += 1;
            if (indent >= 4 or std.mem.startsWith(u8, body, "\t")) {
                // A hanging list continuation takes precedence over indented code.
                const last = if (d._blocks.items.len == 0) null else &d._blocks.items[d._blocks.items.len - 1];
                if (!(may_join and last != null and last.?.marker.len > 0 and q.depth == last.?.depth and indent >= @as(usize, last.?.indent) + last.?.marker.len)) {
                    body = body[if (indent >= 4) 4 else 1..];
                    try d.block(.{ .kind = .code, .depth = q.depth }, body, true);
                    may_join = false;
                    continue;
                }
            }
            body = std.mem.trim(u8, body, " \t");
            if (body.len == 0) {
                try d.block(.{ .kind = .blank, .depth = q.depth }, "", true);
                may_join = false;
                continue;
            }
            if (rule(body)) {
                try d.block(.{ .kind = .rule, .depth = q.depth }, "", true);
                may_join = false;
                continue;
            }
            var heading: usize = 0;
            while (heading < body.len and body[heading] == '#') heading += 1;
            if (heading > 0 and heading <= 6 and (heading == body.len or body[heading] == ' ')) {
                try d.block(.{ .kind = .heading, .depth = q.depth, .heading = @intCast(heading) }, std.mem.trimStart(u8, body[heading..], " "), false);
                may_join = false;
                continue;
            }
            const marker = listMarker(body);
            if (marker > 0) {
                var item = std.mem.trimStart(u8, body[marker..], " ");
                const task = taskMark(item);
                if (task != null) item = std.mem.trimStart(u8, item[4..], " \t");
                try d.block(.{ .kind = .prose, .depth = q.depth, .indent = @intCast(@min(indent, std.math.maxInt(u16))), .marker = body[0..marker], .task = task }, item, false);
                may_join = true;
                continue;
            }
            // A row with a pipe in it, and under it a delimiter row of as
            // many cells, begin a table, which takes every line after them
            // up to a blank one or the start of another block.
            if (piped(body)) {
                var ahead = lines;
                if (ahead.next()) |under| {
                    const header_cells = cellCount(body);
                    if (!under.code and under.depth == q.depth and delimiterRow(under.body) == header_cells) {
                        lines = ahead;
                        try d.table(q.depth, body, under.body, &lines);
                        may_join = false;
                        continue;
                    }
                }
            }
            if (may_join) {
                const last = &d._blocks.items[d._blocks.items.len - 1];
                if (last.depth == q.depth and (last.marker.len == 0 or indent >= @as(usize, last.indent) + last.marker.len)) {
                    try d.append(" ", .{}, "");
                    try d.inlineRead(body, .{}, "", 0);
                    last.end = d._text.items.len;
                    last.end_span = d._spans.items.len;
                    continue;
                }
            }
            try d.block(.{ .kind = .prose, .depth = q.depth }, body, false);
            may_join = true;
        }
    }

    fn table(d: *Document, depth: u16, header: []const u8, delimiter: []const u8, lines: *Quoted) !void {
        var b: Document.Block = .{ .kind = .table, .depth = depth, .start = d._text.items.len, .first_span = d._spans.items.len };
        const columns: u16 = @intCast(@min(cellCount(header), std.math.maxInt(u16)));
        const first_align = d._aligns.items.len;
        var delimiters: Cells = .init(delimiter);
        while (delimiters.next()) |cell| {
            const c = std.mem.trim(u8, cell, " \t");
            const left = c[0] == ':';
            const right = c[c.len - 1] == ':';
            try d._aligns.append(d._allocator, if (left and right) .center else if (left) .left else if (right) .right else .none);
        }
        const first_cell = d._cells.items.len;
        try d.row(header, columns);
        var rows: usize = 1;
        while (true) {
            var ahead = lines.*;
            const next = ahead.next() orelse break;
            if (next.code or next.depth != depth) break;
            const body = std.mem.trim(u8, next.body, " \t");
            if (body.len == 0 or interrupts(body)) break;
            lines.* = ahead;
            try d.row(body, columns);
            rows += 1;
        }
        b.table = .{ .columns = columns, .rows = rows, .first_cell = first_cell, .first_align = first_align };
        b.end = d._text.items.len;
        b.end_span = d._spans.items.len;
        try d._blocks.append(d._allocator, b);
    }

    /// One row of a table: exactly `columns` cells, the ones it lacks empty
    /// and the ones past them dropped.
    fn row(d: *Document, line: []const u8, columns: u16) !void {
        var it: Cells = .init(line);
        var n: u16 = 0;
        while (n < columns) : (n += 1) {
            const raw = std.mem.trim(u8, it.next() orelse "", " \t");
            var cell_source = raw;
            if (std.mem.find(u8, raw, "\\|") != null) {
                // An escaped pipe is a pipe in the cell, in a code span too.
                const owned = try d._allocator.alloc(u8, std.mem.replacementSize(u8, raw, "\\|", "|"));
                _ = std.mem.replace(u8, raw, "\\|", "|", owned);
                d._unescaped.append(d._allocator, owned) catch |err| {
                    d._allocator.free(owned);
                    return err;
                };
                cell_source = owned;
            }
            const start = d._text.items.len;
            const first_span = d._spans.items.len;
            try d.inlineRead(cell_source, .{}, "", 0);
            try d._cells.append(d._allocator, .{ .start = start, .end = d._text.items.len, .first_span = first_span, .end_span = d._spans.items.len });
        }
    }

    fn block(d: *Document, value: Document.Block, body: []const u8, literal: bool) !void {
        var b = value;
        b.start = d._text.items.len;
        b.first_span = d._spans.items.len;
        if (literal) try d.append(body, .{}, "") else try d.inlineRead(body, .{}, "", 0);
        b.end = d._text.items.len;
        b.end_span = d._spans.items.len;
        try d._blocks.append(d._allocator, b);
    }

    fn inlineRead(d: *Document, body: []const u8, flags: Flags, uri: []const u8, depth: u8) std.mem.Allocator.Error!void {
        if (depth == 32) return d.append(body, flags, uri);
        var i: usize = 0;
        var plain: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len and std.ascii.isPunctuation(body[i + 1])) {
                try d.append(body[plain..i], flags, uri);
                try d.append(body[i + 1 .. i + 2], flags, uri);
                i += 2;
                plain = i;
                continue;
            }
            if (body[i] == '`' or body[i] == '*' or body[i] == '_') {
                const ch = body[i];
                var n: usize = 1;
                while (i + n < body.len and body[i + n] == ch) n += 1;
                if (ch != '`') n = @min(n, 2);
                if (delimiterEnd(body, i, n, ch)) |end| {
                    if (end > i + n and (ch == '`' or (!std.ascii.isWhitespace(body[i + n]) and !std.ascii.isWhitespace(body[end - 1])))) {
                        try d.append(body[plain..i], flags, uri);
                        var nested = flags;
                        if (ch == '`') {
                            nested.code = true;
                            try d.append(body[i + n .. end], nested, uri);
                        } else {
                            if (n == 2) nested.strong = true else nested.emphasis = true;
                            try d.inlineRead(body[i + n .. end], nested, uri, depth + 1);
                        }
                        i = end + n;
                        plain = i;
                        continue;
                    }
                }
            }
            if (body[i] == '[' and (i == 0 or body[i - 1] != '!')) {
                if (std.mem.find(u8, body[i + 1 ..], "](")) |off| {
                    const label_end = i + 1 + off;
                    const target_start = label_end + 2;
                    if (targetEnd(body, target_start)) |end| {
                        const target = body[target_start..end];
                        if (target.len > 0 and std.mem.indexOfAny(u8, target, " \t\n") == null) {
                            try d.append(body[plain..i], flags, uri);
                            try d.inlineRead(body[i + 1 .. label_end], flags, target, depth + 1);
                            i = end + 1;
                            plain = i;
                            continue;
                        }
                    }
                }
            }
            if (body[i] == '<') {
                if (std.mem.findScalar(u8, body[i + 1 ..], '>')) |off| {
                    const end = i + 1 + off;
                    const target = body[i + 1 .. end];
                    if ((std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://")) and std.mem.indexOfAny(u8, target, " \t") == null) {
                        try d.append(body[plain..i], flags, uri);
                        try d.append(target, flags, target);
                        i = end + 1;
                        plain = i;
                        continue;
                    }
                }
            }
            i += 1;
        }
        try d.append(body[plain..], flags, uri);
    }
};

/// The lines of a Markdown source one at a time, each with its quotation
/// taken off and the fenced block it belongs to, if any: the reader's own
/// rules for quotes and fences, for a program that shows a source line by
/// line -- a transcript, say -- rather than as the blocks `Document` makes
/// of it.
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
    _lines: std.mem.SplitIterator(u8, .scalar),
    /// The block the lines are in, and the quote depth it opened at.
    _fence: ?struct { fence: Fence, depth: u16 } = null,

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
        return .{ ._lines = std.mem.splitScalar(u8, source, '\n') };
    }

    /// The next line, or null after the last.
    pub fn next(q: *Quoted) ?Line {
        const raw = q._lines.next() orelse return null;
        const text = std.mem.trimEnd(u8, raw, "\r");
        const marked = quote(text);
        if (q._fence) |open| {
            const body = stripQuote(text, open.depth);
            const trimmed = std.mem.trimStart(u8, body, " ");
            const closes = if (fence(trimmed)) |run|
                marked.depth == open.depth and run.char == open.fence.char and run.count >= open.fence.count and
                    std.mem.trim(u8, trimmed[run.count..], " \t").len == 0
            else
                false;
            if (closes) q._fence = null;
            return .{ .text = text, .body = body, .depth = open.depth, .code = true, .fence = open.fence, .closes = closes };
        }
        const plain: Line = .{ .text = text, .body = marked.rest, .depth = marked.depth, .code = false };
        var indent: usize = 0;
        while (indent < marked.rest.len and marked.rest[indent] == ' ') indent += 1;
        if (indent >= 4 or std.mem.startsWith(u8, marked.rest, "\t")) return plain;
        const trimmed = std.mem.trim(u8, marked.rest, " \t");
        const run = fence(trimmed) orelse return plain;
        const opened: Fence = .{ .char = run.char, .count = run.count, .info = std.mem.trim(u8, trimmed[run.count..], " \t") };
        q._fence = .{ .fence = opened, .depth = marked.depth };
        return .{ .text = text, .body = marked.rest, .depth = marked.depth, .code = true, .fence = opened, .opens = true };
    }
};

/// The cells of a table row: split at every pipe a backslash does not
/// escape, one pipe at each end dropped.
const Cells = struct {
    rest: ?[]const u8,

    fn init(line: []const u8) Cells {
        var body = std.mem.trim(u8, line, " \t");
        if (body.len > 0 and body[0] == '|') body = body[1..];
        if (endsInPipe(body)) body = body[0 .. body.len - 1];
        return .{ .rest = body };
    }

    fn next(c: *Cells) ?[]const u8 {
        const body = c.rest orelse return null;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\') {
                i += 1;
            } else if (body[i] == '|') {
                c.rest = body[i + 1 ..];
                return body[0..i];
            }
        }
        c.rest = null;
        return body;
    }
};

fn endsInPipe(body: []const u8) bool {
    if (body.len == 0 or body[body.len - 1] != '|') return false;
    var slashes: usize = 0;
    while (slashes + 1 < body.len and body[body.len - 2 - slashes] == '\\') slashes += 1;
    return slashes % 2 == 0;
}

/// Whether a line has a pipe a backslash does not escape.
fn piped(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
        } else if (body[i] == '|') return true;
    }
    return false;
}

fn cellCount(line: []const u8) usize {
    var it: Cells = .init(line);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// How many cells a delimiter row has, or null when the line is not one:
/// a pipe somewhere, and every cell hyphens with a colon at either end.
fn delimiterRow(line: []const u8) ?usize {
    const body = std.mem.trim(u8, line, " \t");
    if (!piped(body)) return null;
    var it: Cells = .init(body);
    var n: usize = 0;
    while (it.next()) |cell| : (n += 1) {
        var c = std.mem.trim(u8, cell, " \t");
        if (c.len > 0 and c[0] == ':') c = c[1..];
        if (c.len > 0 and c[c.len - 1] == ':') c = c[0 .. c.len - 1];
        if (c.len == 0) return null;
        for (c) |ch| if (ch != '-') return null;
    }
    return n;
}

/// Whether a line begins a block that ends a table: a heading, a rule or a
/// list item. Quotes and fences are told apart by `Quoted` before this.
fn interrupts(body: []const u8) bool {
    if (rule(body) or listMarker(body) > 0) return true;
    var heading: usize = 0;
    while (heading < body.len and body[heading] == '#') heading += 1;
    return heading > 0 and heading <= 6 and (heading == body.len or body[heading] == ' ');
}

/// A list item's task mark: `[ ]` open, `[x]` or `[X]` done, then a space.
fn taskMark(item: []const u8) ?bool {
    if (item.len < 4 or item[0] != '[' or item[2] != ']' or (item[3] != ' ' and item[3] != '\t')) return null;
    return switch (item[1]) {
        ' ', '\t' => false,
        'x', 'X' => true,
        else => null,
    };
}

fn targetEnd(body: []const u8, start: usize) ?usize {
    var level: usize = 0;
    for (body[start..], start..) |ch, i| {
        if (ch == '(') level += 1;
        if (ch == ')') {
            if (level == 0) return i;
            level -= 1;
        }
    }
    return null;
}
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
fn rule(body: []const u8) bool {
    if (body.len == 0 or std.mem.findScalar(u8, "-*_", body[0]) == null) return false;
    var count: usize = 0;
    for (body) |ch| {
        if (ch == body[0]) count += 1 else if (ch != ' ') return false;
    }
    return count >= 3;
}
fn listMarker(body: []const u8) usize {
    if (body.len >= 2 and std.mem.findScalar(u8, "-+*", body[0]) != null and body[1] == ' ') return 2;
    var n: usize = 0;
    while (n < body.len and n < 9 and std.ascii.isDigit(body[n])) n += 1;
    if (n > 0 and n + 1 < body.len and (body[n] == '.' or body[n] == ')') and body[n + 1] == ' ') return n + 2;
    return 0;
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

fn wordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}
fn delimiterEnd(body: []const u8, start: usize, count: usize, ch: u8) ?usize {
    if (ch == '_' and start > 0 and start + count < body.len and wordByte(body[start - 1]) and wordByte(body[start + count])) return null;
    var i = start + count;
    while (i < body.len) {
        if (ch != '`' and body[i] == '\\' and i + 1 < body.len) {
            i += 2;
            continue;
        }
        if (body[i] != ch) {
            i += 1;
            continue;
        }
        var run: usize = 1;
        while (i + run < body.len and body[i + run] == ch) run += 1;
        if (ch == '`') {
            if (run == count) return i;
        } else if (run == count or run > count and run % 2 != 0) {
            const end = i + run - count;
            if (!(ch == '_' and end > 0 and end + count < body.len and wordByte(body[end - 1]) and wordByte(body[end + count]))) return end;
        }
        i += run;
    }
    return null;
}
