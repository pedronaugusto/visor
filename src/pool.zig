//! The bytes a screen owns: the graphemes too long to live in a cell, and
//! the OSC 8 targets its cells point at.
//!
//! Both are interned. A grapheme written twice is stored once and both cells
//! hold the same offset, which is what lets `Cell.eql` compare two cells
//! without comparing two strings. A link written twice is one entry, and its
//! parameters are part of its identity: two targets that differ only by an
//! `id=` are two links, because they are two links to the terminal.
//!
//! An offset stays valid within one pool generation. `Screen.compactPool`
//! and resize replace these pools and rewrite live cells; the renderer
//! detects the changed generation and forgets its previous identities.
//! Growable storage can move while offsets stay valid, so borrowed slices
//! have a shorter lifetime than those offsets. `Graphemes.reset` invalidates
//! offsets too; its caller clears the grid and repaints.
//! Nothing here wraps or reuses an offset behind a live cell.

const std = @import("std");
const cellmod = @import("cell.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Text = cellmod.internal.StoredCell.Text;
const Link = @TypeOf(@as(cellmod.internal.StoredCell, .{}).link);
const PoolGeneration = cellmod.PoolGeneration;
const GraphemeOffset = cellmod.GraphemeOffset;
const LinkIndex = cellmod.LinkIndex;
const LinkOffset = cellmod.LinkOffset;
const aegis = @import("dependencies.zig").aegis;
const ByteLength = cellmod.ByteLength;

// Identities never wrap: exhaustion refuses creation instead of reusing a
// handle. The 48-bit namespace fits in Link's upper bits and Text's bytes.
// aegis: safe-type-internals: this atomic issuer validates the 48-bit ceiling
// before CAS; its public result is PoolGeneration and can never wrap.
var generations: std.atomic.Value(u64) = .init(1);

pub fn nextGeneration() PoolGeneration {
    var next = generations.load(.monotonic);
    while (true) {
        if (next > std.math.maxInt(u48)) @panic("pool identities exhausted");
        next = generations.cmpxchgWeak(next, next + 1, .monotonic, .monotonic) orelse return .fromRaw(next);
    }
}

/// The longest grapheme, link target or link parameter list a pool names:
/// a length is sixteen bits. The screen refuses longer ones before they
/// reach a pool (`error.TooLong`), so here it is an invariant.
pub const max_len = std.math.maxInt(u16);

fn pooledText(offset: GraphemeOffset, len: ByteLength) Text {
    var t: Text = .{ .buf = @splat(0), .len = Text.pooled };
    std.mem.writeInt(u32, t.buf[0..4], offset.raw(), .little);
    std.mem.writeInt(u16, t.buf[4..6], len.raw(), .little);
    // What `Text.offset` and `Text.length` read back is what was written.
    assert(t.offset().? == offset);
    assert(t.length() == len);
    return t;
}

fn pooledLink(index: LinkIndex) Link {
    // Zero is `.none`, so the last index has no handle.
    const next = index.successor() catch unreachable; // unreachable: the last index has no handle, and is refused when interning
    const link: Link = @fromBackingInt(next.raw());
    assert(link.index().? == index);
    return link;
}

/// The pool of graphemes longer than a cell holds inline.
pub const Graphemes = struct {
    /// The allocator `init` was given, which the pool grows and is freed with.
    gpa: Allocator,
    /// Every long grapheme, back to back, in the order they were first seen.
    bytes: std.ArrayList(u8) = .empty,
    /// Where each one is, keyed by what it says.
    index: Index = .empty,

    const Index = std.HashMapUnmanaged(Entry, void, Context, std.hash_map.default_max_load_percentage);

    /// One interned grapheme's place in `bytes`.
    pub const Entry = struct { offset: GraphemeOffset, len: ByteLength };

    /// Hashing and equality for an `Entry`, which both have to read the
    /// bytes it points at.
    // aegis: safe-type-internals: intern validates every Entry before publication.
    // Hash/equality extract its byte address only for slicing that owned pool.
    pub const Context = struct {
        bytes: []const u8,

        pub fn hash(ctx: Graphemes.Context, e: Graphemes.Entry) u64 {
            return std.hash.Wyhash.hash(0, ctx.bytes[e.offset.raw()..][0..e.len.raw()]);
        }
        pub fn eql(ctx: Graphemes.Context, a: Graphemes.Entry, b: Graphemes.Entry) bool {
            return std.mem.eql(u8, ctx.bytes[a.offset.raw()..][0..a.len.raw()], ctx.bytes[b.offset.raw()..][0..b.len.raw()]);
        }
    };

    /// The same, for a lookup by the grapheme itself rather than by an entry
    /// already in the pool.
    pub const Adapted = struct {
        bytes: []const u8,

        pub fn hash(_: Graphemes.Adapted, key: []const u8) u64 {
            return std.hash.Wyhash.hash(0, key);
        }
        pub fn eql(ctx: Graphemes.Adapted, key: []const u8, e: Graphemes.Entry) bool {
            return std.mem.eql(u8, key, ctx.bytes[e.offset.raw()..][0..e.len.raw()]);
        }
    };

    /// An empty pool that grows with `gpa`.
    pub fn init(gpa: Allocator) Graphemes {
        return .{ .gpa = gpa };
    }

    /// Gives the pool back.
    pub fn deinit(p: *Graphemes) void {
        p.bytes.deinit(p.gpa);
        p.index.deinit(p.gpa);
        p.* = undefined;
    }

    /// A grapheme as a `Cell.Text`: in the cell when it fits, in the pool
    /// when it does not, and never twice in the pool.
    ///
    /// Allocates only when the grapheme is longer than six bytes and has
    /// not been seen before, which is never for ASCII and rare for anything
    /// else. The grapheme is at most `max_len` bytes.
    pub fn intern(p: *Graphemes, grapheme: []const u8) Allocator.Error!Text {
        const gpa = p.gpa;
        if (grapheme.len <= Text.max_inline) return .inlined(grapheme);
        assert(grapheme.len <= max_len);
        const byte_len: ByteLength = .fromRaw(@intCast(grapheme.len)); // safe: Screen checked max_len before interning

        const found = p.index.getEntryAdapted(grapheme, Adapted{ .bytes = p.bytes.items });
        if (found) |e| return pooledText(e.key_ptr.offset, e.key_ptr.len);

        const offset: GraphemeOffset = .fromRaw(aegis.int.cast(u32, p.bytes.items.len) catch return error.OutOfMemory);
        const end = try appendEnd(p.bytes.items.len, grapheme.len);
        const borrowed = aliasOffset(p.bytes.items, grapheme);
        try p.bytes.ensureUnusedCapacity(gpa, grapheme.len);
        try p.index.ensureUnusedCapacityContext(gpa, 1, .{ .bytes = p.bytes.items });
        const source = if (borrowed) |off| p.bytes.items[off..][0..grapheme.len] else grapheme;
        p.bytes.appendSliceAssumeCapacity(source);
        // The entry names the bytes just appended, the end of the pool.
        assert(end.raw() == p.bytes.items.len);
        const entry: Entry = .{ .offset = offset, .len = byte_len };
        p.index.putAssumeCapacityContext(entry, {}, .{ .bytes = p.bytes.items });
        return pooledText(offset, byte_len);
    }

    /// What `slice` fails with: a handle this pool did not issue.
    pub const SliceError = error{InvalidHandle};

    /// The bytes of a grapheme, whichever tier it is in.
    /// Internal offsets are bounded here; Screen checks public pool identities.
    ///
    /// The `Text` is taken by pointer because a short grapheme lives in it:
    /// the bytes come back borrowed from whatever holds the cell, and a
    /// temporary would be gone by the time they were read. Pooled bytes
    /// borrow from the growable pool: interning unrelated graphemes can
    /// invalidate them. Reset, compaction, resize and deinitialization also
    /// invalidate pooled slices.
    pub fn slice(p: *const Graphemes, t: *const Text) SliceError![]const u8 {
        if (!t.isPooled()) return t.inlineSlice() orelse error.InvalidHandle;
        const off: usize = t.offset().?.raw();
        const n = t.length().raw();
        if (off > p.bytes.items.len or n > p.bytes.items.len - off) return error.InvalidHandle;
        return p.bytes.items[off..][0..n];
    }

    /// Empties the pool, keeping the memory. Pooled `Cell.Text` handles
    /// held before this become invalid; Screen owns their checked exports.
    /// The caller clears the grid and repaints.
    pub fn reset(p: *Graphemes) void {
        p.bytes.clearRetainingCapacity();
        p.index.clearRetainingCapacity();
    }

    /// How many bytes of grapheme the screen is holding.
    pub fn len(p: *const Graphemes) usize {
        return p.bytes.items.len;
    }

    /// Whether `length` bytes at `offset` lie inside what the pool holds.
    pub fn holds(p: *const Graphemes, offset: GraphemeOffset, length: ByteLength) bool {
        const start: aegis.units.Bytes(usize) = .fromRaw(offset.raw());
        const end = start.add(.fromRaw(length.raw())) catch return false;
        return end.compare(.fromRaw(p.bytes.items.len)) != .gt;
    }
};

/// One OSC 8 target: where the terminal is told to go, and the parameters it
/// is told alongside. Both slices borrow from the link pool; interning
/// unrelated links can invalidate them, as can compaction, resize and
/// deinitialization. Use `Screen.dupeTarget` to retain one.
pub const Target = struct {
    /// The URI, which the terminal opens on a click.
    uri: []const u8,
    /// The `key=value:key=value` list, or an empty slice for none. `id=` is
    /// the one terminals act on, and two targets that differ only there are
    /// two targets.
    params: []const u8,
};

/// An independent copy of a link target. `deinit` releases both slices
/// through the allocator the copy was made with.
pub const OwnedTarget = struct {
    /// Private: the allocator the copies were made with, which frees them.
    gpa: Allocator,
    /// Private: the copied URI.
    uri: []const u8,
    /// Private: the copied parameters.
    params: []const u8,

    /// Copies both target slices, retaining the allocator that releases them.
    pub fn init(gpa: Allocator, source: Target) Allocator.Error!OwnedTarget {
        const uri = try gpa.dupe(u8, source.uri);
        errdefer gpa.free(uri);
        const params = try gpa.dupe(u8, source.params);
        return .{ .gpa = gpa, .uri = uri, .params = params };
    }

    /// The target borrowed read-only until deinit. The slice descriptors are copies.
    pub fn target(t: *const OwnedTarget) Target {
        return .{ .uri = t.uri, .params = t.params };
    }

    pub fn deinit(t: *OwnedTarget) void {
        t.gpa.free(t.uri);
        t.gpa.free(t.params);
        t.* = undefined;
    }
};

/// Every link a screen's cells point at.
pub const Links = struct {
    /// The allocator `init` was given, which the table grows and is freed with.
    gpa: Allocator,
    /// The URIs and parameter lists, back to back.
    bytes: std.ArrayList(u8) = .empty,
    /// One entry a link, in the order they were first seen.
    entries: std.ArrayList(Entry) = .empty,
    /// Which link a target already has.
    index: Index = .empty,

    const Index = std.HashMapUnmanaged(LinkIndex, void, Context, std.hash_map.default_max_load_percentage);

    /// Where a link's two strings are.
    pub const Entry = struct { uri_off: LinkOffset, uri_len: ByteLength, params_off: LinkOffset, params_len: ByteLength };

    // aegis: safe-type-internals: this index contains only published LinkIndex values.
    // Resolution bounds them against this table before extracting byte offsets.
    pub const Context = struct {
        links: *const Links,

        pub fn hash(ctx: Links.Context, i: LinkIndex) u64 {
            return hashTarget(ctx.links.get(pooledLink(i)).?);
        }
        pub fn eql(ctx: Links.Context, a: LinkIndex, b: LinkIndex) bool {
            return eqlTarget(ctx.links.get(pooledLink(a)).?, ctx.links.get(pooledLink(b)).?);
        }
    };

    pub const Adapted = struct {
        links: *const Links,

        pub fn hash(_: Links.Adapted, key: Target) u64 {
            return hashTarget(key);
        }
        pub fn eql(ctx: Links.Adapted, key: Target, i: LinkIndex) bool {
            return eqlTarget(key, ctx.links.get(pooledLink(i)).?);
        }
    };

    fn hashTarget(t: Target) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(t.uri);
        h.update(&.{0});
        h.update(t.params);
        return h.final();
    }

    fn eqlTarget(a: Target, b: Target) bool {
        return std.mem.eql(u8, a.uri, b.uri) and std.mem.eql(u8, a.params, b.params);
    }

    /// An empty table that grows with `gpa`.
    pub fn init(gpa: Allocator) Links {
        return .{ .gpa = gpa };
    }

    /// Gives the table back.
    pub fn deinit(l: *Links) void {
        l.index.deinit(l.gpa);
        l.bytes.deinit(l.gpa);
        l.entries.deinit(l.gpa);
        l.* = undefined;
    }

    /// The link for a target, interned: the same URI and parameters always
    /// give the same `Link`. Each is at most `max_len` bytes. A table
    /// holding every link a sixteen-bit handle names is out of memory.
    pub fn intern(l: *Links, uri: []const u8, params: []const u8) Allocator.Error!Link {
        if (uri.len == 0) return .none;
        const target: Target = .{ .uri = uri, .params = params };
        if (l.index.getKeyAdapted(target, Adapted{ .links = l })) |i| return pooledLink(i);
        return l.append(uri, params);
    }

    // Keep allocation and extent checks out of the repeated-link lookup's
    // register set. A miss alone needs this path and its larger stack frame.
    noinline fn append(l: *Links, uri: []const u8, params: []const u8) Allocator.Error!Link {
        const gpa = l.gpa;
        assert(uri.len <= max_len);
        assert(params.len <= max_len);
        const uri_len: ByteLength = .fromRaw(@intCast(uri.len)); // safe: Screen checked max_len before interning
        const params_len: ByteLength = .fromRaw(@intCast(params.len)); // safe: Screen checked max_len before interning
        const uri_off: LinkOffset = .fromRaw(aegis.int.cast(u32, l.bytes.items.len) catch return error.OutOfMemory);
        const i: LinkIndex = .fromRaw(aegis.int.cast(u16, l.entries.items.len) catch return error.OutOfMemory);
        if (i.eql(.fromRaw(std.math.maxInt(u16)))) return error.OutOfMemory;

        const added = aegis.units.Bytes(u32).fromRaw(uri_len.raw()).add(.fromRaw(params_len.raw())) catch return error.OutOfMemory;
        const end = try appendEnd(l.bytes.items.len, added.raw());
        const params_start = try appendEnd(l.bytes.items.len, uri_len.raw());
        const params_off: LinkOffset = .fromRaw(params_start.raw());

        const uri_borrowed = aliasOffset(l.bytes.items, uri);
        const params_borrowed = aliasOffset(l.bytes.items, params);
        try l.bytes.ensureUnusedCapacity(gpa, added.raw());
        try l.entries.ensureUnusedCapacity(gpa, 1);
        try l.index.ensureUnusedCapacityContext(gpa, 1, .{ .links = l });

        const uri_source = if (uri_borrowed) |off| l.bytes.items[off..][0..uri.len] else uri;
        l.bytes.appendSliceAssumeCapacity(uri_source);
        const params_source = if (params_borrowed) |off| l.bytes.items[off..][0..params.len] else params;
        l.bytes.appendSliceAssumeCapacity(params_source);
        // The two strings sit back to back at the end of the pool, which is
        // where `get` reads them from.
        assert(end.raw() == l.bytes.items.len);
        l.entries.appendAssumeCapacity(.{
            .uri_off = uri_off,
            .uri_len = uri_len,
            .params_off = params_off,
            .params_len = params_len,
        });
        l.index.putAssumeCapacityContext(i, {}, .{ .links = l });
        return pooledLink(i);
    }

    /// The target a stored link names, or null for `.none` or an index outside this table. The returned slices borrow from the growable
    /// link pool: further interning, compaction, resize or deinitialization
    /// can invalidate them even when the original cell is unchanged.
    pub fn get(l: *const Links, link: Link) ?Target {
        if (link == .none) return null;
        const i = link.index() orelse return null;
        if (!l.contains(i)) return null;
        const e = l.entries.items[i.raw()];
        return .{
            .uri = l.bytes.items[e.uri_off.raw()..][0..e.uri_len.raw()],
            .params = l.bytes.items[e.params_off.raw()..][0..e.params_len.raw()],
        };
    }

    /// How many links the screen is holding.
    pub fn count(l: *const Links) usize {
        return l.entries.items.len;
    }

    /// Whether `index` names an entry of the table.
    pub fn contains(l: *const Links, index: LinkIndex) bool {
        const entries: LinkIndex = .fromRaw(@intCast(l.entries.items.len)); // safe: append refuses the last u16 index
        return index.compare(entries) == .lt;
    }
};

/// Checks the complete addressable byte extent before allocation or mutation.
fn appendEnd(current: usize, added: usize) Allocator.Error!aegis.units.Bytes(u32) {
    const bytes: aegis.units.Bytes(usize) = .fromRaw(current);
    const end = bytes.add(.fromRaw(added)) catch return error.OutOfMemory;
    return end.convert(u32) catch return error.OutOfMemory;
}

/// The offset of a slice borrowed from `storage`, saved across a possible
/// reallocation. Empty slices need no preservation.
// aegis: no-danger: addresses are compared to preserve a borrowed slice across
// growth; the result is only a local offset, never a public identity or pointer.
fn aliasOffset(storage: []const u8, bytes: []const u8) ?usize {
    if (bytes.len == 0 or storage.len == 0) return null;
    const base = @intFromPtr(storage.ptr); // safe: compared as numbers, never dereferenced
    const at = @intFromPtr(bytes.ptr); // safe: compared as numbers, never dereferenced
    if (at < base or at - base > storage.len) return null;
    const off = at - base;
    if (bytes.len > storage.len - off) return null;
    return off;
}

const testing = std.testing;

test "a short grapheme never reaches the pool" {
    var p: Graphemes = .init(testing.allocator);
    defer p.deinit();

    const a = try p.intern("a");
    try testing.expect(!a.isPooled());
    try testing.expectEqual(@as(usize, 0), p.len());
    try testing.expectEqualStrings("a", try p.slice(&a));

    const six = try p.intern("123456");
    try testing.expect(!six.isPooled());
    try testing.expectEqual(@as(usize, 0), p.len());

    // Seven is one too many, and the warning sign with its presentation
    // selector -- the cluster the drift rule exists for -- is exactly six.
    const seven = try p.intern("1234567");
    try testing.expect(seven.isPooled());
    try testing.expect(!(try p.intern("\u{26a0}\u{fe0f}")).isPooled());
}

test "a long grapheme is pooled once however often it is written" {
    var p: Graphemes = .init(testing.allocator);
    defer p.deinit();

    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    const first = try p.intern(family);
    try testing.expect(first.isPooled());
    try testing.expectEqualStrings(family, try p.slice(&first));
    const after = p.len();

    for (0..64) |_| {
        const again = try p.intern(family);
        try testing.expect(Text.eql(first, again));
    }
    try testing.expectEqual(after, p.len());
}

test "two different long graphemes get two places" {
    var p: Graphemes = .init(testing.allocator);
    defer p.deinit();

    const a = try p.intern("\u{1f468}\u{200d}\u{1f469}");
    const b = try p.intern("\u{1f468}\u{200d}\u{1f467}");
    try testing.expect(!Text.eql(a, b));
    try testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f469}", try p.slice(&a));
    try testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f467}", try p.slice(&b));
}

test "interning survives the pool being grown under it" {
    var p: Graphemes = .init(testing.allocator);
    defer p.deinit();

    var kept: [64]Text = undefined;
    var buf: [16]u8 = undefined;
    for (0..64) |i| {
        const g = try std.mem.print(&buf, "long-{d:0>8}", .{i});
        kept[i] = try p.intern(g);
    }
    for (0..64) |i| {
        const g = try std.mem.print(&buf, "long-{d:0>8}", .{i});
        try testing.expectEqualStrings(g, try p.slice(&kept[i]));
        try testing.expect(Text.eql(kept[i], try p.intern(g)));
    }
}

test "interning a borrowed substring survives pool growth" {
    var p: Graphemes = .init(testing.allocator);
    defer p.deinit();

    const whole = try p.intern("x-borrowed-long");
    p.bytes.shrinkAndFree(testing.allocator, p.bytes.items.len);
    const borrowed = (try p.slice(&whole))[2..];
    const part = try p.intern(borrowed);
    try testing.expectEqualStrings("borrowed-long", try p.slice(&part));
}

test "a link is interned and its parameters are part of it" {
    var l: Links = .init(testing.allocator);
    defer l.deinit();

    const a = try l.intern("https://ziglang.org", "");
    const b = try l.intern("https://ziglang.org", "");
    const c = try l.intern("https://ziglang.org", "id=1");
    const d = try l.intern("https://ziglang.org", "id=2");

    try testing.expectEqual(a, b);
    try testing.expect(a != c);
    try testing.expect(c != d);
    try testing.expectEqual(@as(usize, 3), l.count());
    try testing.expectEqualStrings("https://ziglang.org", l.get(a).?.uri);
    try testing.expectEqualStrings("", l.get(a).?.params);
    try testing.expectEqualStrings("id=2", l.get(d).?.params);
}

test "an empty uri is no link at all" {
    var l: Links = .init(testing.allocator);
    defer l.deinit();
    try testing.expectEqual(Link.none, try l.intern("", "id=1"));
    try testing.expectEqual(@as(?Target, null), l.get(.none));
    try testing.expectEqual(@as(usize, 0), l.count());
}

test "interning a borrowed target survives link-pool growth" {
    var l: Links = .init(testing.allocator);
    defer l.deinit();

    const whole = try l.intern("x-https://example.test", "x-id=borrowed");
    l.bytes.shrinkAndFree(testing.allocator, l.bytes.items.len);
    const target = l.get(whole).?;
    const part = try l.intern(target.uri[2..], target.params[2..]);
    try testing.expectEqualStrings("https://example.test", l.get(part).?.uri);
    try testing.expectEqualStrings("id=borrowed", l.get(part).?.params);
}

test "a link index from another screen reads as nothing" {
    var l: Links = .init(testing.allocator);
    defer l.deinit();
    _ = try l.intern("a://b", "");
    try testing.expectEqual(@as(?Target, null), l.get(pooledLink(.fromRaw(9))));
}

/// Tests only. Every allocation-failure check runs over it: each growth is then an
/// allocation in every run, so the count of allocations to fail repeats.
const NoResize = @import("shakedown").alloc.NoResize;

test "the pool gives its memory back under a failing allocator" {
    var no_resize: NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(gpa: Allocator) !void {
            var p: Graphemes = .init(gpa);
            defer p.deinit();
            var l: Links = .init(gpa);
            defer l.deinit();
            var buf: [24]u8 = undefined;
            for (0..24) |i| {
                const g = try std.mem.print(&buf, "grapheme-{d:0>6}", .{i});
                _ = try p.intern(g);
                _ = try l.intern(g, "id=x");
            }
        }
    }.run, .{});
}

test "pool address exhaustion is rejected before allocation or mutation" {
    var fail: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var no_resize: NoResize = .init(fail.allocator());
    var storage: [1]u8 = .{0};
    const address: [*]u8 = @ptrCast(&storage); // safe: synthetic extent is never read; growth fails before append on the old implementation
    const limit = std.math.maxInt(u32);
    var graphemes: Graphemes = .init(no_resize.allocator());
    graphemes.bytes.items = address[0..limit];
    graphemes.bytes.capacity = limit;
    defer graphemes.bytes = .empty;
    try testing.expectError(error.OutOfMemory, graphemes.intern("long-cluster"));
    try testing.expect(!fail.has_induced_failure);
    try testing.expectEqual(@as(usize, limit), graphemes.bytes.items.len);
    try testing.expectEqual(@as(u32, 0), graphemes.index.count());

    var links: Links = .init(no_resize.allocator());
    links.bytes.items = address[0 .. limit - 1];
    links.bytes.capacity = limit - 1;
    defer links.bytes = .empty;
    try testing.expectError(error.OutOfMemory, links.intern("uri", "id=x"));
    try testing.expect(!fail.has_induced_failure);
    try testing.expectEqual(@as(usize, limit - 1), links.bytes.items.len);
    try testing.expectEqual(@as(usize, 0), links.entries.items.len);
}
