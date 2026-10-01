//! A terminal session as a value: the grid, renderer, size, capabilities,
//! probe and pictures. The caller owns input, output, time and the loop.
const std = @import("std");
const morse = @import("morse");
const Screen = @import("screen.zig").Screen;
const render = @import("render.zig");
const Renderer = render.Renderer;
const Caps = @import("caps.zig").Caps;
const Layers = @import("layer.zig").Layers;
const Winsize = @import("winsize.zig").Winsize;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// A probe's wait budget on the caller's clock, in milliseconds. No read,
/// clock or queue is owned here. Hand early input to the application, and
/// fold answers into the session before asking for the next wait.
pub const ProbeWait = struct {
    end_ms: i64,
    quiet_ms: i64,

    pub fn init(now_ms: i64, timeout_ms: i64, quiet_ms: i64) ProbeWait {
        return .{ .end_ms = now_ms +| @max(timeout_ms, 0), .quiet_ms = @max(quiet_ms, 0) };
    }

    /// The next read's budget, or null once complete, quiet after DA1, or
    /// at the overall deadline. DA1 alone does not end the probe.
    pub fn remaining(wait: ProbeWait, probe: *const Caps.Probe, now_ms: i64) ?i64 {
        if (now_ms >= wait.end_ms or probe.settled(now_ms, wait.quiet_ms)) return null;
        const until = if (probe.answered.contains(.device_attributes))
            @min(wait.end_ms, (probe.last_ms orelse now_ms) +| wait.quiet_ms)
        else
            wait.end_ms;
        return @max(until -| now_ms, 0);
    }
};

/// Convenience around independent values the caller may use directly.
/// Drain input through `handle`, call `resize` once, paint `screen`, then
/// `draw`. Neither this value nor any of its writes flushes output.
pub const Session = struct {
    _gpa: Allocator,
    _screen: Screen,
    _renderer: Renderer,
    _ws: Winsize,
    _caps: Caps = .{},
    _probe: Caps.Probe,
    _layers: Layers,
    /// Last size of a drained batch, applied by `resize` before painting.
    _pending: ?Winsize = null,
    /// An in-band report also confirms a size already seen by a signal.
    _resize_report: bool = false,

    /// The grid borrowed for painting. Its storage lives until resize or deinit.
    /// Resize this session through resize so both grids follow the same size.
    pub fn screen(s: *Session) *Screen {
        return &s._screen;
    }

    /// The renderer borrowed for terminal entry and mode changes.
    /// Keep its address stable while a Tty holds it; the session owns deinit.
    pub fn renderer(s: *Session) *Renderer {
        return &s._renderer;
    }

    /// The picture owner borrowed for transmission and frame declarations.
    pub fn layers(s: *Session) *Layers {
        return &s._layers;
    }

    /// Current terminal geometry, by value; reports are applied by resize.
    pub fn windowSize(s: *const Session) Winsize {
        return s._ws;
    }

    /// Current capability policy, by value; change it through setCaps.
    pub fn capabilities(s: *const Session) Caps {
        return s._caps;
    }

    /// Probe progress borrowed read-only; handle folds its answers in.
    pub fn probe(s: *const Session) *const Caps.Probe {
        return &s._probe;
    }

    pub const Error = Allocator.Error || render.Error || Renderer.ModesError;

    /// Allocates the screen and renderer at the same size. The probe id
    /// belongs to the caller and must be excluded from its image ids.
    pub fn init(gpa: Allocator, ws: Winsize, questions: morse.Probe) Allocator.Error!Session {
        var grid = try Screen.init(gpa, ws.cells);
        errdefer grid.deinit();
        return .{
            ._gpa = gpa,
            ._layers = .init(gpa),
            ._screen = grid,
            ._renderer = try Renderer.init(gpa, ws.cells),
            ._ws = ws,
            ._probe = .{ .questions = questions },
        };
    }

    /// Gives memory back. Leave the terminal first when this value entered
    /// it; freeing memory writes nothing.
    pub fn deinit(s: *Session) void {
        s._layers.deinit();
        s._renderer.deinit();
        s._screen.deinit();
        s.* = undefined;
    }

    /// Applies caller-selected caps as well as the probe's learned ones.
    /// An application can call this after `handle` to apply its own policy.
    pub fn setCaps(s: *Session, w: *Writer, caps: Caps) Error!bool {
        if (std.meta.eql(s._caps, caps)) return false;
        if (s._renderer.entered() != null) try s._renderer.setCaps(w, caps) else s._renderer.repaint();
        s._caps = caps;
        s._screen.method = caps.width_method;
        s._layers.repaint();
        return true;
    }

    /// Takes a screen and input modes, keeping pixel mouse parsing in step.
    /// Raw mode and restoration are the caller's (`Tty.enter` can do them).
    pub fn enter(s: *Session, w: *Writer, parser: *morse.KeyParser, mode: render.Mode, modes: render.Modes) Error!void {
        parser.mouse_pixels = pixelMouse(modes);
        try s._renderer.enter(w, s._caps, mode, modes);
    }

    /// Changes modes and the parser's flag together. Pixel reports are
    /// byte-identical to cell reports; the requested encoding decides.
    pub fn setModes(s: *Session, w: *Writer, parser: *morse.KeyParser, modes: render.Modes) Renderer.ModesError!void {
        if (s._renderer.entered() == null) return error.NotEntered;
        parser.mouse_pixels = pixelMouse(modes);
        try s._renderer.setModes(w, modes);
    }

    fn pixelMouse(modes: render.Modes) bool {
        return if (modes.mouse) |mouse| mouse.encoding == .sgr_pixels else false;
    }

    /// Frees pictures and gives the screen back. Raw mode is the caller's.
    pub fn leave(s: *Session, w: *Writer) Error!void {
        try s._layers.freeAll(w);
        try s._renderer.leave(w);
    }

    /// Folds terminal housekeeping in, returning whether another frame is
    /// due. Size reports are coalesced until `resize`; caps and graphics
    /// replies are applied now. Keys, text and application policy stay with
    /// the caller. `now_ms` comes from the caller's clock for the probe.
    pub fn handle(s: *Session, w: *Writer, event: morse.Event, now_ms: i64) Error!bool {
        const was = s._probe.caps;
        s._probe.feed(event, now_ms);
        var redraw = if (!std.meta.eql(was, s._probe.caps)) try s.setCaps(w, s._probe.caps) else false;
        switch (event) {
            .resize => {
                var next = s._pending orelse s._ws;
                _ = next.update(event);
                s._pending = next;
                s._resize_report = true;
                return true;
            },
            .reply => |reply| switch (reply) {
                .window_size => |report| {
                    if (report.what == .text_area_cells) {
                        var next = s._pending orelse s._ws;
                        const before = next.cells;
                        _ = next.update(event);
                        if (!std.meta.eql(before, next.cells)) next.cell = .{};
                        s._pending = next;
                        s._resize_report = true;
                        return true;
                    }
                    if (s._pending) |*next| redraw = next.update(event) or redraw else redraw = s._ws.update(event) or redraw;
                },
                .graphics => |response| {
                    const held = if (response.id) |id| s._layers.image(id) != null else false;
                    s._layers.ack(response);
                    redraw = held or redraw;
                },
                else => {},
            },
            else => {},
        }
        return redraw;
    }

    /// Applies the last size once, before the caller paints. Both grids
    /// follow it. An unchanged report with in-band resize enabled repaints:
    /// the signal may have drawn before the terminal's own size changed.
    /// Ask the cell's pixel size again after either case, since a font
    /// change also looks like a resize. Returns whether a repaint is due.
    pub fn resize(s: *Session, w: *Writer) Error!bool {
        const next = s._pending orelse return false;
        const changed = !std.meta.eql(s._ws.cells, next.cells) or !std.meta.eql(s._ws.area, next.area);
        const confirmed = s._resize_report and s._caps.in_band_resize;
        if (changed) {
            // Reserve the renderer first, then let Screen's atomic resize
            // commit. The remaining storage swap cannot fail, so allocation
            // failure cannot split the two grids or invalidate old borrows.
            var prepared: ?Renderer = if (!std.meta.eql(s._renderer.dimensions(), next.cells))
                try Renderer.init(s._gpa, next.cells)
            else
                null;
            defer if (prepared) |*r| r.deinit();
            if (!std.meta.eql(s._screen.dimensions(), next.cells)) try s._screen.resize(next.cells);
            if (prepared) |*r| render.internal.resizePrepared(&s._renderer, r);
        }
        if (changed or confirmed) {
            s._renderer.repaint();
            s._layers.repaint();
            try morse.queryWindowSize(w, .cell_pixels);
        }
        s._ws = next;
        s._pending = null;
        s._resize_report = false;
        return changed or confirmed;
    }

    /// Writes one frame, after `resize` and application painting. No flush.
    pub fn draw(s: *Session, w: *Writer) render.Error!Renderer.Stats {
        return s._renderer.draw(w, &s._screen, &s._layers, s._caps);
    }
};

const testing = std.testing;

test "a session coalesces sizes, resizes both grids, and asks for cell pixels again" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 }, .cell = .{ .width = 9, .height = 20 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try s.handle(&out.writer, .{ .resize = .{ .cols = 10, .rows = 4 } }, 0));
    try testing.expect(try s.handle(&out.writer, .{ .resize = .{ .cols = 12, .rows = 5 } }, 1));
    try testing.expectEqual(@as(u16, 8), s._screen.dimensions().cols);
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqual(s._ws.cells, s._screen.dimensions());
    try testing.expectEqual(s._ws.cells, s._renderer.dimensions());
    try testing.expectEqual(@as(u16, 12), s._ws.cells.cols);
    try testing.expect(!s._ws.cell.known());
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try testing.expect(!try s.resize(&out.writer));
    out.clearRetainingCapacity();
    try testing.expect(try s.handle(&out.writer, .{ .reply = morse.Reply.parse("\x1b[8;6;14t").? }, 2));
    _ = try s.resize(&out.writer);
    try testing.expectEqual(@as(u16, 14), s._screen.dimensions().cols);
    try testing.expectEqual(s._screen.dimensions(), s._renderer.dimensions());
}

test "a session repaints an unchanged in-band size, including pictures" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    s._probe.caps.in_band_resize = true;
    s._probe.caps.kitty_graphics = true;
    _ = try s.setCaps(&out.writer, s._probe.caps);
    try s._screen.write(0, 0, "x", .{}, .none);
    const layer: @import("layer.zig").Layer = .{ .image = 7, .rect = .{ .cols = 2, .rows = 2 } };
    try s._layers.declare(layer);
    _ = try s.draw(&out.writer);
    out.clearRetainingCapacity();
    _ = try s.handle(&out.writer, .{ .resize = .{ .cols = 8, .rows = 3 } }, 1);
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try s._layers.declare(layer);
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
    try testing.expect(try s.handle(&out.writer, .{ .reply = morse.Reply.parse("\x1b[?2048;2$y").? }, 0));
    try testing.expectEqualStrings("\x1b[?2048h", out.written());
    try testing.expect(s._renderer.entered().?.in_band_resize);
    try s.leave(&out.writer);
}

test "the probe wait keeps DA1 quiet time and the overall deadline on caller time" {
    var probe: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    const wait = ProbeWait.init(1000, 500, 50);
    try testing.expectEqual(@as(?i64, 500), wait.remaining(&probe, 1000));
    probe.feed(.{ .reply = morse.Reply.parse("\x1b[?62c").? }, 1010);
    try testing.expectEqual(@as(?i64, 40), wait.remaining(&probe, 1020));
    probe.feed(.{ .reply = morse.Reply.parse("\x1b[?2048;2$y").? }, 1040);
    try testing.expectEqual(@as(?i64, 40), wait.remaining(&probe, 1050));
    try testing.expectEqual(@as(?i64, null), wait.remaining(&probe, 1090));
    probe.answered = .initEmpty();
    try testing.expectEqual(@as(?i64, null), wait.remaining(&probe, 1500));
    probe.answered = .initFull();
    try testing.expectEqual(@as(?i64, null), wait.remaining(&probe, 1000));
}

test "a failed session resize keeps both grids and their borrowed content together" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var s = try Session.init(gpa, .{ .cells = .{ .cols = 4, .rows = 1 } }, .{ .graphics_id = 1 });
            defer s.deinit();
            s._screen.method = .unicode;
            const link = try s._screen.link("https://kept.invalid", "id=kept");
            try s._screen.write(0, 0, "a\u{301}\u{302}\u{303}", .{}, link);
            var sink: Writer.Discarding = .init(&.{});
            _ = try s.draw(&sink.writer);
            _ = try s.handle(&sink.writer, .{ .resize = .{ .cols = 5, .rows = 2 } }, 0);
            const size = s._screen.dimensions();
            const generation = s._screen._pool_generation;
            const cells = s._screen._cells;
            const prev = s._renderer._prev;
            const borrowed = s._screen.textAt(0, 0);
            const pending = s._pending;
            _ = s.resize(&sink.writer) catch |err| {
                try testing.expectEqual(size, s._screen.dimensions());
                try testing.expectEqual(size, s._renderer.dimensions());
                try testing.expectEqual(size, s._ws.cells);
                try testing.expectEqual(generation, s._screen._pool_generation);
                try testing.expect(s._screen._cells.ptr == cells.ptr);
                try testing.expect(s._renderer._prev.ptr == prev.ptr);
                try testing.expect(s._screen.textAt(0, 0).ptr == borrowed.ptr);
                try testing.expectEqualStrings("a\u{301}\u{302}\u{303}", borrowed);
                try testing.expectEqual(pending, s._pending);
                return err;
            };
            try testing.expectEqual(s._screen.dimensions(), s._renderer.dimensions());
            try testing.expectEqual(s._ws.cells, s._screen.dimensions());
            try testing.expectEqualStrings("https://kept.invalid", s._screen.target(s._screen.readCell(0, 0).?.link).?.uri);
            _ = try s.draw(&sink.writer);
        }
    }.run, .{});
}

test "session allocation and coordinated state stay behind their owner" {
    inline for (.{ "gpa", "screen", "renderer", "ws", "caps", "probe", "layers", "pending", "resize_report" }) |field| {
        try testing.expect(!@hasField(Session, field));
    }
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
