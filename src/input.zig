//! The terminal's input, read: bytes off the `Tty`, framed by
//! `morse.KeyParser`, and handed back one event at a time.
//!
//! What a program needed and did not have is the pump around the parser:
//! the read, the wait for the rest of a sequence, the lone `ESC` settled on
//! the program's own timeout, and a resize woken out of that wait. This is
//! that pump and nothing more. The events are morse's own, as the parser
//! produces them — keys, text, paste, focus, resizes, colour-scheme reports,
//! the mouse, and every answer to a question read as a typed `reply`: a
//! colour, a size, a mode, a graphics acknowledgement. A program never
//! parses what it is handed a second time, and a value it has to keep is a
//! value, not bytes to copy under a cap. No reply is dropped and there is no
//! second event type to translate into.
//!
//! It starts no thread and keeps no clock. `next` blocks on the caller's
//! `std.Io`, so a program runs it wherever it likes — on its main loop, or
//! as a task in an `Io.Group` feeding a queue — and stops it by cancelling
//! that task: the wait is a cancellation point, so nothing has to be written
//! to the terminal to wake it. `nextWithin` is the same read with the
//! caller's deadline beside it, for a wait that ends on silence — a startup
//! probe's quiet period — with nothing cancelled and nothing lost.
//!
//! What this file will never hold: a thread, a queue, a timer of its own, or
//! a decision about what an event means.

const std = @import("std");
const builtin = @import("builtin");
const morse = @import("morse");

const tty_mod = @import("tty.zig");
const Tty = tty_mod.Tty;

const Io = std.Io;
const is_windows = builtin.os.tag == .windows;

/// The terminal's input, read and framed, one event at a time.
pub const Input = struct {
    /// The terminal read from.
    _tty: *Tty,
    /// The parser, over the caller's buffer.
    _parser: morse.KeyParser,
    /// Where each read lands, the caller's.
    _read_buffer: []u8,
    /// What was read and not yet handed to the parser.
    _fresh: []const u8 = &.{},
    /// How long a lone `ESC` waits for the rest of a sequence before it is
    /// the Escape key.
    _escape: Io.Duration,
    /// The stream ended with this call's events still to hand over.
    _ended: bool = false,
    /// The resize pipe woke a wait, and the size has not been handed over.
    _resize_due: bool = false,

    /// The buffers and the one timeout.
    pub const Options = struct {
        /// Where a sequence is held while the rest of it arrives. At least
        /// `morse.KeyParser.min_buffer`, and as long as the longest reply the
        /// program asks for: a clipboard reply is as long as what was
        /// copied.
        parser_buffer: []u8,
        /// Where each read lands. At least one byte; a larger one reads a paste in
        /// fewer calls.
        read_buffer: []u8,
        /// How long a lone `ESC` — or `ESC [`, or `ESC O` — waits for the
        /// rest of a sequence before it is the key it also is. A terminal
        /// asked for `KittyFlags.disambiguate_escape_codes` spells Escape as
        /// a sequence of its own, and then this is never waited out.
        escape: Io.Duration,
    };

    /// Anything reading can fail with, cancellation included.
    /// `error.EndOfStream` is the terminal gone.
    pub const Error = Io.File.ReadStreamingError;

    /// A reader over `tty`, with the caller's buffers and timeout.
    /// An empty read buffer is refused with `error.EmptyReadBuffer`.
    pub fn init(tty: *Tty, options: Options) error{EmptyReadBuffer}!Input {
        if (options.read_buffer.len == 0) return error.EmptyReadBuffer;
        return .{
            ._tty = tty,
            ._parser = .init(options.parser_buffer),
            ._read_buffer = options.read_buffer,
            ._escape = options.escape,
        };
    }

    /// Whether SGR mouse reports are parsed as pixels, copied from the parser.
    pub fn mousePixels(in: *const Input) bool {
        return in._parser.mouse_pixels;
    }

    /// Match parsing to the encoding requested from the terminal.
    /// Set this alongside enter or setModes, including a partial mode change.
    pub fn setMousePixels(in: *Input, pixels: bool) void {
        in._parser.mouse_pixels = pixels;
    }

    /// The next event, waiting for one as long as it takes.
    ///
    /// Anything the event borrows — `text`, `unhandled`, the bytes a reply
    /// carries — is valid until the next call. Whether SGR mouse reports
    /// are in pixels is `mousePixels()`, which a program that asked
    /// for them sets through `setMousePixels`. A resize, when `Tty.watchResize` is on, comes back as the
    /// same `resize` event an in-band report is, with the size and the
    /// pixels the operating system has now.
    pub fn next(in: *Input) Error!morse.Event {
        return (try in.nextWithin(.none)).?;
    }

    /// The next event, or null when `timeout` passes before one is framed.
    ///
    /// What was read already is handed over first, even past the deadline,
    /// so a deadline that has gone by still empties what is buffered. A lone
    /// `ESC` whose own timeout ends first is the key it also is; one still
    /// waiting at the caller's deadline stays held for the next call. What
    /// the event borrows is valid until the next call, as with `next`.
    pub fn nextWithin(in: *Input, timeout: Io.Timeout) Error!?morse.Event {
        const until = timeout.toDeadline(in._tty.ioContext());
        while (true) {
            // What was read already comes first, including the repeats a
            // console sequence can stand for.
            var events = in._parser.feed(in._fresh);
            const event = events.next();
            in._fresh = events.remainder();
            if (event) |e| return e;

            // Then a resize, asked of the operating system now rather than
            // when the signal came, because another may have followed it.
            if (in._resize_due) {
                in._resize_due = false;
                if (in._tty.size()) |ws| return .{ .resize = .{
                    .rows = ws.cells.rows,
                    .cols = ws.cells.cols,
                    .ypixels = ws.area.height,
                    .xpixels = ws.area.width,
                } } else |_| {}
            }

            if (in._ended) {
                if (in._parser.flush()) |e| return e;
                return error.EndOfStream;
            }

            switch (try in.wait(until)) {
                .bytes => |n| in._fresh = in._read_buffer[0..n],
                .ended => in._ended = true,
                .quiet => if (in._parser.flush()) |e| return e,
                .expired => return null,
                .resized => {},
            }
        }
    }

    /// What one wait came back with.
    const Woke = union(enum) {
        /// Bytes, into the read buffer.
        bytes: usize,
        /// The stream ended.
        ended,
        /// Nothing arrived within the escape timeout.
        quiet,
        /// Nothing arrived before the caller's deadline.
        expired,
        /// The resize pipe, and nothing else.
        resized,
    };

    /// Whether what the parser holds is a key as well as the start of a
    /// sequence, which is the one case the timeout settles.
    fn ambiguous(in: *const Input) bool {
        const held = in._parser.pending();
        if (held.len == 0 or held.len > 2 or held[0] != 0x1b) return false;
        return held.len == 1 or held[1] == '[' or held[1] == 'O';
    }

    /// Waits for the terminal, the resize pipe, the escape timeout or the
    /// caller's deadline, whichever comes first.
    const wait = if (is_windows) waitWindows else waitPosix;

    /// Which timeout a wait runs under: the escape's, while what the parser
    /// holds is ambiguous, or the caller's, whichever ends first. `expires`
    /// says a timeout is the caller's deadline, not the escape's.
    const Limit = struct { timeout: Io.Timeout, expires: bool };

    fn limit(in: *const Input, until: Io.Timeout) Limit {
        const left = until.toDurationFromNow(in._tty.ioContext());
        if (in.ambiguous()) {
            const escape: Io.Clock.Duration = .{ .raw = in._escape, .clock = .awake };
            if (left) |l| if (l.raw.nanoseconds < in._escape.nanoseconds) return .{ .timeout = .{ .duration = l }, .expires = true };
            return .{ .timeout = .{ .duration = escape }, .expires = false };
        }
        const l = left orelse return .{ .timeout = .none, .expires = false };
        return .{ .timeout = .{ .duration = l }, .expires = true };
    }

    /// The console has no resize signal and its handles take no part in a
    /// poll, so the wait is the read -- except for the lone `ESC`, which
    /// waits on the console's input handle for the caller's timeout first.
    /// The handle is signalled by any input record, and a read in terminal
    /// input mode passes over the ones that are not keys (focus, menu,
    /// buffer size), so those are taken off the queue and the wait begun
    /// again rather than left to a read that would block on them.
    fn waitWindows(in: *Input, until: Io.Timeout) Error!Woke {
        const file = in._tty.inputFile();
        while (true) {
            const lim = in.limit(until);
            const left = lim.timeout.toDurationFromNow(in._tty.ioContext()) orelse return in.readBlocking(file);
            const ms: u32 = @intCast(std.math.clamp(left.raw.toMilliseconds(), 0, std.math.maxInt(u32) - 1));
            switch (console.waitInput(file.handle, ms) catch return in.readBlocking(file)) {
                .ready => {},
                .timed_out => return if (lim.expires) .expired else .quiet,
            }
            var records: [16]console.InputRecord = undefined;
            const n = console.peekInput(file.handle, &records) catch return in.readBlocking(file);
            if (keyWaiting(records[0..n])) return in.readBlocking(file);
            // Nothing a read would return: take those records off and wait
            // again. A queue that cannot be drained is left to the read.
            _ = console.readInput(file.handle, records[0..n]) catch return in.readBlocking(file);
        }
    }

    fn waitPosix(in: *Input, until: Io.Timeout) Error!Woke {
        const io = in._tty.ioContext();
        const tty_file = in._tty.inputFile();
        const lim = in.limit(until);
        const timeout = lim.timeout;
        const resize = in._tty.resizeFile();

        if (timeout == .none and resize == null) return in.readBlocking(tty_file);

        var storage: [2]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        batch.addAt(0, .{ .file_read_streaming = .{ .file = tty_file, .data = &.{in._read_buffer} } });
        var sink: [64]u8 = undefined;
        if (resize) |file| batch.addAt(1, .{ .file_read_streaming = .{ .file = file, .data = &.{&sink} } });

        const outcome = batch.awaitConcurrent(io, timeout);
        // Whatever finished is kept, before and after the rest is called off:
        // a read that completed while being cancelled still read bytes.
        var woke: ?Woke = null;
        var failed: ?Error = null;
        in.collect(&batch, &woke, &failed);
        batch.cancel(io);
        in.collect(&batch, &woke, &failed);

        if (woke) |w| return w;
        if (failed) |e| return e;
        if (in._resize_due) return .resized;
        outcome catch |err| switch (err) {
            error.Timeout => return if (lim.expires) .expired else .quiet,
            error.Canceled => return error.Canceled,
            // An `Io` that cannot wait on two things at once still reads.
            error.ConcurrencyUnavailable => return in.readBlocking(tty_file),
        };
        return .quiet;
    }

    /// The completions of one wait, folded into what it woke for. A resize
    /// is remembered rather than returned, so bytes that came with it are
    /// handed over first and the size after them.
    fn collect(in: *Input, batch: *Io.Batch, woke: *?Woke, failed: *?Error) void {
        while (batch.next()) |done| {
            const result = done.result.file_read_streaming;
            if (done.index == 1) {
                // The pipe does not block: whatever this read took, the rest
                // is taken here so the next wait does not wake for it again.
                in._tty.drainResize();
                in._resize_due = true;
                continue;
            }
            if (result) |n| {
                woke.* = if (n == 0) .ended else .{ .bytes = n };
            } else |err| switch (err) {
                error.EndOfStream => woke.* = .ended,
                error.WouldBlock => {},
                else => |e| failed.* = e,
            }
        }
    }

    /// One read with nothing beside it.
    fn readBlocking(in: *Input, file: Io.File) Error!Woke {
        const n = file.readStreaming(in._tty.ioContext(), &.{in._read_buffer}) catch |err| switch (err) {
            error.EndOfStream => return .ended,
            else => |e| return e,
        };
        return if (n == 0) .ended else .{ .bytes = n };
    }
};

/// Whether a console's queued input holds a key going down, which is what a
/// read in terminal input mode returns bytes for.
fn keyWaiting(records: []const console.InputRecord) bool {
    for (records) |r| if (r.keyDown()) return true;
    return false;
}

/// The console's input records and waits are conduit's.
const console = @import("conduit.tty").console;

const testing = std.testing;
const conduit = @import("conduit");
const corpus = @import("corpus");

/// A `Tty` over the read end of a pipe, and the write end to type into.
const Piped = struct {
    tty: Tty,
    write_end: std.posix.fd_t,
    open_write: bool = true,

    fn init() !Piped {
        const fds = try tty_mod.pipe();
        return .{
            .tty = .adopt(testing.io, .{ .handle = fds[0], .flags = .{ .nonblocking = false } }),
            .write_end = fds[1],
        };
    }

    fn deinit(p: *Piped) void {
        p.hangUp();
        p.tty.close();
    }

    fn type_(p: *Piped, bytes: []const u8) void {
        var left = bytes;
        while (left.len > 0) {
            const rc = std.posix.system.write(p.write_end, left.ptr, left.len);
            if (std.posix.errno(rc) != .SUCCESS) return;
            left = left[@intCast(rc)..];
        }
    }

    fn hangUp(p: *Piped) void {
        if (!p.open_write) return;
        _ = std.posix.system.close(p.write_end);
        p.open_write = false;
    }
};

fn inputOver(tty: *Tty, parser: []u8, read: []u8, escape_ms: i64) error{EmptyReadBuffer}!Input {
    return .init(tty, .{
        .parser_buffer = parser,
        .read_buffer = read,
        .escape = .fromMilliseconds(escape_ms),
    });
}

test "input refuses an empty read buffer before reading the terminal" {
    var tty = Tty.adopt(testing.io, .{ .handle = if (is_windows) std.os.windows.INVALID_HANDLE_VALUE else -1, .flags = .{ .nonblocking = false } });
    var parser: [morse.KeyParser.min_buffer]u8 = undefined;
    const result: error{EmptyReadBuffer}!Input = Input.init(&tty, .{
        .parser_buffer = &parser,
        .read_buffer = &.{},
        .escape = .fromMilliseconds(20),
    });
    try testing.expectError(error.EmptyReadBuffer, result);
}

test "input accepts a single byte of read storage" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [morse.KeyParser.min_buffer]u8 = undefined;
    var read: [1]u8 = undefined;
    var in = try Input.init(&p.tty, .{
        .parser_buffer = &parser,
        .read_buffer = &read,
        .escape = .fromMilliseconds(20),
    });
    p.type_("\x1b[A");
    p.hangUp();
    try testing.expectEqual(morse.Key.up, (try in.next()).key.key);
    try testing.expectError(error.EndOfStream, in.next());
}

test "keys, text and replies come through as the parser makes them" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [256]u8 = undefined;
    var read: [64]u8 = undefined;
    var in = try inputOver(&p.tty, &parser, &read, 25);

    p.type_("a\x1b[A\x1b_Gi=5;OK\x1b\\hello\x1b[I");
    p.hangUp();

    const a = try in.next();
    try testing.expectEqual(morse.Key{ .char = 'a' }, a.key.key);
    try testing.expectEqual(morse.Key.up, (try in.next()).key.key);
    // A reply is handed over read.
    const reply = (try in.next()).reply.graphics;
    try testing.expectEqual(@as(?u32, 5), reply.id);
    try testing.expect(reply.ok());
    try testing.expectEqualStrings("hello", (try in.next()).text);
    try testing.expect((try in.next()) == .focus_in);
    try testing.expectError(error.EndOfStream, in.next());
}

test "a lone escape is the Escape key once the caller's timeout has passed" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&p.tty, &parser, &read, 10);

    p.type_("\x1b");
    const e = try in.next();
    try testing.expectEqual(morse.Key.escape, e.key.key);
    // And `ESC [` is alt and a bracket, the other string that is both.
    p.type_("\x1b[");
    const b = try in.next();
    try testing.expectEqual(morse.Key{ .char = '[' }, b.key.key);
    try testing.expect(b.key.mods.alt);
}

test "an escape followed within the timeout is the start of a sequence" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    // A long timeout, and the rest of the sequence well inside it.
    var in = try inputOver(&p.tty, &parser, &read, 5_000);

    p.type_("\x1b");
    const later = try std.Thread.spawn(.{}, struct {
        fn run(pp: *Piped) void {
            std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
            pp.type_("[A");
        }
    }.run, .{&p});
    defer later.join();
    try testing.expectEqual(morse.Key.up, (try in.next()).key.key);
}

test "the end of the stream settles what was pending, then says so" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&p.tty, &parser, &read, 5_000);

    p.type_("x\x1b");
    p.hangUp();
    try testing.expectEqual(morse.Key{ .char = 'x' }, (try in.next()).key.key);
    try testing.expectEqual(morse.Key.escape, (try in.next()).key.key);
    try testing.expectError(error.EndOfStream, in.next());
    try testing.expectError(error.EndOfStream, in.next());
}

test "a read within a deadline hands over what came, and null once the deadline passes in silence" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&p.tty, &parser, &read, 5_000);

    // Nothing typed: the deadline ends the wait, and nothing is lost.
    try testing.expectEqual(null, try in.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake } }));

    // What is typed is handed over, and what is buffered comes first even
    // with a deadline already gone by.
    p.type_("a\x1b[B");
    try testing.expectEqual(morse.Key{ .char = 'a' }, (try in.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(1_000), .clock = .awake } })).?.key.key);
    try testing.expectEqual(morse.Key.down, (try in.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(-1), .clock = .awake } })).?.key.key);

    // A lone escape with a long timeout of its own is still held at a
    // short deadline, and the rest of its sequence makes it the key it
    // starts on the next read.
    p.type_("\x1b");
    try testing.expectEqual(null, try in.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    p.type_("[A");
    try testing.expectEqual(morse.Key.up, (try in.next()).key.key);

    // And one whose own timeout ends first is the Escape key.
    var quick = try inputOver(&p.tty, &parser, &read, 10);
    p.type_("\x1b");
    try testing.expectEqual(morse.Key.escape, (try quick.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(2_000), .clock = .awake } })).?.key.key);
}

test "a resize wakes the wait and carries the size and pixels the system has now" {
    if (is_windows) return error.SkipZigTest;
    var pair = try conduit.Pty.open(testing.allocator, .{ .rows = 30, .cols = 100, .x_pixel = 900, .y_pixel = 600 });
    defer pair.close(testing.io);
    var t: Tty = .adopt(testing.io, pair.slaveFile());
    try t.watchResize();
    defer t.unwatchResize();

    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&t, &parser, &read, 25);

    try std.posix.raise(.WINCH);
    const e = try in.next();
    try testing.expectEqual(morse.Resize{ .rows = 30, .cols = 100, .ypixels = 600, .xpixels = 900 }, e.resize);

    // Several signals before the reader looks are one wake and one event,
    // with the size as it is by then.
    try pair.resize(.{ .rows = 20, .cols = 80, .x_pixel = 720, .y_pixel = 400 });
    try std.posix.raise(.WINCH);
    try std.posix.raise(.WINCH);
    const again = try in.next();
    try testing.expectEqual(@as(u32, 80), again.resize.cols);
    try testing.expectEqual(@as(u32, 720), again.resize.xpixels);
    try testing.expect(!t.resized());

    // For a loop of its own: the same wake, asked without blocking.
    try std.posix.raise(.WINCH);
    try testing.expect(t.resized());
    try testing.expect(!t.resized());
}

test "watching a resize puts back the handler it found" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &before);
    try p.tty.watchResize();
    try testing.expect(p.tty.resizeFile() != null);
    p.tty.unwatchResize();
    try testing.expect(p.tty.resizeFile() == null);
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &after);
    try testing.expectEqual(before.handler.handler, after.handler.handler);
}

test "two terminals watching each hear a resize, and one stopping leaves the other" {
    if (is_windows) return error.SkipZigTest;
    var a: Piped = try .init();
    defer a.deinit();
    var b: Piped = try .init();
    defer b.deinit();
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &before);

    try a.tty.watchResize();
    try b.tty.watchResize();
    try testing.expect(a.tty.resizeFile().?.handle != b.tty.resizeFile().?.handle);
    try std.posix.raise(.WINCH);
    try testing.expect(a.tty.resized());
    try testing.expect(b.tty.resized());

    // The first stops: the second still hears, and the handler stays.
    a.tty.unwatchResize();
    try testing.expect(a.tty.resizeFile() == null);
    try std.posix.raise(.WINCH);
    try testing.expect(!a.tty.resized());
    try testing.expect(b.tty.resized());

    // The last stops: the handler found before the first is back.
    b.tty.unwatchResize();
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &after);
    try testing.expectEqual(before.handler.handler, after.handler.handler);
}

test "cancelling the task that reads stops the wait, with nothing written to wake it" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&p.tty, &parser, &read, 25);

    var task = try testing.io.concurrent(Input.next, .{&in});
    try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, task.cancel(testing.io));

    // The same with a lone escape held, where the wait has a timeout.
    p.type_("\x1b");
    var slow = try inputOver(&p.tty, &parser, &read, 60_000);
    var held = try testing.io.concurrent(Input.next, .{&slow});
    try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, held.cancel(testing.io));
}

//=========================================================================
// The pump loses nothing and adds nothing: whatever the bytes, and however
// the reads cut them, the events are the parser's over the whole stream.
//=========================================================================

/// Pieces a terminal's input is made of, whole and cut short.
const fragments = [_][]const u8{
    "\x1b",                           "[",                  "O",                      "A",
    "a",
    "é",
    "hello",                          "\x1b[A",             "\x1b[97;5u",             "\x1b[200~",
    "\x1b[201~",                      "\x1b[I",             "\x1b[O",                 "\x1b_Gi=7;OK\x1b\\",
    "\x1b]11;rgb:1e1e/1e1e/2e2e\x07", "\x1b[<0;10;5M",      "\x1b[48;24;80;480;720t", "\x1b[?997;1n",
    "\x1b[6;20;9t",                   "\x1bP1+r5463\x1b\\", "\x1b[?2026;1$y",         "\r",
    "\x7f",                           "\x1b\x1b",           "\x1b[1;5",               "\x1b]52;c;",
    "\x1bOP",                         "\x00",
};

/// What a stream of events says, with the one thing the reads may change
/// taken out: where a run of typed text is cut.
fn describe(log: *std.Io.Writer.Allocating, text: *std.Io.Writer.Allocating, event: morse.Event) !void {
    switch (event) {
        .text => |t| return text.writer.writeAll(t),
        .key => |k| if (k.key == .char and !k.mods.any() and k.kind == .press and k.text().len > 0 and
            k.shifted == null and k.base == null)
        {
            return text.writer.writeAll(k.text());
        },
        else => {},
    }
    if (text.written().len > 0) {
        try log.writer.print("T:{s}\n", .{text.written()});
        text.clearRetainingCapacity();
    }
    switch (event) {
        .unhandled => |u| try log.writer.print("U:{s}\n", .{u}),
        .reply => |r| try log.writer.print("Y:{any}\n", .{r}),
        .mouse => |m| try log.writer.print("M:{any}\n", .{m}),
        .key => |k| try log.writer.print("K:{any}\n", .{k}),
        .resize => |r| try log.writer.print("R:{any}\n", .{r}),
        .color_scheme => |c| try log.writer.print("C:{t}\n", .{c}),
        .overflow => |n| try log.writer.print("O:{d}\n", .{n}),
        else => try log.writer.print("E:{t}\n", .{event}),
    }
}

/// What the pump property drew over the corpus, for the test that proves
/// it explores.
const Tally = struct {
    /// How long each stream was, in bytes.
    bytes: corpus.Spread = .{},
    /// Which fragment each piece took; a raw piece is `fragments.len`.
    pieces: corpus.Spread = .{},
    /// How many bytes each read took at most.
    read_len: corpus.Spread = .{},
};

fn pumpMatchesParser(gpa: std.mem.Allocator, smith: *std.testing.Smith, tally: ?*Tally) !void {
    var dice: corpus.Dice = .init(smith);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const count = dice.valueRangeAtMost(u16, 0, 256);
    var piece: u16 = 0;
    while (piece < count and stream.items.len < 2048) : (piece += 1) {
        if (dice.valueRangeAtMost(u8, 0, 7) == 0) {
            var raw: [8]u8 = undefined;
            const n = dice.slice(&raw);
            try stream.appendSlice(gpa, raw[0..n]);
            if (tally) |t| t.pieces.add(fragments.len);
        } else {
            const which = dice.index(fragments.len);
            try stream.appendSlice(gpa, fragments[which]);
            if (tally) |t| t.pieces.add(which);
        }
    }
    const read_len: usize = dice.valueRangeAtMost(u8, 1, 32);
    if (tally) |t| {
        t.bytes.add(stream.items.len);
        t.read_len.add(read_len);
    }

    // The parser over the whole stream, and what is left settled at its end.
    var want_log: std.Io.Writer.Allocating = .init(gpa);
    defer want_log.deinit();
    var want_text: std.Io.Writer.Allocating = .init(gpa);
    defer want_text.deinit();
    {
        var buffer: [128]u8 = undefined;
        var parser: morse.KeyParser = .init(&buffer);
        var events = parser.feed(stream.items);
        while (events.next()) |e| try describe(&want_log, &want_text, e);
        if (parser.flush()) |e| try describe(&want_log, &want_text, e);
    }

    // The same stream through a pipe, read in pieces.
    var got_log: std.Io.Writer.Allocating = .init(gpa);
    defer got_log.deinit();
    var got_text: std.Io.Writer.Allocating = .init(gpa);
    defer got_text.deinit();
    {
        var p: Piped = try .init();
        defer p.deinit();
        p.type_(stream.items);
        p.hangUp();
        var parser: [128]u8 = undefined;
        var read: [32]u8 = undefined;
        var in = try inputOver(&p.tty, &parser, read[0..read_len], 1);
        while (true) {
            const e = in.next() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try describe(&got_log, &got_text, e);
        }
    }
    try describe(&want_log, &want_text, .paste_end);
    try describe(&got_log, &got_text, .paste_end);
    try testing.expectEqualStrings(want_log.written(), got_log.written());
}

test "the pump hands over what the parser makes of the whole stream, however it is read" {
    if (is_windows) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try pumpMatchesParser(gpa, smith, null);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the pump's corpus draws every fragment, raw bytes, every read size and long streams" {
    if (is_windows) return error.SkipZigTest;
    var t: Tally = .{};
    for (corpus.entries) |entry| {
        var smith: std.testing.Smith = .{ .in = entry };
        try pumpMatchesParser(testing.allocator, &smith, &t);
    }
    try testing.expect(t.pieces.covers(0, fragments.len));
    try testing.expect(t.read_len.covers(1, 32));
    try testing.expect(t.bytes.least == 0);
    try testing.expect(t.bytes.most > 1024);
}

test "a console queue with a key going down is one a read returns for, and one with only other records is not" {
    var focus: console.InputRecord = .{ .event_type = 0x0010, .event = .{ .raw = @splat(0) } };
    var up: console.InputRecord = .{ .event_type = console.key_event, .event = .{ .key = .{
        .down = 0,
        .repeat_count = 1,
        .virtual_key = 0x41,
        .scan_code = 0,
        .character = 'a',
        .control_keys = 0,
    } } };
    try testing.expect(!keyWaiting(&.{ focus, up }));
    var down = up;
    down.event.key.down = 1;
    try testing.expect(keyWaiting(&.{ focus, down }));
    try testing.expect(!keyWaiting(&.{}));
    _ = &focus;
    _ = &up;
}

test "the pump is compiled for every target, the Windows wait included" {
    // Every other test here is skipped on Windows before it reaches `next`,
    // so this is what makes the cross-compiled check analyse the wait there.
    _ = &Input.next;
    _ = &Input.nextWithin;
}

test "a silent deadline submits one read and cancels it with the remaining budget" {
    // The Io observes the operations and advances a synthetic clock. It
    // never reads a descriptor or waits on the machine running the test.
    const Clocked = struct {
        ticks: usize = 0,
        waits: usize = 0,
        cancels: usize = 0,
        reads: usize = 0,
        budget: Io.Timeout = .none,

        fn now(ptr: ?*anyopaque, _: Io.Clock) Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            defer self.ticks += 1;
            return .fromNanoseconds(@as(i96, @intCast(self.ticks)) * 10 * std.time.ns_per_ms);
        }
        fn wait(ptr: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.waits += 1;
            self.budget = timeout;
            var index = batch.submitted.head;
            while (index != .none) {
                const submission = batch.storage[index.toIndex()].submission;
                if (submission.operation == .file_read_streaming) self.reads += 1;
                index = submission.node.next;
            }
            return error.Timeout;
        }
        fn cancel(ptr: ?*anyopaque, _: *Io.Batch) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.cancels += 1;
        }
    };
    var clocked: Clocked = .{};
    var vtable = testing.io.vtable.*;
    vtable.now = Clocked.now;
    vtable.batchAwaitConcurrent = Clocked.wait;
    vtable.batchCancel = Clocked.cancel;
    const io: Io = .{ .userdata = &clocked, .vtable = &vtable };
    var tty = Tty.adopt(io, .{ .handle = if (is_windows) std.os.windows.INVALID_HANDLE_VALUE else -1, .flags = .{ .nonblocking = false } });
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = try inputOver(&tty, &parser, &read, 5_000);
    // Exercise the Io wait on every host, including Windows where the
    // real console wait has its own integration tests.
    const until = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(30), .clock = .awake } }).toDeadline(io);
    try testing.expectEqual(Input.Woke.expired, try in.waitPosix(until));
    try testing.expectEqual(@as(usize, 2), clocked.ticks);
    try testing.expectEqual(@as(usize, 1), clocked.waits);
    try testing.expectEqual(@as(usize, 1), clocked.reads);
    try testing.expectEqual(@as(usize, 1), clocked.cancels);
    try testing.expectEqual(@as(i96, 20 * std.time.ns_per_ms), clocked.budget.duration.raw.nanoseconds);
    try testing.expectEqual(Io.Clock.awake, clocked.budget.duration.clock);
}

test "input framing and borrowed buffers stay behind their owner" {
    inline for (.{ "tty", "parser", "read_buffer", "fresh", "escape", "ended", "resize_due" }) |field| {
        try testing.expect(!@hasField(Input, field));
    }
}
