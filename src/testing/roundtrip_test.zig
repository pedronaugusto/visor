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

const cellmod = @import("../cell.zig");
const geom = @import("../geom.zig");
const render = @import("../render.zig");
const textmod = @import("../text.zig");
const term = @import("../term.zig");
const Caps = @import("../caps.zig").Caps;
const Cell = cellmod.Cell;
const Renderer = render.Renderer;
const Screen = @import("../screen.zig").Screen;
const Term = term.Term;

/// What the generators drew, counted.
const Spread = @import("spread").Spread;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Source = shakedown.Source;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The graphemes the generator draws from: ASCII, a combining pair, a wide
/// one, a cluster too long to live in a cell, and the one the two width
/// models disagree about, and the ones a terminal measuring clusters would join
/// to the cell beside them.
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
    // Clusters a terminal measuring clusters joins to the cell on their left
    // when the break rules say so: two regional indicators, a skin-tone
    // modifier beside the emoji it modifies, a spacing mark beside anything.
    "\u{1f1e6}",
    "\u{1f1e7}",
    "\u{1f44d}",
    "\u{1f3fb}",
    "\u{915}",
    "\u{903}",
};

/// The styles it draws from: enough to exercise every arm of the colour
/// union, both halves of the bold-and-dim off code, and both scripts and the
/// way back from each.
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
    .{ .script = .superscript },
    .{ .script = .subscript, .overline = true, .fg = .palette(201) },
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
    /// The pictures shown beside the screen.
    layers: layer.Layers,
    /// Where the generator's draws are counted, for the test that proves the
    /// cases explore; null everywhere else.
    tally: ?*Tally = null,

    fn init(gpa: Allocator, size: geom.Size, method: textmod.Method) !Harness {
        var s: Screen = try .init(gpa, size);
        errdefer s.deinit();
        s.method = method;
        var r: Renderer = try .init(gpa, size);
        errdefer r.deinit();
        return .{
            .gpa = gpa,
            .layers = .init(gpa),
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
        h.screen.deinit();
        h.layers.deinit();
        h.renderer.deinit();
        h.out.deinit();
        h.* = undefined;
    }

    /// One frame: draw, feed the bytes to a terminal that started blank and
    /// was fed every frame before it, and compare.
    fn frame(h: *Harness, t: *Term) !Renderer.Stats {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        try t.feed(h.out.written());
        try term.expectScreensEqual(&h.screen, t.screen());
        return stats;
    }
};

/// Every invariant the grid promises, checked over the whole of it.
fn checkGrid(s: *const Screen) !void {
    for (0..s.dimensions().rows) |r| {
        var col: u16 = 0;
        while (col < s.dimensions().cols) {
            const c = s.own_cells[s.index(col, @intCast(r))];
            try testing.expect(c.shape.reserved == 0);
            if (c.text.isPooled()) {
                try testing.expect(s.graphemes.holds(c.text.offset().?, c.text.length()));
            }
            if (c.link.index()) |li| try testing.expect(s.links.contains(li));
            if (c.isTail()) {
                // A tail is its head's, content and all: the renderer never
                // writes one, and the terminal makes its own from the head.
                const head = s.headOf(col, @intCast(r)) orelse return error.OrphanTail;
                var own = s.own_cells[s.index(head.col, head.row)];
                own.shape.kind = .spacer_tail;
                try testing.expect(c.eql(own));
                col += 1;
                continue;
            }
            // A head's block is inside the grid and made of its own tails,
            // so the columns of a row add up to the row.
            const span = c.width();
            try testing.expect(col + span <= s.dimensions().cols);
            try testing.expect(r + c.rows() <= s.dimensions().rows);
            for (0..c.rows()) |dr| {
                for (0..span) |dc| {
                    if (dr == 0 and dc == 0) continue;
                    const t = s.own_cells[s.index(@intCast(col + dc), @intCast(r + dr))];
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
fn checkDamage(s: *const Screen, before: []const cellmod.internal.StoredCell) !void {
    for (0..s.dimensions().rows) |r| {
        const span = s.damage.row(@intCast(r));
        var col: u16 = 0;
        while (col < s.dimensions().cols) : (col += 1) {
            const i = s.index(col, @intCast(r));
            const changed = !s.own_cells[i].eql(before[i]);
            const named = if (span) |sp| col >= sp.first and col <= sp.last else false;
            if (changed and !named) return error.DamageUnderReported;
        }
    }
}

/// What the generators drew over a run of cases, one `Spread` a
/// question: the evidence that the properties explore the grid rather than
/// replaying one small case.
const Tally = struct {
    /// The grid's width, at the start and after every resize.
    cols: Spread = .{},
    /// Its height, the same.
    rows: Spread = .{},
    /// Which grid operation, `operate`'s switch.
    ops: Spread = .{},
    /// Which grapheme a write took.
    graphemes: Spread = .{},
    /// How many frames (or resize steps) one input ran to.
    frames: Spread = .{},
    /// Which picture operation, the image property's switch.
    picture_ops: Spread = .{},
    /// How far down the terminal the prompt left an inline screen.
    prompt: Spread = .{},
    /// How many times an inline screen changed size.
    resizes: Spread = .{},
};

/// One random operation on the grid.
fn operate(h: *Harness, src: *Source) !void {
    const s = &h.screen;
    const cols = s.dimensions().cols;
    const rows = s.dimensions().rows;
    const graphemes = &alphabet;
    const op = gen.intRange(src, u8, 0, 7);
    if (h.tally) |tl| tl.ops.add(op);
    switch (op) {
        0, 1, 2 => {
            const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
            const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
            const which_grapheme = gen.intRange(src, usize, 0, graphemes.len - 1);
            if (h.tally) |tl| tl.graphemes.add(which_grapheme);
            const g = graphemes[which_grapheme];
            const style = styles[gen.intRange(src, usize, 0, styles.len - 1)];
            const which = gen.intRange(src, usize, 0, uris.len - 1);
            const link = try s.link(uris[which], params[which]);
            try s.write(col, row, g, style, link);
        },
        7 => {
            const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
            const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
            const g = graphemes[gen.intRange(src, usize, 0, graphemes.len - 1)];
            const style = styles[gen.intRange(src, usize, 0, styles.len - 1)];
            _ = try s.writeScaled(col, row, g, style, .none, gen.intRange(src, u3, 2, 3));
        },
        3 => {
            const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
            const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
            try s.writeOwnedCell(col, row, .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)]));
        },
        4 => {
            const rect = randomRect(src, cols, rows);
            try s.fill(rect, .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)]));
        },
        5 => {
            const rect = randomRect(src, cols, rows);
            s.scroll(rect, gen.intRange(src, i32, -3, 3));
        },
        6 => {
            s.cursor.visible = gen.boolean(src);
            s.cursor.col = @intCast(gen.intRange(src, usize, 0, cols - 1));
            s.cursor.row = @intCast(gen.intRange(src, usize, 0, rows - 1));
            s.cursor.shape = @fromBackingInt(@intCast(gen.intRange(src, u8, 0, 6)));
        },
        else => unreachable,
    }
}

/// A rectangle somewhere inside the grid.
fn randomRect(src: *Source, cols: u16, rows: u16) geom.Rect {
    const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
    const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
    return .{
        .col = col,
        .row = row,
        .cols = @intCast(gen.intRange(src, usize, 0, (cols - col) - 1) + 1),
        .rows = @intCast(gen.intRange(src, usize, 0, (rows - row) - 1) + 1),
    };
}

/// How the terminal on the other end measures, given how the renderer was
/// told to. A terminal told every width measures by codepoint on its own,
/// which is the case the telling exists for.
fn terminalMethod(method: textmod.Method) textmod.Method {
    return if (method == .explicit) .wcwidth else method;
}

/// The four properties, once, over a generated sequence of frames.
fn roundTrip(gpa: Allocator, src: *Source, method: textmod.Method, tally: ?*Tally) !void {
    const size: geom.Size = .{
        .cols = gen.intRange(src, u16, 1, 24),
        .rows = gen.intRange(src, u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    h.tally = tally;
    if (tally) |tl| {
        tl.cols.add(size.cols);
        tl.rows.add(size.rows);
    }
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(terminalMethod(method));

    const before = try gpa.alloc(cellmod.internal.StoredCell, h.screen.own_cells.len);
    defer gpa.free(before);

    var frames: usize = 0;
    while (frames < 6 and src.more(7)) : (frames += 1) {
        @memcpy(before, h.screen.own_cells);
        h.screen.damage.clear();

        var ops: usize = 0;
        const count = gen.intRange(src, u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, src);

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
    if (tally) |tl| tl.frames.add(frames);

    // A repaint recovers from any state the renderer drifted into.
    corrupt(&h.renderer, src);
    h.renderer.repaint();
    _ = try h.frame(&t);
    try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);

    // And a terminal given one full repaint of the final screen holds the
    // same thing as the terminal that was given every frame.
    var fresh: Term = try .init(gpa, size);
    defer fresh.deinit();
    fresh.setMethod(terminalMethod(method));
    var once: Renderer = try .init(gpa, size);
    defer once.deinit();
    once.repaint();
    h.out.clearRetainingCapacity();
    h.screen.damageAll();
    _ = try once.draw(&h.out.writer, &h.screen, null, h.caps);
    try fresh.feed(h.out.written());
    try term.expectScreensEqual(t.screen(), fresh.screen());
}

/// Puts the renderer's idea of the terminal out of step with it, the way a
/// dropped write or a program writing to the terminal behind the renderer's
/// back would.
fn corrupt(r: *Renderer, src: *Source) void {
    var i: usize = 0;
    const count = gen.intRange(src, u8, 1, 8);
    while (i < count and r.prev.len != 0) : (i += 1) {
        r.prev[gen.intRange(src, usize, 0, r.prev.len - 1)] = .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)]);
    }
    r.style = styles[gen.intRange(src, usize, 0, styles.len - 1)];
    r.own_cursor = null;
    r.shown = null;
}

test "the round trip holds against a terminal measuring by codepoint" {
    try checked(roundTrip, .{textmod.Method.wcwidth}, null);
}

test "the round trip holds against a terminal measuring by cluster" {
    try checked(roundTrip, .{textmod.Method.unicode}, null);
}

test "the round trip holds against a terminal told every width" {
    try checked(roundTrip, .{textmod.Method.explicit}, null);
}

/// The properties across resizes: the terminal takes a new size first and
/// keeps whatever fitted, the program hears of it afterwards, and frames
/// drawn at the old size land on the terminal after it changed. The next
/// frame at the size the program was told must leave the terminal showing
/// exactly the screen, the rows it has nothing new to write included. The
/// frames draw everything the other properties do, clusters the width
/// models disagree about and text drawn at a scale among it.
fn roundTripResize(gpa: Allocator, src: *Source, method: textmod.Method, tally: ?*Tally) !void {
    var size: geom.Size = .{
        .cols = gen.intRange(src, u16, 1, 24),
        .rows = gen.intRange(src, u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    h.tally = tally;
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(terminalMethod(method));
    h.out.clearRetainingCapacity();
    try h.renderer.enter(&h.out.writer, h.caps, .alt, .{});
    try t.feed(h.out.written());

    try scribble(&h, src);
    _ = try h.frame(&t);

    const steps = gen.intRange(src, u8, 1, 5);
    if (tally) |tl| tl.frames.add(steps);
    for (0..steps) |step| {
        const to = nextSize(src, size);
        if (tally) |tl| {
            tl.cols.add(to.cols);
            tl.rows.add(to.rows);
        }
        var hops = gen.intRange(src, u8, 0, 3);
        const told_each = gen.boolean(src);
        // The terminal passes through sizes on the way, frames drawn at the
        // size the program knows landing after each; the program hears of
        // every one or only of the last.
        while (hops > 0) : (hops -= 1) {
            const mid = nextSize(src, size);
            try stale(&h, &t, src, mid);
            if (told_each) {
                try h.screen.resize(mid);
                try h.renderer.resize(mid);
            }
        }
        try stale(&h, &t, src, to);
        try h.screen.resize(to);
        try h.renderer.resize(to);
        try checkGrid(&h.screen);
        size = to;

        // A frame now, or not until the next size; always after the last.
        if (step + 1 == steps or gen.intRange(src, u8, 0, 3) != 0) {
            try scribble(&h, src);
            _ = try h.frame(&t);
            try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
            h.screen.damageAll();
            try testing.expectEqual(@as(usize, 0), (try h.frame(&t)).bytes);
        }
    }
}

/// The terminal resized to `to`, and now and then a frame drawn at the size
/// the program still knows landing after it.
fn stale(h: *Harness, t: *Term, src: *Source, to: geom.Size) !void {
    if (gen.boolean(src)) {
        try scribble(h, src);
        h.out.clearRetainingCapacity();
        _ = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        try t.resize(to);
        try t.feed(h.out.written());
    } else try t.resize(to);
}

/// What a program draws after a resize: now and then its whole layout again
/// from nothing, then some operations.
fn scribble(h: *Harness, src: *Source) !void {
    if (gen.boolean(src)) h.screen.clear();
    var ops: usize = 0;
    const count = gen.intRange(src, u8, 1, 12);
    while (ops < count) : (ops += 1) try operate(h, src);
}

/// A size in the generator's range, reached from `from` the way a window's
/// edge moves: both ways, the width alone, or the height alone.
fn nextSize(src: *Source, from: geom.Size) geom.Size {
    const cols = gen.intRange(src, u16, 1, 24);
    const rows = gen.intRange(src, u16, 1, 12);
    return switch (gen.intRange(src, u8, 0, 2)) {
        0 => .{ .cols = cols, .rows = rows },
        1 => .{ .cols = cols, .rows = from.rows },
        else => .{ .cols = from.cols, .rows = rows },
    };
}

test "the round trip holds across resizes against a terminal measuring by codepoint" {
    try checked(roundTripResize, .{textmod.Method.wcwidth}, null);
}

test "the round trip holds across resizes against a terminal measuring by cluster" {
    try checked(roundTripResize, .{textmod.Method.unicode}, null);
}

test "the round trip holds across resizes against a terminal told every width" {
    try checked(roundTripResize, .{textmod.Method.explicit}, null);
}

/// The rows of a terminal the inline screen occupies, compared with the
/// screen cell by cell the way `expectScreensEqual` does, from the row the
/// saved origin names.
fn expectRegionEqual(want: *const Screen, t: *const Term) !void {
    const got = t.screen();
    const origin = (t.savedCursor() orelse return error.NoOrigin).row;
    try testing.expect(origin + want.dimensions().rows <= got.dimensions().rows);
    var row: u16 = 0;
    while (row < want.dimensions().rows) : (row += 1) {
        var col: u16 = 0;
        while (col < want.dimensions().cols) : (col += 1) {
            const a = want.readCell(col, row).?;
            const b = got.readCell(col, origin + row).?;
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
fn roundTripInline(gpa: Allocator, src: *Source, method: textmod.Method, tally: ?*Tally) !void {
    const cols = gen.intRange(src, u16, 1, 24);
    const terminal_rows = gen.intRange(src, u16, 2, 16);
    const prompt = gen.intRange(src, u16, 0, terminal_rows - 1);
    var size: geom.Size = .{ .cols = cols, .rows = gen.intRange(src, u16, 1, terminal_rows) };
    if (tally) |tl| {
        tl.cols.add(size.cols);
        tl.rows.add(size.rows);
        tl.prompt.add(prompt);
    }

    var t: Term = try .init(gpa, .{ .cols = cols, .rows = terminal_rows });
    defer t.deinit();
    t.setMethod(terminalMethod(method));
    var i: u16 = 0;
    while (i < prompt) : (i += 1) try t.feed("$\r\n");

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    h.tally = tally;
    h.caps.scroll_detection = false;
    try h.renderer.enter(&h.out.writer, h.caps, .@"inline", .{});
    try t.feed(h.out.written());
    try expectRegionEqual(&h.screen, &t);

    var frames: usize = 0;
    while (frames < 6 and src.more(7)) : (frames += 1) {
        // Now and then the screen changes size, in rows or in columns; the
        // terminal is the same terminal, so the screen is never wider than
        // it.
        if (gen.intRange(src, u8, 0, 3) == 0) {
            size = .{
                .cols = gen.intRange(src, u16, 1, cols),
                .rows = gen.intRange(src, u16, 1, terminal_rows),
            };
            if (tally) |tl| tl.resizes.add(1);
            try h.screen.resize(size);
            try h.renderer.resize(size);
        }
        var ops: usize = 0;
        const count = gen.intRange(src, u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, src);
        try checkGrid(&h.screen);

        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        try testing.expectEqual(@as(u32, 0), stats.scrolled);
        try t.feed(h.out.written());
        try expectRegionEqual(&h.screen, &t);

        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);
    }

    if (tally) |tl| tl.frames.add(frames);

    // A repaint recovers, from the origin.
    corrupt(&h.renderer, src);
    h.renderer.repaint();
    h.out.clearRetainingCapacity();
    _ = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
    try t.feed(h.out.written());
    try expectRegionEqual(&h.screen, &t);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);

    // And the way out leaves the frame and puts the cursor below it.
    const origin = t.savedCursor().?.row;
    h.out.clearRetainingCapacity();
    try h.renderer.leave(&h.out.writer);
    try t.feed(h.out.written());
    try testing.expectEqual(@as(u16, 0), t.position().col);
    try testing.expectEqual(@min(origin + size.rows, @as(u16, terminal_rows) - 1), t.position().row);
}

test "the round trip holds for an inline screen measuring by codepoint" {
    try checked(roundTripInline, .{textmod.Method.wcwidth}, null);
}

test "the round trip holds for an inline screen measuring by cluster" {
    try checked(roundTripInline, .{textmod.Method.unicode}, null);
}

//=========================================================================
// Pictures: the same idea over the layers, where the property is that a
// frame with nothing new in it writes nothing, and that the text pass never
// writes a graphics command.
//=========================================================================

const layer = @import("../layer.zig");

/// A picture the program is showing, as the program keeps it between
/// frames; declared again every frame, because that is how the layers work.
const Shown = struct {
    image: layer.ImageId,
    placement: layer.PlacementId,
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
fn imageRoundTrip(gpa: Allocator, src: *Source, tally: ?*Tally) !void {
    const size: geom.Size = .{
        .cols = gen.intRange(src, u16, 2, 24),
        .rows = gen.intRange(src, u16, 2, 12),
    };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    h.tally = tally;
    if (tally) |tl| {
        tl.cols.add(size.cols);
        tl.rows.add(size.rows);
    }
    h.caps.kitty_graphics = gen.intRange(src, u8, 0, 3) != 0;
    h.caps.scroll_detection = false;

    var run: PictureRun = try .init(gpa, &h, src, tally);
    defer run.deinit();

    while (run.frames < 6 and src.more(7)) : (run.frames += 1) {
        const previous = try gpa.dupe(Shown, run.showing.items);
        defer gpa.free(previous);
        run.resent.clearRetainingCapacity();

        var ops: usize = 0;
        const count = gen.intRange(src, u8, 1, 8);
        while (ops < count) : (ops += 1) try run.pictureOp();
        for (run.showing.items) |p| try h.layers.declare(p.asLayer());
        try checkGrid(&h.screen);
        try run.checkFrame(previous);
        try run.checkSettled();
    }

    if (tally) |tl| tl.frames.add(run.frames);

    // Everything taken down: one deletion each, then nothing.
    const remaining = run.showing.items.len;
    run.showing.clearRetainingCapacity();
    h.out.clearRetainingCapacity();
    const down = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
    try testing.expectEqual(if (h.caps.kitty_graphics) remaining else 0, std.mem.count(u8, h.out.written(), "a=d"));
    try testing.expectEqual(@as(u32, @intCast(if (h.caps.kitty_graphics) remaining else 0)), down.placements);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);
    try testing.expectEqual(@as(usize, 0), h.layers.count());
}

/// One run of pictures: what the program shows, what it wrote outside a
/// frame, and the two terminals the frames are read back by.
const PictureRun = struct {
    gpa: Allocator,
    h: *Harness,
    src: *Source,
    tally: ?*Tally,
    /// Given every byte.
    whole: Term,
    /// Given each frame only up to its first graphics command, which must
    /// already be the whole picture of the text.
    before_graphics: Term,
    showing: std.ArrayList(Shown) = .empty,
    /// What the program writes itself, outside a frame: pixels sent and
    /// images freed. Never fed to the terminals, which draw frames.
    side: std.Io.Writer.Allocating,
    /// The images sent or freed this frame, whose placements the terminal
    /// took down itself.
    resent: std.ArrayList(layer.ImageId) = .empty,
    expected_commands: usize = 0,
    frames: usize = 0,

    fn init(gpa: Allocator, h: *Harness, src: *Source, tally: ?*Tally) !PictureRun {
        const size = h.screen.dimensions();
        var whole: Term = try .init(gpa, size);
        errdefer whole.deinit();
        whole.setMethod(.unicode);
        var before_graphics: Term = try .init(gpa, size);
        before_graphics.setMethod(.unicode);
        return .{
            .gpa = gpa,
            .h = h,
            .src = src,
            .tally = tally,
            .whole = whole,
            .before_graphics = before_graphics,
            .side = .init(gpa),
        };
    }

    fn deinit(run: *PictureRun) void {
        run.whole.deinit();
        run.before_graphics.deinit();
        run.showing.deinit(run.gpa);
        run.side.deinit();
        run.resent.deinit(run.gpa);
        run.* = undefined;
    }

    /// One thing the program does to its pictures, or to the text.
    fn pictureOp(run: *PictureRun) !void {
        const src = run.src;
        const size = run.h.screen.dimensions();
        const picture_op = gen.intRange(src, u8, 0, 6);
        if (run.tally) |tl| tl.picture_ops.add(picture_op);
        switch (picture_op) {
            0, 1 => {
                // A new picture, or the same one moved.
                const shown: Shown = .{
                    .image = .fromRaw(gen.intRange(src, u32, 1, 4)),
                    .placement = .fromRaw(gen.intRange(src, u32, 1, 3)),
                    .rect = randomRect(src, size.cols, size.rows),
                    .under = gen.boolean(src),
                    .order = .{
                        .layer = gen.intRange(src, i32, -2, 2),
                        .z = gen.intRange(src, i32, -2, 2),
                        .sibling = gen.intRange(src, i32, -2, 2),
                    },
                };
                for (run.showing.items) |*held| {
                    if (held.image == shown.image and held.placement == shown.placement) {
                        held.* = shown;
                        break;
                    }
                } else try run.showing.append(run.gpa, shown);
            },
            2 => {
                if (run.showing.items.len != 0) _ = run.showing.swapRemove(gen.intRange(src, usize, 0, run.showing.items.len - 1));
            },
            3 => try run.imageOp(),
            4 => {
                // A frame of animation: every picture a cell along.
                for (run.showing.items) |*held| {
                    held.rect.col = @intCast(@min(held.rect.col + 1, size.cols - 1));
                    held.rect.cols = @intCast(@min(held.rect.cols, size.cols - held.rect.col));
                }
            },
            5, 6 => try operate(run.h, src),
            else => unreachable,
        }
    }

    /// Something done to an image rather than to a placement of it.
    fn imageOp(run: *PictureRun) !void {
        const src = run.src;
        const layers = &run.h.layers;
        switch (gen.intRange(src, u8, 0, 2)) {
            // Pixels sent under an id, perhaps one on screen, which the
            // terminal takes down while they land.
            0 => {
                const id: layer.ImageId = .fromRaw(gen.intRange(src, u32, 1, 4));
                const px = [_]u8{
                    0, 0, 0, 255,
                    0, 0, 0, 255,
                    0, 0, 0, 255,
                    0, 0, 0, 255,
                };
                _ = try layers.transmit(&run.side.writer, id, &px, .{
                    .width = .fromRaw(2),
                    .height = .fromRaw(2),
                    .answer = gen.boolean(src),
                    .now = ms(@intCast(run.frames * 16)),
                });
                try run.resent.append(run.gpa, id);
            },
            // The terminal answers for an image, or refuses it.
            1 => layers.ack(.{
                .id = .fromRaw(gen.intRange(src, u32, 1, 4)),
                .message = if (gen.boolean(src)) "OK" else "ENOENT",
            }),
            // An image freed: its placements go with it, and nothing is
            // left for the frame to delete.
            2 => {
                const id: layer.ImageId = .fromRaw(gen.intRange(src, u32, 1, 4));
                try layers.deleteImage(&run.side.writer, id);
                try run.resent.append(run.gpa, id);
                var i: usize = 0;
                while (i < run.showing.items.len) {
                    if (run.showing.items[i].image == id) {
                        _ = run.showing.swapRemove(i);
                    } else i += 1;
                }
            },
            else => unreachable,
        }
    }

    /// The frame drawn and read back: the text whole before the first
    /// graphics command, every command counted, and a deletion for each
    /// picture that left and for nothing else.
    fn checkFrame(run: *PictureRun, previous: []const Shown) !void {
        const h = run.h;
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        const bytes = h.out.written();
        try testing.expectEqual(bytes.len, stats.bytes);

        // The text pass is finished before the first graphics command.
        const first = std.mem.find(u8, bytes, "\x1b_G") orelse bytes.len;
        try run.before_graphics.feed(bytes[0..first]);
        try term.expectScreensEqual(&h.screen, run.before_graphics.screen());
        try run.before_graphics.feed(bytes[first..]);
        try run.whole.feed(bytes);
        try term.expectScreensEqual(&h.screen, run.whole.screen());

        // Every graphics command is counted, and none is written for a
        // terminal without the protocol.
        const commands = std.mem.count(u8, bytes, "\x1b_G");
        try testing.expectEqual(commands, stats.placements);
        if (!h.caps.kitty_graphics) try testing.expectEqual(@as(usize, 0), commands);
        run.expected_commands += commands;
        try testing.expectEqual(run.expected_commands, run.whole.graphics().len);

        // A deletion names one placement, keeps the bytes, and happens only
        // for a picture that left -- not for one whose image was sent again
        // or freed, which the terminal took down itself.
        var left: usize = 0;
        for (previous) |was| {
            if (std.mem.findScalar(layer.ImageId, run.resent.items, was.image) != null) continue;
            for (run.showing.items) |now| {
                if (now.image == was.image and now.placement == was.placement) break;
            } else left += 1;
        }
        const deletions = std.mem.count(u8, bytes, "a=d");
        try testing.expectEqual(if (h.caps.kitty_graphics) left else 0, deletions);
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=a"));
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=A"));
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bytes, "d=N"));
    }

    /// Declared again unchanged, the frame writes nothing at all, damaged
    /// or not.
    fn checkSettled(run: *PictureRun) !void {
        const h = run.h;
        for (run.showing.items) |p| try h.layers.declare(p.asLayer());
        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);
        for (run.showing.items) |p| try h.layers.declare(p.asLayer());
        h.screen.damageAll();
        h.out.clearRetainingCapacity();
        try testing.expectEqual(@as(usize, 0), (try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps)).bytes);
    }
};

test "pictures placed, moved, stacked and taken down keep every frame idempotent and out of the text pass" {
    try checked(imageRoundTrip, .{}, null);
}

//=========================================================================
// The cases explore. Each property is run over its cases with its
// draws counted, and the counts must cover the whole of every range the
// property asks for: every size from one cell to the largest, every
// operation, every grapheme, and runs of more than one frame. A generator
// that answered every case with the same small one fails here, not
// silently.
//=========================================================================

const counting_seed = 0x5eed;

/// `property` over the cases `check` draws, with its draws counted when there
/// is a `tally`.
fn checked(comptime property: anytype, args: anytype, tally: ?*Tally) !void {
    const Run = struct { args: @TypeOf(args), tally: ?*Tally };
    const body = struct {
        fn run(r: Run, case: *shakedown.Case) !void {
            try @call(.auto, property, .{ testing.allocator, case.source } ++ r.args ++ .{r.tally});
        }
    }.run;
    // Counted runs use one seed: what they assert is about the generators, so
    // the cases are the same on every run.
    try shakedown.check(testing.allocator, Run{ .args = args, .tally = tally }, body, .{ .seed = if (tally != null) counting_seed else null });
}

test "the round trip's cases draw every size, every operation and every grapheme" {
    // The assertions are about the cases `check` draws, not the fuzzer's.
    if (@import("builtin").fuzz) return error.SkipZigTest;
    var t: Tally = .{};
    try checked(roundTrip, .{textmod.Method.unicode}, &t);
    try testing.expect(t.cols.covers(1, 24));
    try testing.expect(t.rows.covers(1, 12));
    try testing.expect(t.ops.covers(0, 7));
    try testing.expect(t.graphemes.covers(0, alphabet.len - 1));
    try testing.expect(t.frames.covers(1, 6));
}

test "the inline round trip's cases draw every width, prompt and height, and resizes" {
    // The assertions are about the cases `check` draws, not the fuzzer's.
    if (@import("builtin").fuzz) return error.SkipZigTest;
    var t: Tally = .{};
    try checked(roundTripInline, .{textmod.Method.unicode}, &t);
    try testing.expect(t.cols.covers(1, 24));
    try testing.expect(t.rows.covers(1, 16));
    try testing.expect(t.prompt.covers(0, 15));
    try testing.expect(t.ops.covers(0, 7));
    try testing.expect(t.frames.covers(1, 6));
    // And the screen changes size in about one frame in four.
    try testing.expect(t.resizes.count > (shakedown.CheckOptions{}).cases / 2);
}

test "the resize round trip's cases draw every size and several steps" {
    // The assertions are about the cases `check` draws, not the fuzzer's.
    if (@import("builtin").fuzz) return error.SkipZigTest;
    var t: Tally = .{};
    try checked(roundTripResize, .{textmod.Method.unicode}, &t);
    try testing.expect(t.cols.covers(1, 24));
    try testing.expect(t.rows.covers(1, 12));
    try testing.expect(t.ops.covers(0, 7));
    try testing.expect(t.graphemes.covers(0, alphabet.len - 1));
    try testing.expect(t.frames.covers(1, 5));
}

test "the picture property's cases draw every size and every picture operation" {
    // The assertions are about the cases `check` draws, not the fuzzer's.
    if (@import("builtin").fuzz) return error.SkipZigTest;
    var t: Tally = .{};
    try checked(imageRoundTrip, .{}, &t);
    try testing.expect(t.cols.covers(2, 24));
    try testing.expect(t.rows.covers(2, 12));
    try testing.expect(t.picture_ops.covers(0, 6));
    try testing.expect(t.ops.covers(0, 7));
    try testing.expect(t.frames.covers(1, 6));
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

test "a raised or lowered cell reaches the terminal raised or lowered" {
    const gpa = testing.allocator;
    const size: geom.Size = .{ .cols = 6, .rows = 2 };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    var t: Term = try .init(gpa, size);
    defer t.deinit();
    t.setMethod(.unicode);

    try h.screen.write(0, 0, "x", .{ .script = .superscript }, .none);
    try h.screen.write(1, 0, "2", .{ .script = .subscript, .bold = true }, .none);
    try h.screen.write(2, 0, "y", .{}, .none);
    try h.screen.write(0, 1, "z", .{ .script = .subscript, .overline = true }, .none);
    _ = try h.frame(&t);
    try testing.expect(t.screen().readCell(0, 0).?.style.script == .superscript);

    // And back to the baseline on the next frame.
    try h.screen.write(0, 0, "x", .{}, .none);
    try h.screen.write(1, 0, "2", .{ .bold = true }, .none);
    _ = try h.frame(&t);
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
    _ = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);

    const link = try h.screen.link("https://ziglang.org", "");
    try h.screen.write(0, 0, "a", .{ .bold = true }, link);
    h.screen.damageAll();
    h.out.clearRetainingCapacity();
    const after = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
    try testing.expectEqual(@as(usize, 0), after.bytes);
}

/// A test's clock reading, in milliseconds.
fn ms(n: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_ms };
}
