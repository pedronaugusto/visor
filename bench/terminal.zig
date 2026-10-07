//! An independent decoder for the deliberately small protocol subset the
//! benchmark programs write: ASCII and UTF-8 text, RGB/bold SGR, cursor
//! addressing, erase, scroll regions, OSC 8 links and kitty image upload and
//! placement. Anything else fails rather than being skipped.
//!
//! Also the drawing-core check (`verifyFrames`): every frame a side wrote is
//! replayed and each cell compared with the generated intent.

const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const Error = error{ Unrecognized, Mismatch, OutOfRange, InvalidUtf8 } || Allocator.Error;

pub const Rgb = [3]i64;

pub const Cell = struct {
    /// The cluster: empty for the column a wide glyph covers.
    text: []const u8 = " ",
    fg: ?Rgb = null,
    bold: bool = false,
    /// The OSC 8 target the cell was written under.
    link: ?[]const u8 = null,

    pub fn eql(a: Cell, b: Cell) bool {
        if (!std.mem.eql(u8, a.text, b.text) or a.bold != b.bold) return false;
        if ((a.fg == null) != (b.fg == null)) return false;
        if (a.fg) |fg| if (!std.mem.eql(i64, &fg, &b.fg.?)) return false;
        if ((a.link == null) != (b.link == null)) return false;
        if (a.link) |link| if (!std.mem.eql(u8, link, b.link.?)) return false;
        return true;
    }
};

pub const Placement = struct { x: i64, y: i64, cols: i64, rows: i64 };
pub const PlacementKey = struct { image: i64, placement: i64 };

/// The image whose upload a frame carries: 16x16 of one RGBA colour.
const upload_pixel = [4]u8{ 31, 63, 127, 255 };

pub const Terminal = struct {
    a: Allocator,
    cols: usize,
    rows: usize,
    x: i64 = 0,
    y: i64 = 0,
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    grid: []Cell,
    placements: std.array_hash_map.Auto(PlacementKey, Placement) = .empty,
    /// Image id to the SHA-256 of its upload, or a note.
    images: std.array_hash_map.Auto(i64, []const u8) = .empty,
    /// Graphics commands seen, counted.
    commands: usize = 0,
    upload: std.ArrayList(u8) = .empty,
    upload_id: ?i64 = null,
    saved: [2]i64 = .{ 0, 0 },
    top: i64 = 0,
    bottom: i64,
    link: ?[]const u8 = null,
    links: std.array_hash_map.String(void) = .empty,
    last: ?usize = null,

    /// `a` should be an arena: cells keep their text until it is freed.
    pub fn init(a: Allocator, cols: usize, rows: usize) !Terminal {
        const grid = try a.alloc(Cell, cols * rows);
        @memset(grid, .{});
        return .{ .a = a, .cols = cols, .rows = rows, .grid = grid, .bottom = @as(i64, @intCast(rows)) - 1 };
    }

    fn icols(t: *const Terminal) i64 {
        return @intCast(t.cols);
    }
    fn irows(t: *const Terminal) i64 {
        return @intCast(t.rows);
    }

    fn index(t: *const Terminal, x: i64, y: i64) Error!usize {
        const i = y * t.icols() + x;
        if (y < 0 or x < 0 or i >= t.grid.len) return error.OutOfRange;
        return @intCast(i);
    }

    fn scroll(t: *Terminal, n: i64) Error!void {
        if (t.top < 0 or t.bottom >= t.irows() or t.top > t.bottom) {
            if (t.top <= t.bottom) return error.OutOfRange;
            return;
        }
        const top: usize = @intCast(t.top);
        const span: usize = @intCast(t.bottom - t.top + 1);
        const region = t.grid[top * t.cols ..][0 .. span * t.cols];
        const old = try t.a.dupe(Cell, region);
        const shift: usize = @intCast(@min(@abs(n), span));
        @memset(region, .{});
        if (n > 0) {
            @memcpy(region[0 .. (span - shift) * t.cols], old[shift * t.cols ..]);
        } else {
            @memcpy(region[shift * t.cols ..], old[0 .. (span - shift) * t.cols]);
        }
    }

    /// A line feed at the bottom margin scrolls the region, as a terminal does.
    fn linefeed(t: *Terminal) Error!void {
        if (t.y == t.bottom) try t.scroll(1) else t.y += 1;
    }

    /// Auto-margin with a pending wrap (am, xenl): a glyph that does not fit
    /// starts the next line.
    fn autowrap(t: *Terminal, width: i64) Error!void {
        if (t.x + width > t.icols()) {
            t.x = 0;
            try t.linefeed();
        }
    }

    fn put(t: *Terminal, x: i64, y: i64, cluster: []const u8) Error!void {
        const i = try t.index(x, y);
        t.grid[i] = .{ .text = cluster, .fg = t.fg, .bold = t.bold, .link = t.link };
        if (cluster.len > 0) t.last = i;
    }

    fn blank(t: *Terminal, i: usize) void {
        t.grid[i] = .{ .text = " ", .fg = t.fg, .bold = t.bold };
    }

    /// Rows as text, each right-trimmed of spaces, joined by newlines.
    pub fn text(t: *const Terminal, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..t.rows) |y| {
            if (y > 0) try out.append(a, '\n');
            const start = out.items.len;
            for (t.grid[y * t.cols ..][0..t.cols]) |c| try out.appendSlice(a, c.text);
            out.shrinkRetainingCapacity(start + std.mem.trimEnd(u8, out.items[start..], " ").len);
        }
        return out.items;
    }

    pub fn feed(t: *Terminal, data: []const u8) Error!void {
        var i: usize = 0;
        while (i < data.len) {
            const rest = data[i..];
            if (std.mem.startsWith(u8, rest, "\x1b_G")) {
                const end = std.mem.findPos(u8, data, i + 3, "\x1b\\") orelse return error.Unrecognized;
                try t.graphics(data[i + 3 .. end]);
                i = end + 2;
            } else if (std.mem.startsWith(u8, rest, "\x1b]")) {
                // OSC 8 hyperlinks only; anything else fails.
                const st = std.mem.findPos(u8, data, i, "\x1b\\");
                const bel = std.mem.findScalarPos(u8, data, i, 0x07);
                const end = if (st != null and bel != null) @min(st.?, bel.?) else st orelse bel orelse return error.Unrecognized;
                const body = data[i + 2 .. end];
                _ = std.unicode.Utf8View.init(body) catch return error.InvalidUtf8;
                if (!std.mem.startsWith(u8, body, "8;")) return error.Unrecognized;
                const sep = std.mem.findScalarPos(u8, body, 2, ';') orelse return error.Unrecognized;
                const uri = body[sep + 1 ..];
                t.link = if (uri.len == 0) null else try t.a.dupe(u8, uri);
                if (t.link) |link| try t.links.put(t.a, link, {});
                i = end + @as(usize, if (data[end] == 0x1b) 2 else 1);
            } else if (std.mem.startsWith(u8, rest, "\x1b7")) {
                t.saved = .{ t.x, t.y };
                i += 2;
            } else if (std.mem.startsWith(u8, rest, "\x1b8")) {
                t.x, t.y = t.saved;
                i += 2;
            } else if (std.mem.startsWith(u8, rest, "\x1b[")) {
                var j: usize = 2;
                while (j < rest.len and std.mem.findScalar(u8, "0123456789;:?>", rest[j]) != null) j += 1;
                if (j >= rest.len or !std.ascii.isAlphabetic(rest[j])) return error.Unrecognized;
                try t.csi(rest[2..j], rest[j]);
                i += j + 1;
            } else if (data[i] == '\r') {
                t.x = 0;
                i += 1;
            } else if (data[i] == '\n') {
                try t.linefeed();
                i += 1;
            } else if (data[i] >= 32 and data[i] <= 126) {
                try t.autowrap(1);
                if (t.x < 0 or t.x >= t.icols() or t.y < 0 or t.y >= t.irows()) return error.OutOfRange;
                if (t.bg != null) return error.Unrecognized;
                try t.put(t.x, t.y, ascii_text[data[i] - 32 ..][0..1]);
                t.x += 1;
                i += 1;
            } else if (data[i] >= 0xc0) {
                // One UTF-8 codepoint: a mark joins the cluster before it,
                // East Asian Wide/Fullwidth takes two columns.
                const size: usize = if (data[i] < 0xe0) 2 else if (data[i] < 0xf0) 3 else 4;
                if (i + size > data.len) return error.InvalidUtf8;
                const bytes = data[i..][0..size];
                const cp = unicode.decode(bytes) catch return error.InvalidUtf8;
                i += size;
                if (unicode.mark(cp) or unicode.format(cp) or (cp >= 0x1F3FB and cp <= 0x1F3FF) or cp == 0xFE0E or cp == 0xFE0F) {
                    const last = t.last orelse return error.Unrecognized;
                    t.grid[last].text = try std.mem.concat(t.a, u8, &.{ t.grid[last].text, bytes });
                    continue;
                }
                const wide: i64 = @intFromBool(unicode.wide(cp));
                try t.autowrap(1 + wide);
                if (t.x < 0 or t.x + wide >= t.icols() or t.y < 0 or t.y >= t.irows()) return error.OutOfRange;
                try t.put(t.x, t.y, try t.a.dupe(u8, bytes));
                if (wide == 1) try t.put(t.x + 1, t.y, "");
                t.x += 1 + wide;
            } else {
                return error.Unrecognized;
            }
        }
    }

    const ascii_text = blk: {
        var chars: [95]u8 = undefined;
        for (&chars, 0..) |*c, k| c.* = 32 + k;
        const final = chars;
        break :blk &final;
    };

    fn graphics(t: *Terminal, body: []const u8) Error!void {
        const semi = std.mem.findScalar(u8, body, ';');
        const keys = if (semi) |s| body[0..s] else body;
        const payload = if (semi) |s| body[s + 1 ..] else "";
        var fields: std.array_hash_map.String([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, keys, ',');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.findScalar(u8, part, '=') orelse return error.Unrecognized;
            try fields.put(t.a, part[0..eq], part[eq + 1 ..]);
        }
        t.commands += 1;
        const action = fields.get("a") orelse "t";
        if (std.mem.eql(u8, action, "p")) {
            if (try int(fields.get("C") orelse "0") != 1) return error.Mismatch;
            const image = try int(fields.get("i") orelse return error.Unrecognized);
            const placement = try int(fields.get("p") orelse "1");
            if (!t.images.contains(image)) return error.Mismatch;
            try t.placements.put(t.a, .{ .image = image, .placement = placement }, .{
                .x = t.x,
                .y = t.y,
                .cols = try int(fields.get("c") orelse "0"),
                .rows = try int(fields.get("r") orelse "0"),
            });
        } else if (std.mem.eql(u8, action, "t")) {
            if (fields.get("i")) |id| t.upload_id = try int(id);
            try t.upload.appendSlice(t.a, try base64(t.a, payload));
            if (std.mem.eql(u8, fields.get("m") orelse "0", "0")) {
                if (t.upload_id != 7) return error.Mismatch;
                if (t.upload.items.len != 4 * 256) return error.Mismatch;
                var k: usize = 0;
                while (k < t.upload.items.len) : (k += 4) {
                    if (!std.mem.eql(u8, t.upload.items[k..][0..4], &upload_pixel)) return error.Mismatch;
                }
                var sum: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(t.upload.items, &sum, .{});
                try t.images.put(t.a, 7, try t.a.dupe(u8, &std.fmt.bytesToHex(sum, .lower)));
                t.upload.clearRetainingCapacity();
            }
        } else {
            return error.Unrecognized;
        }
    }

    fn csi(t: *Terminal, params: []const u8, final: u8) Error!void {
        if (params.len > 0 and (params[0] == '?' or params[0] == '>')) {
            if (final != 'h' and final != 'l' and final != 'u') return error.Unrecognized;
            return;
        }
        // `38:2::r:g:b` and `38:2:0:r:g:b` read as `38;2;r;g;b`.
        var raw: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < params.len) {
            const p = params[k..];
            if ((std.mem.startsWith(u8, p, "38:2:") or std.mem.startsWith(u8, p, "48:2:"))) {
                const skip: ?usize = if (p.len > 5 and p[5] == ':') 6 else if (p.len > 6 and p[5] == '0' and p[6] == ':') 7 else null;
                if (skip) |s| {
                    try raw.appendSlice(t.a, p[0..2]);
                    try raw.appendSlice(t.a, ";2;");
                    k += s;
                    continue;
                }
            }
            try raw.append(t.a, params[k]);
            k += 1;
        }
        var nums: std.ArrayList(i64) = .empty;
        if (raw.items.len == 0) {
            try nums.append(t.a, 0);
        } else {
            var fields = std.mem.splitAny(u8, raw.items, ";:");
            while (fields.next()) |f| try nums.append(t.a, if (f.len == 0) 0 else try int(f));
        }
        const v = nums.items;
        const n: i64 = if (v[0] != 0) v[0] else 1;
        const cols = t.icols();
        const rows = t.irows();
        switch (final) {
            'H', 'f' => {
                // Terminals clamp an absolute position to the screen.
                t.y = @min(rows, if (v[0] != 0) v[0] else 1) - 1;
                t.x = @min(cols, if (v.len > 1 and v[1] != 0) v[1] else 1) - 1;
            },
            'G' => t.x = @min(cols, n) - 1,
            'E' => {
                t.x = 0;
                t.y = @min(rows - 1, t.y + n);
            },
            'F' => {
                t.x = 0;
                t.y = @max(0, t.y - n);
            },
            'd' => t.y = @min(rows, n) - 1,
            'A' => t.y = @max(0, t.y - n),
            'B' => t.y = @min(rows - 1, t.y + n),
            'C' => t.x = @min(cols - 1, t.x + n),
            'D' => t.x = @max(0, t.x - n),
            'm' => try t.sgr(v),
            'J' => {
                if (v[0] != 0 and v[0] != 2) return error.Unrecognized;
                const start: i64 = if (v[0] == 2) 0 else t.y * cols + t.x;
                var at: usize = @intCast(@max(0, start));
                while (at < t.grid.len) : (at += 1) t.blank(at);
            },
            'K' => {
                const end: i64 = if (v[0] == 0) cols else if (v[0] == 1) t.x + 1 else cols;
                var x: i64 = if (v[0] == 0) t.x else 0;
                while (x < end) : (x += 1) t.blank(try t.index(x, t.y));
            },
            'X' => {
                var x = t.x;
                while (x < @min(cols, t.x + n)) : (x += 1) try t.put(x, t.y, " ");
            },
            'r' => {
                t.top = (if (v[0] != 0) v[0] else 1) - 1;
                t.bottom = (if (v.len > 1 and v[1] != 0) v[1] else rows) - 1;
                t.x = 0;
                t.y = 0;
            },
            'S' => try t.scroll(n),
            'T' => try t.scroll(-n),
            's' => t.saved = .{ t.x, t.y },
            'u' => {
                t.x, t.y = t.saved;
            },
            else => return error.Unrecognized,
        }
    }

    fn sgr(t: *Terminal, v: []const i64) Error!void {
        var k: usize = 0;
        while (k < v.len) : (k += 1) {
            switch (v[k]) {
                0 => {
                    t.fg = null;
                    t.bg = null;
                    t.bold = false;
                },
                1 => t.bold = true,
                22 => t.bold = false,
                39 => t.fg = null,
                49 => t.bg = null,
                59 => {},
                38, 48 => {
                    if (k + 1 >= v.len or v[k + 1] != 2) return error.Unrecognized;
                    if (k + 5 > v.len) return error.Unrecognized;
                    const rgb: Rgb = v[k + 2 ..][0..3].*;
                    if (v[k] == 38) t.fg = rgb else t.bg = rgb;
                    k += 4;
                },
                else => return error.Unrecognized,
            }
        }
    }

    /// The grid as Python's `json.dumps` wrote it (lists of
    /// `[text, fg, bold]`, a fourth item for a link), the form the frame
    /// digests in the old reports were taken over.
    pub fn gridJson(t: *const Terminal, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(a, '[');
        for (t.grid, 0..) |c, k| {
            if (k > 0) try out.appendSlice(a, ", ");
            try out.append(a, '[');
            try pyString(a, &out, c.text);
            if (c.fg) |fg| {
                try out.print(a, ", [{d}, {d}, {d}]", .{ fg[0], fg[1], fg[2] });
            } else try out.appendSlice(a, ", null");
            try out.appendSlice(a, if (c.bold) ", true" else ", false");
            if (c.link) |link| {
                try out.appendSlice(a, ", ");
                try pyString(a, &out, link);
            }
            try out.append(a, ']');
        }
        try out.append(a, ']');
        return out.items;
    }
};

/// A string as Python's `json.dumps` (ensure_ascii) writes it.
pub fn pyString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    var it = (std.unicode.Utf8View.init(s) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0c => try out.appendSlice(a, "\\f"),
            ' '...'!', '#'...'[', ']'...'~' => try out.append(a, @intCast(cp)),
            else => if (cp < 0x10000) {
                try out.print(a, "\\u{x:0>4}", .{cp});
            } else {
                const v = cp - 0x10000;
                try out.print(a, "\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
            },
        }
    }
    try out.append(a, '"');
}

pub fn int(s: []const u8) Error!i64 {
    return std.fmt.parseInt(i64, s, 10) catch error.Unrecognized;
}

/// Strict base64 with padding, as `base64.b64decode(validate=True)`.
pub fn base64(a: Allocator, s: []const u8) Error![]u8 {
    const d = std.base64.standard.Decoder;
    const n = d.calcSizeForSlice(s) catch return error.Unrecognized;
    const out = try a.alloc(u8, n);
    d.decode(out, s) catch return error.Unrecognized;
    return out;
}

/// Hex-encoded bytes, as the programs print them.
pub fn unhex(a: Allocator, s: []const u8) Error![]u8 {
    if (s.len % 2 != 0) return error.Unrecognized;
    const out = try a.alloc(u8, s.len / 2);
    _ = std.fmt.hexToBytes(out, s) catch return error.Unrecognized;
    return out;
}

/// The intent of a drawing-core frame: the alphabet cycling through every
/// cell; with `heavy`, an RGB and bold per cell that `salt` alternates.
pub fn expected(a: Allocator, cols: usize, rows: usize, heavy: bool, salt: usize) ![]Cell {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    const cells = try a.alloc(Cell, cols * rows);
    for (cells, 0..) |*c, i| {
        c.* = .{
            .text = alphabet[i % alphabet.len ..][0..1],
            .fg = if (heavy) .{ @intCast((i * 13 + salt * 17) % 256), @intCast((i * 7 + 31) % 256), @intCast((i * 3 + 53) % 256) } else null,
            .bold = heavy and (i + salt) % 2 == 0,
        };
    }
    return cells;
}

/// What a drawing-core program reported on its last line.
pub const Result = struct {
    units: u64,
    /// Changed cells the library counted itself, where it exposes them.
    native_count: ?u64,
    output_bytes: u64,
    ns: u64,
};

/// One drawing-core check: `frames` are the hex lines a side printed.
pub fn verifyFrames(a: Allocator, task: []const u8, cols: usize, rows: usize, frames_in: []const []const u8, result: Result) !json.Value {
    var evidence: json.ObjectMap = .empty;
    if (std.mem.eql(u8, task, "buffer_diff") or std.mem.eql(u8, task, "cell_reads")) {
        if (frames_in.len != 0) return error.Mismatch;
        const per_pass = (cols * rows + 96) / 97;
        if (result.native_count != 3 * per_pass) return error.Mismatch;
        try evidence.put(a, "status", .{ .string = "passed" });
        try evidence.put(a, "changed_cells_per_pass", .{ .integer = @intCast(per_pass) });
        return .{ .object = evidence };
    }
    var t = try Terminal.init(a, cols, rows);
    const picture = std.mem.startsWith(u8, task, "picture_");
    var frames = frames_in;
    if (picture) {
        if (frames.len == 0) return error.Mismatch;
        try t.feed(try unhex(a, frames[0]));
        if (t.placements.count() != 0 or t.images.count() != 1) return error.Mismatch;
        frames = frames[1..];
    }
    if (frames.len != 4) return error.Mismatch;
    var digests: json.Array = .init(a);
    for (frames, 0..) |frame, k| {
        const previous = t.commands;
        try t.feed(try unhex(a, frame));
        const want = try expected(a, cols, rows, std.mem.eql(u8, task, "style_heavy"), k % 2);
        for (t.grid, want, 0..) |got, w, j| if (!got.eql(w)) {
            std.log.err("{s}: frame {d} cell {d}: got \"{s}\", want \"{s}\"", .{ task, k, j, got.text, w.text });
            return error.Mismatch;
        };
        // The backend may emit an SGR reset on an empty diff, but no cells.
        if (std.mem.startsWith(u8, task, "unchanged") and k > 0 and result.native_count != 0) return error.Mismatch;
        if (picture) {
            const x: i64 = if (std.mem.eql(u8, task, "picture_layers")) @intCast(k % 2) else 0;
            if (t.placements.count() != 1) return error.Mismatch;
            const p = t.placements.get(.{ .image = 7, .placement = 1 }) orelse return error.Mismatch;
            if (!std.meta.eql(p, Placement{ .x = x, .y = 0, .cols = 2, .rows = 2 })) return error.Mismatch;
            if (std.mem.eql(u8, task, "picture_unchanged") and k > 0 and t.commands != previous) return error.Mismatch;
        }
        var sum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(try t.gridJson(a), &sum, .{});
        try digests.append(.{ .string = try a.dupe(u8, &std.fmt.bytesToHex(sum, .lower)) });
    }
    var images: json.ObjectMap = .empty;
    var it = t.images.iterator();
    while (it.next()) |e| try images.put(a, try a.print("{d}", .{e.key_ptr.*}), .{ .string = e.value_ptr.* });
    try evidence.put(a, "status", .{ .string = "passed" });
    try evidence.put(a, "frame_sha256", .{ .array = digests });
    try evidence.put(a, "picture_placements", .{ .integer = @intCast(t.placements.count()) });
    try evidence.put(a, "images", .{ .object = images });
    return .{ .object = evidence };
}

test "text, wide glyphs, marks and wrap" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Terminal.init(a, 4, 2);
    try t.feed("ab\u{6f22}e\u{301}xy");
    try std.testing.expectEqualStrings("ab\u{6f22}\ne\u{301}xy", try t.text(a));
    try std.testing.expectEqualStrings("", t.grid[3].text);
    try t.feed("\x1b[1;1H\x1b[38:2::1:2:3;1mZ\x1b[0m");
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, t.grid[0].fg.?);
    try std.testing.expect(t.grid[0].bold);
    try std.testing.expectError(error.Unrecognized, t.feed("\x07"));
    try std.testing.expectError(error.Unrecognized, t.feed("\x1b[5n"));
}

test "scroll regions and erase" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Terminal.init(a, 3, 3);
    try t.feed("aaa\r\nbbb\r\nccc");
    try t.feed("\x1b[2;3r\x1b[S");
    try std.testing.expectEqualStrings("aaa\nccc\n", try t.text(a));
    try t.feed("\x1b[r\x1b[T");
    try std.testing.expectEqualStrings("\naaa\nccc", try t.text(a));
    try t.feed("\x1b[2;2H\x1b[K");
    try std.testing.expectEqualStrings("\na\nccc", try t.text(a));
    try t.feed("\x1b[2J");
    try std.testing.expectEqualStrings("\n\n", try t.text(a));
}

test "links and kitty placement" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Terminal.init(a, 4, 2);
    try t.feed("\x1b]8;;https://x\x1b\\ab\x1b]8;;\x07c");
    try std.testing.expectEqualStrings("https://x", t.grid[0].link.?);
    try std.testing.expect(t.grid[2].link == null);
    try std.testing.expectEqual(@as(usize, 1), t.links.count());

    var pixels: [1024]u8 = undefined;
    for (0..256) |k| pixels[k * 4 ..][0..4].* = upload_pixel;
    var encoded: [2048]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&encoded, &pixels);
    try t.feed(try a.print("\x1b_Ga=t,i=7,f=32,s=16,v=16;{s}\x1b\\", .{b64}));
    try t.feed("\x1b[1;2H\x1b_Ga=p,i=7,c=2,r=2,C=1\x1b\\");
    try std.testing.expectEqual(Placement{ .x = 1, .y = 0, .cols = 2, .rows = 2 }, t.placements.get(.{ .image = 7, .placement = 1 }).?);
    try std.testing.expectError(error.Mismatch, t.feed("\x1b_Ga=p,i=8,C=1\x1b\\"));
}

test "grid JSON matches Python's json.dumps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Terminal.init(a, 4, 1);
    try t.feed("\x1b[38;2;1;2;3;1m\"\u{e9}\x1b]8;;u\x1b\\\u{1f600}");
    // json.dumps([('"', (1, 2, 3), True), ('é', (1, 2, 3), True),
    //             ('😀', (1, 2, 3), True, 'u'), ('', (1, 2, 3), True, 'u')])
    try std.testing.expectEqualStrings(
        "[[\"\\\"\", [1, 2, 3], true], [\"\\u00e9\", [1, 2, 3], true], [\"\\ud83d\\ude00\", [1, 2, 3], true, \"u\"], [\"\", [1, 2, 3], true, \"u\"]]",
        try t.gridJson(a),
    );
}
