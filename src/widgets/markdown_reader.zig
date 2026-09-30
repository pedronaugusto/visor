//! A small Markdown reader. Owns source and rendered runs; no screen or style.
const std = @import("std");

pub const Flags = packed struct(u3) { strong: bool = false, emphasis: bool = false, code: bool = false };
pub const Span = struct { start: usize, end: usize, flags: Flags, uri: []const u8 = "" };
pub const Fence = struct { char: u8, count: usize, info: []const u8 };
pub const Block = struct {
    /// Opening fence, or null for prose and indented code.
    fence: ?Fence = null,
    kind: enum { prose, code, heading, rule, blank },
    depth: u16 = 0,
    indent: u16 = 0,
    marker: []const u8 = "",
    heading: u3 = 0,
    start: usize = 0,
    end: usize = 0,
    first_span: usize = 0,
    end_span: usize = 0,
};

/// Parsed Markdown, independent of width, theme and screen. Owns all bytes.
/// Do not copy an initialized Document; deinit it once after its widgets.
pub const Document = struct {
    pub const Block = @import("markdown_reader.zig").Block;
    pub const Span = @import("markdown_reader.zig").Span;
    pub const Fence = @import("markdown_reader.zig").Fence;
    _allocator: std.mem.Allocator,
    _source: []u8,
    _text: std.ArrayList(u8) = .empty,
    _spans: std.ArrayList(Document.Span) = .empty,
    _blocks: std.ArrayList(Document.Block) = .empty,

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
        var lines = std.mem.splitScalar(u8, d._source, '\n');
        var fenced: ?struct { char: u8, count: usize, depth: u16, indent: u16, info: []const u8 } = null;
        var may_join = false;
        while (lines.next()) |raw| {
            if (raw.len == 0 and lines.peek() == null) break;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const q = quote(line);
            if (fenced) |f| {
                const body = stripQuote(line, f.depth);
                const trimmed = std.mem.trimStart(u8, body, " ");
                const closing = fence(trimmed);
                if (q.depth == f.depth and closing != null and closing.?.char == f.char and closing.?.count >= f.count and std.mem.trim(u8, trimmed[closing.?.count..], " \t").len == 0) {
                    fenced = null;
                } else {
                    try d.block(.{ .kind = .code, .depth = f.depth, .indent = f.indent, .fence = .{ .char = f.char, .count = f.count, .info = f.info } }, body, true);
                }
                may_join = false;
                continue;
            }
            var body = q.rest;
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
            if (fence(body)) |f| {
                if (indent <= 3) {
                    fenced = .{ .char = f.char, .count = f.count, .depth = q.depth, .indent = 0, .info = std.mem.trim(u8, body[f.count..], " \t") };
                    may_join = false;
                    continue;
                }
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
                try d.block(.{ .kind = .prose, .depth = q.depth, .indent = @intCast(@min(indent, std.math.maxInt(u16))), .marker = body[0..marker] }, std.mem.trimStart(u8, body[marker..], " "), false);
                may_join = true;
                continue;
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
