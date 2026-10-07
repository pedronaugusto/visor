//! Deterministic text inputs every library reads before its clock starts;
//! generated at preparation, never committed. One directory per grid size.
//!
//! Widths follow the rule the decoder replays (`unicode.columns`): East
//! Asian Wide/Fullwidth is two columns, a combining mark joins the cell
//! before it, everything else is one. `wide` and `ascii` hold only clusters
//! every library measures alike; `emoji` holds ZWJ sequences, flags, skin
//! tones, keycaps and VS16, where they differ.
//!
//! Every file is byte for byte what the Python generator made, except the
//! compressed IDAT of `picture.png`: its pixels, chunks and CRCs are the
//! same, and the deflate stream is std's at level 6 instead of zlib's.

const std = @import("std");
const unicode = @import("unicode.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const words = [_][]const u8{
    "alpha", "beta",    "gamma", "delta", "epsilon", "zeta",    "eta", "theta", "iota", "kappa", "lambda",
    "mu",    "omicron", "rho",   "sigma", "tau",     "upsilon", "phi", "chi",   "psi",  "omega", "internationalization",
};
const wide_pieces = [_][]const u8{
    "\u{6f22}\u{5b57}",         "\u{65e5}\u{672c}\u{8a9e}", "\u{4e2d}\u{6587}\u{5b57}", "\u{d55c}\u{ad6d}\u{c5b4}",
    "\u{30c6}\u{30b9}\u{30c8}", "\u{1f600}",                "\u{1f680}",                "\u{1f389}",
    "\u{1f30d}",                "\u{1f525}",                "e\u{301}",                 "n\u{303}",
    "a\u{308}",
} ++ words[0..6].*;
const emoji_pieces = [_][]const u8{
    "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", "\u{1f469}\u{1f3fd}\u{200d}\u{1f4bb}",
    "\u{1f1ef}\u{1f1f5}",                                           "\u{1f1e7}\u{1f1f7}",
    "\u{1f44d}\u{1f3fb}",                                           "\u{2764}\u{fe0f}",
    "1\u{fe0f}\u{20e3}",                                            "\u{1f3f3}\u{fe0f}\u{200d}\u{1f308}",
    "\u{6f22}\u{5b57}",                                             "e\u{301}",
    "x",                                                            "ok",
    "\u{1f600}",                                                    "q\u{307}\u{323}",
};

/// Pieces from `pieces`, every third from `seed`, joined by spaces while
/// they fit in `cols` columns.
fn fillLine(a: Allocator, out: *std.ArrayList(u8), pieces: []const []const u8, cols: usize, seed: usize) !void {
    var used: usize = 0;
    var k = seed;
    var first = true;
    while (true) {
        const piece = pieces[k % pieces.len];
        k += 3;
        const need = unicode.columns(piece) + @intFromBool(!first);
        if (used + need > cols) break;
        if (!first) try out.append(a, ' ');
        try out.appendSlice(a, piece);
        first = false;
        used += need;
    }
}

fn asciiLine(a: Allocator, out: *std.ArrayList(u8), cols: usize, seed: usize) !void {
    const start = out.items.len;
    try fillLine(a, out, &words, cols, seed);
    try out.append(a, ' ');
    try out.appendNTimes(a, 'x', cols);
    out.shrinkRetainingCapacity(start + @min(cols, out.items.len - start));
}

fn logLine(a: Allocator, out: *std.ArrayList(u8), i: usize, cols: usize) !void {
    const start = out.items.len;
    try out.print(a, "2026-10-03T12:{d:0>2}:{d:0>2}.{d:0>3}Z INFO worker-{d} request {d} handled in {d} ms", .{
        i / 60 % 60, i % 60, i % 1000, i % 8, i * 7919 % 100000, i % 97,
    });
    out.shrinkRetainingCapacity(start + @min(cols, out.items.len - start));
}

/// The files of one grid size, by name, in the order they are written.
pub const File = struct { name: []const u8, data: []const u8 };

pub fn files(a: Allocator, cols: usize, rows: usize) ![]File {
    var list: std.ArrayList(File) = .empty;

    var ascii: std.ArrayList(u8) = .empty;
    for (0..rows * 2) |i| {
        if (i > 0) try ascii.append(a, '\n');
        try asciiLine(a, &ascii, cols, i);
    }
    try ascii.append(a, '\n');
    try list.append(a, .{ .name = "ascii.txt", .data = ascii.items });

    var wide: std.ArrayList(u8) = .empty;
    for (0..rows * 2) |i| {
        if (i > 0) try wide.append(a, '\n');
        try fillLine(a, &wide, &wide_pieces, cols, i);
    }
    try wide.append(a, '\n');
    try list.append(a, .{ .name = "wide.txt", .data = wide.items });

    var emoji: std.ArrayList(u8) = .empty;
    for (0..rows) |i| {
        if (i > 0) try emoji.append(a, '\n');
        try fillLine(a, &emoji, &emoji_pieces, cols * 2, i);
    }
    try emoji.append(a, '\n');
    try list.append(a, .{ .name = "emoji.txt", .data = emoji.items });

    var log: std.ArrayList(u8) = .empty;
    for (0..rows * 3) |i| {
        if (i > 0) try log.append(a, '\n');
        try logLine(a, &log, i, cols);
    }
    try log.append(a, '\n');
    try list.append(a, .{ .name = "log.txt", .data = log.items });

    var prose: std.ArrayList(u8) = .empty;
    {
        var used: usize = 0;
        var i: usize = 0;
        while (used < cols * rows * 7 / 10) : (i += 1) {
            const word = words[(i * 7) % words.len];
            if (i > 0) try prose.append(a, ' ');
            try prose.appendSlice(a, word);
            used += word.len + 1;
        }
    }
    try list.append(a, .{ .name = "prose.txt", .data = prose.items });

    var doc: std.ArrayList(u8) = .empty;
    try doc.appendSlice(a, "# Document\n\n");
    for (0..@max(1, rows / 4)) |s| {
        if (s > 0) try doc.append(a, '\n');
        try doc.print(a, "## Section {d}\n\nA paragraph with **strong {d}**, *emphasis*, `code {d}` and " ++
            "[a link](https://example.com/{d}) that runs long enough to wrap at most widths. ", .{ s, s, s, s });
        for (0..24) |k| {
            if (k > 0) try doc.append(a, ' ');
            try doc.appendSlice(a, words[(s + k) % words.len]);
        }
        try doc.print(a, "\n\n- first item {d}\n- second item with _more_ words\n  - nested item\n1. numbered\n\n" ++
            "> quoted text {d}\n> > nested quote\n\n```zig\nconst x = {d};\nconst y = x + 1;\n```\n\n---\n", .{ s, s, s });
    }
    try list.append(a, .{ .name = "doc.md", .data = doc.items });

    // GFM tables and task lists: one table a section, as many rows as the
    // grid, every alignment, inline markup, a wide word and an escaped pipe.
    var tables: std.ArrayList(u8) = .empty;
    for (0..@max(1, rows / 4)) |s| {
        if (s > 0) try tables.append(a, '\n');
        try tables.print(a, "## Tables {d}\n\n- [x] done task {d}\n- [ ] open task with `code`\n\n" ++
            "| name | size | kind | note |\n| :--- | ---: | :--: | ---- |\n", .{ s, s });
        for (0..rows) |r| {
            if (r > 0) try tables.append(a, '\n');
            try tables.print(a, "| row {d} **{s}** | {d} | \u{6f22}\u{5b57} `{d}` | a \\| pipe and [link](https://example.com/{d}) |", .{
                r, words[r % words.len], r * 7919 % 1000, r, r,
            });
        }
        try tables.append(a, '\n');
    }
    try list.append(a, .{ .name = "tables.md", .data = tables.items });

    var pool: std.ArrayList(u8) = .empty;
    const tones = [_][]const u8{ "", "\u{1f3fb}", "\u{1f3fc}", "\u{1f3fd}", "\u{1f3fe}", "\u{1f3ff}" };
    const jobs = [_][]const u8{
        "\u{1f4bb}", "\u{1f52c}", "\u{1f3a8}", "\u{1f680}", "\u{1f373}",
        "\u{1f33e}", "\u{1f3eb}", "\u{1f3ed}", "\u{1f527}", "\u{1f3a4}",
    };
    var first = true;
    for ([_][]const u8{ "\u{1f469}", "\u{1f468}" }) |base| for (tones) |tone| for (jobs) |job| {
        if (!first) try pool.append(a, '\n');
        first = false;
        try pool.print(a, "{s}{s}\u{200d}{s}", .{ base, tone, job });
    };
    for (0..26) |x| {
        var y: usize = 0;
        while (y < 26) : (y += 3) {
            var buf: [8]u8 = undefined;
            const n = try std.unicode.utf8Encode(@intCast(0x1F1E6 + x), buf[0..4]);
            const m = try std.unicode.utf8Encode(@intCast(0x1F1E6 + y), buf[n..][0..4]);
            try pool.append(a, '\n');
            try pool.appendSlice(a, buf[0 .. @as(usize, n) + m]);
        }
    }
    try pool.append(a, '\n');
    try list.append(a, .{ .name = "pool.txt", .data = pool.items });

    const events = [_][]const u8{
        "a",      "Z",      "\x1b[A",                        "\x1b[97;5u", "\x1b[<0;10;5M", "\x1b[<0;10;5m",
        "\x1b[I", "\x1b[O", "\x1b[200~hello world\x1b[201~", "\x1b[15~",   "\u{e9}",        "\x1b[1;5C",
    };
    var input: std.ArrayList(u8) = .empty;
    for (0..cols * rows / 4) |i| try input.appendSlice(a, events[i % events.len]);
    try input.append(a, '.');
    try list.append(a, .{ .name = "input.bin", .data = input.items });

    try list.append(a, .{ .name = "picture.png", .data = try redPng(a, (cols - 1) * 8, (rows - 1) * 16) });
    return list.items;
}

/// One opaque red RGBA image: 8-bit, colour type 6, one filter byte a row.
pub fn redPng(a: Allocator, width: usize, height: usize) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try raw.ensureTotalCapacity(a, (1 + width * 4) * height);
    for (0..height) |_| {
        raw.appendAssumeCapacity(0);
        for (0..width) |_| raw.appendSliceAssumeCapacity(&.{ 255, 0, 0, 255 });
    }
    var compressed: Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer compressed.deinit();
    {
        const window = try a.alloc(u8, std.compress.flate.max_window_len);
        defer a.free(window);
        var deflate = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);
        try deflate.writer.writeAll(raw.items);
        try deflate.finish();
    }
    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(a, &png, "IHDR", &ihdr);
    try chunk(a, &png, "IDAT", compressed.written());
    try chunk(a, &png, "IEND", "");
    return png.items;
}

fn chunk(a: Allocator, png: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try png.appendSlice(a, &len);
    try png.appendSlice(a, tag);
    try png.appendSlice(a, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try png.appendSlice(a, &sum);
}

/// Writes `<root>/<cols>x<rows>/` for one size.
pub fn generate(gpa: Allocator, io: Io, root: []const u8, cols: usize, rows: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = try a.print("{s}/{d}x{d}", .{ root, cols, rows });
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    for (try files(a, cols, rows)) |file| try dir.writeFile(io, .{ .sub_path = file.name, .data = file.data });
}

const Size = struct { cols: usize, rows: usize, files: []const [2][]const u8 };
const python_digests = [_]Size{
    .{ .cols = 8, .rows = 4, .files = &.{
        .{ "ascii.txt", "d7ffb73cf18b3c05a4dc2dcd875f6ea6229ace7fe6081fa7fcec9313e445b939" },
        .{ "doc.md", "104fe003384dbfe0cdf34ee031c7cf533ede1faf43db95fd93e5506760da95da" },
        .{ "emoji.txt", "7c6a27db631e8110f2279bedb95bfac5ecb7691ba7d2dae0885e2fed79d68f03" },
        .{ "input.bin", "cb2d2fd3c790b7fed36965008ddb1e1a533019b2c1d4a6d7a4baba01a89584d6" },
        .{ "log.txt", "37443281ef501c8e233fdfa47d24c891cc56c2fc36ae135bd37133e821975c61" },
        .{ "pool.txt", "738c06b48f9433f358973300b21c17c014a3e4b1bbd51bfa1617d8c6d7a3770e" },
        .{ "prose.txt", "c511bd93b87cd461cef746ffa238af641731f905f15de28145a1a366b700bad2" },
        .{ "tables.md", "891b23ee49882238f527d09c6f5880a146ed8fe7e08277b1940bad557e2659fc" },
        .{ "wide.txt", "40142c617efd76db03c94760826e62e4eaa3027034bba44dd4dce03d7e627826" },
    } },
    .{ .cols = 200, .rows = 60, .files = &.{
        .{ "ascii.txt", "cd75d75052c7e23e5c5c843518e81b97389a4bba703a301f065de546c77dfdef" },
        .{ "doc.md", "a96f5a11d6f80ee96d82bf3e97f197526b2fec5d373ce07abad0800f58372452" },
        .{ "emoji.txt", "40579cfbc248f546531f6212e8ccbf209f2056c2788972c5b3e32f5f43f3a5e0" },
        .{ "input.bin", "e2e931f27044158c4091efb03922621ecd936094f58812d663d06d4c547caa14" },
        .{ "log.txt", "e8948bd7a23985d3380d8d039db9e842fef313601c9b57019f0e3ca3cdc99be1" },
        .{ "pool.txt", "738c06b48f9433f358973300b21c17c014a3e4b1bbd51bfa1617d8c6d7a3770e" },
        .{ "prose.txt", "aa3d88345651af5ee4326468be400a6c2bc9f740294b541d39ea96d8185c8ad7" },
        .{ "tables.md", "0f8a4ee90b4bc5c034d40b3d9d858e04d97f53f4d49d4792d579c80f60359cca" },
        .{ "wide.txt", "57b425246da862fedff1e0d333f1fd7c9135c2c07b535515ff76c930f08ecaae" },
    } },
};

test "the corpus is the Python generator's, byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // SHA-256 of each file the Python generator wrote at 8x4 and 200x60.
    for (python_digests) |size| {
        for (try files(arena.allocator(), size.cols, size.rows)) |file| {
            if (std.mem.eql(u8, file.name, "picture.png")) continue;
            var sum: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file.data, &sum, .{});
            const hex = std.fmt.bytesToHex(sum, .lower);
            const expected = for (size.files) |f| {
                if (std.mem.eql(u8, f[0], file.name)) break f[1];
            } else return error.MissingDigest;
            std.testing.expectEqualStrings(expected, &hex) catch |err| {
                std.debug.print("{s} at {d}x{d}\n", .{ file.name, size.cols, size.rows });
                return err;
            };
        }
    }
}

test "the picture decodes to the same red pixels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const png = try redPng(arena.allocator(), 56, 48);
    try @import("pictures.zig").checkRedPng(arena.allocator(), png, 56, 48);
}
