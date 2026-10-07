//! Shared memory for pictures: the pixels put where the terminal reads
//! them, so what goes through the terminal's input is a name, not the
//! picture. POSIX shared memory objects, named the way the kitty graphics
//! protocol takes them (`t=s`): a slash and no other. The terminal opens
//! the object, reads it and unlinks it; a program that learns the terminal
//! could not (an error, no answer) unlinks it itself.
//!
//! With libc, `shm_open`; on Linux without it, the file under `/dev/shm`
//! that `shm_open` names there. Elsewhere, nothing: `put` says so, and the
//! picture goes in the escape code instead.
const std = @import("std");
const builtin = @import("builtin");

/// The longest name, the slash included: macOS takes 31 bytes
/// (`PSHMNAMLEN`), the least of the systems that have these.
pub const max_name = 31;

/// A name, held by value so a record can keep it without an allocation.
pub const Name = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Whether this build can put a picture in shared memory at all.
pub const supported = switch (builtin.target.os.tag) {
    .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => builtin.link_libc,
    .linux => !builtin.target.abi.isAndroid(),
    else => false,
};

pub const PutError = error{ Unsupported, SharedMemory };

// The process owns this namespace; neither configuration nor a Layers
// lifetime can reset it. Refuse exhaustion rather than ever reusing a name.
var namespace: std.atomic.Value(u64) = .init(1);

pub fn nextNamespace() u64 {
    var next = namespace.load(.monotonic);
    while (true) {
        if (next == std.math.maxInt(u64)) @panic("shared memory names exhausted");
        next = namespace.cmpxchgWeak(next, next + 1, .monotonic, .monotonic) orelse return next;
    }
}

/// A process-wide name, reserved once and never reused.
pub fn nextName() Name {
    return nameOf(nextNamespace());
}

/// Read-only observation for the ownership reservation tests.
pub fn nextSequence() u64 {
    return namespace.load(.monotonic);
}

/// Hex keeps a full 32-bit pid and 64-bit sequence within macOS's limit.
fn nameOf(seq: u64) Name {
    var n: Name = .{};
    const pid: u32 = if (builtin.link_libc) @intCast(std.c.getpid()) else if (builtin.target.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
    comptime std.debug.assert("/v-ffffffff-ffffffffffffffff".len <= max_name);
    // unreachable: the longest name, a u32 and a u64 in hex, fits, as asserted above
    const s = std.mem.print(&n.buf, "/v-{x}-{x}", .{ pid, seq }) catch unreachable;
    n.len = @intCast(s.len);
    return n;
}

/// A new object named `name`, holding `bytes`. Fails when one of the name
/// exists (never overwritten: it may be one the terminal has not read).
///
/// The object is memory, mapped and copied into, as `shm_open` makes it,
/// so it takes no `std.Io`: with libc through `shm_open`, and on Linux
/// without it through the same calls, on the file under `/dev/shm`.
pub fn put(name: Name, bytes: []const u8) PutError!void {
    if (!supported) return error.Unsupported;
    var z: [path_max]u8 = undefined;
    const fd = try create(&z, name);
    defer closeFd(fd);
    errdefer unlink(name);
    // an object is sized once, and a zero-sized one cannot be mapped
    const size = @max(bytes.len, 1);
    try truncate(fd, size);
    const map = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return error.SharedMemory;
    defer std.posix.munmap(map);
    @memcpy(map[0..bytes.len], bytes);
}

/// Removes the object, if it is still there. What a program does with a
/// picture the terminal did not read. Allocates nothing, takes no `std.Io`
/// and cannot fail, so a value's `deinit` can do it on any way out.
pub fn unlink(name: Name) void {
    if (!supported) return;
    var z: [path_max]u8 = undefined;
    if (builtin.link_libc) {
        _ = std.c.shm_unlink(zOf(&z, name));
        return;
    }
    // an object already gone is what is wanted
    _ = std.os.linux.unlink(devShmPath(&z, name));
}

/// Room for `/dev/shm`, the longest name and its terminator.
const path_max = "/dev/shm".len + max_name + 1;

fn zOf(z: *[path_max]u8, name: Name) [*:0]const u8 {
    @memcpy(z[0..name.len], name.slice());
    z[name.len] = 0;
    return z[0..name.len :0];
}

/// The file `shm_open` names on Linux: the name under `/dev/shm`.
fn devShmPath(z: *[path_max]u8, name: Name) [*:0]const u8 {
    const prefix = "/dev/shm";
    @memcpy(z[0..prefix.len], prefix);
    @memcpy(z[prefix.len..][0..name.len], name.slice());
    z[prefix.len + name.len] = 0;
    return z[0 .. prefix.len + name.len :0];
}

/// Creates the object for reading and writing by this user alone, refusing
/// one that exists.
fn create(z: *[path_max]u8, name: Name) PutError!std.posix.fd_t {
    if (builtin.link_libc) {
        const fd = std.c.shm_open(zOf(z, name), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })), @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.SharedMemory;
        return fd;
    }
    const linux = std.os.linux;
    const rc = linux.open(devShmPath(z, name), .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.SharedMemory;
    return @intCast(rc);
}

fn truncate(fd: std.posix.fd_t, size: usize) PutError!void {
    if (builtin.link_libc) {
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.SharedMemory;
        return;
    }
    const linux = std.os.linux;
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SharedMemory;
}

fn closeFd(fd: std.posix.fd_t) void {
    if (builtin.link_libc) _ = std.c.close(fd) else _ = std.os.linux.close(fd);
}

test "a picture put in shared memory reads back whole, and is gone once unlinked" {
    if (!supported) return error.SkipZigTest;
    const name = nextName();
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try put(name, &pixels);
    defer unlink(name);
    // a second put under the same name is refused, never an overwrite
    try std.testing.expectError(error.SharedMemory, put(name, &pixels));
    try std.testing.expectEqualSlices(u8, &pixels, try readBack(name, pixels.len));
    unlink(name);
    try std.testing.expectError(error.SharedMemory, readBack(name, pixels.len));
}

test "a name is a slash and no other, and fits every system" {
    const n = nameOf(std.math.maxInt(u64));
    try std.testing.expect(n.len <= max_name);
    try std.testing.expectEqual(@as(u8, '/'), n.slice()[0]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, n.slice(), "/"));
}

var read_back: [64]u8 = undefined;

fn readBack(name: Name, len: usize) ![]const u8 {
    if (builtin.link_libc) {
        var z: [path_max]u8 = undefined;
        const fd = std.c.shm_open(zOf(&z, name), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(std.c.mode_t, 0));
        if (fd < 0) return error.SharedMemory;
        defer _ = std.c.close(fd);
        const map = try std.posix.mmap(null, len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0);
        defer std.posix.munmap(map);
        @memcpy(read_back[0..len], map[0..len]);
        return read_back[0..len];
    }
    var path: [16 + max_name]u8 = undefined;
    const p = try std.mem.print(&path, "/dev/shm{s}", .{name.slice()});
    const file = std.Io.Dir.openFileAbsolute(std.testing.io, p, .{}) catch return error.SharedMemory;
    defer file.close(std.testing.io);
    const n = try file.readPositionalAll(std.testing.io, read_back[0..len], 0);
    return read_back[0..n];
}

test "the shared memory namespace is unique across threads" {
    const Worker = struct {
        fn run(values: *[128]u64) void {
            for (values) |*value| value.* = nextNamespace();
        }
    };
    var values: [4][128]u64 = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads, &values) |*thread, *batch| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{batch});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    var seen: std.AutoHashMap(u64, void) = .init(std.testing.allocator);
    defer seen.deinit();
    for (values) |batch| for (batch) |value| {
        const entry = try seen.getOrPut(value);
        try std.testing.expect(!entry.found_existing);
    };
}
