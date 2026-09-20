//! The property this package is built around: what `draw` writes, fed back
//! through `Term`, is the screen it was given.
//!
//! Random grid operations, drawn, parsed by the emulator, compared. Four
//! properties come out of the one generator, and each is a different bug:
//!
//! - **The terminal shows the screen.** Every cell, read by column and
//!   including the covered column of a wide grapheme, because a dump of the
//!   grid as a string is exactly where that column goes missing.
//! - **Drawing again writes nothing.** Then every row damaged by hand and
//!   drawn a third time, which must also write nothing: the previous frame
//!   really is what the terminal holds, and not merely what the damage map
//!   said.
//! - **A repaint recovers from anything.** The previous frame is corrupted
//!   on purpose and `repaint` called; the terminal must come back to the
//!   screen. This is what makes the escape hatch worth having.
//! - **Incremental equals a repaint.** A second terminal is given one full
//!   repaint of the final screen, and the two terminals must agree.
//!
//! All four run three times: against a terminal measuring by codepoint, a
//! terminal measuring by cluster, and a terminal measuring by codepoint that
//! is told the width of every cluster it could measure differently. The rule
//! that repaints a drifting row exists for the case where two width models
//! disagree, and a harness with one width model cannot produce the input it
//! defends against; the third run is the case where the disagreement is
//! there and the protocol, not the repaint, is what settles it.
//!
//! The same generator checks the grid's own invariants after every
//! operation, so a damage map that under-reports fails here rather than once
//! a week on someone's terminal.

const std = @import("std");

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const render = @import("render.zig");
const textmod = @import("text.zig");
const term = @import("term.zig");
const Caps = @import("caps.zig").Caps;
const Cell = cellmod.Cell;
const Renderer = render.Renderer;
const Screen = @import("screen.zig").Screen;
const Term = term.Term;

/// The inputs replayed on every run, shared with the conformance build.
const corpus = @import("corpus");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const testing = std.testing;

/// The graphemes the generator draws from: ASCII, a combining pair, a wide
/// one, a cluster too long to live in a cell, and the one the two width
/// models disagree about.
const alphabet = [_][]const u8{
    "a",
    "b",
    " ",
    "~",
    "\u{e9}",
    "e\u{301}",
    "\u{4e2d}",
    "\u{ff21}",
    "\u{26a0}\u{fe0f}",
    "\u{1f469}\u{200d}\u{1f680}",
    "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}",
};

/// The styles it draws from: enough to exercise every arm of the colour
/// union and both halves of the bold-and-dim off code.
const styles = [_]cellmod.Style{
    .{},
    .{ .bold = true },
    .{ .dim = true },
    .{ .bold = true, .dim = true },
    .{ .fg = .ansi(.red) },
    .{ .fg = .ansi(.bright_cyan), .bg = .ansi(.black) },
    .{ .fg = .palette(137) },
    .{ .fg = .rgb(0x1c, 0x2e, 0xff) },
    .{ .bg = .rgb(9, 9, 9), .italic = true },
    .{ .underline = .curly, .underline_color = .rgb(1, 2, 3) },
    .{ .reverse = true },
    .{ .strikethrough = true, .overline = true, .blink = true },
    .{ .hidden = true },
};

/// The links it draws from, including two that differ only in their
/// parameters.
const uris = [_][]const u8{ "", "https://ziglang.org", "file:///tmp/a", "https://ziglang.org" };
const params = [_][]const u8{ "", "", "id=one", "id=two" };

/// Everything one round of the property needs.
const Harness = struct {
    gpa: Allocator,
    screen: Screen,
    renderer: Renderer,
    out: std.Io.Writer.Allocating,
    caps: Caps,

    fn init(gpa: Allocator, size: geom.Size, method: textmod.Method) !Harness {
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit(gpa);
        s.method = method;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit(gpa);
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            .caps = .{
                .width_method = method,
                .osc8 = true,
                .truecolor = true,
                .sync = true,
                .scroll_detection = true,
                .rep = true,
                .explicit_width = method == .explicit,
            },
        };
    }

    fn deinit(h: *Harness) void {
        h.screen.deinit(h.gpa);
        h.renderer.deinit(h.gpa);
        h.out.deinit();
    }

    /// One frame: draw, feed the bytes to a terminal that started blank and
    /// was fed every frame before it, and compare.
    fn frame(h: *Harness, t: *Term) !Renderer.Stats {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        try t.feed(h.out.written());
        try term.expectScreensEqual(&h.screen, t.screen());
        return stats;
    }
};

/// Every invariant the grid promises, checked over the whole of it.
fn checkGrid(s: *const Screen) !void {
    for (0..s.size.rows) |r| {
        var sum: u32 = 0;
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const c = s.cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape._reserved == 0);
            if (c.isTail()) {
                try testing.expect(col > 0);
                try testing.expect(s.cells[s.index(col - 1, @intCast(r))].shape.kind == .wide);
            } else {
                sum += c.width();
                if (c.shape.kind == .wide) {
                    try testing.expect(col + 1 < s.size.cols);
                    try testing.expect(s.cells[s.index(col + 1, @intCast(r))].isTail());
                }
            }
            if (c.text.isPooled()) {
                try testing.expect(c.text.offset().? + c.text.length() <= s.graphemes.len());
            }
            if (c.link.index()) |li| try testing.expect(li < s.links.count());
        }
        try testing.expectEqual(@as(u32, s.size.cols), sum);
    }
}

/// That the conservative damage map names every cell that changed, checked
/// against a copy taken before the operations.
fn checkDamage(s: *const Screen, before: []const Cell) !void {
    for (0..s.size.rows) |r| {
        const span = s.damage.row(@intCast(r));
        var col: u16 = 0;
        while (col < s.size.cols) : (col += 1) {
            const i = s.index(col, @intCast(r));
            const changed = !s.cells[i].eql(before[i]);
            const named = if (span) |sp| col >= sp.first and col <= sp.last else false;
            if (changed and !named) return error.DamageUnderReported;
        }
    }
}

/// One random operation on the grid.
fn operate(h: *Harness, smith: *Smith) !void {
    const s = &h.screen;
    const cols = s.size.cols;
    const rows = s.size.rows;
    switch (smith.valueRangeAtMost(u8, 0, 6)) {
        0, 1, 2 => {
            const col: u16 = @intCast(smith.index(cols));
            const row: u16 = @intCast(smith.index(rows));
            const g = alphabet[smith.index(alphabet.len)];
            const style = styles[smith.index(styles.len)];
            const which = smith.index(uris.len);
            const link = try s.link(h.gpa, uris[which], params[which]);
            try s.write(col, row, g, style, link);
        },
        3 => {
            const col: u16 = @intCast(smith.index(cols));
            const row: u16 = @intCast(smith.index(rows));
            s.writeOwnedCell(col, row, .blank(styles[smith.index(styles.len)]));
        },
        4 => {
            const rect = randomRect(smith, cols, rows);
            s.fill(rect, .blank(styles[smith.index(styles.len)]));
        },
        5 => {
            const rect = randomRect(smith, cols, rows);
            s.scroll(rect, smith.valueRangeAtMost(i32, -3, 3));
        },
        6 => {
            s.cursor.visible = smith.value(bool);
            s.cursor.col = @intCast(smith.index(cols));
            s.cursor.row = @intCast(smith.index(rows));
            s.cursor.shape = @enumFromInt(smith.valueRangeAtMost(u8, 0, 6));
        },
        else => unreachable,
    }
}

/// A rectangle somewhere inside the grid.
fn randomRect(smith: *Smith, cols: u16, rows: u16) geom.Rect {
    const col: u16 = @intCast(smith.index(cols));
    const row: u16 = @intCast(smith.index(rows));
    return .{
        .col = col,
        .row = row,
        .cols = @intCast(smith.index(cols - col) + 1),
        .rows = @intCast(smith.index(rows - row) + 1),
    };
}

/// How the terminal on the other end measures, given how the renderer was
/// told to. A terminal told every width measures by codepoint on its own,
/// which is the case the telling exists for.
fn terminalMethod(method: textmod.Method) textmod.Method {
    return if (method == .explicit) .wcwidth else method;
}

/// The four properties, once, over a generated sequence of frames.
fn roundTrip(gpa: Allocator, smith: *Smith, method: textmod.Method) !void {
    const size: geom.Size = .{
        .cols = @intCast(smith.valueRangeAtMost(u8, 1, 24)),
        .rows = @intCast(smith.valueRangeAtMost(u8, 1, 12)),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(terminalMethod(method));

    const before = try gpa.alloc(Cell, h.screen.cells.len);
    defer gpa.free(before);

    var frames: usize = 0;
    while (frames < 6 and !smith.eos()) : (frames += 1) {
        @memcpy(before, h.screen.cells);
        h.screen.damage.clear();

        var ops: usize = 0;
        const count = smith.valueRangeAtMost(u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, smith);

        try checkGrid(&h.screen);
        try checkDamage(&h.screen, before);

        // The terminal shows the screen.
        _ = try h.frame(&t);

        // Drawn again with nothing changed: not one byte.
        try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);

        // And again with every row claimed to have changed, which is the
        // stronger statement: the previous frame is what the terminal holds.
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
    }

    // A repaint recovers from any state the renderer drifted into.
    corrupt(&h.renderer, smith);
    h.renderer.repaint();
    _ = try h.frame(&t);
    try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);

    // And a terminal given one full repaint of the final screen holds the
    // same thing as the terminal that was given every frame.
    var fresh: Term = try .init(gpa, size);
    defer fresh.deinit();
    fresh.setMethod(terminalMethod(method));
    var once: Renderer = try .init(gpa, size);
    defer once.deinit(gpa);
    once.repaint();
    h.out.clearRetainingCapacity();
    h.screen.damageAll();
    _ = try once.draw(&h.out.writer, &h.screen, h.caps);
    try fresh.feed(h.out.written());
    try term.expectScreensEqual(t.screen(), fresh.screen());
}

/// Puts the renderer's idea of the terminal out of step with it, the way a
/// dropped write or a program writing to the terminal behind the renderer's
/// back would.
fn corrupt(r: *Renderer, smith: *Smith) void {
    var i: usize = 0;
    const count = smith.valueRangeAtMost(u8, 1, 8);
    while (i < count and r.prev.len != 0) : (i += 1) {
        r.prev[smith.index(r.prev.len)] = .blank(styles[smith.index(styles.len)]);
    }
    r.style = styles[smith.index(styles.len)];
    r.cursor = null;
    r.shown = null;
}

test "the round trip holds against a terminal measuring by codepoint" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTrip(gpa, smith, .wcwidth);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the round trip holds against a terminal measuring by cluster" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTrip(gpa, smith, .unicode);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the round trip holds against a terminal told every width" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTrip(gpa, smith, .explicit);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "every cluster written to the last row reaches the terminal" {
    const gpa = testing.allocator;
    const size: geom.Size = .{ .cols = 24, .rows = 4 };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(.unicode);

    var col: u16 = 0;
    var which: usize = 0;
    while (col < size.cols) : (which += 1) {
        const g = alphabet[which % alphabet.len];
        const w = textmod.graphemeWidth(g, .unicode);
        if (col + w > size.cols) break;
        try h.screen.write(col, size.rows - 1, g, styles[which % styles.len], .none);
        col += w;
    }
    _ = try h.frame(&t);

    col = 0;
    while (col < size.cols) : (col += 1) {
        try testing.expectEqualStrings(
            h.screen.textAt(col, size.rows - 1),
            t.screen().textAt(col, size.rows - 1),
        );
    }
}

test "a frame the damage map named but nothing changed in writes nothing at all" {
    // The cursor is the point: hiding it before a body pass that turns out
    // to have nothing to write, and showing it again after, is twelve bytes
    // on every frame of a program that marks what it redrew rather than what
    // it changed -- and it is the property this package is checked against.
    const gpa = testing.allocator;
    const size: geom.Size = .{ .cols = 8, .rows = 3 };
    var h: Harness = try .init(gpa, size, .wcwidth);
    defer h.deinit();
    var t: Term = try .init(gpa, size);
    defer t.deinit();

    try h.screen.write(0, 0, "a", .{ .bold = true }, .none);
    h.screen.cursor.visible = true;
    h.screen.cursor.col = 3;
    _ = try h.frame(&t);

    for (0..3) |_| {
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
    }

    // And the same on a terminal with no OSC 8, where a link is not a
    // difference the terminal could show and the previous frame does not
    // record one. Read off the renderer rather than through the terminal,
    // because the two screens differ by exactly the link the terminal was
    // never told about.
    h.caps.osc8 = false;
    h.renderer.repaint();
    h.out.clearRetainingCapacity();
    _ = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);

    const link = try h.screen.link(gpa, "https://ziglang.org", "");
    try h.screen.write(0, 0, "a", .{ .bold = true }, link);
    h.screen.damageAll();
    h.out.clearRetainingCapacity();
    const after = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
    try testing.expectEqual(@as(usize, 0), after.bytes);
}
