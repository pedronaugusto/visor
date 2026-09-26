//! The round trip run a second time, against an emulator that is not ours.
//!
//! `Term` ships with this package, so a bug in `Term` can hide the same bug
//! in `draw`: the two were written by the same hand from the same reading of
//! the same specifications, and a property that compares them agrees with
//! itself. This build compares the renderer against a terminal written by
//! someone else -- the one inside a shipping terminal emulator, read through
//! its own grid rather than through a formatted dump. Where the two
//! disagree, the emulator is right and this package is wrong.
//!
//! The same four properties as the suite inside the package, over the same
//! committed corpus, read by column:
//!
//! - **The terminal shows the screen.** Every column, the covered column of
//!   a wide cluster included, its grapheme, its width, its style and its
//!   link.
//! - **Drawing again writes nothing.**
//! - **A repaint recovers from anything.**
//! - **Incremental equals a repaint.**
//!
//! And twice, once with the terminal measuring by codepoint and once with it
//! in mode 2027 measuring whole clusters, because the rule that repaints a
//! drifting row exists for the case where the two models disagree.
//!
//! Then the same comparison across resizes, the emulator resizing its own
//! grid the way it does for a window and frames at the old size landing
//! after it, with pictures placed across them and checked where the
//! emulator has them; and the probe's questions put to the emulator and its
//! answers read back.
//!
//! This file is a module of its own. Nothing in the package imports it, and
//! the dependency it needs is lazy, so a consumer of `visor` never fetches a
//! terminal emulator.

const std = @import("std");
const visor = @import("visor");
const vt = @import("ghostty-vt");
const corpus = @import("corpus");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const testing = std.testing;

/// The graphemes the generator draws from: ASCII, a combining pair, a wide
/// one, a cluster too long to live in a cell, and the ones the two width
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
/// combine, so that what it checks is where rows and cells end up across a
/// resize and not how a cluster is measured, which the properties above
/// are for.
const resize_alphabet = [_][]const u8{ "a", "b", " ", "~", "\u{e9}", "\u{4e2d}", "\u{ff21}" };

/// The styles it draws from: enough to exercise every arm of the colour
/// union and both halves of the bold-and-dim off code.
const styles = [_]visor.Style{
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

//=========================================================================
// The second emulator.
//=========================================================================

/// A terminal that is not ours, fed the bytes and read by column.
const Oracle = struct {
    gpa: Allocator,
    tiny: vt.TinyIo,
    term: vt.Terminal,

    /// What one column holds, in terms this package can compare.
    const Read = struct {
        /// The grapheme, written into the caller's buffer.
        text: []const u8,
        /// How the terminal counts the column.
        wide: vt.Cell.Wide,
        /// The style the terminal has on it.
        style: vt.Style,
        /// The link on it, or null. Borrowed from the terminal's own page,
        /// so read before the next byte is fed.
        link: ?Hyperlink,
    };

    /// An OSC 8 target as the terminal keeps it: the URI, and the `id`
    /// parameter when one was given.
    const Hyperlink = struct {
        uri: []const u8,
        id: ?[]const u8,
    };

    fn init(gpa: Allocator, size: visor.Size, method: visor.Method) !*Oracle {
        // Boxed: `Terminal` keeps a `std.Io` that points at the `TinyIo`
        // beside it, so neither may move after this.
        const o = try gpa.create(Oracle);
        errdefer gpa.destroy(o);
        o.* = .{ .gpa = gpa, .tiny = .init, .term = undefined };
        o.term = try .init(o.tiny.io(), gpa, .{
            .cols = size.cols,
            .rows = size.rows,
            .max_scrollback_lines = 0,
        });
        // The width model, asked for the way a program asks for it. The
        // renderer's own `enter` writes exactly this sequence.
        if (method == .unicode) o.feed("\x1b[?2027h");
        return o;
    }

    fn deinit(o: *Oracle) void {
        const gpa = o.gpa;
        o.term.deinit(gpa);
        gpa.destroy(o);
    }

    /// The window resized: the terminal's grid changes size, which it does
    /// on its own and before any program hears of it.
    fn resize(o: *Oracle, size: visor.Size) !void {
        try o.term.resize(o.gpa, .{ .cols = size.cols, .rows = size.rows });
    }

    /// The bytes a frame wrote.
    fn feed(o: *Oracle, bytes: []const u8) void {
        var stream = o.term.vtStream();
        defer stream.deinit();
        stream.nextSlice(bytes);
    }

    /// One column, into the caller's buffer.
    fn read(o: *const Oracle, col: u16, row: u16, buf: []u8) !Read {
        const found = o.term.screens.active.pages.getCell(.{ .active = .{
            .x = col,
            .y = row,
        } }) orelse return error.ColumnMissing;

        var n: usize = 0;
        const first = found.cell.codepoint();
        // An empty cell and a cell holding a space are the same thing on a
        // terminal, and this package writes the space.
        n += std.unicode.utf8Encode(if (first == 0) ' ' else first, buf[n..]) catch
            return error.BadCodepoint;
        if (found.cell.hasGrapheme()) {
            if (found.node.page().lookupGrapheme(found.cell)) |rest| {
                for (rest) |cp| {
                    n += std.unicode.utf8Encode(cp, buf[n..]) catch
                        return error.BadCodepoint;
                }
            }
        }
        const page = found.node.page();
        const link: ?Hyperlink = if (page.lookupHyperlink(found.cell)) |id| blk: {
            const entry = page.hyperlink_set.get(page.memory, id);
            break :blk .{
                .uri = entry.uri.slice(page.memory),
                .id = switch (entry.id) {
                    .explicit => |s| s.slice(page.memory),
                    .implicit => null,
                },
            };
        } else null;
        return .{ .text = buf[0..n], .wide = found.cell.wide, .style = found.style(), .link = link };
    }
};

/// The `id` in an OSC 8 parameter list, or null when there is none or it is
/// empty, which a terminal treats as none.
fn idOf(list: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |pair| {
        if (!std.mem.startsWith(u8, pair, "id=")) continue;
        const value = pair[3..];
        return if (value.len == 0) null else value;
    }
    return null;
}

/// Whether the terminal's link is the one this package drew: the same URI,
/// and the same `id` or none on both sides. An implicit id is the
/// terminal's own number and is not compared.
fn linkAgrees(want: ?visor.Target, got: ?Oracle.Hyperlink) bool {
    const mine = want orelse return got == null;
    const theirs = got orelse return false;
    if (!std.mem.eql(u8, mine.uri, theirs.uri)) return false;
    const my_id = idOf(mine.params);
    if (my_id == null or theirs.id == null) return my_id == null and theirs.id == null;
    return std.mem.eql(u8, my_id.?, theirs.id.?);
}

/// How this package's kinds read on the other terminal.
///
/// `spacer_head` is a column this package left blank because a wide cluster
/// did not fit before the margin; it writes a space there rather than
/// wrapping, so the terminal sees an ordinary narrow cell and is right to.
fn wideOf(kind: visor.Cell.Kind) vt.Cell.Wide {
    return switch (kind) {
        .narrow, .spacer_head => .narrow,
        .wide => .wide,
        .spacer_tail => .spacer_tail,
    };
}

/// One of this package's colours in the other terminal's terms.
fn colorOf(color: visor.Color) vt.Style.Color {
    return switch (color.kind) {
        .default => .none,
        // The sixteen theme colours have their own short codes and the
        // palette has an index; the terminal stores both as an index,
        // because `38;5;1` and `31` name the same colour.
        .ansi => .{ .palette = @intFromEnum(color.toAnsi()) },
        .palette => .{ .palette = color.index() },
        .rgb => .{ .rgb = .{ .r = color.r, .g = color.g, .b = color.b } },
    };
}

/// Whether the terminal's style says what this package's style asked for.
fn styleAgrees(want: visor.Style, got: vt.Style) bool {
    if (!got.fg_color.eql(colorOf(want.fg))) return false;
    if (!got.bg_color.eql(colorOf(want.bg))) return false;
    if (!got.underline_color.eql(colorOf(want.underline_color))) return false;
    const f = got.flags;
    return f.bold == want.bold and
        f.faint == want.dim and
        f.italic == want.italic and
        f.blink == want.blink and
        f.inverse == want.reverse and
        f.invisible == want.hidden and
        f.strikethrough == want.strikethrough and
        f.overline == want.overline and
        @intFromEnum(f.underline) == @intFromEnum(want.underline);
}

/// Every column of the grid the terminal rebuilt, against the grid that was
/// drawn.
fn expectAgrees(screen: *const visor.Screen, o: *const Oracle) !void {
    var buf: [64]u8 = undefined;
    var row: u16 = 0;
    while (row < screen.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < screen.size.cols) : (col += 1) {
            const mine = screen.readCell(col, row).?;
            const theirs = try o.read(col, row, &buf);

            if (wideOf(mine.shape.kind) != theirs.wide) {
                std.debug.print(
                    "column {d},{d}: this package says {s}, the terminal says {s}\n",
                    .{ col, row, @tagName(mine.shape.kind), @tagName(theirs.wide) },
                );
                return error.WidthDisagrees;
            }

            // The covered column of a wide cluster draws nothing on either
            // side, and the two do not agree on what is written under it.
            if (mine.shape.kind == .spacer_tail) continue;

            const want = screen.textAt(col, row);
            if (!std.mem.eql(u8, want, theirs.text)) {
                std.debug.print(
                    "column {d},{d}: this package wrote '{f}', the terminal shows '{f}'\n",
                    .{ col, row, std.ascii.hexEscape(want, .lower), std.ascii.hexEscape(theirs.text, .lower) },
                );
                return error.TextDisagrees;
            }

            if (!styleAgrees(mine.style, theirs.style)) {
                std.debug.print(
                    "column {d},{d}: style disagrees\n  drawn: {any}\n  shown: {any}\n",
                    .{ col, row, mine.style, theirs.style },
                );
                return error.StyleDisagrees;
            }

            if (!linkAgrees(screen.target(mine.link), theirs.link)) {
                std.debug.print(
                    "column {d},{d}: link disagrees\n  drawn: {?any}\n  shown: {?any}\n",
                    .{ col, row, screen.target(mine.link), theirs.link },
                );
                return error.LinkDisagrees;
            }
        }
    }
}

//=========================================================================
// The property.
//=========================================================================

/// Everything one round needs.
const Harness = struct {
    gpa: Allocator,
    screen: visor.Screen,
    renderer: visor.Renderer,
    out: std.Io.Writer.Allocating,
    caps: visor.Caps,

    fn init(gpa: Allocator, size: visor.Size, method: visor.Method) !Harness {
        var s: visor.Screen = try .init(gpa, size);
        errdefer s.deinit(gpa);
        s.method = method;
        var r: visor.Renderer = try .init(gpa, size);
        errdefer r.deinit(gpa);
        return .{
            .gpa = gpa,
            .screen = s,
            .renderer = r,
            .out = .init(gpa),
            // Not `explicit_width` and not `scaled_text`: the emulator at
            // the pinned commit parses OSC 66 and acts on none of it, so a
            // frame that used the protocol would show nothing where the text
            // went, and the package's own emulator is what checks that path.
            .caps = .{
                .width_method = method,
                .osc8 = true,
                .truecolor = true,
                .sync = true,
                .scroll_detection = true,
                .rep = true,
            },
        };
    }

    fn deinit(h: *Harness) void {
        h.screen.deinit(h.gpa);
        h.renderer.deinit(h.gpa);
        h.out.deinit();
    }

    /// The alternate screen taken the way a program takes it.
    fn enter(h: *Harness, o: *Oracle) !void {
        h.out.clearRetainingCapacity();
        try h.renderer.enter(&h.out.writer, h.caps, .alt, .{});
        o.feed(h.out.written());
    }

    /// The program told of a new size: the grid and the renderer follow.
    fn resize(h: *Harness, size: visor.Size) !void {
        try h.screen.resize(h.gpa, size);
        try h.renderer.resize(h.gpa, size);
    }

    /// A frame drawn and not yet delivered: its bytes, which the caller
    /// feeds when it decides they arrive.
    fn render(h: *Harness) ![]const u8 {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        return h.out.written();
    }

    /// One frame: draw, feed the bytes to the other terminal, compare.
    fn frame(h: *Harness, o: *Oracle) !visor.Renderer.Stats {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        o.feed(h.out.written());
        try expectAgrees(&h.screen, o);
        return stats;
    }
};

/// One random operation on the grid. The same set the suite inside the
/// package draws from, written against the public API.
fn operate(h: *Harness, smith: anytype, graphemes: []const []const u8) !void {
    const s = &h.screen;
    const cols = s.size.cols;
    const rows = s.size.rows;
    switch (smith.valueRangeAtMost(u8, 0, 6)) {
        0, 1, 2 => {
            const col: u16 = @intCast(smith.index(cols));
            const row: u16 = @intCast(smith.index(rows));
            const g = graphemes[smith.index(graphemes.len)];
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
        4 => s.fill(randomRect(smith, cols, rows), .blank(styles[smith.index(styles.len)])),
        5 => s.scroll(randomRect(smith, cols, rows), smith.valueRangeAtMost(i32, -3, 3)),
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
fn randomRect(smith: anytype, cols: u16, rows: u16) visor.Rect {
    const col: u16 = @intCast(smith.index(cols));
    const row: u16 = @intCast(smith.index(rows));
    return .{
        .col = col,
        .row = row,
        .cols = @intCast(smith.index(cols - col) + 1),
        .rows = @intCast(smith.index(rows - row) + 1),
    };
}

/// The four properties, once, over a generated sequence of frames.
fn roundTrip(gpa: Allocator, smith: *Smith, method: visor.Method) !void {
    const size: visor.Size = .{
        .cols = @intCast(smith.valueRangeAtMost(u8, 1, 24)),
        .rows = @intCast(smith.valueRangeAtMost(u8, 1, 12)),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, method);
    defer o.deinit();

    var frames: usize = 0;
    while (frames < 6 and !smith.eos()) : (frames += 1) {
        var ops: usize = 0;
        const count = smith.valueRangeAtMost(u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, smith, &alphabet);

        // The terminal shows the screen.
        _ = try h.frame(o);

        // Drawn again with nothing changed: not one byte.
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);

        // And again with every row claimed to have changed, which is the
        // stronger statement: the previous frame is what the terminal holds.
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }

    // A repaint recovers from any state the renderer drifted into.
    corrupt(&h.renderer, smith);
    h.renderer.repaint();
    _ = try h.frame(o);
    try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);

    // And a terminal given one full repaint of the final screen holds the
    // same thing as the terminal that was given every frame.
    const fresh = try Oracle.init(gpa, size, method);
    defer fresh.deinit();
    var once: visor.Renderer = try .init(gpa, size);
    defer once.deinit(gpa);
    once.repaint();
    h.out.clearRetainingCapacity();
    h.screen.damageAll();
    _ = try once.draw(&h.out.writer, &h.screen, h.caps);
    fresh.feed(h.out.written());
    try expectAgrees(&h.screen, fresh);
}

/// Puts the renderer's model out of step with the terminal, as a dropped
/// write or an out-of-band terminal write would.
fn corrupt(r: *visor.Renderer, smith: *Smith) void {
    var i: usize = 0;
    const count = smith.valueRangeAtMost(u8, 1, 8);
    while (i < count and r.prev.len != 0) : (i += 1) {
        r.prev[smith.index(r.prev.len)] = .blank(styles[smith.index(styles.len)]);
    }
    r.style = styles[smith.index(styles.len)];
    r.cursor = null;
    r.shown = null;
}

test "the second emulator agrees, measuring by codepoint" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTrip(gpa, smith, .wcwidth);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the second emulator agrees, measuring by cluster" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try roundTrip(gpa, smith, .unicode);
        }
    }.one, .{ .corpus = &corpus.entries });
}

//=========================================================================
// Resizing.
//
// A window being dragged is the terminal changing size on its own, the
// program hearing of it afterwards, and frames in flight across both. The
// program here hears of a size only after the terminal has taken it, which
// is the order an in-band report (mode 2048) guarantees: the terminal sends
// it once its grid is the new size. What the terminal does to its rows and
// its cursor on the way is its own business; the property is that the next
// frame drawn at the size the program was told leaves the terminal showing
// exactly the screen, whatever came before.
//=========================================================================

/// A size somewhere in the generator's range, reached from `from` the way a
/// window's edge moves: both ways, the width alone, or the height alone.
fn nextSize(smith: anytype, from: visor.Size) visor.Size {
    const cols = smith.valueRangeAtMost(u16, 1, 24);
    const rows = smith.valueRangeAtMost(u16, 1, 12);
    return switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .{ .cols = cols, .rows = rows },
        1 => .{ .cols = cols, .rows = from.rows },
        else => .{ .cols = from.cols, .rows = rows },
    };
}

/// What a program draws after a resize: now and then the whole layout
/// again from nothing, as a program whose layout moved does, then some
/// random operations.
fn scribble(h: *Harness, smith: anytype) !void {
    if (smith.value(bool)) h.screen.clear();
    var ops: usize = 0;
    const count = smith.valueRangeAtMost(u8, 1, 12);
    while (ops < count) : (ops += 1) try operate(h, smith, &resize_alphabet);
}

/// ASCII along a row, one cell a byte.
fn put(s: *visor.Screen, col: u16, row: u16, text: []const u8, style: visor.Style) !void {
    for (text, 0..) |b, i| try s.write(col + @as(u16, @intCast(i)), row, &.{b}, style, .none);
}

/// The terminal passes through a size the program may never hear of, with
/// a frame drawn at the program's size arriving after it, or not.
fn dragThrough(h: *Harness, o: *Oracle, dice: *Dice, to: visor.Size) !void {
    if (dice.value(bool)) {
        try scribble(h, dice);
        const stale = try h.render();
        try o.resize(to);
        o.feed(stale);
    } else try o.resize(to);
}

/// The generator's questions answered from a seeded generator rather than
/// from the input itself.
///
/// `Smith` reads eight bytes for every value it is asked for and answers
/// the lowest value in range when those bytes are out of it, so a corpus
/// entry of random bytes answers every ranged question with its minimum --
/// a one-column, one-row terminal, every time. Seeded from the input, a
/// run gets the whole range, and the corpus is that many different runs.
const Dice = struct {
    prng: std.Random.DefaultPrng,

    fn init(smith: *Smith) Dice {
        return .{ .prng = .init(smith.value(u64)) };
    }

    fn valueRangeAtMost(d: *Dice, comptime T: type, at_least: T, at_most: T) T {
        return d.prng.random().intRangeAtMost(T, at_least, at_most);
    }

    fn index(d: *Dice, len: usize) usize {
        return d.prng.random().uintLessThan(usize, len);
    }

    fn value(d: *Dice, comptime T: type) T {
        comptime std.debug.assert(T == bool);
        return d.prng.random().boolean();
    }
};

fn resizeTrip(gpa: Allocator, smith: *Smith, method: visor.Method) !void {
    var dice: Dice = .init(smith);
    var size: visor.Size = .{
        .cols = dice.valueRangeAtMost(u16, 1, 24),
        .rows = dice.valueRangeAtMost(u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, method);
    defer o.deinit();
    try h.enter(o);

    try scribble(&h, &dice);
    _ = try h.frame(o);

    var drawn = true;
    const steps = dice.valueRangeAtMost(u8, 1, 5);
    for (0..steps) |_| {
        const to = nextSize(&dice, size);
        switch (dice.valueRangeAtMost(u8, 0, 3)) {
            // The terminal takes the size, then the program hears of it.
            0 => {
                try o.resize(to);
                try h.resize(to);
            },
            // A frame drawn at the old size is still on its way when the
            // terminal takes the new one, and lands after it.
            1 => {
                try dragThrough(&h, o, &dice, to);
                try h.resize(to);
            },
            // A drag: the terminal passes through sizes the program never
            // hears of, frames at the old size landing between them.
            2 => {
                var hops = dice.valueRangeAtMost(u8, 1, 3);
                while (hops > 0) : (hops -= 1) try dragThrough(&h, o, &dice, nextSize(&dice, size));
                try dragThrough(&h, o, &dice, to);
                try h.resize(to);
            },
            // A drag the program hears every step of, drawing after none
            // of them but the last.
            else => {
                var hops = dice.valueRangeAtMost(u8, 1, 3);
                while (hops > 0) : (hops -= 1) {
                    const mid = nextSize(&dice, size);
                    try o.resize(mid);
                    try h.resize(mid);
                }
                try o.resize(to);
                try h.resize(to);
            },
        }
        size = to;

        // A frame now, or not until the next size.
        drawn = dice.valueRangeAtMost(u8, 0, 3) != 0;
        if (drawn) {
            try scribble(&h, &dice);
            _ = try h.frame(o);
            try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
        }
    }
    if (!drawn) {
        try scribble(&h, &dice);
        _ = try h.frame(o);
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
}

test "the second emulator agrees across resizes, measuring by codepoint" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try resizeTrip(gpa, smith, .wcwidth);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the second emulator agrees across resizes, measuring by cluster" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try resizeTrip(gpa, smith, .unicode);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "a label is not left on the row it moved from when the window grows" {
    const gpa = testing.allocator;
    const small: visor.Size = .{ .cols = 20, .rows = 6 };
    const tall: visor.Size = .{ .cols = 20, .rows = 8 };
    var h: Harness = try .init(gpa, small, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, small, .unicode);
    defer o.deinit();
    try h.enter(o);

    // A mode label on the last row.
    try put(&h.screen, 0, small.rows - 1, "H O L O M A P", .{ .bold = true });
    _ = try h.frame(o);

    // The window grows; the label moves to the new last row and the row it
    // was on is blank in the new layout.
    try o.resize(tall);
    try h.resize(tall);
    h.screen.clear();
    try put(&h.screen, 0, tall.rows - 1, "H O L O M A P", .{ .bold = true });
    _ = try h.frame(o);
}

test "a frame at the old size landing after the terminal shrank leaves nothing behind" {
    const gpa = testing.allocator;
    const wide: visor.Size = .{ .cols = 16, .rows = 5 };
    const narrow: visor.Size = .{ .cols = 9, .rows = 3 };
    var h: Harness = try .init(gpa, wide, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, wide, .unicode);
    defer o.deinit();
    try h.enter(o);

    for (0..wide.rows) |row| try put(&h.screen, 0, @intCast(row), "0123456789abcdef", .{});
    _ = try h.frame(o);

    // The program draws again at the width it knows; the terminal has
    // already shrunk when the bytes arrive, so they wrap and scroll.
    for (0..wide.rows) |row| try put(&h.screen, 0, @intCast(row), "fedcba9876543210", .{ .italic = true });
    const stale = try h.render();
    try o.resize(narrow);
    o.feed(stale);

    try h.resize(narrow);
    h.screen.clear();
    try put(&h.screen, 0, 1, "ok", .{});
    _ = try h.frame(o);
}

/// Where the second emulator has a placement of an image, in cells, or
/// null when it has none.
fn placementOf(o: *const Oracle, image: u32, placement: u32) ?visor.Rect {
    const screen = o.term.screens.active;
    var it = screen.kitty_images.placements.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.image_id != image or key.placement_id.tag != .external or key.placement_id.id != placement) continue;
        const pin = switch (entry.value_ptr.location) {
            .pin => |pin| pin,
            else => return null,
        };
        if (pin.garbage) return null;
        const at = screen.pages.pointFromPin(.active, pin.*) orelse return null;
        return .{
            .col = @intCast(at.active.x),
            .row = @intCast(at.active.y),
            .cols = @intCast(entry.value_ptr.columns),
            .rows = @intCast(entry.value_ptr.rows),
        };
    }
    return null;
}

/// How many placements the second emulator has, garbage aside.
fn placementCount(o: *const Oracle) usize {
    var n: usize = 0;
    var it = o.term.screens.active.kitty_images.placements.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.location) {
        .pin => |pin| if (!pin.garbage) {
            n += 1;
        },
        else => n += 1,
    };
    return n;
}

/// Every layer the screen shows is where the second emulator has it, and
/// it has nothing else.
fn expectLayersAgree(h: *const Harness, o: *const Oracle) !void {
    for (h.screen.layers.shown.items) |layer| {
        const at = placementOf(o, layer.image, layer.placement) orelse {
            std.debug.print("image {d}/{d}: drawn at {any}, the terminal has none\n", .{ layer.image, layer.placement, layer.rect });
            return error.PlacementMissing;
        };
        if (!std.meta.eql(at, layer.rect)) {
            std.debug.print("image {d}/{d}: drawn at {any}, the terminal has it at {any}\n", .{ layer.image, layer.placement, layer.rect, at });
            return error.PlacementMoved;
        }
    }
    try testing.expectEqual(h.screen.layers.shown.items.len, placementCount(o));
}

/// A picture of `id`, four by four pixels, sent the way a program sends one.
fn sendPicture(h: *Harness, o: *Oracle, id: u32) !void {
    const pixels: [4 * 4 * 4]u8 = @splat(0x80);
    h.out.clearRetainingCapacity();
    _ = try h.screen.layers.transmit(h.gpa, &h.out.writer, id, &pixels, .{ .width = 4, .height = 4 });
    o.feed(h.out.written());
}

/// Pictures across resizes: a few layers laid out, the terminal resized as
/// the text property resizes it, the layers laid out again for the new
/// size -- sometimes in the same cells, sometimes moved -- and every one
/// where the terminal has it.
fn layerResizeTrip(gpa: Allocator, smith: *Smith) !void {
    var dice: Dice = .init(smith);
    var size: visor.Size = .{
        .cols = dice.valueRangeAtMost(u16, 4, 24),
        .rows = dice.valueRangeAtMost(u16, 4, 12),
    };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    h.caps.kitty_graphics = true;
    const o = try Oracle.init(gpa, size, .unicode);
    defer o.deinit();
    try h.enter(o);

    const pictures = dice.valueRangeAtMost(u32, 1, 3);
    var id: u32 = 1;
    while (id <= pictures) : (id += 1) try sendPicture(&h, o, id);

    var rects: [3]visor.Rect = undefined;
    for (rects[0..pictures]) |*r| r.* = randomRect(&dice, size.cols, size.rows);
    try layOut(&h, rects[0..pictures]);
    _ = try h.frame(o);
    try expectLayersAgree(&h, o);

    const steps = dice.valueRangeAtMost(u8, 1, 5);
    for (0..steps) |_| {
        const to = nextSize(&dice, size);
        var hops = dice.valueRangeAtMost(u8, 0, 2);
        while (hops > 0) : (hops -= 1) try dragThrough(&h, o, &dice, nextSize(&dice, size));
        try dragThrough(&h, o, &dice, to);
        try h.resize(to);
        size = to;

        // Each picture keeps its cells where they still fit, or moves.
        for (rects[0..pictures]) |*r| {
            const fits = r.col + r.cols <= size.cols and r.row + r.rows <= size.rows;
            if (!fits or dice.value(bool)) r.* = randomRect(&dice, size.cols, size.rows);
        }
        try layOut(&h, rects[0..pictures]);
        try scribble(&h, &dice);
        _ = try h.frame(o);
        try expectLayersAgree(&h, o);
        // The same layers again: nothing to write.
        try layOut(&h, rects[0..pictures]);
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
}

/// This frame's layers: picture `i + 1` at `rects[i]`.
fn layOut(h: *Harness, rects: []const visor.Rect) !void {
    for (rects, 1..) |r, i| try h.screen.layers.declare(h.gpa, .{ .image = @intCast(i), .rect = r });
}

test "pictures stay where the program put them across resizes" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: Allocator, smith: *Smith) anyerror!void {
            try layerResizeTrip(gpa, smith);
        }
    }.one, .{ .corpus = &corpus.entries });
}

//=========================================================================
// The probe.
//=========================================================================

/// Everything the second emulator answered, for the probe to read.
var answers: [4096]u8 = undefined;
var answered: usize = 0;

fn writePty(_: *vt.TerminalStream.Handler, data: []const u8) void {
    @memcpy(answers[answered..][0..data.len], data);
    answered += data.len;
}

fn deviceAttributes(_: *vt.TerminalStream.Handler) @typeInfo(@typeInfo(@typeInfo(@FieldType(vt.TerminalStream.Handler.Effects, "device_attributes")).optional.child).pointer.child).@"fn".return_type.? {
    return .{};
}

test "the probe finds what the second emulator has, reset modes included" {
    const gpa = testing.allocator;
    var tiny: vt.TinyIo = .init;
    var term: vt.Terminal = try .init(tiny.io(), gpa, .{ .cols = 80, .rows = 24 });
    defer term.deinit(gpa);
    var handler: vt.TerminalStream.Handler = .init(&term);
    handler.effects.write_pty = &writePty;
    handler.effects.device_attributes = &deviceAttributes;
    var stream: vt.TerminalStream = .init(.{ .allocator = gpa, .handler = handler });
    defer stream.deinit();

    var probe: visor.Caps.Probe = .{ .graphics_id = 1 };
    var questions: std.Io.Writer.Allocating = .init(gpa);
    defer questions.deinit();
    try probe.write(&questions.writer);
    answered = 0;
    stream.nextSlice(questions.written());

    // Each answer framed the way a program's input reader frames it.
    var parse_buf: [4096]u8 = undefined;
    var parser: visor.morse.KeyParser = .init(&parse_buf);
    var events = parser.feed(answers[0..answered]);
    while (events.next()) |ev| switch (ev) {
        .unhandled => |bytes| probe.feed(bytes),
        else => {},
    };

    try testing.expect(probe.settled());
    // Neither mode is on when the probe asks -- the emulator answers
    // reset -- and both are there to be used.
    try testing.expect(probe.caps.sync);
    try testing.expect(probe.caps.in_band_resize);
    try testing.expectEqual(visor.Method.unicode, probe.caps.width_method);
    try testing.expect(probe.caps.kitty_keyboard);
}

test "two links that differ only by their id are two links to the second emulator" {
    const gpa = testing.allocator;
    const size: visor.Size = .{ .cols = 8, .rows = 1 };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, .unicode);
    defer o.deinit();

    const one = try h.screen.link(gpa, "https://ziglang.org", "id=one");
    const two = try h.screen.link(gpa, "https://ziglang.org", "id=two");
    const bare = try h.screen.link(gpa, "https://ziglang.org", "");
    try h.screen.write(0, 0, "a", .{}, one);
    try h.screen.write(1, 0, "b", .{}, two);
    try h.screen.write(2, 0, "c", .{}, bare);
    try h.screen.write(3, 0, "d", .{}, .none);
    _ = try h.frame(o);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one", (try o.read(0, 0, &buf)).link.?.id.?);
    try testing.expectEqualStrings("two", (try o.read(1, 0, &buf)).link.?.id.?);
    try testing.expectEqual(@as(?[]const u8, null), (try o.read(2, 0, &buf)).link.?.id);
    try testing.expectEqual(@as(?Oracle.Hyperlink, null), (try o.read(3, 0, &buf)).link);

    // And a drawn link the terminal did not get is a failure, not a pass.
    try h.screen.write(3, 0, "d", .{}, one);
    try testing.expectError(error.LinkDisagrees, expectAgrees(&h.screen, o));
}

test "every cluster written to the last row reaches the second emulator" {
    const gpa = testing.allocator;
    const size: visor.Size = .{ .cols = 24, .rows = 4 };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, .unicode);
    defer o.deinit();

    var col: u16 = 0;
    var which: usize = 0;
    while (col < size.cols) : (which += 1) {
        const g = alphabet[which % alphabet.len];
        const w = visor.graphemeWidth(g, .unicode);
        if (col + w > size.cols) break;
        try h.screen.write(col, size.rows - 1, g, styles[which % styles.len], .none);
        col += w;
    }
    _ = try h.frame(o);
}
