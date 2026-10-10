//! Nodes under nodes, opened and closed, with a selection that scrolls
//! itself into view.
//!
//! The tree is a slice of nodes in the order they are read, each with its
//! depth: a node's children are the nodes after it that are deeper, up to
//! the next one that is not. That is the order a walk of the program's own
//! data produces, and it needs no allocation to build or to draw.
//!
//! Which nodes are open is the program's, on each node: the program keeps
//! it beside its own data and says so every frame, and a program that leaves
//! the children of a closed node out of the slice altogether only has to say
//! the node has some. The selection and the scroll are the caller's too, in
//! `State`, the way a list keeps them; `draw` writes back only the offset
//! it moved and, when the selected node is inside one that is closed, the
//! node the selection went up to.
//!
//! Each row is drawn as a list draws an item: runs in styles of their own,
//! something at the right edge, cut where it stops fitting. Before the text
//! go the guides that join a node to its parent and its siblings, and the
//! symbol that says whether it is open.

const std = @import("std");
const visor = @import("base.zig");
const list_mod = @import("list.zig");

const List = list_mod.List;
const Item = list_mod.Item;
const Style = visor.Style;

/// Nodes under nodes, with a selection.
pub const Tree = struct {
    /// The nodes, in the order they are read: each followed by its
    /// children. A node is at most one deeper than the node before it.
    nodes: []const Node,
    /// The style every row is blanked to first, or null to leave the rows as
    /// they are and write only the guides, the symbols and the runs.
    style: ?Style = .{},
    /// The style the selected node draws in, over its runs' own, or null to
    /// draw it in its runs' own styles.
    selected_style: ?Style = .{ .reverse = true },
    /// Whether the selected style reaches the right edge of the window or
    /// stops at the end of the text.
    highlight_row: bool = true,
    /// Drawn at the start of the selected node's row.
    marker: []const u8 = "",
    /// Drawn at the start of every other row. Null means as many spaces as
    /// `marker` is wide.
    blank_marker: ?[]const u8 = null,
    /// Columns between the marker and the guides.
    gap: u16 = 0,
    /// The lines joining a node to its parent and siblings, or null for
    /// plain indentation, `indent` columns a level.
    guides: ?Guides = .lines,
    /// Columns a level is indented when there are no guides.
    indent: u16 = 2,
    /// The style the guides and symbols draw in, or null for the row's own.
    guide_style: ?Style = null,
    /// What is drawn before a node's text to say whether it is open.
    symbols: Symbols = .{},
    /// Drawn in the last columns of a run that was cut.
    ellipsis: []const u8 = "",

    /// One node of a tree.
    pub const Node = struct {
        /// How many levels down: zero for a node with no parent.
        depth: u16 = 0,
        /// Whether its children are shown, or null for a node that has none
        /// to show. A closed node may leave its children out of the slice.
        open: ?bool = null,
        /// The text, on one row, cut where it does not fit. Ignored when
        /// `segments` has any.
        text: []const u8 = "",
        /// The style `text` draws in.
        style: Style = .{},
        /// The OSC 8 target `text` belongs to.
        link: visor.Link = .none,
        /// The row as runs in styles of their own, in place of `text`.
        segments: []const List.Segment = &.{},
        /// Runs against the right edge of the row, as a list item has.
        aside: []const List.Segment = &.{},
    };

    /// The lines drawn in the columns before a node, one piece a level.
    /// Every piece should be the same width; that width is the indent.
    pub const Guides = struct {
        /// Before a node with a sibling after it.
        branch: []const u8,
        /// Before a node that is its parent's last.
        last: []const u8,
        /// Under a node with a sibling after it, beside its descendants.
        through: []const u8,
        /// Under a node that was its parent's last.
        blank: []const u8,

        /// Box-drawing lines, three columns a level.
        pub const lines: Guides = .{ .branch = "├─ ", .last = "└─ ", .through = "│  ", .blank = "   " };
        /// Rounded corners, three columns a level.
        pub const rounded: Guides = .{ .branch = "├─ ", .last = "╰─ ", .through = "│  ", .blank = "   " };
        /// ASCII, three columns a level.
        pub const ascii: Guides = .{ .branch = "|- ", .last = "`- ", .through = "|  ", .blank = "   " };
    };

    /// What says whether a node is open. Each should be the same width.
    pub const Symbols = struct {
        /// Before an open node.
        open: []const u8 = "▾ ",
        /// Before a closed node.
        closed: []const u8 = "▸ ",
        /// Before a node with no children.
        leaf: []const u8 = "  ",
    };

    /// What a tree remembers between frames.
    pub const State = struct {
        /// Which node is selected, as an index into `nodes`, or none.
        selected: ?usize = null,
        /// The first row drawn, counted in rows shown.
        offset: usize = 0,

        /// Selects a node, or nothing.
        pub fn select(s: *State, which: ?usize) void {
            s.selected = which;
            if (which == null) s.offset = 0;
        }

        /// The node shown after the selected one, stopping at the last.
        pub fn next(s: *State, tree: Tree) void {
            const at = s.shownSelection(tree) orelse return s.select(tree.firstShown());
            s.select(tree.nextShown(at) orelse at);
        }

        /// The node shown before the selected one, stopping at the first.
        pub fn previous(s: *State, tree: Tree) void {
            const at = s.shownSelection(tree) orelse return s.select(tree.lastShown());
            s.select(tree.previousShown(at) orelse at);
        }

        /// The first node.
        pub fn first(s: *State, tree: Tree) void {
            s.select(tree.firstShown());
        }

        /// The last node shown.
        pub fn last(s: *State, tree: Tree) void {
            s.select(tree.lastShown());
        }

        /// The selected node's parent, staying put on a node with none.
        pub fn parent(s: *State, tree: Tree) void {
            const at = s.shownSelection(tree) orelse return;
            s.select(tree.parentOf(at) orelse at);
        }

        /// The selected node's first child, when it is open and has one.
        pub fn child(s: *State, tree: Tree) void {
            const at = s.shownSelection(tree) orelse return;
            if (tree.nodes[at].open == true and tree.hasChildren(at)) s.select(at + 1);
        }

        fn shownSelection(s: *State, tree: Tree) ?usize {
            const at = s.selected orelse return null;
            if (at >= tree.nodes.len) return null;
            return tree.shownAncestor(at);
        }
    };

    /// Which rows a window so many rows tall shows.
    pub const Visible = struct {
        /// The node on the first row, or null when nothing is shown.
        first: ?usize,
        /// How many rows are drawn.
        count: usize,
        /// How many rows the open tree takes in all.
        total: usize,
    };

    //=====================================================================
    // Walking the tree.
    //=====================================================================

    /// The node's parent: the nearest node before it that is less deep.
    pub fn parentOf(t: Tree, at: usize) ?usize {
        const depth = t.nodes[at].depth;
        var i = at;
        while (i > 0) {
            i -= 1;
            if (t.nodes[i].depth < depth) return i;
        }
        return null;
    }

    /// Whether the node has children in the slice.
    pub fn hasChildren(t: Tree, at: usize) bool {
        return at + 1 < t.nodes.len and t.nodes[at + 1].depth > t.nodes[at].depth;
    }

    /// Whether every node above this one is open.
    pub fn isShown(t: Tree, at: usize) bool {
        return t.shownAncestor(at) == at;
    }

    /// The node itself when it is shown, or the outermost closed node it is
    /// inside, which is the one shown in its place.
    pub fn shownAncestor(t: Tree, at: usize) usize {
        var shown = at;
        var i = at;
        while (t.parentOf(i)) |p| : (i = p) {
            if (t.nodes[p].open != true) shown = p;
        }
        return shown;
    }

    /// The first node, or null for an empty tree.
    pub fn firstShown(t: Tree) ?usize {
        return if (t.nodes.len == 0) null else 0;
    }

    /// The last node shown.
    pub fn lastShown(t: Tree) ?usize {
        if (t.nodes.len == 0) return null;
        return t.shownAncestor(t.nodes.len - 1);
    }

    /// The node shown after this shown one: its first child when it is
    /// open, or the next node not under it.
    pub fn nextShown(t: Tree, at: usize) ?usize {
        const depth = t.nodes[at].depth;
        var i = at + 1;
        if (t.nodes[at].open != true) {
            while (i < t.nodes.len and t.nodes[i].depth > depth) i += 1;
        }
        return if (i < t.nodes.len) i else null;
    }

    /// The node shown before this shown one: its parent, or the last node
    /// shown under the sibling before it.
    pub fn previousShown(t: Tree, at: usize) ?usize {
        const depth = t.nodes[at].depth;
        var i = at;
        const before = while (i > 0) {
            i -= 1;
            if (t.nodes[i].depth <= depth) break i;
        } else return null;
        if (t.nodes[before].depth < depth) return before;
        var shown = before;
        while (t.nodes[shown].open == true and t.hasChildren(shown)) {
            // The last child: the last node one deeper before the subtree ends.
            const level = t.nodes[shown].depth;
            var j = shown + 1;
            var last_child = j;
            while (j < t.nodes.len and t.nodes[j].depth > level) : (j += 1) {
                if (t.nodes[j].depth == level + 1) last_child = j;
            }
            shown = last_child;
        }
        return shown;
    }

    /// How many rows the shown nodes take.
    pub fn rowCount(t: Tree) usize {
        var n: usize = 0;
        var at = t.firstShown();
        while (at) |i| : (at = t.nextShown(i)) n += 1;
        return n;
    }

    /// The row a shown node is on, counted from the first node.
    pub fn rowOf(t: Tree, node: usize) usize {
        var n: usize = 0;
        var at = t.firstShown();
        while (at) |i| : (at = t.nextShown(i)) {
            if (i >= node) break;
            n += 1;
        }
        return n;
    }

    /// The node on a row of a window the tree was drawn into with this
    /// state, for a click: null below the last.
    pub fn nodeAt(t: Tree, state: State, row: usize) ?usize {
        return t.nodeOnRow(state.offset + row);
    }

    fn nodeOnRow(t: Tree, row: usize) ?usize {
        var at = t.firstShown();
        var n: usize = 0;
        while (at) |i| : (at = t.nextShown(i)) {
            if (n == row) return i;
            n += 1;
        }
        return null;
    }

    /// The rows a window `rows` tall shows, the offset moved as `draw` moves
    /// it to keep the selection on screen, and a selection inside a closed
    /// node moved up to the node shown in its place.
    pub fn visible(t: Tree, rows: u16, state: *State) Visible {
        if (state.selected) |sel| {
            state.selected = if (sel < t.nodes.len) t.shownAncestor(sel) else null;
        }
        const total = t.rowCount();
        if (rows > 0) if (state.selected) |sel| {
            const row = t.rowOf(sel);
            if (row < state.offset) state.offset = row;
            if (row >= state.offset + rows) state.offset = row + 1 - rows;
        };
        state.offset = @min(state.offset, total -| rows);
        const count = @min(rows, total - state.offset);
        return .{ .first = if (count == 0) null else t.nodeOnRow(state.offset), .count = count, .total = total };
    }

    //=====================================================================
    // Drawing.
    //=====================================================================

    /// Guides are drawn for this many levels; deeper levels are indented
    /// without them.
    pub const guide_levels = 64;
    /// Rows laid out at a time.
    const chunk = 128;
    const none = std.math.maxInt(u16);

    /// Draws as many rows as the window has, moving the offset when the
    /// selection would otherwise be off screen.
    pub fn draw(t: Tree, win: visor.Window, state: *State) visor.DrawError!void {
        if (win.rect().isEmpty()) return;
        const shown = t.visible(win.rows(), state);
        var at = shown.first orelse return;
        var row: usize = 0;
        var batch: [chunk]usize = undefined;
        while (row < shown.count) {
            const n = @min(chunk, shown.count - row);
            for (batch[0..n], 0..) |*slot, k| {
                slot.* = at;
                if (k + 1 < n) at = t.nextShown(at).?;
            }
            // For each level, the depth of the first node after the batch
            // that is no deeper than it: which says whether a node at that
            // level has a sibling still to come.
            var after: [guide_levels]u16 = @splat(none);
            var least: u16 = none;
            var j = batch[n - 1] + 1;
            while (j < t.nodes.len and least > 0) : (j += 1) {
                const d = t.nodes[j].depth;
                if (d >= least) continue;
                var level = d;
                while (level < @min(least, guide_levels)) : (level += 1) after[level] = d;
                least = d;
            }
            // Rows are independent, so the batch is drawn from its end, the
            // levels updated as each node goes by.
            var k = n;
            while (k > 0) {
                k -= 1;
                const node = batch[k];
                try t.drawRow(win, @intCast(row + k), node, state.selected == node, &after);
                var level = t.nodes[node].depth;
                while (level < guide_levels) : (level += 1) after[level] = t.nodes[node].depth;
            }
            row += n;
            if (row < shown.count) at = t.nextShown(batch[n - 1]).?;
        }
    }

    fn drawRow(t: Tree, win: visor.Window, y: u16, node: usize, chosen: bool, after: *const [guide_levels]u16) visor.DrawError!void {
        const n = t.nodes[node];
        const over: ?Style = if (chosen) t.selected_style else null;
        const fill: ?Style = if (chosen and t.highlight_row) over orelse t.style else t.style;
        if (fill) |ground| try win.fill(.{ .col = 0, .row = y, .cols = win.cols(), .rows = 1 }, .blank(ground));
        const ink = t.guide_style orelse over orelse t.style orelse Style{};
        const mark_ink = over orelse t.style orelse Style{};

        var x: u16 = 0;
        const marker_width = win.width(t.marker);
        if (marker_width != 0) {
            const mark = if (chosen) t.marker else t.blank_marker orelse "";
            _ = try win.printSegment(.{ .text = mark, .style = mark_ink }, .{ .row = y, .wrap = .none });
        }
        x = marker_width +| t.gap;

        if (t.guides) |g| {
            var level: u16 = 1;
            while (level <= n.depth and x < win.cols()) : (level += 1) {
                const known = level < guide_levels;
                const goes_on = known and after[level] == level;
                const piece = if (level == n.depth)
                    (if (goes_on) g.branch else g.last)
                else if (goes_on) g.through else g.blank;
                const shown_piece = if (known) piece else g.blank;
                _ = try win.printSegment(.{ .text = shown_piece, .style = ink }, .{ .col = x, .row = y, .wrap = .none });
                x +|= win.width(shown_piece);
            }
        } else {
            x +|= n.depth *| t.indent;
        }
        const symbol = if (n.open) |open| (if (open) t.symbols.open else t.symbols.closed) else t.symbols.leaf;
        if (symbol.len != 0 and x < win.cols()) {
            _ = try win.printSegment(.{ .text = symbol, .style = ink }, .{ .col = x, .row = y, .wrap = .none });
        }
        x +|= win.width(symbol);
        if (x >= win.cols()) return;

        // The text is a list item of one row, drawn by the list's own rules.
        const item: Item = .{ .text = n.text, .style = n.style, .link = n.link, .segments = n.segments, .aside = n.aside };
        var one: List.State = .{ .selected = if (chosen) 0 else null };
        try (List{
            .items = (&item)[0..1],
            .style = null,
            .selected_style = over,
            .highlight_row = false,
            .ellipsis = t.ellipsis,
            .text_min = 0,
        }).draw(win.child(.{ .col = x, .row = y, .rows = 1 }), &one);
    }
};

const testing = std.testing;
const Harness = @import("../testing/widget_harness.zig").Harness;
const corpus = @import("corpus");

// src
// ├─ widgets
// │  ├─ list.zig
// │  └─ tree.zig
// └─ visor.zig
// README.md
const files = [_]Tree.Node{
    .{ .depth = 0, .open = true, .text = "src" },
    .{ .depth = 1, .open = true, .text = "widgets" },
    .{ .depth = 2, .text = "list.zig" },
    .{ .depth = 2, .text = "tree.zig" },
    .{ .depth = 1, .text = "visor.zig" },
    .{ .depth = 0, .text = "README.md" },
};

test "a tree draws its nodes with guides joining each to its parent and siblings" {
    var h: Harness = try .init(testing.allocator, 22, 7);
    defer h.deinit();
    var state: Tree.State = .{};
    try (Tree{ .nodes = &files }).draw(h.window(), &state);
    try h.expectFrame(
        \\▾ src
        \\├─ ▾ widgets
        \\│  ├─   list.zig
        \\│  └─   tree.zig
        \\└─   visor.zig
        \\  README.md
        \\
        \\
    );
}

test "a closed node hides what is under it, and the program's flag is all that says so" {
    var nodes = files;
    nodes[1].open = false;
    var h: Harness = try .init(testing.allocator, 16, 4);
    defer h.deinit();
    var state: Tree.State = .{};
    const tree: Tree = .{ .nodes = &nodes, .symbols = .{ .leaf = "" } };
    try tree.draw(h.window(), &state);
    try h.expectFrame(
        \\▾ src
        \\├─ ▸ widgets
        \\└─ visor.zig
        \\README.md
        \\
    );
    try testing.expectEqual(@as(usize, 4), tree.rowCount());
    // A closed node may leave its children out entirely.
    const shallow = [_]Tree.Node{ .{ .text = "a", .open = false }, .{ .text = "b" } };
    try testing.expectEqual(@as(usize, 2), (Tree{ .nodes = &shallow }).rowCount());
}

test "without guides a level is indented, and the selection is marked and filled" {
    var h: Harness = try .init(testing.allocator, 20, 6);
    defer h.deinit();
    var state: Tree.State = .{ .selected = 2 };
    try (Tree{
        .nodes = &files,
        .guides = null,
        .marker = "> ",
        .selected_style = .{ .bold = true },
        .symbols = .{ .open = "- ", .closed = "+ ", .leaf = "  " },
    }).draw(h.window(), &state);
    try h.expectFrame(
        \\  - src
        \\    - widgets
        \\>       list.zig
        \\        tree.zig
        \\      visor.zig
        \\    README.md
        \\
    );
    try testing.expect(h.styleAt(10, 2).bold);
    try testing.expect(h.styleAt(13, 2).bold);
    try testing.expect(!h.styleAt(10, 3).bold);
}

test "moving the selection walks the rows shown, into and out of open nodes" {
    var nodes = files;
    const tree: Tree = .{ .nodes = &nodes };
    var state: Tree.State = .{};
    var seen: [6]usize = undefined;
    for (&seen) |*s| {
        state.next(tree);
        s.* = state.selected.?;
    }
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, &seen);
    for (0..6) |k| {
        try testing.expectEqual(5 - k, state.selected.?);
        state.previous(tree);
    }
    try testing.expectEqual(@as(?usize, 0), state.selected);

    // Closed, the nodes under it are stepped over both ways.
    nodes[1].open = false;
    state.select(1);
    state.next(tree);
    try testing.expectEqual(@as(?usize, 4), state.selected);
    state.previous(tree);
    try testing.expectEqual(@as(?usize, 1), state.selected);
    nodes[0].open = false;
    state.select(0);
    state.next(tree);
    try testing.expectEqual(@as(?usize, 5), state.selected);
    state.previous(tree);
    try testing.expectEqual(@as(?usize, 0), state.selected);

    // Up to the parent, down to the first child, and the ends.
    nodes[0].open = true;
    nodes[1].open = true;
    state.select(3);
    state.parent(tree);
    try testing.expectEqual(@as(?usize, 1), state.selected);
    state.parent(tree);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    state.parent(tree);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    state.child(tree);
    try testing.expectEqual(@as(?usize, 1), state.selected);
    state.last(tree);
    try testing.expectEqual(@as(?usize, 5), state.selected);
    state.first(tree);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    // An empty tree selects nothing.
    state.next(.{ .nodes = &.{} });
    try testing.expectEqual(@as(?usize, null), state.selected);
}

test "a selection inside a node that closed goes up to the node shown in its place" {
    var nodes = files;
    nodes[0].open = false;
    var h: Harness = try .init(testing.allocator, 16, 2);
    defer h.deinit();
    var state: Tree.State = .{ .selected = 3 };
    try (Tree{ .nodes = &nodes }).draw(h.window(), &state);
    try testing.expectEqual(@as(?usize, 0), state.selected);
    try h.expectFrame(
        \\▸ src
        \\  README.md
        \\
    );
}

test "the selection scrolls itself into view, and a click finds its node" {
    var h: Harness = try .init(testing.allocator, 20, 2);
    defer h.deinit();
    var state: Tree.State = .{ .selected = 4 };
    const tree: Tree = .{ .nodes = &files, .selected_style = null };
    try tree.draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 3), state.offset);
    try h.expectFrame(
        \\│  └─   tree.zig
        \\└─   visor.zig
        \\
    );
    try testing.expectEqual(@as(?usize, 3), tree.nodeAt(state, 0));
    try testing.expectEqual(@as(?usize, 4), tree.nodeAt(state, 1));
    state.first(tree);
    try tree.draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 0), state.offset);
    state.offset = 99;
    state.selected = null;
    const shown = tree.visible(2, &state);
    try testing.expectEqual(@as(usize, 4), state.offset);
    try testing.expectEqual(@as(?usize, 4), shown.first);
    try testing.expectEqual(@as(usize, 6), shown.total);
}

test "runs, an aside and a cut with an ellipsis draw as a list item draws them" {
    var h: Harness = try .init(testing.allocator, 16, 2);
    defer h.deinit();
    const Run = List.Segment;
    const nodes = [_]Tree.Node{
        .{ .open = true, .segments = &[_]Run{ .{ .text = "src", .style = .{ .bold = true } }, .{ .text = "/" } }, .aside = &[_]Run{.{ .text = "3" }} },
        .{ .depth = 1, .text = "a name too long to fit", .style = .{ .italic = true } },
    };
    var state: Tree.State = .{};
    try (Tree{ .nodes = &nodes, .ellipsis = "…", .guides = .ascii, .symbols = .{ .leaf = "" } }).draw(h.window(), &state);
    try h.expectFrame(
        \\▾ src/         3
        \\`- a name too l…
        \\
    );
    try testing.expect(h.styleAt(2, 0).bold);
    try testing.expect(!h.styleAt(5, 0).bold);
    try testing.expect(h.styleAt(3, 1).italic);
}

/// A tree of random shape, opened at random, held to what a slow and
/// obvious reading of the same nodes says.
fn treeHolds(gpa: std.mem.Allocator, smith: *std.testing.Smith) !void {
    var dice: corpus.Dice = .init(smith);
    var nodes: [40]Tree.Node = undefined;
    const n: usize = dice.valueRangeAtMost(u8, 0, nodes.len);
    var depth: u16 = 0;
    for (nodes[0..n], 0..) |*node, i| {
        if (i > 0) depth = dice.valueRangeAtMost(u16, 0, depth + 1);
        node.* = .{ .depth = depth, .text = "n", .open = if (dice.value(bool)) dice.value(bool) else null };
    }
    const tree: Tree = .{ .nodes = nodes[0..n] };

    // Shown, the slow way: every node whose parents are all open.
    var shown: [40]usize = undefined;
    var count: usize = 0;
    for (0..n) |i| {
        var open = true;
        var p = tree.parentOf(i);
        while (p) |at| : (p = tree.parentOf(at)) {
            if (nodes[at].open != true) open = false;
        }
        try testing.expectEqual(open, tree.isShown(i));
        if (open) {
            shown[count] = i;
            count += 1;
        }
    }
    try testing.expectEqual(count, tree.rowCount());
    for (shown[0..count], 0..) |node, row| {
        try testing.expectEqual(row, tree.rowOf(node));
        try testing.expectEqual(@as(?usize, node), tree.nodeOnRow(row));
        try testing.expectEqual(if (row + 1 < count) shown[row + 1] else null, tree.nextShown(node));
        try testing.expectEqual(if (row > 0) shown[row - 1] else null, tree.previousShown(node));
    }

    // Drawn with any selection and offset, the selection is a shown node on
    // screen, and the frame reads back.
    const rows = dice.valueRangeAtMost(u16, 1, 8);
    var h: Harness = try .init(gpa, 24, rows);
    defer h.deinit();
    var state: Tree.State = .{ .offset = dice.valueRangeAtMost(u8, 0, 50) };
    if (n > 0 and dice.value(bool)) state.selected = dice.index(n);
    const was = state.selected;
    try tree.draw(h.window(), &state);
    if (state.selected) |sel| {
        try testing.expect(tree.isShown(sel));
        try testing.expectEqual(tree.shownAncestor(was.?), sel);
        const row = tree.rowOf(sel);
        try testing.expect(row >= state.offset and row < state.offset + rows);
    }
    _ = try h.frame();
}

test "whatever the shape and what is open, the walk agrees with the slow reading" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try treeHolds(gpa, smith);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the guides of a long tree are the guides of the same rows drawn one at a time" {
    // More rows than one batch, so the levels carried from one batch to the
    // next are checked against each row drawn in a window of its own.
    var nodes: [300]Tree.Node = undefined;
    for (&nodes, 0..) |*node, i| node.* = .{ .depth = @intCast(i % 5), .open = true, .text = "x" };
    nodes[299].open = null;
    const tree: Tree = .{ .nodes = &nodes };
    var whole: Harness = try .init(testing.allocator, 20, 300);
    defer whole.deinit();
    var state: Tree.State = .{};
    try tree.draw(whole.window(), &state);
    var one: Harness = try .init(testing.allocator, 20, 1);
    defer one.deinit();
    for (0..300) |row| {
        one.window().clear();
        var single: Tree.State = .{ .offset = row };
        try tree.draw(one.window(), &single);
        for (0..20) |col| {
            try testing.expectEqualStrings(whole.screen.textAt(@intCast(col), @intCast(row)), one.screen.textAt(@intCast(col), 0));
        }
    }
}
