//! This program's own terminal.
//!
//! Separate, and optional. A program that already owns its terminal — a
//! multiplexer, a test harness, a client with a daemon behind it — needs
//! none of this terminal ownership. Picture transport separately
//! opens shared-memory objects when explicitly configured.
//!
//! What it owns is small and dangerous: the mode the terminal was found in,
//! and the way back to it. Everything else — the timeouts, the event loop,
//! when to read, when to flush — is the caller's. No thread is started, no
//! signal is listened for unless asked for (through reactor's `Signals`,
//! which owns the process's handlers), and no panic handler is installed
//! behind anyone's back.
//!
//! The registrations for raw terminals live here, so
//! `restoreGlobal` can put every terminal back from a panic handler, where
//! there is nothing to pass and nothing that may fail.
//!
//! The terminal's own calls -- opening it, raw mode and the way back, the
//! size, the device's name and its foreground group, and the console's
//! entry points on Windows -- are conduit's (`conduit.tty`), which owns them
//! for this package and for the programs that run a child on a
//! pseudo-terminal alike. What is here is what a screen needs on top: a
//! device the reader can poll, the modes a renderer entered undone on every
//! way out, and a resize woken into the input.
//!
//! What this file will never hold: a parser, a screen, a frame, a clock, or
//! a thread.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("dependencies.zig").tty;
const reactor = @import("dependencies.zig").reactor;

const Winsize = @import("winsize.zig").Winsize;
const render = @import("render.zig");
const Caps = @import("caps.zig").Caps;
const Renderer = render.Renderer;

const Io = std.Io;
const Writer = std.Io.Writer;
const windows = std.os.windows;
const is_windows = builtin.target.os.tag == .windows;

/// Raw terminals registered for panic restoration. Each terminal owns its
/// saved mode and renderer association; the list only makes them reachable.
var open_ttys: ?*Tty = null;

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
/// Keep its address stable between `raw` and `restore`, and call these
/// operations, including resize registration for every terminal, from one
/// thread. An entered renderer must stay alive and at the same address until
/// `leave`, `restore` or `close` releases it.
pub const Tty = struct {
    /// Private: the terminal itself.
    file: Io.File,
    /// Private: on Windows, the input handle, which is a second descriptor.
    input: if (is_windows) Io.File else void,
    /// Private: what the terminal was before `raw`, or null when it has not been
    /// changed.
    saved: ?Saved = null,
    /// Private: the renderer exclusively borrowed by this terminal until restoration.
    own_renderer: ?*Renderer = null,
    /// Private: the next raw terminal in the panic registrations.
    next_raw: ?*Tty = null,
    /// Private: this terminal's listener for the resize signal, while it watches for one.
    resize: ?reactor.Signals = null,

    /// Anything opening the terminal can fail with.
    pub const OpenError = terminal.OpenControllingError;
    /// Anything changing its mode can fail with.
    pub const ModeError = error{ NotATerminal, Unexpected };
    /// Anything asking its size can fail with.
    pub const SizeError = error{ NotATerminal, Unexpected };

    /// The program's controlling terminal: `/dev/tty` on POSIX (on macOS
    /// under a name `poll` can wait on), the console handles on Windows,
    /// opened by `conduit.tty.openControlling`.
    ///
    /// Not the standard streams: a program whose output is a pipe still has
    /// a terminal, and a program drawing a screen wants the terminal rather
    /// than whatever its output was redirected to.
    pub fn open(io: Io) OpenError!Tty {
        const own = try terminal.openControlling(io);
        if (is_windows) return .{ .file = own.output, .input = own.input };
        return .{ .file = own.output, .input = {} };
    }

    /// A terminal the program already has open: a descriptor it was handed,
    /// or the far end of a pseudo-terminal it made. Everything `open` gives
    /// works on it, and `close` closes the file.
    pub fn adopt(file: Io.File) Tty {
        return .{ .file = file, .input = if (is_windows) file else {} };
    }

    /// Gives the terminal back, restoring its mode first if it was changed.
    pub fn close(t: *Tty, io: Io) void {
        t.restore();
        t.unwatchResize(io);
        t.file.close(io);
        if (is_windows and t.input.handle != t.file.handle) t.input.close(io);
        t.* = undefined;
    }

    /// Raw mode: no line editing, no echo, no signals from control keys, and
    /// a read that returns as soon as there is anything.
    ///
    /// The mode is remembered here, and this terminal is registered so
    /// `restoreGlobal` can put it back from a panic.
    pub fn raw(t: *Tty) ModeError!void {
        if (t.saved != null) return;
        if (is_windows) {
            const input_mode = terminal.rawMode(t.input.handle) catch |err| return modeError(err);
            const output_mode = terminal.rawMode(t.file.handle) catch |err| {
                // glint-ignore: Z026 -- the output's failure is the one reported; a second has nowhere to go
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
            t.register();
            return;
        }
        const was = terminal.rawMode(t.file.handle) catch |err| return modeError(err);
        const saved: Saved = .{ .handle = t.file.handle, .mode = was };
        t.saved = saved;
        t.register();
    }

    /// The mode as it was found, and the screen and input modes a renderer
    /// entered through `enter` undone as well. Safe to call when nothing
    /// was changed; POSIX output is best effort when the terminal is full.
    pub fn restore(t: *Tty) void {
        const was = t.saved orelse return;
        const r = t.own_renderer;
        t.own_renderer = null;
        t.saved = null;
        t.unregister();
        restoreSaved(was, r);
    }

    fn register(t: *Tty) void {
        t.next_raw = open_ttys;
        open_ttys = t;
    }

    fn unregister(t: *Tty) void {
        var slot = &open_ttys;
        while (slot.*) |held| {
            if (held == t) {
                slot.* = t.next_raw;
                t.next_raw = null;
                return;
            }
            slot = &held.next_raw;
        }
    }

    /// Anything entering or leaving a screen can fail with.
    pub const EnterError = ModeError || Renderer.Error || error{AlreadyEntered};

    /// Takes the screen: raw mode, then everything `Renderer.enter` writes,
    /// flushed. From here the way back — `leave`, `restore`, `close`,
    /// `restoreGlobal` and `Panic` — undoes the modes the renderer has on at
    /// the time as well as the terminal's mode. An already-entered terminal
    /// or renderer returns `AlreadyEntered` before raw mode changes.
    pub fn enter(
        t: *Tty,
        io: Io,
        r: *Renderer,
        caps: Caps,
        mode: render.Mode,
        modes: render.Modes,
    ) EnterError!void {
        if (t.own_renderer != null or r.entered() != null) return error.AlreadyEntered;
        try t.raw();
        t.own_renderer = r;
        var buffer: [256]u8 = undefined;
        var out = t.writer(io, &buffer);
        try r.enter(&out.interface, caps, mode, modes);
        try out.interface.flush();
    }

    /// Gives the screen back: everything `Renderer.leave` writes, flushed,
    /// and then the terminal's mode as it was found.
    pub fn leave(t: *Tty, io: Io) Renderer.Error!void {
        const r = t.own_renderer orelse {
            t.restore();
            return;
        };
        defer t.restore();
        // Keep the restoration intent until the terminal accepts the leave
        // bytes, including the flush. On failure `restore` retries through
        // the saved descriptor using the still-entered renderer.
        var buffer: [256]u8 = undefined;
        var out = t.writer(io, &buffer);
        try render.internal.leaveFlushed(r, &out.interface);
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
    pub fn writer(t: *Tty, io: Io, buf: []u8) Io.File.Writer {
        return .initStreaming(t.file, io, buf);
    }

    /// Anything reading from the terminal can fail with.
    pub const ReadError = Io.File.ReadStreamingError;

    /// Reads whatever is there, into a buffer the caller owns.
    pub fn read(t: *Tty, io: Io, buf: []u8) ReadError!usize {
        const file = if (is_windows) t.input else t.file;
        return file.readStreaming(io, &.{buf});
    }

    /// What `watchResize` fails with: no listener could be had.
    pub const WatchResizeError = error{ SystemResources, Unexpected };

    /// Has a resize wake the reader: a listener for `SIGWINCH` on reactor's
    /// `Signals`, which `Input.next` waits on beside the terminal and turns
    /// into a `resize` event carrying the size and pixels the operating
    /// system has now.
    ///
    /// The listener is this `Tty`'s, so two terminals watching -- a program's
    /// own and one it drives, or two in a test -- each get their wake and
    /// neither's `unwatchResize` takes the other's away. The signal is the
    /// process's, and reactor owns its handler: it is installed when the
    /// first listener of any kind starts and the one it found is put back
    /// when the last stops, and it tells every listener, a program's own
    /// among them. A burst of signals is one wake and one event.
    ///
    /// A terminal that answers for mode 2048 makes this unnecessary: the
    /// resize arrives on the input stream, in step with everything else. On
    /// Windows there is no signal and this does nothing.
    pub fn watchResize(t: *Tty, io: Io) WatchResizeError!void {
        if (is_windows) return;
        if (t.resize != null) return;
        t.resize = reactor.Signals.start(io, &.{.window_change}) catch |err| switch (err) {
            error.TooManyListeners => return error.SystemResources,
            error.Unsupported, error.Unexpected => return error.Unexpected,
            else => return error.SystemResources,
        };
    }

    /// Stops this terminal watching; when it was the last listener of the
    /// signal, reactor puts back the handler it found. Safe to call when
    /// nothing is being watched.
    pub fn unwatchResize(t: *Tty, io: Io) void {
        if (is_windows) return;
        if (t.resize) |*listener| listener.stop(io);
        t.resize = null;
    }

    /// Whether the terminal has changed size since this was last asked, for
    /// a program with a loop of its own rather than an `Input`. Never
    /// blocks; false when nothing is being watched.
    pub fn resized(t: *Tty, io: Io) bool {
        return t.takeResize(io);
    }

    /// Takes what a wait on `resizeWake` reported. `Input` calls this after
    /// the wake woke it.
    pub fn drainResize(t: *Tty, io: Io) void {
        _ = t.takeResize(io);
    }

    fn takeResize(t: *Tty, io: Io) bool {
        if (is_windows) return false;
        const listener = &(t.resize orelse return false);
        var any = false;
        while (listener.next(io, .{ .duration = .{ .raw = .zero, .clock = .awake } })) |_| {
            any = true;
        } else |_| {}
        return any;
    }

    /// The wake a delivery of the resize signal sets, to wait on beside the
    /// terminal while it watches.
    pub fn resizeWake(t: *const Tty) ?*reactor.Wake {
        if (is_windows) return null;
        const listener = t.resize orelse return null;
        return listener.wake();
    }

    /// The file keys and replies arrive on.
    pub fn inputFile(t: *const Tty) Io.File {
        return if (is_windows) t.input else t.file;
    }
};

/// A primitive's failure as this file's.
fn modeError(err: terminal.RawModeError) Tty.ModeError {
    return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.ProcessOrphaned, error.Unexpected => error.Unexpected,
    };
}

/// Puts every registered terminal back: the modes a renderer entered through
/// `Tty.enter` undone — keyboard flags popped, mouse, paste, focus and
/// colour-scheme reports off, the alternate screen left, the cursor shown —
/// and the terminal's own mode. POSIX restores raw mode first.
///
/// Allocates nothing, fails at nothing, and is safe from a panic handler or
/// an atexit hook. A terminal that was never put in raw mode is left alone.
pub fn restoreGlobal() void {
    while (open_ttys) |t| t.restore();
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
/// undone through a buffer on the stack and output that may fail. On POSIX,
/// raw mode comes back first and the output never waits for space.
fn restoreSaved(was: Saved, renderer: ?*Renderer) void {
    // Raw mode must come back even when output cannot accept a byte. Every
    // step is best effort: the caller may be a panic handler, nothing here
    // can report a failure, and a step that fails must not stop the next.
    // glint-ignore: Z026 -- best effort, see above
    if (!is_windows) terminal.restore(was.handle, was.mode) catch {};
    if (renderer) |r| {
        var buffer: [512]u8 = undefined;
        var out: Writer = .fixed(&buffer);
        // glint-ignore: Z026 -- a full buffer still holds the sequences that fit, which are written
        r.leave(&out) catch {};
        writeRaw(if (is_windows) was.output else was.handle, out.buffered());
    }
    if (is_windows) {
        // glint-ignore: Z026 -- best effort, see above
        terminal.restore(was.input, was.input_mode) catch {};
        // glint-ignore: Z026 -- best effort, see above
        terminal.restore(was.output, was.output_mode) catch {};
        return;
    }
}

/// Bytes to a descriptor with nothing in between: no `Io`, no buffer, no
/// error, because the caller may be a panic handler with a broken `Io` and
/// nothing to report a failure to.
fn writeRaw(handle: if (is_windows) windows.HANDLE else std.posix.fd_t, bytes: []const u8) void {
    // Best effort: a full terminal must never hold up panic restoration.
    const flags = if (!is_windows) std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(u32, 0)) else 0;
    if (!is_windows) {
        if (std.posix.errno(flags) != .SUCCESS) return;
        const nonblock = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
        fcntlSet(handle, std.posix.F.SETFL, @as(u32, @intCast(flags)) | nonblock) catch return;
    }
    // glint-ignore: Z026 -- putting the flags back is best effort after the write has finished or failed; the write's own result is the one returned
    defer if (!is_windows) fcntlSet(handle, std.posix.F.SETFL, @intCast(flags)) catch {};
    var left = bytes;
    while (left.len != 0) {
        if (is_windows) {
            var written: windows.DWORD = 0;
            const n: windows.DWORD = @intCast(@min(left.len, std.math.maxInt(windows.DWORD)));
            if (terminal.console.WriteFile(handle, left.ptr, n, &written, null) == .FALSE or written == 0) return;
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
            .INTR => continue,
            else => return,
        }
    }
}

const testing = std.testing;

test "the global restore does nothing when no terminal was taken" {
    try testing.expect(open_ttys == null);
    restoreGlobal();
    try testing.expect(open_ttys == null);
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
    while (std.mem.find(u8, buf[0..got], part) == null) {
        if (got == buf.len) return error.NoSpaceLeft;
        const n = try file.readStreaming(io, &.{buf[got..]});
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

/// The attributes a terminal has, read through conduit: its raw mode hands
/// back what it found, and `restore` puts that back at once. Never
/// `std.posix.tcgetattr`: with a C library linked on Linux it writes the C
/// library's `struct termios` over std's kernel-layout one, which is
/// smaller, and the stack under it is overwritten.
fn attributesOf(handle: terminal.Handle) !std.posix.termios {
    const found = try terminal.rawMode(handle);
    try terminal.restore(handle, found);
    return found.termios;
}

test "entering through the terminal arms the way back, and the panic path undoes exactly that" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(pair.slaveFile());
    const before = try attributesOf(t.file.handle);

    var r: Renderer = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer r.deinit();
    const modes: render.Modes = .{
        .keyboard = .{ .report_event_types = true },
        .mouse = .{ .motion = .press },
        .paste = true,
    };
    try t.enter(testing.io, &r, .{}, .alt, modes);
    try testing.expect(t.own_renderer == &r);
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
    try testing.expect(t.own_renderer == null);
    try testing.expect(open_ttys == null);
    // what is left of the way in, then the way out, whole
    var out: [1024]u8 = undefined;
    const undone = try readUntil(testing.io, pair.readFile(), &out, "\x1b[<u\x1b[?1049l");
    try testing.expect(std.mem.endsWith(u8, undone, want.buffered()));
    try testing.expect(std.mem.endsWith(u8, undone, "\x1b[<u\x1b[?1049l"));
    var after = try attributesOf(t.file.handle);
    // A BSD kernel marks input for retyping whenever canonical mode comes
    // back without a flush that waits on the output; it clears on the next
    // read and is not part of the mode that was found.
    if (@hasField(@TypeOf(after.lflag), "PENDIN")) after.lflag.PENDIN = before.lflag.PENDIN;
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.iflag, after.iflag);
    try testing.expect(t.saved == null);
    t.restore();
}

test "leaving through the terminal releases its renderer before destruction" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(pair.slaveFile());

    var r: Renderer = try .init(testing.allocator, .{ .cols = 4, .rows = 2 });
    try t.enter(testing.io, &r, .{}, .alt, .{ .paste = true });
    var seen: [256]u8 = undefined;
    const bytes = try readUntil(testing.io, pair.readFile(), &seen, "\x1b[?2004h");
    try testing.expect(std.mem.find(u8, bytes, "\x1b[?2004h") != null);

    // left with nothing reading the master: the way out must not wait on it
    try t.leave(testing.io);
    try testing.expect(t.own_renderer == null);
    try testing.expect(t.saved == null);
    const undone = try readUntil(testing.io, pair.readFile(), &seen, "\x1b[?1049l");
    try testing.expect(std.mem.find(u8, undone, "\x1b[?2004l") != null);

    r.deinit();
    t.restore();
}

test "opening this program's terminal compiles and fails cleanly without one" {
    // `open` is analysed only where it is called, and nothing else in the
    // suite calls it: a platform it did not compile on went unnoticed.
    if (Tty.open(testing.io)) |opened| {
        var t = opened;
        t.close(testing.io);
    } else |_| {}
}

test "the size carries the text area in pixels where the terminal set it" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{ .rows = 40, .cols = 132, .x_pixel = 1188, .y_pixel = 800 });
    defer pair.close(testing.io);

    var t: Tty = .adopt(pair.slaveFile());
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
    var t: Tty = .adopt(.{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    try testing.expectError(error.NotATerminal, t.size());
}

/// The pseudo-terminal the suite runs against is conduit's, as the
/// terminal primitives are.
const conduit = @import("dependencies.zig").conduit;

/// What `pipe` fails with.
pub const PipeError = error{Unexpected};

/// A pipe, for a test that wants a file that is not a terminal.
pub fn pipe() PipeError![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(std.posix.system.pipe(&fds)) != .SUCCESS) return error.Unexpected;
    return fds;
}

test "two terminals cannot borrow the same entered renderer" {
    if (is_windows) return error.SkipZigTest;
    var first = try conduit.Pty.open(testing.allocator, .{});
    defer first.close(testing.io);
    var second = try conduit.Pty.open(testing.allocator, .{});
    defer second.close(testing.io);
    var a: Tty = .adopt(first.slaveFile());
    var b: Tty = .adopt(second.slaveFile());
    var r = try Renderer.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer r.deinit();
    defer a.restore();
    defer b.restore();
    try a.enter(testing.io, &r, .{}, .alt, .{ .paste = true });
    try testing.expectError(error.AlreadyEntered, b.enter(testing.io, &r, .{}, .alt, .{ .focus = true }));
    try testing.expect(b.saved == null);
    try testing.expect(r.own_entered.?.modes.paste);
    try testing.expect(!r.own_entered.?.modes.focus);
}

test "restoring one entered terminal leaves the other renderer armed" {
    if (is_windows) return error.SkipZigTest;
    var first = try conduit.Pty.open(testing.allocator, .{});
    defer first.close(testing.io);
    var second = try conduit.Pty.open(testing.allocator, .{});
    defer second.close(testing.io);
    var a: Tty = .adopt(first.slaveFile());
    var b: Tty = .adopt(second.slaveFile());
    var ra = try Renderer.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer ra.deinit();
    var rb = try Renderer.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer rb.deinit();
    defer a.restore();
    defer b.restore();
    try a.enter(testing.io, &ra, .{}, .alt, .{ .paste = true });
    try b.enter(testing.io, &rb, .{}, .alt, .{ .focus = true });
    var seen: [1024]u8 = undefined;
    _ = try readUntil(testing.io, first.readFile(), &seen, "\x1b[?2004h");
    _ = try readUntil(testing.io, second.readFile(), &seen, "\x1b[?1004h");
    a.restore();
    try testing.expect(ra.own_entered == null);
    try testing.expect(rb.own_entered != null);
    const left = try readUntil(testing.io, first.readFile(), &seen, "\x1b[?1049l");
    try testing.expect(std.mem.find(u8, left, "\x1b[?2004l") != null);
    try testing.expect(std.mem.find(u8, left, "\x1b[?1004l") == null);
    restoreGlobal();
    try testing.expect(rb.own_entered == null);
    try testing.expect(b.saved == null);
    const restored = try readUntil(testing.io, second.readFile(), &seen, "\x1b[?1049l");
    try testing.expect(std.mem.find(u8, restored, "\x1b[?1004l") != null);
}

test "panic restoration restores every raw terminal and clears its registration" {
    if (is_windows) return error.SkipZigTest;
    var first = try conduit.Pty.open(testing.allocator, .{});
    defer first.close(testing.io);
    var second = try conduit.Pty.open(testing.allocator, .{});
    defer second.close(testing.io);
    var a: Tty = .adopt(first.slaveFile());
    var b: Tty = .adopt(second.slaveFile());
    defer a.restore();
    defer b.restore();
    try a.raw();
    try b.raw();
    restoreGlobal();
    try testing.expect(a.saved == null);
    try testing.expect(b.saved == null);
}

test "an entered terminal refuses to replace its renderer association" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(pair.slaveFile());
    var r = try Renderer.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer r.deinit();
    defer t.restore();
    try t.enter(testing.io, &r, .{}, .alt, .{ .paste = true });
    try testing.expectError(error.AlreadyEntered, t.enter(testing.io, &r, .{}, .alt, .{ .focus = true }));
    try testing.expect(r.own_entered.?.modes.paste);
    try testing.expect(!r.own_entered.?.modes.focus);
}

test "a failed leave flush still restores the entered modes on the saved terminal" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{});
    defer pair.close(testing.io);
    var t: Tty = .adopt(pair.slaveFile());
    var r = try Renderer.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer r.deinit();
    defer t.restore();
    try t.enter(testing.io, &r, .{}, .alt, .{ .paste = true });
    var seen: [1024]u8 = undefined;
    _ = try readUntil(testing.io, pair.readFile(), &seen, "\x1b[?25l");
    // Fail the buffered writer, while the saved terminal remains usable by
    // the primitive restoration path. Nothing closes the real descriptor.
    const file = t.file;
    t.file.handle = -1;
    defer t.file = file;
    try testing.expectError(error.WriteFailed, t.leave(testing.io));
    try testing.expect(t.saved == null);
    try testing.expect(r.own_entered == null);
    const master = pair.readFile().handle;
    try fcntlSet(master, std.posix.F.SETFL, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const n = std.posix.system.read(master, &seen, seen.len);
    try testing.expect(std.posix.errno(n) == .SUCCESS);
    const count: usize = @intCast(n);
    try testing.expect(std.mem.find(u8, seen[0..count], "\x1b[?2004l") != null);
    try testing.expect(std.mem.find(u8, seen[0..count], "\x1b[?1049l") != null);
}

test "primitive restoration output does not wait for a full descriptor" {
    if (is_windows) return error.SkipZigTest;
    const fds = try pipe();
    defer for (fds) |fd| {
        _ = std.posix.system.close(fd);
    };
    const flags = std.posix.system.fcntl(fds[1], std.posix.F.GETFL, @as(u32, 0));
    try testing.expect(std.posix.errno(flags) == .SUCCESS);
    const nonblock = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    try fcntlSet(fds[1], std.posix.F.SETFL, @as(u32, @intCast(flags)) | nonblock);
    var bytes: [4096]u8 = @splat('x');
    while (true) {
        const rc = std.posix.system.write(fds[1], &bytes, bytes.len);
        if (std.posix.errno(rc) == .SUCCESS) continue;
        try testing.expect(std.posix.errno(rc) == .AGAIN);
        break;
    }
    try fcntlSet(fds[1], std.posix.F.SETFL, @intCast(flags));
    const before = std.posix.system.fcntl(fds[1], std.posix.F.GETFL, @as(u32, 0));
    try testing.expect(std.posix.errno(before) == .SUCCESS);
    var started: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.fd_t, began: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) void {
            began.store(true, .release);
            writeRaw(fd, "restoring");
            finished.store(true, .release);
        }
    }.run, .{ fds[1], &started, &done });
    defer {
        // Release even the unfixed blocking writer before joining it.
        if (!done.load(.acquire)) _ = std.posix.system.read(fds[0], &bytes, bytes.len);
        worker.join();
    }
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    // A writer that does not block finishes at once; one that blocks never
    // does. Up to five seconds tells them apart on a loaded runner.
    var waited: u32 = 0;
    while (!done.load(.acquire) and waited < 500) : (waited += 1) try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    try testing.expect(done.load(.acquire));
    const after = std.posix.system.fcntl(fds[1], std.posix.F.GETFL, @as(u32, 0));
    try testing.expectEqual(before, after);
}
