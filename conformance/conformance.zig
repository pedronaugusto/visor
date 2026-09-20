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
//!   a wide cluster included, its grapheme, its width and its style.
//! - **Drawing again writes nothing.**
//! - **A repaint recovers from anything.**
//! - **Incremental equals a repaint.**
//!
//! And twice, once with the terminal measuring by codepoint and once with it
//! in mode 2027 measuring whole clusters, because the rule that repaints a
//! drifting row exists for the case where the two models disagree.
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
        return .{ .text = buf[0..n], .wide = found.cell.wide, .style = found.style() };
    }
};

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
fn randomRect(smith: *Smith, cols: u16, rows: u16) visor.Rect {
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
        while (ops < count) : (ops += 1) try operate(&h, smith);

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
