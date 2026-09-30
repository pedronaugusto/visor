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
    gpa: Allocator,
    screen: Screen,
    renderer: Renderer,
    ws: Winsize,
    caps: Caps = .{},
    probe: Caps.Probe,
    layers: Layers = .{},
    /// Last size of a drained batch, applied by `resize` before painting.
    pending: ?Winsize = null,
    /// An in-band report also confirms a size already seen by a signal.
    resize_report: bool = false,

    pub const Error = Allocator.Error || render.Error || Renderer.ModesError;

    /// Allocates the screen and renderer at the same size. The probe id
    /// belongs to the caller and must be excluded from its image ids.
    pub fn init(gpa: Allocator, ws: Winsize, questions: morse.Probe) Allocator.Error!Session {
        var screen = try Screen.init(gpa, ws.cells);
        errdefer screen.deinit();
        return .{
            .gpa = gpa,
            .screen = screen,
            .renderer = try Renderer.init(gpa, ws.cells),
            .ws = ws,
            .probe = .{ .questions = questions },
        };
    }

    /// Gives memory back. Leave the terminal first when this value entered
    /// it; freeing memory writes nothing.
    pub fn deinit(s: *Session) void {
        s.layers.deinit(s.gpa);
        s.renderer.deinit();
        s.screen.deinit();
        s.* = undefined;
    }

    /// Applies caller-selected caps as well as the probe's learned ones.
    /// An application can call this after `handle` to apply its own policy.
    pub fn setCaps(s: *Session, w: *Writer, caps: Caps) Error!bool {
        if (std.meta.eql(s.caps, caps)) return false;
        if (s.renderer.entered != null) try s.renderer.setCaps(w, caps) else s.renderer.repaint();
        s.caps = caps;
        s.screen.method = caps.width_method;
        s.layers.repaint();
        return true;
    }

    /// Takes a screen and input modes, keeping pixel mouse parsing in step.
    /// Raw mode and restoration are the caller's (`Tty.enter` can do them).
    pub fn enter(s: *Session, w: *Writer, parser: *morse.KeyParser, mode: render.Mode, modes: render.Modes) Error!void {
        parser.mouse_pixels = pixelMouse(modes);
        try s.renderer.enter(w, s.caps, mode, modes);
    }

    /// Changes modes and the parser's flag together. Pixel reports are
    /// byte-identical to cell reports; the requested encoding decides.
    pub fn setModes(s: *Session, w: *Writer, parser: *morse.KeyParser, modes: render.Modes) Renderer.ModesError!void {
        if (s.renderer.entered == null) return error.NotEntered;
        parser.mouse_pixels = pixelMouse(modes);
        try s.renderer.setModes(w, modes);
    }

    fn pixelMouse(modes: render.Modes) bool {
        return if (modes.mouse) |mouse| mouse.encoding == .sgr_pixels else false;
    }

    /// Frees pictures and gives the screen back. Raw mode is the caller's.
    pub fn leave(s: *Session, w: *Writer) Error!void {
        try s.layers.freeAll(w);
        try s.renderer.leave(w);
    }

    /// Folds terminal housekeeping in, returning whether another frame is
    /// due. Size reports are coalesced until `resize`; caps and graphics
    /// replies are applied now. Keys, text and application policy stay with
    /// the caller. `now_ms` comes from the caller's clock for the probe.
    pub fn handle(s: *Session, w: *Writer, event: morse.Event, now_ms: i64) Error!bool {
        const was = s.probe.caps;
        s.probe.feed(event, now_ms);
        var redraw = if (!std.meta.eql(was, s.probe.caps)) try s.setCaps(w, s.probe.caps) else false;
        switch (event) {
            .resize => {
                var next = s.pending orelse s.ws;
                _ = next.update(event);
                s.pending = next;
                s.resize_report = true;
                return true;
            },
            .reply => |reply| switch (reply) {
                .window_size => |report| {
                    if (report.what == .text_area_cells) {
                        var next = s.pending orelse s.ws;
                        const before = next.cells;
                        _ = next.update(event);
                        if (!std.meta.eql(before, next.cells)) next.cell = .{};
                        s.pending = next;
                        s.resize_report = true;
                        return true;
                    }
                    if (s.pending) |*next| redraw = next.update(event) or redraw else redraw = s.ws.update(event) or redraw;
                },
                .graphics => |response| {
                    const held = if (response.id) |id| s.layers.image(id) != null else false;
                    s.layers.ack(response);
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
        const next = s.pending orelse return false;
        const changed = !std.meta.eql(s.ws.cells, next.cells) or !std.meta.eql(s.ws.area, next.area);
        const confirmed = s.resize_report and s.caps.in_band_resize;
        if (changed) {
            if (!std.meta.eql(s.screen.size, next.cells)) try s.screen.resize(next.cells);
            if (!std.meta.eql(s.renderer.size, next.cells)) try s.renderer.resize(next.cells);
        }
        if (changed or confirmed) {
            s.renderer.repaint();
            s.layers.repaint();
            try morse.queryWindowSize(w, .cell_pixels);
        }
        s.ws = next;
        s.pending = null;
        s.resize_report = false;
        return changed or confirmed;
    }

    /// Writes one frame, after `resize` and application painting. No flush.
    pub fn draw(s: *Session, w: *Writer) render.Error!Renderer.Stats {
        return s.renderer.draw(w, &s.screen, &s.layers, s.caps);
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
    try testing.expectEqual(@as(u16, 8), s.screen.size.cols);
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqual(s.ws.cells, s.screen.size);
    try testing.expectEqual(s.ws.cells, s.renderer.size);
    try testing.expectEqual(@as(u16, 12), s.ws.cells.cols);
    try testing.expect(!s.ws.cell.known());
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try testing.expect(!try s.resize(&out.writer));
    out.clearRetainingCapacity();
    try testing.expect(try s.handle(&out.writer, .{ .reply = morse.Reply.parse("\x1b[8;6;14t").? }, 2));
    _ = try s.resize(&out.writer);
    try testing.expectEqual(@as(u16, 14), s.screen.size.cols);
    try testing.expectEqual(s.screen.size, s.renderer.size);
}

test "a session repaints an unchanged in-band size, including pictures" {
    var s = try Session.init(testing.allocator, .{ .cells = .{ .cols = 8, .rows = 3 } }, .{ .graphics_id = 1 });
    defer s.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    s.probe.caps.in_band_resize = true;
    s.probe.caps.kitty_graphics = true;
    _ = try s.setCaps(&out.writer, s.probe.caps);
    try s.screen.write(0, 0, "x", .{}, .none);
    const layer: @import("layer.zig").Layer = .{ .image = 7, .rect = .{ .cols = 2, .rows = 2 } };
    try s.layers.declare(testing.allocator, layer);
    _ = try s.draw(&out.writer);
    out.clearRetainingCapacity();
    _ = try s.handle(&out.writer, .{ .resize = .{ .cols = 8, .rows = 3 } }, 1);
    try testing.expect(try s.resize(&out.writer));
    try testing.expectEqualStrings("\x1b[16t", out.written());
    try s.layers.declare(testing.allocator, layer);
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
    try testing.expect(s.renderer.entered.?.in_band_resize);
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
