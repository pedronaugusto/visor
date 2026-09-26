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
//! The terminal's own calls -- raw mode and the way back, the size, the
//! device's name and its foreground group -- are conduit's (`conduit.tty`),
//! which owns them for this package and for the programs that run a child on
//! a pseudo-terminal alike. What is here is what a screen needs on top: the
//! controlling terminal opened, the modes a renderer entered undone on every
//! way out, and a resize woken into the input.
//!
//! What this file will never hold: a parser, a screen, a frame, a clock, or
//! a thread.

const std = @import("std");
const builtin = @import("builtin");
const morse = @import("morse");
const terminal = @import("conduit.tty");

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

/// A pipe's descriptor, `-1` for none.
const Fd = if (is_windows) i32 else std.posix.fd_t;

/// The write end of every watching `Tty`'s resize pipe, `-1` for a free
/// slot. The signal is the process's, so the one handler has to reach every
/// terminal that watches it; each `Tty` owns its pipe and only names its
/// write end here. Atomic because the handler reads it at any moment.
var watchers: [max_watchers]std.atomic.Value(Fd) = @splat(.init(-1));
/// How many terminals can watch at once. A program has one terminal; a
/// test, or a program that also drives a pseudo-terminal of its own, a few.
const max_watchers = 8;
/// How many slots are taken, which says when the handler goes in and when
/// the one it replaced comes back.
var watching: usize = 0;
/// The `SIGWINCH` handler that was there before the first watcher.
var resize_was: if (is_windows) void else std.posix.Sigaction = undefined;

/// The handler: one byte into each watcher's pipe, which is all a signal
/// handler may do. A full pipe already holds a wake, so a write that would
/// block is dropped.
fn onWinch(_: std.posix.SIG) callconv(.c) void {
    const byte: [1]u8 = .{'w'};
    for (&watchers) |*w| {
        const fd = w.load(.acquire);
        if (fd != -1) _ = std.posix.system.write(fd, &byte, 1);
    }
}

/// Empties a resize pipe's read end; whether there was anything in it.
fn drainPipe(fd: Fd) bool {
    var any = false;
    var sink: [64]u8 = undefined;
    while (true) {
        const rc = std.posix.system.read(fd, &sink, sink.len);
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) return any;
        any = true;
    }
}

fn fcntlSet(fd: std.posix.fd_t, cmd: i32, arg: u32) error{Unexpected}!void {
    const rc = std.posix.system.fcntl(fd, cmd, @as(usize, arg));
    if (std.posix.errno(rc) != .SUCCESS) return error.Unexpected;
}

/// What the terminal was before this program touched it: the mode of each
/// handle, which on Windows is two.
const Saved = if (is_windows) struct {
    input: windows.HANDLE,
    output: windows.HANDLE,
    input_mode: terminal.Saved,
    output_mode: terminal.Saved,
} else struct {
    handle: std.posix.fd_t,
    mode: terminal.Saved,
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
    /// This terminal's resize pipe, read end first, while it watches for a
    /// resize; `-1` otherwise.
    resize_pipe: [2]Fd = .{ -1, -1 },

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
            const input_mode = terminal.rawMode(t.input.handle) catch |err| return modeError(err);
            const output_mode = terminal.rawMode(t.file.handle) catch |err| {
                terminal.restore(t.input.handle, input_mode) catch {};
                return modeError(err);
            };
            const saved: Saved = .{
                .input = t.input.handle,
                .output = t.file.handle,
                .input_mode = input_mode,
                .output_mode = output_mode,
            };
            t.saved = saved;
            open_tty = saved;
            return;
        }
        const was = terminal.rawMode(t.file.handle) catch |err| return modeError(err);
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
        const got = terminal.winSize(t.file.handle) catch |err| return switch (err) {
            error.NotATerminal => error.NotATerminal,
            error.Unexpected => error.Unexpected,
        };
        return .{
            .cells = .{ .cols = got.cols, .rows = got.rows },
            .area = .{ .width = got.x_pixel, .height = got.y_pixel },
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
    /// byte into this terminal's own pipe, which `Input.next` waits on beside
    /// the terminal and turns into a `resize` event carrying the size and
    /// pixels the operating system has now.
    ///
    /// The pipe is this `Tty`'s, so two terminals watching -- a program's
    /// own and one it drives, or two in a test -- each get their wake and
    /// neither's `unwatchResize` takes the other's away. The signal is the
    /// process's, so its handler is installed once, when the first terminal
    /// watches, and only when asked for, because a library that installs a
    /// signal handler takes something from the program that the program
    /// cannot get back; the last terminal to stop watching puts back the one
    /// the first found. The handler does nothing but write, so a burst of
    /// signals is one wake and one event.
    ///
    /// A terminal that answers for mode 2048 makes this unnecessary: the
    /// resize arrives on the input stream, in step with everything else. On
    /// Windows there is no signal and this does nothing.
    pub fn watchResize(t: *Tty) error{ SystemResources, Unexpected }!void {
        if (is_windows) return;
        if (t.resize_pipe[0] != -1) return;
        if (watching == max_watchers) return error.SystemResources;
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
        for (&watchers) |*w| {
            if (w.load(.acquire) != -1) continue;
            w.store(fds[1], .release);
            break;
        }
        t.resize_pipe = fds;
        watching += 1;
        if (watching == 1) {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = onWinch },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.RESTART,
            };
            std.posix.sigaction(.WINCH, &action, &resize_was);
        }
    }

    /// Stops this terminal watching, and closes its pipe; when it was the
    /// last one watching, puts back the `SIGWINCH` handler the first one
    /// found. Safe to call when nothing is being watched.
    pub fn unwatchResize(t: *Tty) void {
        if (is_windows or t.resize_pipe[0] == -1) return;
        for (&watchers) |*w| {
            if (w.load(.acquire) == t.resize_pipe[1]) w.store(-1, .release);
        }
        watching -= 1;
        if (watching == 0) std.posix.sigaction(.WINCH, &resize_was, null);
        for (t.resize_pipe) |fd| {
            _ = std.posix.system.close(fd);
        }
        t.resize_pipe = .{ -1, -1 };
    }

    /// Whether the terminal has changed size since this was last asked, for
    /// a program with a loop of its own rather than an `Input`. Never
    /// blocks; false when nothing is being watched.
    pub fn resized(t: *Tty) bool {
        if (is_windows or t.resize_pipe[0] == -1) return false;
        return drainPipe(t.resize_pipe[0]);
    }

    /// Empties this terminal's resize pipe, which woke a wait. `Input` calls
    /// this after the pipe woke it.
    pub fn drainResize(t: *Tty) void {
        if (is_windows or t.resize_pipe[0] == -1) return;
        _ = drainPipe(t.resize_pipe[0]);
    }

    /// The read end of this terminal's resize pipe, while it watches.
    pub fn resizeFile(t: *const Tty) ?Io.File {
        if (is_windows or t.resize_pipe[0] == -1) return null;
        return .{ .handle = t.resize_pipe[0], .flags = .{ .nonblocking = true } };
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
    const group = terminal.foregroundGroup(ctty) catch return null;
    for ([_]std.posix.fd_t{ 0, 1, 2 }) |fd| {
        const theirs = terminal.foregroundGroup(fd) catch continue;
        if (theirs != group) continue;
        const path = terminal.ttyName(fd, buf) catch continue;
        if (!std.mem.startsWith(u8, path, "/dev/") or std.mem.eql(u8, path, "/dev/tty")) continue;
        return path;
    }
    return null;
}

/// A primitive's failure as this file's.
fn modeError(err: terminal.RawModeError) Tty.ModeError {
    return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.ProcessOrphaned, error.Unexpected => error.Unexpected,
    };
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
        terminal.restore(was.input, was.input_mode) catch {};
        terminal.restore(was.output, was.output_mode) catch {};
        return;
    }
    // At once, not after the output drains, and with unread input thrown
    // away: conduit's `restore` never waits on a terminal that is not reading
    // (paused, or gone), which would hold a panicking program here for ever.
    terminal.restore(was.handle, was.mode) catch {};
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

const GENERIC_READ: windows.DWORD = 0x80000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const FILE_SHARE_READ: windows.DWORD = 0x00000001;
const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
const OPEN_EXISTING: windows.DWORD = 3;

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
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
    var pair = try conduit.Pty.open(.{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(testing.io, pair.slaveFile());
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
    const entered = try readAtLeast(testing.io, pair.readFile(), &seen, 1);
    try testing.expect(std.mem.startsWith(u8, entered, "\x1b[?1049h\x1b[>2u"));

    // The panic path: no argument, no allocation, no failure, and no wait
    // on a terminal that is not reading: nothing reads the master until
    // the mode is back.
    restoreGlobal();
    try testing.expect(armed == null);
    try testing.expectEqual(@as(?Saved, null), open_tty);
    // what is left of the way in, then the way out, whole
    var out: [1024]u8 = undefined;
    const undone = try readUntil(testing.io, pair.readFile(), &out, "\x1b[<u\x1b[?1049l");
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
    var pair = try conduit.Pty.open(.{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(testing.io, pair.slaveFile());

    var r: Renderer = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    try t.enter(&r, .{}, .alt, .{ .paste = true });
    var seen: [256]u8 = undefined;
    const bytes = try readUntil(testing.io, pair.readFile(), &seen, "\x1b[?2004h");
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004h") != null);

    // left with nothing reading the master: the way out must not wait on it
    try t.leave(&r);
    try testing.expect(armed == null);
    try testing.expect(t.saved == null);
    const undone = try readUntil(testing.io, pair.readFile(), &seen, "\x1b[?1049l");
    try testing.expect(std.mem.indexOf(u8, undone, "\x1b[?2004l") != null);

    // Entered again, and the renderer goes away without leaving: the way
    // back forgets it rather than reaching for it.
    try t.enter(&r, .{}, .alt, .{});
    _ = try readAtLeast(testing.io, pair.readFile(), &seen, 1);
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
    var pair = try conduit.Pty.open(.{ .rows = 40, .cols = 132, .x_pixel = 1188, .y_pixel = 800 });
    defer pair.close(testing.io);

    var t: Tty = .adopt(testing.io, pair.slaveFile());
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
    const fds = try pipe();
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    var t: Tty = .adopt(testing.io, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    try testing.expectError(error.NotATerminal, t.size());
}

/// The pseudo-terminal the suite runs against is conduit's, as the
/// terminal primitives are.
const conduit = @import("conduit");

/// A pipe, for a test that wants a file that is not a terminal.
pub fn pipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(std.posix.system.pipe(&fds)) != .SUCCESS) return error.Unexpected;
    return fds;
}
