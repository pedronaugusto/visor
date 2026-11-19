//! Shared memory for pictures: the pixels put where the terminal reads
//! them, so what goes through the terminal's input is a name, not the
//! picture. The objects the kitty graphics protocol takes (`t=s`), named
//! with a slash and no other: on POSIX a shared memory object, which the
//! terminal opens, reads and unlinks; on Windows a named file mapping, which
//! the terminal opens, reads and closes. A picture is written into the
//! object where it is mapped (`create`), or copied there (`put`).
//!
//! What a program keeps of an object until the terminal has read it is its
//! `Held`, given back with `release`. On POSIX that is nothing: the name is
//! all an unlink takes, and a terminal that read the object has unlinked it
//! already. On Windows it is the handle that made the mapping: a named
//! mapping has no unlink and lives until its last handle closes, so the
//! program keeps its handle until the terminal has read the picture, and
//! closing it then is the unlink.
//!
//! With libc, `shm_open`; on Linux without it, the file under `/dev/shm`
//! that `shm_open` names there; on Windows, `CreateFileMappingW` with a name
//! in the session's namespace. Elsewhere, nothing: `put` says so, and the
//! picture goes in the escape code instead.
const std = @import("std");
const builtin = @import("builtin");
const intake = @import("../intake.zig");
const aegis = @import("../dependencies.zig").aegis;
const windows = std.os.windows;
const is_windows = builtin.target.os.tag == .windows;

/// The longest name, the slash included: macOS takes 31 bytes
/// (`PSHMNAMLEN`), the least of the systems that have these. Windows takes
/// the same names.
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
    .windows => true,
    else => false,
};

pub const PutError = error{ Unsupported, SharedMemory };

/// What the program keeps of an object until the terminal has read it, for
/// `release`: on Windows the handle that made the mapping, elsewhere nothing.
pub const Held = if (is_windows) windows.HANDLE else void;

// The process owns this namespace; neither configuration nor a Layers
// lifetime can reset it. Refuse exhaustion rather than ever reusing a name.
var namespace: aegis.Atomic(Namespace) = .init(.fromRaw(1));

/// One reservation from the process's namespace: a name's sequence, or a
/// `Layers`' generation of shared objects.
pub const Namespace = aegis.id.Id(struct {}, u64);

pub fn nextNamespace() Namespace {
    var next = namespace.load(.monotonic);
    while (true) {
        const after = next.successor() catch @panic("shared memory names exhausted");
        next = namespace.cmpxchgWeak(next, after, .monotonic, .monotonic) orelse return next;
    }
}

/// A process-wide name, reserved once and never reused.
pub fn nextName() Name {
    return nameOf(nextNamespace());
}

/// Read-only observation for the ownership reservation tests.
pub fn nextSequence() Namespace {
    return namespace.load(.monotonic);
}

/// Hex keeps a full 32-bit pid and 64-bit sequence within macOS's limit.
/// A build without shared memory makes no object, so its names have no
/// process in them.
fn nameOf(seq: Namespace) Name {
    var n: Name = .{};
    const pid: u32 = if (!supported) 0 else if (is_windows) windows.GetCurrentProcessId() else if (builtin.link_libc) @intCast(std.c.getpid()) else @intCast(std.os.linux.getpid()); // safe: a POSIX pid is positive and fits 32 bits
    comptime std.debug.assert("/v-ffffffff-ffffffffffffffff".len <= max_name);
    const s = std.mem.print(&n.buf, "/v-{x}-{x}", .{ pid, seq.raw() }) catch aegis.assert.never("the longest name, a u32 and a u64 in hex, fits, as asserted above");
    n.len = @intCast(s.len);
    return n;
}

/// A new object's memory, mapped for writing: what goes in `bytes` is what
/// the terminal reads.
pub const Mapping = struct {
    memory: []align(std.heap.page_size_min) u8,
    len: usize,
    /// What `release` takes when the object is done with.
    held: Held,

    /// The object's bytes, as long as it was made.
    pub fn bytes(m: Mapping) []u8 {
        return m.memory[0..m.len];
    }

    /// Gives the address space back. The object stays, named, for the
    /// terminal to read, until it is released.
    pub fn unmap(m: Mapping) void {
        // unreachable: a build without shared memory makes no mapping (`create`)
        if (!supported) unreachable;
        if (is_windows) {
            // a view this process mapped is always one it can unmap
            _ = win32.UnmapViewOfFile(m.memory.ptr);
            return;
        }
        std.posix.munmap(m.memory);
    }
};

/// A new object named `name`, `len` bytes long, mapped for the caller to
/// fill: a picture written there is in the object, with no copy. Fails
/// when one of the name exists (never overwritten: it may be one the
/// terminal has not read).
///
/// The object is memory, as `shm_open` makes it, so it takes no
/// `std.Io`: with libc through `shm_open`, on Linux without it through
/// the same calls, on the file under `/dev/shm`, and on Windows through a
/// file mapping backed by the paging file.
pub fn create(name: Name, len: usize) PutError!Mapping {
    if (!supported) return error.Unsupported;
    if (is_windows) return createWindows(name, len);
    var z: [path_max]u8 = undefined;
    const fd = try open(&z, name);
    defer closeFd(fd);
    errdefer unlink(name);
    // an object is sized once, and a zero-sized one cannot be mapped
    const size = @max(len, 1);
    try truncate(fd, size);
    const map = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return error.SharedMemory;
    return .{ .memory = map, .len = len, .held = {} };
}

/// A named mapping of `len` bytes in the session's namespace, refusing a
/// name that exists. Its security is the default, this user's alone.
fn createWindows(name: Name, len: usize) PutError!Mapping {
    const size: u64 = @max(len, 1);
    var w: [max_name + 1]u16 = undefined;
    const handle = win32.CreateFileMappingW(
        windows.INVALID_HANDLE_VALUE,
        null,
        win32.page_readwrite,
        @truncate(size >> 32),
        @truncate(size),
        wideOf(&w, name),
    ) orelse return error.SharedMemory;
    // never another's mapping, which a terminal may not have read
    if (windows.GetLastError() == .ALREADY_EXISTS) {
        windows.CloseHandle(handle);
        return error.SharedMemory;
    }
    errdefer windows.CloseHandle(handle);
    const view = win32.MapViewOfFile(handle, win32.file_map_write, 0, 0, @intCast(size)) orelse return error.SharedMemory;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(view));
    return .{ .memory = base[0..@intCast(size)], .len = len, .held = handle };
}

/// A new object named `name`, holding a copy of `bytes`, and what to
/// release it with; `create`'s refusals.
pub fn put(name: Name, bytes: []const u8) PutError!Held {
    const map = try create(name, bytes.len);
    defer map.unmap();
    @memcpy(map.bytes(), bytes);
    return map.held;
}

/// Lets the object go: what a program does once the terminal has read the
/// picture, or once it learns the terminal could not. On POSIX the object
/// is unlinked, if it is still there; on Windows the handle that made it is
/// closed, which takes the object away once the terminal has closed its
/// own. Allocates nothing, takes no `std.Io` and cannot fail, so a value's
/// `deinit` can do it on any way out.
pub fn release(name: Name, held: Held) void {
    if (is_windows) return windows.CloseHandle(held);
    unlink(name);
}

/// Removes a POSIX object, if it is still there.
fn unlink(name: Name) void {
    if (!supported or is_windows) return;
    var z: [path_max]u8 = undefined;
    if (builtin.link_libc) {
        _ = std.c.shm_unlink(zOf(&z, name));
        return;
    }
    // an object already gone is what is wanted
    _ = std.os.linux.unlink(devShmPath(&z, name));
}

/// The kernel32 calls a named mapping takes, which std does not bind.
const win32 = struct {
    extern "kernel32" fn CreateFileMappingW(file: windows.HANDLE, attributes: ?*anyopaque, protect: windows.DWORD, size_high: windows.DWORD, size_low: windows.DWORD, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn OpenFileMappingW(access: windows.DWORD, inherit: windows.BOOL, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: windows.DWORD, offset_high: windows.DWORD, offset_low: windows.DWORD, len: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
    const page_readwrite: windows.DWORD = 0x04;
    const file_map_write: windows.DWORD = 0x0002;
    const file_map_read: windows.DWORD = 0x0004;
};

/// The name in UTF-16, as Windows takes it: every byte of a name is ASCII.
fn wideOf(w: *[max_name + 1]u16, name: Name) [*:0]const u16 {
    for (name.slice(), 0..) |b, i| w[i] = b;
    w[name.len] = 0;
    return w[0..name.len :0];
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
fn open(z: *[path_max]u8, name: Name) PutError!std.posix.fd_t {
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

test "a picture put in shared memory reads back whole, and is gone once released" {
    if (!supported) return error.SkipZigTest;
    const name = nextName();
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const held = try put(name, &pixels);
    var released = false;
    defer if (!released) release(name, held);
    // a second put under the same name is refused, never an overwrite
    try std.testing.expectError(error.SharedMemory, put(name, &pixels));
    var back: [64]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &pixels, try readBack(&back, name, pixels.len));
    release(name, held);
    released = true;
    try std.testing.expectError(error.SharedMemory, readBack(&back, name, pixels.len));
}

test "a picture written where an object is mapped is the object's" {
    if (!supported) return error.SkipZigTest;
    const name = nextName();
    const map = try create(name, 6);
    defer release(name, map.held);
    @memcpy(map.bytes(), "pixels");
    map.unmap();
    var back: [64]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, "pixels", try readBack(&back, name, 6));
    try std.testing.expectError(error.SharedMemory, create(name, 6));
}

test "a name is a slash and no other, and fits every system" {
    const n = nameOf(.fromRaw(std.math.maxInt(u64)));
    try std.testing.expect(n.len <= max_name);
    try std.testing.expectEqual(@as(u8, '/'), n.slice()[0]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, n.slice(), "/"));
}

/// The object's first `len` bytes, read into `back`.
fn readBack(back: *[64]u8, name: Name, len: usize) ![]const u8 {
    if (is_windows) {
        var w: [max_name + 1]u16 = undefined;
        const handle = win32.OpenFileMappingW(win32.file_map_read, .FALSE, wideOf(&w, name)) orelse return error.SharedMemory;
        defer windows.CloseHandle(handle);
        const view = win32.MapViewOfFile(handle, win32.file_map_read, 0, 0, len) orelse return error.SharedMemory;
        defer _ = win32.UnmapViewOfFile(view);
        @memcpy(back[0..len], @as([*]const u8, @ptrCast(view))[0..len]);
        return back[0..len];
    }
    if (builtin.link_libc) {
        var z: [path_max]u8 = undefined;
        const fd = std.c.shm_open(zOf(&z, name), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(std.c.mode_t, 0));
        if (fd < 0) return error.SharedMemory;
        defer _ = std.c.close(fd);
        const map = try std.posix.mmap(null, len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0);
        defer std.posix.munmap(map);
        @memcpy(back[0..len], map[0..len]);
        return back[0..len];
    }
    var path: [16 + max_name]u8 = undefined;
    const p = try std.mem.print(&path, "/dev/shm{s}", .{name.slice()});
    const file = std.Io.Dir.openFileAbsolute(std.testing.io, p, .{}) catch return error.SharedMemory;
    defer file.close(std.testing.io);
    const n = try intake.readPositionalAll(file, std.testing.io, back[0..len], 0);
    return back[0..n];
}

test "the shared memory namespace is unique across threads" {
    const Worker = struct {
        fn run(values: *[128]Namespace) void {
            for (values) |*value| value.* = nextNamespace();
        }
    };
    var values: [4][128]Namespace = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads, &values) |*thread, *batch| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{batch});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    var seen: std.AutoHashMap(Namespace, void) = .init(std.testing.allocator);
    defer seen.deinit();
    for (values) |batch| for (batch) |value| {
        const entry = try seen.getOrPut(value);
        try std.testing.expect(!entry.found_existing);
    };
}
