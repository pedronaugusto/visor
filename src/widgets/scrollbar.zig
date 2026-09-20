//! Where a viewport is in something longer.
//!
//! The strip it draws into is the caller's: a scrollbar is one column beside
//! a list or one row under a paragraph, and which column that is belongs to
//! the layout and not to this. The state is three numbers the program
//! already has.

const std = @import("std");
const visor = @import("visor");

const layout = @import("layout.zig");
const Direction = layout.Direction;
const Style = visor.Style;
const Window = visor.Window;

/// Where a viewport is in something longer.
pub const Scrollbar = struct {
    /// Which way the bar runs.
    direction: Direction = .vertical,
    /// The glyph the track is drawn with.
    track: []const u8 = "\u{2502}",
    /// The glyph the thumb is drawn with.
    thumb: []const u8 = "\u{2588}",
    /// A glyph at the near end, or null for none.
    begin: ?[]const u8 = null,
    /// A glyph at the far end, or null for none.
    end: ?[]const u8 = null,
    /// The style the track and the ends draw in.
    style: Style = .{ .dim = true },
    /// The style the thumb draws in.
    thumb_style: Style = .{},
    /// Whether to draw at all when everything fits.
    hide_when_whole: bool = true,

    /// How far down something is and how much of it shows.
    pub const State = struct {
        /// How long the whole thing is, in rows or columns.
        content: usize = 0,
        /// How much of it is on screen.
        viewport: usize = 0,
        /// How far in the first visible row or column is.
        position: usize = 0,

        /// Where the thumb starts and how long it is, in a bar `len` long.
        ///
        /// Public because a program that lets the mouse drag a scrollbar has
        /// to invert this, and inverting arithmetic it cannot see is how a
        /// drag ends up a cell out.
        pub fn thumbIn(s: State, len: u16) struct { start: u16, len: u16 } {
            if (len == 0 or s.content == 0) return .{ .start = 0, .len = 0 };
            if (s.viewport >= s.content) return .{ .start = 0, .len = len };
            const size: u16 = @intCast(@max(1, @as(u128, s.viewport) * len / s.content));
            const room = len - size;
            const most = s.content - s.viewport;
            const at = @min(s.position, most);
            return .{ .start = @intCast(@as(u128, at) * room / most), .len = size };
        }
    };

    /// Draws the track and the thumb along the window's first column or row.
    pub fn draw(b: Scrollbar, win: Window, state: State) std.mem.Allocator.Error!void {
        if (win.rect.isEmpty()) return;
        if (b.hide_when_whole and state.viewport >= state.content) return;

        const len = switch (b.direction) {
            .vertical => win.rows(),
            .horizontal => win.cols(),
        };
        var from: u16 = 0;
        var room = len;
        if (b.begin) |g| {
            if (room == 0) return;
            try b.put(win, 0, g, b.style);
            from = 1;
            room -= 1;
        }
        if (b.end) |g| {
            if (room == 0) return;
            try b.put(win, len - 1, g, b.style);
            room -= 1;
        }
        if (room == 0) return;

        const thumb = state.thumbIn(room);
        var i: u16 = 0;
        while (i < room) : (i += 1) {
            const on = i >= thumb.start and i < thumb.start + thumb.len;
            try b.put(
                win,
                from + i,
                if (on) b.thumb else b.track,
                if (on) b.thumb_style else b.style,
            );
        }
    }

    /// One cell along the bar's axis.
    fn put(b: Scrollbar, win: Window, at: u16, glyph: []const u8, style: Style) std.mem.Allocator.Error!void {
        switch (b.direction) {
            .vertical => try win.write(0, at, glyph, style, .none),
            .horizontal => try win.write(at, 0, glyph, style, .none),
        }
    }
};

const testing = std.testing;
const Harness = @import("harness.zig").Harness;

test "a scrollbar's thumb is as long as the viewport is of the content" {
    var h: Harness = try .init(testing.allocator, 1, 8);
    defer h.deinit();
    try (Scrollbar{}).draw(h.window(), .{ .content = 32, .viewport = 8, .position = 0 });
    try h.expectFrame(
        \\█
        \\█
        \\│
        \\│
        \\│
        \\│
        \\│
        \\│
        \\
    );
}

test "the thumb reaches the far end when the position does" {
    var h: Harness = try .init(testing.allocator, 1, 4);
    defer h.deinit();
    try (Scrollbar{}).draw(h.window(), .{ .content = 8, .viewport = 4, .position = 4 });
    try h.expectFrame(
        \\│
        \\│
        \\█
        \\█
        \\
    );
}

test "a scrollbar with nothing to scroll draws nothing" {
    var h: Harness = try .init(testing.allocator, 1, 3);
    defer h.deinit();
    try (Scrollbar{}).draw(h.window(), .{ .content = 3, .viewport = 3 });
    try h.expectFrame("\n\n\n");
}

test "arrows take a cell off each end of the track" {
    var h: Harness = try .init(testing.allocator, 6, 1);
    defer h.deinit();
    try (Scrollbar{
        .direction = .horizontal,
        .track = "\u{2500}",
        .begin = "\u{25c0}",
        .end = "\u{25b6}",
    }).draw(h.window(), .{ .content = 8, .viewport = 4, .position = 0 });
    try h.expectFrame(
        \\◀██──▶
        \\
    );
}

test "the thumb arithmetic is the same one a drag has to invert" {
    const s: Scrollbar.State = .{ .content = 100, .viewport = 10, .position = 45 };
    const t = s.thumbIn(20);
    try testing.expectEqual(@as(u16, 2), t.len);
    try testing.expectEqual(@as(u16, 9), t.start);
    try testing.expectEqual(@as(u16, 18), s.thumbIn(20).start + 9);
}

test "thumb arithmetic accepts the full usize state range" {
    const almost_whole: Scrollbar.State = .{
        .content = std.math.maxInt(usize),
        .viewport = std.math.maxInt(usize) - 1,
        .position = std.math.maxInt(usize),
    };
    try testing.expectEqual(@as(u16, 19), almost_whole.thumbIn(20).len);
    try testing.expectEqual(@as(u16, 1), almost_whole.thumbIn(20).start);

    const at_end: Scrollbar.State = .{
        .content = std.math.maxInt(usize),
        .viewport = 1,
        .position = std.math.maxInt(usize),
    };
    const thumb = at_end.thumbIn(std.math.maxInt(u16));
    try testing.expectEqual(@as(u16, 1), thumb.len);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16) - 1), thumb.start);
}

test "the thumb stays inside the track and reaches both ends exactly once" {
    var content: usize = 1;
    while (content <= 40) : (content += 7) {
        var viewport: usize = 1;
        while (viewport <= content) : (viewport += 3) {
            var len: u16 = 1;
            while (len <= 12) : (len += 1) {
                var position: usize = 0;
                while (position <= content) : (position += 1) {
                    const s: Scrollbar.State = .{
                        .content = content,
                        .viewport = viewport,
                        .position = position,
                    };
                    const t = s.thumbIn(len);
                    try testing.expect(t.len >= 1);
                    try testing.expect(t.start + t.len <= len);
                    if (position == 0) try testing.expectEqual(@as(u16, 0), t.start);
                    if (position >= content - viewport) {
                        try testing.expectEqual(len, t.start + t.len);
                    }
                }
            }
        }
    }
}
