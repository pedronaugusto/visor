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
//! generated cases, read by column:
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
const Spread = @import("spread").Spread;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Source = shakedown.Source;
const widgets = visor.widgets;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.conformance);

/// The graphemes the generator draws from: ASCII, a combining pair, a wide
/// one, a cluster too long to live in a cell, and the ones the two width
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
        return initKeeping(gpa, size, method, 0);
    }

    /// A terminal that keeps `scrollback` rows that went up past its top.
    fn initKeeping(gpa: Allocator, size: visor.Size, method: visor.Method, scrollback: usize) !*Oracle {
        // Boxed: `Terminal` keeps a `std.Io` that points at the `TinyIo`
        // beside it, so neither may move after this.
        const o = try gpa.create(Oracle);
        errdefer gpa.destroy(o);
        o.* = .{ .gpa = gpa, .tiny = .init, .term = undefined };
        o.term = try .init(o.tiny.io(), gpa, .{
            .cols = size.cols,
            .rows = size.rows,
            .max_scrollback_lines = scrollback,
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

    /// How many rows the terminal has, the ones in its scrollback included.
    fn totalRows(o: *const Oracle) usize {
        return o.term.screens.active.pages.total_rows;
    }

    /// One row counted from the top of the scrollback, as text: each
    /// cluster once, trailing blanks off.
    fn historyRow(o: *const Oracle, row: usize, buf: []u8) ![]const u8 {
        var n: usize = 0;
        var col: u16 = 0;
        while (col < o.term.cols) : (col += 1) {
            const found = o.term.screens.active.pages.getCell(.{ .screen = .{ .x = col, .y = @intCast(row) } }) orelse
                return error.ColumnMissing;
            if (found.cell.wide == .spacer_tail) continue;
            const first = found.cell.codepoint();
            n += std.unicode.utf8Encode(if (first == 0) ' ' else first, buf[n..]) catch return error.BadCodepoint;
            if (found.cell.hasGrapheme()) {
                if (found.node.page().lookupGrapheme(found.cell)) |rest| {
                    for (rest) |cp| n += std.unicode.utf8Encode(cp, buf[n..]) catch return error.BadCodepoint;
                }
            }
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
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
        .ansi => .{ .palette = @backingInt(color.toAnsi()) },
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
        @backingInt(f.underline) == @backingInt(want.underline);
}

/// Where the grid the terminal rebuilt first differs from the grid that was
/// drawn, and in what.
const Disagreement = struct {
    col: u16,
    row: u16,
    what: What,

    const What = enum { width, text, style, link };
};

/// The first column, reading row by row, where the grid the terminal rebuilt
/// is not the grid that was drawn, or null when every column agrees. Says
/// nothing: `expectAgrees` is what reports one.
fn firstDisagreement(screen: *const visor.Screen, o: *const Oracle) !?Disagreement {
    var buf: [64]u8 = undefined;
    var row: u16 = 0;
    while (row < screen.dimensions().rows) : (row += 1) {
        var col: u16 = 0;
        while (col < screen.dimensions().cols) : (col += 1) {
            const mine = screen.readCell(col, row).?;
            const theirs = try o.read(col, row, &buf);
            if (wideOf(mine.shape.kind) != theirs.wide) return .{ .col = col, .row = row, .what = .width };
            // The covered column of a wide cluster draws nothing on either
            // side, and the two do not agree on what is written under it.
            if (mine.shape.kind == .spacer_tail) continue;
            if (!std.mem.eql(u8, screen.textAt(col, row), theirs.text)) return .{ .col = col, .row = row, .what = .text };
            if (!styleAgrees(mine.style, theirs.style)) return .{ .col = col, .row = row, .what = .style };
            if (!linkAgrees(screen.target(mine.link), theirs.link)) return .{ .col = col, .row = row, .what = .link };
        }
    }
    return null;
}

/// Every column of the grid the terminal rebuilt, against the grid that was
/// drawn.
///
/// A disagreement is reported through `std.log.err`, which the test runner
/// counts as a failure of the test that logged it whatever the test returns.
/// So a report can never sit beside a pass: a caller that catches the error,
/// or a test that expects it, still fails. A test that wants to provoke a
/// disagreement asks `firstDisagreement`, which reports nothing.
fn expectAgrees(screen: *const visor.Screen, o: *const Oracle) !void {
    const d = (try firstDisagreement(screen, o)) orelse return;
    const mine = screen.readCell(d.col, d.row).?;
    var buf: [64]u8 = undefined;
    const theirs = try o.read(d.col, d.row, &buf);
    switch (d.what) {
        .width => {
            log.err(
                "column {d},{d}: this package says {s}, the terminal says {s}",
                .{ d.col, d.row, @tagName(mine.shape.kind), @tagName(theirs.wide) },
            );
            return error.WidthDisagrees;
        },
        .text => {
            log.err(
                "column {d},{d}: this package wrote '{f}', the terminal shows '{f}'",
                .{ d.col, d.row, std.ascii.hexEscape(screen.textAt(d.col, d.row), .lower), std.ascii.hexEscape(theirs.text, .lower) },
            );
            return error.TextDisagrees;
        },
        .style => {
            log.err(
                "column {d},{d}: style disagrees\n  drawn: {any}\n  shown: {any}",
                .{ d.col, d.row, mine.style, theirs.style },
            );
            return error.StyleDisagrees;
        },
        .link => {
            log.err(
                "column {d},{d}: link disagrees\n  drawn: {?any}\n  shown: {?any}",
                .{ d.col, d.row, screen.target(mine.link), theirs.link },
            );
            return error.LinkDisagrees;
        },
    }
}

//=========================================================================
// The property.
//=========================================================================

/// What the generators drew over a run of cases, one `Spread` a
/// question.
const Tally = struct {
    /// The grid's width, at the start and after every resize.
    cols: Spread = .{},
    /// Its height, the same.
    rows: Spread = .{},
    /// Which grid operation.
    ops: Spread = .{},
    /// Which grapheme a write took.
    graphemes: Spread = .{},
    /// How many frames one input ran to.
    frames: Spread = .{},
};

/// `property` over the cases `check` draws, with its draws counted in
/// `tally` when it is given one.
fn checked(comptime property: anytype, args: anytype, tally: ?*Tally) !void {
    const Run = struct { args: @TypeOf(args), tally: ?*Tally };
    const body = struct {
        fn run(r: Run, case: *shakedown.Case) !void {
            try @call(.auto, property, .{ testing.allocator, case.source } ++ r.args ++ .{r.tally});
        }
    }.run;
    try shakedown.check(testing.allocator, Run{ .args = args, .tally = tally }, body, .{ .seed = if (tally != null) 0x5eed else null });
}

/// `property` over the cases `check` draws, for a property that counts
/// nothing.
fn checkedUncounted(comptime property: anytype, args: anytype) !void {
    const body = struct {
        fn run(a: @TypeOf(args), case: *shakedown.Case) !void {
            try @call(.auto, property, .{ testing.allocator, case.source } ++ a);
        }
    }.run;
    try shakedown.check(testing.allocator, args, body, .{});
}

/// Everything one round needs.
const Harness = struct {
    gpa: Allocator,
    screen: visor.Screen,
    renderer: visor.Renderer,
    out: std.Io.Writer.Allocating,
    caps: visor.Caps,
    /// The pictures shown beside the screen.
    layers: visor.Layers,
    /// Where the generator's draws are counted, for the test that proves the
    /// cases explore; null everywhere else.
    tally: ?*Tally = null,

    fn init(gpa: Allocator, size: visor.Size, method: visor.Method) !Harness {
        var s: visor.Screen = try .init(gpa, size);
        errdefer s.deinit();
        s.method = method;
        var r: visor.Renderer = try .init(gpa, size);
        errdefer r.deinit();
        return .{
            .gpa = gpa,
            .layers = .init(gpa),
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
        h.screen.deinit();
        h.layers.deinit();
        h.renderer.deinit();
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
        try h.screen.resize(size);
        try h.renderer.resize(size);
    }

    /// A frame drawn and not yet delivered: its bytes, which the caller
    /// feeds when it decides they arrive.
    fn render(h: *Harness) ![]const u8 {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        return h.out.written();
    }

    /// One frame: draw, feed the bytes to the other terminal, compare.
    fn frame(h: *Harness, o: *Oracle) !visor.Renderer.Stats {
        h.out.clearRetainingCapacity();
        const stats = try h.renderer.draw(&h.out.writer, &h.screen, &h.layers, h.caps);
        try testing.expectEqual(h.out.written().len, stats.bytes);
        o.feed(h.out.written());
        try expectAgrees(&h.screen, o);
        return stats;
    }
};

/// One random operation on the grid. The same set the suite inside the
/// package draws from, written against the public API.
fn operate(h: *Harness, src: *Source) !void {
    const s = &h.screen;
    const cols = s.dimensions().cols;
    const rows = s.dimensions().rows;
    const op = gen.intRange(src, u8, 0, 6);
    if (h.tally) |t| t.ops.add(op);
    switch (op) {
        0, 1, 2 => {
            const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
            const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
            const which = gen.intRange(src, usize, 0, alphabet.len - 1);
            if (h.tally) |t| t.graphemes.add(which);
            const g = alphabet[which];
            const style = styles[gen.intRange(src, usize, 0, styles.len - 1)];
            const target = gen.intRange(src, usize, 0, uris.len - 1);
            const link = try s.link(uris[target], params[target]);
            try s.write(col, row, g, style, link);
        },
        3 => {
            const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
            const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
            try s.writeOwnedCell(col, row, .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)]));
        },
        4 => try s.fill(randomRect(src, cols, rows), .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)])),
        5 => s.scroll(randomRect(src, cols, rows), gen.intRange(src, i32, -3, 3)),
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
fn randomRect(src: *Source, cols: u16, rows: u16) visor.Rect {
    const col: u16 = @intCast(gen.intRange(src, usize, 0, cols - 1));
    const row: u16 = @intCast(gen.intRange(src, usize, 0, rows - 1));
    return .{
        .col = col,
        .row = row,
        .cols = @intCast(gen.intRange(src, usize, 0, (cols - col) - 1) + 1),
        .rows = @intCast(gen.intRange(src, usize, 0, (rows - row) - 1) + 1),
    };
}

/// The four properties, once, over a generated sequence of frames.
fn roundTrip(gpa: Allocator, src: *Source, method: visor.Method, tally: ?*Tally) !void {
    const size: visor.Size = .{
        .cols = gen.intRange(src, u16, 1, 24),
        .rows = gen.intRange(src, u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    h.tally = tally;
    if (tally) |t| {
        t.cols.add(size.cols);
        t.rows.add(size.rows);
    }
    const o = try Oracle.init(gpa, size, method);
    defer o.deinit();

    var frames: usize = 0;
    while (frames < 6 and src.more(7)) : (frames += 1) {
        var ops: usize = 0;
        const count = gen.intRange(src, u8, 1, 12);
        while (ops < count) : (ops += 1) try operate(&h, src);

        // The terminal shows the screen.
        _ = try h.frame(o);

        // Drawn again with nothing changed: not one byte.
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);

        // And again with every row claimed to have changed, which is the
        // stronger statement: the previous frame is what the terminal holds.
        h.screen.damageAll();
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
    if (tally) |t| t.frames.add(frames);

    // A repaint recovers from any state the renderer drifted into.
    corrupt(&h.renderer, src);
    h.renderer.repaint();
    _ = try h.frame(o);
    try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);

    // And a terminal given one full repaint of the final screen holds the
    // same thing as the terminal that was given every frame.
    const fresh = try Oracle.init(gpa, size, method);
    defer fresh.deinit();
    var once: visor.Renderer = try .init(gpa, size);
    defer once.deinit();
    once.repaint();
    h.out.clearRetainingCapacity();
    h.screen.damageAll();
    _ = try once.draw(&h.out.writer, &h.screen, null, h.caps);
    fresh.feed(h.out.written());
    try expectAgrees(&h.screen, fresh);
}

/// Puts the renderer's model out of step with the terminal, as a dropped
/// write or an out-of-band terminal write would.
fn corrupt(r: *visor.Renderer, src: *Source) void {
    var i: usize = 0;
    const count = gen.intRange(src, u8, 1, 8);
    while (i < count and r.prev.len != 0) : (i += 1) {
        r.prev[gen.intRange(src, usize, 0, r.prev.len - 1)] = .blank(styles[gen.intRange(src, usize, 0, styles.len - 1)]);
    }
    r.style = styles[gen.intRange(src, usize, 0, styles.len - 1)];
    r.own_cursor = null;
    r.shown = null;
}

test "the second emulator agrees, measuring by codepoint" {
    try checked(roundTrip, .{visor.Method.wcwidth}, null);
}

test "the second emulator agrees, measuring by cluster" {
    try checked(roundTrip, .{visor.Method.unicode}, null);
}

test "the cases draw every size, every operation and every grapheme against the second emulator" {
    // The assertions are about the cases `check` draws, not the fuzzer's.
    if (@import("builtin").fuzz) return error.SkipZigTest;
    var t: Tally = .{};
    try checked(roundTrip, .{visor.Method.unicode}, &t);
    try testing.expect(t.cols.covers(1, 24));
    try testing.expect(t.rows.covers(1, 12));
    try testing.expect(t.ops.covers(0, 6));
    try testing.expect(t.graphemes.covers(0, alphabet.len - 1));
    try testing.expect(t.frames.covers(1, 6));
}

test "a mark on a terminal one column wide stays with its base" {
    // The emulator joins a codepoint to the cell under the cursor only past
    // the first column, so in one column, measuring clusters, the mark after
    // a base that filled the column was dropped.
    const gpa = testing.allocator;
    var h: Harness = try .init(gpa, .{ .cols = 1, .rows = 2 }, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, h.screen.dimensions(), .unicode);
    defer o.deinit();
    try h.screen.write(0, 0, "e\u{301}", .{}, .none);
    try h.screen.write(0, 1, "a\u{301}\u{302}", .{ .bold = true }, .none);
    _ = try h.frame(o);
    try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
}

test "cells the program drew apart stay apart on the second emulator, where it would join them" {
    // The emulator joins a codepoint to the cell on the left of the cursor
    // wherever the break rules find no break: regional indicators pair, a
    // skin tone joins a thumb, a spacing mark joins anything. Each row puts
    // such cells side by side, three regional indicators, a row of marks and
    // flags beside lone indicators among them, drawn and then drawn again.
    const gpa = testing.allocator;
    const rows = [_][]const []const u8{
        &.{ "\u{1f1e6}", "\u{1f1e7}", "\u{1f1e6}", "z" },
        &.{ "\u{1f44d}", "\u{1f3fb}", "a", "\u{1f3fb}" },
        &.{ "\u{915}", "\u{903}", "\u{903}", "\u{903}", "\u{903}", "\u{903}", "a", "\u{903}" },
        &.{ "\u{4e2d}", "\u{903}", " ", "\u{903}", "\u{1f1e6}", "a" },
        // a flag beside a lone indicator: more than marks, so mode 2027 off
        // cannot keep it apart, and it is written before the cell it would
        // join
        &.{ "\u{1f1e6}", "\u{1f1e7}\u{1f1e8}", "z", "\u{1f1fa}", "\u{1f1f8}\u{1f1e6}" },
    };
    var h: Harness = try .init(gpa, .{ .cols = 16, .rows = rows.len }, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, h.screen.dimensions(), .unicode);
    defer o.deinit();
    try h.enter(o);
    for (rows, 0..) |cells, row| {
        var col: u16 = 0;
        for (cells) |g| {
            try h.screen.write(col, @intCast(row), g, .{}, .none);
            col += visor.graphemeWidth(g, .unicode);
        }
    }
    _ = try h.frame(o);
    try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    // And the right-hand cells drawn again on their own, their neighbours
    // unchanged on the terminal.
    try h.screen.write(2, 0, "\u{1f1e7}", .{ .bold = true }, .none);
    try h.screen.write(2, 1, "\u{1f3fb}", .{ .bold = true }, .none);
    try h.screen.write(1, 2, "\u{903}", .{ .bold = true }, .none);
    _ = try h.frame(o);
}

test "measured by codepoint, a cluster of wide codepoints is in the cells the terminal gives each" {
    // The woman, the joiner and the rocket: the emulator measuring by
    // codepoint puts the woman and the joiner in two columns and the rocket
    // in the next two, and so does the grid.
    const gpa = testing.allocator;
    var h: Harness = try .init(gpa, .{ .cols = 10, .rows = 2 }, .wcwidth);
    defer h.deinit();
    const o = try Oracle.init(gpa, h.screen.dimensions(), .wcwidth);
    defer o.deinit();
    try h.screen.write(0, 0, "\u{1f469}\u{200d}\u{1f680}", .{}, .none);
    try h.screen.write(4, 0, "x", .{}, .none);
    try h.screen.write(5, 1, "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}", .{}, .none);
    _ = try h.frame(o);
    try testing.expectEqualStrings("\u{1f680}", h.screen.textAt(2, 0));
    try testing.expectEqualStrings("x", h.screen.textAt(4, 0));
    try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
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
fn nextSize(src: *Source, from: visor.Size) visor.Size {
    const cols = gen.intRange(src, u16, 1, 24);
    const rows = gen.intRange(src, u16, 1, 12);
    return switch (gen.intRange(src, u8, 0, 2)) {
        0 => .{ .cols = cols, .rows = rows },
        1 => .{ .cols = cols, .rows = from.rows },
        else => .{ .cols = from.cols, .rows = rows },
    };
}

/// What a program draws after a resize: now and then the whole layout
/// again from nothing, as a program whose layout moved does, then some
/// random operations.
fn scribble(h: *Harness, src: *Source) !void {
    if (gen.boolean(src)) h.screen.clear();
    var ops: usize = 0;
    const count = gen.intRange(src, u8, 1, 12);
    while (ops < count) : (ops += 1) try operate(h, src);
}

/// ASCII along a row, one cell a byte.
fn put(s: *visor.Screen, col: u16, row: u16, text: []const u8, style: visor.Style) !void {
    for (text, 0..) |b, i| try s.write(col + @as(u16, @intCast(i)), row, &.{b}, style, .none);
}

/// The terminal passes through a size the program may never hear of, with
/// a frame drawn at the program's size arriving after it, or not.
fn dragThrough(h: *Harness, o: *Oracle, src: *Source, to: visor.Size) !void {
    if (gen.boolean(src)) {
        try scribble(h, src);
        const stale = try h.render();
        try o.resize(to);
        o.feed(stale);
    } else try o.resize(to);
}

fn resizeTrip(gpa: Allocator, src: *Source, method: visor.Method) !void {
    var size: visor.Size = .{
        .cols = gen.intRange(src, u16, 1, 24),
        .rows = gen.intRange(src, u16, 1, 12),
    };

    var h: Harness = try .init(gpa, size, method);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, method);
    defer o.deinit();
    try h.enter(o);

    try scribble(&h, src);
    _ = try h.frame(o);

    var drawn = true;
    const steps = gen.intRange(src, u8, 1, 5);
    for (0..steps) |_| {
        const to = nextSize(src, size);
        switch (gen.intRange(src, u8, 0, 3)) {
            // The terminal takes the size, then the program hears of it.
            0 => {
                try o.resize(to);
                try h.resize(to);
            },
            // A frame drawn at the old size is still on its way when the
            // terminal takes the new one, and lands after it.
            1 => {
                try dragThrough(&h, o, src, to);
                try h.resize(to);
            },
            // A drag: the terminal passes through sizes the program never
            // hears of, frames at the old size landing between them.
            2 => {
                var hops = gen.intRange(src, u8, 1, 3);
                while (hops > 0) : (hops -= 1) try dragThrough(&h, o, src, nextSize(src, size));
                try dragThrough(&h, o, src, to);
                try h.resize(to);
            },
            // A drag the program hears every step of, drawing after none
            // of them but the last.
            else => {
                var hops = gen.intRange(src, u8, 1, 3);
                while (hops > 0) : (hops -= 1) {
                    const mid = nextSize(src, size);
                    try o.resize(mid);
                    try h.resize(mid);
                }
                try o.resize(to);
                try h.resize(to);
            },
        }
        size = to;

        // A frame now, or not until the next size.
        drawn = gen.intRange(src, u8, 0, 3) != 0;
        if (drawn) {
            try scribble(&h, src);
            _ = try h.frame(o);
            try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
        }
    }
    if (!drawn) {
        try scribble(&h, src);
        _ = try h.frame(o);
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
}

test "the second emulator agrees across resizes, measuring by codepoint" {
    try checkedUncounted(resizeTrip, .{visor.Method.wcwidth});
}

test "the second emulator agrees across resizes, measuring by cluster" {
    try checkedUncounted(resizeTrip, .{visor.Method.unicode});
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
    for (h.layers.placements()) |layer| {
        const at = placementOf(o, layer.image.raw(), layer.placement.raw()) orelse {
            log.err("image {d}/{d}: drawn at {any}, the terminal has none", .{ layer.image.raw(), layer.placement.raw(), layer.rect });
            return error.PlacementMissing;
        };
        if (!std.meta.eql(at, layer.rect)) {
            log.err("image {d}/{d}: drawn at {any}, the terminal has it at {any}", .{ layer.image, layer.placement, layer.rect, at });
            return error.PlacementMoved;
        }
    }
    try testing.expectEqual(h.layers.placements().len, placementCount(o));
}

/// A picture of `id`, four by four pixels, sent the way a program sends one.
fn sendPicture(h: *Harness, o: *Oracle, id: u32) !void {
    const pixels: [4 * 4 * 4]u8 = @splat(0x80);
    h.out.clearRetainingCapacity();
    _ = try h.layers.transmit(&h.out.writer, .fromRaw(id), &pixels, .{ .width = .fromRaw(4), .height = .fromRaw(4) });
    o.feed(h.out.written());
}

/// Pictures across resizes: a few layers laid out, the terminal resized as
/// the text property resizes it, the layers laid out again for the new
/// size -- sometimes in the same cells, sometimes moved -- and every one
/// where the terminal has it.
fn layerResizeTrip(gpa: Allocator, src: *Source) !void {
    var size: visor.Size = .{
        .cols = gen.intRange(src, u16, 4, 24),
        .rows = gen.intRange(src, u16, 4, 12),
    };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    h.caps.kitty_graphics = true;
    const o = try Oracle.init(gpa, size, .unicode);
    defer o.deinit();
    try h.enter(o);

    const pictures = gen.intRange(src, u32, 1, 3);
    var id: u32 = 1;
    while (id <= pictures) : (id += 1) try sendPicture(&h, o, id);

    var rects: [3]visor.Rect = undefined;
    for (rects[0..pictures]) |*r| r.* = randomRect(src, size.cols, size.rows);
    try layOut(&h, rects[0..pictures]);
    _ = try h.frame(o);
    try expectLayersAgree(&h, o);

    const steps = gen.intRange(src, u8, 1, 5);
    for (0..steps) |_| {
        const to = nextSize(src, size);
        var hops = gen.intRange(src, u8, 0, 2);
        while (hops > 0) : (hops -= 1) try dragThrough(&h, o, src, nextSize(src, size));
        try dragThrough(&h, o, src, to);
        try h.resize(to);
        size = to;

        // Each picture keeps its cells where they still fit, or moves.
        for (rects[0..pictures]) |*r| {
            const fits = r.col + r.cols <= size.cols and r.row + r.rows <= size.rows;
            if (!fits or gen.boolean(src)) r.* = randomRect(src, size.cols, size.rows);
        }
        try layOut(&h, rects[0..pictures]);
        try scribble(&h, src);
        _ = try h.frame(o);
        try expectLayersAgree(&h, o);
        // The same layers again: nothing to write.
        try layOut(&h, rects[0..pictures]);
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
}

/// This frame's layers: picture `i + 1` at `rects[i]`.
fn layOut(h: *Harness, rects: []const visor.Rect) !void {
    for (rects, 1..) |r, i| try h.layers.declare(.{ .image = .fromRaw(@intCast(i)), .rect = r });
}

test "pictures stay where the program put them across resizes" {
    try checkedUncounted(layerResizeTrip, .{});
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

    var probe: visor.Caps.Probe = .init(.{ .graphics_id = try visor.morse.QueryImageId.fromRaw(1) });
    var questions: std.Io.Writer.Allocating = .init(gpa);
    defer questions.deinit();
    try probe.write(&questions.writer);
    answered = 0;
    stream.nextSlice(questions.written());

    // Each answer framed the way a program's input reader frames it.
    var parse_buf: [4096]u8 = undefined;
    var parser: visor.morse.KeyParser = .init(&parse_buf);
    var events = parser.feed(answers[0..answered]);
    while (events.next()) |ev| {
        // Every answer is read as one: nothing the probe asked comes back
        // as bytes for it to parse.
        try testing.expect(ev != .unhandled);
        probe.feed(ev, .zero);
    }

    // The emulator as it runs here leaves some questions unanswered -- the
    // colours and the sizes, which it answers through handlers this build
    // does not install -- so the probe is settled by the device attributes
    // and a quiet period after the last answer, not at once.
    try testing.expect(probe.hasAnswered(.device_attributes));
    try testing.expect(!probe.settled(.zero, .fromMilliseconds(50)));
    try testing.expect(probe.settled(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .fromMilliseconds(50)));
    try testing.expect(probe.capabilities().truecolor);
    // Neither mode is on when the probe asks -- the emulator answers
    // reset -- and both are there to be used.
    try testing.expect(probe.capabilities().sync);
    try testing.expect(probe.capabilities().in_band_resize);
    try testing.expectEqual(visor.Method.unicode, probe.capabilities().width_method);
    try testing.expect(probe.capabilities().kitty_keyboard);
}

test "two links that differ only by their id are two links to the second emulator" {
    const gpa = testing.allocator;
    const size: visor.Size = .{ .cols = 8, .rows = 1 };
    var h: Harness = try .init(gpa, size, .unicode);
    defer h.deinit();
    const o = try Oracle.init(gpa, size, .unicode);
    defer o.deinit();

    const one = try h.screen.link("https://ziglang.org", "id=one");
    const two = try h.screen.link("https://ziglang.org", "id=two");
    const bare = try h.screen.link("https://ziglang.org", "");
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

    // And a drawn link the terminal did not get is a disagreement, found
    // where it is. Asked quietly: `expectAgrees` would report it, and a
    // report fails the test that made it.
    try h.screen.write(3, 0, "d", .{}, one);
    try testing.expectEqual(
        @as(?Disagreement, .{ .col = 3, .row = 0, .what = .link }),
        try firstDisagreement(&h.screen, o),
    );
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

test "a list of rows a person picks from reaches the second emulator as drawn" {
    // Runs in their own styles lined up in a column, a state at the right
    // edge, a second row under an item, a marker in its own style, and text
    // cut with an ellipsis: every cell the list drew, read back.
    const gpa = testing.allocator;
    for ([_]visor.Method{ .unicode, .wcwidth }) |method| {
        var h: Harness = try .init(gpa, .{ .cols = 22, .rows = 5 }, method);
        defer h.deinit();
        const o = try Oracle.init(gpa, h.screen.dimensions(), method);
        defer o.deinit();
        const Run = widgets.List.Segment;
        const items = [_]widgets.Item{
            .{ .segments = &[_]Run{ .{ .text = "1", .style = .{ .dim = true } }, .{ .text = "\u{4e2d}\u{6587} name", .at = 2 } }, .aside = &[_]Run{.{ .text = "12k", .style = .{ .fg = .ansi(.yellow) } }} },
            .{ .segments = &[_]Run{ .{ .text = "2", .style = .{ .bold = true } }, .{ .text = "a name far too long to fit", .at = 2 } }, .aside = &[_]Run{.{ .text = "3.4M" }}, .below = &.{&[_]Run{.{ .text = "e\u{301}t\u{e9} \u{26a0}\u{fe0f}", .style = .{ .italic = true } }}} },
            .{ .text = "last" },
        };
        var state: widgets.List.State = .{ .selected = 1 };
        try (widgets.List{
            .items = &items,
            .marker = "\u{25b8}",
            .blank_marker = " ",
            .marker_style = .{ .fg = .ansi(.red), .bold = true },
            .gap = 1,
            .selected_style = null,
            .ellipsis = "\u{2026}",
            .text_min = 0,
        }).draw(h.screen.window(), &state);
        _ = try h.frame(o);
        try testing.expectEqual(@as(usize, 0), (try h.frame(o)).bytes);
    }
}

test "a repeat after a cluster repeats the codepoint that began its cell" {
    // What visor's own emulator (src/term.zig) models REP after: the base
    // of the cell printed last, not its last mark. The renderer repeats no
    // cluster, so this is the model held to the pinned emulator.
    const gpa = testing.allocator;
    const cases = [_]struct { bytes: []const u8, cells: []const []const u8 }{
        .{ .bytes = "e\u{301}\x1b[2b", .cells = &.{ "e\u{301}", "e", "e", " " } },
        .{ .bytes = "\u{1f1e6}\u{1f1e7}\x1b[2b", .cells = &.{ "\u{1f1e6}\u{1f1e7}", " ", "\u{1f1e6}\u{1f1e6}", " " } },
        .{ .bytes = "a\x1b[2b", .cells = &.{ "a", "a", "a", " " } },
    };
    for (cases) |case| {
        const o = try Oracle.init(gpa, .{ .cols = 10, .rows = 1 }, .unicode);
        defer o.deinit();
        o.feed("\x1b[?2027h");
        o.feed(case.bytes);
        var buf: [64]u8 = undefined;
        for (case.cells, 0..) |want, col| {
            try testing.expectEqualStrings(want, (try o.read(@intCast(col), 0, &buf)).text);
        }
    }
}

test "an ASCII batch stays apart from a prepend on the second emulator" {
    for ([_]visor.Method{ .unicode, .wcwidth }) |method| {
        var h = try Harness.init(testing.allocator, .{ .cols = 5, .rows = 1 }, method);
        defer h.deinit();
        const o = try Oracle.init(testing.allocator, h.screen.dimensions(), method);
        defer o.deinit();
        h.caps.rep = false;
        try h.enter(o);
        try h.screen.write(0, 0, "\u{d4e}", .{}, .none);
        try h.screen.write(1, 0, "a", .{}, .none);
        try h.screen.write(2, 0, "b", .{}, .none);
        _ = try h.frame(o);
        try h.screen.write(1, 0, "c", .{}, .none);
        _ = try h.frame(o);
    }
}

test "rows printed above an inline screen go up into the second emulator's scrollback" {
    const gpa = testing.allocator;
    for ([_]visor.Method{ .unicode, .wcwidth }) |method| {
        const view: visor.Size = .{ .cols = 12, .rows = 2 };
        const o = try Oracle.initKeeping(gpa, .{ .cols = 12, .rows = 5 }, method, 1000);
        defer o.deinit();
        if (method == .unicode) o.feed("\x1b[?2027h");
        o.feed("$ run\r\n");
        var screen: visor.Screen = try .init(gpa, view);
        defer screen.deinit();
        screen.method = method;
        var renderer: visor.Renderer = try .init(gpa, view);
        defer renderer.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const caps: visor.Caps = .{ .width_method = method, .truecolor = true, .osc8 = true };
        try renderer.enter(&out.writer, caps, .@"inline", .{});
        o.feed(out.written());

        var want: std.ArrayList([]const u8) = .empty;
        defer {
            for (want.items) |line| gpa.free(line);
            want.deinit(gpa);
        }
        try want.append(gpa, try gpa.dupe(u8, "$ run"));
        for (0..9) |round| {
            screen.clear();
            var buf: [32]u8 = undefined;
            _ = try screen.window().printSegment(.{ .text = try std.mem.print(&buf, "working {d}", .{round}) }, .{ .wrap = .none });
            _ = try screen.window().printSegment(.{ .text = "\u{2588}\u{2588}\u{2591}", .style = .{ .fg = .ansi(.green) } }, .{ .row = 1, .wrap = .none });

            const count: u16 = @intCast(round % 3);
            var lines: visor.Screen = try .init(gpa, .{ .cols = 12, .rows = count });
            defer lines.deinit();
            lines.method = method;
            for (0..count) |k| {
                const text = try std.mem.print(&buf, "done {d}.{d} \u{4e2d}", .{ round, k });
                _ = try lines.window().printSegment(.{ .text = text, .style = .{ .bold = k == 0 } }, .{ .row = @intCast(k), .wrap = .none });
                try want.append(gpa, try gpa.dupe(u8, text));
            }
            out.clearRetainingCapacity();
            const stats = try renderer.printAbove(&out.writer, &lines, &screen, null, caps);
            try testing.expectEqual(out.written().len, stats.bytes);
            o.feed(out.written());
            // The screen reads back where the emulator now has it.
            try expectAgreesAt(&screen, o, o.term.screens.active.saved_cursor.?.y);
        }

        // Everything printed is above the screen, the oldest in scrollback,
        // in the order it went out, and nothing else between.
        var buf: [128]u8 = undefined;
        const total = o.totalRows();
        const first_view = total - view.rows;
        try testing.expect(first_view >= want.items.len);
        var row = first_view - want.items.len;
        for (want.items) |line| {
            try testing.expectEqualStrings(line, try o.historyRow(row, &buf));
            row += 1;
        }
        try testing.expectEqualStrings("working 8", try o.historyRow(first_view, &buf));

        // Leaving keeps the last frame under the printed rows.
        out.clearRetainingCapacity();
        try renderer.leave(&out.writer);
        o.feed(out.written());
        try testing.expectEqualStrings("working 8", try o.historyRow(o.totalRows() - 3, &buf));
    }
}

/// Every column of the screen against the emulator's rows from `top`.
fn expectAgreesAt(s: *const visor.Screen, o: *const Oracle, top: u16) !void {
    var buf: [64]u8 = undefined;
    for (0..s.dimensions().rows) |row| {
        for (0..s.dimensions().cols) |col| {
            const want = s.readCell(@intCast(col), @intCast(row)).?;
            const got = try o.read(@intCast(col), @intCast(top + row), &buf);
            try testing.expectEqual(wideOf(want.shape.kind), got.wide);
            if (want.isTail()) continue;
            try testing.expectEqualStrings(s.textAt(@intCast(col), @intCast(row)), got.text);
            try testing.expect(styleAgrees(want.style, got.style));
        }
    }
}

test "inline picture corpus preserves text and cursor in the real emulator" {
    // Ghostty's pinned terminal does not draw sixel or OSC 1337 images.
    // Replay still proves their strings do not leak into text, damage and
    // removal restore the grid, and the renderer restores the cursor.
    const size: visor.Size = .{ .cols = 8, .rows = 4 };
    inline for (.{ visor.Caps.Pictures.sixel, visor.Caps.Pictures.iterm }) |protocol| {
        var screen = try visor.Screen.init(testing.allocator, size);
        defer screen.deinit();
        screen.method = .unicode;
        var renderer = try visor.Renderer.init(testing.allocator, size);
        defer renderer.deinit();
        var layers: visor.Layers = .init(testing.allocator);
        defer layers.deinit();
        layers.configureSize(.{ .cells = size, .cell = .{ .width = 1, .height = 1 } });
        const caps: visor.Caps = .{ .width_method = .unicode, .picture_protocol = protocol };
        if (protocol == .sixel) {
            try layers.storeSixel(.fromRaw(7), .{ .width = 2, .height = 2, .pixels = .{ .indexed = &.{ 0, 0, 0, 0 } }, .palette = &.{.{ .r = 255, .g = 0, .b = 0 }} });
        } else try layers.storeIterm(.fromRaw(7), "PNG", 3);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const oracle = try Oracle.init(testing.allocator, size, .unicode);
        defer oracle.deinit();
        try renderer.enter(&out.writer, caps, .alt, .{});
        oracle.feed(out.written());
        for (0..5) |frame| {
            out.clearRetainingCapacity();
            if (frame != 3) try layers.declare(.{ .image = .fromRaw(7), .rect = .{ .col = @intCast(frame % 2), .row = 0, .cols = 2, .rows = 2 } });
            if (frame == 2) _ = try screen.write(6, 2, "x", .{}, .none);
            if (frame == 4) renderer.repaint();
            _ = try renderer.draw(&out.writer, &screen, &layers, caps);
            oracle.feed(out.written());
            try expectAgrees(&screen, oracle);
        }
    }
}
