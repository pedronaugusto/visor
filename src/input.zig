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
//! to the terminal to wake it.
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
    tty: *Tty,
    /// The parser, over the caller's buffer.
    parser: morse.KeyParser,
    /// Where each read lands, the caller's.
    read_buffer: []u8,
    /// What was read and not yet handed to the parser.
    fresh: []const u8 = &.{},
    /// How long a lone `ESC` waits for the rest of a sequence before it is
    /// the Escape key.
    escape: Io.Duration,
    /// The stream ended with this call's events still to hand over.
    ended: bool = false,
    /// The resize pipe woke a wait, and the size has not been handed over.
    resize_due: bool = false,

    /// The buffers and the one timeout.
    pub const Options = struct {
        /// Where a sequence is held while the rest of it arrives. At least
        /// `morse.KeyParser.min_buffer`, and as long as the longest reply the
        /// program asks for: a clipboard reply is as long as what was
        /// copied.
        parser_buffer: []u8,
        /// Where each read lands. Any size; a larger one reads a paste in
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
    pub fn init(tty: *Tty, options: Options) Input {
        return .{
            .tty = tty,
            .parser = .init(options.parser_buffer),
            .read_buffer = options.read_buffer,
            .escape = options.escape,
        };
    }

    /// The next event, waiting for one as long as it takes.
    ///
    /// Anything the event borrows — `text`, `unhandled`, the bytes a reply
    /// carries — is valid until the next call. Whether SGR mouse reports
    /// are in pixels is `parser.mouse_pixels`, which a program that asked
    /// for them sets. A resize, when `Tty.watchResize` is on, comes back as the
    /// same `resize` event an in-band report is, with the size and the
    /// pixels the operating system has now.
    pub fn next(in: *Input) Error!morse.Event {
        while (true) {
            // What was read already comes first, including the repeats a
            // console sequence can stand for.
            var events = in.parser.feed(in.fresh);
            const event = events.next();
            in.fresh = events.remainder();
            if (event) |e| return e;

            // Then a resize, asked of the operating system now rather than
            // when the signal came, because another may have followed it.
            if (in.resize_due) {
                in.resize_due = false;
                if (in.tty.size()) |ws| return .{ .resize = .{
                    .rows = ws.cells.rows,
                    .cols = ws.cells.cols,
                    .ypixels = ws.area.height,
                    .xpixels = ws.area.width,
                } } else |_| {}
            }

            if (in.ended) {
                if (in.parser.flush()) |e| return e;
                return error.EndOfStream;
            }

            switch (try in.wait()) {
                .bytes => |n| in.fresh = in.read_buffer[0..n],
                .ended => in.ended = true,
                .quiet => if (in.parser.flush()) |e| return e,
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
        /// The resize pipe, and nothing else.
        resized,
    };

    /// Whether what the parser holds is a key as well as the start of a
    /// sequence, which is the one case the timeout settles.
    fn ambiguous(in: *const Input) bool {
        const held = in.parser.pending();
        if (held.len == 0 or held.len > 2 or held[0] != 0x1b) return false;
        return held.len == 1 or held[1] == '[' or held[1] == 'O';
    }

    /// Waits for the terminal, the resize pipe, or the escape timeout,
    /// whichever comes first.
    const wait = if (is_windows) waitWindows else waitPosix;

    /// The console has no resize signal and its handles take no part in a
    /// poll, so the wait is the read.
    fn waitWindows(in: *Input) Error!Woke {
        return in.readBlocking(in.tty.inputFile());
    }

    fn waitPosix(in: *Input) Error!Woke {
        const io = in.tty.io;
        const tty_file = in.tty.inputFile();
        const timeout: Io.Timeout = if (in.ambiguous())
            .{ .duration = .{ .raw = in.escape, .clock = .awake } }
        else
            .none;
        const resize = in.tty.resizeFile();

        if (timeout == .none and resize == null) return in.readBlocking(tty_file);

        var storage: [2]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        batch.addAt(0, .{ .file_read_streaming = .{ .file = tty_file, .data = &.{in.read_buffer} } });
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
        if (in.resize_due) return .resized;
        outcome catch |err| switch (err) {
            error.Timeout => return .quiet,
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
                _ = tty_mod.drainResizePipe();
                in.resize_due = true;
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
        const n = file.readStreaming(in.tty.io, &.{in.read_buffer}) catch |err| switch (err) {
            error.EndOfStream => return .ended,
            else => |e| return e,
        };
        return if (n == 0) .ended else .{ .bytes = n };
    }
};

const testing = std.testing;
const testing_pty = tty_mod.testing_pty;
const corpus = @import("corpus");

/// A `Tty` over the read end of a pipe, and the write end to type into.
const Piped = struct {
    tty: Tty,
    write_end: std.posix.fd_t,
    open_write: bool = true,

    fn init() !Piped {
        const fds = try testing_pty.pipe();
        return .{
            .tty = .adopt(testing.io, .{ .handle = fds[0], .flags = .{ .nonblocking = false } }),
            .write_end = fds[1],
        };
    }

    fn deinit(p: *Piped) void {
        p.hangUp();
        _ = std.posix.system.close(p.tty.file.handle);
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

fn inputOver(tty: *Tty, parser: []u8, read: []u8, escape_ms: i64) Input {
    return .init(tty, .{
        .parser_buffer = parser,
        .read_buffer = read,
        .escape = .fromMilliseconds(escape_ms),
    });
}

test "keys, text and replies come through as the parser makes them" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [256]u8 = undefined;
    var read: [64]u8 = undefined;
    var in = inputOver(&p.tty, &parser, &read, 25);

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
    var in = inputOver(&p.tty, &parser, &read, 10);

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
    var in = inputOver(&p.tty, &parser, &read, 5_000);

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
    var in = inputOver(&p.tty, &parser, &read, 5_000);

    p.type_("x\x1b");
    p.hangUp();
    try testing.expectEqual(morse.Key{ .char = 'x' }, (try in.next()).key.key);
    try testing.expectEqual(morse.Key.escape, (try in.next()).key.key);
    try testing.expectError(error.EndOfStream, in.next());
    try testing.expectError(error.EndOfStream, in.next());
}

test "a resize wakes the wait and carries the size and pixels the system has now" {
    if (is_windows) return error.SkipZigTest;
    var pair = try testing_pty.open(testing.io);
    defer pair.close();
    try pair.setSize(.{ .row = 30, .col = 100, .xpixel = 900, .ypixel = 600 });
    var t: Tty = .adopt(testing.io, pair.slave);
    try t.watchResize();
    defer t.unwatchResize();

    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = inputOver(&t, &parser, &read, 25);

    try std.posix.raise(.WINCH);
    const e = try in.next();
    try testing.expectEqual(morse.Resize{ .rows = 30, .cols = 100, .ypixels = 600, .xpixels = 900 }, e.resize);

    // Several signals before the reader looks are one wake and one event,
    // with the size as it is by then.
    try pair.setSize(.{ .row = 20, .col = 80, .xpixel = 720, .ypixel = 400 });
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

test "cancelling the task that reads stops the wait, with nothing written to wake it" {
    if (is_windows) return error.SkipZigTest;
    var p: Piped = try .init();
    defer p.deinit();
    var parser: [64]u8 = undefined;
    var read: [16]u8 = undefined;
    var in = inputOver(&p.tty, &parser, &read, 25);

    var task = try testing.io.concurrent(Input.next, .{&in});
    try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, task.cancel(testing.io));

    // The same with a lone escape held, where the wait has a timeout.
    p.type_("\x1b");
    var slow = inputOver(&p.tty, &parser, &read, 60_000);
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
        var in = inputOver(&p.tty, &parser, read[0..read_len], 1);
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
