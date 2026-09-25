//! A frame around a window: its border, its titles and its padding.
//!
//! `Block` is the widget every other widget is usually drawn inside, so it
//! gives back the window that is left: the caller draws into what `draw`
//! returns and never has to know whether there was a frame around it.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Align = layout.Align;
const Padding = layout.Padding;
const Style = visor.Style;
const Window = visor.Window;

/// A frame, a title and padding around a window.
pub const Block = struct {
    /// Which sides carry a line.
    borders: Window.Border.Where = .none,
    /// The six glyphs the frame is drawn with.
    glyphs: Window.Border.Glyphs = .single,
    /// The style the frame is drawn in.
    border_style: Style = .{},
    /// A title on the top row.
    title: ?Title = null,
    /// A title on the bottom row.
    title_bottom: ?Title = null,
    /// Cells taken off the inside of the frame.
    padding: Padding = .{},
    /// A style every cell inside the frame, the frame included, is blanked
    /// to first. Null leaves what is already there, which is what a block
    /// drawn over a background wants.
    style: ?Style = null,
    /// Corners marked with the frame's corner glyphs and no line between
    /// them: a reticle, or a pair of brackets at opposite corners. They take
    /// no room from the inside, and need a window at least two cells each
    /// way.
    corners: Corners = .{},

    /// Which corners carry a mark.
    pub const Corners = packed struct(u4) {
        top_left: bool = false,
        top_right: bool = false,
        bottom_left: bool = false,
        bottom_right: bool = false,

        /// All four.
        pub const all: Corners = .{ .top_left = true, .top_right = true, .bottom_left = true, .bottom_right = true };
        /// The top-left and the bottom-right: a frame implied, never drawn.
        pub const diagonal: Corners = .{ .top_left = true, .bottom_right = true };
    };

    /// Text on one of the frame's rows.
    pub const Title = struct {
        /// The text, drawn on one row and cut where it does not fit.
        text: []const u8,
        /// The style it is drawn in.
        style: Style = .{},
        /// Where along the row it sits.
        where: Align = .left,
    };

    /// Draws the frame and gives back the window inside it.
    ///
    /// The window that comes back is the inside of the border, less the
    /// padding, and is empty when there is nothing left — so a caller draws
    /// into it without checking, and a block in a window two cells tall
    /// writes its frame and nothing else.
    pub fn draw(b: Block, win: Window) std.mem.Allocator.Error!Window {
        if (win.rect.isEmpty()) return win;
        if (b.style) |s| win.fill(.fromSize(win.size()), .blank(s));

        const inner = win.child(.{ .border = .{
            .where = b.borders,
            .glyphs = b.glyphs,
            .style = b.border_style,
        } });

        if (win.cols() >= 2 and win.rows() >= 2) {
            const right = win.cols() - 1;
            const bottom = win.rows() - 1;
            if (b.corners.top_left) try win.write(0, 0, b.glyphs.top_left, b.border_style, .none);
            if (b.corners.top_right) try win.write(right, 0, b.glyphs.top_right, b.border_style, .none);
            if (b.corners.bottom_left) try win.write(0, bottom, b.glyphs.bottom_left, b.border_style, .none);
            if (b.corners.bottom_right) try win.write(right, bottom, b.glyphs.bottom_right, b.border_style, .none);
        }

        if (b.title) |t| try b.drawTitle(win, 0, t);
        if (b.title_bottom) |t| try b.drawTitle(win, win.rows() -| 1, t);

        return inner.child(.{
            .col = b.padding.left,
            .row = b.padding.top,
            .cols = inner.cols() -| b.padding.left -| b.padding.right,
            .rows = inner.rows() -| b.padding.top -| b.padding.bottom,
        });
    }

    /// One title, between the two vertical sides of the frame.
    fn drawTitle(b: Block, win: Window, row: u16, t: Title) std.mem.Allocator.Error!void {
        const left: u16 = if (b.borders.left) 1 else 0;
        const right: u16 = if (b.borders.right) 1 else 0;
        const room = win.cols() -| left -| right;
        if (room == 0 or row >= win.rows()) return;
        const taken = @min(win.width(t.text), room);
        _ = try win.printSegment(
            .{ .text = t.text, .style = t.style },
            .{ .col = left + layout.offset(room, taken, t.where), .row = row, .wrap = .none },
        );
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a block draws its frame and gives back the inside" {
    var h: Harness = try .init(testing.allocator, 10, 4);
    defer h.deinit();

    const inner = try (Block{ .borders = .all }).draw(h.window());
    try testing.expectEqual(@as(u16, 8), inner.cols());
    try testing.expectEqual(@as(u16, 2), inner.rows());
    _ = try inner.printSegment(.{ .text = "hello" }, .{});

    try h.expectFrame(
        \\┌────────┐
        \\│hello   │
        \\│        │
        \\└────────┘
        \\
    );
}

test "a title sits where it is told between the frame's sides" {
    var h: Harness = try .init(testing.allocator, 12, 3);
    defer h.deinit();
    _ = try (Block{
        .borders = .all,
        .glyphs = .rounded,
        .title = .{ .text = "one", .where = .center },
        .title_bottom = .{ .text = "two", .where = .right },
    }).draw(h.window());
    try h.expectFrame(
        \\╭───one────╮
        \\│          │
        \\╰───────two╯
        \\
    );
}

test "padding takes cells off the inside and nothing off the frame" {
    var h: Harness = try .init(testing.allocator, 9, 5);
    defer h.deinit();
    const inner = try (Block{ .borders = .all, .padding = .all(1) }).draw(h.window());
    try testing.expectEqual(visor.Rect{ .col = 2, .row = 2, .cols = 5, .rows = 1 }, inner.rect);
    _ = try inner.printSegment(.{ .text = "abcdefgh" }, .{ .wrap = .none });
    try h.expectFrame(
        \\┌───────┐
        \\│       │
        \\│ abcde │
        \\│       │
        \\└───────┘
        \\
    );
}

test "a block with no room left gives back an empty window" {
    var h: Harness = try .init(testing.allocator, 4, 2);
    defer h.deinit();
    const inner = try (Block{ .borders = .all, .padding = .all(2) }).draw(h.window());
    try testing.expect(inner.rect.isEmpty());
    try h.expectFrame(
        \\┌──┐
        \\└──┘
        \\
    );
}

test "a block's own style blanks what was under it" {
    var h: Harness = try .init(testing.allocator, 6, 2);
    defer h.deinit();
    _ = try h.window().printSegment(.{ .text = "xxxxxx" }, .{});
    _ = try (Block{ .style = .{ .bg = .ansi(.blue) } }).draw(h.window());
    try h.expectFrame(
        \\
        \\
        \\
    );
    try testing.expectEqual(visor.Color.ansi(.blue), h.styleAt(0, 0).bg);
}

test "corners mark a frame without drawing it, and take no room from the inside" {
    var h: Harness = try .init(testing.allocator, 8, 4);
    defer h.deinit();
    const inner = try (Block{
        .corners = .diagonal,
        .border_style = .{ .dim = true },
        .padding = .{ .left = 2, .right = 2, .top = 1, .bottom = 1 },
    }).draw(h.window());
    try testing.expectEqual(visor.Rect{ .col = 2, .row = 1, .cols = 4, .rows = 2 }, inner.rect);
    _ = try inner.printSegment(.{ .text = "abcd" }, .{});
    try h.expectFrame(
        \\┌
        \\  abcd
        \\
        \\       ┘
        \\
    );
    try testing.expect(h.styleAt(0, 0).dim);

    h.window().clear();
    _ = try (Block{ .corners = .all, .glyphs = .rounded }).draw(h.window().child(.{ .cols = 3, .rows = 2 }));
    try h.expectFrame(
        \\╭ ╮
        \\╰ ╯
        \\
        \\
        \\
    );
}
