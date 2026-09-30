//! Rows in columns, with a header and a selection.
//!
//! The column widths are the layout solver's constraints, so a table is a
//! horizontal split repeated down the window and nothing else: `fixed` for a
//! date, `fill` for a name, `max` for a number that is usually short.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Align = layout.Align;
const Constraint = layout.Constraint;
const Style = visor.Style;
const Window = visor.Window;

/// One row of a table: one string a column. Named `Table.Row` outside this
/// file.
const TableRow = struct {
    /// The cells, left to right. A row with fewer than the table has
    /// columns leaves the rest blank.
    cells: []const []const u8,
    /// The style the whole row draws in.
    style: Style = .{},
};

/// The most columns a table can have.
///
/// The column rectangles are worked out on the stack once a frame, so the
/// number has to be fixed somewhere; sixty-four columns is four times what
/// fits across the widest terminal anyone uses.
pub const max_columns = 64;

/// Rows in columns, with a header and a selection.
pub const Table = struct {
    /// One row: one string a column, and the style it draws in.
    pub const Row = TableRow;

    /// The rows, in order.
    rows: []const Row,
    /// How wide each column is. One constraint a column.
    widths: []const Constraint,
    /// A row above the others that does not scroll.
    header: ?Row = null,
    /// The style the header draws in.
    header_style: Style = .{ .bold = true },
    /// The style every row is blanked to first.
    style: Style = .{},
    /// The style the selected row draws in.
    selected_style: Style = .{ .reverse = true },
    /// Drawn before the selected row.
    marker: []const u8 = "",
    /// The style the marker draws in, and the blank before every other row,
    /// or null for the row's own: the selected style beside the selected
    /// row and the table's style beside the rest.
    marker_style: ?Style = null,
    /// Cells left empty between two columns.
    column_spacing: u16 = 1,
    /// Where the text sits in each column.
    where: Align = .left,

    /// What a table remembers between frames.
    pub const State = struct {
        /// Which row is selected, or none.
        selected: ?usize = null,
        /// The first row drawn under the header.
        offset: usize = 0,

        /// Selects a row, or nothing.
        pub fn select(s: *State, which: ?usize) void {
            s.selected = which;
            if (which == null) s.offset = 0;
        }

        /// The row after this one, stopping at the last.
        pub fn next(s: *State, count: usize) void {
            if (count == 0) return s.select(null);
            s.selected = if (s.selected) |i| @min(i +| 1, count - 1) else 0;
        }

        /// The row before this one, stopping at the first.
        pub fn previous(s: *State, count: usize) void {
            if (count == 0) return s.select(null);
            s.selected = if (s.selected) |i| i -| 1 else count - 1;
        }
    };

    /// Which rows a window so many rows tall shows under the header.
    pub const Visible = struct {
        /// The first row shown.
        first: usize,
        /// How many are shown.
        count: usize,
        /// How many are not: what a head saying "N more" counts.
        hidden: usize,
    };

    /// The rows a window `height` rows tall shows under its header, the
    /// offset moved as `draw` moves it to keep the selection on screen. A
    /// program asks before it draws, to say how many more there are.
    pub fn visible(t: Table, height: u16, state: *State) Visible {
        const room = height -| @intFromBool(t.header != null);
        t.scrollIntoView(room, state);
        const count = @min(t.rows.len -| state.offset, room);
        return .{ .first = state.offset, .count = count, .hidden = t.rows.len - count };
    }

    /// Draws the header and as many rows as are left, moving the offset
    /// when the selection would otherwise be off screen.
    pub fn draw(t: Table, win: Window, state: *State) (std.mem.Allocator.Error || error{InvalidHandle})!void {
        if (win.rect.isEmpty() or t.widths.len == 0) return;

        const marker_width = win.width(t.marker);
        const body = win.child(.{ .col = marker_width, .cols = win.cols() -| marker_width });

        var columns: [max_columns]visor.Rect = undefined;
        const n = @min(t.widths.len, max_columns);
        const cells = (layout.Layout{
            .direction = .horizontal,
            .constraints = t.widths[0..n],
            .spacing = t.column_spacing,
        }).split(.fromSize(body.size()), columns[0..n]);

        var row: u16 = 0;
        if (t.header) |h| {
            win.fill(.{ .col = 0, .row = 0, .cols = win.cols(), .rows = 1 }, .blank(t.header_style)) catch unreachable;
            try t.drawRow(body, cells, 0, h, t.header_style);
            row = 1;
        }

        const shown = t.visible(win.rows(), state);
        for (shown.first..shown.first + shown.count) |which| {
            const chosen = state.selected == which;
            const style = if (chosen) t.selected_style else t.rows[which].style;
            win.fill(
                .{ .col = 0, .row = row, .cols = win.cols(), .rows = 1 },
                .blank(if (chosen) style else t.style),
            ) catch unreachable;
            if (marker_width != 0) {
                const mark_style = t.marker_style orelse if (chosen) style else t.style;
                if (chosen) {
                    _ = try win.printSegment(
                        .{ .text = t.marker, .style = mark_style },
                        .{ .col = 0, .row = row, .wrap = .none },
                    );
                } else if (t.marker_style) |blank| {
                    win.fill(.{ .col = 0, .row = row, .cols = marker_width, .rows = 1 }, .blank(blank)) catch unreachable;
                }
            }
            try t.drawRow(body, cells, row, t.rows[which], style);
            row += 1;
        }
    }

    /// One row's cells, each in its own column.
    fn drawRow(
        t: Table,
        body: Window,
        cells: []const visor.Rect,
        row: u16,
        r: Row,
        style: Style,
    ) (std.mem.Allocator.Error || error{InvalidHandle})!void {
        for (cells, 0..) |rect, i| {
            if (i >= r.cells.len) break;
            if (rect.cols == 0) continue;
            // Its own window, so text longer than the column is cut by the
            // clip rather than written over the next column.
            const cell = body.child(.{
                .col = rect.col,
                .row = row,
                .cols = rect.cols,
                .rows = 1,
            });
            const text = r.cells[i];
            const taken = @min(body.width(text), rect.cols);
            _ = try cell.printSegment(.{ .text = text, .style = style }, .{
                .col = layout.offset(rect.cols, taken, t.where),
                .wrap = .none,
            });
        }
    }

    /// Moves the offset as little as it takes to put the selection on
    /// screen, and never past the end of the rows.
    fn scrollIntoView(t: Table, room: u16, state: *State) void {
        if (room == 0) return;
        if (state.selected) |i| {
            if (i < state.offset) state.offset = i;
            if (i - state.offset >= room) state.offset = i - (room - 1);
        }
        const most = t.rows.len -| room;
        if (state.offset > most) state.offset = most;
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

const rows = [_]Table.Row{
    .{ .cells = &.{ "one", "1" } },
    .{ .cells = &.{ "two", "22" } },
    .{ .cells = &.{ "three", "333" } },
};

test "a table draws its header and its rows in their columns" {
    var h: Harness = try .init(testing.allocator, 12, 4);
    defer h.deinit();
    var state: Table.State = .{};
    try (Table{
        .rows = &rows,
        .widths = &.{ .{ .fill = 1 }, .{ .fixed = 3 } },
        .header = .{ .cells = &.{ "name", "n" } },
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\name     n
        \\one      1
        \\two      22
        \\three    333
        \\
    );
}

test "a column too narrow for its text cuts it rather than spilling" {
    var h: Harness = try .init(testing.allocator, 9, 2);
    defer h.deinit();
    var state: Table.State = .{};
    try (Table{
        .rows = &.{.{ .cells = &.{ "abcdefgh", "xy" } }},
        .widths = &.{ .{ .fixed = 4 }, .{ .fixed = 2 } },
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\abcd xy
        \\
        \\
    );
}

test "the selection scrolls under a header that does not move" {
    var h: Harness = try .init(testing.allocator, 12, 3);
    defer h.deinit();
    var state: Table.State = .{ .selected = 2 };
    try (Table{
        .rows = &rows,
        .widths = &.{ .{ .fill = 1 }, .{ .fixed = 3 } },
        .header = .{ .cells = &.{ "name", "n" } },
        .marker = "> ",
        .selected_style = .{ .bold = true },
    }).draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 1), state.offset);
    try h.expectFrame(
        \\  name   n
        \\  two    22
        \\> three  333
        \\
    );
}

test "the columns are aligned where the table says" {
    var h: Harness = try .init(testing.allocator, 11, 1);
    defer h.deinit();
    var state: Table.State = .{};
    try (Table{
        .rows = &.{.{ .cells = &.{ "ab", "cd" } }},
        .widths = &.{ .{ .fixed = 5 }, .{ .fixed = 5 } },
        .where = .right,
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\   ab    cd
        \\
    );
}

test "whatever the window, the selected row is under the header and on screen" {
    const many = [_]Table.Row{
        .{ .cells = &.{"0"} }, .{ .cells = &.{"1"} }, .{ .cells = &.{"2"} },
        .{ .cells = &.{"3"} }, .{ .cells = &.{"4"} }, .{ .cells = &.{"5"} },
    };
    const t: Table = .{
        .rows = &many,
        .widths = &.{.{ .fill = 1 }},
        .header = .{ .cells = &.{"n"} },
    };
    var window_rows: u16 = 2;
    while (window_rows <= many.len + 2) : (window_rows += 1) {
        var state: Table.State = .{};
        for (0..many.len) |chosen| {
            var h: Harness = try .init(testing.allocator, 4, window_rows);
            defer h.deinit();
            state.select(chosen);
            try t.draw(h.window(), &state);
            _ = try h.frame();

            // The header keeps its row whatever the selection is.
            try testing.expectEqualStrings("n", h.term.screen().textAt(0, 0));
            try testing.expect(chosen >= state.offset);
            try testing.expect(chosen < state.offset + window_rows - 1);
            const row: u16 = @intCast(chosen - state.offset + 1);
            try testing.expectEqualStrings(
                many[chosen].cells[0],
                h.term.screen().textAt(0, row),
            );
        }
    }
}

test "a column's text is measured the way the screen measures" {
    var h: Harness = try .initMeasured(testing.allocator, 4, 1, .wcwidth);
    defer h.deinit();
    var state: Table.State = .{};
    try (Table{
        .rows = &.{.{ .cells = &.{sign ++ "x"} }},
        .widths = &.{.{ .fixed = 4 }},
        .where = .right,
    }).draw(h.window(), &state);
    _ = try h.frame();
    // Two columns measured by codepoint, so two to the left of it.
    try testing.expectEqualStrings(sign, h.term.screen().textAt(2, 0));
}

const sign = "\u{26a0}\u{fe0f}";

test "what is shown under the header and how many are not, for a head that says so" {
    var many: [12]Table.Row = undefined;
    for (&many) |*r| r.* = .{ .cells = &.{"x"} };
    const t: Table = .{ .rows = &many, .widths = &.{.{ .fill = 1 }}, .header = .{ .cells = &.{"n"} } };
    // Six rows of window: the header and five rows, the selection at the
    // bottom once it passes them.
    var state: Table.State = .{ .selected = 9 };
    try testing.expectEqual(Table.Visible{ .first = 5, .count = 5, .hidden = 7 }, t.visible(6, &state));
    var fresh: Table.State = .{ .selected = 2 };
    try testing.expectEqual(Table.Visible{ .first = 0, .count = 5, .hidden = 7 }, t.visible(6, &fresh));
    // Without a header every row of the window is a row of the table.
    const bare: Table = .{ .rows = &many, .widths = &.{.{ .fill = 1 }} };
    var top: Table.State = .{};
    try testing.expectEqual(Table.Visible{ .first = 0, .count = 6, .hidden = 6 }, bare.visible(6, &top));
    // A window with room for the header alone shows no rows.
    var none: Table.State = .{};
    try testing.expectEqual(Table.Visible{ .first = 0, .count = 0, .hidden = 12 }, t.visible(1, &none));
    var empty: Table.State = .{};
    try testing.expectEqual(Table.Visible{ .first = 0, .count = 0, .hidden = 0 }, (Table{ .rows = &.{}, .widths = &.{.{ .fill = 1 }} }).visible(5, &empty));
}

test "what visible says is what draw draws" {
    var many: [9]Table.Row = undefined;
    const names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8" };
    var cells: [names.len][1][]const u8 = undefined;
    for (&many, &cells, names) |*r, *c, name| {
        c.* = .{name};
        r.* = .{ .cells = c };
    }
    const t: Table = .{ .rows = &many, .widths = &.{.{ .fill = 1 }}, .header = .{ .cells = &.{"n"} } };
    var window_rows: u16 = 1;
    while (window_rows <= many.len + 2) : (window_rows += 1) {
        for (0..many.len) |chosen| {
            var asked: Table.State = .{ .selected = chosen };
            const shown = t.visible(window_rows, &asked);
            var h: Harness = try .init(testing.allocator, 3, window_rows);
            defer h.deinit();
            var drawn: Table.State = .{ .selected = chosen };
            try t.draw(h.window(), &drawn);
            _ = try h.frame();
            try testing.expectEqual(asked, drawn);
            for (0..shown.count) |k| {
                try testing.expectEqualStrings(names[shown.first + k], h.term.screen().textAt(0, @intCast(k + 1)));
            }
            // And nothing under the last of them.
            if (shown.count + 1 < window_rows) {
                try testing.expectEqualStrings(" ", h.term.screen().textAt(0, @intCast(shown.count + 1)));
            }
        }
    }
}

test "a table drawn by hand at worked-out columns and the same table drawn by Table are the same cells" {
    // The shape a program hand-rolls: a bold header, a marker in its own
    // style and a blank in that style beside the other rows, the chosen row
    // reversed, and a size in a column after the names.
    const hot: Style = .{ .fg = .ansi(.yellow), .bold = true };
    const head: Style = .{ .bold = true };
    const chosen_style: Style = .{ .reverse = true };
    const cols: u16 = 14;
    const names = [_][]const u8{ "alpha", "beta", "gamma" };
    const sizes = [_][]const u8{ "12k", "3.4M", "7" };
    const sel: usize = 1;
    // The marker takes two columns; the name fills what the size's five
    // and one of spacing leave.
    const name_cols: u16 = cols - 2 - 1 - 5;

    var by_hand: Harness = try .init(testing.allocator, cols, names.len + 1);
    defer by_hand.deinit();
    const w = by_hand.window();
    try w.fill(.{ .row = 0, .cols = cols, .rows = 1 }, .blank(head));
    _ = try w.printSegment(.{ .text = "name", .style = head }, .{ .col = 2, .wrap = .none });
    _ = try w.printSegment(.{ .text = "size", .style = head }, .{ .col = 2 + name_cols + 1, .wrap = .none });
    for (names, sizes, 0..) |name, size, i| {
        const row: u16 = @intCast(i + 1);
        const on = i == sel;
        const style: Style = if (on) chosen_style else .{};
        try w.fill(.{ .row = row, .cols = cols, .rows = 1 }, .blank(style));
        if (on) {
            _ = try w.printSegment(.{ .text = "\u{25b8} ", .style = hot }, .{ .row = row, .wrap = .none });
        } else {
            try w.fill(.{ .row = row, .cols = 2, .rows = 1 }, .blank(hot));
        }
        _ = try w.printSegment(.{ .text = name, .style = style }, .{ .col = 2, .row = row, .wrap = .none });
        _ = try w.printSegment(.{ .text = size, .style = style }, .{ .col = 2 + name_cols + 1, .row = row, .wrap = .none });
    }

    var by_table: Harness = try .init(testing.allocator, cols, names.len + 1);
    defer by_table.deinit();
    var rows_buf: [names.len]Table.Row = undefined;
    var cells: [names.len][2][]const u8 = undefined;
    for (names, sizes, 0..) |name, size, i| {
        cells[i] = .{ name, size };
        rows_buf[i] = .{ .cells = &cells[i] };
    }
    var state: Table.State = .{ .selected = sel };
    try (Table{
        .rows = &rows_buf,
        .widths = &.{ .{ .fixed = name_cols }, .{ .fixed = 5 } },
        .header = .{ .cells = &.{ "name", "size" } },
        .header_style = head,
        .selected_style = chosen_style,
        .marker = "\u{25b8} ",
        .marker_style = hot,
    }).draw(by_table.window(), &state);
    _ = try by_hand.frame();
    _ = try by_table.frame();
    try visor.expectScreensEqual(&by_hand.screen, &by_table.screen);
}

test "navigation and scrolling clamp state at the usize edge" {
    var state: Table.State = .{ .selected = std.math.maxInt(usize), .offset = std.math.maxInt(usize) };
    const table: Table = .{ .rows = &.{}, .widths = &.{} };
    table.scrollIntoView(2, &state);
    try testing.expectEqual(@as(usize, 0), state.offset);
    state.next(3);
    try testing.expectEqual(@as(?usize, 2), state.selected);
}
