//! What every widget in this module is tested through.
//!
//! A widget is drawn into a real `Screen`, the frame is rendered to bytes,
//! the bytes are fed to the terminal emulator the package ships, and the
//! grid the terminal rebuilt is compared with the expected picture. Nothing
//! is asserted against the buffer the widget wrote: a widget that draws the
//! right cells and a renderer that writes the wrong bytes for them look the
//! same from there, and the point of this package is that they do not have
//! to.
//!
//! Every comparison also draws the frame a second time and asserts it wrote
//! no bytes at all, so every widget carries the idempotence property with
//! it: whatever the widget put in the grid, the renderer agrees the terminal
//! is already showing it.

const std = @import("std");
const visor = @import("visor");

const testing = std.testing;

/// A screen, the renderer, and the terminal a frame is read back through.
pub const Harness = struct {
    gpa: std.mem.Allocator,
    screen: visor.Screen,
    renderer: visor.Renderer,
    term: visor.Term,
    out: std.Io.Writer.Allocating,
    text: std.Io.Writer.Allocating,
    caps: visor.Caps,

    /// A grid that size, measured by cluster, with a terminal to match.
    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Harness {
        return initMeasured(gpa, cols, rows, .unicode);
    }

    /// A grid that size, measured `method`'s way, with a terminal that
    /// measures the same way.
    pub fn initMeasured(gpa: std.mem.Allocator, cols: u16, rows: u16, method: visor.Method) !Harness {
        const size: visor.Size = .{ .cols = cols, .rows = rows };
        var screen: visor.Screen = try .init(gpa, size);
        errdefer screen.deinit(gpa);
        screen.method = method;
        var renderer: visor.Renderer = try .init(gpa, size);
        errdefer renderer.deinit(gpa);
        var term: visor.Term = try .init(gpa, size);
        errdefer term.deinit();
        term.setMethod(method);
        return .{
            .gpa = gpa,
            .screen = screen,
            .renderer = renderer,
            .term = term,
            .out = .init(gpa),
            .text = .init(gpa),
            .caps = .{ .width_method = method, .truecolor = true, .osc8 = true },
        };
    }

    pub fn deinit(h: *Harness) void {
        h.screen.deinit(h.gpa);
        h.renderer.deinit(h.gpa);
        h.term.deinit();
        h.out.deinit();
        h.text.deinit();
    }

    /// The whole grid as a window, which is what a widget draws into.
    pub fn window(h: *Harness) visor.Window {
        return h.screen.window();
    }

    /// The frame, through the renderer and the terminal, as text.
    ///
    /// Also asserts that drawing the same screen again writes nothing, which
    /// is the property the whole package is checked against, applied to
    /// whatever the widget just drew.
    pub fn frame(h: *Harness) ![]const u8 {
        h.out.clearRetainingCapacity();
        _ = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try h.term.feed(h.out.written());
        try visor.expectScreensEqual(&h.screen, h.term.screen());

        h.out.clearRetainingCapacity();
        const again = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try testing.expectEqual(@as(usize, 0), again.bytes);

        h.text.clearRetainingCapacity();
        try visor.dumpScreen(h.term.screen(), &h.text.writer);
        return h.text.written();
    }

    /// The frame, against the picture it should be.
    ///
    /// `want` is one line a row with no trailing spaces written; the grid's
    /// own trailing blanks are trimmed before the comparison so that a test
    /// reads as the picture it is checking.
    pub fn expectFrame(h: *Harness, want: []const u8) !void {
        const got = try h.frame();
        var trimmed: std.Io.Writer.Allocating = .init(h.gpa);
        defer trimmed.deinit();
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null and line.len == 0) break;
            try trimmed.writer.writeAll(std.mem.trimEnd(u8, line, " "));
            try trimmed.writer.writeByte('\n');
        }
        try testing.expectEqualStrings(want, trimmed.written());
    }

    /// The style of one cell, for the tests that are about colour.
    pub fn styleAt(h: *Harness, col: u16, row: u16) visor.Style {
        return h.term.screen().readCell(col, row).?.style;
    }
};
