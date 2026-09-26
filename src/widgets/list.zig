//! Items in a column, with a selection that scrolls itself into view.
//!
//! The selection and the scroll are the caller's: `State` is a struct the
//! program owns between frames, and the only thing `draw` writes back into
//! it is the offset it had to move to keep the selected item on screen.
//! That is the whole of what a list has to remember.
//!
//! An item is a row a person picks from: a marker beside the chosen one,
//! runs of text in styles of their own, something said at the right edge,
//! and rows under the first when one row is not enough. Every run is
//! measured the way the screen measures, and what does not fit is cut where
//! it stops fitting, with the ellipsis the list is given.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;
const Window = visor.Window;

/// One item of a list.
pub const Item = struct {
    /// The text, on one row, cut where it does not fit. Ignored when
    /// `segments` has any.
    text: []const u8 = "",
    /// The style `text` draws in.
    style: Style = .{},
    /// The OSC 8 target `text` belongs to.
    link: visor.Link = .none,
    /// The first row as runs in styles of their own, in place of `text`.
    segments: []const List.Segment = &.{},
    /// Runs against the right edge of the first row: a cost, a count, a
    /// state. The text is cut to the room left of them, down to
    /// `List.text_min` columns; past that the aside is cut first.
    aside: []const List.Segment = &.{},
    /// The rows under the first, each its own runs, starting where the text
    /// starts. An item is `1 + below.len` rows tall.
    below: []const []const List.Segment = &.{},

    /// How many rows the item takes.
    pub fn rows(it: Item) usize {
        return 1 + it.below.len;
    }
};

/// Items in a column, with a selection.
pub const List = struct {
    /// The items, in order.
    items: []const Item,
    /// The style every row of an item is blanked to first.
    style: Style = .{},
    /// The style the selected item draws in, over its runs' own, or null to
    /// draw it in its runs' own styles, for a program that styles the chosen
    /// item's runs itself.
    selected_style: ?Style = .{ .reverse = true },
    /// Drawn before the selected item.
    marker: []const u8 = "",
    /// Drawn before every other item. Null means as many spaces as `marker`
    /// is wide, which is what keeps the text in one column.
    blank_marker: ?[]const u8 = null,
    /// The style both markers draw in, or null for the row's own.
    marker_style: ?Style = null,
    /// Columns between the marker and the text, left as the row is blanked.
    gap: u16 = 0,
    /// Whether the selected style reaches the right edge of the window or
    /// stops at the end of the text.
    highlight_row: bool = true,
    /// Drawn in the last columns of a run that was cut, in the run's style.
    /// Empty cuts without a mark.
    ellipsis: []const u8 = "",
    /// Columns kept between the text and the aside.
    aside_gap: u16 = 1,
    /// How many columns of the text the aside may take room from. The text
    /// is cut to make room for the whole aside only down to this many
    /// columns (or its own width, when that is less); past it the aside is
    /// cut first, and the text after. The default never cuts the text for an
    /// aside; zero keeps the aside whole whatever it costs the text.
    text_min: u16 = std.math.maxInt(u16),

    /// A run of text in an item, in a style of its own.
    pub const Segment = struct {
        /// The text, on one row.
        text: []const u8,
        /// The style it draws in.
        style: Style = .{},
        /// The OSC 8 target it belongs to.
        link: visor.Link = .none,
        /// The column it starts at, counted from where the item's text
        /// starts, which lines runs up in columns across items; null to
        /// follow the run before it. The run before is cut where this one
        /// starts, and a column that run already passed is where it ends.
        at: ?u16 = null,
        /// The most columns it takes, or null for as many as it has and
        /// there is room for. Longer text is cut there, with the ellipsis.
        cols: ?u16 = null,
    };

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

    /// Which items a window so many rows tall shows.
    pub const Visible = struct {
        /// The first item shown.
        first: usize,
        /// How many are shown, whole.
        count: usize,
        /// How many are not: what a head saying "N more" counts.
        hidden: usize,
    };

    /// The items a window `rows` tall shows, the offset moved as `draw`
    /// moves it to keep the selection on screen. A program asks before it
    /// draws, to say how many more there are.
    ///
    /// Only whole items are counted, except the first when it alone is
    /// taller than the window, which is drawn as far as it goes.
    pub fn visible(l: List, rows: u16, state: *State) Visible {
        l.scrollIntoView(rows, state);
        var used: usize = 0;
        var count: usize = 0;
        var i = state.offset;
        while (i < l.items.len) : (i += 1) {
            const tall = l.items[i].rows();
            if (used + tall > rows) {
                if (count == 0 and rows > 0) count = 1;
                break;
            }
            used += tall;
            count += 1;
        }
        return .{ .first = state.offset, .count = count, .hidden = l.items.len - count };
    }

    /// Draws as many items as the window has rows for, moving the offset
    /// when the selection would otherwise be off screen.
    pub fn draw(l: List, win: Window, state: *State) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        const shown = l.visible(win.rows(), state);
        const marker_width = win.width(l.marker);
        const indent = marker_width +| l.gap;

        var row: u16 = 0;
        for (l.items[shown.first..][0..shown.count], shown.first..) |item, i| {
            const chosen = state.selected == i;
            const over: ?Style = if (chosen) l.selected_style else null;
            const fill: Style = if (chosen and l.highlight_row) over orelse l.style else l.style;

            var line: usize = 0;
            while (line < item.rows() and row < win.rows()) : ({
                line += 1;
                row += 1;
            }) {
                win.fill(.{ .col = 0, .row = row, .cols = win.cols(), .rows = 1 }, .blank(fill));
                const content = win.child(.{ .col = indent, .row = row, .rows = 1 });
                if (line > 0) {
                    try l.drawRuns(content, item.below[line - 1], over, content.cols());
                    continue;
                }
                if (marker_width != 0) {
                    const mark_style = l.marker_style orelse over orelse l.style;
                    const mark = if (chosen) l.marker else l.blank_marker orelse blank: {
                        win.fill(.{ .col = 0, .row = row, .cols = marker_width, .rows = 1 }, .blank(mark_style));
                        break :blank "";
                    };
                    _ = try win.printSegment(
                        .{ .text = mark, .style = mark_style },
                        .{ .col = 0, .row = row, .wrap = .none },
                    );
                }
                const one = [_]Segment{.{ .text = item.text, .style = item.style, .link = item.link }};
                const runs: []const Segment = if (item.segments.len != 0) item.segments else &one;
                try l.drawFirst(content, runs, item.aside, over);
            }
        }
    }

    /// An item's first row: its runs, and its aside against the right edge.
    fn drawFirst(l: List, win: Window, runs: []const Segment, aside: []const Segment, over: ?Style) std.mem.Allocator.Error!void {
        const room = win.cols();
        if (aside.len == 0) return l.drawRuns(win, runs, over, room);

        const extent = l.extentOf(win, runs);
        var aside_width: u16 = 0;
        for (aside) |a| aside_width +|= win.width(a.text);

        // Room for the text with the whole aside beside it, and what the
        // text is owed before the aside gives way.
        const beside = room -| (l.aside_gap +| aside_width);
        const owed = @min(extent, l.text_min, room);
        if (extent <= beside or beside >= owed) {
            try l.drawRuns(win, runs, over, beside);
            try l.drawRuns(win.child(.{ .col = room -| aside_width }), aside, over, aside_width);
            return;
        }
        try l.drawRuns(win, runs, over, owed);
        const left = room -| owed -| l.aside_gap;
        if (left == 0) return;
        const drawn = @min(left, aside_width);
        try l.drawRuns(win.child(.{ .col = room -| drawn }), aside, over, drawn);
    }

    /// How far a row's runs reach, uncut.
    fn extentOf(l: List, win: Window, runs: []const Segment) u16 {
        _ = l;
        var at: u16 = 0;
        for (runs) |r| {
            const start = if (r.at) |c| @max(c, at) else at;
            const w = win.width(r.text);
            at = start +| if (r.cols) |most| @min(w, most) else w;
        }
        return at;
    }

    /// Runs laid along one row from its first column and cut at `limit`: a
    /// run is cut where the next one's column begins, and the one that
    /// crosses `limit` is cut there with the ellipsis.
    fn drawRuns(l: List, win: Window, runs: []const Segment, over: ?Style, limit: u16) std.mem.Allocator.Error!void {
        const end = @min(limit, win.cols());
        var at: u16 = 0;
        for (runs, 0..) |r, i| {
            const start = if (r.at) |c| @max(c, at) else at;
            var stop = end;
            if (r.cols) |most| stop = @min(stop, start +| most);
            if (i + 1 < runs.len) {
                if (runs[i + 1].at) |c| stop = @min(stop, @max(c, start));
            }
            if (start >= stop) {
                at = start;
                continue;
            }
            const style = over orelse r.style;
            const room = stop - start;
            const w = win.width(r.text);
            if (w <= room) {
                _ = try win.printSegment(.{ .text = r.text, .style = style, .link = r.link }, .{ .col = start, .wrap = .none });
                at = start + w;
                continue;
            }
            const kept = visor.fit(r.text, room, l.ellipsis, win.screen.method);
            _ = try win.print(&.{
                .{ .text = kept, .style = style, .link = r.link },
                .{ .text = l.ellipsis, .style = style, .link = r.link },
            }, .{ .col = start, .wrap = .none });
            at = stop;
        }
    }

    /// Moves the offset as little as it takes to put the selection on
    /// screen, and never past the point where the last items fill it.
    fn scrollIntoView(l: List, rows: u16, state: *State) void {
        if (rows == 0) return;
        if (state.selected) |sel| if (sel < l.items.len) {
            if (sel < state.offset) state.offset = sel;
            while (state.offset < sel and l.span(state.offset, sel) > rows) state.offset += 1;
        };
        // The furthest offset whose items still fill the window.
        var most = l.items.len;
        var used: usize = 0;
        while (most > 0 and used + l.items[most - 1].rows() <= rows) {
            used += l.items[most - 1].rows();
            most -= 1;
        }
        // An item taller than the window is shown from its top.
        if (most == l.items.len and most > 0) most -= 1;
        if (state.offset > most) state.offset = most;
    }

    /// How many rows items `from` through `to` take.
    fn span(l: List, from: usize, to: usize) usize {
        var n: usize = 0;
        for (l.items[from .. to + 1]) |it| n += it.rows();
        return n;
    }
};

const Run = List.Segment;

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

test "the marker is measured the way the screen measures" {
    // A sign with a presentation selector is one column measured by
    // codepoint and two measured whole: the text starts after the one the
    // screen draws.
    var h: Harness = try .initMeasured(testing.allocator, 6, 1, .wcwidth);
    defer h.deinit();
    var state: List.State = .{ .selected = 0 };
    try (List{ .items = &.{.{ .text = "ab" }}, .marker = sign, .highlight_row = false }).draw(h.window(), &state);
    _ = try h.frame();
    try testing.expectEqualStrings("a", h.term.screen().textAt(1, 0));
}

const sign = "\u{26a0}\u{fe0f}";

test "an item's runs draw in their own styles, and the selected one in its own when no style is laid over it" {
    var h: Harness = try .init(testing.allocator, 12, 2);
    defer h.deinit();
    var state: List.State = .{ .selected = 1 };
    const items = [_]Item{
        .{ .segments = &.{ .{ .text = "1", .style = .{ .dim = true } }, .{ .text = "one", .at = 2 } } },
        .{ .segments = &.{ .{ .text = "2", .style = .{ .bold = true } }, .{ .text = "two", .style = .{ .italic = true }, .at = 2 } } },
    };
    try (List{
        .items = &items,
        .marker = "\u{25b8}",
        .gap = 1,
        .marker_style = .{ .underline = .single },
        .selected_style = null,
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\  1 one
        \\▸ 2 two
        \\
    );
    // The marker's style reaches the blank marker too; the gap is the row's.
    try testing.expectEqual(visor.Underline.single, h.styleAt(0, 0).underline);
    try testing.expectEqual(visor.Underline.single, h.styleAt(0, 1).underline);
    try testing.expectEqual(visor.Underline.none, h.styleAt(1, 1).underline);
    try testing.expect(h.styleAt(2, 0).dim);
    try testing.expect(h.styleAt(2, 1).bold);
    try testing.expect(h.styleAt(4, 1).italic);
    try testing.expect(!h.styleAt(4, 0).italic);
}

test "runs placed at a column line up across items, and one that would reach the next is cut" {
    var h: Harness = try .init(testing.allocator, 12, 2);
    defer h.deinit();
    var state: List.State = .{};
    const items = [_]Item{
        .{ .segments = &.{ .{ .text = "ab" }, .{ .text = "$1", .at = 6 } } },
        .{ .segments = &.{ .{ .text = "abcdefgh" }, .{ .text = "$22", .at = 6 } } },
    };
    try (List{ .items = &items, .ellipsis = "\u{2026}" }).draw(h.window(), &state);
    try h.expectFrame(
        \\ab    $1
        \\abcde…$22
        \\
    );
}

test "an aside sits at the right edge, and the text is cut to the room it leaves or the aside gives way" {
    const items = [_]Item{.{ .text = "a long name", .aside = &.{.{ .text = "3/4", .style = .{ .bold = true } }} }};
    // Room for both: the aside against the edge.
    {
        var h: Harness = try .init(testing.allocator, 16, 1);
        defer h.deinit();
        var state: List.State = .{};
        try (List{ .items = &items, .ellipsis = "\u{2026}" }).draw(h.window(), &state);
        try h.expectFrame(
            \\a long name  3/4
            \\
        );
        try testing.expect(h.styleAt(13, 0).bold);
    }
    // Too narrow: by default the aside is cut first, to what is left.
    {
        var h: Harness = try .init(testing.allocator, 14, 1);
        defer h.deinit();
        var state: List.State = .{};
        try (List{ .items = &items, .ellipsis = "\u{2026}" }).draw(h.window(), &state);
        try h.expectFrame(
            \\a long name 3…
            \\
        );
    }
    // With the text owed nothing, the aside stays whole and the text is cut.
    {
        var h: Harness = try .init(testing.allocator, 13, 1);
        defer h.deinit();
        var state: List.State = .{};
        try (List{ .items = &items, .ellipsis = "\u{2026}", .text_min = 0 }).draw(h.window(), &state);
        try h.expectFrame(
            \\a long n… 3/4
            \\
        );
    }
    // Owed four columns: the text keeps them, the aside takes what is left.
    {
        var h: Harness = try .init(testing.allocator, 7, 1);
        defer h.deinit();
        var state: List.State = .{};
        try (List{ .items = &items, .ellipsis = "\u{2026}", .text_min = 4 }).draw(h.window(), &state);
        try h.expectFrame(
            \\a l… 3…
            \\
        );
    }
}

test "an item of two rows draws its second under its text, and the window counts it twice" {
    var h: Harness = try .init(testing.allocator, 10, 4);
    defer h.deinit();
    const items = [_]Item{
        .{ .text = "one", .below = &.{&.{.{ .text = "first", .style = .{ .dim = true } }}} },
        .{ .text = "two", .below = &.{&.{.{ .text = "second" }}} },
        .{ .text = "three", .below = &.{&.{.{ .text = "third" }}} },
    };
    var state: List.State = .{ .selected = 2 };
    const list: List = .{ .items = &items, .marker = "> ", .selected_style = null };
    const shown = list.visible(4, &state);
    try testing.expectEqual(List.Visible{ .first = 1, .count = 2, .hidden = 1 }, shown);
    try list.draw(h.window(), &state);
    try h.expectFrame(
        \\  two
        \\  second
        \\> three
        \\  third
        \\
    );
}

test "what is shown and how many are not, for a head that says so" {
    var items: [12]Item = undefined;
    for (&items) |*it| it.* = .{ .text = "x" };
    const list: List = .{ .items = &items };
    var state: List.State = .{ .selected = 9 };
    try testing.expectEqual(List.Visible{ .first = 5, .count = 5, .hidden = 7 }, list.visible(5, &state));
    // A fresh state each frame puts the selection at the bottom of the
    // window once it passes it, and at the top of the list before that.
    var fresh: List.State = .{ .selected = 2 };
    try testing.expectEqual(List.Visible{ .first = 0, .count = 5, .hidden = 7 }, list.visible(5, &fresh));
    var none: List.State = .{};
    try testing.expectEqual(List.Visible{ .first = 0, .count = 0, .hidden = 0 }, (List{ .items = &.{} }).visible(5, &none));
}

test "whatever the heights and the selection, the selected item is whole on screen" {
    var items: [9]Item = undefined;
    const second = [_][]const Run{&.{.{ .text = "." }}};
    const third = [_][]const Run{ &.{.{ .text = "." }}, &.{.{ .text = "." }} };
    for (&items, 0..) |*it, i| it.* = .{ .text = "x", .below = switch (i % 3) {
        0 => &.{},
        1 => &second,
        else => &third,
    } };
    const list: List = .{ .items = &items };
    var rows: u16 = 3;
    while (rows <= 12) : (rows += 1) {
        var state: List.State = .{};
        for (0..items.len * 2) |step| {
            const chosen = if (step < items.len) step else items.len * 2 - 1 - step;
            state.select(chosen);
            const shown = list.visible(rows, &state);
            try testing.expect(chosen >= shown.first and chosen < shown.first + shown.count);
            var used: usize = 0;
            for (items[shown.first..][0..shown.count]) |it| used += it.rows();
            try testing.expect(used <= rows);
            try testing.expectEqual(items.len - shown.count, shown.hidden);
        }
    }
}

test "measured by codepoint, runs and the aside are measured the way the screen measures" {
    var h: Harness = try .initMeasured(testing.allocator, 8, 1, .wcwidth);
    defer h.deinit();
    var state: List.State = .{};
    const items = [_]Item{.{ .segments = &.{ .{ .text = sign }, .{ .text = "b" } }, .aside = &.{.{ .text = sign }} }};
    try (List{ .items = &items }).draw(h.window(), &state);
    _ = try h.frame();
    try testing.expectEqualStrings("b", h.term.screen().textAt(1, 0));
    try testing.expectEqualStrings(sign, h.term.screen().textAt(7, 0));
}

/// Two screens that must hold the same cells: one drawn run by run at the
/// columns a program works out itself, the other by the list.
fn expectSameCells(a: *Harness, b: *Harness) !void {
    _ = try a.frame();
    _ = try b.frame();
    try visor.expectScreensEqual(&a.screen, &b.screen);
}

test "a picker drawn by hand at worked-out columns and the same picker drawn by the list are the same cells" {
    // The shape a program hand-rolls: a marker in its own style, a blank
    // one in the same style, a gap, names cut with an ellipsis, and what
    // each costs in a column after the widest name.
    const hot: Style = .{ .fg = .ansi(.yellow), .bold = true };
    const hi: Style = .{ .bold = true };
    const mid: Style = .{ .fg = .ansi(.white) };
    const dim: Style = .{ .dim = true };
    const names = [_][]const u8{ "alpha", "a much longer name", "gamma" };
    const costs = [_][]const u8{ "12k", "3.4M", "" };
    const cols: u16 = 20;
    const sel: usize = 1;
    const name_room: u16 = cols - 2 - 2 - 6;
    var name_w: u16 = 0;
    for (names) |n| name_w = @max(name_w, @min(visor.width(n, .unicode), name_room));

    var by_hand: Harness = try .init(testing.allocator, cols, names.len);
    defer by_hand.deinit();
    const w = by_hand.window();
    for (names, costs, 0..) |name, cost, i| {
        const row: u16 = @intCast(i);
        const on = i == sel;
        w.fill(.{ .row = row, .cols = cols, .rows = 1 }, .blank(.{}));
        _ = try w.printSegment(.{ .text = if (on) "\u{25b8}" else " ", .style = hot }, .{ .row = row, .wrap = .none });
        const fits = visor.width(name, .unicode) <= name_room;
        const kept = if (fits) name else visor.fit(name, name_room, "\u{2026}", .unicode);
        _ = try w.print(&.{
            .{ .text = kept, .style = if (on) hi else mid },
            .{ .text = if (fits) "" else "\u{2026}", .style = if (on) hi else mid },
        }, .{ .col = 2, .row = row, .wrap = .none });
        _ = try w.printSegment(.{ .text = cost, .style = if (on) hot else dim }, .{ .col = 2 + name_w + 2, .row = row, .wrap = .none });
    }

    var by_list: Harness = try .init(testing.allocator, cols, names.len);
    defer by_list.deinit();
    var items: [names.len]Item = undefined;
    var runs: [names.len][2]Run = undefined;
    for (names, costs, 0..) |name, cost, i| {
        const on = i == sel;
        runs[i] = .{
            .{ .text = name, .style = if (on) hi else mid, .cols = name_room },
            .{ .text = cost, .style = if (on) hot else dim, .at = name_w + 2 },
        };
        items[i] = .{ .segments = &runs[i] };
    }
    var state: List.State = .{ .selected = sel };
    try (List{
        .items = &items,
        .marker = "\u{25b8}",
        .blank_marker = " ",
        .marker_style = hot,
        .gap = 1,
        .selected_style = null,
        .ellipsis = "\u{2026}",
    }).draw(by_list.window(), &state);
    try expectSameCells(&by_hand, &by_list);
}

test "a row with its state at the right edge, drawn by hand and by the list, is the same cells" {
    // The text cut to leave the state its room, as a program does it.
    const cols: u16 = 16;
    const left = "3 n2 some ship";
    const right = "3/4 \u{00b7} 12k";
    const bad: Style = .{ .fg = .ansi(.red) };
    var by_hand: Harness = try .init(testing.allocator, cols, 1);
    defer by_hand.deinit();
    const w = by_hand.window();
    _ = try w.printSegment(.{ .text = "\u{25b8}", .style = .{ .bold = true } }, .{ .wrap = .none });
    const room = cols - 3 - visor.width(right, .unicode);
    const kept = visor.fit(left, room, "\u{2026}", .unicode);
    _ = try w.print(&.{ .{ .text = kept }, .{ .text = "\u{2026}" } }, .{ .col = 2, .wrap = .none });
    _ = try w.printSegment(.{ .text = right, .style = bad }, .{ .col = cols - visor.width(right, .unicode), .wrap = .none });

    var by_list: Harness = try .init(testing.allocator, cols, 1);
    defer by_list.deinit();
    var state: List.State = .{ .selected = 0 };
    try (List{
        .items = &.{.{ .text = left, .aside = &.{.{ .text = right, .style = bad }} }},
        .marker = "\u{25b8}",
        .marker_style = .{ .bold = true },
        .gap = 1,
        .selected_style = null,
        .ellipsis = "\u{2026}",
        .text_min = 0,
    }).draw(by_list.window(), &state);
    try expectSameCells(&by_hand, &by_list);
}
