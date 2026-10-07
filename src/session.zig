//! A terminal session as a value: the grid, renderer, size, capabilities,
//! probe and pictures. The caller owns input, output, time and the loop.
const std = @import("std");
const morse = @import("dependencies.zig").morse;
const Screen = @import("screen.zig").Screen;
const render = @import("render.zig");
const Renderer = render.Renderer;
const Caps = @import("caps.zig").Caps;
const layer_mod = @import("layer.zig");
const Layers = layer_mod.Layers;
const winsize = @import("winsize.zig");
const Winsize = winsize.Winsize;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Io = std.Io;

/// A probe's wait budget on the caller's clock. No read, clock or queue is
/// owned here. Hand early input to the application, and fold answers into
/// the session before asking for the next wait.
pub const ProbeWait = struct {
    /// Private: when the whole probe gives up.
    end: Io.Timestamp,
    /// Private: how long after the last answer the probe counts as settled.
    quiet: Io.Duration,

    /// A wait from `now` that gives up after `timeout`, and settles once the
    /// device attributes are in and `quiet` passes with nothing more.
    pub fn init(now: Io.Timestamp, timeout: Io.Duration, quiet: Io.Duration) ProbeWait {
        return .{
            .end = .{ .nanoseconds = now.nanoseconds +| @max(timeout.nanoseconds, 0) },
            .quiet = .{ .nanoseconds = @max(quiet.nanoseconds, 0) },
        };
    }

    /// The next read's budget, or null once complete, quiet after DA1, or
    /// at the overall deadline. DA1 alone does not end the probe.
    pub fn remaining(wait: ProbeWait, probe: *const Caps.Probe, now: Io.Timestamp) ?Io.Duration {
        if (now.nanoseconds >= wait.end.nanoseconds or probe.settled(now, wait.quiet)) return null;
        const until = if (probe.hasAnswered(.device_attributes))
            @min(wait.end.nanoseconds, (probe.lastAnswer() orelse now).nanoseconds +| wait.quiet.nanoseconds)
        else
            wait.end.nanoseconds;
        return .{ .nanoseconds = @max(until -| now.nanoseconds, 0) };
    }
};

/// Coordinates component owners, terminal geometry and capability policy.
/// Drain input through `handle`, call `resize` once, paint `screen()`, then
/// `draw`. Neither this value nor any of its writes flushes output.
pub const Session = struct {
    /// Private: the allocator `init` was given.
    gpa: Allocator,
    /// Private: the grid the program paints.
    own_screen: Screen,
    /// Private: the renderer that writes the grid's changes.
    own_renderer: Renderer,
    /// Private: the size the screen and renderer are at.
    ws: Winsize,
    /// Private: the capability policy in force.
    caps: Caps = .{},
    /// Private: learned policy waiting for the renderer to accept its mode commands.
    pending_caps: ?Caps = null,
    /// Private: the questions put to the terminal and the answers so far.
    own_probe: Caps.Probe,
    /// Private: the pictures and what each frame shows of them.
    own_layers: Layers,
    /// Private: last size of a drained batch, applied by `resize` before painting.
    own_pending: ?Winsize = null,
    /// Private: an in-band report also confirms a size already seen by a signal.
    resize_report: bool = false,

    /// The grid borrowed for painting. Its storage lives until resize or deinit.
    /// Resize this session through resize so both grids follow the same size.
    pub fn screen(s: *Session) *Screen {
        return &s.own_screen;
    }

    /// The renderer borrowed for terminal entry and mode changes.
    /// Keep its address stable while a Tty holds it; the session owns deinit.
    pub fn renderer(s: *Session) *Renderer {
        return &s.own_renderer;
    }

    /// The picture owner borrowed for transmission and frame declarations.
    pub fn layers(s: *Session) *Layers {
        s.own_layers.configureSize(s.ws);
        return &s.own_layers;
    }

    /// Current terminal geometry, by value; reports are applied by resize.
    pub fn windowSize(s: *const Session) Winsize {
        return s.ws;
    }

    /// Current capability policy, by value; change it through setCaps.
    pub fn capabilities(s: *const Session) Caps {
        return s.caps;
    }

    /// Probe progress borrowed read-only; handle folds its answers in.
    pub fn probe(s: *const Session) *const Caps.Probe {
        return &s.own_probe;
    }

    pub const Error = Allocator.Error || Renderer.Error || Renderer.ModesError;

    /// Allocates the screen and renderer at the same size. The probe id
    /// belongs to the caller and must be excluded from its image ids.
    pub fn init(gpa: Allocator, ws: Winsize, questions: morse.Probe) Allocator.Error!Session {
        var grid = try Screen.init(gpa, ws.cells);
        errdefer grid.deinit();
        return .{
            .gpa = gpa,
            .own_layers = .init(gpa),
            .own_screen = grid,
            .own_renderer = try Renderer.init(gpa, ws.cells),
            .ws = ws,
            .own_probe = .init(questions),
        };
    }

    /// Gives memory back. Leave the terminal first when this value entered
    /// it; freeing memory writes nothing.
    pub fn deinit(s: *Session) void {
        s.own_layers.deinit();
        s.own_renderer.deinit();
        s.own_screen.deinit();
        s.* = undefined;
    }

    /// Applies the caller's capability policy, whole.
    /// What the probe learns later is merged into it field by field (see
    /// `handle`), so an override set here outlives a late answer.
    /// Success supersedes pending learned policy; failure keeps it retryable.
    pub fn setCaps(s: *Session, w: *Writer, caps: Caps) Error!bool {
        const changed = !std.meta.eql(s.caps, caps);
        if (s.own_renderer.entered() != null) try s.own_renderer.setCaps(w, caps) else if (changed) s.own_renderer.repaint();
        // A successful explicit policy also supersedes a queued probe change.
        s.pending_caps = null;
        if (!changed) return false;
        s.caps = caps;
        s.own_screen.method = caps.width_method;
        s.own_layers.repaint();
        return true;
    }

    /// Takes a screen and input modes, keeping pixel mouse parsing in step.
    /// Raw mode and restoration are the caller's (`Tty.enter` can do them).
    /// A live or partial entry returns `AlreadyEntered` before parser changes.
    pub fn enter(s: *Session, w: *Writer, parser: *morse.KeyParser, mode: render.Mode, modes: render.Modes) Error!void {
        if (s.own_renderer.entered() != null) return error.AlreadyEntered;
        parser.mouse_pixels = pixelMouse(modes);
        try s.own_renderer.enter(w, s.caps, mode, modes);
    }

    /// Changes modes and the parser's flag together. Pixel reports are
    /// byte-identical to cell reports; the requested encoding decides.
    pub fn setModes(s: *Session, w: *Writer, parser: *morse.KeyParser, modes: render.Modes) Renderer.ModesError!void {
        if (s.own_renderer.entered() == null) return error.NotEntered;
        parser.mouse_pixels = pixelMouse(modes);
        try s.own_renderer.setModes(w, modes);
    }

    fn pixelMouse(modes: render.Modes) bool {
        return if (modes.mouse) |mouse| mouse.encoding == .sgr_pixels else false;
    }

    /// Frees pictures and gives the screen back. Raw mode is the caller's.
    pub fn leave(s: *Session, w: *Writer) Error!void {
        try s.own_layers.deleteAll(w);
        try s.own_renderer.leave(w);
    }

    /// Folds terminal housekeeping in, returning whether another frame is
    /// due. Size reports are coalesced until `resize`; caps and graphics
    /// replies are applied now. Keys, text and application policy stay with
    /// the caller. `now` comes from the caller's clock for the probe.
    /// A probe answer changes only the capabilities it changed in the probe:
    /// every other field of the policy -- whatever the caller set through
    /// `setCaps`, such as `osc8` or a colour guess -- is kept, however late
    /// the answer arrives.
    /// Housekeeping is retained even when capability output fails; the next
    /// event retries that output without replaying the consumed input.
    pub fn handle(s: *Session, w: *Writer, event: morse.Event, now: Io.Timestamp) Error!bool {
        const was = s.own_probe.capabilities();
        s.own_probe.feed(event, now);
        const learned = s.own_probe.capabilities();
        if (!std.meta.eql(was, learned)) s.pending_caps = merged(s.pending_caps orelse s.caps, was, learned);
        // Consume the input before writing: the terminal cannot replay a
        // resize or acknowledgement when capability output needs a retry.
        var redraw = false;
        switch (event) {
            .resize => {
                var next = s.own_pending orelse s.ws;
                _ = next.update(event);
                s.own_pending = next;
                s.resize_report = true;
                redraw = true;
            },
            .reply => |reply| switch (reply) {
                .window_size => |report| {
                    if (report.what == .text_area_cells) {
                        var next = s.own_pending orelse s.ws;
                        _ = next.update(event);
                        s.own_pending = next;
                        s.resize_report = true;
                        redraw = true;
                    } else if (s.own_pending) |*next| redraw = next.update(event) or redraw else redraw = s.ws.update(event) or redraw;
                },
                .graphics => |response| {
                    const held = if (response.id) |id| s.own_layers.image(id) != null else false;
                    s.own_layers.ack(response);
                    redraw = held or redraw;
                },
                else => {},
            },
            else => {},
        }
        const policy_changed = if (s.pending_caps) |caps| try s.setCaps(w, caps) else false;
        return policy_changed or redraw;
    }

    /// `policy` with every field the probe changed from `was` to `learned`
    /// taken from `learned`, and every other field left as the policy has it.
    fn merged(policy: Caps, was: Caps, learned: Caps) Caps {
        var next = policy;
        inline for (@typeInfo(Caps).@"struct".field_names) |name| {
            if (!std.meta.eql(@field(was, name), @field(learned, name)))
                @field(next, name) = @field(learned, name);
        }
        return next;
    }

    /// Applies the last size once, before the caller paints. Both grids
    /// follow it. An unchanged report with in-band resize enabled repaints:
    /// the signal may have drawn before the terminal's own size changed.
    /// Ask the cell's pixel size again after either case, since a font
    /// change also looks like a resize. Returns whether a repaint is due.
    pub fn resize(s: *Session, w: *Writer) Error!bool {
        const next = s.own_pending orelse return false;
        const changed = !std.meta.eql(s.ws.cells, next.cells) or !std.meta.eql(s.ws.area, next.area);
        const confirmed = s.resize_report and s.caps.in_band_resize;
        if (changed) {
            // Reserve the renderer first, then let Screen's atomic resize
            // commit. The remaining storage swap cannot fail, so allocation
            // failure cannot split the two grids or invalidate old borrows.
            var prepared: ?Renderer = if (!std.meta.eql(s.own_renderer.dimensions(), next.cells))
                try render.internal.prepare(s.gpa, next.cells)
            else
                null;
            defer if (prepared) |*r| r.deinit();
            if (!std.meta.eql(s.own_screen.dimensions(), next.cells)) try s.own_screen.resize(next.cells);
            if (prepared) |*r| render.internal.resizePrepared(&s.own_renderer, r);
        }
        if (changed or confirmed) {
            s.own_renderer.repaint();
            s.own_layers.repaint();
            try morse.queryWindowSize(w, .cell_pixels);
        }
        s.ws = next;
        s.own_pending = null;
        s.resize_report = false;
        return changed or confirmed;
    }

    /// Writes one frame, after `resize` and application painting. No flush.
    pub fn draw(s: *Session, w: *Writer) Renderer.Error!Renderer.Stats {
        s.own_layers.configureSize(s.ws);
        return s.own_renderer.draw(w, &s.own_screen, &s.own_layers, s.caps);
    }
};

const testing = std.testing;

test "a session coalesces sizes, resizes both grids, and asks for cell pixels again" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 }, .cell = .{ .width = 9, .height = 20 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try s.handle(&out.writer, .{ .resize = .{ .cols = 10, .rows = 4 } }, ms(0)));
    try testing.expect(try s.handle(&out.writer, .{ .resize = .{ .cols = 12, .rows = 5 } }, ms(1)));
    try testing.expectEqual(@as(u16, 8), s.own_screen.dimensions().cols);
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqual(s.ws.cells, s.own_screen.dimensions());
    try testing.expectEqual(s.ws.cells, s.own_renderer.dimensions());
    try testing.expectEqual(@as(u16, 12), s.ws.cells.cols);
    try testing.expect(!s.ws.cell.known());
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try testing.expect(!try s.resize(&out.writer));
    out.clearRetainingCapacity();
    try testing.expect(try s.handle(&out.writer, .{ .reply = morse.Reply.parse("\x1b[8;6;14t").? }, ms(2)));
    _ = try s.resize(&out.writer);
    try testing.expectEqual(@as(u16, 14), s.own_screen.dimensions().cols);
    try testing.expectEqual(s.own_screen.dimensions(), s.own_renderer.dimensions());
}

test "a session repaints an unchanged in-band size, including pictures" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    s.own_probe.caps.in_band_resize = true;
    s.own_probe.caps.kitty_graphics = true;
    _ = try s.setCaps(&out.writer, s.own_probe.capabilities());
    try s.own_screen.write(0, 0, "x", .{}, .none);
    const layer: layer_mod.Layer = .{ .image = 7, .rect = .{ .cols = 2, .rows = 2 } };
    try s.own_layers.declare(layer);
    _ = try s.draw(&out.writer);
    out.clearRetainingCapacity();
    _ = try s.handle(&out.writer, .{ .resize = .{ .cols = 8, .rows = 3 } }, ms(1));
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try s.own_layers.declare(layer);
    const drawn = try s.draw(&out.writer);
    try testing.expectEqual(@as(u32, 3), drawn.rows);
    try testing.expectEqual(@as(u32, 1), drawn.placements);
}

test "session modes keep pixel mouse parsing in step and caps change without re-entering" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var buffer: [256]u8 = undefined;
    var parser = morse.KeyParser.init(&buffer);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.enter(&out.writer, &parser, .alt, .{});
    try s.setModes(&out.writer, &parser, .{ .mouse = .{ .motion = .drag, .encoding = .sgr_pixels } });
    var events = parser.feed("\x1b[<0;36;51M");
    try testing.expect(events.next().?.mouse.pixels);
    try s.setModes(&out.writer, &parser, .{ .mouse = .{ .motion = .press } });
    events = parser.feed("\x1b[<0;36;51M");
    try testing.expect(!events.next().?.mouse.pixels);
    try s.setModes(&out.writer, &parser, .{});
    try testing.expect(!parser.mouse_pixels);
    out.clearRetainingCapacity();
    try testing.expect(try s.handle(&out.writer, .{ .reply = morse.Reply.parse("\x1b[?2048;2$y").? }, ms(0)));
    try testing.expectEqualStrings("\x1b[?2048h", out.written());
    try testing.expect(s.own_renderer.entered().?.in_band_resize);
    try s.leave(&out.writer);
}

test "a second session entry preserves pixel mouse parsing" {
    for ([_]bool{ false, true }) |partial| {
        var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 4, .rows = 2 } }, .{ .graphics_id = 1 });
        defer s.deinit();
        var buffer: [256]u8 = undefined;
        var parser = morse.KeyParser.init(&buffer);
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const modes: render.Modes = .{ .mouse = .{ .motion = .drag, .encoding = .sgr_pixels }, .paste = true };
        if (partial) {
            var refused: Writer = .fixed(&.{});
            try testing.expectError(error.WriteFailed, s.enter(&refused, &parser, .alt, modes));
        } else try s.enter(&out.writer, &parser, .alt, modes);
        out.clearRetainingCapacity();
        const result = s.enter(&out.writer, &parser, .alt, .{});
        try testing.expect(parser.mouse_pixels);
        try testing.expectError(error.AlreadyEntered, result);
        try testing.expectEqual(@as(usize, 0), out.written().len);
        var events = parser.feed("\x1b[<0;36;51M");
        try testing.expect(events.next().?.mouse.pixels);
        try s.leave(&out.writer);
        try testing.expect(std.mem.find(u8, out.written(), "\x1b[?1016l") != null);
        try testing.expect(std.mem.find(u8, out.written(), "\x1b[?2004l") != null);
    }
}

test "the probe wait keeps DA1 quiet time and the overall deadline on caller time" {
    var probe: Caps.Probe = .init(.{ .graphics_id = 1 });
    const wait = ProbeWait.init(ms(1000), .fromMilliseconds(500), .fromMilliseconds(50));
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(500)), wait.remaining(&probe, ms(1000)));
    probe.feed(.{ .reply = morse.Reply.parse("\x1b[?62c").? }, ms(1010));
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(40)), wait.remaining(&probe, ms(1020)));
    probe.feed(.{ .reply = morse.Reply.parse("\x1b[?2048;2$y").? }, ms(1040));
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(40)), wait.remaining(&probe, ms(1050)));
    try testing.expectEqual(@as(?std.Io.Duration, null), wait.remaining(&probe, ms(1090)));
    probe.answered = .empty;
    try testing.expectEqual(@as(?std.Io.Duration, null), wait.remaining(&probe, ms(1500)));
    probe.answered = .full;
    try testing.expectEqual(@as(?std.Io.Duration, null), wait.remaining(&probe, ms(1000)));
}

test "a failed session resize keeps both grids and their borrowed content together" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var s = try Session.init(gpa, .{ .cells = .{ .cols = 4, .rows = 1 } }, .{ .graphics_id = 1 });
            defer s.deinit();
            s.own_screen.method = .unicode;
            const link = try s.own_screen.link("https://kept.invalid", "id=kept");
            try s.own_screen.write(0, 0, "a\u{301}\u{302}\u{303}", .{}, link);
            var sink: Writer.Discarding = .init(&.{});
            _ = try s.draw(&sink.writer);
            _ = try s.handle(&sink.writer, .{ .resize = .{ .cols = 5, .rows = 2 } }, ms(0));
            const size = s.own_screen.dimensions();
            const generation = s.own_screen.pool_generation;
            const cells = s.own_screen.own_cells;
            const prev = s.own_renderer.prev;
            const borrowed = s.own_screen.textAt(0, 0);
            const pending = s.own_pending;
            _ = s.resize(&sink.writer) catch |err| {
                try testing.expectEqual(size, s.own_screen.dimensions());
                try testing.expectEqual(size, s.own_renderer.dimensions());
                try testing.expectEqual(size, s.ws.cells);
                try testing.expectEqual(generation, s.own_screen.pool_generation);
                try testing.expect(s.own_screen.own_cells.ptr == cells.ptr);
                try testing.expect(s.own_renderer.prev.ptr == prev.ptr);
                try testing.expect(s.own_screen.textAt(0, 0).ptr == borrowed.ptr);
                try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", borrowed);
                try testing.expectEqual(pending, s.own_pending);
                return err;
            };
            try testing.expectEqual(s.own_screen.dimensions(), s.own_renderer.dimensions());
            try testing.expectEqual(s.ws.cells, s.own_screen.dimensions());
            try testing.expectEqualStrings("https://kept.invalid", s.own_screen.target(s.own_screen.readCell(0, 0).?.link).?.uri);
            _ = try s.draw(&sink.writer);
        }
    }.run, .{});
}

test "session allocation and coordinated state stay behind their owner" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 3, .rows = 2 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    try testing.expectEqual(s.windowSize().cells, s.screen().dimensions());
    try testing.expectEqual(s.screen().dimensions(), s.renderer().dimensions());
    var policy = s.capabilities();
    policy.osc8 = true;
    try testing.expect(!s.capabilities().osc8);
    var bytes: [1024]u8 = undefined;
    var out: Writer = .fixed(&bytes);
    _ = try s.setCaps(&out, policy);
    try testing.expect(s.capabilities().osc8);
    try testing.expectEqual(@as(usize, 0), s.layers().images().len);
    try s.probe().write(&out);
}

test "a session retries learned capabilities after failed output" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 2, .rows = 1 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var bytes: [1024]u8 = undefined;
    var out: Writer = .fixed(&bytes);
    try s.renderer().enter(&out, .{}, .alt, .{});
    var refused: Writer = .fixed(&.{});
    const answer: morse.Event = .{ .reply = .{ .mode = .{ .mode = morse.inBandResize.number, .state = .reset } } };
    try testing.expectError(error.WriteFailed, s.handle(&refused, answer, ms(10)));
    try testing.expect(s.probe().capabilities().in_band_resize);
    try testing.expect(!s.capabilities().in_band_resize);
    out.end = 0;
    try testing.expect(try s.handle(&out, .{ .key = .{ .key = .escape } }, ms(11)));
    try testing.expect(s.capabilities().in_band_resize);
    try testing.expectEqualStrings("\x1b[?2048h", out.buffered());
    var policy = s.capabilities();
    policy.osc8 = true;
    _ = try s.setCaps(&out, policy);
    out.end = 0;
    try testing.expect(!try s.handle(&out, .{ .key = .{ .key = .escape } }, ms(12)));
    try testing.expect(s.capabilities().osc8);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "session housekeeping survives failed capability output" {
    const events = [_]morse.Event{
        .{ .resize = .{ .cols = 4, .rows = 3, .xpixels = 40, .ypixels = 60 } },
        .{ .reply = .{ .window_size = .{ .what = .text_area_cells, .width = 4, .height = 3 } } },
        .{ .reply = .{ .window_size = .{ .what = .text_area_pixels, .width = 40, .height = 60 } } },
        .{ .reply = .{ .window_size = .{ .what = .cell_pixels, .width = 10, .height = 20 } } },
        .{ .reply = .{ .graphics = .{ .id = 2, .message = "OK" } } },
    };
    for (events) |event| {
        var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 2, .rows = 1 } }, .{ .graphics_id = 1 });
        defer s.deinit();
        var bytes: [4096]u8 = undefined;
        var out: Writer = .fixed(&bytes);
        try s.renderer().enter(&out, .{}, .alt, .{});
        _ = try s.layers().transmit(&out, 2, &.{ 0, 0, 0, 255 }, .{ .width = 1, .height = 1, .answer = true });
        var refused: Writer = .fixed(&.{});
        const answer: morse.Event = .{ .reply = .{ .mode = .{ .mode = morse.inBandResize.number, .state = .reset } } };
        try testing.expectError(error.WriteFailed, s.handle(&refused, answer, ms(10)));
        try testing.expectError(error.WriteFailed, s.handle(&refused, event, ms(11)));

        // Output recovers on another event; the consumed input is not replayed.
        out.end = 0;
        try testing.expect(try s.handle(&out, .{ .key = .{ .key = .escape } }, ms(12)));
        _ = try s.resize(&out);
        switch (event) {
            .resize => {
                try testing.expectEqual(@as(u16, 4), s.screen().dimensions().cols);
                try testing.expectEqual(@as(u16, 3), s.renderer().dimensions().rows);
                try testing.expectEqual(winsize.Pixels{ .width = 40, .height = 60 }, s.windowSize().area);
            },
            .reply => |reply| switch (reply) {
                .window_size => |report| switch (report.what) {
                    .text_area_cells => try testing.expectEqual(@as(u16, 4), s.screen().dimensions().cols),
                    .text_area_pixels => try testing.expectEqual(winsize.Pixels{ .width = 40, .height = 60 }, s.windowSize().area),
                    .cell_pixels => try testing.expectEqual(winsize.Pixels{ .width = 10, .height = 20 }, s.windowSize().cell),
                    else => unreachable,
                },
                .graphics => try testing.expectEqual(layer_mod.Image.State.ready, s.layers().image(2).?.state),
                else => unreachable,
            },
            else => unreachable,
        }
    }
}

test "session policy can cancel pending learned capabilities at the current value" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 2, .rows = 1 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var bytes: [1024]u8 = undefined;
    var out: Writer = .fixed(&bytes);
    try s.renderer().enter(&out, .{}, .alt, .{});
    var refused: Writer = .fixed(&.{});
    const answer: morse.Event = .{ .reply = .{ .mode = .{ .mode = morse.inBandResize.number, .state = .reset } } };
    try testing.expectError(error.WriteFailed, s.handle(&refused, answer, ms(10)));
    out.end = 0;
    try testing.expect(!try s.setCaps(&out, s.capabilities()));
    try testing.expectEqualStrings("\x1b[?2048l", out.buffered());
    out.end = 0;
    try testing.expect(!try s.handle(&out, .{ .key = .{ .key = .escape } }, ms(11)));
    try testing.expect(!s.renderer().entered().?.caps.in_band_resize);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "a late probe answer keeps the caller's capability overrides" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 2, .rows = 1 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var bytes: [1024]u8 = undefined;
    var out: Writer = .fixed(&bytes);
    var policy = s.capabilities();
    policy.osc8 = true;
    policy.truecolor = true;
    policy.rep = true;
    _ = try s.setCaps(&out, policy);
    const answer: morse.Event = .{ .reply = morse.Reply.parse("\x1b[?2026;1$y").? };
    try testing.expect(try s.handle(&out, answer, ms(5)));
    const caps = s.capabilities();
    try testing.expect(caps.sync);
    try testing.expect(caps.osc8);
    try testing.expect(caps.truecolor);
    try testing.expect(caps.rep);
    // The same answer again changes nothing the probe knows, so the
    // caller's later choice stands; a new answer changes only its field.
    policy = s.capabilities();
    policy.sync = false;
    _ = try s.setCaps(&out, policy);
    try testing.expect(!try s.handle(&out, answer, ms(6)));
    try testing.expect(!s.capabilities().sync);
    try testing.expect(try s.handle(&out, .{ .reply = morse.Reply.parse("\x1b[?2048;2$y").? }, ms(7)));
    try testing.expect(s.capabilities().in_band_resize);
    try testing.expect(!s.capabilities().sync);
    try testing.expect(s.capabilities().osc8);
}

test "a session is small enough to return and hold by value" {
    try testing.expect(@sizeOf(Session) < 4096);
}

/// A test's clock reading, in milliseconds.
fn ms(n: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_ms };
}
