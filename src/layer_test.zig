const std = @import("std");
const NoResize = @import("shakedown").alloc.NoResize;
const morse = @import("dependencies.zig").morse;
const geom = @import("geom.zig");
const Caps = @import("caps.zig").Caps;
const shm = @import("layer/shm.zig");
const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Writer = std.Io.Writer;
const under_base: i32 = -1_000_000;
const Image = @import("layer.zig").Image;
const Layer = @import("layer.zig").Layer;
const ImageIds = @import("layer.zig").ImageIds;
const Replacement = @import("layer.zig").Replacement;
const Layers = @import("layer.zig").Layers;
const layer_access = @import("layer.zig").test_access;
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
        r.shown = false;
        r.own_cursor = .{ .col = 0, .row = 0 };
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
        f.* = undefined;
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
    try testing.expect(std.mem.find(u8, bytes, "i=13") != null);
    try testing.expect(std.mem.find(u8, bytes, "a=p") != null);
    try testing.expect(std.mem.find(u8, bytes, "q=2") != null);
    try testing.expect(std.mem.find(u8, bytes, "C=1") != null);
    try testing.expect(std.mem.find(u8, bytes, "z=-1000000") != null);
    // Placed from the cell it belongs at.
    try testing.expect(std.mem.find(u8, bytes, "\x1b[2;3H") != null);
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
    try testing.expect(std.mem.find(u8, f.written(), "a=d") == null);
    try testing.expect(std.mem.find(u8, f.written(), "a=p") != null);
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
    try testing.expect(std.mem.find(u8, bytes, "a=d") != null);
    // The narrow form: this image, this placement, lowercase so the pixels
    // stay on the terminal.
    try testing.expect(std.mem.find(u8, bytes, "d=i") != null);
    try testing.expect(std.mem.find(u8, bytes, "i=5") != null);
    try testing.expect(std.mem.find(u8, bytes, "p=3") != null);
    try testing.expect(std.mem.find(u8, bytes, "d=I") == null);
    try testing.expect(std.mem.find(u8, bytes, "d=a") == null);
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
    try testing.expect(std.mem.find(u8, bytes, "a=p") != null);
    try testing.expect(std.mem.find(u8, bytes, "i=1") != null);
    try testing.expect(std.mem.find(u8, bytes, "a=d") != null);
    try testing.expect(std.mem.find(u8, bytes, "i=2") != null);

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
    const placed = std.mem.find(u8, bytes, "a=p,q=2,i=7").?;
    const dropped = std.mem.find(u8, bytes, "a=d,q=2,d=i,i=6").?;
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
    try testing.expect(std.mem.find(u8, bytes, "o=z") != null);
    try testing.expect(l.ready(9, ms(0), .fromMilliseconds(250)));
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
    try testing.expect(std.mem.find(u8, out.written(), "o=z") == null);
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
    while (std.mem.find(u8, rest, "\x1b_G")) |at| {
        const semi = std.mem.findScalarPos(u8, rest, at, ';').?;
        const end = std.mem.findPos(u8, rest, semi, "\x1b\\").?;
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

    _ = try l.transmit(&out.writer, 6, &px, .{ .width = 1, .height = 1, .answer = true, .now = ms(1000) });
    try testing.expect(std.mem.find(u8, out.written(), "q=") == null);
    try testing.expect(!l.ready(6, ms(1100), .fromMilliseconds(250)));
    l.ack(.{ .id = .fromRaw(6), .message = "OK" });
    try testing.expect(l.ready(6, ms(1101), .fromMilliseconds(250)));
    try testing.expectEqual(@as(?bool, true), l.answers);

    // A refusal: not ready, and the program sends again.
    _ = try l.transmit(&out.writer, 7, &px, .{ .width = 1, .height = 1, .answer = true, .now = ms(2000) });
    l.ack(.{ .id = .fromRaw(7), .message = "EBADPNG: bad data" });
    try testing.expect(!l.ready(7, ms(5000), .fromMilliseconds(250)));
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);

    // An answer about an id never sent here -- a probe's -- changes nothing.
    l.ack(.{ .id = .fromRaw(31), .message = "OK" });
    try testing.expect(l.image(31) == null);
}

test "a terminal that never answers is given the grace once, and then not waited for" {
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };

    _ = try l.transmit(&out.writer, 2, &px, .{ .width = 1, .height = 1, .answer = true, .now = ms(1000) });
    try testing.expect(!l.ready(2, ms(1249), .fromMilliseconds(250)));
    try testing.expect(l.ready(2, ms(1250), .fromMilliseconds(250)));
    try testing.expectEqual(@as(u32, 1), l.fallbacks);
    try testing.expectEqual(@as(?bool, false), l.answers);

    _ = try l.transmit(&out.writer, 3, &px, .{ .width = 1, .height = 1, .answer = true, .now = ms(2000) });
    try testing.expect(l.ready(3, ms(2000), .fromMilliseconds(250)));
    try testing.expectEqual(@as(u32, 1), l.fallbacks);
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
    try testing.expectEqual(@as(usize, 1), f.layers.own_images.items.len);
    try f.layers.declare(layer);
    const again = try f.draw();
    try testing.expectEqual(@as(u32, 1), again.placements);
    try testing.expect(std.mem.find(u8, f.written(), "a=p") != null);

    // Freed: the pixels and the placements, in one command the program
    // wrote, and nothing for the next frame to delete.
    sent.clearRetainingCapacity();
    try f.layers.deleteImage(&sent.writer, 8);
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
    try testing.expect(std.mem.find(u8, bytes, "i=16,p=9,X=6,Y=10,z=") != null);
    try testing.expect(std.mem.find(u8, bytes, "c=") == null);
    try testing.expect(std.mem.find(u8, bytes, "r=") == null);
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
    try testing.expectEqual(@as(usize, 4), l.own_images.items.len);
    try l.deleteAll(&out.writer);
    try testing.expectEqual(@as(usize, 0), l.own_images.items.len);
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
    const first = std.mem.find(u8, bytes, "i=1,").?;
    const second = std.mem.find(u8, bytes, "i=2,").?;
    try testing.expect(first < second);
    try testing.expect(std.mem.find(u8, bytes, "z=-1000000") != null);
    try testing.expect(std.mem.find(u8, bytes, "z=-999999") != null);
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
    try testing.expect(std.mem.find(u8, f.written(), "z=-") == null);
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
    try testing.expect(std.mem.find(u8, f.written(), "\x1b_G") == null);
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
    try testing.expect(std.mem.find(u8, f.written(), "\x1b_G") == null);
    try testing.expect(std.mem.find(u8, f.written(), "a=d") == null);
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
    try testing.expect(std.mem.find(u8, f.written(), "\x1b]8;") == null);
    for (0..3) |col| {
        try testing.expectEqual(l, f.screen.readCell(@intCast(col), 0).?.link);
    }

    // And a link differing only in its parameters is a different link.
    const other = try f.screen.link("https://ziglang.org", "id=2");
    try testing.expect(l != other);
    try f.screen.write(1, 0, "i", .{}, other);
    _ = try f.draw();
    try testing.expect(std.mem.find(u8, f.written(), "id=2") != null);
}

test "a program that asks for clicks gets clicks and no motion" {
    // Not this package's code, but this package's promise: a program that
    // asks for clicks gets clicks, and not a report for every cell the
    // pointer crosses.
    var buffer: [256]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.mouse(&out, .{ .motion = .press });
    const bytes = out.buffered();
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1000h") != null);
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1006h") != null);
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1002h") == null);
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1003h") == null);
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1002l") != null);
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?1003l") != null);
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
    const pixels = [_]u8{ 9, 8, 7, 6 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // tried, and read: the medium is on for good, the object gone
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(true);
    defer l.deinit();
    const n = try l.transmit(&out.writer, 5, &pixels, .{ .width = 1, .height = 1 });
    try testing.expect(std.mem.find(u8, out.written(), "t=s") != null);
    try testing.expect(std.mem.find(u8, out.written(), "S=4") != null);
    const name = l.image(5).?.shm.?;
    try testing.expectEqual(name.len, n);
    // on trial, the terminal is asked to answer even when the caller was not
    try testing.expect(!l.ready(5, ms(0), .fromMilliseconds(1000)));
    l.ack(.{ .id = .fromRaw(5), .message = "OK" });
    try testing.expect(l.ready(5, ms(0), .fromMilliseconds(1000)));
    try testing.expect(l.shared_memory.?.state == .yes);
    try testing.expect(l.image(5).?.shm == null);
    // the object was unlinked: its name can be put again
    try shm.put(name, &pixels);
    shm.unlink(name);
}

test "a terminal that cannot read shared memory gets the picture again in the escape code" {
    if (!shm.supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pixels = [_]u8{ 1, 2, 3, 4 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // refused: the medium is off, the picture failed and is sent again
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(true);
    defer l.deinit();
    _ = try l.transmit(&out.writer, 7, &pixels, .{ .width = 1, .height = 1 });
    l.ack(.{ .id = .fromRaw(7), .message = "EBADF:no such object" });
    try testing.expect(l.shared_memory.?.state == .no);
    try testing.expect(!l.ready(7, ms(0), .fromMilliseconds(1000)));
    out.clearRetainingCapacity();
    _ = try l.transmit(&out.writer, 7, &pixels, .{ .width = 1, .height = 1, .compress = false });
    try testing.expect(std.mem.find(u8, out.written(), "t=s") == null);
    try testing.expect(l.ready(7, ms(0), .fromMilliseconds(1000)));

    // silence: a terminal that never answers is not trusted with another
    var q: Layers = .init(testing.allocator);
    q.configureSharedMemory(true);
    defer q.deinit();
    _ = try q.transmit(&out.writer, 8, &pixels, .{ .width = 1, .height = 1, .now = ms(0) });
    try testing.expect(!q.ready(8, ms(10), .fromMilliseconds(1000)));
    try testing.expect(!q.ready(8, ms(2000), .fromMilliseconds(1000)));
    try testing.expect(q.shared_memory.?.state == .no);
    try testing.expect(q.image(8).?.shm == null);
}

test "a replacement lands over the old picture, placed before dropped before freed" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var ids = try ImageIds.init(6, 9, 8);
    var p: Replacement = .{};
    var sink: Writer.Discarding = .init(&.{});
    const pixels: [16]u8 = @splat(0);
    const at: Layer = .{ .image = 0, .rect = .{ .col = 2, .row = 1, .cols = 8, .rows = 4 } };
    const first = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .width = 2, .height = 2, .answer = true, .now = ms(1000) });
    try testing.expectEqual(@as(u32, 6), first.id);
    try testing.expect(!p.canSend());
    try testing.expectError(error.Busy, p.send(&f.layers, &sink.writer, &ids, &pixels, .{}));
    try testing.expect(try p.declare(&f.layers, at, ms(1016), .fromMilliseconds(250)));
    try testing.expectEqual(@as(u32, 0), (try f.draw()).placements);
    f.layers.ack(.{ .id = .fromRaw(first.id), .message = "OK" });
    try testing.expect(!try p.declare(&f.layers, at, ms(1033), .fromMilliseconds(250)));
    try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
    const next = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .width = 2, .height = 2, .answer = true, .now = ms(2000) });
    try testing.expectEqual(@as(u32, 7), next.id);
    try testing.expect(try p.declare(&f.layers, at, ms(2016), .fromMilliseconds(250)));
    try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
    f.layers.ack(.{ .id = .fromRaw(next.id), .message = "OK" });
    _ = try p.declare(&f.layers, at, ms(2041), .fromMilliseconds(250));
    const swapped = try f.draw();
    try testing.expectEqual(f.written().len, swapped.bytes);
    const placed = std.mem.find(u8, f.written(), "a=p,q=2,i=7,p=1").?;
    const dropped = std.mem.find(u8, f.written(), "a=d,q=2,d=i,i=6,p=1").?;
    const freed = std.mem.find(u8, f.written(), "a=d,q=2,d=I,i=6").?;
    try testing.expect(placed < dropped and dropped < freed);
    try testing.expect(f.layers.image(6) == null);
    _ = try p.declare(&f.layers, at, ms(2100), .fromMilliseconds(250));
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
    const pixels: [16]u8 = @splat(0);
    _ = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now = ms(1000) });
    try testing.expect(try p.declare(&f.layers, at, ms(1249), .fromMilliseconds(250)));
    try testing.expect(!try p.declare(&f.layers, at, ms(1250), .fromMilliseconds(250)));
    _ = try f.draw();
    try testing.expectEqual(@as(u32, 1), f.layers.fallbacks);
    const next = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now = ms(2000) });
    f.layers.ack(.{ .id = .fromRaw(next.id), .message = "EBADPNG:bad" });
    _ = try p.declare(&f.layers, at, ms(2001), .fromMilliseconds(250));
    try testing.expect(p.takeDirty());
    try testing.expect(!p.takeDirty());
    try testing.expectEqual(@as(?u32, 2), p.current());
    _ = try f.draw();
    try testing.expect(f.layers.image(next.id) == null);
    const retry = try p.send(&f.layers, &sink.writer, &ids, &pixels, .{ .answer = true, .now = ms(3000) });
    f.layers.ack(.{ .id = .fromRaw(retry.id), .message = "OK" });
    _ = try p.declare(&f.layers, at, ms(3001), .fromMilliseconds(250));
    var no_room: [0]u8 = .{};
    var blocked: Writer = .fixed(&no_room);
    try testing.expectError(error.WriteFailed, f.renderer.draw(&blocked, &f.screen, &f.layers, f.caps));
    try testing.expect(f.layers.image(2) != null);
    _ = try f.draw();
    try testing.expect(f.layers.image(2) == null);
    try testing.expect(std.mem.find(u8, f.written(), "a=p,q=2,i=4") != null);
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
    try layer_access.record(&l, .{ .id = id });
    const next = try ids.acquire(&l);
    try layer_access.record(&l, .{ .id = next });
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
    f.layers.ack(.{ .id = .fromRaw(sent.id), .message = "EBADPNG:bad" });
    _ = try p.declare(&f.layers, .{ .image = 0, .rect = .{ .cols = 2, .rows = 2 } }, ms(0), .fromMilliseconds(250));
    try testing.expect(p.takeDirty());
    try testing.expectEqual(@as(usize, 0), f.layers.count());
    try testing.expectEqual(@as(usize, 0), f.layers.declared.items.len);
    try testing.expect(!f.screen.damage.any());
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
    l.configureSharedMemory(true);
    defer l.deinit();
    const before = shm.nextSequence();
    var buf: [256]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try testing.expectError(error.OutOfMemory, l.transmit(&out, 1, &.{ 1, 2, 3, 4 }, .{ .compress = false }));
    try testing.expectEqual(before, shm.nextSequence());
    try testing.expectEqual(@as(usize, 0), l.own_images.items.len);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "shared memory validates the protocol size before any ownership or output" {
    try testing.expectEqual(std.math.maxInt(u32), try layer_access.sharedSize(std.math.maxInt(u32)));
    if (@bitSizeOf(usize) <= 32) return error.SkipZigTest;
    const oversized: usize = @as(usize, std.math.maxInt(u32)) + 1;
    try testing.expectError(error.PayloadTooLarge, layer_access.sharedSize(oversized));
    var fail = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var l: Layers = .init(fail.allocator());
    l.configureSharedMemory(true);
    defer l.deinit();
    const before = shm.nextSequence();
    var out: Writer = .fixed(&.{});
    // Only the length may be inspected: there are no pixels behind this
    // pointer, and validation must precede any attempt to read or copy it.
    const pixels = @as([*]const u8, @ptrFromInt(1))[0..oversized];
    try testing.expectError(error.PayloadTooLarge, l.transmit(&out, 1, pixels, .{ .compress = false }));
    try testing.expectEqual(before, shm.nextSequence());
    try testing.expectEqual(@as(usize, 0), l.own_images.capacity);
}

test "shared memory keeps its cleanup owner when configuration is cleared" {
    if (!shm.supported) return error.SkipZigTest;
    var l: Layers = .init(testing.allocator);
    l.configureSharedMemory(true);
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 19, "data", .{ .width = 1, .height = 1 });
    const name = l.image(19).?.shm.?;
    defer shm.unlink(name);
    l.configureSharedMemory(false);
    l.deinit();
    // Cleanup must have removed the object, regardless of current policy.
    try shm.put(name, "data");
}

test "shared memory names belong to the process rather than each Layers" {
    if (!shm.supported) return error.SkipZigTest;
    var a: Layers = .init(testing.allocator);
    a.configureSharedMemory(true);
    defer a.deinit();
    var b: Layers = .init(testing.allocator);
    b.configureSharedMemory(true);
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
    l.configureSharedMemory(true);
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 1, "old!", .{ .width = 1, .height = 1 });
    const first = l.image(1).?.shm.?;
    defer shm.unlink(first);
    l.configureSharedMemory(false);
    l.configureSharedMemory(true);
    const generation = l.shared_memory.?.generation;
    _ = try l.transmit(&sink.writer, 2, "new!", .{ .width = 1, .height = 1 });
    const second = l.image(2).?.shm.?;
    defer shm.unlink(second);
    l.ack(.{ .id = .fromRaw(1), .message = "EBADF:old configuration" });
    try testing.expect(l.shared_memory.?.state == .trying);
    try shm.put(first, "gone");
    shm.unlink(first);
    l.ack(.{ .id = .fromRaw(2), .message = "OK" });
    try testing.expect(l.shared_memory.?.state == .yes);
    l.configureSharedMemory(true);
    try testing.expectEqual(generation, l.shared_memory.?.generation);
    try testing.expect(l.shared_memory.?.state == .yes);
    try shm.put(second, "gone");
    shm.unlink(second);
}

test "shared memory keeps ownership through every allocation and partial output failure" {
    if (!shm.supported) return error.SkipZigTest;
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var l: Layers = .init(gpa);
            l.configureSharedMemory(true);
            var owned = true;
            defer if (owned) l.deinit();
            var out: Writer = .fixed(&.{});
            if (l.transmit(&out, 7, "data", .{ .width = 1, .height = 1 })) |_| return error.TestUnexpectedResult else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WriteFailed => {},
                else => return err,
            }
            const name = l.image(7).?.shm.?;
            defer shm.unlink(name);
            try testing.expectEqual(@as(usize, 1), l.shared_objects.items.len);
            try testing.expect(l.image(7).?.state == .failed);
            try testing.expect(!l.ready(7, ms(1000), .fromMilliseconds(10)));
            l.configureSharedMemory(false);
            l.deinit();
            owned = false;
            try shm.put(name, "gone");
        }
    }.run, .{});
}

test "direct transmission silence cannot make an unread shared picture ready" {
    if (!shm.supported) return error.SkipZigTest;
    var l: Layers = .init(testing.allocator);
    defer l.deinit();
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 1, "png", .{ .format = .png, .answer = true });
    try testing.expect(l.ready(1, ms(10), .fromMilliseconds(10)));
    try testing.expectEqual(@as(?bool, false), l.answers);
    l.configureSharedMemory(true);
    _ = try l.transmit(&sink.writer, 2, "data", .{ .width = 1, .height = 1, .now = ms(10) });
    const name = l.image(2).?.shm.?;
    defer shm.unlink(name);
    try testing.expect(!l.ready(2, ms(10), .fromMilliseconds(10)));
    try testing.expect(!l.ready(2, ms(20), .fromMilliseconds(10)));
    try testing.expectEqual(Image.State.failed, l.image(2).?.state);
    try testing.expect(l.image(2).?.shm == null);
    try shm.put(name, "gone");
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
    _ = try layers.transmit(&out.writer, 1, &.{ 1, 2, 3, 4 }, .{ .width = 1, .height = 1, .answer = true, .now = ms(std.math.minInt(i64)) });
    try testing.expect(layers.ready(1, ms(std.math.maxInt(i64)), .fromMilliseconds(50)));
    layers.answers = null;
    _ = try layers.transmit(&out.writer, 2, &.{ 1, 2, 3, 4 }, .{ .width = 1, .height = 1, .answer = true, .now = ms(std.math.maxInt(i64)) });
    try testing.expect(!layers.ready(2, ms(std.math.minInt(i64)), .fromMilliseconds(50)));
}

test "managed layers keep one allocator through pictures placements and retirement" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var layers = Layers.init(gpa);
            defer layers.deinit();
            var out: Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            var ids = try ImageIds.init(1, 4, 9);
            var replacement: Replacement = .{};
            const sent = try replacement.send(&layers, &out.writer, &ids, "rgba", .{ .width = 1, .height = 1 });
            try testing.expectEqual(@as(usize, 1), layers.images().len);
            _ = try replacement.declare(&layers, .{ .image = sent.id, .rect = .{ .cols = 1, .rows = 1 } }, ms(0), .fromMilliseconds(1));
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
            const first = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true, .now = ms(100) });
            try testing.expect(try p.settle(&layers, ms(109), .fromMilliseconds(10)));
            try testing.expect(!try p.settle(&layers, ms(110), .fromMilliseconds(10)));
            try testing.expectEqual(first.id, p.current().?);
            const at: Layer = .{ .image = first.id, .rect = .{ .cols = 1, .rows = 1 } };
            try layers.declare(at);
            const next = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true });
            layers.ack(.{ .id = .fromRaw(next.id), .message = "refused" });
            try testing.expect(!try p.settle(&layers, ms(0), .fromMilliseconds(10)));
            try testing.expect(p.takeDirty());
            try testing.expectEqual(first.id, p.current().?);
            try testing.expectEqualDeep(at, layers.declarations()[0]);
            const last = try p.send(&layers, &sink.writer, &ids, "rgba", .{ .answer = true });
            layers.ack(.{ .id = .fromRaw(last.id), .message = "OK" });
            try testing.expect(!try p.settle(&layers, ms(0), .fromMilliseconds(10)));
            try testing.expectEqual(last.id, p.current().?);
            try testing.expectEqualDeep(at, layers.declarations()[0]);
            layers.ack(.{ .id = .fromRaw(last.id), .message = "refused" });
            try testing.expect(!try p.settle(&layers, ms(0), .fromMilliseconds(10)));
            try testing.expectEqual(null, p.current());
            try testing.expect(p.takeDirty());
        }
    };
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{});
}

test "a late graphics answer cannot revive a failed transmission" {
    var l = Layers.init(testing.allocator);
    defer l.deinit();
    var blocked: Writer = .fixed(&.{});
    try testing.expectError(error.WriteFailed, l.transmit(&blocked, 7, "pixels", .{ .compress = false, .answer = true }));
    l.ack(.{ .id = .fromRaw(7), .message = "OK" });
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);
    try testing.expect(!l.ready(7, ms(1000), .fromMilliseconds(10)));
    var sink: Writer.Discarding = .init(&.{});
    _ = try l.transmit(&sink.writer, 7, "pixels", .{ .compress = false, .answer = true });
    try testing.expectEqual(Image.State.loading, l.image(7).?.state);
    l.ack(.{ .id = .fromRaw(7), .message = "OK" });
    try testing.expect(l.ready(7, ms(1000), .fromMilliseconds(10)));
    // A terminal refusal also requires a new transmission before readiness.
    l.ack(.{ .id = .fromRaw(7), .message = "EBADPNG:bad data" });
    l.ack(.{ .id = .fromRaw(7), .message = "OK" });
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);
    try l.deleteImage(&sink.writer, 7);
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
            try testing.expect(!layers.ready(42, ms(1000), .fromMilliseconds(10)));
            try testing.expect(layers.image(42).?.state == .failed);
            var sink: Writer.Discarding = .init(&.{});
            _ = try layers.transmit(&sink.writer, 42, "rgba", .{ .compress = false });
            try testing.expect(layers.ready(42, ms(1000), .fromMilliseconds(10)));
        }
    }
}

const inline_palette = [_]morse.Rgb{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 255, .g = 0, .b = 0 } };
const inline_pixels = [_]u8{ 1, 1, 1, 1 };

fn inlineFixture(protocol: Caps.Pictures) !Fixture {
    var f = try Fixture.init(testing.allocator, 8, 4);
    f.caps.picture_protocol = protocol;
    f.layers.configureSize(.{ .cells = .{ .cols = 8, .rows = 4 }, .cell = .{ .width = 1, .height = 1 } });
    if (protocol == .sixel) try f.layers.storeSixel(7, .{ .width = 2, .height = 2, .pixels = .{ .indexed = &inline_pixels }, .palette = &inline_palette }) else try f.layers.storeIterm(7, "PNG", 0);
    return f;
}

test "inline pictures redraw after text damage, moves, removals and repaint, but an identical frame writes nothing" {
    inline for (.{ Caps.Pictures.sixel, Caps.Pictures.iterm }) |protocol| {
        var f = try inlineFixture(protocol);
        defer f.deinit();
        var picture: Layer = .{ .image = 7, .rect = .{ .col = 1, .row = 0, .cols = 2, .rows = 2 } };
        try f.layers.declare(picture);
        try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
        const marker = if (protocol == .sixel) "\x1bP0;1;0q" else "\x1b]1337;File=";
        try testing.expect(std.mem.find(u8, f.written(), marker) != null);
        try f.layers.declare(picture);
        try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
        _ = try f.screen.write(0, 0, "x", .{}, .none);
        try f.layers.declare(picture);
        try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
        picture.rect.col = 3;
        try f.layers.declare(picture);
        try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
        try testing.expect(std.mem.find(u8, f.written(), "\x1b[1;4H") != null);
        try testing.expect((try f.draw()).bytes > 0);
        try testing.expect(std.mem.find(u8, f.written(), marker) == null);
        try testing.expectEqual(@as(usize, 0), f.layers.count());
        try f.layers.declare(picture);
        _ = try f.draw();
        f.renderer.repaint();
        try f.layers.declare(picture);
        try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
        try f.layers.retire(7);
        _ = try f.draw();
        try testing.expectEqual(@as(usize, 0), f.layers.images().len);
        try testing.expect(std.mem.find(u8, f.written(), "\x1b_G") == null);
    }
}

test "inline pictures golden bytes use morse's single writers with clipped cells and pixels" {
    var f = try inlineFixture(.sixel);
    defer f.deinit();
    try f.layers.declare(.{ .image = 7, .rect = .{ .col = 7, .row = 2, .cols = 2, .rows = 2 } });
    f.out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 1), try f.layers.emit(&f.out.writer, f.caps));
    try testing.expectEqualStrings("\x1b[3;8H\x1bP0;1;0q\"1;1;1;1#0;2;0;0;0#1;2;100;0;0#1@\x1b\\", f.written());
    _ = try f.layers.commitFrame(&f.out.writer, f.caps);
    try f.layers.storeIterm(7, "PNG", 0);
    f.caps.picture_protocol = .iterm;
    try f.layers.declare(.{ .image = 7, .rect = .{ .col = 7, .row = 2, .cols = 2, .rows = 2 } });
    f.out.clearRetainingCapacity();
    _ = try f.layers.emit(&f.out.writer, f.caps);
    try testing.expectEqualStrings("\x1b[3;8H\x1b]1337;File=size=3;width=1;height=2;preserveAspectRatio=0;inline=1;doNotMoveCursor=1:UE5H\x1b\\", f.written());
    try f.layers.storeIterm(7, "PNGmore", 3);
    f.out.clearRetainingCapacity();
    _ = try f.layers.emit(&f.out.writer, f.caps);
    try testing.expectEqualStrings("\x1b[3;8H\x1b]1337;MultipartFile=size=7;width=1;height=2;preserveAspectRatio=0;inline=1;doNotMoveCursor=1\x1b\\\x1b]1337;FilePart=UE5H\x1b\\\x1b]1337;FilePart=bW9y\x1b\\\x1b]1337;FilePart=ZQ==\x1b\\\x1b]1337;FileEnd\x1b\\", f.written());
}

test "inline pictures reject malformed pixels before replacing a usable image" {
    var f = try inlineFixture(.sixel);
    defer f.deinit();
    try testing.expectError(error.InvalidImage, f.layers.storeSixel(7, .{ .width = 3, .height = 2, .pixels = .{ .indexed = &inline_pixels }, .palette = &inline_palette }));
    try testing.expectError(error.InvalidImage, f.layers.storeSixel(7, .{ .width = 1, .height = 1, .pixels = .{ .indexed = &.{2} }, .palette = &inline_palette }));
    try testing.expectEqual(@as(u32, 2), f.layers.image(7).?.width);
}

test "inline pictures recover after a refused frame and restore the screen cursor" {
    inline for (.{ Caps.Pictures.sixel, Caps.Pictures.iterm }) |protocol| {
        var f = try inlineFixture(protocol);
        defer f.deinit();
        const picture: Layer = .{ .image = 7, .rect = .{ .col = 1, .row = 0, .cols = 2, .rows = 2 } };
        try f.layers.declare(picture);
        var blocked: Writer = .failing;
        try testing.expectError(error.WriteFailed, f.renderer.draw(&blocked, &f.screen, &f.layers, f.caps));
        try testing.expectEqual(@as(usize, 0), f.layers.count());
        try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
        try f.layers.declare(picture);
        try testing.expectEqual(@as(usize, 0), (try f.draw()).bytes);
        f.caps.picture_protocol = .cells;
        try f.layers.declare(picture);
        try testing.expect((try f.draw()).bytes > 0);
        try testing.expectEqual(@as(usize, 0), f.layers.count());
    }
}

test "inline pictures use source cropping, probe geometry and palette limits" {
    var f = try inlineFixture(.sixel);
    defer f.deinit();
    f.caps.sixel_max_width = 1;
    f.caps.sixel_max_height = 1;
    f.caps.sixel_registers = 1;
    try f.layers.declare(.{ .image = 7, .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 }, .source = .{ .x = .fromRaw(1), .y = .fromRaw(1), .width = .fromRaw(1), .height = .fromRaw(1) } });
    _ = try f.draw();
    try testing.expect(std.mem.find(u8, f.written(), "q\"1;1;1;1#0;2;0;0;0#0@") != null);
    f.layers.configureSize(.{ .cells = .{ .cols = 8, .rows = 4 } });
    try f.layers.declare(.{ .image = 7, .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 } });
    try testing.expectEqual(@as(u32, 0), (try f.draw()).placements);
}

test "inline pictures cursor-right mode is enabled on entry and undone on leave" {
    var f = try inlineFixture(.sixel);
    defer f.deinit();
    f.caps.sixel_cursor_right = true;
    try f.renderer.enter(&f.out.writer, f.caps, .alt, .{});
    try testing.expect(std.mem.find(u8, f.written(), "\x1b[?8452h") != null);
    try f.layers.declare(.{ .image = 7, .rect = .{ .col = 0, .row = 3, .cols = 2, .rows = 1 } });
    try testing.expectEqual(@as(u32, 1), (try f.draw()).placements);
    try f.renderer.leave(&f.out.writer);
    try testing.expect(std.mem.find(u8, f.written(), "\x1b[?8452l") != null);
}

fn retainInlineImages(gpa: Allocator) !void {
    var layers: Layers = .init(gpa);
    defer layers.deinit();
    try layers.storeSixel(7, .{ .width = 2, .height = 2, .pixels = .{ .indexed = &inline_pixels }, .palette = &inline_palette });
    try layers.storeIterm(7, "PNG", 3);
    try layers.storeIterm(8, "PNG", 0);
}

test "inline pictures retain and replace transactionally at every allocation failure" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), retainInlineImages, .{});
}

/// A test's clock reading, in milliseconds.
fn ms(n: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_ms };
}
