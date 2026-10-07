//! Correctness of the operation workloads, untimed.
//!
//! Each workload prints canonical evidence (`grid`: rows as text, covered
//! columns skipped; `value`, `text`, `rects`; `wire`: frame bytes). Where a
//! layout is visor's own choice (solver, glyph choice, alignment) a stated
//! invariant holds instead of a fixed answer. Frame bytes are replayed by the
//! decoder and must rebuild the workload's own grid.

const std = @import("std");
const terminal = @import("terminal.zig");
const pictures = @import("pictures.zig");
const unicode = @import("unicode.zig");
const Terminal = terminal.Terminal;
const Allocator = std.mem.Allocator;
const json = std.json;

/// Workloads whose output is checked against a stated invariant.
const checked_by_invariant = [_][]const u8{
    "paragraph", "table",        "gauge",     "line_gauge", "sparkline", "chart",     "canvas",
    "calendar",  "layout_split", "text_wrap", "modes",      "barchart",  "scrollbar",
};

fn among(name: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// A workload's evidence lines, by tag, in the order printed.
pub const Evidence = struct {
    tags: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty,

    pub fn parse(a: Allocator, lines: []const []const u8) !Evidence {
        var ev: Evidence = .{};
        for (lines) |line| {
            const tab = std.mem.findScalar(u8, line, '\t');
            const tag = if (tab) |t| line[0..t] else line;
            const value = if (tab) |t| line[t + 1 ..] else "";
            const entry = try ev.tags.getOrPut(a, tag);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, value);
        }
        return ev;
    }

    pub fn get(ev: *const Evidence, tag: []const u8) ?[]const []const u8 {
        return if (ev.tags.get(tag)) |list| list.items else null;
    }

    pub fn need(ev: *const Evidence, tag: []const u8) ![]const []const u8 {
        const list = ev.get(tag) orelse return error.MissingEvidence;
        if (list.len == 0) return error.MissingEvidence;
        return list;
    }

    pub fn last(ev: *const Evidence, tag: []const u8) ![]const u8 {
        const list = try ev.need(tag);
        return list[list.len - 1];
    }

    fn set(ev: *Evidence, a: Allocator, tag: []const u8, value: []const u8) !void {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(a, value);
        try ev.tags.put(a, tag, list);
    }
};

fn textOf(a: Allocator, hexed: []const u8) ![]u8 {
    const bytes = try terminal.unhex(a, hexed);
    _ = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    return bytes;
}

fn grid(a: Allocator, ev: *const Evidence) ![]u8 {
    return textOf(a, try ev.last("grid"));
}

fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, l);
    return out.items;
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x1c...0x1f, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// `str.split()`: runs of whitespace separate words.
fn words(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var at: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const cp = unicode.decode(slice) catch unreachable; // unreachable: the view checked the text is UTF-8
        if (isSpace(cp)) {
            if (start) |s| try out.append(a, text[s..at]);
            start = null;
        } else if (start == null) start = at;
        at += slice.len;
    }
    if (start) |s| try out.append(a, text[s..]);
    return out.items;
}

fn check(ok: bool) !void {
    if (!ok) return error.InvariantFailed;
}

fn int(n: usize) json.Value {
    return .{ .integer = @intCast(n) };
}

/// The value after the first `=` of `key=value`, as an integer.
fn afterEquals(s: []const u8) !usize {
    var it = std.mem.splitScalar(u8, s, '=');
    _ = it.next();
    const field = it.next() orelse return error.InvariantFailed;
    return std.fmt.parseInt(usize, field, 10) catch error.InvariantFailed;
}

/// The words of `text` are the first words of `prose`.
fn wordsPrefix(a: Allocator, text: []const u8, prose: []const u8) !usize {
    const got = try words(a, text);
    const want = try words(a, prose);
    try check(got.len > 0 and got.len <= want.len);
    for (got, want[0..got.len]) |g, w| try check(std.mem.eql(u8, g, w));
    return got.len;
}

/// Numbers of `r<digits>` standing as words (`\br(\d+)\b`), in order.
fn rowIds(a: Allocator, line: []const u8, out: *std.ArrayList(usize)) !void {
    const cps = try unicode.codepoints(a, line);
    var k: usize = 0;
    while (k < cps.len) : (k += 1) {
        if (cps[k] != 'r' or (k > 0 and unicode.word(cps[k - 1]))) continue;
        var end = k + 1;
        while (end < cps.len and cps[end] >= '0' and cps[end] <= '9') end += 1;
        if (end == k + 1 or (end < cps.len and unicode.word(cps[end]))) continue;
        var n: usize = 0;
        for (cps[k + 1 .. end]) |d| n = n * 10 + (d - '0');
        try out.append(a, n);
        k = end - 1;
    }
}

const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Matches of `(January|…|December) 20\d\d`, non-overlapping.
fn monthsShown(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    outer: while (i < text.len) {
        for (months) |m| {
            const r = text[i..];
            if (std.mem.startsWith(u8, r, m) and r.len >= m.len + 5 and std.mem.eql(u8, r[m.len..][0..3], " 20") and
                std.ascii.isDigit(r[m.len + 3]) and std.ascii.isDigit(r[m.len + 4]))
            {
                count += 1;
                i += m.len + 5;
                continue :outer;
            }
        }
        i += 1;
    }
    return count;
}

const full_block: u21 = 0x2588;

/// The lengths of the runs of `█` in `track`.
fn blockRuns(a: Allocator, track: []const u21) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    var run: usize = 0;
    for (track) |cp| {
        if (cp == full_block) {
            run += 1;
        } else if (run > 0) {
            try out.append(a, run);
            run = 0;
        }
    }
    if (run > 0) try out.append(a, run);
    return out.items;
}

const Rect = [4]i64;

/// Checks a library that lays the same content out by its own rules.
fn invariant(a: Allocator, task: []const u8, ev: *const Evidence, cols: usize, rows: usize, corpus: std.Io.Dir, io: std.Io, e: *json.ObjectMap) !void {
    const is = struct {
        fn f(t: []const u8, name: []const u8) bool {
            return std.mem.eql(u8, t, name);
        }
    }.f;
    if (is(task, "paragraph")) {
        const g = try grid(a, ev);
        for (try splitLines(a, g)) |l| try check((try unicode.codepoints(a, l)).len <= cols);
        const prose = try corpus.readFileAlloc(io, "prose.txt", a, .unlimited);
        try e.put(a, "words_shown", int(try wordsPrefix(a, g, prose)));
    } else if (is(task, "table")) {
        const g = try splitLines(a, try grid(a, ev));
        const n = rows * 8;
        try check(std.mem.find(u8, g[0], "id") != null and std.mem.find(u8, g[0], "value") != null and std.mem.find(u8, g[0], "state") != null);
        var ids: std.ArrayList(usize) = .empty;
        for (g[1..]) |l| try rowIds(a, l, &ids);
        try check(ids.items.len > 0);
        for (ids.items, 0..) |id, k| try check(id == ids.items[0] + k);
        try check(ids.items[0] <= n / 2 and n / 2 <= ids.items[ids.items.len - 1]);
        try e.put(a, "rows_shown", int(ids.items.len));
    } else if (is(task, "line_gauge")) {
        const g = try splitLines(a, try grid(a, ev));
        for (g) |l| try check(std.mem.startsWith(u8, l, "disk"));
        try e.put(a, "rows", int(g.len));
    } else if (is(task, "gauge")) {
        const first = try unicode.codepoints(a, (try splitLines(a, try grid(a, ev)))[0]);
        var filled: usize = 0;
        for (first, 0..) |cp, k| if (cp >= 0x2580 and cp <= 0x259f) {
            filled = k + 1;
        };
        const want = 0.6180339887 * @as(f64, @floatFromInt(cols));
        try check(@abs(@as(f64, @floatFromInt(filled)) - want) <= 1.5);
        try e.put(a, "filled_columns", int(filled));
    } else if (is(task, "sparkline")) {
        var bars: usize = 0;
        for (try unicode.codepoints(a, try grid(a, ev))) |cp| {
            if (cp == ' ' or cp == '\n') continue;
            try check(cp >= 0x2581 and cp <= 0x2588);
            bars += 1;
        }
        try check(bars > 0);
        try e.put(a, "bar_cells", int(bars));
    } else if (is(task, "chart") or is(task, "canvas")) {
        const g = try grid(a, ev);
        var dots: usize = 0;
        for (try unicode.codepoints(a, g)) |cp| {
            if (cp >= 0x2800 and cp <= 0x28ff) dots += 1;
        }
        try check(dots > cols / 4);
        if (is(task, "chart")) try check(std.mem.find(u8, g, "100") != null and std.mem.find(u8, g, "-1") != null);
        try e.put(a, "braille_cells", int(dots));
    } else if (is(task, "calendar")) {
        const g = try grid(a, ev);
        const shown = monthsShown(g);
        try check(shown == (rows + 1) / 9 * ((cols + 2) / 22));
        try check((std.mem.find(u8, g, "28") != null) == (shown > 0));
        try e.put(a, "months", int(shown));
    } else if (is(task, "layout_split")) {
        var outer: std.ArrayList(Rect) = .empty;
        var inner: std.ArrayList(Rect) = .empty;
        var it = std.mem.splitScalar(u8, (try ev.need("rects"))[0], ';');
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            var rect: Rect = undefined;
            var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, raw, "R"), ',');
            for (&rect) |*v| v.* = std.fmt.parseInt(i64, parts.next() orelse return error.InvariantFailed, 10) catch return error.InvariantFailed;
            try check(parts.next() == null);
            try (if (raw[0] == 'R') &outer else &inner).append(a, rect);
        }
        const o = outer.items;
        try check(o.len == 6 and o[0][3] == 3);
        for (o[0 .. o.len - 1], o[1..]) |p, q| try check(q[1] == p[1] + p[3] + 1);
        try check(o[o.len - 1][1] + o[o.len - 1][3] == @as(i64, @intCast(rows)));
        for (0..6) |row| {
            const start = @min(row * 5, inner.items.len);
            const cells = inner.items[start..@min(start + 5, inner.items.len)];
            try check(cells.len > 0);
            try check(cells[0][2] == 12 and cells[0][0] == 0);
            try check(cells[cells.len - 1][0] + cells[cells.len - 1][2] == @as(i64, @intCast(cols)));
        }
        var heights: json.Array = .init(a);
        for (o) |r| try heights.append(.{ .integer = r[3] });
        try e.put(a, "outer_heights", .{ .array = heights });
    } else if (is(task, "barchart")) {
        const g = try splitLines(a, try grid(a, ev));
        const last = try words(a, g[g.len - 1]);
        for (last, 0..) |label, k| try check(std.mem.eql(u8, label, try a.print("b{d}", .{k % 100})));
        try check(last.len == cols / 4);
        try e.put(a, "bars", int(last.len));
    } else if (is(task, "scrollbar")) {
        const g = try splitLines(a, try grid(a, ev));
        var right: std.ArrayList(u21) = .empty;
        for (g[0 .. g.len - 1]) |l| {
            const cps = try unicode.codepoints(a, l);
            try right.append(a, if (cps.len >= cols) cps[cols - 1] else ' ');
        }
        const bottom = try unicode.codepoints(a, g[g.len - 1]);
        const right_runs = try blockRuns(a, right.items);
        const bottom_runs = try blockRuns(a, bottom);
        try check(right_runs.len == 1 and bottom_runs.len == 1);
        var thumbs: json.Array = .init(a);
        try thumbs.append(int(right_runs[0]));
        try thumbs.append(int(bottom_runs[0]));
        try e.put(a, "thumbs", .{ .array = thumbs });
    } else if (is(task, "resize")) {
        const area = try a.print("{d}x{d}", .{ cols, rows });
        try check(std.mem.eql(u8, try textOf(a, (try ev.need("value"))[0]), try std.mem.concat(a, u8, &.{ "area=", area })));
        try e.put(a, "area", .{ .string = area });
    } else if (is(task, "modes")) {
        const wire = try terminal.unhex(a, try ev.last("wire"));
        for ([_][]const u8{ "1049", "1004", "2004", "1006" }) |mode| {
            for ("hl") |end| {
                const seq = try a.print("\x1b[?{s}{c}", .{ mode, end });
                try check(std.mem.find(u8, wire, seq) != null);
            }
        }
        try e.put(a, "bytes", int(wire.len));
    } else if (is(task, "text_wrap")) {
        const n = try afterEquals((try ev.need("value"))[0]);
        const prose = try corpus.readFileAlloc(io, "prose.txt", a, .unlimited);
        try check(n >= (try unicode.codepoints(a, prose)).len / cols);
        try e.put(a, "rows", int(n));
    } else if (is(task, "markdown_parse")) {
        try e.put(a, "blocks", int(try afterEquals((try ev.need("info"))[0])));
    } else {
        std.log.err("no invariant for {s}", .{task});
        return error.InvariantFailed;
    }
}

const print_words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };

fn clip(s: []const u8, cols: usize) []const u8 {
    return s[0..@min(s.len, cols)];
}

/// What the terminal shows after `frames` frames of two log lines printed
/// above an inline view a quarter of it tall, worked out from the rule.
pub fn printAboveScreen(a: Allocator, cols: usize, rows: usize, frames: usize) ![]u8 {
    const view_rows = @max(2, rows / 4);
    var printed: std.ArrayList([]const u8) = .empty;
    for (0..2 * frames) |i| {
        try printed.append(a, clip(try a.print("log {d:0>6} {s} {s}", .{ i, print_words[i % 8], print_words[(i + 3) % 8] }), cols));
    }
    var screen: std.ArrayList([]const u8) = .empty;
    const room = rows - view_rows;
    // Python's printed[-room:], where a room of zero keeps them all.
    const above = if (printed.items.len > room and room > 0) printed.items[printed.items.len - room ..] else printed.items;
    try screen.appendSlice(a, above);
    try screen.append(a, clip(try a.print("working {d:0>6}", .{frames}), cols));
    for (1..view_rows) |y| {
        const hashes = try a.alloc(u8, (frames + y) % (cols + 1));
        @memset(hashes, '#');
        try screen.append(a, hashes);
    }
    while (screen.items.len < rows) try screen.append(a, "");
    var out: std.ArrayList(u8) = .empty;
    for (screen.items, 0..) |row, k| {
        if (k > 0) try out.append(a, '\n');
        try out.appendSlice(a, std.mem.trimEnd(u8, row, " "));
    }
    return out.items;
}

fn replayedBytes(wires: []const []const u8) usize {
    var n: usize = 0;
    for (wires) |w| n += w.len / 2;
    return n;
}

/// Frame bytes replayed by the decoder rebuild the side's grid.
fn ownWire(a: Allocator, task: []const u8, ev: *Evidence, cols: usize, rows: usize, corpus: std.Io.Dir, io: std.Io, e: *json.ObjectMap) !void {
    const wires = try ev.need("wire");
    var t = try Terminal.init(a, cols, rows);
    if (std.mem.eql(u8, task, "print_above")) {
        // The first frame enters and draws the view; each after prints two
        // rows above it. The decoder's screen after each is worked out from
        // the rule, and is then the side's grid for the exact comparison.
        for (wires, 0..) |w, k| {
            try t.feed(try terminal.unhex(a, w));
            try check(std.mem.eql(u8, try t.text(a), try printAboveScreen(a, cols, rows, k)));
        }
        const text = try t.text(a);
        const hexed = try a.alloc(u8, text.len * 2);
        _ = try std.mem.print(hexed, "{x}", .{text});
        try ev.set(a, "grid", hexed);
    } else if (std.mem.eql(u8, task, "scroll_repaint")) {
        const log_text = try corpus.readFileAlloc(io, "log.txt", a, .unlimited);
        const log = try splitLines(a, std.mem.trimEnd(u8, log_text, "\n"));
        for (wires, 0..) |w, k| {
            try t.feed(try terminal.unhex(a, w));
            var want: std.ArrayList(u8) = .empty;
            for (0..rows) |y| {
                if (y > 0) try want.append(a, '\n');
                try want.appendSlice(a, log[(k + y) % log.len]);
            }
            try check(std.mem.eql(u8, try t.text(a), want.items));
        }
    } else {
        for (wires) |w| try t.feed(try terminal.unhex(a, w));
    }
    if (!std.mem.eql(u8, task, "print_above")) try check(std.mem.eql(u8, try t.text(a), try grid(a, ev)));
    if (std.mem.eql(u8, task, "links")) try check(t.links.count() == rows);
    try e.put(a, "frames", int(wires.len));
    try e.put(a, "replayed_bytes", int(replayedBytes(wires)));
}

/// One operation workload at one size: its lines before its result line.
/// Returns its evidence.
pub fn verify(a: Allocator, io: std.Io, task: []const u8, cols: usize, rows: usize, corpus_root: []const u8, lines: []const []const u8) !json.ObjectMap {
    const corpus_path = try a.print("{s}/{d}x{d}", .{ corpus_root, cols, rows });
    var corpus = try std.Io.Dir.cwd().openDir(io, corpus_path, .{});
    defer corpus.close(io);
    var ev: Evidence = try .parse(a, lines);
    var e: json.ObjectMap = .empty;
    if (std.mem.startsWith(u8, task, "picture_frame_")) {
        const png = try corpus.readFileAlloc(io, "picture.png", a, .unlimited);
        return (try pictures.verify(a, task, cols, rows, &ev, png)).object;
    }
    const wired = among(task, &.{ "wide_repaint", "scroll_repaint", "links", "print_above" });
    if (wired and ev.get("wire") != null) try ownWire(a, task, &ev, cols, rows, corpus, io, &e);
    const small = cols == 8 and rows == 4;
    if (among(task, &checked_by_invariant) and !small) {
        invariant(a, task, &ev, cols, rows, corpus, io, &e) catch |err| {
            std.log.err("{s} {d}x{d}: breaks the invariant", .{ task, cols, rows });
            return err;
        };
    }
    try e.put(a, "status", .{ .string = "passed" });
    return e;
}

test "print_above screen by the rule" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("working 000000\n#\n\n\n\n\n\n", try printAboveScreen(a, 20, 8, 0));
    try std.testing.expectEqualStrings(
        "log 000000 alpha del\nlog 000001 beta epsi\nworking 000001\n##\n\n\n\n",
        try printAboveScreen(a, 20, 8, 1),
    );
}

test "invariant helpers: row ids, months, words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: std.ArrayList(usize) = .empty;
    try rowIds(a, "\u{2502}r12 x r13\u{2502} rr14 r15a", &ids);
    try std.testing.expectEqualSlices(usize, &.{ 12, 13 }, ids.items);
    try std.testing.expectEqual(@as(usize, 2), monthsShown("  March 2026   April 2026 May 19"));
    const w = try words(a, "  a b\n c ");
    try std.testing.expectEqual(@as(usize, 3), w.len);
    try std.testing.expectEqualStrings("c", w[2]);
}
