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
const shm = @import("shm.zig");

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
    first: u32,
    last: u32,
    graphics_id: u32,
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
    _current: ?u32 = null,
    _pending: ?u32 = null,
    _dirty: bool = false,

    /// The usable picture id, by value; retire it through this owner.
    pub fn current(p: *const Replacement) ?u32 {
        return p._current;
    }

    /// The picture still awaiting settlement, by value.
    pub fn pending(p: *const Replacement) ?u32 {
        return p._pending;
    }

    pub const Error = Writer.Error || Allocator.Error || error{ Busy, NoImageId, PayloadTooLarge };

    /// Whether another picture can be sent. Call `settle` or `declare` to settle a
    /// ready or refused pending picture before sending the next one.
    pub fn canSend(p: *const Replacement) bool {
        return p._pending == null;
    }

    /// Sends one new picture, returning its id and payload byte count.
    /// On a partial write the recorded image is retired at the next commit
    /// and `takeDirty` asks the owner to produce it again.
    pub fn send(p: *Replacement, layers: *Layers, w: *Writer, ids: *ImageIds, pixels: []const u8, how: Transmit) Error!struct { id: u32, bytes: usize } {
        const gpa = layers._gpa;
        if (!p.canSend()) return error.Busy;
        const id = try ids.acquire(layers);
        // Reserve cleanup before any command can reach the terminal.
        try layers._retired.ensureUnusedCapacity(gpa, 1);
        const bytes = layers.transmit(w, id, pixels, how) catch |err| {
            if (layers.image(id) != null) layers._retired.appendAssumeCapacity(id);
            p._dirty = true;
            return err;
        };
        p._pending = id;
        return .{ .id = id, .bytes = bytes };
    }

    /// Fold acknowledgements and grace into ownership without declaring a
    /// placement. Returns true while a pending image still needs a reply.
    /// Refusals retain a usable current picture and set takeDirty.
    /// On allocation failure, current and pending ownership stay unchanged.
    pub fn settle(p: *Replacement, layers: *Layers, now_ms: i64, grace_ms: i64) Allocator.Error!bool {
        // Reserve every retirement before changing either ownership slot.
        const current_failed = if (p._current) |id| if (layers.image(id)) |img| img.state == .failed else true else false;
        const reserve: usize = if (p._pending != null) 1 + @as(usize, @intFromBool(p._current != null)) else @intFromBool(current_failed);
        try layers._retired.ensureUnusedCapacity(layers._gpa, reserve);
        if (p._pending) |id| {
            const ready = layers.ready(id, now_ms, grace_ms);
            const failed = if (layers.image(id)) |img| img.state == .failed else true;
            if (failed) {
                try layers.retire(id);
                p._pending = null;
                p._dirty = true;
            } else if (ready) {
                if (p._current) |old| try layers.retire(old);
                p._current = id;
                p._pending = null;
            }
        }
        if (p._current) |id| {
            const failed = if (layers.image(id)) |img| img.state == .failed else true;
            if (failed) {
                try layers.retire(id);
                p._current = null;
                p._dirty = true;
            }
        }
        return p._pending != null;
    }

    /// Settle and declare at want, overriding its image id. Returns true
    /// while a pending image needs another frame. A null want leaves
    /// ownership unsettled and makes no declaration; use settle explicitly
    /// to advance hidden pictures.
    pub fn declare(p: *Replacement, layers: *Layers, want: ?Layer, now_ms: i64, grace_ms: i64) Allocator.Error!bool {
        var at = want orelse return p._pending != null;
        // A declaration must be able to commit after ownership changes.
        try layers._declared.ensureUnusedCapacity(layers._gpa, 1);
        const waiting = try p.settle(layers, now_ms, grace_ms);
        if (p._current) |id| {
            at.image = id;
            try layers.declare(at);
        }
        return waiting;
    }

    /// Whether a refusal or write failure asked for another picture since
    /// last checked. Call `settle` or `declare` after `Layers.ack` to fold refusals in.
    pub fn takeDirty(p: *Replacement) bool {
        defer p._dirty = false;
        return p._dirty;
    }

    /// Retires everything this value owns at the next committed frame.
    pub fn retire(p: *Replacement, layers: *Layers) Allocator.Error!void {
        const gpa = layers._gpa;
        try layers._retired.ensureUnusedCapacity(gpa, 2);
        if (p._current) |id| {
            try layers.retire(id);
            layers.undeclareImage(id);
        }
        if (p._pending) |id| {
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

/// The images this program has sent, and what this frame shows of them.
pub const Layers = struct {
    _gpa: Allocator,

    // Fields prefixed _ are implementation storage; use metadata accessors.
    /// The images the terminal holds for this program, one per id. Sending
    /// to an id replaces its entry and freeing one removes it, so the list
    /// is as long as the pictures that are alive.
    _images: std.ArrayList(Image) = .empty,
    /// What this frame has declared, in declaration order.
    _declared: std.ArrayList(Layer) = .empty,
    /// What the terminal is showing, after the last `emit`.
    _shown: std.ArrayList(Layer) = .empty,
    /// Images freed only after a complete frame stopped declaring them.
    _retired: std.ArrayList(u32) = .empty,
    /// Whether this terminal answers a transmit: unknown until the first
    /// answer (true), or until a grace period runs out with no answer ever
    /// (false), after which direct transmissions are not waited for.
    _answers: ?bool = null,
    /// How many images were taken as ready because the grace period ran
    /// out rather than because the terminal said so.
    _fallbacks: u32 = 0,
    /// The deflate window, made the first time a picture is compressed and
    /// kept for the next.
    _window: []u8 = &.{},
    /// Where a picture is deflated to, kept and reused for the next, so
    /// sending pictures frame after frame allocates nothing once the buffer
    /// has grown to the largest of them.
    _deflated: std.ArrayList(u8) = .empty,
    /// Whether the next `emit` places every declared layer, whatever `shown`
    /// says, because the terminal may have moved or dropped any of them.
    _replace_all: bool = false,
    /// Pictures through shared memory, where the program allows it (the
    /// terminal is on this machine, or may be): null sends every picture
    /// in the escape code.
    _shared_memory: ?SharedMemory = null,
    _shared_objects: std.ArrayList(SharedObject) = .empty,

    /// Captures the allocator for every image, placement and scratch buffer.
    pub fn init(gpa: Allocator) Layers {
        return .{ ._gpa = gpa };
    }

    /// Borrowed metadata; expires when images change or Layers is destroyed.
    pub fn images(l: *const Layers) []const Image {
        return l._images.items;
    }
    /// This frame's declarations, borrowed until a declaration or frame commit.
    pub fn declarations(l: *const Layers) []const Layer {
        return l._declared.items;
    }
    /// The placements last committed, borrowed until the next frame or clear.
    pub fn placements(l: *const Layers) []const Layer {
        return l._shown.items;
    }
    /// Whether a frame must process pictures or retirements.
    pub fn hasFrameWork(l: *const Layers) bool {
        return l._declared.items.len != 0 or l._shown.items.len != 0 or l._retired.items.len != 0;
    }
    /// The terminal's learned direct-transmission answer policy.
    pub fn answerPolicy(l: *const Layers) ?bool {
        return l._answers;
    }
    /// Images accepted after their answer grace period.
    pub fn fallbackCount(l: *const Layers) u32 {
        return l._fallbacks;
    }

    /// Allows shared memory through `io`, or disables it with null. This
    /// changes future transmissions; live objects keep their own cleanup Io.
    /// Repeating the same configuration keeps the terminal's learned answer.
    /// Disable and enable again to retry a refused medium. The supplied Io
    /// must outlive every outstanding object, including after configuration changes.
    pub fn configureSharedMemory(l: *Layers, io: ?std.Io) void {
        if (io) |next| {
            if (l._shared_memory) |current| {
                if (current.io.userdata == next.userdata and current.io.vtable == next.vtable) return;
            }
            l._shared_memory = .{ .io = next, .generation = shm.nextNamespace() };
        } else l._shared_memory = null;
    }

    /// Gives the lists and the window back, and unlinks any picture still
    /// in shared memory.
    pub fn deinit(l: *Layers) void {
        const gpa = l._gpa;
        for (l._shared_objects.items) |object| object.deinit();
        l._shared_objects.deinit(gpa);
        l._images.deinit(gpa);
        l._declared.deinit(gpa);
        l._shown.deinit(gpa);
        l._retired.deinit(gpa);
        gpa.free(l._window);
        l._deflated.deinit(gpa);
        l.* = undefined;
    }

    /// What the program knows about an image, or null.
    pub fn image(l: *const Layers, id: u32) ?Image {
        return (l.find(id) orelse return null).*;
    }

    fn find(l: *const Layers, id: u32) ?*Image {
        for (l._images.items) |*held| {
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
        const gpa = l._gpa;
        if (l._shared_memory) |*sm| if (sm.state != .no and how.format != .png) {
            if (try l.transmitShared(w, sm, id, pixels, how)) |n| return n;
        };
        var packed_pixels: std.Io.Writer.Allocating = .fromArrayList(gpa, &l._deflated);
        defer l._deflated = packed_pixels.toArrayList();
        packed_pixels.clearRetainingCapacity();
        var payload = pixels;
        var compressed = false;
        if (how.compress and how.format != .png and pixels.len > 64) {
            if (l._window.len == 0) l._window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            try packed_pixels.ensureTotalCapacity(pixels.len / 8 + 1024);
            var deflate = std.compress.flate.Compress.init(
                &packed_pixels.writer,
                l._window,
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
        const gpa = l._gpa;
        if (l.find(rec.id) == null) try l._images.ensureUnusedCapacity(gpa, 1);
        l.recordReserved(rec);
    }

    fn recordReserved(l: *Layers, rec: Image) void {
        if (l.find(rec.id)) |held| {
            l.release(held);
            held.* = rec;
        } else l._images.appendAssumeCapacity(rec);
        l.forgetShown(rec.id);
    }

    /// The picture put in shared memory and its name sent, or null when it
    /// could not be put there (the medium is then off, and the caller's
    /// picture goes in the escape code). While the medium is on trial the
    /// terminal is asked to answer, whatever the caller asked.
    fn transmitShared(l: *Layers, w: *Writer, sm: *SharedMemory, id: u32, pixels: []const u8, how: Transmit) (Writer.Error || Allocator.Error || error{PayloadTooLarge})!?usize {
        const gpa = l._gpa;
        const size = try sharedSize(pixels.len);
        // Reserve before the OS object exists. Once it does, the image
        // record can take its name without any further allocation.
        if (l.find(id) == null) try l._images.ensureUnusedCapacity(gpa, 1);
        if (l.sharedObject(id) == null) try l._shared_objects.ensureUnusedCapacity(gpa, 1);
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
        l._shared_objects.appendAssumeCapacity(object);
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
        for (l._shared_objects.items) |object| {
            if (object.id == id) return object;
        }
        return null;
    }

    fn release(l: *Layers, held: *Image) void {
        held.shm = null;
        for (l._shared_objects.items, 0..) |object, i| {
            if (object.id != held.id) continue;
            const owned = l._shared_objects.swapRemove(i);
            owned.deinit();
            return;
        }
    }

    // A reply to an object from an earlier configuration cannot settle the
    // current medium's trial or turn that medium off.
    fn policyFor(l: *Layers, object: SharedObject) ?*SharedMemory {
        const policy = if (l._shared_memory) |*sm| sm else return null;
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
                if (shared == null and l._answers == false) {
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
                l._fallbacks += 1;
                if (l._answers == null) l._answers = false;
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
        l._answers = true;
        held.state = if (response.ok()) .ready else .failed;
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
        try morse.deleteImage(w, .{ .target = .{ .image = .{ .id = id } }, .free = true, .quiet = .silent });
        var i: usize = 0;
        while (i < l._images.items.len) {
            if (l._images.items[i].id == id) {
                l.release(&l._images.items[i]);
                _ = l._images.swapRemove(i);
            } else i += 1;
        }
        l.forgetShown(id);
        l.undeclareImage(id);
        var retired_i: usize = 0;
        while (retired_i < l._retired.items.len) {
            if (l._retired.items[retired_i] == id) {
                _ = l._retired.swapRemove(retired_i);
            } else retired_i += 1;
        }
    }

    /// Frees `id` inside `commitFrame`, after placements and deletions.
    /// A still-declared image is kept until a later frame stops using it.
    pub fn retire(l: *Layers, id: u32) Allocator.Error!void {
        const gpa = l._gpa;
        if (std.mem.indexOfScalar(u32, l._retired.items, id) != null) return;
        try l._retired.append(gpa, id);
    }

    /// Frees every image. What a program writes on the way out.
    pub fn freeAll(l: *Layers, w: *Writer) Writer.Error!void {
        while (l._images.items.len > 0) try l.free(w, l._images.items[l._images.items.len - 1].id);
        l._shown.clearRetainingCapacity();
        l._declared.clearRetainingCapacity();
    }

    /// Shows a layer this frame.
    ///
    /// Declaring the same image and placement twice in a frame keeps the
    /// second: that is how a picture is moved, and it costs one command
    /// rather than a delete and a place.
    pub fn declare(l: *Layers, layer: Layer) Allocator.Error!void {
        const gpa = l._gpa;
        for (l._declared.items) |*held| {
            if (held.sameAs(layer)) {
                held.* = layer;
                return;
            }
        }
        try l._declared.append(gpa, layer);
    }

    /// Takes a layer off the frame it would otherwise still be in.
    pub fn undeclare(l: *Layers, image_id: u32, placement: u32) void {
        var i: usize = 0;
        while (i < l._declared.items.len) : (i += 1) {
            const held = l._declared.items[i];
            if (held.image == image_id and held.placement == placement) {
                _ = l._declared.orderedRemove(i);
                return;
            }
        }
    }

    fn undeclareImage(l: *Layers, id: u32) void {
        var i: usize = 0;
        while (i < l._declared.items.len) {
            if (l._declared.items[i].image == id) {
                _ = l._declared.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Drops the record of an image's placements, which the terminal has
    /// taken down itself.
    fn forgetShown(l: *Layers, id: u32) void {
        var i: usize = 0;
        while (i < l._shown.items.len) {
            if (l._shown.items[i].image == id) {
                _ = l._shown.orderedRemove(i);
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
        l._replace_all = true;
    }

    /// The placements and the deletions, after the text pass, in one block:
    /// every placement first, then the deletions, so a picture that replaces
    /// another covers it before it goes.
    ///
    /// Writes nothing when nothing moved, so a caller may call it twice and
    /// a renderer that calls it for them costs nothing.
    pub fn emit(l: *Layers, w: *Writer, caps: Caps) Writer.Error!usize {
        if (!caps.kitty_graphics) return 0;
        std.mem.sort(Layer, l._declared.items, {}, lessThan);
        var written: usize = 0;

        // Here: a placement command, which replaces whatever was at the same
        // image and placement id without flicker.
        for (l._declared.items, 0..) |now, i| {
            if (!l._replace_all) if (findSameIndex(l._shown.items, now)) |before_i| {
                const before = l._shown.items[before_i];
                if (before.eql(now) and zOf(now, i) == zOf(before, before_i)) continue;
            };
            try writePlace(w, now, zOf(now, i));
            written += 1;
        }
        // Gone: name the one placement rather than everything on screen, and
        // keep the image's pixels, because the program may show it again.
        for (l._shown.items) |was| {
            if (findSameIndex(l._declared.items, was) != null) continue;
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
        if (!caps.kitty_graphics) {
            l._declared.clearRetainingCapacity();
            return 0;
        }
        var freed: usize = 0;
        var i: usize = 0;
        while (i < l._retired.items.len) {
            const id = l._retired.items[i];
            var declared = false;
            for (l._declared.items) |layer| if (layer.image == id) {
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
        l._replace_all = false;
        const was_shown = l._shown;
        l._shown = l._declared;
        l._declared = was_shown;
        l._declared.clearRetainingCapacity();
        return freed;
    }

    /// Takes every placement off the screen, keeping the images. What a
    /// program writes when it leaves a view it will come back to.
    pub fn clear(l: *Layers, w: *Writer, caps: Caps) Writer.Error!void {
        if (!caps.kitty_graphics) return;
        for (l._shown.items) |was| try writeDelete(w, was);
        l._shown.clearRetainingCapacity();
        l._declared.clearRetainingCapacity();
    }

    /// How many layers the terminal is showing.
    pub fn count(l: *const Layers) usize {
        return l._shown.items.len;
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
    try l.record(.{ .id = id });
    const next = try ids.acquire(&l);
    try l.record(.{ .id = next });
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
    try testing.expectEqual(std.math.maxInt(u32), try sharedSize(std.math.maxInt(u32)));
    if (@bitSizeOf(usize) <= 32) return error.SkipZigTest;
    const oversized: usize = @as(usize, std.math.maxInt(u32)) + 1;
    try testing.expectError(error.PayloadTooLarge, sharedSize(oversized));
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
