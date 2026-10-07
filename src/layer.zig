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
//! clock. Sixel pixels and iTerm2 file bytes are retained for redraws;
//! their writers are morse's. The diff renderer owns their damage because
//! neither protocol has a placement id.

const std = @import("std");
const builtin = @import("builtin");
const morse = @import("dependencies.zig").morse;

const geom = @import("geom.zig");
const Caps = @import("caps.zig").Caps;
const shm = @import("layer/shm.zig");
const Winsize = @import("winsize.zig").Winsize;

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
    /// Storage protocol; inline images live here until retired.
    protocol: Caps.Pictures = .kitty,
    /// How wide the image is, in pixels.
    width: u32 = 0,
    /// How tall it is, in pixels.
    height: u32 = 0,
    /// Whether the terminal has it.
    state: State = .ready,
    /// When it was sent, on the caller's clock, in milliseconds.
    sent_ms: i64 = 0,
    /// The name it was sent through, until the terminal answers. This is
    /// diagnostic metadata; Layers keeps the cleanup owner privately.
    shm: ?shm.Name = null,

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
        pub fn before(a: Layer.Order, b: Layer.Order) bool {
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

/// Pictures through shared memory: the pixels are put where the terminal
/// reads them and only a name goes through its input, with no compression
/// and no base64 — on the same machine, the difference between a picture
/// that costs a frame and one that costs a copy. The terminal that takes
/// them is found by trying: the first picture asks for an answer, and an
/// error or a grace period with no answer turns the medium off for good,
/// that picture refused so the caller sends it again, in the escape code.
const SharedMemory = struct {
    /// What `/dev/shm` is written through where there is no libc.
    io: std.Io,
    state: enum { trying, yes, no } = .trying,
    generation: u64,
};

// This is the owner, not the image snapshot or the current policy. Once
// created it carries everything cleanup needs, even after reconfiguration.
const SharedObject = struct {
    id: u32,
    name: shm.Name,
    io: std.Io,
    generation: u64,

    fn init(policy: SharedMemory, id: u32, pixels: []const u8) shm.PutError!SharedObject {
        const name = shm.nextName();
        try shm.put(policy.io, name, pixels);
        return .{ .id = id, .name = name, .io = policy.io, .generation = policy.generation };
    }

    fn deinit(object: SharedObject) void {
        shm.unlink(object.io, object.name);
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

/// Rotating image ids in an inclusive range, shared by any number of
/// replacements. Skips zero, the probe id and every image still held by
/// `Layers`, including those awaiting retirement.
pub const ImageIds = struct {
    /// Private.
    first: u32,
    /// Private.
    last: u32,
    /// Private.
    graphics_id: u32,
    /// Private.
    next: u32,

    pub fn init(first: u32, last: u32, graphics_id: u32) error{InvalidIdRange}!ImageIds {
        if (first == 0 or first > last or (first == last and first == graphics_id)) return error.InvalidIdRange;
        return .{ .first = first, .last = last, .graphics_id = graphics_id, .next = first };
    }

    /// A free id, or `NoImageId` while the range is wholly occupied.
    pub fn acquire(ids: *ImageIds, layers: *const Layers) error{NoImageId}!u32 {
        const start = ids.next;
        while (true) {
            const id = ids.next;
            ids.next = if (id == ids.last) ids.first else id + 1;
            if (id != ids.graphics_id and layers.image(id) == null) return id;
            if (ids.next == start) return error.NoImageId;
        }
    }
};

/// One replaceable picture, independent of its position, stack or content.
/// Send to an unused id, keep the current picture while the new one lands,
/// then declare the new one and retire the old through `commitFrame`.
/// One transmit may be in flight. The caller owns the value, its id range,
/// grace period and any decision about when to produce another picture.
pub const Replacement = struct {
    /// Private.
    own_current: ?u32 = null,
    /// Private.
    own_pending: ?u32 = null,
    /// Private.
    dirty: bool = false,

    /// The usable picture id, by value; retire it through this owner.
    pub fn current(p: *const Replacement) ?u32 {
        return p.own_current;
    }

    /// The picture still awaiting settlement, by value.
    pub fn pending(p: *const Replacement) ?u32 {
        return p.own_pending;
    }

    pub const Error = Writer.Error || Allocator.Error || error{ Busy, NoImageId, PayloadTooLarge };

    /// Whether another picture can be sent. Call `settle` or `declare` to settle a
    /// ready or refused pending picture before sending the next one.
    pub fn canSend(p: *const Replacement) bool {
        return p.own_pending == null;
    }

    /// Sends one new picture, returning its id and payload byte count.
    /// On a partial write the recorded image is retired at the next commit
    /// and `takeDirty` asks the owner to produce it again.
    pub fn send(p: *Replacement, layers: *Layers, w: *Writer, ids: *ImageIds, pixels: []const u8, how: Transmit) Error!struct { id: u32, bytes: usize } {
        const gpa = layers.gpa;
        if (!p.canSend()) return error.Busy;
        const id = try ids.acquire(layers);
        // Reserve cleanup before any command can reach the terminal.
        try layers.retired.ensureUnusedCapacity(gpa, 1);
        const bytes = layers.transmit(w, id, pixels, how) catch |err| {
            if (layers.image(id) != null) layers.retired.appendAssumeCapacity(id);
            p.dirty = true;
            return err;
        };
        p.own_pending = id;
        return .{ .id = id, .bytes = bytes };
    }

    /// Fold acknowledgements and grace into ownership without declaring a
    /// placement. Returns true while a pending image still needs a reply.
    /// Refusals retain a usable current picture and set takeDirty.
    /// On allocation failure, current and pending ownership stay unchanged.
    pub fn settle(p: *Replacement, layers: *Layers, now_ms: i64, grace_ms: i64) Allocator.Error!bool {
        // Reserve every retirement before changing either ownership slot.
        const current_failed = if (p.own_current) |id| if (layers.image(id)) |img| img.state == .failed else true else false;
        const reserve: usize = if (p.own_pending != null) 1 + @as(usize, @intFromBool(p.own_current != null)) else @intFromBool(current_failed);
        try layers.retired.ensureUnusedCapacity(layers.gpa, reserve);
        if (p.own_pending) |id| {
            const ready = layers.ready(id, now_ms, grace_ms);
            const failed = if (layers.image(id)) |img| img.state == .failed else true;
            if (failed) {
                try layers.retire(id);
                p.own_pending = null;
                p.dirty = true;
            } else if (ready) {
                if (p.own_current) |old| try layers.retire(old);
                p.own_current = id;
                p.own_pending = null;
            }
        }
        if (p.own_current) |id| {
            const failed = if (layers.image(id)) |img| img.state == .failed else true;
            if (failed) {
                try layers.retire(id);
                p.own_current = null;
                p.dirty = true;
            }
        }
        return p.own_pending != null;
    }

    /// Settle and declare at want, overriding its image id. Returns true
    /// while a pending image needs another frame. A null want leaves
    /// ownership unsettled and makes no declaration; use settle explicitly
    /// to advance hidden pictures.
    pub fn declare(p: *Replacement, layers: *Layers, want: ?Layer, now_ms: i64, grace_ms: i64) Allocator.Error!bool {
        var at = want orelse return p.own_pending != null;
        // A declaration must be able to commit after ownership changes.
        try layers.declared.ensureUnusedCapacity(layers.gpa, 1);
        const waiting = try p.settle(layers, now_ms, grace_ms);
        if (p.own_current) |id| {
            at.image = id;
            try layers.declare(at);
        }
        return waiting;
    }

    /// Whether a refusal or write failure asked for another picture since
    /// last checked. Call `settle` or `declare` after `Layers.ack` to fold refusals in.
    pub fn takeDirty(p: *Replacement) bool {
        defer p.dirty = false;
        return p.dirty;
    }

    /// Retires everything this value owns at the next committed frame.
    pub fn retire(p: *Replacement, layers: *Layers) Allocator.Error!void {
        const gpa = layers.gpa;
        try layers.retired.ensureUnusedCapacity(gpa, 2);
        if (p.own_current) |id| {
            try layers.retire(id);
            layers.undeclareImage(id);
        }
        if (p.own_pending) |id| {
            try layers.retire(id);
            layers.undeclareImage(id);
        }
        p.* = .{};
    }
};

/// The protocol's S field must fit before any OS object is created.
fn sharedSize(len: usize) error{PayloadTooLarge}!u32 {
    return std.math.cast(u32, len) orelse error.PayloadTooLarge;
}

/// The z the terminal is given for a layer under the text.
///
/// Below zero is under the text; the sorted position is added, so the
/// stacking order the `Order` tuples give survives into the one integer the
/// protocol takes.
const under_base: i32 = -1_000_000;

const InlineImage = struct {
    id: u32,
    data: []u8,
    scratch: []u8 = &.{},
    palette: []morse.Rgb = &.{},
    sixel: ?morse.Sixel = null,
    part_bytes: usize = 0,

    fn deinit(image: InlineImage, gpa: Allocator) void {
        gpa.free(image.data);
        gpa.free(image.scratch);
        gpa.free(image.palette);
    }
};

/// The images this program has sent, and what this frame shows of them.
pub const Layers = struct {
    /// Private.
    gpa: Allocator,

    // Fields documented Private: are implementation storage; use metadata accessors.
    /// Private: the images the terminal holds for this program, one per id. Sending
    /// to an id replaces its entry and freeing one removes it, so the list
    /// is as long as the pictures that are alive.
    own_images: std.ArrayList(Image) = .empty,
    /// Private: what this frame has declared, in declaration order.
    declared: std.ArrayList(Layer) = .empty,
    /// Private: what the terminal is showing, after the last `emit`.
    shown: std.ArrayList(Layer) = .empty,
    /// Private: images freed only after a complete frame stopped declaring them.
    retired: std.ArrayList(u32) = .empty,
    /// Private: whether this terminal answers a transmit: unknown until the first
    /// answer (true), or until a grace period runs out with no answer ever
    /// (false), after which direct transmissions are not waited for.
    answers: ?bool = null,
    /// Private: how many images were taken as ready because the grace period ran
    /// out rather than because the terminal said so.
    fallbacks: u32 = 0,
    /// Private: the deflate window, made the first time a picture is compressed and
    /// kept for the next.
    window: []u8 = &.{},
    /// Private: where a picture is deflated to, kept and reused for the next, so
    /// sending pictures frame after frame allocates nothing once the buffer
    /// has grown to the largest of them.
    deflated: std.ArrayList(u8) = .empty,
    /// Private: whether the next `emit` places every declared layer, whatever `shown`
    /// says, because the terminal may have moved or dropped any of them.
    replace_all: bool = false,
    /// Private: pictures through shared memory, where the program allows it (the
    /// terminal is on this machine, or may be): null sends every picture
    /// in the escape code.
    shared_memory: ?SharedMemory = null,
    /// Private.
    shared_objects: std.ArrayList(SharedObject) = .empty,
    /// Private.
    own_inline: std.ArrayList(InlineImage) = .empty,
    /// Private.
    size: Winsize = .{},
    /// Private.
    inline_dirty: bool = false,
    /// Private.
    sixel_cursor_right: bool = false,
    /// Private.
    protocol: ?Caps.Pictures = null,

    /// Geometry for inline pictures, including the probe's cell size.
    /// Renderer supplies the grid bounds; unknown pixel sizes suppress sixels.
    pub fn configureSize(l: *Layers, size: Winsize) void {
        if (!std.meta.eql(l.size, size)) l.repaint();
        l.size = size;
    }

    /// Retains a copy of pixels and palette for a sixel picture. No bytes
    /// are written until the frame places it. Indexed pixels must name a
    /// palette entry (or the transparent index). Invalid input is rejected
    /// before changing the image. The palette is the caller's, as in morse.
    pub fn storeSixel(l: *Layers, id: u32, image_data: morse.Sixel) (Allocator.Error || error{InvalidImage})!void {
        const pixel_count = std.math.mul(usize, image_data.width, image_data.height) catch return error.InvalidImage;
        const channels: usize = if (image_data.pixels == .rgba) 4 else 1;
        const len = std.math.mul(usize, pixel_count, channels) catch return error.InvalidImage;
        const pixels = switch (image_data.pixels) {
            .indexed => |v| v,
            .rgba => |v| v,
        };
        if (pixel_count == 0 or pixels.len != len or image_data.palette.len == 0 or image_data.palette.len > morse.sixel_palette_max) return error.InvalidImage;
        if (image_data.pixels == .indexed) for (pixels) |index| {
            if (index >= image_data.palette.len and index != image_data.transparent) return error.InvalidImage;
        };
        var held: InlineImage = .{ .id = id, .data = try l.gpa.dupe(u8, pixels) };
        errdefer held.deinit(l.gpa);
        held.scratch = try l.gpa.alloc(u8, std.math.mul(usize, pixel_count, 4) catch return error.InvalidImage);
        held.palette = try l.gpa.dupe(morse.Rgb, image_data.palette);
        var copied = image_data;
        copied.pixels = if (channels == 4) .{ .rgba = held.data } else .{ .indexed = held.data };
        copied.palette = held.palette;
        held.sixel = copied;
        try l.storeInline(held, .{ .id = id, .width = copied.width, .height = copied.height, .protocol = .sixel });
    }

    /// Retains an already encoded image file (PNG, JPEG, etc.) for iTerm2.
    /// Zero part_bytes uses File; otherwise morse's multipart writer is used.
    /// Files are fitted to the placement's cell rectangle without preserving
    /// aspect ratio. Source cropping belongs to the caller's image decoder.
    pub fn storeIterm(l: *Layers, id: u32, file: []const u8, part_bytes: usize) Allocator.Error!void {
        const held: InlineImage = .{ .id = id, .data = try l.gpa.dupe(u8, file), .part_bytes = part_bytes };
        errdefer held.deinit(l.gpa);
        try l.storeInline(held, .{ .id = id, .protocol = .iterm });
    }

    fn storeInline(l: *Layers, held: InlineImage, metadata: Image) Allocator.Error!void {
        try l.own_inline.ensureUnusedCapacity(l.gpa, 1);
        try l.record(metadata);
        l.own_inline.appendAssumeCapacity(held);
        l.inline_dirty = true;
    }

    /// Whether an inline picture changed since the last accepted frame.
    /// The diff renderer erases the old footprint before drawing again.
    pub fn inlineChanged(l: *const Layers) bool {
        if (l.inline_dirty or l.replace_all or l.shown.items.len != l.declared.items.len) return true;
        for (l.declared.items) |now| {
            const i = findSameIndex(l.shown.items, now) orelse return true;
            if (!now.eql(l.shown.items[i])) return true;
        }
        return false;
    }

    /// Captures the allocator for every image, placement and scratch buffer.
    pub fn init(gpa: Allocator) Layers {
        return .{ .gpa = gpa };
    }

    /// Borrowed metadata; expires when images change or Layers is destroyed.
    pub fn images(l: *const Layers) []const Image {
        return l.own_images.items;
    }
    /// This frame's declarations, borrowed until a declaration or frame commit.
    pub fn declarations(l: *const Layers) []const Layer {
        return l.declared.items;
    }
    /// The placements last committed, borrowed until the next frame or clear.
    pub fn placements(l: *const Layers) []const Layer {
        return l.shown.items;
    }
    /// Whether a frame must process pictures or retirements.
    pub fn hasFrameWork(l: *const Layers) bool {
        return l.declared.items.len != 0 or l.shown.items.len != 0 or l.retired.items.len != 0;
    }
    /// The terminal's learned direct-transmission answer policy.
    pub fn answerPolicy(l: *const Layers) ?bool {
        return l.answers;
    }
    /// Images accepted after their answer grace period.
    pub fn fallbackCount(l: *const Layers) u32 {
        return l.fallbacks;
    }

    /// Allows shared memory through `io`, or disables it with null. This
    /// changes future transmissions; live objects keep their own cleanup Io.
    /// Repeating the same configuration keeps the terminal's learned answer.
    /// Disable and enable again to retry a refused medium. The supplied Io
    /// must outlive every outstanding object, including after configuration changes.
    pub fn configureSharedMemory(l: *Layers, io: ?std.Io) void {
        if (io) |next| {
            if (l.shared_memory) |current| {
                if (current.io.userdata == next.userdata and current.io.vtable == next.vtable) return;
            }
            l.shared_memory = .{ .io = next, .generation = shm.nextNamespace() };
        } else l.shared_memory = null;
    }

    /// Gives the lists and the window back, and unlinks any picture still
    /// in shared memory.
    pub fn deinit(l: *Layers) void {
        const gpa = l.gpa;
        for (l.shared_objects.items) |object| object.deinit();
        l.shared_objects.deinit(gpa);
        for (l.own_inline.items) |held| held.deinit(gpa);
        l.own_inline.deinit(gpa);
        l.own_images.deinit(gpa);
        l.declared.deinit(gpa);
        l.shown.deinit(gpa);
        l.retired.deinit(gpa);
        gpa.free(l.window);
        l.deflated.deinit(gpa);
        l.* = undefined;
    }

    /// What the program knows about an image, or null.
    pub fn image(l: *const Layers, id: u32) ?Image {
        return (l.find(id) orelse return null).*;
    }

    fn find(l: *const Layers, id: u32) ?*Image {
        for (l.own_images.items) |*held| {
            if (held.id == id) return held;
        }
        return null;
    }

    /// Sends an image under `id`: through shared memory where that is
    /// allowed and the terminal takes it (`configureSharedMemory`), else chunked
    /// in the escape code, deflated when that helps; quiet unless an
    /// answer was asked for. Returns how many bytes went through the
    /// terminal's input: the name, or the pixels after compression and
    /// before base64.
    ///
    /// Sending to an id the terminal is showing replaces the pixels, and the
    /// terminal drops that image's placements while they land; the next
    /// frame places them again. A picture replaced without a gap goes to a
    /// second id instead, and the layer is declared with that one once
    /// `ready` says so: the old placement is deleted after the new one is
    /// made.
    ///
    /// A shared-memory payload beyond the protocol's u32 size returns
    /// `PayloadTooLarge` before allocating or creating an object.
    /// Written to `w` directly and not through a frame, so the caller sends
    /// before it draws. A failed write retains a refused, freeable image;
    /// it cannot become ready through grace. Send it again to retry.
    pub fn transmit(
        l: *Layers,
        w: *Writer,
        id: u32,
        pixels: []const u8,
        how: Transmit,
    ) (Writer.Error || Allocator.Error || error{PayloadTooLarge})!usize {
        const gpa = l.gpa;
        if (l.shared_memory) |*sm| if (sm.state != .no and how.format != .png) {
            if (try l.transmitShared(w, sm, id, pixels, how)) |n| return n;
        };
        var packed_pixels: std.Io.Writer.Allocating = .fromArrayList(gpa, &l.deflated);
        defer l.deflated = packed_pixels.toArrayList();
        packed_pixels.clearRetainingCapacity();
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
        try l.record(.{
            .id = id,
            .width = how.width,
            .height = how.height,
            .state = if (how.answer) .loading else .ready,
            .sent_ms = how.now_ms,
        });

        errdefer l.find(id).?.state = .failed;
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

    /// The record of an image sent, replacing the one under its id; the
    /// terminal takes that image's placements down while it lands.
    fn record(l: *Layers, rec: Image) Allocator.Error!void {
        const gpa = l.gpa;
        if (l.find(rec.id) == null) try l.own_images.ensureUnusedCapacity(gpa, 1);
        l.recordReserved(rec);
    }

    fn recordReserved(l: *Layers, rec: Image) void {
        if (l.find(rec.id)) |held| {
            l.release(held);
            held.* = rec;
        } else l.own_images.appendAssumeCapacity(rec);
        l.forgetShown(rec.id);
    }

    /// The picture put in shared memory and its name sent, or null when it
    /// could not be put there (the medium is then off, and the caller's
    /// picture goes in the escape code). While the medium is on trial the
    /// terminal is asked to answer, whatever the caller asked.
    fn transmitShared(l: *Layers, w: *Writer, sm: *SharedMemory, id: u32, pixels: []const u8, how: Transmit) (Writer.Error || Allocator.Error || error{PayloadTooLarge})!?usize {
        const gpa = l.gpa;
        const size = try sharedSize(pixels.len);
        // Reserve before the OS object exists. Once it does, the image
        // record can take its name without any further allocation.
        if (l.find(id) == null) try l.own_images.ensureUnusedCapacity(gpa, 1);
        if (l.sharedObject(id) == null) try l.shared_objects.ensureUnusedCapacity(gpa, 1);
        const object = SharedObject.init(sm.*, id, pixels) catch {
            sm.state = .no;
            return null;
        };
        const trying = sm.state == .trying;
        l.recordReserved(.{
            .id = id,
            .width = how.width,
            .height = how.height,
            .state = if (how.answer or trying) .loading else .ready,
            .sent_ms = how.now_ms,
            .shm = object.name,
        });
        l.shared_objects.appendAssumeCapacity(object);
        errdefer l.find(id).?.state = .failed;
        try morse.transmitImage(w, .{
            .image = .{ .id = id },
            .format = how.format,
            .medium = .shared_memory,
            .width = how.width,
            .height = how.height,
            .size = size,
            .quiet = if (how.answer or trying) .answers else .silent,
        }, object.name.slice());
        return object.name.len;
    }

    /// An image's shared memory object, unlinked if it is still there:
    /// the terminal unlinks what it reads, and what it could not read is
    /// this program's to take away.
    fn sharedObject(l: *const Layers, id: u32) ?SharedObject {
        for (l.shared_objects.items) |object| {
            if (object.id == id) return object;
        }
        return null;
    }

    fn release(l: *Layers, held: *Image) void {
        held.shm = null;
        for (l.own_inline.items, 0..) |inline_image, i| {
            if (inline_image.id != held.id) continue;
            l.own_inline.swapRemove(i).deinit(l.gpa);
            l.inline_dirty = true;
            break;
        }
        for (l.shared_objects.items, 0..) |object, i| {
            if (object.id != held.id) continue;
            const owned = l.shared_objects.swapRemove(i);
            owned.deinit();
            return;
        }
    }

    // A reply to an object from an earlier configuration cannot settle the
    // current medium's trial or turn that medium off.
    fn policyFor(l: *Layers, object: SharedObject) ?*SharedMemory {
        const policy = if (l.shared_memory) |*sm| sm else return null;
        return if (policy.generation == object.generation) policy else null;
    }

    /// Whether the terminal has the image, so a layer can show it.
    ///
    /// An image sent quietly is ready at once. A direct transmission asking for an answer
    /// is ready when the answer says so, or when `grace_ms` has passed on
    /// the caller's clock since it went — and a terminal that lets the grace
    /// period run out without ever having answered is taken to be one that
    /// never answers, so later direct transmissions are not waited for.
    /// A shared-memory trial needs its own answer: silence refuses the image
    /// and releases its object. A refused image is
    /// not ready; send it again.
    pub fn ready(l: *Layers, id: u32, now_ms: i64, grace_ms: i64) bool {
        const held = l.find(id) orelse return false;
        switch (held.state) {
            .ready => return true,
            .failed => return false,
            .loading => {
                // Silence permits only bytes sent through the escape code
                // to be taken on trust. Shared memory needs its own proof.
                const shared = l.sharedObject(id);
                if (shared == null and l.answers == false) {
                    held.state = .ready;
                    return true;
                }
                if (now_ms -| held.sent_ms < grace_ms) return false;
                // A picture in shared memory is not taken on trust: a
                // terminal that never said it read one is one that is
                // not given another, and this one is sent again.
                if (shared) |object| {
                    l.release(held);
                    if (l.policyFor(object)) |sm| sm.state = .no;
                    held.state = .failed;
                    return false;
                }
                held.state = .ready;
                l.fallbacks += 1;
                if (l.answers == null) l.answers = false;
                return true;
            },
        }
    }

    /// The terminal answered about an image: ready or refused. An answer
    /// about an id this program never sent — the answer to a probe, say —
    /// changes nothing. A failed image stays refused until transmitted again.
    pub fn ack(l: *Layers, response: morse.GraphicsResponse) void {
        const id = response.id orelse return;
        const held = l.find(id) orelse return;
        l.answers = true;
        if (held.state != .failed) held.state = if (response.ok()) .ready else .failed;
        if (l.sharedObject(id)) |object| {
            l.release(held);
            if (l.policyFor(object)) |sm| {
                if (sm.state == .trying) sm.state = if (response.ok()) .yes else .no;
                // a medium that worked and now fails (a terminal reached
                // through ssh by a later attach, say) is off from here
                if (!response.ok()) sm.state = .no;
            }
        }
    }

    /// Frees an image: its pixels and every placement of it, in the
    /// terminal and here. What a program does with a picture it is finished
    /// with, so the terminal's memory and this list stay as small as what
    /// is alive.
    pub fn free(l: *Layers, w: *Writer, id: u32) Writer.Error!void {
        if (l.image(id) == null or l.image(id).?.protocol == .kitty) try morse.deleteImage(w, .{ .target = .{ .image = .{ .id = id } }, .free = true, .quiet = .silent });
        var i: usize = 0;
        while (i < l.own_images.items.len) {
            if (l.own_images.items[i].id == id) {
                l.release(&l.own_images.items[i]);
                _ = l.own_images.swapRemove(i);
            } else i += 1;
        }
        l.forgetShown(id);
        l.undeclareImage(id);
        var retired_i: usize = 0;
        while (retired_i < l.retired.items.len) {
            if (l.retired.items[retired_i] == id) {
                _ = l.retired.swapRemove(retired_i);
            } else retired_i += 1;
        }
    }

    /// Frees `id` inside `commitFrame`, after placements and deletions.
    /// A still-declared image is kept until a later frame stops using it.
    pub fn retire(l: *Layers, id: u32) Allocator.Error!void {
        const gpa = l.gpa;
        if (std.mem.findScalar(u32, l.retired.items, id) != null) return;
        try l.retired.append(gpa, id);
    }

    /// Frees every image. What a program writes on the way out.
    pub fn freeAll(l: *Layers, w: *Writer) Writer.Error!void {
        while (l.own_images.items.len > 0) try l.free(w, l.own_images.items[l.own_images.items.len - 1].id);
        l.shown.clearRetainingCapacity();
        l.declared.clearRetainingCapacity();
    }

    /// Shows a layer this frame.
    ///
    /// Declaring the same image and placement twice in a frame keeps the
    /// second: that is how a picture is moved, and it costs one command
    /// rather than a delete and a place.
    pub fn declare(l: *Layers, layer: Layer) Allocator.Error!void {
        const gpa = l.gpa;
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

    /// The next `emit` places every declared layer again, as though the
    /// terminal could have moved or dropped any placement it had.
    ///
    /// Which it can: a terminal that changes size moves its rows about, and
    /// a placement is pinned to a row; one a frame at the old size scrolled
    /// goes up with the text, and one on a row the terminal gave up is
    /// gone. A placement with the same image and placement id replaces the
    /// one there without flicker, wherever it went, and brings back one
    /// that went, so placing again is right either way. A layer that is no
    /// longer declared is still deleted by name, wherever the terminal has
    /// it. `Renderer` calls this on every repaint, so a program that
    /// resizes need not.
    pub fn repaint(l: *Layers) void {
        l.replace_all = true;
    }

    /// The placements and the deletions, after the text pass, in one block:
    /// every placement first, then the deletions, so a picture that replaces
    /// another covers it before it goes.
    ///
    /// Writes nothing when nothing moved, so a caller may call it twice and
    /// a renderer that calls it for them costs nothing.
    pub fn emit(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        var removed: usize = 0;
        if (l.protocol == .kitty and caps.pictures() != .kitty) {
            for (l.shown.items) |was| {
                try writeDelete(w, was);
                removed += 1;
            }
        }
        if (caps.pictures() == .cells) return removed;
        if (caps.pictures() != .kitty) return removed + try l.emitInline(w, caps);
        std.mem.sort(Layer, l.declared.items, {}, lessThan);
        var written: usize = 0;

        // Here: a placement command, which replaces whatever was at the same
        // image and placement id without flicker.
        for (l.declared.items, 0..) |now, i| {
            if (l.image(now.image)) |rec| if (rec.protocol != .kitty) continue;
            if (!l.replace_all) if (findSameIndex(l.shown.items, now)) |before_i| {
                const before = l.shown.items[before_i];
                if (before.eql(now) and zOf(now, i) == zOf(before, before_i)) continue;
            };
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

    /// Commits after `emit` and the complete frame reached the caller's
    /// writer. Frees retired images after their old placements were dropped,
    /// then keeps the declarations. Returns the number of free commands.
    /// A failed free keeps its record and retirement for the next attempt.
    /// No allocation and no flush. The renderer calls this for its frames.
    pub fn commitFrame(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        if (caps.pictures() == .cells) l.declared.clearRetainingCapacity();
        var freed: usize = 0;
        var i: usize = 0;
        while (i < l.retired.items.len) {
            const id = l.retired.items[i];
            var declared = false;
            for (l.declared.items) |layer| if (layer.image == id) {
                declared = true;
                break;
            };
            if (declared) {
                i += 1;
                continue;
            }
            try l.free(w, id);
            freed += 1;
        }
        l.replace_all = false;
        l.inline_dirty = false;
        l.protocol = caps.pictures();
        const was_shown = l.shown;
        l.shown = l.declared;
        l.declared = was_shown;
        l.declared.clearRetainingCapacity();
        return freed;
    }

    /// Takes every placement off the screen, keeping the images. What a
    /// program writes when it leaves a view it will come back to.
    pub fn clear(l: *Layers, w: *Writer, caps: Caps) Writer.Error!void {
        if (caps.pictures() == .kitty) {
            for (l.shown.items) |was| try writeDelete(w, was);
        } else {
            for (l.shown.items) |was| {
                if (was.rect.col >= l.size.cells.cols) continue;
                const cols = @min(was.rect.cols, l.size.cells.cols - was.rect.col);
                if (cols == 0) continue;
                var row: u32 = was.rect.row;
                const bottom = @min(@as(u32, was.rect.row) + was.rect.rows, l.size.cells.rows);
                while (row < bottom) : (row += 1) {
                    try morse.cursorTo(w, row + 1, @as(u32, was.rect.col) + 1);
                    try morse.eraseChars(w, cols);
                }
            }
            l.inline_dirty = true;
        }
        l.shown.clearRetainingCapacity();
        l.declared.clearRetainingCapacity();
    }

    /// How many layers the terminal is showing.
    pub fn count(l: *const Layers) usize {
        return l.shown.items.len;
    }

    fn emitInline(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        if (!l.inlineChanged()) return 0;
        std.mem.sort(Layer, l.declared.items, {}, lessThan);
        var written: usize = 0;
        for (l.declared.items) |layer| {
            const rec = l.image(layer.image) orelse continue;
            if (rec.protocol != caps.pictures()) continue;
            if (layer.rect.col >= l.size.cells.cols or layer.rect.row >= l.size.cells.rows) continue;
            const cols = @min(layer.rect.cols, l.size.cells.cols - layer.rect.col);
            // Without cursor-right support leave one row for the sixel cursor.
            // iTerm images request doNotMoveCursor.
            const bottom = l.size.cells.rows -| @as(u16, if (caps.pictures() == .sixel and !l.sixel_cursor_right) 1 else 0);
            const rows = @min(layer.rect.rows, bottom -| layer.rect.row);
            if (cols == 0 or rows == 0) continue;
            for (l.own_inline.items) |*held| {
                if (held.id != layer.image) continue;
                if (held.sixel) |original| {
                    const cell = l.size.cellSize() orelse continue;
                    const max_width: u32 = @intFromFloat(@min(@as(f64, std.math.maxInt(u32)), @as(f64, cell.width) * cols));
                    const max_height: u32 = @intFromFloat(@min(@as(f64, std.math.maxInt(u32)), @as(f64, cell.height) * rows));
                    const x = @min(layer.source.x, original.width);
                    const y = @min(layer.source.y, original.height);
                    const width = @min(@min(original.width - x, if (layer.source.width == 0) original.width else layer.source.width), @min(max_width, if (caps.sixel_max_width == 0) max_width else caps.sixel_max_width));
                    const height = @min(@min(original.height - y, if (layer.source.height == 0) original.height else layer.source.height), @min(max_height, if (caps.sixel_max_height == 0) max_height else caps.sixel_max_height));
                    if (width == 0 or height == 0) continue;
                    for (0..height) |row| {
                        for (0..width) |col| {
                            const from = (row + y) * original.width + x + col;
                            const to = (row * width + col) * 4;
                            switch (original.pixels) {
                                .rgba => @memcpy(held.scratch[to..][0..4], held.data[from * 4 ..][0..4]),
                                .indexed => {
                                    const index = held.data[from];
                                    const transparent = index == original.transparent;
                                    const color = original.palette[if (transparent) 0 else index];
                                    @memcpy(held.scratch[to..][0..4], &[_]u8{ color.r, color.g, color.b, if (transparent) 0 else 255 });
                                },
                            }
                        }
                    }
                    var image_data = original;
                    image_data.width = width;
                    image_data.height = height;
                    image_data.palette = original.palette[0..@min(original.palette.len, @max(1, caps.sixel_registers))];
                    image_data.pixels = .{ .rgba = held.scratch[0 .. @as(usize, width) * height * 4] };
                    try morse.cursorTo(w, @as(u32, layer.rect.row) + 1, @as(u32, layer.rect.col) + 1);
                    try morse.sixel(w, image_data);
                } else {
                    // iTerm2 has no source rectangle: its caller supplies a
                    // cropped file. Nonzero source/offsets are not representable.
                    if (!std.meta.eql(layer.source, morse.GraphicsRect{}) or layer.x_offset != 0 or layer.y_offset != 0) continue;
                    try morse.cursorTo(w, @as(u32, layer.rect.row) + 1, @as(u32, layer.rect.col) + 1);
                    const file: morse.ItermFile = .{ .width = .{ .cells = cols }, .height = .{ .cells = rows }, .preserve_aspect_ratio = false, .do_not_move_cursor = true };
                    if (held.part_bytes == 0) try morse.itermImage(w, file, held.data) else try morse.itermImageMultipart(w, file, held.data, held.part_bytes);
                }
                written += 1;
            }
        }
        return written;
    }

    //=====================================================================
    // The commands.
    //=====================================================================

    /// One placement, drawn from the cell it is put at.
    fn writePlace(w: *Writer, layer: Layer, z: i32) Writer.Error!void {
        try morse.cursorTo(w, @as(u32, layer.rect.row) + 1, @as(u32, layer.rect.col) + 1);
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

pub const test_access = if (builtin.is_test) struct {
    pub const sharedSize = sharedSizeFixture;
    pub const record = Layers.record;
} else struct {};
const sharedSizeFixture = sharedSize;
