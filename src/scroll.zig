//! Finding the frame whose rows moved, and writing it as a scroll.
//!
//! A frame in which the text scrolled by one row differs from the last one in
//! every row, so a diff repaints the whole screen for something the terminal
//! can do in a dozen bytes. This hashes the rows of both frames, looks for the
//! one offset that explains the most of them, checks the cells rather than
//! trusting the hashes, and writes a scrolling region and a scroll.
//!
//! It is conservative by construction: the offset has to explain at least two
//! rows that really changed, the band has to be longer than the distance
//! moved, and every row in it is compared cell by cell before a byte is
//! written. When any of that fails the frame is drawn the ordinary way, which
//! is correct and only costs more.
//!
//! What this file will never do: guess. A row that matches by hash and not by
//! cells is not a match.

const std = @import("std");
const morse = @import("morse");

const cellmod = @import("cell.zig");
const render = @import("render.zig");
const Caps = @import("caps.zig").Caps;
const Screen = @import("screen.zig").Screen;

const Cell = cellmod.Cell;
const Renderer = render.Renderer;
const Writer = std.Io.Writer;

/// The fewest rows an offset must explain before a scroll is worth writing.
const min_moved_rows = 2;
/// The fewest dirty rows before it is worth hashing the frame at all. Below
/// this a scroll cannot save more than it costs to look for one.
const min_dirty_rows = 3;

/// Writes this frame's rows as a scroll if they are one, and tells the
/// previous frame that they moved. Returns how many rows the terminal moved,
/// or null when the frame is not a scroll.
pub fn apply(r: *Renderer, out: *Writer, s: *Screen, caps: Caps) render.Error!?u32 {
    const found = detect(r, s, caps) orelse return null;
    const rows = r.size.rows;

    // The vacated rows are filled with the terminal's current background, so
    // the style has to be the one a blank cell is in.
    var ignored: Renderer.Stats = .{};
    try r.setStyle(out, .{}, &ignored);
    try r.setLink(out, s, .none, caps, &ignored);

    const whole = found.top == 0 and found.bottom == rows - 1;
    if (!whole) try morse.scrollRegion(out, found.top + 1, found.bottom + 1);
    if (found.up) {
        try morse.scrollUp(out, found.distance);
    } else {
        try morse.scrollDown(out, found.distance);
    }
    if (!whole) try morse.scrollRegionReset(out);
    r.cursor = null;

    r.shiftPrev(found.top, found.bottom, found.distance, found.up);
    return @as(u32, found.bottom - found.top) + 1;
}

/// A scroll the renderer could write instead of a repaint.
const Found = struct {
    /// The first row of the scrolling region.
    top: u16,
    /// The last row of it.
    bottom: u16,
    /// How many rows the contents move.
    distance: u16,
    /// Whether they move up, the way a terminal scrolls when something is
    /// written past the last row.
    up: bool,
};

/// Looks for the offset that explains the most rows, then for the longest
/// band of rows it explains, then checks that band cell by cell.
fn detect(r: *Renderer, s: *const Screen, caps: Caps) ?Found {
    const rows = r.size.rows;
    if (rows < 3 or r.repaint_all) return null;
    if (s.damage.count() < min_dirty_rows) return null;
    for (r.force) |f| if (f) return null;

    const now = r.hashes[0..rows];
    const was = r.hashes[rows..][0..rows];
    for (0..rows) |i| {
        now[i] = hashRow(s.rowAt(@intCast(i)), caps);
        was[i] = hashRow(r.prevRow(@intCast(i)), caps);
    }

    const offset = bestOffset(now, was) orelse return null;
    const band = longestBand(now, was, offset) orelse return null;

    const distance: u16 = @intCast(@abs(offset));
    if (band.last - band.first + 1 <= distance) return null;

    const up = offset < 0;
    const top = if (up) band.first else band.first - distance;
    const bottom = if (up) band.last + distance else band.last;
    if (up and bottom >= rows) return null;
    if (!up and band.first < distance) return null;

    var i = band.first;
    while (i <= band.last) : (i += 1) {
        const source: u16 = if (up) i + distance else i - distance;
        if (!rowsEqual(s.rowAt(i), r.prevRow(source), caps)) return null;
    }
    return .{ .top = top, .bottom = bottom, .distance = distance, .up = up };
}

/// The row offset that explains the most rows that really changed, or null
/// when no offset explains enough of them.
fn bestOffset(now: []const u64, was: []const u64) ?i32 {
    const rows: i32 = @intCast(now.len);
    var best: i32 = 0;
    var best_count: u32 = 0;
    var d: i32 = -(rows - 1);
    while (d <= rows - 1) : (d += 1) {
        if (d == 0) continue;
        var n: u32 = 0;
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const j = i - d;
            if (j < 0 or j >= rows) continue;
            const iu: usize = @intCast(i);
            const ju: usize = @intCast(j);
            if (now[iu] == was[ju] and now[iu] != was[iu]) n += 1;
        }
        if (n > best_count) {
            best_count = n;
            best = d;
        }
    }
    if (best_count < min_moved_rows) return null;
    return best;
}

/// The longest run of rows an offset explains, and how many of them really
/// changed.
fn longestBand(now: []const u64, was: []const u64, offset: i32) ?struct { first: u16, last: u16 } {
    const rows: i32 = @intCast(now.len);
    var best_first: i32 = -1;
    var best_last: i32 = -1;
    var best_moved: u32 = 0;

    var run_first: i32 = -1;
    var moved: u32 = 0;
    var i: i32 = 0;
    while (i <= rows) : (i += 1) {
        const j = if (i < rows) i - offset else -1;
        const ok = i < rows and j >= 0 and j < rows and
            now[@intCast(i)] == was[@intCast(j)];
        if (ok) {
            if (run_first < 0) {
                run_first = i;
                moved = 0;
            }
            if (now[@intCast(i)] != was[@intCast(i)]) moved += 1;
            continue;
        }
        if (run_first >= 0) {
            const length = i - run_first;
            const best_length = best_last - best_first + 1;
            if (moved >= min_moved_rows and (best_first < 0 or length > best_length)) {
                best_first = run_first;
                best_last = i - 1;
                best_moved = moved;
            }
            run_first = -1;
        }
    }
    if (best_first < 0) return null;
    return .{ .first = @intCast(best_first), .last = @intCast(best_last) };
}

/// A row's contents as one number, so two frames can be compared row by row
/// before they are compared cell by cell.
fn hashRow(cells: []const Cell, caps: Caps) u64 {
    if (caps.osc8) return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cells));
    var h: std.hash.Wyhash = .init(0);
    for (cells) |c| {
        const seen = render.visible(c, caps);
        h.update(std.mem.asBytes(&seen));
    }
    return h.final();
}

/// Whether two rows hold the same thing, which is what a hash match is
/// checked against.
fn rowsEqual(a: []const Cell, b: []const Cell, caps: Caps) bool {
    if (a.len != b.len) return false;
    if (caps.osc8) return cellmod.rowsEqual(a, b);
    for (a, b) |x, y| if (!render.visible(x, caps).eql(y)) return false;
    return true;
}
