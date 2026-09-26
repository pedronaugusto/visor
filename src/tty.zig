//! This program's own terminal.
//!
//! Separate, and optional. A program that already owns its terminal — a
//! multiplexer, a test harness, a client with a daemon behind it — never
//! imports this, and nothing else in the package touches a descriptor.
//!
//! What it owns is small and dangerous: the mode the terminal was found in,
//! and the way back to it. Everything else — the timeouts, the event loop,
//! when to read, when to flush — is the caller's. No thread is started, no
//! signal handler is installed unless asked for, and no panic handler is
//! installed behind anyone's back.
//!
//! The one piece of global state in this package lives here: the terminal
//! that is currently in raw mode, so `restoreGlobal` can put it back from a
//! panic handler, where there is nothing to pass and nothing that may fail.
//!
//! What this file will never hold: a parser, a screen, a frame, a clock, or
//! a thread.

const std = @import("std");
const builtin = @import("builtin");
const morse = @import("morse");

const Winsize = @import("winsize.zig").Winsize;
const render = @import("render.zig");
const Caps = @import("caps.zig").Caps;
const Renderer = render.Renderer;

const Io = std.Io;
const Writer = std.Io.Writer;
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;

/// The terminal that is in raw mode, so the way back can be taken without an
/// argument, an allocator or a failure.
///
/// One program has one terminal, and a panic handler has nothing to be
/// handed. It is written when `raw` succeeds and cleared when `restore`
/// runs.
var open_tty: ?Saved = null;

/// The renderer a `Tty` entered a screen through, so the way back can undo
/// the modes it switched as well as the terminal's mode.
///
/// Set by `Tty.enter` and cleared by `Tty.leave`, by the way back itself, and
/// by `Renderer.deinit`, so it never names a renderer that is gone.
var armed: ?*Renderer = null;

/// Stops the way back reaching for `r`. `Renderer.deinit` calls this.
pub fn forget(r: *const Renderer) void {
    if (armed == r) armed = null;
}

/// The pipe a resize writes into, read end first; `-1` when nothing is
/// watched. Global because a signal handler is handed nothing else.
var resize_pipe: [2]if (is_windows) i32 else std.posix.fd_t = .{ -1, -1 };
/// The `SIGWINCH` handler that was there before `watchResize`.
var resize_was: if (is_windows) void else std.posix.Sigaction = undefined;

/// The handler: one byte into a pipe, which is all a signal handler may do.
/// A full pipe already holds a wake, so a write that would block is dropped.
fn onWinch(_: std.posix.SIG) callconv(.c) void {
    const byte: [1]u8 = .{'w'};
    _ = std.posix.system.write(resize_pipe[1], &byte, 1);
}

/// Empties the resize pipe; whether there was anything in it. `Input` calls
/// this after the pipe woke it.
pub fn drainResizePipe() bool {
    var any = false;
    var sink: [64]u8 = undefined;
    while (true) {
        const rc = std.posix.system.read(resize_pipe[0], &sink, sink.len);
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) return any;
        any = true;
    }
}

fn fcntlSet(fd: std.posix.fd_t, cmd: i32, arg: u32) error{Unexpected}!void {
    const rc = std.posix.system.fcntl(fd, cmd, @as(usize, arg));
    if (std.posix.errno(rc) != .SUCCESS) return error.Unexpected;
}

/// What the terminal was before this program touched it.
const Saved = if (is_windows) struct {
    input: windows.HANDLE,
    output: windows.HANDLE,
    input_mode: windows.DWORD,
    output_mode: windows.DWORD,
} else struct {
    handle: std.posix.fd_t,
    mode: std.posix.termios,
};

/// The descriptor, the saved mode, and the way back.
pub const Tty = struct {
    /// The terminal itself.
    file: Io.File,
    /// The `Io` it was opened with, and the one its reads and writes use.
    io: Io,
    /// On Windows, the input handle, which is a second descriptor.
    input: if (is_windows) Io.File else void,
    /// What the terminal was before `raw`, or null when it has not been
    /// changed.
    saved: ?Saved = null,

    /// Anything opening the terminal can fail with.
    pub const OpenError = Io.File.OpenError || error{NotATerminal};
    /// Anything changing its mode can fail with.
    pub const ModeError = error{ NotATerminal, Unexpected };
    /// Anything asking its size can fail with.
    pub const SizeError = error{ NotATerminal, Unexpected };

    /// The program's controlling terminal: `/dev/tty` on POSIX, the console
    /// handles on Windows.
    ///
    /// Not the standard streams: a program whose output is a pipe still has
    /// a terminal, and a program drawing a screen wants the terminal rather
    /// than whatever its output was redirected to.
    pub fn open(io: Io) OpenError!Tty {
        if (is_windows) {
            const input = CreateFileW(
                std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                OPEN_EXISTING,
                0,
                null,
            );
            if (input == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;
            errdefer windows.CloseHandle(input);
            const output = CreateFileW(
                std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                OPEN_EXISTING,
                0,
                null,
            );
            if (output == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;
            return .{
                .file = .{ .handle = output, .flags = .{ .nonblocking = false } },
                .io = io,
                .input = .{ .handle = input, .flags = .{ .nonblocking = false } },
            };
        }
        const file = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        if (builtin.os.tag == .macos) {
            // The kernel's poll cannot wait on /dev/tty here -- it answers
            // POLLNVAL at once -- and the reader waits on the terminal and
            // the resize pipe together. The device the standard streams are
            // on is the same terminal under a name poll does work on.
            var path: [std.posix.PATH_MAX]u8 = undefined;
            if (deviceOf(file.handle, &path)) |device| {
                if (Io.Dir.openFileAbsolute(io, device, .{ .mode = .read_write })) |real| {
                    file.close(io);
                    return .{ .file = real, .io = io, .input = {} };
                } else |_| {}
            }
        }
        return .{ .file = file, .io = io, .input = {} };
    }

    /// A terminal the program already has open: a descriptor it was handed,
    /// or the far end of a pseudo-terminal it made. Everything `open` gives
    /// works on it, and `close` closes the file.
    pub fn adopt(io: Io, file: Io.File) Tty {
        return .{ .file = file, .io = io, .input = if (is_windows) file else {} };
    }

    /// Gives the terminal back, restoring its mode first if it was changed.
    pub fn close(t: *Tty) void {
        t.restore();
        t.unwatchResize();
        t.file.close(t.io);
        if (is_windows and t.input.handle != t.file.handle) t.input.close(t.io);
        t.* = undefined;
    }

    /// Raw mode: no line editing, no echo, no signals from control keys, and
    /// a read that returns as soon as there is anything.
    ///
    /// The mode the terminal was in is remembered, both here and in the one
    /// global this package has, so `restoreGlobal` can put it back from a
    /// panic.
    pub fn raw(t: *Tty) ModeError!void {
        if (t.saved != null) return;
        if (is_windows) {
            var input_mode: windows.DWORD = 0;
            var output_mode: windows.DWORD = 0;
            if (GetConsoleMode(t.input.handle, &input_mode) == .FALSE) {
                return error.NotATerminal;
            }
            if (GetConsoleMode(t.file.handle, &output_mode) == .FALSE) {
                return error.NotATerminal;
            }
            const saved: Saved = .{
                .input = t.input.handle,
                .output = t.file.handle,
                .input_mode = input_mode,
                .output_mode = output_mode,
            };
            var want_in = input_mode;
            want_in &= ~@as(windows.DWORD, ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT |
                ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE);
            want_in |= ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS;
            var want_out = output_mode;
            want_out |= ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
            t.saved = saved;
            errdefer t.restore();
            if (SetConsoleMode(t.input.handle, want_in) == .FALSE) return error.Unexpected;
            if (SetConsoleMode(t.file.handle, want_out) == .FALSE) return error.Unexpected;
            open_tty = saved;
            return;
        }
        const was = std.posix.tcgetattr(t.file.handle) catch return error.NotATerminal;
        var want = was;
        want.iflag.IGNBRK = false;
        want.iflag.BRKINT = false;
        want.iflag.PARMRK = false;
        want.iflag.ISTRIP = false;
        want.iflag.INLCR = false;
        want.iflag.IGNCR = false;
        want.iflag.ICRNL = false;
        want.iflag.IXON = false;
        want.oflag.OPOST = false;
        want.lflag.ECHO = false;
        want.lflag.ECHONL = false;
        want.lflag.ICANON = false;
        want.lflag.ISIG = false;
        want.lflag.IEXTEN = false;
        want.cflag.PARENB = false;
        want.cflag.CSIZE = .CS8;
        want.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        want.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(t.file.handle, .FLUSH, want) catch return error.Unexpected;
        const saved: Saved = .{ .handle = t.file.handle, .mode = was };
        t.saved = saved;
        open_tty = saved;
    }

    /// The mode as it was found, and the screen and input modes a renderer
    /// entered through `enter` undone before it. Safe to call when nothing
    /// was changed.
    pub fn restore(t: *Tty) void {
        const was = t.saved orelse return;
        restoreSaved(was);
        t.saved = null;
        open_tty = null;
    }

    /// Anything entering or leaving a screen can fail with.
    pub const EnterError = ModeError || render.Error;

    /// Takes the screen: raw mode, then everything `Renderer.enter` writes,
    /// flushed. From here the way back — `leave`, `restore`, `close`,
    /// `restoreGlobal` and `Panic` — undoes the modes the renderer has on at
    /// the time as well as the terminal's mode.
    pub fn enter(
        t: *Tty,
        r: *Renderer,
        caps: Caps,
        mode: render.Mode,
        modes: render.Modes,
    ) EnterError!void {
        try t.raw();
        armed = r;
        var buffer: [256]u8 = undefined;
        var out = t.writer(&buffer);
        try r.enter(&out.interface, caps, mode, modes);
        try out.interface.flush();
    }

    /// Gives the screen back: everything `Renderer.leave` writes, flushed,
    /// and then the terminal's mode as it was found.
    pub fn leave(t: *Tty, r: *Renderer) render.Error!void {
        forget(r);
        defer t.restore();
        var buffer: [256]u8 = undefined;
        var out = t.writer(&buffer);
        try r.leave(&out.interface);
        try out.interface.flush();
    }

    /// How big the terminal is, from the operating system: the grid, and
    /// the text area in pixels where the terminal filled that in.
    ///
    /// The cell's own pixel size is not here, because the operating system
    /// does not know it: ask the terminal (`CSI 16 t`) and fold the answer
    /// into the `Winsize` with `update`. `Caps.in_band_resize` is the better
    /// source for the rest where the terminal has it: the report arrives on
    /// the input stream, in step with everything else, rather than out of
    /// band and after the fact.
    pub fn size(t: *Tty) SizeError!Winsize {
        if (is_windows) {
            var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (GetConsoleScreenBufferInfo(t.file.handle, &info) == .FALSE) {
                return error.NotATerminal;
            }
            const cols = info.srWindow.Right - info.srWindow.Left + 1;
            const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
            return .{ .cells = .{ .cols = @intCast(@max(cols, 0)), .rows = @intCast(@max(rows, 0)) } };
        }
        var ws: std.posix.winsize = undefined;
        const err = std.posix.system.ioctl(t.file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(err) != .SUCCESS) return error.NotATerminal;
        return .{
            .cells = .{ .cols = ws.col, .rows = ws.row },
            .area = .{ .width = ws.xpixel, .height = ws.ypixel },
        };
    }

    /// A buffered writer over the terminal, in a buffer the caller owns.
    ///
    /// A frame should reach the terminal in one write, so the buffer wants
    /// to be at least as large as `Renderer.Stats.bytes` says a frame is.
    /// Nothing in this package flushes it.
    pub fn writer(t: *Tty, buf: []u8) Io.File.Writer {
        return .initStreaming(t.file, t.io, buf);
    }

    /// Anything reading from the terminal can fail with.
    pub const ReadError = Io.File.ReadStreamingError;

    /// Reads whatever is there, into a buffer the caller owns.
    pub fn read(t: *Tty, buf: []u8) ReadError!usize {
        const file = if (is_windows) t.input else t.file;
        return file.readStreaming(t.io, &.{buf});
    }

    /// Has a resize wake the reader: a handler for `SIGWINCH` that writes a
    /// byte into a pipe, which `Input.next` waits on beside the terminal and
    /// turns into a `resize` event carrying the size and pixels the
    /// operating system has now.
    ///
    /// Installed only when asked for, because a library that installs a
    /// signal handler takes something from the program that the program
    /// cannot get back; `unwatchResize` and `close` put the one it found
    /// back. The handler does nothing but that write, so a burst of signals
    /// is one wake and one event.
    ///
    /// A terminal that answers for mode 2048 makes this unnecessary: the
    /// resize arrives on the input stream, in step with everything else. On
    /// Windows there is no signal and this does nothing.
    pub fn watchResize(t: *Tty) error{ SystemResources, Unexpected }!void {
        _ = t;
        if (is_windows) return;
        if (resize_pipe[0] != -1) return;
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe(&fds))) {
            .SUCCESS => {},
            .MFILE, .NFILE => return error.SystemResources,
            else => return error.Unexpected,
        }
        errdefer for (fds) |fd| {
            _ = std.posix.system.close(fd);
        };
        for (fds) |fd| {
            try fcntlSet(fd, std.posix.F.SETFL, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
            try fcntlSet(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
        }
        resize_pipe = fds;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.WINCH, &action, &resize_was);
    }

    /// Puts back the `SIGWINCH` handler `watchResize` found, and closes the
    /// pipe. Safe to call when nothing is being watched.
    pub fn unwatchResize(t: *Tty) void {
        _ = t;
        if (is_windows or resize_pipe[0] == -1) return;
        std.posix.sigaction(.WINCH, &resize_was, null);
        for (resize_pipe) |fd| {
            _ = std.posix.system.close(fd);
        }
        resize_pipe = .{ -1, -1 };
    }

    /// Whether the terminal has changed size since this was last asked, for
    /// a program with a loop of its own rather than an `Input`. Never
    /// blocks; false when nothing is being watched.
    pub fn resized(t: *Tty) bool {
        _ = t;
        if (is_windows or resize_pipe[0] == -1) return false;
        return drainResizePipe();
    }

    /// The read end of the resize pipe, when a resize is being watched.
    pub fn resizeFile(t: *const Tty) ?Io.File {
        _ = t;
        if (is_windows or resize_pipe[0] == -1) return null;
        return .{ .handle = resize_pipe[0], .flags = .{ .nonblocking = true } };
    }

    /// The file keys and replies arrive on.
    pub fn inputFile(t: *const Tty) Io.File {
        return if (is_windows) t.input else t.file;
    }
};

/// The device behind `/dev/tty`, found as the device one of the standard
/// streams is open on when it is the same terminal: the same foreground
/// process group, which belongs to one session and so to one terminal.
/// Null when no standard stream is on it. macOS only.
fn deviceOf(ctty: std.posix.fd_t, buf: *[std.posix.PATH_MAX]u8) ?[]const u8 {
    const group = foregroundGroup(ctty) orelse return null;
    for ([_]std.posix.fd_t{ 0, 1, 2 }) |fd| {
        const theirs = foregroundGroup(fd) orelse continue;
        if (theirs != group) continue;
        @memset(buf, 0);
        if (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.GETPATH, @intFromPtr(buf))) != .SUCCESS) continue;
        const path = std.mem.sliceTo(buf, 0);
        if (!std.mem.startsWith(u8, path, "/dev/") or std.mem.eql(u8, path, "/dev/tty")) continue;
        return path;
    }
    return null;
}

/// The foreground process group of the terminal `fd` is open on, or null
/// when it is not a terminal. By ioctl, because Zig's libc bindings for
/// macOS have neither `tcgetpgrp` nor the request's name. macOS only.
fn foregroundGroup(fd: std.posix.fd_t) ?std.posix.pid_t {
    const tiocgpgrp = 0x40047477; // _IOR('t', 119, int)
    var group: std.posix.pid_t = 0;
    const rc = std.posix.system.ioctl(fd, ioctlRequest(tiocgpgrp), @intFromPtr(&group));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return group;
}

/// Puts the one open terminal back: the modes a renderer entered through
/// `Tty.enter` undone — keyboard flags popped, mouse, paste, focus and
/// colour-scheme reports off, the alternate screen left, the cursor shown —
/// and then the terminal's own mode.
///
/// Allocates nothing, fails at nothing, and is safe from a panic handler or
/// an atexit hook. A terminal that was never put in raw mode is left alone.
pub fn restoreGlobal() void {
    const was = open_tty orelse return;
    restoreSaved(was);
    open_tty = null;
}

/// A panic handler that puts the terminal back — screen, input modes and
/// raw mode — and then panics.
///
/// Yours to install, and never installed behind your back:
///
/// ```zig
/// pub const panic = visor.Tty.Panic;
/// ```
///
/// Without it, a program that panics in raw mode leaves the user with a
/// terminal that does not echo, which is a worse thing to do to someone than
/// the crash itself.
pub const Panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, first_trace_address: ?usize) noreturn {
        restoreGlobal();
        std.debug.defaultPanic(message, first_trace_address);
    }
}.call);

/// The way back, from whatever remembered it: the modes a renderer entered,
/// undone through a buffer on the stack and one write that may fail, then the
/// terminal's own mode.
fn restoreSaved(was: Saved) void {
    if (armed) |r| {
        armed = null;
        var buffer: [512]u8 = undefined;
        var out: Writer = .fixed(&buffer);
        r.leave(&out) catch {};
        writeRaw(if (is_windows) was.output else was.handle, out.buffered());
    }
    if (is_windows) {
        _ = SetConsoleMode(was.input, was.input_mode);
        _ = SetConsoleMode(was.output, was.output_mode);
        return;
    }
    // At once, not after the output drains: a terminal that is not reading
    // (paused, or gone) would hold a panicking program here for ever. What
    // was written is already queued and is sent either way.
    discardInput(was.handle);
    std.posix.tcsetattr(was.handle, .NOW, was.mode) catch {};
}

/// Throws away what the terminal sent that nobody read, without waiting on
/// the output: a late answer to a probe would otherwise land in the shell.
fn discardInput(handle: std.posix.fd_t) void {
    const T = std.posix.T;
    if (@hasDecl(T, "CFLSH")) {
        // TCIFLUSH, which is zero on every Linux architecture
        _ = std.posix.system.ioctl(handle, ioctlRequest(T.CFLSH), @as(usize, 0));
    } else if (@hasDecl(T, "IOCFLUSH")) {
        var which: c_int = 1; // FREAD
        _ = std.posix.system.ioctl(handle, ioctlRequest(T.IOCFLUSH), @intFromPtr(&which));
    }
}

/// The request argument as this system's `ioctl` spells its type: a
/// `c_int` through libc, where the high bit of a request is a sign bit.
const IoctlRequest = if (is_windows) u32 else @typeInfo(@TypeOf(std.posix.system.ioctl)).@"fn".params[1].type.?;
fn ioctlRequest(v: u32) IoctlRequest {
    return if (@typeInfo(IoctlRequest).int.signedness == .signed) @bitCast(v) else @intCast(v);
}

/// Bytes to a descriptor with nothing in between: no `Io`, no buffer, no
/// error, because the caller may be a panic handler with a broken `Io` and
/// nothing to report a failure to.
fn writeRaw(handle: if (is_windows) windows.HANDLE else std.posix.fd_t, bytes: []const u8) void {
    var left = bytes;
    while (left.len != 0) {
        if (is_windows) {
            var written: windows.DWORD = 0;
            const n: windows.DWORD = @intCast(@min(left.len, std.math.maxInt(windows.DWORD)));
            if (WriteFile(handle, left.ptr, n, &written, null) == .FALSE or written == 0) return;
            left = left[written..];
            continue;
        }
        const rc = std.posix.system.write(handle, left.ptr, left.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return;
                left = left[n..];
            },
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}

//=========================================================================
// The console, which `std.os.windows` carries the types for and not the
// entry points. Everything here is an `extern` declaration against the
// system import library, in the same style as `std.os.windows.kernel32`; no
// C is involved. Nothing below is reached off Windows.
//=========================================================================

const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
const ENABLE_QUICK_EDIT_MODE: windows.DWORD = 0x0040;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

const GENERIC_READ: windows.DWORD = 0x80000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const FILE_SHARE_READ: windows.DWORD = 0x00000001;
const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
const OPEN_EXISTING: windows.DWORD = 3;

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) windows.BOOL;

const testing = std.testing;

test "the global restore does nothing when no terminal was taken" {
    try testing.expectEqual(@as(?Saved, null), open_tty);
    restoreGlobal();
    try testing.expectEqual(@as(?Saved, null), open_tty);
}

test "the panic handler is a type to install, not something installed" {
    // Installing it is the caller's line of code, never this package's.
    try testing.expect(@TypeOf(Panic) == type);
    try testing.expect(@hasDecl(Panic, "call"));
}

/// The master end read on a thread of its own, for the calls that wait for
/// the output to drain before they return.
/// Everything the master end has been sent, until `want` bytes have come.
fn readAtLeast(io: Io, file: Io.File, buf: []u8, want: usize) ![]const u8 {
    var got: usize = 0;
    while (got < want) {
        const n = try file.readStreaming(io, &.{buf[got..]});
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

/// Everything the master end has been sent, until `part` is in it: a
/// write may arrive in more than one read.
fn readUntil(io: Io, file: Io.File, buf: []u8, part: []const u8) ![]const u8 {
    var got: usize = 0;
    while (std.mem.indexOf(u8, buf[0..got], part) == null) {
        if (got == buf.len) return error.NoSpaceLeft;
        const n = try file.readStreaming(io, &.{buf[got..]});
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

test "entering through the terminal arms the way back, and the panic path undoes exactly that" {
    if (is_windows) return error.SkipZigTest;
    var pair = try testing_pty.open(testing.io);
    defer pair.close();
    var t: Tty = .adopt(testing.io, pair.slave);
    const before = try std.posix.tcgetattr(t.file.handle);

    var r: Renderer = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer r.deinit(testing.allocator);
    const modes: render.Modes = .{
        .keyboard = .{ .report_event_types = true },
        .mouse = .{ .motion = .press },
        .paste = true,
    };
    try t.enter(&r, .{}, .alt, modes);
    try testing.expect(armed == &r);
    try testing.expect(t.saved != null);

    // What the renderer would write on the way out, worked out on a copy so
    // the real one is still entered.
    var copy = r;
    var want_buf: [512]u8 = undefined;
    var want: Writer = .fixed(&want_buf);
    try copy.leave(&want);

    var seen: [1024]u8 = undefined;
    const entered = try readAtLeast(testing.io, pair.master, &seen, 1);
    try testing.expect(std.mem.startsWith(u8, entered, "\x1b[?1049h\x1b[>2u"));

    // The panic path: no argument, no allocation, no failure, and no wait
    // on a terminal that is not reading: nothing reads the master until
    // the mode is back.
    restoreGlobal();
    try testing.expect(armed == null);
    try testing.expectEqual(@as(?Saved, null), open_tty);
    // what is left of the way in, then the way out, whole
    var out: [1024]u8 = undefined;
    const undone = try readUntil(testing.io, pair.master, &out, "\x1b[<u\x1b[?1049l");
    try testing.expect(std.mem.endsWith(u8, undone, want.buffered()));
    try testing.expect(std.mem.endsWith(u8, undone, "\x1b[<u\x1b[?1049l"));
    var after = try std.posix.tcgetattr(t.file.handle);
    // A BSD kernel marks input for retyping whenever canonical mode comes
    // back without a flush that waits on the output; it clears on the next
    // read and is not part of the mode that was found.
    if (@hasField(@TypeOf(after.lflag), "PENDIN")) after.lflag.PENDIN = before.lflag.PENDIN;
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.iflag, after.iflag);
    // The tty still thinks it is raw; that is the caller's own record, and
    // restoring it again is harmless.
    t.saved = null;
}

test "leaving through the terminal disarms, and a renderer that goes away is forgotten" {
    if (is_windows) return error.SkipZigTest;
    var pair = try testing_pty.open(testing.io);
    defer pair.close();
    var t: Tty = .adopt(testing.io, pair.slave);

    var r: Renderer = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    try t.enter(&r, .{}, .alt, .{ .paste = true });
    var seen: [256]u8 = undefined;
    const bytes = try readUntil(testing.io, pair.master, &seen, "\x1b[?2004h");
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004h") != null);

    // left with nothing reading the master: the way out must not wait on it
    try t.leave(&r);
    try testing.expect(armed == null);
    try testing.expect(t.saved == null);
    const undone = try readUntil(testing.io, pair.master, &seen, "\x1b[?1049l");
    try testing.expect(std.mem.indexOf(u8, undone, "\x1b[?2004l") != null);

    // Entered again, and the renderer goes away without leaving: the way
    // back forgets it rather than reaching for it.
    try t.enter(&r, .{}, .alt, .{});
    _ = try readAtLeast(testing.io, pair.master, &seen, 1);
    r.deinit(testing.allocator);
    try testing.expect(armed == null);
    t.restore();
}

test "opening this program's terminal compiles and fails cleanly without one" {
    // `open` is analysed only where it is called, and nothing else in the
    // suite calls it: a platform it did not compile on went unnoticed.
    if (Tty.open(testing.io)) |opened| {
        var t = opened;
        t.close();
    } else |_| {}
}

test "the size carries the text area in pixels where the terminal set it" {
    if (is_windows) return error.SkipZigTest;
    var pair = try testing_pty.open(testing.io);
    defer pair.close();
    try pair.setSize(.{ .row = 40, .col = 132, .xpixel = 1188, .ypixel = 800 });

    var t: Tty = .adopt(testing.io, pair.slave);
    const ws = try t.size();
    try testing.expectEqual(@as(u16, 132), ws.cells.cols);
    try testing.expectEqual(@as(u16, 40), ws.cells.rows);
    try testing.expectEqual(@as(u32, 1188), ws.area.width);
    try testing.expectEqual(@as(u32, 800), ws.area.height);
    // The operating system knows the area, never the cell.
    try testing.expect(!ws.cell.known());
    try testing.expect(!ws.cellSize().?.reported);
}

test "a file that is not a terminal has no size" {
    if (is_windows) return error.SkipZigTest;
    const fds = try testing_pty.pipe();
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    var t: Tty = .adopt(testing.io, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    try testing.expectError(error.NotATerminal, t.size());
}

/// A pseudo-terminal for the suite, opened without libc: the master from
/// `/dev/ptmx`, unlocked and named by the ioctls each kernel spells its own
/// way, and the slave by that name. Test-only.
pub const testing_pty = struct {
    pub const Pair = struct {
        io: Io,
        master: Io.File,
        slave: Io.File,

        pub fn setSize(p: *Pair, ws: std.posix.winsize) !void {
            const rc = std.posix.system.ioctl(p.master.handle, set_winsize, @intFromPtr(&ws));
            if (std.posix.errno(rc) != .SUCCESS) return error.Unexpected;
        }

        pub fn close(p: *Pair) void {
            p.slave.close(p.io);
            p.master.close(p.io);
        }
    };

    const set_winsize = ioctlRequest(switch (builtin.os.tag) {
        .linux => std.os.linux.T.IOCSWINSZ,
        else => 0x80087467,
    });

    pub fn open(io: Io) !Pair {
        const master = try Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write });
        errdefer master.close(io);
        var name_buf: [128]u8 = @splat(0);
        const name: []const u8 = switch (builtin.os.tag) {
            .linux => blk: {
                var unlock: c_int = 0;
                if (std.posix.errno(std.posix.system.ioctl(master.handle, std.os.linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
                    return error.Unexpected;
                var n: c_uint = 0;
                if (std.posix.errno(std.posix.system.ioctl(master.handle, std.os.linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS)
                    return error.Unexpected;
                break :blk try std.fmt.bufPrint(&name_buf, "/dev/pts/{d}", .{n});
            },
            .macos => blk: {
                const grant = ioctlRequest(0x20007454); // TIOCPTYGRANT
                const unlock = ioctlRequest(0x20007452); // TIOCPTYUNLK
                const get_name = ioctlRequest(0x40807453); // TIOCPTYGNAME
                if (std.posix.errno(std.posix.system.ioctl(master.handle, grant, @as(usize, 0))) != .SUCCESS) return error.Unexpected;
                if (std.posix.errno(std.posix.system.ioctl(master.handle, unlock, @as(usize, 0))) != .SUCCESS) return error.Unexpected;
                if (std.posix.errno(std.posix.system.ioctl(master.handle, get_name, @intFromPtr(&name_buf))) != .SUCCESS)
                    return error.Unexpected;
                break :blk std.mem.sliceTo(&name_buf, 0);
            },
            else => return error.SkipZigTest,
        };
        const slave = try Io.Dir.openFileAbsolute(io, name, .{ .mode = .read_write });
        return .{ .io = io, .master = master, .slave = slave };
    }

    pub fn pipe() ![2]std.posix.fd_t {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.posix.errno(std.posix.system.pipe(&fds)) != .SUCCESS) return error.Unexpected;
        return fds;
    }
};
