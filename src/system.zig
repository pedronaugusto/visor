//! The calls visor makes past std's checked layer, each one call with what its caller must hold: a
//! descriptor's status flags, one raw write to a descriptor or to Windows' console (for a panic
//! handler, which has no `Io` to write through), and a pipe and its close for a terminal a test
//! types into. glint's P007 seam with the shared-memory layer (glint.json).
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.target.os.tag == .windows;
const windows = std.os.windows;

/// Where a raw write goes: a descriptor, or on Windows a console handle.
pub const Handle = if (is_windows) windows.HANDLE else std.posix.fd_t;

/// The status flags of the open descriptor `fd` (F_GETFL), or null where the system refuses.
pub fn statusFlags(fd: std.posix.fd_t) ?u32 {
    const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(u32, 0));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Sets the status flags of the open descriptor `fd` (F_SETFL).
pub fn setStatusFlags(fd: std.posix.fd_t, flags: u32) error{Unexpected}!void {
    const rc = std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(usize, flags));
    if (std.posix.errno(rc) != .SUCCESS) return error.Unexpected;
}

/// What one raw write did.
pub const Wrote = union(enum) {
    /// This many of the bytes went, at most all of them; zero is a handle that takes none.
    bytes: usize,
    /// A signal cut the write short before any byte went.
    interrupted,
    /// The system refused the write.
    failed,
};

/// One write of `bytes` to the open `handle`, with no `Io` and no buffer between: a descriptor's
/// `write`, or one synchronous `NtWriteFile` as the console takes it. The caller keeps `handle`
/// open for the call.
pub fn writeOnce(handle: Handle, bytes: []const u8) Wrote {
    if (is_windows) {
        var status_block: windows.IO_STATUS_BLOCK = undefined;
        const n: u32 = @intCast(@min(bytes.len, std.math.maxInt(u32)));
        // NtWriteFile fills the status block where it succeeds, and it is read only then.
        const status = windows.ntdll.NtWriteFile(handle, null, null, null, &status_block, bytes.ptr, n, null, null);
        if (status != .SUCCESS) return .failed;
        return .{ .bytes = status_block.Information };
    }
    const rc = std.posix.system.write(handle, bytes.ptr, bytes.len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .bytes = @intCast(rc) },
        .INTR => .interrupted,
        else => .failed,
    };
}

/// A pipe: its read end, then its write end.
pub fn pipe() error{Unexpected}![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    // pipe fills both descriptors where it succeeds.
    if (std.posix.errno(std.posix.system.pipe(&fds)) != .SUCCESS) return error.Unexpected;
    return fds;
}

/// Closes the descriptor `fd`, which the caller owns and uses no more.
pub fn close(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}
