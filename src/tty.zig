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

const geom = @import("geom.zig");

const Io = std.Io;
const Size = geom.Size;
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
    /// Whether a resize handler has been installed.
    watching: bool = false,

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
        return .{ .file = file, .io = io, .input = {} };
    }

    /// Gives the terminal back, restoring its mode first if it was changed.
    pub fn close(t: *Tty) void {
        t.restore();
        t.file.close(t.io);
        if (is_windows) t.input.close(t.io);
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
            if (SetConsoleMode(t.input.handle, want_in) == .FALSE) return error.Unexpected;
            if (SetConsoleMode(t.file.handle, want_out) == .FALSE) return error.Unexpected;
            t.saved = saved;
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

    /// The mode as it was found. Safe to call when it was never changed.
    pub fn restore(t: *Tty) void {
        const was = t.saved orelse return;
        restoreSaved(was);
        t.saved = null;
        open_tty = null;
    }

    /// How big the terminal is, from the operating system.
    ///
    /// `Caps.in_band_resize` is the better source where the terminal has it:
    /// the report arrives on the input stream, in step with everything else,
    /// rather than out of band and after the fact.
    pub fn size(t: *Tty) SizeError!Size {
        if (is_windows) {
            var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (GetConsoleScreenBufferInfo(t.file.handle, &info) == .FALSE) {
                return error.NotATerminal;
            }
            const cols = info.srWindow.Right - info.srWindow.Left + 1;
            const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
            return .{ .cols = @intCast(@max(cols, 0)), .rows = @intCast(@max(rows, 0)) };
        }
        var ws: std.posix.winsize = undefined;
        const err = std.posix.system.ioctl(t.file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(err) != .SUCCESS) return error.NotATerminal;
        return .{ .cols = ws.col, .rows = ws.row };
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

    /// Calls `handler` when the terminal changes size.
    ///
    /// Installed only when asked for, because a library that installs a
    /// signal handler takes something from the program that the program
    /// cannot get back. The handler runs in a signal context: it may not
    /// allocate, may not lock and may not draw. Set a flag and read it from
    /// the loop; ask the size again when you do, because the one that was
    /// current when the signal arrived may not be any more.
    ///
    /// A terminal that answers for mode 2048 makes this unnecessary: the
    /// resize arrives on the input stream, as an event rather than an
    /// interruption.
    pub fn onResize(t: *Tty, comptime handler: fn () void) error{}!void {
        if (is_windows) {
            // The console reports a resize as an input record, which the
            // read path already sees; there is no signal to install.
            t.watching = true;
            return;
        }
        const wrapped = struct {
            fn onSignal(_: i32) callconv(.c) void {
                handler();
            }
        };
        var action: std.posix.Sigaction = .{
            .handler = .{ .handler = wrapped.onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.WINCH, &action, null);
        t.watching = true;
    }
};

/// Puts the one open terminal back.
///
/// Allocates nothing, fails at nothing, and is safe from a panic handler or
/// an atexit hook. A terminal that was never put in raw mode is left alone.
pub fn restoreGlobal() void {
    const was = open_tty orelse return;
    restoreSaved(was);
    open_tty = null;
}

/// A panic handler that puts the terminal back and then panics.
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

/// The way back, from whatever remembered it.
fn restoreSaved(was: Saved) void {
    if (is_windows) {
        _ = SetConsoleMode(was.input, was.input_mode);
        _ = SetConsoleMode(was.output, was.output_mode);
        return;
    }
    std.posix.tcsetattr(was.handle, .FLUSH, was.mode) catch {};
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
