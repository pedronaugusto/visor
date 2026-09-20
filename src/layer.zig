//! Pictures under and over the text.
//!
//! An image is bytes the terminal was sent; a layer is one placement of one
//! image, at a rectangle of cells, in a stack. The text pass never writes a
//! graphics command and never deletes a placement: that is a rule of this
//! package, not an implementation detail, and it has a test. It exists
//! because the usual answer — delete every placement at the start of every
//! frame that changed a cell — makes a picture flicker or vanish whenever
//! anything near it is redrawn.
//!
//! A layer that moves or resizes is **re-placed**, not deleted and placed
//! again: the protocol says a second placement with the same image and
//! placement id replaces the first without flicker. Deletion fires only when
//! a layer genuinely leaves the frame, and then names that one placement
//! rather than everything on screen.
//!
//! Nothing here waits for the terminal. An image is placed by the number the
//! program chose, which needs no round trip; the acknowledgement, when it
//! comes, upgrades the number to the id the terminal assigned and is
//! otherwise ignored. A renderer that told the terminal to stay quiet would
//! otherwise wait for a reply that is never coming.
//!
//! What this file will never hold: an encoder, a decoder, a file format, or
//! a timer. The bytes of an image are the caller's; `morse.transmitImage`
//! writes them.

const std = @import("std");
const morse = @import("morse");

const geom = @import("geom.zig");
const Caps = @import("caps.zig").Caps;

const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Writer = std.Io.Writer;

/// Bytes the terminal was sent: what the program calls it, what the terminal
/// calls it, and how big it is.
pub const Image = struct {
    /// The number the program chose, the protocol's `I=`. A placement names
    /// this, so nothing has to wait for the terminal to answer.
    number: u32,
    /// The id the terminal assigned, once it has said so. Zero until then.
    id: u32 = 0,
    /// How wide the image is, in pixels.
    width: u32 = 0,
    /// How tall it is, in pixels.
    height: u32 = 0,
    /// Whether the terminal has answered for it, and said yes.
    acked: bool = false,

    /// Which image a command should name: the id when the terminal has told
    /// us one, and the number until then.
    pub fn handle(image: Image) morse.GraphicsImage {
        return if (image.id != 0) .{ .id = image.id } else .{ .number = image.number };
    }
};

/// A picture on the screen.
pub const Layer = struct {
    /// Which image, by the number the program chose.
    image: u32,
    /// Which placement of it. Two layers of the same image need two of
    /// these; re-declaring the same pair moves the picture rather than
    /// making a second one.
    placement: u32 = 1,
    /// Where on the grid, in cells.
    rect: Rect,
    /// The part of the image to show, in pixels. All zero shows all of it.
    source: morse.GraphicsRect = .{},
    /// How far into the first cell the image starts, in pixels.
    x_offset: u32 = 0,
    /// The same vertically.
    y_offset: u32 = 0,
    /// Whether the picture goes under the text or over it.
    under: bool = true,
    /// Where in the stack, compared lexicographically so a nested layer
    /// never escapes its parent's place in it.
    order: Order = .{},

    /// Where a layer sits in the stack.
    ///
    /// A tuple rather than one number, compared left to right, so a program
    /// with a tree of panels can give each level its own key and a child can
    /// never be sorted out from under its parent. The terminal takes one
    /// integer, and the sorted position is what becomes it.
    pub const Order = struct {
        /// The outermost key: which named layer this belongs to.
        layer: i32 = 0,
        /// Within it, the depth.
        z: i32 = 0,
        /// Within that, the order among siblings.
        sibling: i32 = 0,

        /// Whether `a` is painted before `b`.
        pub fn before(a: Order, b: Order) bool {
            if (a.layer != b.layer) return a.layer < b.layer;
            if (a.z != b.z) return a.z < b.z;
            return a.sibling < b.sibling;
        }
    };

    /// Whether two layers name the same placement of the same image.
    pub fn sameAs(a: Layer, b: Layer) bool {
        return a.image == b.image and a.placement == b.placement;
    }

    /// Whether the terminal would draw the two the same way.
    pub fn eql(a: Layer, b: Layer) bool {
        return a.sameAs(b) and
            std.meta.eql(a.rect, b.rect) and
            std.meta.eql(a.source, b.source) and
            a.x_offset == b.x_offset and
            a.y_offset == b.y_offset and
            a.under == b.under and
            std.meta.eql(a.order, b.order);
    }
};

/// The z the terminal is given for a layer under the text.
///
/// Below zero is under the text; the sorted position is added, so the
/// stacking order the `Order` tuples give survives into the one integer the
/// protocol takes.
const under_base: i32 = -1_000_000;

/// What this frame shows.
pub const Layers = struct {
    /// The images the program has sent, by number.
    images: std.ArrayList(Image) = .empty,
    /// What this frame has declared, in declaration order.
    declared: std.ArrayList(Layer) = .empty,
    /// What the terminal is showing, after the last `emit`.
    shown: std.ArrayList(Layer) = .empty,
    /// Where each shown layer was in the stack, so a re-place is only
    /// written when something really moved.
    dirty: bool = false,

    /// Gives the lists back.
    pub fn deinit(l: *Layers, gpa: Allocator) void {
        l.images.deinit(gpa);
        l.declared.deinit(gpa);
        l.shown.deinit(gpa);
        l.* = .{};
    }

    /// Records an image the program has sent, or updates one it had.
    pub fn declareImage(l: *Layers, gpa: Allocator, sent: Image) Allocator.Error!void {
        for (l.images.items) |*held| {
            if (held.number != sent.number) continue;
            const id = held.id;
            const acked = held.acked;
            held.* = sent;
            if (held.id == 0) held.id = id;
            if (!held.acked) held.acked = acked;
            return;
        }
        try l.images.append(gpa, sent);
    }

    /// What the program knows about an image, or null.
    pub fn image(l: *const Layers, number: u32) ?Image {
        for (l.images.items) |held| {
            if (held.number == number) return held;
        }
        return null;
    }

    /// Shows a layer this frame.
    ///
    /// Declaring the same image and placement twice in a frame keeps the
    /// second: that is how a picture is moved, and it costs one command
    /// rather than a delete and a place.
    pub fn declare(l: *Layers, gpa: Allocator, layer: Layer) Allocator.Error!void {
        for (l.declared.items) |*held| {
            if (held.sameAs(layer)) {
                held.* = layer;
                return;
            }
        }
        try l.declared.append(gpa, layer);
    }

    /// Takes a layer off the frame it would otherwise still be in.
    pub fn undeclare(l: *Layers, image_number: u32, placement: u32) void {
        var i: usize = 0;
        while (i < l.declared.items.len) : (i += 1) {
            const held = l.declared.items[i];
            if (held.image == image_number and held.placement == placement) {
                _ = l.declared.orderedRemove(i);
                return;
            }
        }
    }

    /// The terminal answered about an image.
    ///
    /// This is how a number becomes an id, and nothing else depends on it:
    /// a placement is written the moment it is declared, because a program
    /// that also asked the terminal to stay quiet would wait here forever.
    pub fn ack(l: *Layers, response: morse.GraphicsResponse) void {
        const number = response.number orelse return;
        for (l.images.items) |*held| {
            if (held.number != number) continue;
            held.acked = response.ok();
            if (response.id) |id| held.id = id;
            return;
        }
    }

    /// The placements and the deletions, after the text pass, in one block.
    ///
    /// Writes nothing when nothing moved, so a caller may call it twice and
    /// a renderer that calls it for them costs nothing.
    pub fn emit(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        if (!caps.kitty_graphics) return 0;
        std.mem.sort(Layer, l.declared.items, {}, lessThan);
        var written: usize = 0;

        // Gone: name the one placement rather than everything on screen, and
        // keep the image data, because the program may show it again.
        for (l.shown.items) |was| {
            if (findSame(l.declared.items, was) != null) continue;
            try l.writeDelete(w, was);
            written += 1;
        }
        // Here: a placement command, which replaces whatever was at the same
        // image and placement id without flicker.
        for (l.declared.items, 0..) |now, i| {
            if (findSameIndex(l.shown.items, now)) |before_i| {
                const before = l.shown.items[before_i];
                if (before.eql(now) and zOf(now, i) == zOf(before, before_i)) continue;
            }
            try l.writePlace(w, now, zOf(now, i));
            written += 1;
        }

        return written;
    }

    /// Commits the declarations after the caller accepted the complete
    /// frame. Kept separate from `emit` so a failed output write can retry
    /// both placements and deletions unchanged.
    pub fn commitFrame(l: *Layers, caps: Caps) void {
        if (!caps.kitty_graphics) {
            l.declared.clearRetainingCapacity();
            return;
        }
        const was_shown = l.shown;
        l.shown = l.declared;
        l.declared = was_shown;
        l.declared.clearRetainingCapacity();
    }

    /// Takes every placement off the screen. What a program writes on the
    /// way out, when there is nobody left to read an answer.
    pub fn clear(l: *Layers, w: *Writer, caps: Caps) Writer.Error!void {
        if (!caps.kitty_graphics) return;
        for (l.shown.items) |was| try l.writeDelete(w, was);
        l.shown.clearRetainingCapacity();
        l.declared.clearRetainingCapacity();
    }

    /// How many layers the terminal is showing.
    pub fn count(l: *const Layers) usize {
        return l.shown.items.len;
    }

    //=====================================================================
    // The commands.
    //=====================================================================

    /// One placement, drawn from the cell it is put at.
    fn writePlace(l: *const Layers, w: *Writer, layer: Layer, z: i32) Writer.Error!void {
        const handle: morse.GraphicsImage = if (l.image(layer.image)) |held|
            held.handle()
        else
            .{ .number = layer.image };
        try morse.cursorTo(w, layer.rect.row + 1, layer.rect.col + 1);
        try morse.placeImage(w, .{
            .image = handle,
            .quiet = .silent,
            .placement = .{
                .id = layer.placement,
                .source = layer.source,
                .x_offset = layer.x_offset,
                .y_offset = layer.y_offset,
                .columns = layer.rect.cols,
                .rows = layer.rect.rows,
                .z = z,
                // The text pass owns the cursor, so a placement must leave
                // it exactly where it found it.
                .keep_cursor = true,
            },
        });
    }

    /// One placement gone, named as narrowly as the protocol allows, and
    /// with the image's bytes kept.
    fn writeDelete(l: *const Layers, w: *Writer, layer: Layer) Writer.Error!void {
        const target: morse.DeleteTarget = if (l.image(layer.image)) |held| blk: {
            if (held.id != 0) break :blk .{ .image = .{ .id = held.id, .placement = layer.placement } };
            break :blk .{ .number = .{ .number = held.number, .placement = layer.placement } };
        } else .{ .number = .{ .number = layer.image, .placement = layer.placement } };
        try morse.deleteImage(w, .{ .target = target, .free = false, .quiet = .silent });
    }
};

/// The single integer the protocol takes, from the tuple that was sorted.
fn zOf(layer: Layer, position: usize) i32 {
    const step: i32 = @intCast(@min(position, 1_000_000));
    return if (layer.under) under_base + step else step;
}

/// The stacking order, for the sort.
fn lessThan(_: void, a: Layer, b: Layer) bool {
    if (a.under != b.under) return a.under and !b.under;
    return Layer.Order.before(a.order, b.order);
}

/// The layer in `list` naming the same placement of the same image.
fn findSame(list: []const Layer, layer: Layer) ?Layer {
    for (list) |held| {
        if (held.sameAs(layer)) return held;
    }
    return null;
}

fn findSameIndex(list: []const Layer, layer: Layer) ?usize {
    for (list, 0..) |held, i| {
        if (held.sameAs(layer)) return i;
    }
    return null;
}

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

    fn init(gpa: Allocator, cols: u16, rows: u16) !Fixture {
        const size: geom.Size = .{ .cols = cols, .rows = rows };
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit(gpa);
        s.method = .unicode;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit(gpa);
        r.shown = false;
        r.cursor = .{ .col = 0, .row = 0 };
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{ .width_method = .unicode, .osc8 = true, .kitty_graphics = true },
        };
    }

    fn deinit(f: *Fixture) void {
        f.screen.deinit(f.gpa);
        f.renderer.deinit(f.gpa);
        f.out.deinit();
    }

    fn draw(f: *Fixture) !Renderer.Stats {
        f.out.clearRetainingCapacity();
        return f.renderer.draw(&f.out.writer, &f.screen, f.caps);
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

test "a layer is placed by the number the program chose, with no round trip" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.screen.layers.declareImage(testing.allocator, .{ .number = 13, .width = 64, .height = 64 });
    try f.screen.layers.declare(testing.allocator, .{
        .image = 13,
        .rect = .{ .col = 2, .row = 1, .cols = 8, .rows = 4 },
    });
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 1), stats.placements);
    const bytes = f.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "I=13") != null);
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
    try f.screen.layers.declare(testing.allocator, layer);
    _ = try f.draw();
    try f.screen.layers.declare(testing.allocator, layer);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 0), stats.placements);
    try testing.expectEqual(@as(usize, 0), stats.bytes);
}

test "a layer that moved is replaced rather than deleted and placed again" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.screen.layers.declare(testing.allocator, .{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 },
    });
    _ = try f.draw();
    try f.screen.layers.declare(testing.allocator, .{
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

    try f.screen.layers.declareImage(testing.allocator, .{ .number = 5 });
    try f.screen.layers.declare(testing.allocator, .{
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
    try testing.expect(std.mem.indexOf(u8, bytes, "d=n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "I=5") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "p=3") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=N") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=a") == null);
}

test "an acknowledgement upgrades a number to an id and holds nothing up" {
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    try l.declareImage(testing.allocator, .{ .number = 7 });
    try testing.expectEqual(@as(u32, 0), l.image(7).?.id);
    try testing.expect(!l.image(7).?.acked);

    l.ack(.{ .number = 7, .id = 99, .message = "OK" });
    try testing.expectEqual(@as(u32, 99), l.image(7).?.id);
    try testing.expect(l.image(7).?.acked);

    // And a refusal is recorded without taking the id away.
    l.ack(.{ .number = 7, .id = 99, .message = "ENOENT: no such file" });
    try testing.expect(!l.image(7).?.acked);
}

test "once the terminal has named an image, commands name it too" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    try f.screen.layers.declareImage(testing.allocator, .{ .number = 7 });
    f.screen.layers.ack(.{ .number = 7, .id = 99, .message = "OK" });
    try f.screen.layers.declare(testing.allocator, .{
        .image = 7,
        .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 },
    });
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "i=99") != null);
    try testing.expect(std.mem.indexOf(u8, f.written(), "I=7") == null);
}

test "layers are stacked in the order their tuples give" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.screen.layers.declare(testing.allocator, .{
        .image = 2,
        .rect = .{ .col = 0, .row = 0, .cols = 2, .rows = 2 },
        .order = .{ .layer = 1 },
    });
    try f.screen.layers.declare(testing.allocator, .{
        .image = 1,
        .rect = .{ .col = 4, .row = 0, .cols = 2, .rows = 2 },
        .order = .{ .layer = 0 },
    });
    _ = try f.draw();
    const bytes = f.written();
    const first = std.mem.indexOf(u8, bytes, "I=1").?;
    const second = std.mem.indexOf(u8, bytes, "I=2").?;
    try testing.expect(first < second);
    try testing.expect(std.mem.indexOf(u8, bytes, "z=-1000000") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "z=-999999") != null);
}

test "inserting a layer re-places unchanged layers at their new z positions" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    const a: Layer = .{ .image = 1, .rect = .{ .cols = 2, .rows = 2 }, .order = .{ .layer = 1 } };
    const b: Layer = .{ .image = 2, .rect = .{ .col = 3, .cols = 2, .rows = 2 }, .order = .{ .layer = 2 } };
    try f.screen.layers.declare(testing.allocator, a);
    try f.screen.layers.declare(testing.allocator, b);
    _ = try f.draw();

    try f.screen.layers.declare(testing.allocator, .{
        .image = 3,
        .rect = .{ .col = 6, .cols = 2, .rows = 2 },
        .order = .{ .layer = 0 },
    });
    try f.screen.layers.declare(testing.allocator, a);
    try f.screen.layers.declare(testing.allocator, b);
    const stats = try f.draw();
    try testing.expectEqual(@as(u32, 3), stats.placements);
}

test "a layer over the text gets a z at or above zero" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    try f.screen.layers.declare(testing.allocator, .{
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
    try f.screen.layers.declare(testing.allocator, .{
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

    try f.screen.layers.declare(testing.allocator, .{
        .image = 1,
        .rect = .{ .col = 0, .row = 0, .cols = 8, .rows = 4 },
    });
    try f.screen.write(0, 5, "a", .{}, .none);
    _ = try f.draw();

    // A frame in which one cell changed and the picture did not.
    try f.screen.layers.declare(testing.allocator, .{
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

    const l = try f.screen.link(testing.allocator, "https://ziglang.org", "id=1");
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
    const other = try f.screen.link(testing.allocator, "https://ziglang.org", "id=2");
    try testing.expect(l != other);
    try f.screen.write(1, 0, "i", .{}, other);
    _ = try f.draw();
    try testing.expect(std.mem.indexOf(u8, f.written(), "id=2") != null);
}

test "the mouse modes are switchable one by one" {
    // Not this package's code, but this package's promise: a program that
    // asks for clicks gets clicks, and not a report for every cell the
    // pointer crosses.
    var buffer: [256]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.mouse(&out, .{ .press = true, .sgr = true });
    const bytes = out.buffered();
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1000h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002h") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003h") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002l") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1003l") != null);
}
