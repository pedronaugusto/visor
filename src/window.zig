//! A clipped, offset view of a screen: the only thing drawing code holds.
//!
//! A window is a rectangle and a pointer, copied by value and made fresh
//! every frame. Everything written through one is clipped to it, so a widget
//! that draws past its edge writes nothing rather than over its neighbour,
//! and nothing here allocates: `print` walks the graphemes and puts them in
//! cells, and the only memory it touches is the screen's.
//!
//! What this file will never hold: a retained tree, a parent pointer, an
//! event, a focus model, or state that survives the frame. A window is a
//! value; if something must be remembered between frames, the caller
//! remembers it.

const std = @import("std");
const morse = @import("morse");

const cellmod = @import("cell.zig");
const geom = @import("geom.zig");
const textmod = @import("text.zig");
const Screen = @import("screen.zig").Screen;
const Target = @import("pool.zig").Target;

const Cell = cellmod.Cell;
const Link = cellmod.Link;
const Style = cellmod.Style;

/// A rectangle of cells.
pub const Rect = geom.Rect;
/// A place on the grid.
pub const Point = geom.Point;
/// How big something is, in cells.
pub const Size = geom.Size;

/// An offset, clipped view of a `Screen`.
pub const Window = struct {
    /// The grid this is a view of.
    screen: *Screen,
    /// Where the view is and how big, in the screen's own coordinates,
    /// already clipped to it.
    rect: Rect,

    /// Text with one style and one link.
    pub const Segment = struct {
        /// The text, which may hold newlines.
        text: []const u8,
        /// The style every cluster of it draws in.
        style: Style = .{},
        /// The OSC 8 target every cluster of it belongs to.
        link: Link = .none,
    };

    /// Where printing stopped, and whether it overflowed.
    pub const Print = struct {
        /// The column printing stopped at, in the window's coordinates.
        col: u16 = 0,
        /// The row it stopped on.
        row: u16 = 0,
        /// Whether something did not fit.
        overflow: bool = false,
    };

    /// Where to start, how to wrap, and whether to write anything.
    pub const PrintOptions = struct {
        /// The column to start at, in the window's coordinates.
        col: u16 = 0,
        /// The row to start on.
        row: u16 = 0,
        /// How a line that does not fit is broken.
        wrap: textmod.Wrap = .grapheme,
        /// Whether to write the cells, or only work out where they would
        /// have gone.
        commit: bool = true,
    };

    /// Offset, size, and a border drawn as the child is made.
    pub const ChildOptions = struct {
        /// How far right of the parent's left edge.
        col: u16 = 0,
        /// How far below the parent's top edge.
        row: u16 = 0,
        /// How wide, or null for the rest of the parent.
        cols: ?u16 = null,
        /// How tall, or null for the rest of the parent.
        rows: ?u16 = null,
        /// A border drawn around the child, which then names the inside of
        /// it.
        border: Border = .{},
    };

    /// Where a border is drawn and with which glyphs.
    pub const Border = struct {
        /// Which sides get a line.
        where: Where = .none,
        /// The six glyphs a box is made of.
        glyphs: Glyphs = .single,
        /// The style they are drawn in.
        style: Style = .{},

        /// Which sides of a window carry a line.
        pub const Where = packed struct(u4) {
            /// The line above.
            top: bool = false,
            /// The line below.
            bottom: bool = false,
            /// The line to the left.
            left: bool = false,
            /// The line to the right.
            right: bool = false,

            /// No line at all.
            pub const none: Where = .{};
            /// A line on every side.
            pub const all: Where = .{ .top = true, .bottom = true, .left = true, .right = true };

            /// Whether any side carries one.
            pub fn any(w: Where) bool {
                return w.top or w.bottom or w.left or w.right;
            }
        };

        /// The six glyphs a box is made of: two lines and four corners.
        pub const Glyphs = struct {
            /// The horizontal line, used above and below.
            horizontal: []const u8 = "\u{2500}",
            /// The vertical line, used left and right.
            vertical: []const u8 = "\u{2502}",
            /// The top-left corner.
            top_left: []const u8 = "\u{250c}",
            /// The top-right corner.
            top_right: []const u8 = "\u{2510}",
            /// The bottom-left corner.
            bottom_left: []const u8 = "\u{2514}",
            /// The bottom-right corner.
            bottom_right: []const u8 = "\u{2518}",

            /// A plain box.
            pub const single: Glyphs = .{};
            /// A box with rounded corners.
            pub const rounded: Glyphs = .{
                .top_left = "\u{256d}",
                .top_right = "\u{256e}",
                .bottom_left = "\u{2570}",
                .bottom_right = "\u{256f}",
            };
            /// A box drawn twice.
            pub const double: Glyphs = .{
                .horizontal = "\u{2550}",
                .vertical = "\u{2551}",
                .top_left = "\u{2554}",
                .top_right = "\u{2557}",
                .bottom_left = "\u{255a}",
                .bottom_right = "\u{255d}",
            };
            /// A box in heavy lines.
            pub const heavy: Glyphs = .{
                .horizontal = "\u{2501}",
                .vertical = "\u{2503}",
                .top_left = "\u{250f}",
                .top_right = "\u{2513}",
                .bottom_left = "\u{2517}",
                .bottom_right = "\u{251b}",
            };
        };
    };

    /// How many columns the window is.
    pub fn cols(w: Window) u16 {
        return w.rect.cols;
    }

    /// How many rows the window is.
    pub fn rows(w: Window) u16 {
        return w.rect.rows;
    }

    /// How big the window is.
    pub fn size(w: Window) Size {
        return w.rect.size();
    }

    /// A sub-window, clipped to this one, with an optional border drawn as
    /// it is made.
    ///
    /// A border is drawn on the edges of the rectangle the options ask for
    /// and the window that comes back is the inside of it, so a caller draws
    /// into the child without knowing whether there is a frame around it.
    /// Everything is clipped: a child asked for outside the parent comes
    /// back empty rather than wrong.
    pub fn child(w: Window, opts: ChildOptions) Window {
        const asked: Rect = .{
            .col = w.rect.col +| opts.col,
            .row = w.rect.row +| opts.row,
            .cols = opts.cols orelse w.rect.cols -| opts.col,
            .rows = opts.rows orelse w.rect.rows -| opts.row,
        };
        const outer = asked.intersect(w.rect);
        var c: Window = .{ .screen = w.screen, .rect = outer };
        if (!opts.border.where.any() or outer.isEmpty()) return c;

        c.drawBorder(opts.border);
        const b = opts.border.where;
        var inner = outer;
        if (b.top) {
            inner.row +|= 1;
            inner.rows -|= 1;
        }
        if (b.bottom) inner.rows -|= 1;
        if (b.left) {
            inner.col +|= 1;
            inner.cols -|= 1;
        }
        if (b.right) inner.cols -|= 1;
        return .{ .screen = w.screen, .rect = inner };
    }

    /// One cell, in this window's coordinates, clipped.
    pub fn writeOwnedCell(w: Window, col: u16, row: u16, c: Cell) void {
        if (col >= w.rect.cols or row >= w.rect.rows) return;
        w.screen.writeOwnedCell(w.rect.col + col, w.rect.row + row, c);
    }

    /// Copies a cell from another screen into this window.
    pub fn copyCell(w: Window, source: *const Screen, col: u16, row: u16, c: Cell) std.mem.Allocator.Error!void {
        if (col >= w.rect.cols or row >= w.rect.rows) return;
        try w.screen.copyCell(source, w.rect.col + col, w.rect.row + row, c);
    }

    /// What is there, or null outside the window.
    pub fn readCell(w: Window, col: u16, row: u16) ?Cell {
        if (col >= w.rect.cols or row >= w.rect.rows) return null;
        return w.screen.readCell(w.rect.col + col, w.rect.row + row);
    }

    /// A grapheme measured, placed, and its tail written if it is wide.
    pub fn write(
        w: Window,
        col: u16,
        row: u16,
        grapheme: []const u8,
        style: Style,
        link: Link,
    ) std.mem.Allocator.Error!void {
        if (col >= w.rect.cols or row >= w.rect.rows) return;
        try w.screen.write(w.rect.col + col, w.rect.row + row, grapheme, style, link);
    }

    /// A grapheme drawn `scale` cells tall and `scale` times its width
    /// across, in this window's coordinates. The block has to fit inside
    /// the window, or nothing is written and the answer is false.
    pub fn writeScaled(
        w: Window,
        col: u16,
        row: u16,
        grapheme: []const u8,
        style: Style,
        link: Link,
        scale: u3,
    ) std.mem.Allocator.Error!bool {
        const tall: u16 = @max(scale, 1);
        const wide: u16 = textmod.graphemeWidth(grapheme, w.screen.method);
        if (col >= w.rect.cols or row >= w.rect.rows) return false;
        if (@as(u32, col) + @as(u32, wide) * tall > w.rect.cols) return false;
        if (@as(u32, row) + tall > w.rect.rows) return false;
        return w.screen.writeScaled(w.rect.col + col, w.rect.row + row, grapheme, style, link, scale);
    }

    /// A rectangle of one cell, in this window's coordinates.
    pub fn fill(w: Window, rect: Rect, c: Cell) void {
        const inside = rect.intersect(.fromSize(w.size()));
        if (inside.isEmpty()) return;
        w.screen.fill(.{
            .col = w.rect.col + inside.col,
            .row = w.rect.row + inside.row,
            .cols = inside.cols,
            .rows = inside.rows,
        }, c);
    }

    /// Every cell of the window blank and default.
    pub fn clear(w: Window) void {
        w.fill(.fromSize(w.size()), .blank(.{}));
    }

    /// The window's rows moved by `n`, the vacated rows blank. A positive
    /// `n` moves the contents up.
    pub fn scroll(w: Window, n: i32) void {
        w.screen.scroll(w.rect, n);
    }

    /// Runs of styled, linked text laid into the window, wrapped.
    ///
    /// Never allocates. A newline in a segment always ends a row; a word
    /// break looks ahead within one segment, so a word split across two
    /// segments breaks at the join.
    pub fn print(w: Window, segments: []const Segment, opts: PrintOptions) std.mem.Allocator.Error!Print {
        var at: Print = .{ .col = opts.col, .row = opts.row };
        if (w.rect.isEmpty()) {
            at.overflow = segments.len != 0;
            return at;
        }
        for (segments) |segment| at = try w.printOne(segment, opts, at);
        return at;
    }

    /// One run.
    pub fn printSegment(w: Window, segment: Segment, opts: PrintOptions) std.mem.Allocator.Error!Print {
        return w.print(&.{segment}, opts);
    }

    /// The columns a string takes, by this screen's width method.
    pub fn width(w: Window, str: []const u8) u16 {
        return textmod.width(str, w.screen.method);
    }

    /// A mouse report in this window's own coordinates, or null when it fell
    /// outside.
    ///
    /// Cells only. A report in pixels is refused rather than divided: the
    /// terminal has already done the rounding for the cell report, and the
    /// division a caller would have to do here is wrong wherever the
    /// terminal pads its text area or rounds its cell metrics.
    pub fn hit(w: Window, mouse: morse.MouseEvent) ?Point {
        if (mouse.pixels) return null;
        if (mouse.x == 0 or mouse.y == 0) return null;
        const col = mouse.x - 1;
        const row = mouse.y - 1;
        if (col < w.rect.col or row < w.rect.row) return null;
        if (col >= w.rect.right() or row >= w.rect.bottom()) return null;
        return .{ .col = @intCast(col - w.rect.col), .row = @intCast(row - w.rect.row) };
    }

    /// The OSC 8 target under a cell of the window, or null: what a click
    /// there opens. A cell carries its link, so nothing has to remember
    /// where the links were drawn.
    pub fn linkAt(w: Window, col: u16, row: u16) ?Target {
        if (col >= w.rect.cols or row >= w.rect.rows) return null;
        const at_col = w.rect.col + col;
        const at_row = w.rect.row + row;
        const head = w.screen.headOf(at_col, at_row) orelse Point{ .col = at_col, .row = at_row };
        const c = w.screen.readCell(head.col, head.row) orelse return null;
        return w.screen.target(c.link);
    }

    /// The text of one row of the window from column `from` up to `to`, as
    /// the terminal shows it: each grapheme once, a wide one taken whole
    /// when the range starts on its covered column, and the blanks at the
    /// end left off. What a selection copies.
    pub fn copyText(w: Window, out: *std.Io.Writer, row: u16, from: u16, to: u16) std.Io.Writer.Error!void {
        if (row >= w.rect.rows) return;
        const end = @min(to, w.rect.cols);
        const at_row = w.rect.row + row;
        var spaces: usize = 0;
        var col = from;
        while (col < end) : (col += 1) {
            const at_col = w.rect.col + col;
            const c = w.screen.readCell(at_col, at_row) orelse break;
            var text: []const u8 = undefined;
            if (c.isTail()) {
                if (col != from) continue;
                const head = w.screen.headOf(at_col, at_row) orelse continue;
                text = w.screen.textAt(head.col, head.row);
            } else text = w.screen.textOf(&c);
            if (std.mem.eql(u8, text, " ")) {
                spaces += 1;
                continue;
            }
            try out.splatByteAll(' ', spaces);
            spaces = 0;
            try out.writeAll(text);
        }
    }

    /// Where the terminal's cursor should end the frame, in this window's
    /// coordinates.
    pub fn showCursor(w: Window, col: u16, row: u16) void {
        if (col >= w.rect.cols or row >= w.rect.rows) return;
        w.screen.cursor.col = w.rect.col + col;
        w.screen.cursor.row = w.rect.row + row;
        w.screen.cursor.visible = true;
    }

    /// No cursor this frame.
    pub fn hideCursor(w: Window) void {
        w.screen.cursor.visible = false;
    }

    /// The shape the terminal draws its cursor as.
    pub fn setCursorShape(w: Window, shape: morse.CursorShape) void {
        w.screen.cursor.shape = shape;
    }

    //=====================================================================
    // Printing.
    //=====================================================================

    /// One segment, continuing from wherever the last one stopped.
    fn printOne(
        w: Window,
        segment: Segment,
        opts: PrintOptions,
        from: Print,
    ) std.mem.Allocator.Error!Print {
        var at = from;
        var it: textmod.Graphemes = .init(segment.text);
        while (it.nextAt()) |found| {
            const g = found.bytes;
            if (g.len == 1 and g[0] == '\n') {
                at.col = 0;
                at.row += 1;
                if (at.row >= w.rect.rows) {
                    at.overflow = true;
                    return at;
                }
                continue;
            }
            if (opts.wrap == .word and g.len == 1 and g[0] == ' ' and at.col == 0) continue;
            if (opts.wrap == .word and atWordStart(segment.text, found.start)) {
                const word = wordWidth(w, segment.text, found.start);
                if (at.col + word > w.rect.cols and word <= w.rect.cols) {
                    at.col = 0;
                    at.row += 1;
                    if (at.row >= w.rect.rows) {
                        at.overflow = true;
                        return at;
                    }
                }
            }
            const cluster = textmod.graphemeWidth(g, w.screen.method);
            if (cluster == 0) continue;
            if (at.col + cluster > w.rect.cols) {
                switch (opts.wrap) {
                    .none => {
                        at.overflow = true;
                        return at;
                    },
                    .grapheme, .word => {
                        at.col = 0;
                        at.row += 1;
                        if (at.row >= w.rect.rows) {
                            at.overflow = true;
                            return at;
                        }
                    },
                }
            }
            if (opts.commit) try w.write(at.col, at.row, g, segment.style, segment.link);
            at.col += cluster;
        }
        return at;
    }

    /// Whether the cluster at `i` begins a word, for the word wrap.
    fn atWordStart(text: []const u8, i: usize) bool {
        if (i == 0) return true;
        const before = text[i - 1];
        if (before == ' ' or before == '\n') return text[i] != ' ' and text[i] != '\n';
        return false;
    }

    /// How wide the word starting at `i` is.
    fn wordWidth(w: Window, text: []const u8, i: usize) u16 {
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
        return textmod.width(text[i..end], w.screen.method);
    }

    /// The lines and corners a bordered child is framed with.
    fn drawBorder(w: Window, border: Border) void {
        const b = border.where;
        const last_col = w.rect.cols -| 1;
        const last_row = w.rect.rows -| 1;
        const glyphs = border.glyphs;

        if (b.top) w.fillLine(0, glyphs.horizontal, border.style);
        if (b.bottom and last_row != 0) w.fillLine(last_row, glyphs.horizontal, border.style);
        if (b.left) w.fillColumn(0, glyphs.vertical, border.style);
        if (b.right and last_col != 0) w.fillColumn(last_col, glyphs.vertical, border.style);

        if (b.top and b.left) w.put(0, 0, glyphs.top_left, border.style);
        if (b.top and b.right) w.put(last_col, 0, glyphs.top_right, border.style);
        if (b.bottom and b.left) w.put(0, last_row, glyphs.bottom_left, border.style);
        if (b.bottom and b.right) w.put(last_col, last_row, glyphs.bottom_right, border.style);
    }

    /// A row of one glyph.
    fn fillLine(w: Window, row: u16, glyph: []const u8, style: Style) void {
        var col: u16 = 0;
        while (col < w.rect.cols) : (col += 1) w.put(col, row, glyph, style);
    }

    /// A column of one glyph.
    fn fillColumn(w: Window, col: u16, glyph: []const u8, style: Style) void {
        var row: u16 = 0;
        while (row < w.rect.rows) : (row += 1) w.put(col, row, glyph, style);
    }

    /// One glyph, where a border's glyphs are short enough to live in a cell
    /// and an allocation would be a surprise.
    fn put(w: Window, col: u16, row: u16, glyph: []const u8, style: Style) void {
        if (glyph.len > Cell.Text.max_inline) return;
        const cluster = textmod.graphemeWidth(glyph, w.screen.method);
        if (cluster == 0) return;
        w.writeOwnedCell(col, row, .{
            .text = .inlined(glyph),
            .style = cellmod.canonical(style),
            .shape = .{
                .kind = if (cluster == 2) .wide else .narrow,
                .drift = textmod.disagrees(glyph),
            },
        });
    }
};

const testing = std.testing;

fn made(cols: u16, rows: u16) !Screen {
    var s: Screen = try .init(testing.allocator, .{ .cols = cols, .rows = rows });
    s.method = .unicode;
    return s;
}

/// A press at a place, counting from one as a mouse report does.
fn mouseAt(x: u32, y: u32) morse.MouseEvent {
    return .{ .button = .left, .press = true, .x = x, .y = y };
}

fn rowText(s: *const Screen, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var col: u16 = 0;
    while (col < s.size.cols) : (col += 1) {
        const g = s.textAt(col, row);
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

test "the whole grid is a window and a child is inside it" {
    var s = try made(10, 4);
    defer s.deinit(testing.allocator);

    const root = s.window();
    try testing.expectEqual(@as(u16, 10), root.cols());
    try testing.expectEqual(@as(u16, 4), root.rows());

    const c = root.child(.{ .col = 2, .row = 1, .cols = 4, .rows = 2 });
    try testing.expectEqual(Rect{ .col = 2, .row = 1, .cols = 4, .rows = 2 }, c.rect);
    c.writeOwnedCell(0, 0, .init(.{ .text = .inlined("x") }));
    try testing.expectEqualStrings("x", s.textAt(2, 1));
}

test "a child asked for outside its parent comes back empty" {
    var s = try made(10, 4);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 20, .row = 20, .cols = 4, .rows = 4 });
    try testing.expect(c.rect.isEmpty());
    c.writeOwnedCell(0, 0, .init(.{ .text = .inlined("x") }));
    try testing.expect(!s.damage.any());
}

test "a child with no size given is the rest of the parent" {
    var s = try made(10, 4);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 3, .row = 1 });
    try testing.expectEqual(@as(u16, 7), c.cols());
    try testing.expectEqual(@as(u16, 3), c.rows());
}

test "a write past the window's edge writes nothing at all" {
    var s = try made(6, 2);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 1, .row = 0, .cols = 2, .rows = 1 });
    c.writeOwnedCell(5, 0, .init(.{ .text = .inlined("x") }));
    c.writeOwnedCell(0, 5, .init(.{ .text = .inlined("x") }));
    try testing.expect(!s.damage.any());
    try testing.expectEqual(@as(?Cell, null), c.readCell(2, 0));
}

test "a bordered child draws its frame and names the inside" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);
    const inside = s.window().child(.{ .border = .{ .where = .all } });
    try testing.expectEqual(Rect{ .col = 1, .row = 1, .cols = 4, .rows = 2 }, inside.rect);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\u{250c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("\u{2502}    \u{2502}", rowText(&s, 1, &buf));
    try testing.expectEqualStrings("\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}", rowText(&s, 3, &buf));
}

test "a border on one side takes one row from that side only" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);
    const inside = s.window().child(.{ .border = .{ .where = .{ .top = true } } });
    try testing.expectEqual(Rect{ .col = 0, .row = 1, .cols = 6, .rows = 3 }, inside.rect);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\u{2500}" ** 6, rowText(&s, 0, &buf));
}

test "print lays text out and says where it stopped" {
    var s = try made(10, 2);
    defer s.deinit(testing.allocator);
    const at = try s.window().print(&.{
        .{ .text = "ab", .style = .{ .bold = true } },
        .{ .text = "cd" },
    }, .{});
    try testing.expectEqual(@as(u16, 4), at.col);
    try testing.expectEqual(@as(u16, 0), at.row);
    try testing.expect(!at.overflow);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd      ", rowText(&s, 0, &buf));
    try testing.expect(s.readCell(1, 0).?.style.bold);
    try testing.expect(!s.readCell(2, 0).?.style.bold);
}

test "print wrapping by grapheme fills each row before the next" {
    var s = try made(3, 3);
    defer s.deinit(testing.allocator);
    const at = try s.window().printSegment(.{ .text = "abcdefg" }, .{ .wrap = .grapheme });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("def", rowText(&s, 1, &buf));
    try testing.expectEqualStrings("g  ", rowText(&s, 2, &buf));
    try testing.expectEqual(@as(u16, 1), at.col);
    try testing.expectEqual(@as(u16, 2), at.row);
}

test "print wrapping by word breaks at a space" {
    var s = try made(10, 3);
    defer s.deinit(testing.allocator);
    _ = try s.window().printSegment(.{ .text = "the quick brown fox" }, .{ .wrap = .word });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("the quick ", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("brown fox ", rowText(&s, 1, &buf));
}

test "print not wrapping drops what does not fit and says so" {
    var s = try made(4, 2);
    defer s.deinit(testing.allocator);
    const at = try s.window().printSegment(.{ .text = "abcdefg" }, .{ .wrap = .none });
    try testing.expect(at.overflow);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("    ", rowText(&s, 1, &buf));
}

test "print measuring only writes nothing" {
    var s = try made(10, 2);
    defer s.deinit(testing.allocator);
    const at = try s.window().printSegment(.{ .text = "abcd" }, .{ .commit = false });
    try testing.expectEqual(@as(u16, 4), at.col);
    try testing.expect(!s.damage.any());
}

test "a newline in a segment ends the row whatever the wrap is" {
    var s = try made(6, 3);
    defer s.deinit(testing.allocator);
    _ = try s.window().printSegment(.{ .text = "ab\ncd" }, .{ .wrap = .none });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ab    ", rowText(&s, 0, &buf));
    try testing.expectEqualStrings("cd    ", rowText(&s, 1, &buf));
}

test "a wide grapheme never straddles the window's right edge" {
    var s = try made(3, 2);
    defer s.deinit(testing.allocator);
    _ = try s.window().printSegment(.{ .text = "ab\u{4e2d}" }, .{ .wrap = .grapheme });
    try testing.expectEqualStrings("\u{4e2d}", s.textAt(0, 1));
    try testing.expectEqual(Cell.Kind.spacer_tail, s.readCell(1, 1).?.shape.kind);
}

test "a link on a segment reaches every cell of it" {
    var s = try made(8, 1);
    defer s.deinit(testing.allocator);
    const l = try s.link(testing.allocator, "https://ziglang.org", "");
    _ = try s.window().printSegment(.{ .text = "zig", .link = l }, .{});
    for (0..3) |col| try testing.expectEqual(l, s.readCell(@intCast(col), 0).?.link);
    try testing.expectEqual(Link.none, s.readCell(3, 0).?.link);
}

test "width measures by the screen's own method" {
    var s = try made(8, 1);
    defer s.deinit(testing.allocator);
    const w = s.window();
    try testing.expectEqual(@as(u16, 3), w.width("abc"));
    try testing.expectEqual(@as(u16, 2), w.width("\u{4e2d}"));
    try testing.expectEqual(@as(u16, 1), w.width("e\u{301}"));
}

test "a mouse report lands in the window's own coordinates or nowhere" {
    var s = try made(20, 10);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 4, .row = 2, .cols = 6, .rows = 3 });

    // Mouse reports count from one.
    try testing.expectEqual(Point{ .col = 0, .row = 0 }, c.hit(mouseAt(5, 3)).?);
    try testing.expectEqual(Point{ .col = 5, .row = 2 }, c.hit(mouseAt(10, 5)).?);
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(4, 3)));
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(11, 3)));
    try testing.expectEqual(@as(?Point, null), c.hit(mouseAt(5, 6)));
}

test "a mouse report in pixels is refused rather than divided" {
    var s = try made(20, 10);
    defer s.deinit(testing.allocator);
    var event = mouseAt(5, 3);
    event.pixels = true;
    try testing.expectEqual(@as(?Point, null), s.window().hit(event));
}

test "the cursor is set in the window's coordinates" {
    var s = try made(20, 10);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 4, .row = 2, .cols = 6, .rows = 3 });
    c.showCursor(1, 1);
    try testing.expectEqual(@as(u16, 5), s.cursor.col);
    try testing.expectEqual(@as(u16, 3), s.cursor.row);
    try testing.expect(s.cursor.visible);
    c.setCursorShape(.bar);
    try testing.expectEqual(morse.CursorShape.bar, s.cursor.shape);
    c.hideCursor();
    try testing.expect(!s.cursor.visible);
    c.showCursor(99, 0);
    try testing.expect(!s.cursor.visible);
}

test "fill and clear stay inside the window" {
    var s = try made(6, 3);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 1, .row = 1, .cols = 3, .rows = 1 });
    c.fill(.fromSize(c.size()), .blank(.{ .bg = .ansi(.blue) }));
    try testing.expect(s.readCell(0, 1).?.eql(.blank(.{})));
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{ .bg = .ansi(.blue) })));
    try testing.expect(s.readCell(4, 1).?.eql(.blank(.{})));
    c.clear();
    try testing.expect(s.readCell(1, 1).?.eql(.blank(.{})));
}

test "a window scrolls only its own rectangle" {
    var s = try made(6, 4);
    defer s.deinit(testing.allocator);
    const c = s.window().child(.{ .col = 0, .row = 1, .cols = 6, .rows = 2 });
    try s.write(0, 0, "a", .{}, .none);
    try s.write(0, 1, "b", .{}, .none);
    try s.write(0, 2, "c", .{}, .none);
    try s.write(0, 3, "d", .{}, .none);
    c.scroll(1);
    try testing.expectEqualStrings("a", s.textAt(0, 0));
    try testing.expectEqualStrings("c", s.textAt(0, 1));
    try testing.expectEqualStrings(" ", s.textAt(0, 2));
    try testing.expectEqualStrings("d", s.textAt(0, 3));
}

test "the link under a cell is what a click there opens, a wide grapheme's in both its columns" {
    var sc: Screen = try .init(testing.allocator, .{ .cols = 10, .rows = 2 });
    defer sc.deinit(testing.allocator);
    const win = sc.window().child(.{ .col = 2, .row = 1 });
    const link = try sc.link(testing.allocator, "file:///tmp/a.log", "");
    _ = try win.print(&.{
        .{ .text = "see " },
        .{ .text = "a\u{4e2d}", .link = link },
    }, .{ .wrap = .none });
    try testing.expect(win.linkAt(0, 0) == null);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(4, 0).?.uri);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(5, 0).?.uri);
    try testing.expectEqualStrings("file:///tmp/a.log", win.linkAt(6, 0).?.uri);
    try testing.expect(win.linkAt(7, 0) == null);
    try testing.expect(win.linkAt(40, 0) == null);
}

test "a row's text comes back as the terminal shows it, trailing blanks left off" {
    var sc: Screen = try .init(testing.allocator, .{ .cols = 12, .rows = 1 });
    defer sc.deinit(testing.allocator);
    const win = sc.window();
    _ = try win.printSegment(.{ .text = "a b\u{4e2d}c" }, .{ .wrap = .none });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try win.copyText(&out.writer, 0, 0, 12);
    try testing.expectEqualStrings("a b\u{4e2d}c", out.written());
    // Starting on the covered column takes the grapheme whole.
    out.clearRetainingCapacity();
    try win.copyText(&out.writer, 0, 4, 6);
    try testing.expectEqualStrings("\u{4e2d}c", out.written());
    // A range ending on the head's first column takes it once.
    out.clearRetainingCapacity();
    try win.copyText(&out.writer, 0, 1, 4);
    try testing.expectEqualStrings(" b\u{4e2d}", out.written());
}
