//! A clipped, offset view of a screen: the only thing drawing code holds.
//!
//! A window is a rectangle and a pointer, copied by value and made fresh
//! every frame. Everything written through one is clipped to it, so a widget
//! that draws past its edge writes nothing rather than over its neighbour.
//! Measurement allocates nothing; committed printing can grow the screen's
//! pool for an unseen grapheme longer than six bytes. The screen owns that
//! storage.
//!
//! What this file will never hold: a retained tree, a parent pointer, an
//! event, a focus model, or state that survives the frame. A window is a
//! value; if something must be remembered between frames, the caller
//! remembers it.

pub fn WindowApi(comptime screen_module: type) type {
    return struct {
        const std = @import("std");
        const morse = @import("../dependencies.zig").morse;

        const cellmod = @import("../cell.zig");
        const geom = @import("../geom.zig");
        const textmod = @import("../text.zig");
        const Screen = screen_module.Screen;
        const Target = @import("../pool.zig").Target;

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
            _screen: *Screen,
            /// Where the view is and how big, in the screen's own coordinates,
            /// already clipped to it.
            _rect: Rect,
            /// What every cell written through this window is drawn in, or null
            /// for the style it was written in. Children inherit it. A pointer, so
            /// the window a widget is handed stays three words, and the ink is the
            /// caller's to keep for as long as the window is used.
            _ink: ?*const Ink = null,

            /// The borrowed screen owner. Its lifetime and resize stay with its owner.
            /// Recreate windows after the screen is resized.
            pub fn screen(w: Window) *Screen {
                return w._screen;
            }

            /// The rectangle already clipped to that screen, by value.
            pub fn rect(w: Window) Rect {
                return w._rect;
            }

            /// The borrowed drawing policy, or null for each cell's own style.
            pub fn ink(w: Window) ?*const Ink {
                return w._ink;
            }

            /// A program's look, applied to every cell a window writes: the style a
            /// cell asked for, turned into the style it is drawn in, knowing where
            /// on the screen it lands and what it holds.
            ///
            /// It is how a program whose look depends on where a cell is (every
            /// other row dimmed, a region faded in) or that watches what is written
            /// (to light what is drawn in a bright style) draws widgets that know
            /// nothing of it, straight into the screen. It is called once for each
            /// grapheme a window writes and for each cell a fill or a border writes,
            /// and never for a cell a scroll moves; with no ink a write costs one
            /// branch more.
            pub const Ink = struct {
                /// The program's own, handed back on every call.
                ctx: *anyopaque,
                /// The style a stroke is drawn in.
                apply: *const fn (ctx: *anyopaque, stroke: Stroke) Style,

                /// One cell about to be written.
                pub const Stroke = struct {
                    /// Where, in the screen's own coordinates.
                    col: u16,
                    /// The row, in the screen's own coordinates.
                    row: u16,
                    /// How many columns it covers.
                    cols: u16,
                    /// What it holds: a grapheme, or a space for a blank.
                    text: []const u8,
                    /// The style it was written in.
                    style: Style,
                };
            };

            /// The same view, drawing in `ink`.
            pub fn inked(w: Window, drawing: ?*const Ink) Window {
                var out = w;
                out._ink = drawing;
                return out;
            }

            /// The style a cell written at a place of this window is drawn in.
            fn styled(w: Window, col: u16, row: u16, span: u16, text: []const u8, style: Style) Style {
                const drawing = w._ink orelse return style;
                return drawing.apply(drawing.ctx, .{
                    .col = w._rect.col + col,
                    .row = w._rect.row + row,
                    .cols = span,
                    .text = text,
                    .style = style,
                });
            }

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
                /// have gone. Measurement (`false`) never allocates; committing can
                /// allocate for previously unseen graphemes longer than six bytes.
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
                /// Inline printable clusters; invalid or oversized glyphs are skipped.
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
                return w._rect.cols;
            }

            /// How many rows the window is.
            pub fn rows(w: Window) u16 {
                return w._rect.rows;
            }

            /// How big the window is.
            pub fn size(w: Window) Size {
                return w._rect.size();
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
                    .col = w._rect.col +| opts.col,
                    .row = w._rect.row +| opts.row,
                    .cols = opts.cols orelse w._rect.cols -| opts.col,
                    .rows = opts.rows orelse w._rect.rows -| opts.row,
                };
                const outer = asked.intersect(w._rect);
                var c: Window = .{ ._screen = w._screen, ._rect = outer, ._ink = w._ink };
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
                return .{ ._screen = w._screen, ._rect = inner, ._ink = w._ink };
            }

            /// The sub-window over `r`, a rectangle in this window's own cells —
            /// what `Layout.split` and `Layout.repeat` hand back for an area made
            /// with `Rect.fromSize(w.size())` — clipped to this one.
            pub fn sub(w: Window, r: Rect) Window {
                return w.child(.{ .col = r.col, .row = r.row, .cols = r.cols, .rows = r.rows });
            }

            /// One cell, in this window's coordinates, clipped by its whole extent.
            /// Stale or foreign handles return `InvalidHandle`; malformed cells return `InvalidCell`.
            pub fn writeOwnedCell(w: Window, col: u16, row: u16, c: Cell) error{ InvalidHandle, InvalidCell }!void {
                const checked = try w._screen.cell(c);
                if (!w.fitsCell(col, row, checked)) return;
                var drawn = checked;
                if (w._ink != null) drawn.style = cellmod.canonical(w.styled(col, row, checked.width(), try w._screen.textOf(&checked), checked.style));
                screen_module.internal.placeCell(w._screen, w._rect.col + col, w._rect.row + row, drawn);
            }

            /// A source-terminal cell, clipped by its full extent. See Screen's
            /// writeOwnedCellUnchecked preconditions; handles are always checked.
            pub fn writeOwnedCellUnchecked(w: Window, col: u16, row: u16, c: Cell) error{InvalidHandle}!void {
                _ = try w._screen.textOf(&c);
                if (c.link != .none and w._screen.target(c.link) == null) return error.InvalidHandle;
                if (!w.fitsCell(col, row, c)) return;
                var drawn = c;
                if (w._ink != null) drawn.style = cellmod.canonical(w.styled(col, row, c.width(), try w._screen.textOf(&c), c.style));
                try w._screen.writeOwnedCellUnchecked(w._rect.col + col, w._rect.row + row, drawn);
            }

            /// Copies a cell from another screen into this window.
            /// The cell must still belong to the source's current pool generations.
            pub fn copyCell(w: Window, source: *const Screen, col: u16, row: u16, c: Cell) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
                const checked = try source.cell(c);
                if (!w.fitsCell(col, row, checked)) return;
                var drawn = checked;
                if (w._ink != null) drawn.style = cellmod.canonical(w.styled(col, row, checked.width(), try source.textOf(&checked), checked.style));
                try w._screen.copyCell(source, w._rect.col + col, w._rect.row + row, drawn);
            }

            /// What is there, or null outside the window.
            pub fn readCell(w: Window, col: u16, row: u16) ?Cell {
                if (col >= w._rect.cols or row >= w._rect.rows) return null;
                return w._screen.readCell(w._rect.col + col, w._rect.row + row);
            }

            /// A grapheme measured and placed only when its whole extent fits.
            pub fn write(
                w: Window,
                col: u16,
                row: u16,
                grapheme: []const u8,
                style: Style,
                link: Link,
            ) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
                if (link != .none and w._screen.target(link) == null) return error.InvalidHandle;
                if (grapheme.len == 0 or grapheme[0] < 0x20 or grapheme[0] == 0x7f) return;
                const valid = try screen_module.internal.glyph(grapheme);
                const span = textmod.graphemeWidth(valid, w._screen.method);
                if (!w.fits(col, row, span, 1)) return;
                const drawn = if (w._ink == null) style else w.styled(col, row, span, grapheme, style);
                try w._screen.write(w._rect.col + col, w._rect.row + row, grapheme, drawn, link);
            }

            // A window owns placement clipping; Screen owns handle checks and tails.
            fn fits(w: Window, col: u16, row: u16, span: u16, height: u16) bool {
                return col < w.cols() and row < w.rows() and @as(u32, col) + span <= w.cols() and @as(u32, row) + height <= w.rows();
            }
            fn fitsCell(w: Window, col: u16, row: u16, c: Cell) bool {
                return cellmod.internal.fits(c, col, row, w.size());
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
            ) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!bool {
                if (link != .none and w._screen.target(link) == null) return error.InvalidHandle;
                if (grapheme.len == 0 or grapheme[0] < 0x20 or grapheme[0] == 0x7f) return false;
                const valid = try screen_module.internal.glyph(grapheme);
                const tall: u16 = @max(scale, 1);
                const wide: u16 = textmod.graphemeWidth(valid, w._screen.method);
                if (col >= w._rect.cols or row >= w._rect.rows) return false;
                if (@as(u32, col) + @as(u32, wide) * tall > w._rect.cols) return false;
                if (@as(u32, row) + tall > w._rect.rows) return false;
                const drawn = if (w._ink == null) style else w.styled(col, row, wide * tall, grapheme, style);
                return w._screen.writeScaled(w._rect.col + col, w._rect.row + row, grapheme, drawn, link, scale);
            }

            /// A rectangle of one cell, in this window's coordinates.
            /// Stale or foreign handles return `InvalidHandle` before any cell changes.
            pub fn fill(w: Window, area: Rect, c: Cell) error{ InvalidHandle, InvalidCell }!void {
                _ = try w._screen.cell(c);
                const inside = area.intersect(.fromSize(w.size()));
                if (inside.isEmpty()) return;
                if (w._ink != null or (!c.isTail() and c.shape.kind != .spacer_head and (c.width() > 1 or c.rows() > 1))) {
                    // Multi-cell fills use the same extent check as direct placement.
                    // The fill's own rectangle is the boundary, not just the window.
                    const bounded = w.sub(inside);
                    var row = inside.row;
                    while (row < inside.bottom()) : (row += 1) {
                        var col = inside.col;
                        while (col < inside.right()) : (col += 1) try bounded.writeOwnedCell(col - inside.col, @intCast(row - inside.row), c);
                    }
                    return;
                }
                try w._screen.fill(.{
                    .col = w._rect.col + inside.col,
                    .row = w._rect.row + inside.row,
                    .cols = inside.cols,
                    .rows = inside.rows,
                }, c);
            }

            /// Every cell of the window blank and default.
            pub fn clear(w: Window) void {
                w.fill(.fromSize(w.size()), .blank(.{})) catch unreachable;
            }

            /// The window's rows moved by `n`, the vacated rows blank. A positive
            /// `n` moves the contents up.
            pub fn scroll(w: Window, n: i32) void {
                w._screen.scroll(w._rect, n);
            }

            /// Runs of styled, linked text laid into the window, wrapped.
            ///
            /// With `commit = false`, only measures and never allocates. Committed
            /// printing can allocate when it interns a previously unseen grapheme
            /// longer than six bytes, by the same rule as `Screen.write`. A newline
            /// always ends a row; a word break looks ahead within one segment, so a
            /// word split across two segments breaks at the join.
            pub fn print(w: Window, segments: []const Segment, opts: PrintOptions) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!Print {
                var at: Print = .{ .col = opts.col, .row = opts.row };
                if (w._rect.isEmpty()) {
                    at.overflow = segments.len != 0;
                    return at;
                }
                for (segments) |segment| at = try w.printOne(segment, opts, at);
                return at;
            }

            /// One run.
            pub fn printSegment(w: Window, segment: Segment, opts: PrintOptions) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!Print {
                return w.print(&.{segment}, opts);
            }

            /// The columns a string takes, by this screen's width method.
            pub fn width(w: Window, str: []const u8) u16 {
                return textmod.width(str, w._screen.method);
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
                if (col < w._rect.col or row < w._rect.row) return null;
                if (col >= w._rect.right() or row >= w._rect.bottom()) return null;
                return .{ .col = @intCast(col - w._rect.col), .row = @intCast(row - w._rect.row) };
            }

            /// The OSC 8 target under a cell of the window, or null: what a click
            /// there opens. A cell carries its link, so nothing has to remember
            /// where the links were drawn. The target borrows from the screen's
            /// growable link pool: interning links, compaction, resize or destruction
            /// can invalidate its slices. `Screen.dupeTarget` makes a retained copy.
            pub fn linkAt(w: Window, col: u16, row: u16) ?Target {
                if (col >= w._rect.cols or row >= w._rect.rows) return null;
                const at_col = w._rect.col + col;
                const at_row = w._rect.row + row;
                const head = w._screen.headOf(at_col, at_row) orelse Point{ .col = at_col, .row = at_row };
                const c = w._screen.readCell(head.col, head.row) orelse return null;
                return w._screen.target(c.link);
            }

            /// The text of one row of the window from column `from` up to `to`, as
            /// the terminal shows it: each grapheme once, a wide one taken whole
            /// when the range starts on its covered column, and the blanks at the
            /// end left off. What a selection copies.
            pub fn copyText(w: Window, out: *std.Io.Writer, row: u16, from: u16, to: u16) std.Io.Writer.Error!void {
                if (row >= w._rect.rows) return;
                const end = @min(to, w._rect.cols);
                const at_row = w._rect.row + row;
                var spaces: usize = 0;
                var col = from;
                while (col < end) : (col += 1) {
                    const at_col = w._rect.col + col;
                    const c = w._screen.readCell(at_col, at_row) orelse break;
                    var text: []const u8 = undefined;
                    if (c.isTail()) {
                        if (col != from) continue;
                        const head = w._screen.headOf(at_col, at_row) orelse continue;
                        text = w._screen.textAt(head.col, head.row);
                    } else text = w._screen.textOf(&c) catch @panic("invalid cell in screen");
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
                if (col >= w._rect.cols or row >= w._rect.rows) return;
                w._screen.cursor.col = w._rect.col + col;
                w._screen.cursor.row = w._rect.row + row;
                w._screen.cursor.visible = true;
            }

            /// No cursor this frame.
            pub fn hideCursor(w: Window) void {
                w._screen.cursor.visible = false;
            }

            /// The shape the terminal draws its cursor as.
            pub fn setCursorShape(w: Window, shape: morse.CursorShape) void {
                w._screen.cursor.shape = shape;
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
            ) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!Print {
                var at = from;
                if (at.row >= w._rect.rows) {
                    at.overflow = at.overflow or segment.text.len != 0;
                    return at;
                }
                var it: textmod.Graphemes = .init(segment.text);
                while (it.nextAt()) |found| {
                    const g = found.bytes;
                    if (textmod.isLineBreak(g)) {
                        at.col = 0;
                        at.row += 1;
                        if (at.row >= w._rect.rows) {
                            at.overflow = true;
                            return at;
                        }
                        continue;
                    }
                    if (opts.wrap == .word and g.len == 1 and g[0] == ' ' and at.col == 0) continue;
                    if (opts.wrap == .word and atWordStart(segment.text, found.start)) {
                        const word = wordWidth(w, segment.text, found.start);
                        if (@as(u32, at.col) + word > w._rect.cols and word <= w._rect.cols) {
                            at.col = 0;
                            at.row += 1;
                            if (at.row >= w._rect.rows) {
                                at.overflow = true;
                                return at;
                            }
                        }
                    }
                    const cluster = textmod.graphemeWidth(g, w._screen.method);
                    if (cluster == 0) continue;
                    if (@as(u32, at.col) + cluster > w._rect.cols) {
                        switch (opts.wrap) {
                            .none => {
                                at.overflow = true;
                                return at;
                            },
                            .grapheme, .word => {
                                at.col = 0;
                                at.row += 1;
                                if (at.row >= w._rect.rows) {
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
                return textmod.width(text[i..end], w._screen.method);
            }

            /// The lines and corners a bordered child is framed with.
            fn drawBorder(w: Window, border: Border) void {
                const b = border.where;
                const last_col = w._rect.cols -| 1;
                const last_row = w._rect.rows -| 1;
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
                while (col < w._rect.cols) : (col += 1) w.put(col, row, glyph, style);
            }

            /// A column of one glyph.
            fn fillColumn(w: Window, col: u16, glyph: []const u8, style: Style) void {
                var row: u16 = 0;
                while (row < w._rect.rows) : (row += 1) w.put(col, row, glyph, style);
            }

            /// One glyph, where a border's glyphs are short enough to live in a cell
            /// and an allocation would be a surprise.
            fn put(w: Window, col: u16, row: u16, glyph: []const u8, style: Style) void {
                if (glyph.len > Cell.Text.max_inline) return;
                const cluster = textmod.graphemeWidth(glyph, w._screen.method);
                if (cluster == 0) return;
                w.writeOwnedCell(col, row, .{
                    .text = .inlined(glyph),
                    .style = cellmod.canonical(style),
                    .shape = .{
                        .kind = if (cluster == 2) .wide else .narrow,
                        .drift = textmod.disagrees(glyph),
                    },
                }) catch return;
            }
        };
    };
}
