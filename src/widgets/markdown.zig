//! Markdown rendered to width, with a theme supplied by the caller.
//! A Document owns parsing; rowCount and draw share the same row iterator.
const std = @import("std");
const visor = @import("visor");
const reader = @import("markdown/reader.zig");
const Paragraph = @import("paragraph.zig").Paragraph;
const layout = @import("layout.zig");

pub const Markdown = struct {
    pub const Document = reader.Document;
    /// A source's lines one at a time, quotation off and fence known, by the
    /// reader's own rules.
    pub const Quoted = reader.Quoted;
    /// Allocation-free visual rows shared by rowCount and draw.
    pub const Rows = RowIterator;
    pub const Row = VisualRow;
    /// Where a table row is in its table.
    pub const TableLine = VisualTableLine;
    /// How many of a table's columns are drawn; the rest are not.
    pub const table_columns = 64;
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
        /// A task's mark, `[ ]`, and a done task's, `[x]`.
        task: visor.Style = .{},
        task_done: visor.Style = .{},
        /// A table's header cells, over the prose style.
        table_header: visor.Style = .{},
        /// The lines between a table's columns and under its header.
        table_border: visor.Style = .{},
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

    /// Draw visible rows. Links are interned in the destination Screen,
    /// once a span; a target with a control in it or longer than a link
    /// holds (65535 bytes) remains text. No parser or layout allocations occur.
    pub fn draw(m: Markdown, win: visor.Window) visor.DrawError!void {
        if (win.rect().isEmpty()) return;
        var rows = Rows.init(m.document, win.cols(), win.screen().method);
        var skipped: usize = 0;
        while (skipped < m.scroll) : (skipped += 1) _ = rows.next() orelse return;
        var y: u16 = 0;
        while (y < win.rows()) : (y += 1) {
            const row = rows.next() orelse return;
            const block = row.block;
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
            if (row.table) |line| {
                try m.drawTableLine(win, y, prefix, row, line, rows.columns());
                continue;
            }
            if (row.first and block.marker.len > 0) _ = try win.printSegment(.{ .text = block.marker, .style = m.theme.list }, .{ .col = prefix, .row = y, .wrap = .none });
            var x: u32 = @min(@as(u32, prefix) + block.marker.len, win.cols());
            if (block.task) |done| {
                if (row.first) _ = try win.printSegment(.{
                    .text = if (done) "[x]" else "[ ]",
                    .style = if (done) m.theme.task_done else m.theme.task,
                }, .{ .col = @intCast(x), .row = y, .wrap = .none });
                x = @min(x + task_width, win.cols());
            }
            _ = try m.drawText(win, x, y, win.cols(), row.text, row.start, row.spans, style, block.kind == .code);
        }
    }

    /// One row of a table: its cells' lines side by side, or the rule under
    /// the header.
    fn drawTableLine(m: Markdown, win: visor.Window, y: u16, prefix: u16, row: VisualRow, line: VisualTableLine, widths: []const u16) visor.DrawError!void {
        const table = row.block.table.?;
        const doc = m.document;
        var x: u32 = prefix;
        for (widths, 0..) |w, c| {
            if (x >= win.cols()) return;
            const last = c + 1 == widths.len;
            if (line.rule) {
                const run = @as(u32, w) + @intFromBool(!last);
                var k: u32 = 0;
                while (k < run and x + k < win.cols()) : (k += 1) try win.write(@intCast(x + k), y, "─", m.theme.table_border, .none);
                x += run;
                if (!last and x < win.cols()) try win.write(@intCast(x), y, "┼", m.theme.table_border, .none);
                x += 1;
                if (!last) {
                    if (x < win.cols()) try win.write(@intCast(x), y, "─", m.theme.table_border, .none);
                    x += 1;
                }
                continue;
            }
            const cell = doc.cells()[table.first_cell + line.row * table.columns + c];
            const text = doc.text()[cell.start..cell.end];
            if (cellLine(text, w, win.screen().method, line.line)) |part| {
                const content = text[part.start..part.end];
                const where: layout.Align = switch (doc.alignments()[table.first_align + c]) {
                    .none, .left => .left,
                    .center => .center,
                    .right => .right,
                };
                const at = x + layout.offset(w, @intCast(@min(part.columns, w)), where);
                const base = if (line.row == 0) overlay(m.theme.prose, m.theme.table_header) else m.theme.prose;
                const limit: u32 = @min(x + w, win.cols());
                _ = try m.drawText(win, at, y, limit, content, cell.start + part.start, doc.spans()[cell.first_span..cell.end_span], base, false);
            }
            x += w;
            if (!last) {
                x += 1;
                if (x < win.cols()) try win.write(@intCast(x), y, "│", m.theme.table_border, .none);
                x += 2;
            }
        }
    }

    /// Clusters of `text`, which starts at `start` in the document's text,
    /// from column `x` up to `limit`, styled by the spans over them. Code
    /// draws tabs to four-column stops and scrolls by `scroll_columns`.
    fn drawText(m: Markdown, win: visor.Window, x0: u32, y: u16, limit: u32, text: []const u8, start: usize, spans: []const reader.Span, style: visor.Style, code: bool) visor.DrawError!u32 {
        var x = x0;
        var it: visor.Graphemes = .init(text);
        var low: usize = 0;
        var high = spans.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (spans[middle].end <= start) low = middle + 1 else high = middle;
        }
        var span_index = low;
        // The link of the span last linked, interned once for all its clusters.
        var linked: ?usize = null;
        var span_link: visor.Link = .none;
        var skipped_columns: u32 = 0;
        var code_column: u32 = 0;
        while (it.nextAt()) |g| {
            const tab = code and std.mem.eql(u8, g.bytes, "\t");
            const w: u32 = if (tab) 4 - code_column % 4 else visor.graphemeWidth(g.bytes, win.screen().method);
            code_column += w;
            if (code and skipped_columns < m.scroll_columns) {
                skipped_columns += w;
                continue;
            }
            if (x + w > limit) break;
            var ink = style;
            var link: visor.Link = .none;
            const at = start + g.start;
            while (span_index < spans.len and spans[span_index].end <= at) span_index += 1;
            if (span_index < spans.len) {
                const span = spans[span_index];
                if (span.flags.strong) ink = overlay(ink, m.theme.strong);
                if (span.flags.emphasis) ink = overlay(ink, m.theme.emphasis);
                if (span.flags.code) ink = overlay(ink, m.theme.inline_code);
                if (span.uri.len > 0) {
                    ink = overlay(ink, m.theme.link);
                    if (linked != span_index) {
                        linked = span_index;
                        span_link = win.screen().link(span.uri, "") catch |err| switch (err) {
                            error.ControlInText, error.TooLong => .none,
                            error.OutOfMemory => return error.OutOfMemory,
                        };
                    }
                    link = span_link;
                }
            }
            if (tab) {
                for (0..w) |offset| try win.write(@intCast(x + offset), y, " ", ink, .none);
            } else try win.write(@intCast(x), y, g.bytes, ink, link);
            x += w;
        }
        return x;
    }
};

/// Columns a task's mark and the space after it take.
const task_width = 4;

/// The `line`th row of a cell's text wrapped at `cols`, or null past its
/// last.
fn cellLine(text: []const u8, cols: u16, method: visor.Method, line: usize) ?visor.Row {
    if (cols == 0) return null;
    var rows: Paragraph.Rows = .init(text, cols, .word, method);
    var n: usize = 0;
    while (rows.next()) |r| : (n += 1) {
        if (n == line) return r;
    }
    return null;
}

/// How many rows a cell's text takes wrapped at `cols`: one at least.
fn cellHeight(text: []const u8, cols: u16, method: visor.Method) usize {
    if (cols == 0) return 1;
    var rows: Paragraph.Rows = .init(text, cols, .word, method);
    var n: usize = 0;
    while (rows.next()) |_| n += 1;
    return @max(n, 1);
}

/// Which line of which row of a table a visual row is.
const VisualTableLine = struct {
    /// Which row of the table: zero is the header.
    row: usize,
    /// Which line of that row's wrapped cells.
    line: usize,
    /// Whether this is the rule under the header rather than cells.
    rule: bool = false,
};

/// Ranges index Document.text(); bytes, spans and fence metadata borrow the
/// Document until deinit. Spans overlap this row and retain document ranges.
pub const VisualRow = struct {
    block_index: usize,
    block: reader.Block,
    start: usize,
    end: usize,
    first: bool,
    text: []const u8,
    spans: []const reader.Span,
    /// For a row of a table, which line of which of its rows; the columns'
    /// widths are `Rows.columns()`.
    table: ?VisualTableLine = null,
};

pub const RowIterator = struct {
    /// Private: the document the rows come from.
    document: *const reader.Document,
    /// Private: the width the rows are wrapped to.
    cols: u16,
    /// Private: the width method clusters are measured by.
    method: visor.Method,
    /// Private: the block the next row comes from.
    block: usize = 0,
    /// Private: the rows of the paragraph being wrapped.
    prose: ?Paragraph.Rows = null,
    /// Private: whether the next row is its block's first.
    first: bool = true,
    /// Private: the table being laid out, its column widths and where it is.
    table: ?TableState = null,

    const TableState = struct {
        block: usize,
        widths: [Markdown.table_columns]u16,
        shown: u16,
        row: usize = 0,
        line: usize = 0,
        height: usize = 1,
        rule: bool = false,
    };

    pub fn init(document: *const reader.Document, cols: u16, method: visor.Method) RowIterator {
        return .{ .document = document, .cols = cols, .method = method };
    }

    /// The widths of the columns of the table the last row belongs to,
    /// borrowed until the next call to `next`. Empty outside a table.
    pub fn columns(it: *const RowIterator) []const u16 {
        const t = &(it.table orelse return &.{});
        return t.widths[0..t.shown];
    }

    /// Each column as wide as its widest cell, when they fit beside each
    /// other; otherwise the room shared out, the narrow columns keeping
    /// their width and the rest splitting what is left, and their cells
    /// wrapped.
    fn tableWidths(it: *const RowIterator, b: reader.Block, prefix: u64) TableState {
        const table = b.table.?;
        const doc = it.document;
        var state: TableState = .{ .block = it.block, .widths = undefined, .shown = @min(table.columns, Markdown.table_columns) };
        const shown = state.shown;
        var natural: [Markdown.table_columns]u32 = @splat(1);
        for (0..table.rows) |r| for (0..shown) |c| {
            const cell = doc.cells()[table.first_cell + r * table.columns + c];
            natural[c] = @max(natural[c], visor.width(doc.text()[cell.start..cell.end], it.method));
        };
        const separators = 3 * @as(u64, shown -| 1);
        const room: u64 = @as(u64, it.cols) -| prefix -| separators;
        var total: u64 = 0;
        for (natural[0..shown]) |n| total += n;
        if (total <= room) {
            for (natural[0..shown], state.widths[0..shown]) |n, *w| w.* = @intCast(n);
            return state;
        }
        var fixed: [Markdown.table_columns]bool = @splat(false);
        var left: u64 = room;
        var open: u64 = shown;
        while (true) {
            const share = if (open == 0) 0 else left / open;
            var changed = false;
            for (0..shown) |c| if (!fixed[c] and natural[c] <= share) {
                fixed[c] = true;
                state.widths[c] = @intCast(natural[c]);
                left -= natural[c];
                open -= 1;
                changed = true;
            };
            if (!changed) break;
        }
        if (open > 0) {
            const share = left / open;
            var extra = left % open;
            for (0..shown) |c| if (!fixed[c]) {
                state.widths[c] = @intCast(@max(1, share + @intFromBool(extra > 0)));
                extra -|= 1;
            };
        }
        return state;
    }

    /// How many lines a table row takes: its tallest cell's.
    fn rowHeight(it: *const RowIterator, b: reader.Block, state: *const TableState, r: usize) usize {
        const table = b.table.?;
        const doc = it.document;
        var tallest: usize = 1;
        for (0..state.shown) |c| {
            const cell = doc.cells()[table.first_cell + r * table.columns + c];
            tallest = @max(tallest, cellHeight(doc.text()[cell.start..cell.end], state.widths[c], it.method));
        }
        return tallest;
    }

    fn tableRow(it: *RowIterator, b: reader.Block, prefix: u64) VisualRow {
        if (it.table == null) {
            it.table = it.tableWidths(b, prefix);
            it.table.?.height = it.rowHeight(b, &it.table.?, 0);
        }
        const state = &it.table.?;
        const table = b.table.?;
        const first = it.document.cells()[table.first_cell + state.row * table.columns];
        const last = it.document.cells()[table.first_cell + state.row * table.columns + table.columns - 1];
        var out = it.row(b, first.start, last.end, state.row == 0 and state.line == 0 and !state.rule);
        out.table = .{ .row = state.row, .line = state.line, .rule = state.rule };
        // Advance: the header's lines, the rule, then each row's lines.
        if (state.rule) {
            state.rule = false;
            state.row = 1;
        } else {
            state.line += 1;
            if (state.line < state.height) return out;
            state.line = 0;
            if (state.row == 0) {
                state.rule = true;
                return out;
            }
            state.row += 1;
        }
        if (state.row < table.rows) {
            state.height = it.rowHeight(b, state, state.row);
            return out;
        }
        it.block += 1;
        return out;
    }
    fn row(it: *const RowIterator, b: reader.Block, start: usize, end: usize, first: bool) VisualRow {
        const spans = it.document.spans()[b.first_span..b.end_span];
        var low: usize = 0;
        var high = spans.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (spans[middle].end <= start) low = middle + 1 else high = middle;
        }
        const begin = low;
        high = spans.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (spans[middle].start < end) low = middle + 1 else high = middle;
        }
        return .{ .block_index = it.block, .block = b, .start = start, .end = end, .first = first, .text = it.document.text()[start..end], .spans = spans[begin..low] };
    }

    pub fn next(it: *RowIterator) ?VisualRow {
        if (it.cols == 0) return null;
        while (it.block < it.document.blocks().len) {
            const b = it.document.blocks()[it.block];
            // The table the last row was in is kept until a row of another
            // block, so its widths outlive its last row by one call.
            if (it.table) |t| if (t.block != it.block) {
                it.table = null;
            };
            if (b.kind == .table) return it.tableRow(b, @as(u64, b.depth) * 2);
            const prefix = @as(u64, b.depth) * 2 + b.indent + b.marker.len + @as(u64, if (b.task != null) task_width else 0);
            if (b.kind != .prose and b.kind != .heading or prefix >= it.cols) {
                const r = it.row(b, b.start, b.end, true);
                it.block += 1;
                return r;
            }
            if (it.prose == null) {
                it.prose = .init(it.document.text()[b.start..b.end], @intCast(it.cols - prefix), .word, it.method);
                it.first = true;
            }
            if (it.prose.?.next()) |r| {
                const out = it.row(b, b.start + r.start, b.start + r.end, it.first);
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
    const info = @typeInfo(visor.Style).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        const value = @field(role, name);
        if (comptime Field == bool) {
            @field(out, name) = @field(base, name) or value;
        } else if (comptime Field == visor.Color) {
            if (!value.eql(.default)) @field(out, name) = value;
        } else {
            if (value != @field(@as(visor.Style, .{}), name)) @field(out, name) = value;
        }
    }
    return out;
}
