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

/// One row of a table: one string a column.
pub const Row = struct {
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
            s.selected = if (s.selected) |i| @min(i + 1, count - 1) else 0;
        }

        /// The row before this one, stopping at the first.
        pub fn previous(s: *State, count: usize) void {
            if (count == 0) return s.select(null);
            s.selected = if (s.selected) |i| i -| 1 else count - 1;
        }
    };

    /// Draws the header and as many rows as are left, moving the offset
    /// when the selection would otherwise be off screen.
    pub fn draw(t: Table, win: Window, state: *State) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty() or t.widths.len == 0) return;

        const marker_width = visor.width(t.marker, .unicode);
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
            win.fill(.{ .col = 0, .row = 0, .cols = win.cols(), .rows = 1 }, .blank(t.header_style));
            try t.drawRow(body, cells, 0, h, t.header_style);
            row = 1;
        }

        const body_rows = win.rows() -| row;
        t.scrollIntoView(body_rows, state);

        var i: usize = 0;
        while (row < win.rows() and state.offset + i < t.rows.len) : ({
            row += 1;
            i += 1;
        }) {
            const which = state.offset + i;
            const chosen = state.selected == which;
            const style = if (chosen) t.selected_style else t.rows[which].style;
            win.fill(
                .{ .col = 0, .row = row, .cols = win.cols(), .rows = 1 },
                .blank(if (chosen) style else t.style),
            );
            if (chosen and marker_width != 0) {
                _ = try win.printSegment(
                    .{ .text = t.marker, .style = style },
                    .{ .col = 0, .row = row, .wrap = .none },
                );
            }
            try t.drawRow(body, cells, row, t.rows[which], style);
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
    ) std.mem.Allocator.Error!void {
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
            const taken = @min(visor.width(text, .unicode), rect.cols);
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
            if (i >= state.offset + room) state.offset = i - room + 1;
        }
        const most = t.rows.len -| room;
        if (state.offset > most) state.offset = most;
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

const rows = [_]Row{
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
