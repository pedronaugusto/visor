//! A live audio scope: sound on standard input, drawn as a waveform, as one
//! channel against the other, or as a spectrum.
//!
//!     ffmpeg -loglevel quiet -i song.flac -f s16le -ac 2 -ar 48000 - | zig build scope
//!     sox -q -d -t raw -b 16 -e signed -c 2 -r 48000 - | zig build scope
//!
//! The second line is the microphone. The sound is 16-bit little-endian
//! stereo at 48 kHz; the screen is the controlling terminal, so standard input
//! is free to carry it. The frame is laid out with `visor.widgets` and drawn
//! as often as the sound moves, and the renderer sends only the cells that
//! changed.
//!
//! `zig build examples` runs it with `--check`: no terminal and no sound, a
//! generated chirp drawn in each view and read back through the emulator.

const std = @import("std");
const visor = @import("visor");
const widgets = @import("visor.widgets");

const rate = 48_000;

/// Samples kept for drawing: a little over 170 ms, enough for the longest
/// time window and the spectrum's transform.
const history = 8192;

/// The transform's length, and so the spectrum's resolution: 23 Hz a bin.
const fft_len = 2048;

const Frame = struct { left: f32, right: f32 };

/// The newest samples, written by the task reading standard input and copied
/// out whole by the one drawing.
const Ring = struct {
    mutex: std.Io.Mutex = .init,
    frames: [history]Frame = @splat(.{ .left = 0, .right = 0 }),
    next: usize = 0,
    /// How many frames have arrived in all, which is how the drawing side
    /// tells a new frame from the one it drew.
    total: u64 = 0,
    ended: bool = false,

    fn push(r: *Ring, io: std.Io, new: []const Frame) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (new) |f| {
            r.frames[r.next] = f;
            r.next = (r.next + 1) % history;
        }
        r.total += new.len;
    }

    /// The last `history` frames, oldest first, and the running total.
    fn copy(r: *Ring, io: std.Io, out: *[history]Frame) struct { total: u64, ended: bool } {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        @memcpy(out[0 .. history - r.next], r.frames[r.next..]);
        @memcpy(out[history - r.next ..], r.frames[0..r.next]);
        return .{ .total = r.total, .ended = r.ended };
    }
};

fn readSound(io: std.Io, ring: *Ring) void {
    defer {
        ring.mutex.lockUncancelable(io);
        ring.ended = true;
        ring.mutex.unlock(io);
    }
    var buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    var bytes: [4 * 512]u8 = undefined;
    var frames: [512]Frame = undefined;
    while (true) {
        // Whole frames only: a read that stops mid-frame is finished by the
        // next one.
        reader.interface.readSliceAll(&bytes) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return,
        };
        for (&frames, 0..) |*f, i| {
            const at = bytes[i * 4 ..][0..4];
            f.* = .{
                .left = @as(f32, @floatFromInt(std.mem.readInt(i16, at[0..2], .little))) / 32768,
                .right = @as(f32, @floatFromInt(std.mem.readInt(i16, at[2..4], .little))) / 32768,
            };
        }
        ring.push(io, &frames);
    }
}

const View = enum { wave, vector, spectrum };

/// Everything the keys change. The drawing reads it and never writes it.
const Settings = struct {
    view: View = .wave,
    /// How much of the sound the waveform spans, in milliseconds.
    window_ms: u16 = 20,
    /// How far the signal is scaled up before it is drawn.
    gain: f32 = 1,
    marker: widgets.Marker = .braille,
    /// Held: the picture stops moving while the sound goes on.
    frozen: bool = false,

    const windows = [_]u16{ 5, 10, 20, 50, 100, 170 };

    fn longer(s: *Settings, by: i8) void {
        const at = std.mem.indexOfScalar(u16, &windows, s.window_ms) orelse 2;
        const to: isize = std.math.clamp(@as(isize, @intCast(at)) + by, 0, windows.len - 1);
        s.window_ms = windows[@intCast(to)];
    }

    fn nextMarker(s: *Settings) void {
        s.marker = switch (s.marker) {
            .braille => .sextant,
            .sextant => .half_block,
            .half_block => .block,
            else => .braille,
        };
    }
};

/// The spectrum's transform, worked in place. Held outside the frame so a
/// frame allocates nothing.
const Scratch = struct {
    re: [fft_len]f32 = undefined,
    im: [fft_len]f32 = undefined,
};

const cyan: visor.Color = .rgb(0x5f, 0xd7, 0xd7);
const pink: visor.Color = .rgb(0xff, 0x87, 0xaf);
const dim: visor.Style = .{ .dim = true };

/// One frame of the whole screen.
fn draw(win: visor.Window, s: Settings, frames: *const [history]Frame, scratch: *Scratch) !void {
    win.clear();
    const rows = (widgets.Layout.vertical(&.{
        .{ .fixed = 1 },
        .{ .fill = 1 },
        .{ .fixed = 1 },
    })).splitFixed(3, .fromSize(win.size()));

    try drawHeader(child(win, rows[0]), s);

    const plot = try (widgets.Block{
        .borders = .all,
        .glyphs = .rounded,
        .border_style = dim,
        .title_bottom = .{ .text = footnote(s), .style = dim, .where = .right },
        .padding = .horizontal(1),
    }).draw(child(win, rows[1]));
    switch (s.view) {
        .wave => try drawWave(plot, s, frames),
        .vector => try drawVector(plot, s, frames),
        .spectrum => try drawSpectrum(plot, s, frames, scratch),
    }

    try (widgets.Keys{
        .keys = &.{
            .{ .key = "1 2 3", .label = "view" },
            .{ .key = "\u{2190}\u{2192}", .label = "time" },
            .{ .key = "\u{2191}\u{2193}", .label = "gain" },
            .{ .key = "m", .label = "marks" },
            .{ .key = "space", .label = "hold" },
            .{ .key = "q", .label = "quit" },
        },
        .key_style = .{ .fg = cyan, .bold = true },
        .label_style = dim,
        .where = .left,
    }).draw(child(win, rows[2]));
}

fn drawHeader(win: visor.Window, s: Settings) !void {
    const tabs: widgets.Tabs = .{
        .titles = &.{ "waveform", "vector", "spectrum" },
        .selected = @intFromEnum(s.view),
        .selected_style = .{ .fg = cyan, .bold = true, .reverse = true },
    };
    var status_buffer: [64]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{s}gain {d:.1}\u{00d7}", .{
        if (s.frozen) "held  " else "",
        s.gain,
    }) catch unreachable;
    const parts = (widgets.Layout.horizontal(&.{
        .{ .fixed = tabs.width(win.screen.method) },
        .{ .fill = 1 },
    })).splitFixed(2, .fromSize(win.size()));
    try tabs.draw(child(win, parts[0]));
    try (widgets.Paragraph{
        .lines = &.{.{ .text = status, .style = dim }},
        .where = .right,
    }).draw(child(win, parts[1]));
}

fn footnote(s: Settings) []const u8 {
    return switch (s.view) {
        .wave => switch (s.window_ms) {
            5 => " 5 ms ",
            10 => " 10 ms ",
            20 => " 20 ms ",
            50 => " 50 ms ",
            100 => " 100 ms ",
            else => " 170 ms ",
        },
        .vector => " left \u{2194}  right \u{2195} ",
        .spectrum => " 20 Hz \u{2192} 20 kHz, log ",
    };
}

/// Both channels over time, the left over the right, starting where the left
/// crosses zero going up so a steady tone stands still.
fn drawWave(win: visor.Window, s: Settings, frames: *const [history]Frame) !void {
    const span: usize = @as(usize, s.window_ms) * rate / 1000;
    const start = trigger(frames, span);
    const p = (widgets.Canvas{
        .x_bounds = .{ 0, 1 },
        .y_bounds = .{ -1, 1 },
        .marker = s.marker,
    }).painter(win);
    try p.line(0, 0, 1, 0, dim);
    // One point for each mark across, each the sample under it.
    const across = @as(usize, win.cols()) * s.marker.across();
    if (across < 2) return;
    var previous: ?Frame = null;
    for (0..across) |i| {
        const f = frames[start + i * span / across];
        const now: Frame = .{
            .left = std.math.clamp(f.left * s.gain, -1, 1),
            .right = std.math.clamp(f.right * s.gain, -1, 1),
        };
        if (previous) |o| {
            const x0 = @as(f64, @floatFromInt(i - 1)) / @as(f64, @floatFromInt(across - 1));
            const x1 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(across - 1));
            try p.line(x0, o.right, x1, now.right, .{ .fg = pink });
            try p.line(x0, o.left, x1, now.left, .{ .fg = cyan });
        }
        previous = now;
    }
}

/// Where the drawn span starts: the last rising zero crossing of the left
/// channel that leaves a whole span after it, or the newest span when there is
/// none.
fn trigger(frames: *const [history]Frame, span: usize) usize {
    const newest = history - span;
    var i = newest;
    while (i > newest -| span and i > 0) : (i -= 1) {
        if (frames[i - 1].left < 0 and frames[i].left >= 0) return i;
    }
    return newest;
}

/// The left channel across, the right up: a mono sound is a diagonal line and
/// a wide one fills the square.
fn drawVector(win: visor.Window, s: Settings, frames: *const [history]Frame) !void {
    // A cell is about twice as tall as it is wide, so a square is twice as many
    // columns as rows.
    const side = @min(win.rows(), win.cols() / 2);
    const square = widgets.place(.fromSize(win.size()), .{ .cols = side * 2, .rows = side }, .center, .center);
    const p = (widgets.Canvas{
        .x_bounds = .{ -1, 1 },
        .y_bounds = .{ -1, 1 },
        .marker = s.marker,
    }).painter(child(win, square));
    try p.line(-1, 0, 1, 0, dim);
    try p.line(0, -1, 0, 1, dim);
    const span: usize = @as(usize, s.window_ms) * rate / 1000;
    var previous: ?Frame = null;
    for (frames[history - span ..]) |f| {
        const x = std.math.clamp(f.left * s.gain, -1, 1);
        const y = std.math.clamp(f.right * s.gain, -1, 1);
        if (previous) |o| try p.line(o.left, o.right, x, y, .{ .fg = cyan });
        previous = .{ .left = x, .right = y };
    }
}

/// The newest `fft_len` samples, both channels mixed, as bars from 20 Hz to
/// 20 kHz on a log scale, 90 dB tall.
fn drawSpectrum(win: visor.Window, s: Settings, frames: *const [history]Frame, scratch: *Scratch) !void {
    for (frames[history - fft_len ..], 0..) |f, i| {
        // A Hann window, so a tone between two bins does not spread over all
        // of them.
        const hann = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / (fft_len - 1));
        scratch.re[i] = (f.left + f.right) * 0.5 * s.gain * hann;
        scratch.im[i] = 0;
    }
    fft(&scratch.re, &scratch.im);

    const p = (widgets.Canvas{
        .x_bounds = .{ 0, 1 },
        .y_bounds = .{ -90, 0 },
        .marker = s.marker,
    }).painter(win);
    const across = @as(usize, win.cols()) * s.marker.across();
    if (across == 0) return;
    const low = @log(20.0);
    const high = @log(20_000.0);
    for (0..across) |column| {
        // The column's share of the octaves, and the bins it covers.
        const a = @exp(low + (high - low) * @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(across)));
        const b = @exp(low + (high - low) * @as(f32, @floatFromInt(column + 1)) / @as(f32, @floatFromInt(across)));
        const first: usize = @intFromFloat(a * fft_len / rate);
        const last: usize = @max(first + 1, @as(usize, @intFromFloat(b * fft_len / rate)));
        var peak: f32 = 0;
        for (first..@min(last, fft_len / 2)) |bin| {
            peak = @max(peak, @sqrt(scratch.re[bin] * scratch.re[bin] + scratch.im[bin] * scratch.im[bin]));
        }
        // Full scale for a sine through a Hann window is a quarter of the
        // transform's length.
        const db = 20 * @log10(@max(peak / (fft_len / 4), 1e-9));
        const x = (@as(f64, @floatFromInt(column)) + 0.5) / @as(f64, @floatFromInt(across));
        if (db <= -90) continue;
        const top: f64 = @min(db, 0);
        const shade: visor.Color = if (top > -12) pink else cyan;
        try p.line(x, -90, x, top, .{ .fg = shade });
    }
}

/// An iterative radix-2 transform, in place.
fn fft(re: *[fft_len]f32, im: *[fft_len]f32) void {
    const bits = std.math.log2_int(usize, fft_len);
    for (0..fft_len) |i| {
        const j = @bitReverse(@as(u11, @intCast(i))) >> @intCast(@bitSizeOf(u11) - bits);
        if (j > i) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    var size: usize = 2;
    while (size <= fft_len) : (size *= 2) {
        const step = -2 * std.math.pi / @as(f32, @floatFromInt(size));
        var start: usize = 0;
        while (start < fft_len) : (start += size) {
            for (0..size / 2) |k| {
                const angle = step * @as(f32, @floatFromInt(k));
                const wr = @cos(angle);
                const wi = @sin(angle);
                const a = start + k;
                const b = a + size / 2;
                const tr = wr * re[b] - wi * im[b];
                const ti = wr * im[b] + wi * re[b];
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}

fn child(win: visor.Window, rect: visor.Rect) visor.Window {
    return win.child(.{ .col = rect.col, .row = rect.row, .cols = rect.cols, .rows = rect.rows });
}

/// What a key does to the settings; true when it asks to quit.
fn onKey(s: *Settings, event: visor.morse.Event) bool {
    const key = switch (event) {
        .key => |k| k,
        else => return false,
    };
    if (key.kind == .release) return false;
    switch (key.key) {
        .escape => return true,
        .left => s.longer(-1),
        .right => s.longer(1),
        .up => s.gain = @min(s.gain * 1.25, 64),
        .down => s.gain = @max(s.gain / 1.25, 0.125),
        .char => |c| switch (c) {
            'q' => return true,
            'c' => return key.mods.ctrl,
            '1' => s.view = .wave,
            '2' => s.view = .vector,
            '3' => s.view = .spectrum,
            'm' => s.nextMarker(),
            ' ' => s.frozen = !s.frozen,
            else => {},
        },
        else => {},
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    if (args.next()) |arg| if (std.mem.eql(u8, arg, "--check")) return check(gpa);

    var ring: Ring = .{};
    var reading = try io.concurrent(readSound, .{ io, &ring });
    defer reading.cancel(io);

    var tty: visor.Tty = try .open(io);
    defer tty.close();
    try tty.watchResize();
    defer tty.unwatchResize();

    var size = (try tty.size()).cells;
    var screen: visor.Screen = try .init(gpa, size);
    defer screen.deinit(gpa);
    var renderer: visor.Renderer = try .init(gpa, size);
    defer renderer.deinit(gpa);

    var parser_buffer: [4096]u8 = undefined;
    var read_buffer: [4096]u8 = undefined;
    var input: visor.Input = .init(&tty, .{
        .parser_buffer = &parser_buffer,
        .read_buffer = &read_buffer,
        .escape = .fromMilliseconds(25),
    });

    // Ask the terminal what it can do, and wait for the answers or a quiet
    // quarter of a second, before taking the screen.
    var probe: visor.Caps.Probe = .{ .questions = .{ .graphics_id = 0x7fff_fff0 } };
    {
        var buffer: [512]u8 = undefined;
        var out = tty.writer(&buffer);
        try probe.write(&out.interface);
        try out.interface.flush();
    }
    const asked = std.Io.Clock.awake.now(io);
    while (!probe.complete()) {
        const waited: i64 = @intCast(asked.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());
        if (probe.settled(waited, 250) or waited > 1000) break;
        const event = try input.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) orelse continue;
        probe.feed(event, waited);
    }
    const caps = probe.caps;
    screen.method = caps.width_method;

    try tty.enter(&renderer, caps, .alt, .{});
    defer tty.leave(&renderer) catch {};

    var settings: Settings = .{};
    var frames: [history]Frame = undefined;
    var scratch: Scratch = .{};
    var drawn_total: u64 = std.math.maxInt(u64);
    var dirty = true;
    var out_buffer: [64 * 1024]u8 = undefined;

    while (true) {
        if (!settings.frozen) {
            const now = ring.copy(io, &frames);
            if (now.total != drawn_total) {
                drawn_total = now.total;
                dirty = true;
            }
        }
        if (dirty) {
            try draw(screen.window(), settings, &frames, &scratch);
            var out = tty.writer(&out_buffer);
            _ = try renderer.draw(&out.interface, &screen, null, caps);
            try out.interface.flush();
            dirty = false;
        }
        // A frame's worth of waiting at 60 frames a second, woken early by a
        // key or a resize.
        const event = try input.nextWithin(.{ .duration = .{ .raw = .fromMilliseconds(16), .clock = .awake } }) orelse continue;
        switch (event) {
            .resize => {
                size = (try tty.size()).cells;
                try screen.resize(gpa, size);
                try renderer.resize(gpa, size);
                dirty = true;
            },
            else => {
                if (onKey(&settings, event)) return;
                dirty = true;
            },
        }
    }
}

/// Every view of a generated chirp, drawn at 80 by 24, rendered, read back by
/// the emulator and compared cell by cell; then drawn again, which must write
/// nothing.
fn check(gpa: std.mem.Allocator) !void {
    var frames: [history]Frame = undefined;
    for (&frames, 0..) |*f, i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        const phase = 2 * std.math.pi * (220 * t + 2000 * t * t);
        f.* = .{ .left = 0.8 * @sin(phase), .right = 0.8 * @sin(phase + 0.9) };
    }
    const size: visor.Size = .{ .cols = 80, .rows = 24 };
    const caps: visor.Caps = .{ .width_method = .unicode, .truecolor = true };
    var scratch: Scratch = .{};
    inline for (.{ View.wave, View.vector, View.spectrum }) |view| {
        inline for (.{ widgets.Marker.braille, widgets.Marker.sextant }) |marker| {
            var screen: visor.Screen = try .init(gpa, size);
            defer screen.deinit(gpa);
            screen.method = caps.width_method;
            var renderer: visor.Renderer = try .init(gpa, size);
            defer renderer.deinit(gpa);

            try draw(screen.window(), .{ .view = view, .marker = marker }, &frames, &scratch);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const stats = try renderer.draw(&out.writer, &screen, null, caps);

            var term: visor.Term = try .init(gpa, size);
            defer term.deinit();
            term.setMethod(caps.width_method);
            try term.feed(out.written());
            try visor.expectScreensEqual(&screen, term.screen());

            var again: std.Io.Writer.Allocating = .init(gpa);
            defer again.deinit();
            std.debug.assert((try renderer.draw(&again.writer, &screen, null, caps)).bytes == 0);

            if (marker == .braille) {
                var text: std.Io.Writer.Allocating = .init(gpa);
                defer text.deinit();
                try visor.dumpScreen(term.screen(), &text.writer);
                std.debug.print("{s}\n{s}: {d} bytes\n\n", .{ text.written(), @tagName(view), stats.bytes });
            }
        }
    }
}
