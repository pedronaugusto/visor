//! The picture-frame checks: every frame decoded against a common opaque-red
//! fixture. The byte forms differ between protocols, so agreement is on RGBA
//! pixels and the cell rectangle, not on escape spellings. PNG generation,
//! uploads and decoding are untimed.

const std = @import("std");
const terminal = @import("terminal.zig");
const Terminal = terminal.Terminal;
const Allocator = std.mem.Allocator;
const json = std.json;

const red = [4]u8{ 255, 0, 0, 255 };

/// The fixture PNG: valid CRCs, the IHDR of a `width`x`height` RGBA image,
/// and IDAT data that inflates to opaque red with a zero filter a row.
pub fn checkRedPng(a: Allocator, data: []const u8, width: usize, height: usize) !void {
    if (!std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return error.Mismatch;
    var pos: usize = 8;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(a);
    while (pos < data.len) {
        if (pos + 12 > data.len) return error.Mismatch;
        const length = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (pos + 12 + length > data.len) return error.Mismatch;
        const tag = data[pos + 4 ..][0..4];
        const body = data[pos + 8 ..][0..length];
        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(body);
        if (crc.final() != std.mem.readInt(u32, data[pos + 8 + length ..][0..4], .big)) return error.Mismatch;
        if (std.mem.eql(u8, tag, "IHDR")) {
            if (body.len != 13) return error.Mismatch;
            if (std.mem.readInt(u32, body[0..4], .big) != width or std.mem.readInt(u32, body[4..8], .big) != height) return error.Mismatch;
            if (!std.mem.eql(u8, body[8..13], &.{ 8, 6, 0, 0, 0 })) return error.Mismatch;
        }
        if (std.mem.eql(u8, tag, "IDAT")) try compressed.appendSlice(a, body);
        pos += length + 12;
    }
    var input: std.Io.Reader = .fixed(compressed.items);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, window);
    const pixels = inflate.reader.allocRemaining(a, .unlimited) catch return error.Mismatch;
    defer a.free(pixels);
    const row = 1 + width * 4;
    if (pixels.len != row * height) return error.Mismatch;
    for (0..height) |y| {
        const line = pixels[y * row ..][0..row];
        if (line[0] != 0) return error.Mismatch;
        var x: usize = 1;
        while (x < row) : (x += 4) if (!std.mem.eql(u8, line[x..][0..4], &red)) return error.Mismatch;
    }
}

fn digits(s: []const u8, at: *usize) ?u64 {
    const start = at.*;
    while (at.* < s.len and std.ascii.isDigit(s[at.*])) at.* += 1;
    if (at.* == start) return null;
    return std.fmt.parseInt(u64, s[start..at.*], 10) catch null;
}

/// A sixel image body (after `ESC P`, before ST) that paints every pixel of
/// a `width`x`height` raster in palette colour (100, 0, 0), nothing outside.
pub fn checkRedSixel(a: Allocator, body: []const u8, width: usize, height: usize) !void {
    const prefix = "0;1;0q\"1;1;";
    if (!std.mem.startsWith(u8, body, prefix)) return error.Mismatch;
    var i: usize = prefix.len;
    const w = digits(body, &i) orelse return error.Mismatch;
    if (i >= body.len or body[i] != ';') return error.Mismatch;
    i += 1;
    const h = digits(body, &i) orelse return error.Mismatch;
    if (w != width or h != height) return error.Mismatch;
    var x: usize = 0;
    var y: usize = 0;
    var color: ?u64 = null;
    var palette: std.AutoHashMapUnmanaged(u64, [3]u64) = .empty;
    defer palette.deinit(a);
    const covered = try a.alloc(bool, width * height);
    defer a.free(covered);
    @memset(covered, false);
    while (i < body.len) {
        var ch = body[i];
        if (ch == '#') {
            i += 1;
            const index = digits(body, &i) orelse return error.Mismatch;
            color = index;
            if (std.mem.startsWith(u8, body[i..], ";2;")) {
                var j = i + 3;
                const r = digits(body, &j);
                const g = if (r != null and j < body.len and body[j] == ';') blk: {
                    j += 1;
                    break :blk digits(body, &j);
                } else null;
                const b = if (g != null and j < body.len and body[j] == ';') blk: {
                    j += 1;
                    break :blk digits(body, &j);
                } else null;
                if (b != null) {
                    try palette.put(a, index, .{ r.?, g.?, b.? });
                    i = j;
                }
            }
        } else if (ch == '$' or ch == '-') {
            x = 0;
            if (ch == '-') y += 6;
            i += 1;
        } else {
            var count: usize = 1;
            if (ch == '!') {
                i += 1;
                count = @intCast(digits(body, &i) orelse return error.Mismatch);
                if (i >= body.len or body[i] < '?' or body[i] > '~') return error.Mismatch;
                ch = body[i];
            }
            i += 1;
            if (ch < '?' or ch > '~' or x + count > width) return error.Mismatch;
            const mask = ch - '?';
            for (0..6) |bit| {
                if (mask & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                const rgb = palette.get(color orelse return error.Mismatch) orelse return error.Mismatch;
                if (y + bit >= height or !std.mem.eql(u64, &rgb, &.{ 100, 0, 0 })) return error.Mismatch;
                @memset(covered[(y + bit) * width + x ..][0..count], true);
            }
            x += count;
        }
    }
    for (covered) |c| if (!c) return error.Mismatch;
}

/// `ESC <open> … ESC \`, exactly once in `wire`: where it starts, where its
/// body starts and where it ends.
const Span = struct { start: usize, body: usize, end: usize };

fn onlySpan(wire: []const u8, open: []const u8) !Span {
    const start = std.mem.find(u8, wire, open) orelse return error.Mismatch;
    const close = std.mem.findPos(u8, wire, start + open.len, "\x1b\\") orelse return error.Mismatch;
    if (std.mem.findPos(u8, wire, close + 2, open)) |next| {
        if (std.mem.findPos(u8, wire, next + open.len, "\x1b\\") != null) return error.Mismatch;
    }
    return .{ .start = start, .body = start + open.len, .end = close + 2 };
}

/// Splits `text` on `sep` into `key=value` pairs.
fn pairs(a: Allocator, text: []const u8, sep: u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, sep);
    while (it.next()) |p| {
        const eq = std.mem.findScalar(u8, p, '=') orelse return error.Mismatch;
        try map.put(a, p[0..eq], p[eq + 1 ..]);
    }
    return map;
}

/// One picture_frame_* workload of one side; `ev` is its parsed evidence.
pub fn verify(a: Allocator, task: []const u8, cols: usize, rows: usize, ev: anytype, png: []const u8) !json.Value {
    const width = (cols - 1) * 8;
    const height = (rows - 1) * 16;
    var t = try Terminal.init(a, cols, rows);
    const protocol = task["picture_frame_".len..];
    if (std.mem.eql(u8, protocol, "kitty")) {
        var raw: std.ArrayList(u8) = .empty;
        for (try ev.need("setup")) |hexed| try raw.appendSlice(a, try terminal.unhex(a, hexed));
        var payload: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (std.mem.findPos(u8, raw.items, at, "\x1b_G")) |start| {
            const semi = std.mem.findScalarPos(u8, raw.items, start + 3, ';') orelse break;
            const keys = raw.items[start + 3 .. semi];
            const end = std.mem.findPos(u8, raw.items, semi + 1, "\x1b\\") orelse break;
            var fields = try pairs(a, keys, ',');
            if (fields.get("s")) |s| {
                if (try terminal.int(s) != width) return error.Mismatch;
                if (try terminal.int(fields.get("v") orelse return error.Mismatch) != height) return error.Mismatch;
                if (!std.mem.eql(u8, fields.get("f") orelse "32", "32")) return error.Mismatch;
            }
            try payload.appendSlice(a, try terminal.base64(a, raw.items[semi + 1 .. end]));
            at = end + 2;
        }
        if (payload.items.len != width * height * 4) return error.Mismatch;
        var k: usize = 0;
        while (k < payload.items.len) : (k += 4) if (!std.mem.eql(u8, payload.items[k..][0..4], &red)) return error.Mismatch;
        try t.images.put(a, 7, "validated RGBA fixture");
    }
    try checkRedPng(a, png, width, height);
    const wires = try ev.need("wire");
    for (wires, 0..) |hexed, frame| {
        const wire = try terminal.unhex(a, hexed);
        const col: i64 = @intCast(frame % 2);
        if (std.mem.eql(u8, protocol, "sixel") or std.mem.eql(u8, protocol, "iterm")) {
            const sixel = std.mem.eql(u8, protocol, "sixel");
            const span = try onlySpan(wire, if (sixel) "\x1bP" else "\x1b]1337;File=");
            try t.feed(wire[0..span.start]);
            if (t.x != col or t.y != 0) return error.Mismatch;
            const body = wire[span.body .. span.end - 2];
            if (sixel) {
                try checkRedSixel(a, body, width, height);
            } else {
                const colon = std.mem.findScalar(u8, body, ':') orelse return error.Mismatch;
                var keys = try pairs(a, body[0..colon], ';');
                if (try terminal.int(keys.get("width") orelse return error.Mismatch) != cols - 1) return error.Mismatch;
                if (try terminal.int(keys.get("height") orelse return error.Mismatch) != rows - 1) return error.Mismatch;
                if (!std.mem.eql(u8, keys.get("doNotMoveCursor") orelse "", "1")) return error.Mismatch;
                if (!std.mem.eql(u8, keys.get("inline") orelse "", "1")) return error.Mismatch;
                if (!std.mem.eql(u8, try terminal.base64(a, body[colon + 1 ..]), png)) return error.Mismatch;
            }
            try t.feed(wire[span.end..]);
        } else {
            try t.feed(wire);
            if (std.mem.eql(u8, protocol, "kitty")) {
                const p = t.placements.get(.{ .image = 7, .placement = 1 }) orelse return error.Mismatch;
                const want: terminal.Placement = .{ .x = col, .y = 0, .cols = @intCast(cols - 1), .rows = @intCast(rows - 1) };
                if (!std.meta.eql(p, want)) return error.Mismatch;
            } else {
                for (0..rows) |y| for (0..cols) |x| {
                    const cell = t.grid[y * cols + x];
                    const lit = y < rows - 1 and x >= frame % 2 and x < frame % 2 + cols - 1;
                    if (!std.mem.eql(u8, cell.text, " ") != lit) return error.Mismatch;
                    if (lit and !std.meta.eql(cell.fg, terminal.Rgb{ 255, 0, 0 })) return error.Mismatch;
                };
            }
        }
    }
    var evidence: json.ObjectMap = .empty;
    try evidence.put(a, "frames", .{ .integer = @intCast(wires.len) });
    try evidence.put(a, "rgba_width", .{ .integer = @intCast(width) });
    try evidence.put(a, "rgba_height", .{ .integer = @intCast(height) });
    try evidence.put(a, "status", .{ .string = "passed: common opaque-red image and moving cell rectangle" });
    return .{ .object = evidence };
}

test "sixel: a full red raster passes, a gap fails" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 3x7: one band of six rows, then one more row.
    try checkRedSixel(a, "0;1;0q\"1;1;3;7#1;2;100;0;0#1!3~-!3@", 3, 7);
    try std.testing.expectError(error.Mismatch, checkRedSixel(a, "0;1;0q\"1;1;3;7#1;2;100;0;0#1!3~-!2@", 3, 7));
    try std.testing.expectError(error.Mismatch, checkRedSixel(a, "0;1;0q\"1;1;3;7#1;2;99;0;0#1!3~-!3@", 3, 7));
}
