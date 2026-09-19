//! Items in a column, with a selection that scrolls itself into view.
//!
//! The selection and the scroll are the caller's: `State` is a struct the
//! program owns between frames, and the only thing `draw` writes back into
//! it is the offset it had to move to keep the selected item on screen.
//! That is the whole of what a list has to remember.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

/// One item of a list.
pub const Item = struct {
    /// The text, on one row, cut where it does not fit.
    text: []const u8,
    /// The style it draws in.
    style: Style = .{},
    /// The OSC 8 target it belongs to.
    link: visor.Link = .none,
};

/// Items in a column, with a selection.
pub const List = struct {
    /// The items, in order.
    items: []const Item,
    /// The style every row is blanked to first.
    style: Style = .{},
    /// The style the selected row draws in, over the item's own.
    selected_style: Style = .{ .reverse = true },
    /// Drawn before the selected item.
    marker: []const u8 = "",
    /// Drawn before every other item. Null means as many spaces as `marker`
    /// is wide, which is what keeps the text in one column.
    blank_marker: ?[]const u8 = null,
    /// Whether the selected style reaches the right edge of the window or
    /// stops at the end of the text.
    highlight_row: bool = true,

    /// What a list remembers between frames.
    pub const State = struct {
        /// Which item is selected, or none.
        selected: ?usize = null,
        /// The first item drawn.
        offset: usize = 0,

        /// Selects an item, or nothing.
        pub fn select(s: *State, which: ?usize) void {
            s.selected = which;
            if (which == null) s.offset = 0;
        }

        /// The item after this one, stopping at the last.
        pub fn next(s: *State, count: usize) void {
            if (count == 0) return s.select(null);
            s.selected = if (s.selected) |i| @min(i + 1, count - 1) else 0;
        }

        /// The item before this one, stopping at the first.
        pub fn previous(s: *State, count: usize) void {
            if (count == 0) return s.select(null);
            s.selected = if (s.selected) |i| i -| 1 else count - 1;
        }

        /// The first item.
        pub fn first(s: *State, count: usize) void {
            s.select(if (count == 0) null else 0);
        }

        /// The last item.
        pub fn last(s: *State, count: usize) void {
            s.select(if (count == 0) null else count - 1);
        }
    };

    /// Draws as many items as the window has rows, moving the offset when
    /// the selection would otherwise be off screen.
    pub fn draw(l: List, win: Window, state: *State) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const rows = win.rows();
        l.scrollIntoView(rows, state);

        const marker_width = visor.width(l.marker, .unicode);
        var row: u16 = 0;
        while (row < rows and state.offset + row < l.items.len) : (row += 1) {
            const i = state.offset + row;
            const item = l.items[i];
            const chosen = state.selected == i;
            const style = if (chosen) l.selected_style else item.style;

            if (chosen and l.highlight_row) {
                win.fill(.{ .col = 0, .row = row, .cols = win.cols(), .rows = 1 }, .blank(style));
            } else {
                win.fill(.{ .col = 0, .row = row, .cols = win.cols(), .rows = 1 }, .blank(l.style));
            }

            var col: u16 = 0;
            if (marker_width != 0) {
                const mark = if (chosen) l.marker else l.blank_marker orelse "";
                _ = try win.printSegment(
                    .{ .text = mark, .style = style },
                    .{ .col = 0, .row = row, .wrap = .none },
                );
                col = marker_width;
            }
            _ = try win.printSegment(
                .{ .text = item.text, .style = style, .link = item.link },
                .{ .col = col, .row = row, .wrap = .none },
            );
        }
    }

    /// Moves the offset as little as it takes to put the selection on
    /// screen, and never past the end of the items.
    fn scrollIntoView(l: List, rows: u16, state: *State) void {
        if (rows == 0) return;
        if (state.selected) |i| {
            if (i < state.offset) state.offset = i;
            if (i >= state.offset + rows) state.offset = i - rows + 1;
        }
        const most = l.items.len -| rows;
        if (state.offset > most) state.offset = most;
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

const three = [_]Item{ .{ .text = "alpha" }, .{ .text = "beta" }, .{ .text = "gamma" } };

test "a list draws its items in order" {
    var h: Harness = try .init(testing.allocator, 7, 3);
    defer h.deinit();
    var state: List.State = .{};
    try (List{ .items = &three }).draw(h.window(), &state);
    try h.expectFrame(
        \\alpha
        \\beta
        \\gamma
        \\
    );
}

test "a marker is drawn before the selected item and the rest line up under it" {
    var h: Harness = try .init(testing.allocator, 8, 3);
    defer h.deinit();
    var state: List.State = .{ .selected = 1 };
    try (List{
        .items = &three,
        .marker = "> ",
        .selected_style = .{ .bold = true },
        .highlight_row = false,
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\  alpha
        \\> beta
        \\  gamma
        \\
    );
    try testing.expect(h.styleAt(2, 1).bold);
    try testing.expect(!h.styleAt(2, 0).bold);
}

test "the selection scrolls itself into view, downward and back up" {
    var h: Harness = try .init(testing.allocator, 6, 2);
    defer h.deinit();
    var state: List.State = .{ .selected = 2 };
    const list: List = .{ .items = &three, .highlight_row = false };
    try list.draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 1), state.offset);
    try h.expectFrame(
        \\beta
        \\gamma
        \\
    );

    state.first(three.len);
    try list.draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 0), state.offset);
    try h.expectFrame(
        \\alpha
        \\beta
        \\
    );
}

test "an offset past the end is pulled back to the last full window" {
    var h: Harness = try .init(testing.allocator, 6, 2);
    defer h.deinit();
    var state: List.State = .{ .offset = 99 };
    try (List{ .items = &three }).draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 1), state.offset);
}

test "moving the selection stops at both ends" {
    var state: List.State = .{};
    state.next(3);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    state.next(3);
    state.next(3);
    state.next(3);
    try testing.expectEqual(@as(?usize, 2), state.selected);
    state.previous(3);
    state.previous(3);
    state.previous(3);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    state.last(3);
    try testing.expectEqual(@as(?usize, 2), state.selected);
    state.next(0);
    try testing.expectEqual(@as(?usize, null), state.selected);
}

test "the selected row is filled to the window's edge when it is highlighted" {
    var h: Harness = try .init(testing.allocator, 8, 2);
    defer h.deinit();
    var state: List.State = .{ .selected = 0 };
    try (List{
        .items = &.{ .{ .text = "ab" }, .{ .text = "cd" } },
        .selected_style = .{ .bg = .ansi(.blue) },
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\ab
        \\cd
        \\
    );
    try testing.expectEqual(visor.Color.ansi(.blue), h.styleAt(7, 0).bg);
    try testing.expectEqual(visor.Color.default, h.styleAt(7, 1).bg);
}

test "whatever the window and the selection, the selected item is on screen" {
    const items = [_]Item{
        .{ .text = "0" }, .{ .text = "1" }, .{ .text = "2" }, .{ .text = "3" },
        .{ .text = "4" }, .{ .text = "5" }, .{ .text = "6" }, .{ .text = "7" },
    };
    var rows: u16 = 1;
    while (rows <= items.len + 1) : (rows += 1) {
        // The same state through every selection in turn, so the offset the
        // last draw left is the one the next one has to cope with.
        var state: List.State = .{};
        for (0..items.len) |chosen| {
            var h: Harness = try .init(testing.allocator, 4, rows);
            defer h.deinit();
            state.select(chosen);
            try (List{ .items = &items }).draw(h.window(), &state);
            _ = try h.frame();

            try testing.expect(chosen >= state.offset);
            try testing.expect(chosen < state.offset + rows);
            const row: u16 = @intCast(chosen - state.offset);
            try testing.expectEqualStrings(
                items[chosen].text,
                h.term.screen().textAt(0, row),
            );
        }
        // And backwards, which is the other half of the scroll.
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            var h: Harness = try .init(testing.allocator, 4, rows);
            defer h.deinit();
            state.select(i);
            try (List{ .items = &items }).draw(h.window(), &state);
            try testing.expect(i >= state.offset);
            try testing.expect(i < state.offset + rows);
        }
    }
}
