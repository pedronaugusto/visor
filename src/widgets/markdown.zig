//! Markdown rendered to width, with a theme supplied by the caller.
//! A Document owns parsing; rowCount and draw share the same row iterator.
const std = @import("std");
const visor = @import("visor");
const reader = @import("markdown_reader.zig");
const Paragraph = @import("paragraph.zig").Paragraph;

pub const Markdown = struct {
    pub const Document = reader.Document;
    /// Neutral by default. Inline roles overlay the block style: set colours
    /// replace colours; enabled attributes add to the containing style.
    pub const Theme = struct {
        prose: visor.Style = .{},
        quote: visor.Style = .{},
        code: visor.Style = .{},
        heading: [6]visor.Style = @splat(.{}),
        strong: visor.Style = .{},
        emphasis: visor.Style = .{},
        inline_code: visor.Style = .{},
        link: visor.Style = .{},
        list: visor.Style = .{},
        rule: visor.Style = .{},
    };
    document: *const Document,
    theme: Theme,
    scroll: usize = 0,
    /// Horizontal scrolling applies only to verbatim code rows.
    scroll_columns: u16 = 0,

    /// Count visual rows without allocation, using the screen's width method.
    pub fn rowCount(m: Markdown, cols: u16, method: visor.Method) usize {
        var rows = Rows.init(m.document, cols, method);
        var total: usize = 0;
        while (rows.next()) |_| total += 1;
        return total;
    }

    /// Draw visible rows. Links are interned in the destination Screen;
    /// unsafe targets remain text. No parser or layout allocations occur.
    pub fn draw(m: Markdown, win: visor.Window) !void {
        if (win.rect.isEmpty()) return;
        var rows = Rows.init(m.document, win.cols(), win.screen.method);
        var skipped: usize = 0;
        while (skipped < m.scroll) : (skipped += 1) _ = rows.next() orelse return;
        var y: u16 = 0;
        while (y < win.rows()) : (y += 1) {
            const row = rows.next() orelse return;
            const block = m.document.blocks.items[row.block];
            var bar: u32 = 0;
            while (bar < block.depth and bar * 2 < win.cols()) : (bar += 1) try win.write(@intCast(bar * 2), y, "│", m.theme.quote, .none);
            const prefix: u16 = @intCast(@min(@as(u32, block.depth) * 2 + block.indent, win.cols()));
            const style = switch (block.kind) {
                .code => m.theme.code,
                .heading => m.theme.heading[block.heading - 1],
                .rule => m.theme.rule,
                else => m.theme.prose,
            };
            if (block.kind == .rule) {
                var x = prefix;
                while (x < win.cols()) : (x += 1) try win.write(x, y, "─", style, .none);
                continue;
            }
            if (row.first and block.marker.len > 0) _ = try win.printSegment(.{ .text = block.marker, .style = m.theme.list }, .{ .col = prefix, .row = y, .wrap = .none });
            var x: u32 = @min(@as(u32, prefix) + block.marker.len, win.cols());
            const text = m.document.text.items[row.start..row.end];
            var it: visor.Graphemes = .init(text);
            const spans = m.document.spans.items[block.first_span..block.end_span];
            var low: usize = 0;
            var high = spans.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (spans[middle].end <= row.start) low = middle + 1 else high = middle;
            }
            var span_index = low;
            var skipped_columns: u32 = 0;
            var code_column: u32 = 0;
            while (it.nextAt()) |g| {
                const tab = block.kind == .code and std.mem.eql(u8, g.bytes, "\t");
                const w: u32 = if (tab) 4 - code_column % 4 else visor.graphemeWidth(g.bytes, win.screen.method);
                code_column += w;
                if (block.kind == .code and skipped_columns < m.scroll_columns) {
                    skipped_columns += w;
                    continue;
                }
                if (x + w > win.cols()) break;
                var ink = style;
                var link: visor.Link = .none;
                const at = row.start + g.start;
                while (span_index < spans.len and spans[span_index].end <= at) span_index += 1;
                if (span_index < spans.len) {
                    const span = spans[span_index];
                    if (span.flags.strong) ink = overlay(ink, m.theme.strong);
                    if (span.flags.emphasis) ink = overlay(ink, m.theme.emphasis);
                    if (span.flags.code) ink = overlay(ink, m.theme.inline_code);
                    if (span.uri.len > 0) {
                        ink = overlay(ink, m.theme.link);
                        link = win.screen.link(span.uri, "") catch |err| switch (err) {
                            error.ControlInText => .none,
                            else => return err,
                        };
                    }
                }
                if (tab) {
                    for (0..w) |offset| try win.write(@intCast(x + offset), y, " ", ink, .none);
                } else try win.write(@intCast(x), y, g.bytes, ink, link);
                x += w;
            }
        }
    }
};

const Row = struct { block: usize, start: usize, end: usize, first: bool };
const Rows = struct {
    document: *const reader.Document,
    cols: u16,
    method: visor.Method,
    block: usize = 0,
    prose: ?Paragraph.Rows = null,
    first: bool = true,

    fn init(document: *const reader.Document, cols: u16, method: visor.Method) Rows {
        return .{ .document = document, .cols = cols, .method = method };
    }
    fn next(it: *Rows) ?Row {
        if (it.cols == 0) return null;
        while (it.block < it.document.blocks.items.len) {
            const b = it.document.blocks.items[it.block];
            const prefix = @as(u64, b.depth) * 2 + b.indent + b.marker.len;
            if (b.kind != .prose and b.kind != .heading or prefix >= it.cols) {
                const r: Row = .{ .block = it.block, .start = b.start, .end = b.end, .first = true };
                it.block += 1;
                return r;
            }
            if (it.prose == null) {
                it.prose = .init(it.document.text.items[b.start..b.end], @intCast(it.cols - prefix), .word, it.method);
                it.first = true;
            }
            if (it.prose.?.next()) |r| {
                const out: Row = .{ .block = it.block, .start = b.start + r.start, .end = b.start + r.end, .first = it.first };
                it.first = false;
                return out;
            }
            it.prose = null;
            it.block += 1;
        }
        return null;
    }
};

fn overlay(base: visor.Style, role: visor.Style) visor.Style {
    var out = base;
    inline for (@typeInfo(visor.Style).@"struct".fields) |field| {
        const value = @field(role, field.name);
        if (comptime field.type == bool) {
            @field(out, field.name) = @field(base, field.name) or value;
        } else if (comptime field.type == visor.Color) {
            if (!value.eql(.default)) @field(out, field.name) = value;
        } else {
            if (value != @field(@as(visor.Style, .{}), field.name)) @field(out, field.name) = value;
        }
    }
    return out;
}
