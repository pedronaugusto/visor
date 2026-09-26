//! How big the terminal is: its grid, and what it has said about pixels.
//!
//! Cells are what a program draws in and they are always known. Pixels are
//! what a program sizing a picture needs, and they come from three places
//! that do not agree: the operating system's window size, an in-band resize
//! report, and the terminal's own answer to "how big is one cell". The first
//! two give the text area, which a terminal may pad, and dividing a padded
//! area by the grid gives a cell a little too large — an error that grows
//! toward the right edge, and a circle that comes out an ellipse. Only the
//! third is the cell.
//!
//! So `Winsize` keeps the two apart: `area` is what the operating system or
//! a resize said, `cell` is what the terminal answered, and `cellSize` hands
//! back whichever it has with a flag saying which. Nothing here divides
//! behind the caller's back and calls the answer a measurement.
//!
//! What this file will never hold: a timeout, a query written on the
//! caller's behalf, or a guess from the environment.

const std = @import("std");
const morse = @import("morse");

const geom = @import("geom.zig");

const Size = geom.Size;

/// A size in pixels. Zero on either side means the terminal did not say.
pub const Pixels = struct {
    /// How wide, in pixels.
    width: u32 = 0,
    /// How tall, in pixels.
    height: u32 = 0,

    /// Whether both sides are known.
    pub fn known(p: Pixels) bool {
        return p.width != 0 and p.height != 0;
    }
};

/// One cell, in pixels, and where the number came from.
pub const CellSize = struct {
    /// How wide one cell is. Fractional when it was worked out from the
    /// text area, whole when the terminal said.
    width: f32,
    /// How tall one cell is.
    height: f32,
    /// Whether the terminal reported it. False means it is the text area
    /// divided by the grid, which is too large wherever the terminal pads.
    reported: bool,
};

/// How big the terminal is: its grid, and what it has said about pixels.
pub const Winsize = struct {
    /// The grid, in cells.
    cells: Size = .{},
    /// The text area in pixels, as the operating system or a resize report
    /// gave it. Zero where nobody said, which is every multiplexer. It may
    /// include the terminal's padding, so it is not the cell size times the
    /// grid.
    area: Pixels = .{},
    /// One cell in pixels, as the terminal answered `CSI 16 t`
    /// (`morse.queryWindowSize(w, .cell_pixels)`). Never worked out from
    /// `area`. Cleared by a resize, because a resize is also what a change of
    /// font looks like: ask again when one arrives.
    cell: Pixels = .{},

    /// One cell in pixels: what the terminal reported, or failing that the
    /// text area divided by the grid, flagged as such; null when neither is
    /// known.
    pub fn cellSize(ws: Winsize) ?CellSize {
        if (ws.cell.known()) return .{
            .width = @floatFromInt(ws.cell.width),
            .height = @floatFromInt(ws.cell.height),
            .reported = true,
        };
        if (!ws.area.known() or ws.cells.isEmpty()) return null;
        return .{
            .width = @as(f32, @floatFromInt(ws.area.width)) / @as(f32, @floatFromInt(ws.cells.cols)),
            .height = @as(f32, @floatFromInt(ws.area.height)) / @as(f32, @floatFromInt(ws.cells.rows)),
            .reported = false,
        };
    }

    /// Folds one input event in: a resize, however it arrived, and the
    /// terminal's answers about its sizes. Returns whether anything changed.
    ///
    /// A resize that changes nothing changes nothing, so a terminal that
    /// reports in band and also sends the signal costs one event, not two.
    pub fn update(ws: *Winsize, event: morse.Event) bool {
        switch (event) {
            .resize => |r| return ws.resized(.{
                .cells = .{ .cols = clamp16(r.cols), .rows = clamp16(r.rows) },
                .area = .{ .width = r.xpixels, .height = r.ypixels },
            }),
            .reply => |reply| {
                const report = switch (reply) {
                    .window_size => |w| w,
                    else => return false,
                };
                const was = ws.*;
                switch (report.what) {
                    .cell_pixels => ws.cell = .{ .width = report.width, .height = report.height },
                    .text_area_pixels => ws.area = .{ .width = report.width, .height = report.height },
                    .text_area_cells => ws.cells = .{
                        .cols = clamp16(report.width),
                        .rows = clamp16(report.height),
                    },
                    .screen_pixels, .screen_cells => return false,
                }
                return !std.meta.eql(was, ws.*);
            },
            else => return false,
        }
    }

    /// A new grid and area, from wherever they came. The reported cell size
    /// is kept only when nothing moved.
    pub fn resized(ws: *Winsize, to: Winsize) bool {
        if (std.meta.eql(ws.cells, to.cells) and std.meta.eql(ws.area, to.area)) return false;
        ws.cells = to.cells;
        ws.area = to.area;
        ws.cell = .{};
        return true;
    }
};

fn clamp16(v: u32) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

const testing = std.testing;

test "a cell the terminal reported is the cell, whatever the area says" {
    var ws: Winsize = .{
        .cells = .{ .cols = 100, .rows = 40 },
        // Padded: ten pixels either side of a grid of 9-pixel cells.
        .area = .{ .width = 920, .height = 840 },
    };
    const derived = ws.cellSize().?;
    try testing.expect(!derived.reported);
    try testing.expectEqual(@as(f32, 9.2), derived.width);

    try testing.expect(ws.update(answer("\x1b[6;20;9t")));
    const reported = ws.cellSize().?;
    try testing.expect(reported.reported);
    try testing.expectEqual(@as(f32, 9), reported.width);
    try testing.expectEqual(@as(f32, 20), reported.height);
}

test "nothing known is nothing, not a division by zero" {
    try testing.expectEqual(@as(?CellSize, null), (Winsize{}).cellSize());
    const no_grid: Winsize = .{ .area = .{ .width = 800, .height = 600 } };
    try testing.expectEqual(@as(?CellSize, null), no_grid.cellSize());
    const no_area: Winsize = .{ .cells = .{ .cols = 80, .rows = 24 } };
    try testing.expectEqual(@as(?CellSize, null), no_area.cellSize());
}

test "a resize carries its pixels, and forgets a reported cell" {
    var ws: Winsize = .{ .cells = .{ .cols = 80, .rows = 24 }, .cell = .{ .width = 9, .height = 20 } };
    try testing.expect(ws.update(.{ .resize = .{ .rows = 30, .cols = 100, .ypixels = 600, .xpixels = 900 } }));
    try testing.expectEqual(Size{ .cols = 100, .rows = 30 }, ws.cells);
    try testing.expectEqual(Pixels{ .width = 900, .height = 600 }, ws.area);
    try testing.expect(!ws.cell.known());
    try testing.expect(!ws.cellSize().?.reported);
}

test "a resize to the same size changes nothing and keeps the cell" {
    var ws: Winsize = .{
        .cells = .{ .cols = 80, .rows = 24 },
        .area = .{ .width = 720, .height = 480 },
        .cell = .{ .width = 9, .height = 20 },
    };
    try testing.expect(!ws.update(.{ .resize = .{ .rows = 24, .cols = 80, .ypixels = 480, .xpixels = 720 } }));
    try testing.expect(ws.cell.known());
}

test "the size answers fold in, and anything else is ignored" {
    var ws: Winsize = .{};
    try testing.expect(ws.update(answer("\x1b[8;24;80t")));
    try testing.expectEqual(Size{ .cols = 80, .rows = 24 }, ws.cells);
    try testing.expect(ws.update(answer("\x1b[4;480;720t")));
    try testing.expectEqual(Pixels{ .width = 720, .height = 480 }, ws.area);
    try testing.expect(!ws.update(answer("\x1b[4;480;720t")));
    try testing.expect(!ws.update(answer("\x1b[?62c")));
    try testing.expect(!ws.update(.{ .key = .{ .key = .escape } }));
    try testing.expect(!ws.update(answer("\x1b[9;50;200t")));
}

/// A reply as the input reads it.
fn answer(bytes: []const u8) morse.Event {
    return .{ .reply = morse.Reply.parse(bytes).? };
}
