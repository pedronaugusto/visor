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
//! The first three run again for an inline screen: rows of a taller
//! terminal taken at a cursor the prompt left somewhere down it, growing and
//! shrinking between frames, with the rows above it and the cursor below it
//! at the end checked too.
//!
//! And the first two across resizes: the terminal takes a new size before
//! the program hears of it and keeps what fitted, frames drawn at the old
//! size land after it, and the next frame at the new size must leave the
//! terminal showing exactly the screen, the rows it has nothing to write on
//! included.
//!
//! Pictures get the same treatment: random placements, moves, deletions,
//! stacking changes and acknowledgements over the layers, with the checks
//! that a frame with nothing new writes nothing, that the text pass is whole
//! before the first graphics command, and that a deletion happens only for a
//! picture that left and names it alone.
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

/// The graphemes the resize property draws from: the narrow and the wide,
/// and none whose width the two models disagree about or whose marks
/// combine.
const resize_alphabet = [_][]const u8{ "a", "b", " ", "~", "\u{e9}", "\u{4e2d}", "\u{ff21}" };

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
                .scaled_text = true,
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
        var col: u16 = 0;
        while (col < s.size.cols) {
            const c = s.cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape._reserved == 0);
            if (c.text.isPooled()) {
                try testing.expect(c.text.offset().? + c.text.length() <= s.graphemes.len());
            }
            if (c.link.index()) |li| try testing.expect(li < s.links.count());
            if (c.isTail()) {
                // A tail is its head's, content and all: the renderer never
                // writes one, and the terminal makes its own from the head.
                const head = s.headOf(col, @intCast(r)) orelse return error.OrphanTail;
                var own = s.cells[s.index(head.col, head.row)];
                own.shape.kind = .spacer_tail;
                try testing.expect(c.eql(own));
                col += 1;
                continue;
            }
            // A head's block is inside the grid and made of its own tails,
            // so the columns of a row add up to the row.
            const span = c.width();
            try testing.expect(col + span <= s.size.cols);
            try testing.expect(r + c.rows() <= s.size.rows);
            for (0..c.rows()) |dr| {
                for (0..span) |dc| {
                    if (dr == 0 and dc == 0) continue;
                    const t = s.cells[s.index(@intCast(col + dc), @intCast(r + dr))];
                    try testing.expect(t.isTail());
                    try testing.expectEqual(c.shape.scale, t.shape.scale);
                }
            }
            col += span;
        }
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

/// What a generator may do to the grid.
const Ops = struct {
    /// The graphemes it writes.
    graphemes: []const []const u8,
    /// Whether it writes text drawn at more than one cell's size.
    scaled: bool,
};

/// Everything: the whole alphabet, and scaled text.
const every_op: Ops = .{ .graphemes = &alphabet, .scaled = true };

/// What the resize property draws: text one cell tall, from the graphemes
/// both width models agree on. Where a block of scaled text lands when the
/// grid it was drawn on is cut is the grid's own question, asked by the
/// properties above; this one asks where the terminal's rows and cells end
/// up.
const resize_ops: Ops = .{ .graphemes = &resize_alphabet, .scaled = false };

/// One random operation on the grid.
fn operate(h: *Harness, smith: anytype, ops: Ops) !void {
    const s = &h.screen;
    const cols = s.size.cols;
    const rows = s.size.rows;
    const graphemes = ops.graphemes;
    switch (smith.valueRangeAtMost(u8, 0, if (ops.scaled) 7 else 6)) {
        0, 1, 2 => {
            const col: u16 = @intCast(smith.index(cols));
            const row: u16 = @intCast(smith.index(rows));
            const g = graphemes[smith.index(graphemes.len)];
            const style = styles[smith.index(styles.len)];
            const which = smith.index(uris.len);
            const link = try s.link(h.gpa, uris[which], params[which]);
            try s.write(col, row, g, style, link);
        },
        7 => {
            const col: u16 = @intCast(smith.index(cols));
            const row: u16 = @intCast(smith.index(rows));
            const g = graphemes[smith.index(graphemes.len)];
            const style = styles[smith.index(styles.len)];
            _ = try s.writeScaled(col, row, g, style, .none, smith.valueRangeAtMost(u3, 2, 3));
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
fn randomRect(smith: anytype, cols: u16, rows: u16) geom.Rect {
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
        while (ops < count) : (ops += 1) try operate(&h, smith, every_op);

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

/// The properties across resizes: the terminal takes a new size first and
/// keeps whatever fitted, the program hears of it afterwards, and frames
/// drawn at the old size land on the terminal after it changed. The next
/// frame at the size the program was told must leave the terminal showing
/// exactly the screen, the rows it has nothing new to write included.
///
/// Driven by `corpus.Dice`, so every entry is a run over the whole range of
/// sizes rather than the one-cell terminal the input's own answers give.
fn roundTripResize(gpa: Allocator, smith: *Smith, method: textmod.Method) !void {
    var dice: corpus.Dice = .init(smith);
    var size: geom.Size = .{
        .cols = dice.valueRangeAtMost(u16, 1, 24),
        .rows = dice.valueRangeAtMost(u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(terminalMethod(method));
    h.out.clearRetainingCapacity();
    try h.renderer.enter(&h.out.writer, h.caps, .alt, .{});
    try t.feed(h.out.written());

    try scribble(&h, &dice);
    _ = try h.frame(&t);

    const steps = dice.valueRangeAtMost(u8, 1, 5);
    for (0..steps) |step| {
        const to = nextSize(&dice, size);
        var hops = dice.valueRangeAtMost(u8, 0, 3);
        const told_each = dice.value(bool);
        // The terminal passes through sizes on the way, frames drawn at the
        // size the program knows landing after each; the program hears of
        // every one or only of the last.
        while (hops > 0) : (hops -= 1) {
            const mid = nextSize(&dice, size);
            try stale(&h, &t, &dice, mid);
            if (told_each) {
                try h.screen.resize(gpa, mid);
                try h.renderer.resize(gpa, mid);
            }
        }
        try stale(&h, &t, &dice, to);
        try h.screen.resize(gpa, to);
        try h.renderer.resize(gpa, to);
        try checkGrid(&h.screen);
        size = to;

        // A frame now, or not until the next size; always after the last.
        if (step + 1 == steps or dice.valueRangeAtMost(u8, 0, 3) != 0) {
            try scribble(&h, &dice);
            _ = try h.frame(&t);
            try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
            h.screen.damageAll();
            try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
        }
    }
}

/// The terminal resized to `to`, and now and then a frame drawn at the size
/// the program still knows landing after it.
fn stale(h: *Harness, t: *Term, dice: *corpus.Dice, to: geom.Size) !void {
    if (dice.value(bool)) {
        try scribble(h, dice);
        h.out.clearRetainingCapacity();
        _ = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try t.resize(to);
        try t.feed(h.out.written());
    } else try t.resize(to);
}

/// What a program draws after a resize: now and then its whole layout again
/// from nothing, then some operations.
fn scribble(h: *Harness, dice: *corpus.Dice) !void {
    if (dice.value(bool)) h.screen.clear();
    var ops: usize = 0;
    const count = dice.valueRangeAtMost(u8, 1, 12);
    while (ops < count) : (ops += 1) try operate(h, dice, resize_ops);
}

/// A size in the generator's range, reached from `from` the way a window's
/// edge moves: both ways, the width alone, or the height alone.
fn nextSize(dice: *corpus.Dice, from: geom.Size) geom.Size {
    const cols = dice.valueRangeAtMost(u16, 1, 24);
    const rows = dice.valueRangeAtMost(u16, 1, 12);
    return switch (dice.valueRangeAtMost(u8, 0, 2)) {
        0 => .{ .cols = cols, .rows = rows },
        1 => .{ .cols = cols, .rows = from.rows },
        else => .{ .cols = from.cols, .rows = rows },
    };
}

test "the round trip holds across resizes against a terminal measuring by codepoint" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTripResize(gpa, smith, .wcwidth);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the round trip holds across resizes against a terminal measuring by cluster" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTripResize(gpa, smith, .unicode);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the round trip holds across resizes against a terminal told every width" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTripResize(gpa, smith, .explicit);
        }
    }.one, .{ .corpus = &corpus.entries });
}

/// The rows of a terminal the inline screen occupies, compared with the
/// screen cell by cell the way `expectScreensEqual` does, from the row the
/// saved origin names.
fn expectRegionEqual(want: *const Screen, t: *const Term) !void {
    const got = t.screen();
    const origin = (t.saved orelse return error.NoOrigin).row;
    try testing.expect(origin + want.size.rows <= got.size.rows);
    var row: u16 = 0;
    while (row < want.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < want.size.cols) : (col += 1) {
            const a = want.cells[want.index(col, row)];
            const b = got.cells[got.index(col, origin + row)];
            const same = std.mem.eql(u8, want.textAt(col, row), got.textAt(col, origin + row)) and
                std.mem.eql(u8, std.mem.asBytes(&a.style), std.mem.asBytes(&b.style)) and
                a.width() == b.width() and a.isTail() == b.isTail() and
                linksEqual(want, got, a.link, b.link);
            if (!same) {
                std.debug.print("inline cell {d},{d} (terminal row {d}) differs\n", .{ col, row, origin + row });
                return error.TestExpectedEqual;
            }
        }
    }
}

fn linksEqual(want: *const Screen, got: *const Screen, a: cellmod.Link, b: cellmod.Link) bool {
    const ta = want.target(a);
    const tb = got.target(b);
    if (ta == null or tb == null) return (ta == null) == (tb == null);
    return std.mem.eql(u8, ta.?.uri, tb.?.uri) and std.mem.eql(u8, ta.?.params, tb.?.params);
}

/// The properties again for an inline screen: rows of a taller terminal,
/// taken at a cursor the prompt left somewhere down it, the screen growing
/// and shrinking between frames, and the cursor left below it at the end.
fn roundTripInline(gpa: Allocator, smith: *Smith, method: textmod.Method) !void {
    const cols: u16 = @intCast(smith.valueRangeAtMost(u8, 1, 24));
    const terminal_rows = smith.valueRangeAtMost(u8, 2, 16);
    const prompt = smith.valueRangeAtMost(u8, 0, terminal_rows - 1);
    var size: geom.Size = .{ .cols = cols, .rows = smith.valueRangeAtMost(u8, 1, terminal_rows) };

    var t: Term = try .init(gpa, .{ .cols = cols, .rows = terminal_rows });
    defer t.deinit();
    t.setMethod(terminalMethod(method));
    var i: u8 = 0;
    while (i < prompt) : (i += 1) try t.feed("$\r\n");

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    h.caps.scroll_detection = false;
    try h.renderer.enter(&h.out.writer, h.caps, .@"inline", .{});
    try t.feed(h.out.written());
    try expectRegionEqual(&h.screen, &t);

    var frames: usize = 0;
    while (frames < 6 and !smith.eos()) : (frames += 1) {
        // Now and then the screen changes size, in rows or in columns; the
        // terminal is the same terminal.
        if (smith.valueRangeAtMost(u8, 0, 3) == 0) {
            size = .{
                .cols = @intCast(smith.valueRangeAtMost(u8, 1, 24)),
                .rows = smith.valueRangeAtMost(u8, 1, terminal_rows),
            };
            try h.screen.resize(gpa, size);
            try h.renderer.resize(gpa, size);
        }
        var ops: usize = 0;
        const count = smith.valueRangeAtMost(u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, smith, every_op);
        try checkGrid(&h.screen);

        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        try testing.expectEqual(@as(u32, 0), stats.scrolled);
        try t.feed(h.out.written());
        try expectRegionEqual(&h.screen, &t);

        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);
    }

    // A repaint recovers, from the origin.
    corrupt(&h.renderer, smith);
    h.renderer.repaint();
    h.out.clearRetainingCapacity();
    _ = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
    try t.feed(h.out.written());
    try expectRegionEqual(&h.screen, &t);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);

    // And the way out leaves the frame and puts the cursor below it.
    const origin = t.saved.?.row;
    h.out.clearRetainingCapacity();
    try h.renderer.leave(&h.out.writer);
    try t.feed(h.out.written());
    try testing.expectEqual(@as(u16, 0), t.col);
    try testing.expectEqual(@min(origin + size.rows, @as(u16, terminal_rows) - 1), t.row);
}

test "the round trip holds for an inline screen measuring by codepoint" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTripInline(gpa, smith, .wcwidth);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the round trip holds for an inline screen measuring by cluster" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTripInline(gpa, smith, .unicode);
        }
    }.one, .{ .corpus = &corpus.entries });
}

//=========================================================================
// Pictures: the same idea over the layers, where the property is that a
// frame with nothing new in it writes nothing, and that the text pass never
// writes a graphics command.
//=========================================================================

const layer = @import("layer.zig");

/// A picture the program is showing, as the program keeps it between
/// frames; declared again every frame, because that is how the layers work.
const Shown = struct {
    image: u32,
    placement: u32,
    rect: geom.Rect,
    under: bool,
    order: layer.Layer.Order,

    fn asLayer(p: Shown) layer.Layer {
        return .{
            .image = p.image,
            .placement = p.placement,
            .rect = p.rect,
            .under = p.under,
            .order = p.order,
        };
    }
};

/// Random placements, moves, deletions, stacking changes and acknowledgements
/// over a few frames, with text drawn beside them.
fn imageRoundTrip(gpa: Allocator, smith: *Smith) !void {
    const size: geom.Size = .{
        .cols = @intCast(smith.valueRangeAtMost(u8, 2, 24)),
        .rows = @intCast(smith.valueRangeAtMost(u8, 2, 12)),
    };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    h.caps.kitty_graphics = smith.valueRangeAtMost(u8, 0, 3) != 0;
    h.caps.scroll_detection = false;

    // Two terminals: one given every byte, one given each frame only up to
    // its first graphics command, which must already be the whole picture
    // of the text.
    var whole: Term = try .init(gpa, size);
    defer whole.deinit();
    whole.setMethod(.unicode);
    var before_graphics: Term = try .init(gpa, size);
    defer before_graphics.deinit();
    before_graphics.setMethod(.unicode);

    var showing: std.ArrayList(Shown) = .empty;
    defer showing.deinit(gpa);
    var expected_commands: usize = 0;

    // What the program writes itself, outside a frame: pixels sent and
    // images freed. Never fed to the terminals, which draw frames.
    var side: std.Io.Writer.Allocating = .init(gpa);
    defer side.deinit();
    // The images sent or freed this frame, whose placements the terminal
    // took down itself.
    var resent: std.ArrayList(u32) = .empty;
    defer resent.deinit(gpa);

    var frames: usize = 0;
    while (frames < 6 and !smith.eos()) : (frames += 1) {
        const previous = try gpa.dupe(Shown, showing.items);
        defer gpa.free(previous);
        resent.clearRetainingCapacity();

        var ops: usize = 0;
        const count = smith.valueRangeAtMost(u8, 1, 8);
        while (ops < count) : (ops += 1) {
            switch (smith.valueRangeAtMost(u8, 0, 6)) {
                0, 1 => {
                    // A new picture, or the same one moved.
                    const shown: Shown = .{
                        .image = smith.valueRangeAtMost(u32, 1, 4),
                        .placement = smith.valueRangeAtMost(u32, 1, 3),
                        .rect = randomRect(smith, size.cols, size.rows),
                        .under = smith.value(bool),
                        .order = .{
                            .layer = smith.valueRangeAtMost(i32, -2, 2),
                            .z = smith.valueRangeAtMost(i32, -2, 2),
                            .sibling = smith.valueRangeAtMost(i32, -2, 2),
                        },
                    };
                    for (showing.items) |*held| {
                        if (held.image == shown.image and held.placement == shown.placement) {
                            held.* = shown;
                            break;
                        }
                    } else try showing.append(gpa, shown);
                },
                2 => {
                    if (showing.items.len != 0) _ = showing.swapRemove(smith.index(showing.items.len));
                },
                3 => switch (smith.valueRangeAtMost(u8, 0, 2)) {
                    // Pixels sent under an id, perhaps one on screen, which
                    // the terminal takes down while they land.
                    0 => {
                        const id = smith.valueRangeAtMost(u32, 1, 4);
                        const px = [_]u8{ 0, 0, 0, 255 } ** 4;
                        _ = try h.screen.layers.transmit(gpa, &side.writer, id, &px, .{
                            .width = 2,
                            .height = 2,
                            .answer = smith.value(bool),
                            .now_ms = @intCast(frames * 16),
                        });
                        try resent.append(gpa, id);
                    },
                    // The terminal answers for an image, or refuses it.
                    1 => h.screen.layers.ack(.{
                        .id = smith.valueRangeAtMost(u32, 1, 4),
                        .message = if (smith.value(bool)) "OK" else "ENOENT",
                    }),
                    // An image freed: its placements go with it, and nothing
                    // is left for the frame to delete.
                    2 => {
                        const id = smith.valueRangeAtMost(u32, 1, 4);
                        try h.screen.layers.free(&side.writer, id);
                        try resent.append(gpa, id);
                        var i: usize = 0;
                        while (i < showing.items.len) {
                            if (showing.items[i].image == id) {
                                _ = showing.swapRemove(i);
                            } else i += 1;
                        }
                    },
                    else => unreachable,
                },
                4 => {
                    // A frame of animation: every picture a cell along.
                    for (showing.items) |*held| {
                        held.rect.col = @intCast(@min(held.rect.col + 1, size.cols - 1));
                        held.rect.cols = @intCast(@min(held.rect.cols, size.cols - held.rect.col));
                    }
                },
                5, 6 => try operate(&h, smith, every_op),
                else => unreachable,
            }
        }
        for (showing.items) |p| try h.screen.layers.declare(gpa, p.asLayer());
        try checkGrid(&h.screen);

        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        const bytes = h.out.written();
        try testing.expectEqual(bytes.len, stats.bytes);

        // The text pass is finished before the first graphics command.
        const first = std.mem.indexOf(u8, bytes, "\x1b_G") orelse bytes.len;
        try before_graphics.feed(bytes[0..first]);
        try term.expectScreensEqual(&h.screen, before_graphics.screen());
        try before_graphics.feed(bytes[first..]);
        try whole.feed(bytes);
        try term.expectScreensEqual(&h.screen, whole.screen());

        // Every graphics command is counted, and none is written for a
        // terminal without the protocol.
        const commands = std.mem.count(u8, bytes, "\x1b_G");
        try testing.expectEqual(commands, stats.placements);
        if (!h.caps.kitty_graphics) try testing.expectEqual(@as(usize, 0), commands);
        expected_commands += commands;
        try testing.expectEqual(expected_commands, whole.graphics.items.len);

        // A deletion names one placement, keeps the bytes, and happens only
        // for a picture that left -- not for one whose image was sent again
        // or freed, which the terminal took down itself.
        var left: usize = 0;
        for (previous) |was| {
            if (std.mem.indexOfScalar(u32, resent.items, was.image) != null) continue;
            for (showing.items) |now| {
                if (now.image == was.image and now.placement == was.placement) break;
            } else left += 1;
        }
        const deletions = std.mem.count(u8, bytes, "a=d");
        try testing.expectEqual(if (h.caps.kitty_graphics) left else 0, deletions);
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=a"));
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=A"));
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=N"));

        // Declared again unchanged, the frame writes nothing at all.
        for (showing.items) |p| try h.screen.layers.declare(gpa, p.asLayer());
        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);
        for (showing.items) |p| try h.screen.layers.declare(gpa, p.asLayer());
        h.screen.damageAll();
        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);
    }

    // Everything taken down: one deletion each, then nothing.
    const remaining = showing.items.len;
    showing.clearRetainingCapacity();
    h.out.clearRetainingCapacity();
    const down = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
    try testing.expectEqual(if (h.caps.kitty_graphics) remaining else 0, std.mem.count(u8, h.out.written(), "a=d"));
    try testing.expectEqual(@as(u32, @intCast(if (h.caps.kitty_graphics) remaining else 0)), down.placements);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, h.caps)).bytes);
    try testing.expectEqual(@as(usize, 0), h.screen.layers.count());
}

test "pictures placed, moved, stacked and taken down keep every frame idempotent and out of the text pass" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try imageRoundTrip(gpa, smith);
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
