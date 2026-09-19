//! The bytes a screen owns: the graphemes too long to live in a cell, and
//! the OSC 8 targets its cells point at.
//!
//! Both are interned. A grapheme written twice is stored once and both cells
//! hold the same offset, which is what lets `Cell.eql` compare two cells
//! without comparing two strings. A link written twice is one entry, and its
//! parameters are part of its identity: two targets that differ only by an
//! `id=` are two links, because they are two links to the terminal.
//!
//! Nothing here is ever compacted or reused. An offset handed out stays
//! valid until the screen is freed, so the renderer's previous frame may hold
//! cells whose graphemes were interned many frames ago. A screen that has
//! churned through a great many distinct long graphemes can be reset with
//! `Graphemes.reset`, which the caller must follow with a repaint.
//!
//! What this file will never be: a ring buffer that wraps. A grapheme a cell
//! points at is valid for as long as the screen is.

const std = @import("std");
const cellmod = @import("cell.zig");

const Allocator = std.mem.Allocator;
const Text = cellmod.Cell.Text;
const Link = cellmod.Link;

/// The pool of graphemes longer than a cell holds inline.
pub const Graphemes = struct {
    /// Every long grapheme, back to back, in the order they were first seen.
    bytes: std.ArrayList(u8) = .empty,
    /// Where each one is, keyed by what it says.
    index: Index = .empty,

    const Index = std.HashMapUnmanaged(Entry, void, Context, std.hash_map.default_max_load_percentage);

    /// One interned grapheme's place in `bytes`.
    const Entry = struct { offset: u32, len: u16 };

    /// Hashing and equality for an `Entry`, which both have to read the
    /// bytes it points at.
    const Context = struct {
        bytes: []const u8,

        pub fn hash(ctx: Context, e: Entry) u64 {
            return std.hash.Wyhash.hash(0, ctx.bytes[e.offset..][0..e.len]);
        }
        pub fn eql(ctx: Context, a: Entry, b: Entry) bool {
            return std.mem.eql(u8, ctx.bytes[a.offset..][0..a.len], ctx.bytes[b.offset..][0..b.len]);
        }
    };

    /// The same, for a lookup by the grapheme itself rather than by an entry
    /// already in the pool.
    const Adapted = struct {
        bytes: []const u8,

        pub fn hash(_: Adapted, key: []const u8) u64 {
            return std.hash.Wyhash.hash(0, key);
        }
        pub fn eql(ctx: Adapted, key: []const u8, e: Entry) bool {
            return std.mem.eql(u8, key, ctx.bytes[e.offset..][0..e.len]);
        }
    };

    /// Gives the pool back.
    pub fn deinit(p: *Graphemes, gpa: Allocator) void {
        p.bytes.deinit(gpa);
        p.index.deinit(gpa);
        p.* = .{};
    }

    /// A grapheme as a `Cell.Text`: in the cell when it fits, in the pool
    /// when it does not, and never twice in the pool.
    ///
    /// Allocates only when the grapheme is longer than six bytes and has
    /// not been seen before, which is never for ASCII and rare for anything
    /// else.
    pub fn intern(p: *Graphemes, gpa: Allocator, grapheme: []const u8) Allocator.Error!Text {
        if (grapheme.len <= Text.max_inline) return .inlined(grapheme);
        const byte_len = std.math.cast(u16, grapheme.len) orelse return error.OutOfMemory;

        const found = p.index.getEntryAdapted(grapheme, Adapted{ .bytes = p.bytes.items });
        if (found) |e| return .atOffset(e.key_ptr.offset, e.key_ptr.len);

        const offset = std.math.cast(u32, p.bytes.items.len) orelse return error.OutOfMemory;
        try p.bytes.ensureUnusedCapacity(gpa, grapheme.len);
        try p.index.ensureUnusedCapacityContext(gpa, 1, .{ .bytes = p.bytes.items });
        p.bytes.appendSliceAssumeCapacity(grapheme);
        const entry: Entry = .{ .offset = offset, .len = byte_len };
        p.index.putAssumeCapacityContext(entry, {}, .{ .bytes = p.bytes.items });
        return .atOffset(offset, byte_len);
    }

    /// The bytes of a grapheme, whichever tier it is in.
    ///
    /// The `Text` is taken by pointer because a short grapheme lives in it:
    /// the bytes come back borrowed from whatever holds the cell, and a
    /// temporary would be gone by the time they were read.
    pub fn slice(p: *const Graphemes, t: *const Text) []const u8 {
        return t.slice(p.bytes.items);
    }

    /// Empties the pool, keeping the memory. Every `Cell.Text` handed out
    /// before this points at nothing: the caller clears the grid and
    /// repaints.
    pub fn reset(p: *Graphemes) void {
        p.bytes.clearRetainingCapacity();
        p.index.clearRetainingCapacity();
    }

    /// How many bytes of grapheme the screen is holding.
    pub fn len(p: *const Graphemes) usize {
        return p.bytes.items.len;
    }
};

/// One OSC 8 target: where the terminal is told to go, and the parameters it
/// is told alongside.
pub const Target = struct {
    /// The URI, which the terminal opens on a click.
    uri: []const u8,
    /// The `key=value:key=value` list, or an empty slice for none. `id=` is
    /// the one terminals act on, and two targets that differ only there are
    /// two targets.
    params: []const u8,
};

/// Every link a screen's cells point at.
pub const Links = struct {
    /// The URIs and parameter lists, back to back.
    bytes: std.ArrayList(u8) = .empty,
    /// One entry a link, in the order they were first seen.
    entries: std.ArrayList(Entry) = .empty,
    /// Which link a target already has.
    index: Index = .empty,

    const Index = std.HashMapUnmanaged(u16, void, Context, std.hash_map.default_max_load_percentage);

    /// Where a link's two strings are.
    const Entry = struct { uri_off: u32, uri_len: u16, params_off: u32, params_len: u16 };

    const Context = struct {
        links: *const Links,

        pub fn hash(ctx: Context, i: u16) u64 {
            return hashTarget(ctx.links.get(.at(i)).?);
        }
        pub fn eql(ctx: Context, a: u16, b: u16) bool {
            return eqlTarget(ctx.links.get(.at(a)).?, ctx.links.get(.at(b)).?);
        }
    };

    const Adapted = struct {
        links: *const Links,

        pub fn hash(_: Adapted, key: Target) u64 {
            return hashTarget(key);
        }
        pub fn eql(ctx: Adapted, key: Target, i: u16) bool {
            return eqlTarget(key, ctx.links.get(.at(i)).?);
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

    /// Gives the table back.
    pub fn deinit(l: *Links, gpa: Allocator) void {
        l.index.deinit(gpa);
        l.bytes.deinit(gpa);
        l.entries.deinit(gpa);
        l.* = .{};
    }

    /// The link for a target, interned: the same URI and parameters always
    /// give the same `Link`.
    pub fn intern(l: *Links, gpa: Allocator, uri: []const u8, params: []const u8) Allocator.Error!Link {
        if (uri.len == 0) return .none;
        const target: Target = .{ .uri = uri, .params = params };
        if (l.index.getKeyAdapted(target, Adapted{ .links = l })) |i| return .at(i);

        const uri_len = std.math.cast(u16, uri.len) orelse return error.OutOfMemory;
        const params_len = std.math.cast(u16, params.len) orelse return error.OutOfMemory;
        const uri_off = std.math.cast(u32, l.bytes.items.len) orelse return error.OutOfMemory;
        const i = std.math.cast(u16, l.entries.items.len) orelse return error.OutOfMemory;
        if (i == std.math.maxInt(u16)) return error.OutOfMemory;

        try l.bytes.ensureUnusedCapacity(gpa, uri.len + params.len);
        try l.entries.ensureUnusedCapacity(gpa, 1);
        try l.index.ensureUnusedCapacityContext(gpa, 1, .{ .links = l });

        l.bytes.appendSliceAssumeCapacity(uri);
        const params_off: u32 = @intCast(l.bytes.items.len);
        l.bytes.appendSliceAssumeCapacity(params);
        l.entries.appendAssumeCapacity(.{
            .uri_off = uri_off,
            .uri_len = uri_len,
            .params_off = params_off,
            .params_len = params_len,
        });
        l.index.putAssumeCapacityContext(i, {}, .{ .links = l });
        return .at(i);
    }

    /// The target a link names, or null for `.none` and for an index that
    /// belongs to another screen.
    pub fn get(l: *const Links, link: Link) ?Target {
        const i = link.index() orelse return null;
        if (i >= l.entries.items.len) return null;
        const e = l.entries.items[i];
        return .{
            .uri = l.bytes.items[e.uri_off..][0..e.uri_len],
            .params = l.bytes.items[e.params_off..][0..e.params_len],
        };
    }

    /// How many links the screen is holding.
    pub fn count(l: *const Links) usize {
        return l.entries.items.len;
    }
};

const testing = std.testing;

test "a short grapheme never reaches the pool" {
    var p: Graphemes = .{};
    defer p.deinit(testing.allocator);

    const a = try p.intern(testing.allocator, "a");
    try testing.expect(!a.isPooled());
    try testing.expectEqual(@as(usize, 0), p.len());
    try testing.expectEqualStrings("a", p.slice(&a));

    const six = try p.intern(testing.allocator, "123456");
    try testing.expect(!six.isPooled());
    try testing.expectEqual(@as(usize, 0), p.len());

    // Seven is one too many, and the warning sign with its presentation
    // selector -- the cluster the drift rule exists for -- is exactly six.
    const seven = try p.intern(testing.allocator, "1234567");
    try testing.expect(seven.isPooled());
    try testing.expect(!(try p.intern(testing.allocator, "\u{26a0}\u{fe0f}")).isPooled());
}

test "a long grapheme is pooled once however often it is written" {
    var p: Graphemes = .{};
    defer p.deinit(testing.allocator);

    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    const first = try p.intern(testing.allocator, family);
    try testing.expect(first.isPooled());
    try testing.expectEqualStrings(family, p.slice(&first));
    const after = p.len();

    for (0..64) |_| {
        const again = try p.intern(testing.allocator, family);
        try testing.expect(Text.eql(first, again));
    }
    try testing.expectEqual(after, p.len());
}

test "two different long graphemes get two places" {
    var p: Graphemes = .{};
    defer p.deinit(testing.allocator);

    const a = try p.intern(testing.allocator, "\u{1f468}\u{200d}\u{1f469}");
    const b = try p.intern(testing.allocator, "\u{1f468}\u{200d}\u{1f467}");
    try testing.expect(!Text.eql(a, b));
    try testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f469}", p.slice(&a));
    try testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f467}", p.slice(&b));
}

test "interning survives the pool being grown under it" {
    var p: Graphemes = .{};
    defer p.deinit(testing.allocator);

    var kept: [64]Text = undefined;
    var buf: [16]u8 = undefined;
    for (0..64) |i| {
        const g = try std.fmt.bufPrint(&buf, "long-{d:0>8}", .{i});
        kept[i] = try p.intern(testing.allocator, g);
    }
    for (0..64) |i| {
        const g = try std.fmt.bufPrint(&buf, "long-{d:0>8}", .{i});
        try testing.expectEqualStrings(g, p.slice(&kept[i]));
        try testing.expect(Text.eql(kept[i], try p.intern(testing.allocator, g)));
    }
}

test "a link is interned and its parameters are part of it" {
    var l: Links = .{};
    defer l.deinit(testing.allocator);

    const a = try l.intern(testing.allocator, "https://ziglang.org", "");
    const b = try l.intern(testing.allocator, "https://ziglang.org", "");
    const c = try l.intern(testing.allocator, "https://ziglang.org", "id=1");
    const d = try l.intern(testing.allocator, "https://ziglang.org", "id=2");

    try testing.expectEqual(a, b);
    try testing.expect(a != c);
    try testing.expect(c != d);
    try testing.expectEqual(@as(usize, 3), l.count());
    try testing.expectEqualStrings("https://ziglang.org", l.get(a).?.uri);
    try testing.expectEqualStrings("", l.get(a).?.params);
    try testing.expectEqualStrings("id=2", l.get(d).?.params);
}

test "an empty uri is no link at all" {
    var l: Links = .{};
    defer l.deinit(testing.allocator);
    try testing.expectEqual(Link.none, try l.intern(testing.allocator, "", "id=1"));
    try testing.expectEqual(@as(?Target, null), l.get(.none));
    try testing.expectEqual(@as(usize, 0), l.count());
}

test "a link index from another screen reads as nothing" {
    var l: Links = .{};
    defer l.deinit(testing.allocator);
    _ = try l.intern(testing.allocator, "a://b", "");
    try testing.expectEqual(@as(?Target, null), l.get(.at(9)));
}

test "the pool gives its memory back under a failing allocator" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var p: Graphemes = .{};
            defer p.deinit(gpa);
            var l: Links = .{};
            defer l.deinit(gpa);
            var buf: [24]u8 = undefined;
            for (0..24) |i| {
                const g = try std.fmt.bufPrint(&buf, "grapheme-{d:0>6}", .{i});
                _ = try p.intern(gpa, g);
                _ = try l.intern(gpa, g, "id=x");
            }
        }
    }.run, .{});
}
