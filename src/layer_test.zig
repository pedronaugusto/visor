const std = @import("std");
const morse = @import("dependencies.zig").morse;
const geom = @import("geom.zig");
const Caps = @import("caps.zig").Caps;
const shm = @import("shm.zig");
const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Writer = std.Io.Writer;
const under_base: i32 = -1_000_000;
const Image = @import("layer.zig").Image;
const Layer = @import("layer.zig").Layer;
const Transmit = @import("layer.zig").Transmit;
const ImageIds = @import("layer.zig").ImageIds;
const Replacement = @import("layer.zig").Replacement;
const Layers = @import("layer.zig").Layers;
const testing = std.testing;

const Screen = @import("screen.zig").Screen;
const Renderer = @import("render.zig").Renderer;

/// A screen with pictures, a renderer, and a terminal that can say what it
/// was sent.
const Fixture = struct {
    gpa: Allocator,
    screen: Screen,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,
    caps: Caps,
    layers: Layers,

    fn init(gpa: Allocator, cols: u16, rows: u16) !Fixture {
        const size: geom.Size = .{ .cols = cols, .rows = rows };
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit();
        s.method = .unicode;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit();
        r._shown = false;
        r._cursor = .{ .col = 0, .row = 0 };
        return .{
            .gpa = gpa,
            .layers = .init(gpa),
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{ .width_method = .unicode, .osc8 = true, .kitty_graphics = true },
        };
    }

    fn deinit(f: *Fixture) void {
        f.screen.deinit();
        f.layers.deinit();
        f.renderer.deinit();
        f.out.deinit();
    }

    fn draw(f: *Fixture) !Renderer.Stats {
        f.out.clearRetainingCapacity();
        return f.renderer.draw(&f.out.writer, &f.screen, &f.layers, f.caps);
    }

    fn written(f: *Fixture) []const u8 {
        return f.out.written();
    }
};

test "the order tuple sorts left to right so a child never escapes its parent" {
    const Order = Layer.Order;
    try testing.expect(Order.before(.{ .layer = 0 }, .{ .layer = 1 }));
    try testing.expect(Order.before(.{ .layer = 1, .z = 0 }, .{ .layer = 1, .z = 1 }));
    try testing.expect(Order.before(.{ .layer = 1, .z = 1, .sibling = 0 }, .{ .layer = 1, .z = 1, .sibling = 1 }));
    // A deep child of an early parent still comes first.
    try testing.expect(Order.before(.{ .layer = 0, .z = 99 }, .{ .layer = 1, .z = -99 }));
    try testing.expect(!Order.before(.{ .layer = 1 }, .{ .layer = 1 }));
}

test "a layer is placed by the id the program chose, with no round trip" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.layers.declare(.{
        .image = 13,
        .rect = .{ .col = 2, .row = 1, .cols = 8, .rows = 4 },
    });
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.placements);
    const bytes = f.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "i=13") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "a=p") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "q=2") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "C=1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "z=-1000000") != null);
    // Placed from the cell it belongs at.
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[2;3H") != null);
}

test "the same layer declared again writes nothing" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    const layer: Layer = .{ .image = 1, .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 } };
    try f.layers.declare(layer);
    _ = try f.draw();
    try f.layers.declare(layer);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.placements);
    try testing.expectEqual(@as(usize, 0), stats.bytes);
}

test "a layer that moved is replaced rather than deleted and placed again" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 },
    });
    _ = try f.draw();
    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 6, .row = 2, .cols = 4, .rows = 2 },
    });
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.placements);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=d") == null);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=p") != null);
}

test "a layer that left is deleted by name and its bytes are kept" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.layers.declare(.{
        .image = 5,
        .placement = 3,
        .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 },
    });
    _ = try f.draw();
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.placements);
    const bytes = f.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "a=d") != null);
    // The narrow form: this image, this placement, lowercase so the pixels
    // stay on the terminal.
    try testing.expect(std.mem.indexOf(u8, bytes, "d=i") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "i=5") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "p=3") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=I") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=a") == null);
}

test "after a resize every picture is placed again, and one that left is still deleted" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    const stays: Layer = .{ .image = 1, .rect = .{ .col = 0, .row = 4, .cols = 4, .rows = 2 } };
    const leaves: Layer = .{ .image = 2, .rect = .{ .col = 8, .row = 0, .cols = 4, .rows = 2 } };
    try f.layers.declare(stays);
    try f.layers.declare(leaves);
    _ = try f.draw();

    // The terminal took a new size and may have moved or dropped either;
    // the one the layout keeps in the same cells is placed there again.
    const size: geom.Size = .{ .cols = 24, .rows = 6 };
    try f.screen.resize(size);
    try f.renderer.resize(size);
    try f.layers.declare(stays);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 2), stats.placements);
    const bytes = f.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "a=p") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "i=1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "a=d") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "i=2") != null);

    // And once placed, it is known where it is again.
    try f.layers.declare(stays);
    try testing.expectEqual(@as(u32, 0), (try f.draw()).placements);
}

test "a picture swapped for another is placed before the old one goes" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    const at: Rect = .{ .col = 1, .row = 1, .cols = 6, .rows = 3 };
    try f.layers.declare(.{ .image = 6, .rect = at });
    _ = try f.draw();
    try f.layers.declare(.{ .image = 7, .rect = at });
    _ = try f.draw();
    const bytes = f.written();
    const placed = std.mem.indexOf(u8, bytes, "a=p,q=2,i=7").?;
    const dropped = std.mem.indexOf(u8, bytes, "a=d,q=2,d=i,i=6").?;
    try testing.expect(placed < dropped);
}

test "an image sent quietly is ready at once, compressed when that is smaller" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // A dark picture, the kind that deflates to nothing.
    var pixels: [64 * 64 * 4]u8 = @splat(0);
    const sent = try l.transmit(&out.writer, 9, &pixels, .{ .width = 64, .height = 64 });
    try testing.expect(sent < pixels.len / 10);
    const bytes = out.written();
    try testing.expect(std.mem.startsWith(u8, bytes, "\x1b_Gq=2,i=9,"));
    try testing.expect(std.mem.indexOf(u8, bytes, "o=z") != null);
    try testing.expect(l.ready(9, 0, 250));
    try testing.expectEqual(Image.State.ready, l.image(9).?.state);

    // Noise does not deflate, and goes as it is.
    out.clearRetainingCapacity();
    var noise: [256]u8 = undefined;
    var x: u32 = 0x12345678;
    for (&noise) |*b| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.* = @truncate(x);
    }
    const raw = try l.transmit(&out.writer, 10, &noise, .{ .width = 8, .height = 8 });
    try testing.expectEqual(noise.len, raw);
    try testing.expect(std.mem.indexOf(u8, out.written(), "o=z") == null);
}

test "the pixels decompress to what was sent, chunk after chunk" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var pixels: [96 * 96 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @truncate(i / 7);
    _ = try l.transmit(&out.writer, 4, &pixels, .{ .width = 96, .height = 96 });

    // Join the chunks' payloads, undo the base64, then the deflate.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    var chunks: usize = 0;
    var rest = out.written();
    while (std.mem.indexOf(u8, rest, "\x1b_G")) |at| {
        const semi = std.mem.indexOfScalarPos(u8, rest, at, ';').?;
        const end = std.mem.indexOfPos(u8, rest, semi, "\x1b\\").?;
        try joined.appendSlice(testing.allocator, rest[semi + 1 .. end]);
        rest = rest[end + 2 ..];
        chunks += 1;
    }
    try testing.expect(chunks > 1);
    const decoded = try testing.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(joined.items));
    defer testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, joined.items);
    var reader: std.Io.Reader = .fixed(decoded);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    var back: std.Io.Writer.Allocating = .init(testing.allocator);
    defer back.deinit();
    _ = try inflate.reader.streamRemaining(&back.writer);
    try testing.expectEqualSlices(u8, &pixels, back.written());
}

test "an image sent asking for an answer is ready on the word, or when the grace runs out" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };

    _ = try l.transmit(&out.writer, 6, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 1000 });
    try testing.expect(std.mem.indexOf(u8, out.written(), "q=") == null);
    try testing.expect(!l.ready(6, 1100, 250));
    l.ack(.{ .id = 6, .message = "OK" });
    try testing.expect(l.ready(6, 1101, 250));
    try testing.expectEqual(@as(?bool, true), l._answers);

    // A refusal: not ready, and the program sends again.
    _ = try l.transmit(&out.writer, 7, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 2000 });
    l.ack(.{ .id = 7, .message = "EBADPNG: bad data" });
    try testing.expect(!l.ready(7, 5000, 250));
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);

    // An answer about an id never sent here -- a probe's -- changes nothing.
    l.ack(.{ .id = 31, .message = "OK" });
    try testing.expect(l.image(31) == null);
}

test "a terminal that never answers is given the grace once, and then not waited for" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };

    _ = try l.transmit(&out.writer, 2, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 1000 });
    try testing.expect(!l.ready(2, 1249, 250));
    try testing.expect(l.ready(2, 1250, 250));
    try testing.expectEqual(@as(u32, 1), l._fallbacks);
    try testing.expectEqual(@as(?bool, false), l._answers);

    _ = try l.transmit(&out.writer, 3, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 2000 });
    try testing.expect(l.ready(3, 2000, 250));
    try testing.expectEqual(@as(u32, 1), l._fallbacks);
}

test "sending to an id on screen places it again, and freeing takes it all away" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };
    const layer: Layer = .{ .image = 8, .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 } };

    _ = try f.layers.transmit(&sent.writer, 8, &px, .{ .width = 1, .height = 1 });
    try f.layers.declare(layer);
    _ = try f.draw();
    try testing.expectEqual(@as(usize, 1), f.layers.count());

    // New pixels under the same id: the terminal took the placement down,
    // so the next frame puts it back though the layer did not move.
    _ = try f.layers.transmit(&sent.writer, 8, &px, .{ .width = 1, .height = 1 });
    try testing.expectEqual(@as(usize, 1), f.layers._images.items.len);
    try f.layers.declare(layer);
    const again = try f.draw();
    try testing.expectEqual(@as(u32, 1), again.placements);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=p") != null);

    // Freed: the pixels and the placements, in one command the program
    // wrote, and nothing for the next frame to delete.
    sent.clearRetainingCapacity();
    try f.layers.free(&sent.writer, 8);
    try testing.expectEqualStrings("\x1b_Ga=d,q=2,d=I,i=8\x1b\\", sent.written());
    try testing.expect(f.layers.image(8) == null);
    try testing.expectEqual(@as(usize, 0), f.layers.count());
    const after = try f.draw();
    try testing.expectEqual(@as(u32, 0), after.placements);
    try testing.expectEqual(@as(usize, 0), after.bytes);
}

test "a layer at its own size names no columns or rows" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    try f.layers.declare(.{
        .image = 16,
        .placement = 9,
        .rect = .{ .col = 3, .row = 2 },
        .x_offset = 6,
        .y_offset = 10,
    });
    _ = try f.draw();
    const bytes = f.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "i=16,p=9,X=6,Y=10,z=") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "c=") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "r=") == null);
}

test "the images list is as long as the pictures alive" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };
    for (0..100) |i| {
        const id: u32 = @intCast(2 + i % 4);
        _ = try l.transmit(&out.writer, id, &px, .{ .width = 1, .height = 1 });
    }
    try testing.expectEqual(@as(usize, 4), l._images.items.len);
    try l.freeAll(&out.writer);
    try testing.expectEqual(@as(usize, 0), l._images.items.len);
}

test "layers are stacked in the order their tuples give" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.layers.declare(.{
        .image = 2,
        .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 },
        .order = .{ .layer = 1 },
    });
    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 4, .row = 0, .cols = 2, .rows = 2 },
        .order = .{ .layer = 0 },
    });
    _ = try f.draw();
    const bytes = f.written();
    const first = std.mem.indexOf(u8, bytes, "i=1,").?;
    const second = std.mem.indexOf(u8, bytes, "i=2,").?;
    try testing.expect(first < second);
    try testing.expect(std.mem.indexOf(u8, bytes, "z=-1000000") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "z=-999999") != null);
}

test "inserting a layer re-places unchanged layers at their new z positions" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    const a: Layer = .{ .image = 1, .rect = .{ .cols = 2, .rows = 2 }, .order = .{ .layer = 1 } };
    const b: Layer = .{ .image = 2, .rect = .{ .col = 3, .cols = 2, .rows = 2 }, .order = .{ .layer = 2 } };
    try f.layers.declare(a);
    try f.layers.declare(b);
    _ = try f.draw();

    try f.layers.declare(.{
        .image = 3,
        .rect = .{ .col = 6, .cols = 2, .rows = 2 },
        .order = .{ .layer = 0 },
    });
    try f.layers.declare(a);
    try f.layers.declare(b);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 3), stats.placements);
}

test "a layer over the text gets a z at or above zero" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 },
        .under = false,
    });
    _ = try f.draw();
    // Zero is the protocol's own default for `z`, so it is not written;
    // what matters is that nothing put it under the text.
    try testing.expect(std.mem.indexOf(u8, f.written(), "z=-") == null);
}

test "a terminal with no graphics gets no graphics commands" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    f.caps.kitty_graphics = false;
    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 },
    });
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.placements);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b_G") == null);
}

//=========================================================================
// The three things the layer that came before this one got wrong.
//=========================================================================

test "the text pass never deletes a placement" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 8, .rows = 4 },
    });
    try f.screen.write(0, 5, "a", .{}, .none);
    _ = try f.draw();

    // A frame in which one cell changed and the picture did not.
    try f.layers.declare(.{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 8, .rows = 4 },
    });
    try f.screen.write(1, 5, "b", .{}, .none);
    const stats = try f.draw();

    try testing.expect(stats.cells > 0);
    try testing.expectEqual(@as(u32, 0), stats.placements);
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b_G") == null);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=d") == null);
}

test "a link survives a frame in which a neighbouring cell changed" {
    var f: Fixture = try .init(testing.allocator, 20, 2);
    defer f.deinit();

    const l = try f.screen.link("https://ziglang.org", "id=1");
    try f.screen.write(0, 0, "z", .{}, l);
    try f.screen.write(1, 0, "i", .{}, l);
    try f.screen.write(2, 0, "g", .{}, l);
    _ = try f.draw();

    // The cell beside the link changes; the link's own cells do not.
    try f.screen.write(5, 0, "x", .{}, .none);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "\x1b]8;") == null);
    for (0..3) |col| {
        try testing.expectEqual(l, f.screen.readCell(@intCast(col), 0).?.link);
    }

    // And a link differing only in its parameters is a different link.
    const other = try f.screen.link("https://ziglang.org", "id=2");
    try testing.expect(l != other);
    try f.screen.write(1, 0, "i", .{}, other);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "id=2") != null);
}

test "a program that asks for clicks gets clicks and no motion" {
    // Not this package's code, but this package's promise: a program that
    // asks for clicks gets clicks, and not a report for every cell the
    // pointer crosses.
    var buffer: [256]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.mouse(&out, .{ .motion = .press });
    const bytes = out.buffered();
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002h") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003h") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002l") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003l") != null);
}

test "sending pictures again allocates nothing once the buffers have grown" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counting.allocator();
    var layers: Layers = .init(gpa);
    defer layers.deinit();
    var sink: std.Io.Writer.Discarding = .init(&.{});

    // A dark picture, which deflates to a fraction of itself.
    const pixels: [64 * 64 * 4]u8 = @splat(0);
    _ = try layers.transmit(&sink.writer, 7, &pixels, .{ .width = 64, .height = 64 });
    const grown = counting.allocations;
    try testing.expect(grown > 0);
    for (0..4) |_| _ = try layers.transmit(&sink.writer, 7, &pixels, .{ .width = 64, .height = 64 });
    try testing.expectEqual(grown, counting.allocations);
}

test "a picture through shared memory: the name goes, the terminal's word settles the medium" {
    if (!shm.supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const pixels = [_]u8{ 9, 8, 7, 6 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // tried, and read: the medium is on for good, the object gone
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(io);
    defer l.deinit();
    const n = try l.transmit(&out.writer, 5, &pixels, .{ .width = 1, .height = 1 });
    try testing.expect(std.mem.indexOf(u8, out.written(), "t=s") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "S=4") != null);
    const name = l.image(5).?.shm.?;
    try testing.expectEqual(name.len, n);
    // on trial, the terminal is asked to answer even when the caller was not
    try testing.expect(!l.ready(5, 0, 1000));
    l.ack(.{ .id = 5, .message = "OK" });
    try testing.expect(l.ready(5, 0, 1000));
    try testing.expect(l._shared_memory.?.state == .yes);
    try testing.expect(l.image(5).?.shm == null);
    // the object was unlinked: its name can be put again
    try shm.put(io, name, &pixels);
    shm.unlink(io, name);
}

test "a terminal that cannot read shared memory gets the picture again in the escape code" {
    if (!shm.supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const pixels = [_]u8{ 1, 2, 3, 4 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // refused: the medium is off, the picture failed and is sent again
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(io);
    defer l.deinit();
    _ = try l.transmit(&out.writer, 7, &pixels, .{ .width = 1, .height = 1 });
    l.ack(.{ .id = 7, .message = "EBADF:no such object" });
    try testing.expect(l._shared_memory.?.state == .no);
    try testing.expect(!l.ready(7, 0, 1000));
    out.clearRetainingCapacity();
    _ = try l.transmit(&out.writer, 7, &pixels, .{ .width = 1, .height = 1, .compress = false });
    try testing.expect(std.mem.indexOf(u8, out.written(), "t=s") == null);
    try testing.expect(l.ready(7, 0, 1000));

    // silence: a terminal that never answers is not trusted with another
    var q: Layers = .init(testing.allocator);
    q.configureSharedMemory(io);
    defer q.deinit();
    _ = try q.transmit(&out.writer, 8, &pixels, .{ .width = 1, .height = 1, .now_ms = 0 });
    try testing.expect(!q.ready(8, 10, 1000));
    try testing.expect(!q.ready(8, 2000, 1000));
    try testing.expect(q._shared_memory.?.state == .no);
    try testing.expect(q.image(8).?.shm == null);
}

test "a replacement lands over the old picture, placed before dropped before freed" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var ids = try ImageIds.init(6, 9, 8);
    var p: Replacement = .{};
    var sink: Writer.Discarding = .init(&.{});
    const pixels = [_]u8{0} ** 16;
    const at: Layer = .{ .image = 0, .rect = .{ .col = 2, .row = 1, .cols = 8, .rows = 4 } };
    const first = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .width = 2, .height = 2, .answer = true, .now_ms = 1000 });
    try testing.expectEqual(@as(u32, 6), first.id);
    try testing.expect(!p.canSend());
    try testing.expectError(error.Busy, p.send(&f.layers, &sink.writer, &ids, &pixels, .{}));
    try testing.expect(try p.declare(&f.layers, at, 1016, 250));
    try testing.expectEqual(@as(u32, 0), (try f.draw()).placements);
    f.layers.ack(.{ .id = first.id, .message = "OK" });
    try testing.expect(!try p.declare(&f.layers, at, 1033, 250));
    try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
    const next = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .width = 2, .height = 2, .answer = true, .now_ms = 2000 });
    try testing.expectEqual(@as(u32, 7), next.id);
    try testing.expect(try p.declare(&f.layers, at, 2016, 250));
    try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
    f.layers.ack(.{ .id = next.id, .message = "OK" });
    _ = try p.declare(&f.layers, at, 2041, 250);
    const swapped = try f.draw();
    try testing.expectEqual(f.written().len, swapped.bytes);
    const placed = std.mem.indexOf(u8, f.written(), "a=p,q=2,i=7,p=1").?;
    const dropped = std.mem.indexOf(u8, f.written(), "a=d,q=2,d=i,i=6,p=1").?;
    const freed = std.mem.indexOf(u8, f.written(), "a=d,q=2,d=I,i=6").?;
    try testing.expect(placed < dropped and dropped < freed);
    try testing.expect(f.layers.image(6) == null);
    _ = try p.declare(&f.layers, at, 2100, 250);
    try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
    // Rotation skips the probe, even when it is not held by Layers.
    try testing.expectEqual(@as(u32, 9), (try p.send(&f.layers, &sink.writer, &ids, &pixels, .{})).id);
}

test "replacement grace, refusals and failed output leave another picture due" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var ids = try ImageIds.init(1, 5, 1);
    var p: Replacement = .{};
    var sink: Writer.Discarding = .init(&.{});
    const at: Layer = .{ .image = 0, .rect = .{ .cols = 2, .rows = 2 } };
    const pixels = [_]u8{0} ** 16;
    _ = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now_ms = 1000 });
    try testing.expect(try p.declare(&f.layers, at, 1249, 250));
    try testing.expect(!try p.declare(&f.layers, at, 1250, 250));
    _ = try f.draw();
    try testing.expectEqual(@as(u32, 1), f.layers._fallbacks);
    const next = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now_ms = 2000 });
    f.layers.ack(.{ .id = next.id, .message = "EBADPNG:bad" });
    _ = try p.declare(&f.layers, at, 2001, 250);
    try testing.expect(p.takeDirty());
    try testing.expect(!p.takeDirty());
    try testing.expectEqual(@as(?u32, 2), p.current());
    _ = try f.draw();
    try testing.expect(f.layers.image(next.id) == null);
    const retry = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now_ms = 3000 });
    f.layers.ack(.{ .id = retry.id, .message = "OK" });
    _ = try p.declare(&f.layers, at, 3001, 250);
    var no_room: [0]u8 = .{};
    var blocked: Writer = .fixed(&no_room);
    try testing.expectError(error.WriteFailed, f.renderer.draw(&blocked, &f.screen, &f.layers, f.caps));
    try testing.expect(f.layers.image(2) != null);
    _ = try f.draw();
    try testing.expect(f.layers.image(2) == null);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=p,q=2,i=4") != null);
    // A free itself can fail too; retirement and the image survive.
    try p.retire(&f.layers);
    _ = try f.layers.emit(&sink.writer, f.caps);
    try testing.expectError(error.WriteFailed, f.layers.commitFrame(&blocked, f.caps));
    try testing.expect(f.layers.image(4) != null);
    _ = try f.layers.commitFrame(&sink.writer, f.caps);
    try testing.expect(f.layers.image(4) == null);
}

test "image ids stay within their range and refuse exhaustion" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    try testing.expectError(error.InvalidIdRange, ImageIds.init(0, 3, 1));
    try testing.expectError(error.InvalidIdRange, ImageIds.init(3, 2, 1));
    var ids = try ImageIds.init(std.math.maxInt(u32) - 1, std.math.maxInt(u32), 1);
    const id = try ids.acquire(&l);
    try @import("layer.zig").test_access.record(&l, .{ .id = id });
    const next = try ids.acquire(&l);
    try @import("layer.zig").test_access.record(&l, .{ .id = next });
    try testing.expect(id != next);
    try testing.expectError(error.NoImageId, ids.acquire(&l));
}

test "a retired first picture is freed even when the frame has no text or placements" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var ids = try ImageIds.init(2, 5, 1);
    var p: Replacement = .{};
    var sink: Writer.Discarding = .init(&.{});
    const sent = try p.send(&f.layers, &sink.writer, &ids, "pixels", .{ .answer = true });
    f.layers.ack(.{ .id = sent.id, .message = "EBADPNG:bad" });
    _ = try p.declare(&f.layers, .{ .image = 0, .rect = .{ .cols = 2, .rows = 2 } }, 0, 250);
    try testing.expect(p.takeDirty());
    try testing.expectEqual(@as(usize, 0), f.layers.count());
    try testing.expectEqual(@as(usize, 0), f.layers._declared.items.len);
    try testing.expect(!f.screen._damage.any());
    const drawn = try f.draw();
    try testing.expect(f.layers.image(sent.id) == null);
    try testing.expectEqual(@as(u32, 1), drawn.placements);
    try testing.expectEqualStrings("\x1b_Ga=d,q=2,d=I,i=2\x1b\\", f.written());
    try testing.expectEqual(f.written().len, drawn.bytes);
    try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
}

test "shared memory reserves ownership before creating a name" {
    var fail = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var l: Layers = .init(fail.allocator());
    l.configureSharedMemory(testing.io);
    defer l.deinit();
    const before = shm.nextSequence();
    var buf: [256]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try testing.expectError(error.OutOfMemory, l.transmit(&out, 1, &.{ 1, 2, 3, 4 }, .{ .compress = false }));
    try testing.expectEqual(before, shm.nextSequence());
    try testing.expectEqual(@as(usize, 0), l._images.items.len);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "shared memory validates the protocol size before any ownership or output" {
    try testing.expectEqual(std.math.maxInt(u32), try @import("layer.zig").test_access.sharedSize(std.math.maxInt(u32)));
    if (@bitSizeOf(usize) <= 32) return error.SkipZigTest;
    const oversized: usize = @as(usize, std.math.maxInt(u32)) + 1;
    try testing.expectError(error.PayloadTooLarge, @import("layer.zig").test_access.sharedSize(oversized));
    var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var l: Layers = .init(fail.allocator());
    l.configureSharedMemory(testing.io);
    defer l.deinit();
    const before = shm.nextSequence();
    var out: Writer = .fixed(&.{});
    // Only the length may be inspected: there are no pixels behind this
    // pointer, and validation must precede any attempt to read or copy it.
    const pixels = @as([*]const u8, @ptrFromInt(1))[0..oversized];
    try testing.expectError(error.PayloadTooLarge, l.transmit(&out, 1, pixels, .{ .compress = false }));
    try testing.expectEqual(before, shm.nextSequence());
    try testing.expectEqual(@as(usize, 0), l._images.capacity);
}

test "shared memory keeps its cleanup owner when configuration is cleared" {
    if (!shm.supported) return error.SkipZigTest;
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(testing.io);
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 19, "data", .{ .width = 1, .height = 1 });
    const name = l.image(19).?.shm.?;
    defer shm.unlink(testing.io, name);
    l.configureSharedMemory(null);
    l.deinit();
    // Cleanup must have removed the object, regardless of current policy.
    try shm.put(testing.io, name, "data");
}

test "shared memory names belong to the process rather than each Layers" {
    if (!shm.supported) return error.SkipZigTest;
    var a: Layers = .init(testing.allocator);
    a.configureSharedMemory(testing.io);
    defer a.deinit();
    var b: Layers = .init(testing.allocator);
    b.configureSharedMemory(testing.io);
    defer b.deinit();
    var sink: Writer.Discarding = .init(&.{});
    _ = try a.transmit(&sink.writer, 1, "data", .{ .width = 1, .height = 1 });
    _ = try b.transmit(&sink.writer, 1, "data", .{ .width = 1, .height = 1 });
    const first = a.image(1).?.shm.?;
    try testing.expect(b.image(1).?.shm != null);
    const second = b.image(1).?.shm.?;
    try testing.expect(!std.mem.eql(u8, first.slice(), second.slice()));
    try testing.expectEqual(Image.State.loading, b.image(1).?.state);
}

test "shared memory reconfiguration cannot lose owners or accept an old policy reply" {
    if (!shm.supported) return error.SkipZigTest;
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    l.configureSharedMemory(testing.io);
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 1, "old!", .{ .width = 1, .height = 1 });
    const first = l.image(1).?.shm.?;
    defer shm.unlink(testing.io, first);
    l.configureSharedMemory(null);
    l.configureSharedMemory(testing.io);
    const generation = l._shared_memory.?.generation;
    _ = try l.transmit(&sink.writer, 2, "new!", .{ .width = 1, .height = 1 });
    const second = l.image(2).?.shm.?;
    defer shm.unlink(testing.io, second);
    l.ack(.{ .id = 1, .message = "EBADF:old configuration" });
    try testing.expect(l._shared_memory.?.state == .trying);
    try shm.put(testing.io, first, "gone");
    shm.unlink(testing.io, first);
    l.ack(.{ .id = 2, .message = "OK" });
    try testing.expect(l._shared_memory.?.state == .yes);
    l.configureSharedMemory(testing.io);
    try testing.expectEqual(generation, l._shared_memory.?.generation);
    try testing.expect(l._shared_memory.?.state == .yes);
    try shm.put(testing.io, second, "gone");
    shm.unlink(testing.io, second);
}

test "shared memory keeps ownership through every allocation and partial output failure" {
    if (!shm.supported) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var l: Layers = .init(gpa);
            l.configureSharedMemory(testing.io);
            var owned = true;
            defer if (owned) l.deinit();
            var out: Writer = .fixed(&.{});
            if (l.transmit(&out, 7, "data", .{ .width = 1, .height = 1 })) |_| return error.TestUnexpectedResult else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WriteFailed => {},
                else => return err,
            }
            const name = l.image(7).?.shm.?;
            defer shm.unlink(testing.io, name);
            try testing.expectEqual(@as(usize, 1), l._shared_objects.items.len);
            try testing.expect(l.image(7).?.state == .failed);
            try testing.expect(!l.ready(7, 1000, 10));
            l.configureSharedMemory(null);
            l.deinit();
            owned = false;
            try shm.put(testing.io, name, "gone");
        }
    }.run, .{});
}

test "direct transmission silence cannot make an unread shared picture ready" {
    if (!shm.supported) return error.SkipZigTest;
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 1, "png", .{ .format = .png, .answer = true });
    try testing.expect(l.ready(1, 10, 10));
    try testing.expectEqual(@as(?bool, false), l._answers);
    l.configureSharedMemory(testing.io);
    _ = try l.transmit(&sink.writer, 2, "data", .{ .width = 1, .height = 1, .now_ms = 10 });
    const name = l.image(2).?.shm.?;
    defer shm.unlink(testing.io, name);
    try testing.expect(!l.ready(2, 10, 10));
    try testing.expect(!l.ready(2, 20, 10));
    try testing.expectEqual(Image.State.failed, l.image(2).?.state);
    try testing.expect(l.image(2).?.shm == null);
    try shm.put(testing.io, name, "gone");
}

test "a picture placement spells the one-based u16 coordinate edge without overflow" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    const edge = std.math.maxInt(u16);
    try l.declare(.{ .image = 7, .rect = .{ .col = edge, .row = edge, .cols = 1, .rows = 1 } });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), try l.emit(&out.writer, .{ .kitty_graphics = true }));
    try testing.expect(std.mem.startsWith(u8, out.written(), "\x1b[65536;65536H"));
}

test "picture grace time spans the signed clock range" {
    var layers: Layers = .init(testing.allocator);
    defer layers.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try layers.transmit(&out.writer, 1, &.{ 1, 2, 3, 4 }, .{ .width = 1, .height = 1, .answer = true, .now_ms = std.math.minInt(i64) });
    try testing.expect(layers.ready(1, std.math.maxInt(i64), 50));
    layers._answers = null;
    _ = try layers.transmit(&out.writer, 2, &.{ 1, 2, 3, 4 }, .{ .width = 1, .height = 1, .answer = true, .now_ms = std.math.maxInt(i64) });
    try testing.expect(!layers.ready(2, std.math.minInt(i64), 50));
}

test "managed layers keep one allocator through pictures placements and retirement" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var layers = Layers.init(gpa);
            defer layers.deinit();
            var out: Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            var ids = try ImageIds.init(1, 4, 9);
            var replacement: Replacement = .{};
            const sent = try replacement.send(&layers, &out.writer, &ids, "rgba", .{ .width = 1, .height = 1 });
            try testing.expectEqual(@as(usize, 1), layers.images().len);
            _ = try replacement.declare(&layers, .{ .image = sent.id, .rect = .{ .cols = 1, .rows = 1 } }, 0, 1);
            try testing.expectEqual(@as(usize, 1), layers.declarations().len);
            _ = try layers.commitFrame(&out.writer, .{ .kitty_graphics = true });
            try replacement.retire(&layers);
            _ = try layers.commitFrame(&out.writer, .{ .kitty_graphics = true });
            try testing.expectEqual(@as(usize, 0), layers.images().len);
        }
    }.run, .{});
}

test "a replacement settles without declaring or hiding placements" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            var layers = Layers.init(gpa);
            defer layers.deinit();
            var ids = try ImageIds.init(2, 8, 1);
            var p: Replacement = .{};
            var sink = Writer.Discarding.init(&.{});
            const first = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true, .now_ms = 100 });
            try testing.expect(try p.settle(&layers, 109, 10));
            try testing.expect(!try p.settle(&layers, 110, 10));
            try testing.expectEqual(first.id, p.current().?);
            const at: Layer = .{ .image = first.id, .rect = .{ .cols = 1, .rows = 1 } };
            try layers.declare(at);
            const next = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true });
            layers.ack(.{ .id = next.id, .message = "refused" });
            try testing.expect(!try p.settle(&layers, 0, 10));
            try testing.expect(p.takeDirty());
            try testing.expectEqual(first.id, p.current().?);
            try testing.expectEqualDeep(at, layers.declarations()[0]);
            const last = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true });
            layers.ack(.{ .id = last.id, .message = "OK" });
            try testing.expect(!try p.settle(&layers, 0, 10));
            try testing.expectEqual(last.id, p.current().?);
            try testing.expectEqualDeep(at, layers.declarations()[0]);
            layers.ack(.{ .id = last.id, .message = "refused" });
            try testing.expect(!try p.settle(&layers, 0, 10));
            try testing.expectEqual(null, p.current());
            try testing.expect(p.takeDirty());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}

test "a late graphics answer cannot revive a failed transmission" {
    var l = Layers.init(testing.allocator);
    defer l.deinit();
    var blocked: Writer = .fixed(&.{});
    try testing.expectError(error.WriteFailed, l.transmit(&blocked, 7, "pixels", .{ .compress = false, .answer = true }));
    l.ack(.{ .id = 7, .message = "OK" });
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);
    try testing.expect(!l.ready(7, 1000, 10));
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 7, "pixels", .{ .compress = false, .answer = true });
    try testing.expectEqual(Image.State.loading, l.image(7).?.state);
    l.ack(.{ .id = 7, .message = "OK" });
    try testing.expect(l.ready(7, 1000, 10));
    // A terminal refusal also requires a new transmission before readiness.
    l.ack(.{ .id = 7, .message = "EBADPNG:bad data" });
    l.ack(.{ .id = 7, .message = "OK" });
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);
    try l.free(&sink.writer, 7);
    try testing.expect(l.image(7) == null);
}

test "failed direct transmission stays refused through grace and can be retried" {
    for ([_]bool{ false, true }) |answer| {
        for ([_]usize{ 0, 12 }) |prefix| {
            var layers: Layers = .init(testing.allocator);
            defer layers.deinit();
            var bytes: [12]u8 = undefined;
            var blocked: Writer = .fixed(bytes[0..prefix]);
            try testing.expectError(error.WriteFailed, layers.transmit(&blocked, 42, "rgba", .{ .answer = answer, .compress = false }));
            try testing.expect(layers.image(42) != null);
            try testing.expect(!layers.ready(42, 1000, 10));
            try testing.expect(layers.image(42).?.state == .failed);
            var sink: Writer.Discarding = .init(&.{});
            _ = try layers.transmit(&sink.writer, 42, "rgba", .{ .compress = false });
            try testing.expect(layers.ready(42, 1000, 10));
        }
    }
}

test "replacement ownership and refusal state stay behind their owner" {
    inline for (.{ "current", "pending", "dirty" }) |field| {
        try testing.expect(!@hasField(Replacement, field));
    }
}

test "image id bounds and allocation cursor stay behind their owner" {
    inline for (.{ "first", "last", "graphics_id", "next" }) |field| {
        try testing.expect(!@hasField(ImageIds, field));
    }
}
