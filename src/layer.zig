//! Pictures under and over the text, from the bytes sent to the placement
//! taken away.
//!
//! An image is pixels the terminal was sent under an id the program chose; a
//! layer is one placement of one image, at a rectangle of cells, in a stack.
//! `Layers` owns the whole of an image's life — sending it, placing it,
//! moving it, taking it away and freeing it — so a program never writes a
//! graphics command itself.
//!
//! The text pass never writes a graphics command and never deletes a
//! placement: that is a rule of this package, not an implementation detail,
//! and it has a test. It exists because the usual answer — delete every
//! placement at the start of every frame that changed a cell — makes a
//! picture flicker or vanish whenever anything near it is redrawn.
//!
//! A layer that moves or resizes is **re-placed**, not deleted and placed
//! again: the protocol says a second placement with the same image and
//! placement id replaces the first without flicker. A layer that leaves is
//! deleted by name, and after the frame's placements, so a picture swapped
//! for another is never a gap.
//!
//! Nothing here waits for the terminal. An image sent quietly is ready at
//! once; one sent asking for an answer is ready when the answer comes, or
//! when the caller's grace period runs out, and a terminal that has never
//! answered is not waited for again. The time is always the caller's.
//!
//! What this file will never hold: an image decoder, a file format, or a
//! clock.

const std = @import("std");
const morse = @import("morse");

const geom = @import("geom.zig");
const Caps = @import("caps.zig").Caps;

const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Writer = std.Io.Writer;

/// Pixels the terminal was sent, under the id the program chose.
pub const Image = struct {
    /// The id, the protocol's `i=`. The program chooses it, so a program
    /// sharing the terminal's image space with nothing else can name its
    /// pictures without a round trip, and a question it asks the terminal
    /// about graphics (`Caps.Probe.graphics_id`) can use one it never sends
    /// a picture under.
    id: u32,
    /// How wide the image is, in pixels.
    width: u32 = 0,
    /// How tall it is, in pixels.
    height: u32 = 0,
    /// Whether the terminal has it.
    state: State = .ready,
    /// When it was sent, on the caller's clock, in milliseconds.
    sent_ms: i64 = 0,

    /// Whether the terminal has an image.
    pub const State = enum {
        /// Sent asking for an answer, and none has come.
        loading,
        /// The terminal has it: it said so, it was sent quietly, or the
        /// caller's grace period ran out.
        ready,
        /// The terminal refused it. Send it again.
        failed,
    };
};

/// A picture on the screen.
pub const Layer = struct {
    /// Which image, by its id.
    image: u32,
    /// Which placement of it. Two layers of the same image need two of
    /// these; re-declaring the same pair moves the picture rather than
    /// making a second one.
    placement: u32 = 1,
    /// Where on the grid, in cells. A zero width and height draws the image
    /// at its own size from the top-left cell.
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

/// How an image is sent.
pub const Transmit = struct {
    /// The shape of the bytes: RGBA, RGB or PNG.
    format: morse.GraphicsFormat = .rgba,
    /// How wide, in pixels. Required for RGBA and RGB.
    width: u32 = 0,
    /// How tall, in pixels.
    height: u32 = 0,
    /// Deflate the pixels before they go, and send them compressed when that
    /// made them smaller. A dark, sparse picture deflates to a few per cent
    /// of its size; a PNG is compressed already and is sent as it is.
    compress: bool = true,
    /// Ask the terminal to say when it has the image, so `ready` can wait
    /// for the word rather than assume it. Off, the image is sent quietly
    /// and is ready at once.
    answer: bool = false,
    /// The caller's clock, in milliseconds, for `ready`'s grace period.
    now_ms: i64 = 0,
};

/// The z the terminal is given for a layer under the text.
///
/// Below zero is under the text; the sorted position is added, so the
/// stacking order the `Order` tuples give survives into the one integer the
/// protocol takes.
const under_base: i32 = -1_000_000;

/// The images this program has sent, and what this frame shows of them.
pub const Layers = struct {
    /// The images the terminal holds for this program, one per id. Sending
    /// to an id replaces its entry and freeing one removes it, so the list
    /// is as long as the pictures that are alive.
    images: std.ArrayList(Image) = .empty,
    /// What this frame has declared, in declaration order.
    declared: std.ArrayList(Layer) = .empty,
    /// What the terminal is showing, after the last `emit`.
    shown: std.ArrayList(Layer) = .empty,
    /// Whether this terminal answers a transmit: unknown until the first
    /// answer (true), or until a grace period runs out with no answer ever
    /// (false), after which nothing is waited for.
    answers: ?bool = null,
    /// How many images were taken as ready because the grace period ran
    /// out rather than because the terminal said so.
    fallbacks: u32 = 0,
    /// The deflate window, made the first time a picture is compressed and
    /// kept for the next.
    window: []u8 = &.{},

    /// Gives the lists and the window back.
    pub fn deinit(l: *Layers, gpa: Allocator) void {
        l.images.deinit(gpa);
        l.declared.deinit(gpa);
        l.shown.deinit(gpa);
        gpa.free(l.window);
        l.* = .{};
    }

    /// What the program knows about an image, or null.
    pub fn image(l: *const Layers, id: u32) ?Image {
        return (l.find(id) orelse return null).*;
    }

    fn find(l: *const Layers, id: u32) ?*Image {
        for (l.images.items) |*held| {
            if (held.id == id) return held;
        }
        return null;
    }

    /// Sends an image under `id`, chunked, deflated when that helps, and
    /// quiet unless an answer was asked for. Returns how many bytes of
    /// pixels went, after compression and before base64.
    ///
    /// Sending to an id the terminal is showing replaces the pixels, and the
    /// terminal drops that image's placements while they land; the next
    /// frame places them again. A picture replaced without a gap goes to a
    /// second id instead, and the layer is declared with that one once
    /// `ready` says so: the old placement is deleted after the new one is
    /// made.
    ///
    /// Written to `w` directly and not through a frame, so the caller sends
    /// before it draws.
    pub fn transmit(
        l: *Layers,
        gpa: Allocator,
        w: *Writer,
        id: u32,
        pixels: []const u8,
        how: Transmit,
    ) (Writer.Error || Allocator.Error)!usize {
        var packed_pixels: std.Io.Writer.Allocating = .init(gpa);
        defer packed_pixels.deinit();
        var payload = pixels;
        var compressed = false;
        if (how.compress and how.format != .png and pixels.len > 64) {
            if (l.window.len == 0) l.window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            try packed_pixels.ensureTotalCapacity(pixels.len / 8 + 1024);
            var deflate = std.compress.flate.Compress.init(
                &packed_pixels.writer,
                l.window,
                .zlib,
                .fastest,
            ) catch return error.OutOfMemory;
            deflate.writer.writeAll(pixels) catch return error.OutOfMemory;
            deflate.finish() catch return error.OutOfMemory;
            if (packed_pixels.written().len < pixels.len) {
                payload = packed_pixels.written();
                compressed = true;
            }
        }

        // Record first: a write that fails part way has still told the
        // terminal something, and the record is what makes it freeable.
        const record: Image = .{
            .id = id,
            .width = how.width,
            .height = how.height,
            .state = if (how.answer) .loading else .ready,
            .sent_ms = how.now_ms,
        };
        if (l.find(id)) |held| held.* = record else try l.images.append(gpa, record);
        // The terminal takes this image's placements down while it lands.
        l.forgetShown(id);

        try morse.transmitImage(w, .{
            .image = .{ .id = id },
            .format = how.format,
            .width = how.width,
            .height = how.height,
            .compressed = compressed,
            .quiet = if (how.answer) .answers else .silent,
        }, payload);
        return payload.len;
    }

    /// Whether the terminal has the image, so a layer can show it.
    ///
    /// An image sent quietly is ready at once. One sent asking for an answer
    /// is ready when the answer says so, or when `grace_ms` has passed on
    /// the caller's clock since it went — and a terminal that lets the grace
    /// period run out without ever having answered is taken to be one that
    /// never answers, so nothing after it is waited for. A refused image is
    /// not ready; send it again.
    pub fn ready(l: *Layers, id: u32, now_ms: i64, grace_ms: i64) bool {
        const held = l.find(id) orelse return false;
        switch (held.state) {
            .ready => return true,
            .failed => return false,
            .loading => {
                if (l.answers == false) {
                    held.state = .ready;
                    return true;
                }
                if (now_ms - held.sent_ms < grace_ms) return false;
                held.state = .ready;
                l.fallbacks += 1;
                if (l.answers == null) l.answers = false;
                return true;
            },
        }
    }

    /// The terminal answered about an image: ready or refused. An answer
    /// about an id this program never sent — the answer to a probe, say —
    /// changes nothing.
    pub fn ack(l: *Layers, response: morse.GraphicsResponse) void {
        const id = response.id orelse return;
        const held = l.find(id) orelse return;
        l.answers = true;
        held.state = if (response.ok()) .ready else .failed;
    }

    /// Frees an image: its pixels and every placement of it, in the
    /// terminal and here. What a program does with a picture it is finished
    /// with, so the terminal's memory and this list stay as small as what
    /// is alive.
    pub fn free(l: *Layers, w: *Writer, id: u32) Writer.Error!void {
        var i: usize = 0;
        while (i < l.images.items.len) {
            if (l.images.items[i].id == id) {
                _ = l.images.swapRemove(i);
            } else i += 1;
        }
        l.forgetShown(id);
        l.undeclareImage(id);
        try morse.deleteImage(w, .{ .target = .{ .image = .{ .id = id } }, .free = true, .quiet = .silent });
    }

    /// Frees every image. What a program writes on the way out.
    pub fn freeAll(l: *Layers, w: *Writer) Writer.Error!void {
        while (l.images.items.len > 0) try l.free(w, l.images.items[l.images.items.len - 1].id);
        l.shown.clearRetainingCapacity();
        l.declared.clearRetainingCapacity();
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
    pub fn undeclare(l: *Layers, image_id: u32, placement: u32) void {
        var i: usize = 0;
        while (i < l.declared.items.len) : (i += 1) {
            const held = l.declared.items[i];
            if (held.image == image_id and held.placement == placement) {
                _ = l.declared.orderedRemove(i);
                return;
            }
        }
    }

    fn undeclareImage(l: *Layers, id: u32) void {
        var i: usize = 0;
        while (i < l.declared.items.len) {
            if (l.declared.items[i].image == id) {
                _ = l.declared.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Drops the record of an image's placements, which the terminal has
    /// taken down itself.
    fn forgetShown(l: *Layers, id: u32) void {
        var i: usize = 0;
        while (i < l.shown.items.len) {
            if (l.shown.items[i].image == id) {
                _ = l.shown.orderedRemove(i);
            } else i += 1;
        }
    }

    /// The placements and the deletions, after the text pass, in one block:
    /// every placement first, then the deletions, so a picture that replaces
    /// another covers it before it goes.
    ///
    /// Writes nothing when nothing moved, so a caller may call it twice and
    /// a renderer that calls it for them costs nothing.
    pub fn emit(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        if (!caps.kitty_graphics) return 0;
        std.mem.sort(Layer, l.declared.items, {}, lessThan);
        var written: usize = 0;

        // Here: a placement command, which replaces whatever was at the same
        // image and placement id without flicker.
        for (l.declared.items, 0..) |now, i| {
            if (findSameIndex(l.shown.items, now)) |before_i| {
                const before = l.shown.items[before_i];
                if (before.eql(now) and zOf(now, i) == zOf(before, before_i)) continue;
            }
            try writePlace(w, now, zOf(now, i));
            written += 1;
        }
        // Gone: name the one placement rather than everything on screen, and
        // keep the image's pixels, because the program may show it again.
        for (l.shown.items) |was| {
            if (findSameIndex(l.declared.items, was) != null) continue;
            try writeDelete(w, was);
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

    /// Takes every placement off the screen, keeping the images. What a
    /// program writes when it leaves a view it will come back to.
    pub fn clear(l: *Layers, w: *Writer, caps: Caps) Writer.Error!void {
        if (!caps.kitty_graphics) return;
        for (l.shown.items) |was| try writeDelete(w, was);
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
    fn writePlace(w: *Writer, layer: Layer, z: i32) Writer.Error!void {
        try morse.cursorTo(w, layer.rect.row + 1, layer.rect.col + 1);
        try morse.placeImage(w, .{
            .image = .{ .id = layer.image },
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
    /// with the image's pixels kept.
    fn writeDelete(w: *Writer, layer: Layer) Writer.Error!void {
        try morse.deleteImage(w, .{
            .target = .{ .image = .{ .id = layer.image, .placement = layer.placement } },
            .free = false,
            .quiet = .silent,
        });
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

test "a layer is placed by the id the program chose, with no round trip" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();

    try f.screen.layers.declare(testing.allocator, .{
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
    try testing.expect(std.mem.indexOf(u8, bytes, "d=i") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "i=5") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "p=3") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=I") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "d=a") == null);
}

test "a picture swapped for another is placed before the old one goes" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    const at: Rect = .{ .col = 1, .row = 1, .cols = 6, .rows = 3 };
    try f.screen.layers.declare(testing.allocator, .{ .image = 6, .rect = at });
    _ = try f.draw();
    try f.screen.layers.declare(testing.allocator, .{ .image = 7, .rect = at });
    _ = try f.draw();
    const bytes = f.written();
    const placed = std.mem.indexOf(u8, bytes, "a=p,q=2,i=7").?;
    const dropped = std.mem.indexOf(u8, bytes, "a=d,q=2,d=i,i=6").?;
    try testing.expect(placed < dropped);
}

test "an image sent quietly is ready at once, compressed when that is smaller" {
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // A dark picture, the kind that deflates to nothing.
    var pixels: [64 * 64 * 4]u8 = @splat(0);
    const sent = try l.transmit(testing.allocator, &out.writer, 9, &pixels, .{ .width = 64, .height = 64 });
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
    const raw = try l.transmit(testing.allocator, &out.writer, 10, &noise, .{ .width = 8, .height = 8 });
    try testing.expectEqual(noise.len, raw);
    try testing.expect(std.mem.indexOf(u8, out.written(), "o=z") == null);
}

test "the pixels decompress to what was sent, chunk after chunk" {
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var pixels: [96 * 96 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @truncate(i / 7);
    _ = try l.transmit(testing.allocator, &out.writer, 4, &pixels, .{ .width = 96, .height = 96 });

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
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };

    _ = try l.transmit(testing.allocator, &out.writer, 6, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 1000 });
    try testing.expect(std.mem.indexOf(u8, out.written(), "q=") == null);
    try testing.expect(!l.ready(6, 1100, 250));
    l.ack(.{ .id = 6, .message = "OK" });
    try testing.expect(l.ready(6, 1101, 250));
    try testing.expectEqual(@as(?bool, true), l.answers);

    // A refusal: not ready, and the program sends again.
    _ = try l.transmit(testing.allocator, &out.writer, 7, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 2000 });
    l.ack(.{ .id = 7, .message = "EBADPNG: bad data" });
    try testing.expect(!l.ready(7, 5000, 250));
    try testing.expectEqual(Image.State.failed, l.image(7).?.state);

    // An answer about an id never sent here -- a probe's -- changes nothing.
    l.ack(.{ .id = 31, .message = "OK" });
    try testing.expect(l.image(31) == null);
}

test "a terminal that never answers is given the grace once, and then not waited for" {
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };

    _ = try l.transmit(testing.allocator, &out.writer, 2, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 1000 });
    try testing.expect(!l.ready(2, 1249, 250));
    try testing.expect(l.ready(2, 1250, 250));
    try testing.expectEqual(@as(u32, 1), l.fallbacks);
    try testing.expectEqual(@as(?bool, false), l.answers);

    _ = try l.transmit(testing.allocator, &out.writer, 3, &px, .{ .width = 1, .height = 1, .answer = true, .now_ms = 2000 });
    try testing.expect(l.ready(3, 2000, 250));
    try testing.expectEqual(@as(u32, 1), l.fallbacks);
}

test "sending to an id on screen places it again, and freeing takes it all away" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };
    const layer: Layer = .{ .image = 8, .rect = .{ .col = 0, .row = 0, .cols = 4, .rows = 2 } };

    _ = try f.screen.layers.transmit(testing.allocator, &sent.writer, 8, &px, .{ .width = 1, .height = 1 });
    try f.screen.layers.declare(testing.allocator, layer);
    _ = try f.draw();
    try testing.expectEqual(@as(usize, 1), f.screen.layers.count());

    // New pixels under the same id: the terminal took the placement down,
    // so the next frame puts it back though the layer did not move.
    _ = try f.screen.layers.transmit(testing.allocator, &sent.writer, 8, &px, .{ .width = 1, .height = 1 });
    try testing.expectEqual(@as(usize, 1), f.screen.layers.images.items.len);
    try f.screen.layers.declare(testing.allocator, layer);
    const again = try f.draw();
    try testing.expectEqual(@as(u32, 1), again.placements);
    try testing.expect(std.mem.indexOf(u8, f.written(), "a=p") != null);

    // Freed: the pixels and the placements, in one command the program
    // wrote, and nothing for the next frame to delete.
    sent.clearRetainingCapacity();
    try f.screen.layers.free(&sent.writer, 8);
    try testing.expectEqualStrings("\x1b_Ga=d,q=2,d=I,i=8\x1b\\", sent.written());
    try testing.expect(f.screen.layers.image(8) == null);
    try testing.expectEqual(@as(usize, 0), f.screen.layers.count());
    const after = try f.draw();
    try testing.expectEqual(@as(u32, 0), after.placements);
    try testing.expectEqual(@as(usize, 0), after.bytes);
}

test "a layer at its own size names no columns or rows" {
    var f: Fixture = try .init(testing.allocator, 20, 6);
    defer f.deinit();
    try f.screen.layers.declare(testing.allocator, .{
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
    var l: Layers = .{};
    defer l.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const px = [_]u8{ 1, 2, 3, 4 };
    for (0..100) |i| {
        const id: u32 = @intCast(2 + i % 4);
        _ = try l.transmit(testing.allocator, &out.writer, id, &px, .{ .width = 1, .height = 1 });
    }
    try testing.expectEqual(@as(usize, 4), l.images.items.len);
    try l.freeAll(&out.writer);
    try testing.expectEqual(@as(usize, 0), l.images.items.len);
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
