//! Which rows of something longer a view shows, and how that holds still
//! while the thing grows.
//!
//! A log, a conversation and a chat all grow at one end and are read at the
//! other. Scrolled back, the reader expects the lines on screen to stay put
//! while new ones arrive below, and scrolled all the way back down, to
//! follow them again. That is two numbers the program already keeps — how
//! far back, and how long the thing was when it looked — and one rule, which
//! is this file.
//!
//! What is drawn in the rows is the caller's: they are rarely one kind of
//! thing, so this hands back the range and the caller draws it. What a click
//! on one of them opens is `Window.linkAt`, because a cell carries its link.

const std = @import("std");
const visor = @import("visor");

/// Which rows of something longer a view shows.
pub const Scroll = struct {
    /// Which end the view holds to when it has not been scrolled.
    anchor: Anchor = .bottom,

    /// Which end a view follows.
    pub const Anchor = enum {
        /// The last rows: a log, a conversation. New rows arrive in view,
        /// and a view scrolled back holds its place while they do.
        bottom,
        /// The first rows: a document. New rows arrive below and move
        /// nothing.
        top,
    };

    /// What a view remembers between frames.
    pub const State = struct {
        /// How far the view is from its anchor, in rows. Zero is at the
        /// anchor, following it. The program adds to it and takes from it;
        /// `view` clamps it.
        offset: usize = 0,
        /// How many rows there were the last time `view` settled the offset,
        /// so the rows that arrived since can be told apart.
        seen: usize = 0,
    };

    /// The rows a frame shows.
    pub const View = struct {
        /// The first row to draw.
        start: usize,
        /// One past the last.
        end: usize,
        /// How many rows are before `start`.
        above: usize,
        /// How many rows are after `end`.
        below: usize,
        /// How far the view could be scrolled at most.
        most: usize,
    };

    /// The rows to draw out of `total` in a view `rows` tall, with the
    /// offset settled into `state`: clamped to what there is and, anchored
    /// at the bottom and scrolled back, grown by the rows that arrived since
    /// the last frame so the ones on screen stay there. Scrolled back down
    /// to zero, the view follows again.
    pub fn view(s: Scroll, state: *State, total: usize, rows: usize) View {
        const most = total -| rows;
        var offset = state.offset;
        if (s.anchor == .bottom and offset != 0 and state.seen != 0 and total > state.seen) {
            offset += total - state.seen;
        }
        offset = @min(offset, most);
        state.offset = offset;
        state.seen = total;
        return switch (s.anchor) {
            .bottom => blk: {
                const end = total - offset;
                const start = end -| rows;
                break :blk .{ .start = start, .end = end, .above = start, .below = offset, .most = most };
            },
            .top => blk: {
                const end = @min(offset + rows, total);
                break :blk .{ .start = offset, .end = end, .above = offset, .below = total - end, .most = most };
            },
        };
    }

    /// The same numbers as a scrollbar takes them.
    pub fn bar(v: View, total: usize) @import("scrollbar.zig").Scrollbar.State {
        return .{ .content = total, .viewport = v.end - v.start, .position = v.start };
    }
};

const testing = std.testing;

test "at the live end the view follows the last rows" {
    const s: Scroll = .{};
    var state: Scroll.State = .{};
    const v = s.view(&state, 100, 40);
    try testing.expectEqual(@as(usize, 60), v.start);
    try testing.expectEqual(@as(usize, 100), v.end);
    try testing.expectEqual(@as(usize, 60), v.above);
    try testing.expectEqual(@as(usize, 0), v.below);
    try testing.expectEqual(@as(usize, 60), v.most);
    const more = s.view(&state, 110, 40);
    try testing.expectEqual(@as(usize, 110), more.end);
}

test "scrolled back, the rows on screen hold still while rows land, and zero lets go" {
    const s: Scroll = .{};
    var state: Scroll.State = .{ .offset = 5, .seen = 100 };
    // Ten rows land while five back: the same rows are on screen.
    const held = s.view(&state, 110, 10);
    try testing.expectEqual(@as(usize, 15), state.offset);
    try testing.expectEqual(@as(usize, 95), held.end);
    try testing.expectEqual(@as(usize, 15), held.below);
    // Clamped to what there is.
    state = .{ .offset = 80, .seen = 100 };
    _ = s.view(&state, 200, 110);
    try testing.expectEqual(@as(usize, 90), state.offset);
    // Nothing seen yet: the offset stands as given.
    state = .{ .offset = 7, .seen = 0 };
    _ = s.view(&state, 100, 20);
    try testing.expectEqual(@as(usize, 7), state.offset);
    // At zero it follows whatever lands.
    state = .{ .offset = 0, .seen = 100 };
    const live = s.view(&state, 150, 10);
    try testing.expectEqual(@as(usize, 0), state.offset);
    try testing.expectEqual(@as(usize, 150), live.end);
}

test "a document is held at its top and grows below" {
    const s: Scroll = .{ .anchor = .top };
    var state: Scroll.State = .{};
    const first = s.view(&state, 100, 20);
    try testing.expectEqual(@as(usize, 0), first.start);
    try testing.expectEqual(@as(usize, 80), first.below);
    state.offset += 30;
    const later = s.view(&state, 150, 20);
    try testing.expectEqual(@as(usize, 30), later.start);
    try testing.expectEqual(@as(usize, 50), later.end);
    try testing.expectEqual(@as(usize, 100), later.below);
    state.offset = 1000;
    try testing.expectEqual(@as(usize, 130), s.view(&state, 150, 20).start);
}

test "fewer rows than room shows them all and cannot scroll" {
    const s: Scroll = .{};
    var state: Scroll.State = .{ .offset = 3 };
    const v = s.view(&state, 5, 20);
    try testing.expectEqual(@as(usize, 0), v.start);
    try testing.expectEqual(@as(usize, 5), v.end);
    try testing.expectEqual(@as(usize, 0), state.offset);
    const b = Scroll.bar(v, 5);
    try testing.expectEqual(@as(usize, 5), b.viewport);
}
