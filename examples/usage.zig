//! What using visor looks like, end to end, with no terminal involved.
//!
//! The region between the two README markers is what README.md shows, and
//! `zig build examples` builds and runs this file, so the snippet a reader
//! copies is code that ran. Nothing here opens a descriptor: the frame goes
//! into a buffer, and the emulator this package ships reads it back, which
//! is also how a program built on visor tests its own screens.

const std = @import("std");
const visor = @import("visor");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // --- README:usage ---
    // What the terminal can do. Nothing here reads an environment
    // variable: `Caps.Probe` writes the questions, the caller reads the
    // answers on its own clock, and a caller that would rather assume
    // sets the fields itself.
    const caps: visor.Caps = .{
        .width_method = .unicode,
        .truecolor = true,
        .osc8 = true,
        .sync = true,
    };

    // The grid, and the renderer that remembers what the terminal was
    // last shown. One allocator each, taken here and never again.
    const size: visor.Size = .{ .cols = 40, .rows = 7 };
    var screen: visor.Screen = try .init(gpa, size);
    defer screen.deinit(gpa);
    screen.method = caps.width_method;

    var renderer: visor.Renderer = try .init(gpa, size);
    defer renderer.deinit(gpa);

    // Drawing code holds a window and nothing else. A child is clipped to
    // its parent, and a border is drawn as the child is made, so what
    // comes back is the inside of the frame.
    const root = screen.window();
    const panel = root.child(.{
        .col = 1,
        .row = 1,
        .cols = 30,
        .rows = 5,
        .border = .{ .where = .all, .glyphs = .rounded, .style = .{ .dim = true } },
    });

    // Runs of styled text, wrapped. `print` never allocates and says
    // where it stopped.
    const link = try screen.link(gpa, "https://ziglang.org", "id=1");
    _ = try panel.print(&.{
        .{ .text = "visor ", .style = .{ .bold = true } },
        .{ .text = "draws a grid", .style = .{ .fg = .ansi(.cyan) } },
        .{ .text = "\n" },
        .{ .text = "ziglang.org", .style = .{ .underline = .single }, .link = link },
    }, .{ .wrap = .word });

    // A wide grapheme takes two columns and the grid knows it: the second
    // one is a tail, and nothing can be written into it by accident.
    try panel.write(0, 2, "\u{4e2d}", .{ .fg = .rgb(0x9a, 0xe0, 0xd5) }, .none);

    // Where the cursor should end the frame, in this window's own
    // coordinates.
    panel.showCursor(12, 2);
    panel.setCursorShape(.bar);

    // The frame. `draw` writes the difference between what the terminal
    // was last shown and this, allocates nothing, and never flushes: the
    // caller decides when the bytes leave.
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const stats = try renderer.draw(&buffer.writer, &screen, null, caps);

    // `Stats` is what makes a budget a test rather than a comment, and
    // what tells a caller how big a write buffer a frame wants.
    std.debug.print("frame: {d} bytes, {d} cells in {d} runs, {d} moves\n", .{
        stats.bytes, stats.cells, stats.runs, stats.moves,
    });

    // Drawn again with nothing changed, the renderer writes nothing at
    // all. That is not an optimisation, it is the property the whole
    // design is checked against.
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    std.debug.assert((try renderer.draw(&second.writer, &screen, null, caps)).bytes == 0);

    // And this is how a program built on visor tests its own screens: the
    // emulator reads the bytes back into a grid, and the two are compared
    // cell by cell, covered columns included.
    var term: visor.Term = try .init(gpa, size);
    defer term.deinit();
    term.setMethod(caps.width_method);
    try term.feed(buffer.written());
    try visor.expectScreensEqual(&screen, term.screen());

    // The grid as text, one row a line, for a golden file or a failing
    // test to be read from.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try visor.dumpScreen(term.screen(), &out.writer);
    std.debug.print("{s}", .{out.written()});

    // Every sequence visor writes comes from morse, which it re-exports
    // whole: one fetch, and everything under the grid is reachable.
    var control: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&control);
    try visor.morse.mouse(&w, .{ .motion = .press });
    // --- README:usage ---
}
