//! A screen that lives at the prompt: inline mode, end to end, with no
//! terminal involved.
//!
//! A program that reports on a job wants a few rows under the prompt, not
//! the whole terminal: the rows scroll into the history with everything
//! else when it is done. `Renderer.enter` with `Mode.inline` takes the rows
//! at the cursor, `resize` takes more, and `leave` puts the cursor on the
//! row below with the last frame still showing. Every frame goes through the
//! emulator, which starts with a prompt already on it, and the rows around
//! the screen are printed so what the terminal shows is what is checked.

const std = @import("std");
const visor = @import("visor");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const caps: visor.Caps = .{ .width_method = .unicode, .truecolor = true, .rep = true };
    const cols: u16 = 44;

    // The terminal, with two lines of history and the prompt on the third:
    // where a program finds it.
    var term: visor.Term = try .init(gpa, .{ .cols = cols, .rows = 8 });
    defer term.deinit();
    term.setMethod(caps.width_method);
    try term.feed("$ ls\r\nbuild.zig  src\r\n$ build");

    var size: visor.Size = .{ .cols = cols, .rows = 2 };
    var screen: visor.Screen = try .init(gpa, size);
    defer screen.deinit(gpa);
    screen.method = caps.width_method;
    var renderer: visor.Renderer = try .init(gpa, size);
    defer renderer.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Two rows at the cursor. The prompt's row is the first of them, and
    // what was typed there is erased with the rest of the rows.
    try renderer.enter(&out.writer, caps, .@"inline");
    try term.feed(out.written());
    try show(gpa, &term, "entered: two rows at the prompt", null);

    var job: Job = .{ .done = 0, .of = 12 };
    try job.draw(screen.window());
    try show(gpa, &term, "the first frame", try frame(&renderer, &screen, &term, caps, &out));

    job.done = 7;
    try job.draw(screen.window());
    try show(gpa, &term, "seven of twelve", try frame(&renderer, &screen, &term, caps, &out));

    // A third row, for a line of log. The terminal scrolls to make room
    // when there is none below, and what was above stays above.
    size = .{ .cols = cols, .rows = 3 };
    try screen.resize(gpa, size);
    try renderer.resize(gpa, size);
    job.done = 12;
    job.note = "linked zig-out/bin/build";
    try job.draw(screen.window());
    try show(gpa, &term, "grown to three rows", try frame(&renderer, &screen, &term, caps, &out));

    // Out, with the frame left where it is and the cursor below it.
    out.clearRetainingCapacity();
    try renderer.leave(&out.writer);
    try term.feed(out.written());
    try show(gpa, &term, "left: the cursor is on the row below", null);
}

/// What the program is reporting on.
const Job = struct {
    done: u32,
    of: u32,
    note: []const u8 = "",

    /// A title, a gauge, and the note when there is a row for it.
    fn draw(job: Job, w: visor.Window) !void {
        w.clear();
        _ = try w.print(&.{
            .{ .text = "building ", .style = .{ .bold = true } },
            .{ .text = "12 steps", .style = .{ .dim = true } },
        }, .{});
        const filled: u16 = @intCast(@as(u64, w.cols()) * job.done / job.of);
        var col: u16 = 0;
        while (col < w.cols()) : (col += 1) {
            const glyph: []const u8 = if (col < filled) "\u{2588}" else "\u{2591}";
            try w.write(col, 1, glyph, .{ .fg = .ansi(.green) }, .none);
        }
        if (w.rows() > 2) _ = try w.printSegment(.{ .text = job.note }, .{ .row = 2 });
    }
};

/// One frame, drawn and fed to the terminal, which must then show the screen
/// in the rows the renderer took.
fn frame(
    renderer: *visor.Renderer,
    screen: *visor.Screen,
    term: *visor.Term,
    caps: visor.Caps,
    out: *std.Io.Writer.Allocating,
) !visor.Renderer.Stats {
    out.clearRetainingCapacity();
    const stats = try renderer.draw(&out.writer, screen, caps);
    try term.feed(out.written());
    std.debug.assert((try renderer.draw(&out.writer, screen, caps)).bytes == 0);
    const origin = term.saved.?.row;
    var row: u16 = 0;
    while (row < screen.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < screen.size.cols) : (col += 1) {
            std.debug.assert(std.mem.eql(u8, screen.textAt(col, row), term.screen().textAt(col, origin + row)));
        }
    }
    return stats;
}

/// The whole terminal, with the cursor's row marked, so the rows around the
/// screen can be seen to survive.
fn show(gpa: std.mem.Allocator, term: *const visor.Term, what: []const u8, stats: ?visor.Renderer.Stats) !void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try visor.dumpScreen(term.screen(), &text.writer);
    if (stats) |s| {
        std.debug.print("\n{s} — {d} bytes, {d} cells in {d} runs, {d} repeated\n", .{
            what, s.bytes, s.cells, s.runs, s.repeated,
        });
    } else {
        std.debug.print("\n{s}\n", .{what});
    }
    var lines = std.mem.splitScalar(u8, text.written(), '\n');
    var row: u16 = 0;
    while (lines.next()) |line| : (row += 1) {
        if (row >= term.screen().size.rows) break;
        std.debug.print("{c}|{s}|\n", .{ @as(u8, if (row == term.row) '>' else ' '), line });
    }
}
