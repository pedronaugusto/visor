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
pub const supported = switch (builtin.os.tag) {
    .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => builtin.link_libc,
    .linux => !builtin.abi.isAndroid(),
    else => false,
};

pub const PutError = error{ Unsupported, SharedMemory };

/// The `seq`th picture of this process's: `/visor-<pid>-<seq>`, unique
/// while the process lives, and short enough everywhere.
pub fn nameOf(seq: u32) Name {
    var n: Name = .{};
    const pid: i64 = if (builtin.link_libc) std.c.getpid() else if (builtin.os.tag == .linux) std.os.linux.getpid() else 0;
    const s = std.fmt.bufPrint(&n.buf, "/visor-{d}-{d}", .{ pid, seq }) catch unreachable;
    n.len = @intCast(s.len);
    return n;
}

/// A new object named `name`, holding `bytes`. Fails when one of the name
/// exists (never overwritten: it may be one the terminal has not read).
pub fn put(io: std.Io, name: Name, bytes: []const u8) PutError!void {
    if (!supported) return error.Unsupported;
    if (builtin.link_libc) return putLibc(name, bytes);
    return putDevShm(io, name, bytes);
}

/// Removes the object, if it is still there. What a program does with a
/// picture the terminal did not read.
pub fn unlink(io: std.Io, name: Name) void {
    if (!supported) return;
    if (builtin.link_libc) {
        var z: [max_name + 1]u8 = undefined;
        _ = std.c.shm_unlink(zOf(&z, name));
        return;
    }
    var path: [16 + max_name]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/dev/shm{s}", .{name.slice()}) catch return;
    // ziglint-ignore: Z026 an object already gone is what is wanted
    std.Io.Dir.deleteFileAbsolute(io, p) catch {};
}

fn zOf(z: *[max_name + 1]u8, name: Name) [*:0]const u8 {
    @memcpy(z[0..name.len], name.slice());
    z[name.len] = 0;
    return z[0..name.len :0];
}

fn putLibc(name: Name, bytes: []const u8) PutError!void {
    var z: [max_name + 1]u8 = undefined;
    const pathz = zOf(&z, name);
    const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })), @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.SharedMemory;
    defer _ = std.c.close(fd);
    errdefer _ = std.c.shm_unlink(pathz);
    // an object is sized once, and a zero-sized one cannot be mapped
    const size = @max(bytes.len, 1);
    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.SharedMemory;
    const map = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0) catch return error.SharedMemory;
    defer std.posix.munmap(map);
    @memcpy(map[0..bytes.len], bytes);
}

fn putDevShm(io: std.Io, name: Name, bytes: []const u8) PutError!void {
    var path: [16 + max_name]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/dev/shm{s}", .{name.slice()}) catch return error.SharedMemory;
    const file = std.Io.Dir.createFileAbsolute(io, p, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.SharedMemory;
    defer file.close(io);
    errdefer unlink(io, name);
    file.writeStreamingAll(io, bytes) catch return error.SharedMemory;
}

test "a picture put in shared memory reads back whole, and is gone once unlinked" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    const name = nameOf(0xfffffff0);
    unlink(io, name);
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try put(io, name, &pixels);
    defer unlink(io, name);
    // a second put under the same name is refused, never an overwrite
    try std.testing.expectError(error.SharedMemory, put(io, name, &pixels));
    try std.testing.expectEqualSlices(u8, &pixels, try readBack(name, pixels.len));
    unlink(io, name);
    try std.testing.expectError(error.SharedMemory, readBack(name, pixels.len));
}

test "a name is a slash and no other, and fits every system" {
    const n = nameOf(std.math.maxInt(u32));
    try std.testing.expect(n.len <= max_name);
    try std.testing.expectEqual(@as(u8, '/'), n.slice()[0]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, n.slice(), "/"));
}

var read_back: [64]u8 = undefined;

fn readBack(name: Name, len: usize) ![]const u8 {
    if (builtin.link_libc) {
        var z: [max_name + 1]u8 = undefined;
        const fd = std.c.shm_open(zOf(&z, name), @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(std.c.mode_t, 0));
        if (fd < 0) return error.SharedMemory;
        defer _ = std.c.close(fd);
        const map = try std.posix.mmap(null, len, .{ .READ = true }, std.c.MAP{ .TYPE = .SHARED }, fd, 0);
        defer std.posix.munmap(map);
        @memcpy(read_back[0..len], map[0..len]);
        return read_back[0..len];
    }
    var path: [16 + max_name]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "/dev/shm{s}", .{name.slice()});
    const file = std.Io.Dir.openFileAbsolute(std.testing.io, p, .{}) catch return error.SharedMemory;
    defer file.close(std.testing.io);
    const n = try file.readPositionalAll(std.testing.io, read_back[0..len], 0);
    return read_back[0..n];
}
