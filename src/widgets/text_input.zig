//! Text being typed: laid out as rows, with the cursor as a place in them.
//!
//! The arithmetic is the whole of it and is public, because the program that
//! draws the text is also the one that moves the cursor up a row or to the
//! end of one, and the two have to agree on where every row breaks. So the
//! layout is a set of functions of the text, the width and the width method,
//! and `draw` is those functions and a few writes.
//!
//! A row is a byte range of the text. Rows break at a newline, and before a
//! word that would cross the width; a word wider than the row is cut between
//! clusters. Every byte belongs to exactly one row — the spaces a break
//! falls after and the newline a row ends on included — so a cursor anywhere
//! in the text has a row and a column. That is why this is not `visor.wrap`,
//! which swallows the spaces at a break.
//!
//! `Buffer` owns text being edited: insertion, deletion by the same motions
//! the cursor moves by, a selection, and edits to undo and redo, every one of
//! them on whole clusters.
//!
//! What this file will never hold: key handling. Which key moves the cursor
//! where, or deletes what, is the program's; this says where "up a row" or
//! "a word back" lands, and does the edit.

const std = @import("std");
const visor = @import("visor");

const Style = visor.Style;

/// Text being typed, and where the cursor is in it.
pub const TextInput = struct {
    /// The text.
    text: []const u8,
    /// Where the cursor is, as a byte offset into `text`. Clamped to its end.
    cursor: usize = 0,
    /// The style the text draws in.
    style: Style = .{},
    /// Whether the terminal's cursor is put at the text cursor. A program
    /// that draws a caret of its own leaves it off and asks `place` where.
    show_cursor: bool = true,
    /// Bytes drawn in `selected_style`, or null.
    selection: ?Range = null,
    /// The style the selection draws in.
    selected_style: Style = .{ .reverse = true },

    /// A run of the text, as byte offsets, `start` before `end`.
    pub const Range = struct {
        start: usize,
        end: usize,
    };

    /// One row: the bytes `text[from..to]`, and whether it ends on a newline
    /// the text carries, which belongs to the row but is not drawn.
    pub const Row = struct {
        /// Where the row starts.
        from: usize,
        /// Where its drawn bytes end.
        to: usize,
        /// Whether a newline follows `to` and ends the row.
        hard: bool = false,
    };

    /// A place in the layout: a row, and a column in cells.
    pub const Place = struct {
        /// Which row.
        row: usize,
        /// Which column of it, in cells.
        col: usize,
    };

    /// What a text input remembers between frames: the first row shown.
    pub const State = struct {
        /// The first row drawn. `draw` moves it to keep the cursor's row on
        /// screen.
        first: usize = 0,
    };

    /// The rows of a text at a width, one at a time. Never empty: an empty
    /// text is one empty row.
    pub const Rows = struct {
        _text: []const u8,
        _cols: u16,
        _method: visor.Method,
        _at: usize = 0,
        _done: bool = false,

        /// The next row, or null after the last.
        pub fn next(r: *Rows) ?TextInput.Row {
            if (r._done) return null;
            const start = r._at;
            var used: u32 = 0;
            var last_space: ?usize = null;
            var it: visor.Graphemes = .init(r._text[start..]);
            while (it.nextAt()) |found| {
                const i = start + found.start;
                const g = found.bytes;
                // A newline is one cluster, or two when a carriage return
                // came before it; either ends the row and belongs to it.
                if (g[g.len - 1] == '\n') {
                    r._at = i + g.len;
                    return .{ .from = start, .to = i, .hard = true };
                }
                const w = visor.graphemeWidth(g, r._method);
                // A cluster wider than the whole row still takes a row: the
                // alternative is a row that never ends.
                if (used != 0 and used + w > r._cols) {
                    const brk = if (last_space) |sp| sp + 1 else i;
                    r._at = brk;
                    return .{ .from = start, .to = brk };
                }
                if (g.len == 1 and g[0] == ' ') last_space = i;
                used += w;
            }
            r._done = true;
            r._at = r._text.len;
            return .{ .from = start, .to = r._text.len };
        }
    };

    /// The rows of `text` at `cols` cells, measured by `method`.
    pub fn rows(text: []const u8, cols: u16, method: visor.Method) Rows {
        return .{ ._text = text, ._cols = @max(cols, 1), ._method = method };
    }

    /// How many rows `text` takes at `cols` cells.
    pub fn rowCount(text: []const u8, cols: u16, method: visor.Method) usize {
        var it = rows(text, cols, method);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Where a byte offset stands: its row, and the cell column in it. A
    /// cursor at a soft break belongs to the start of the next row; one at a
    /// newline, to the end of the row the newline ends.
    pub fn place(text: []const u8, cols: u16, method: visor.Method, cursor: usize) Place {
        const c = @min(cursor, text.len);
        var it = rows(text, cols, method);
        var row: usize = 0;
        var current = it.next().?;
        while (true) : (row += 1) {
            // A row owns its bytes up to where the next one starts: its
            // newline, when it ends on one, and nothing when it ends on a
            // soft break, whose place is the next row's start.
            const following = it.next();
            const owned_end = if (following) |f| f.from else text.len + 1;
            if (c < owned_end) {
                return .{ .row = row, .col = visor.width(text[current.from..@min(c, current.to)], method) };
            }
            current = following.?;
        }
    }

    /// The byte offset at a row and a column: the cluster there, or the
    /// row's end when the row is shorter. A row past the last is the last.
    pub fn at(text: []const u8, cols: u16, method: visor.Method, row: usize, col: usize) usize {
        var it = rows(text, cols, method);
        var r = it.next().?;
        var n: usize = 0;
        while (n < row) : (n += 1) r = it.next() orelse break;
        var x: usize = 0;
        var g: visor.Graphemes = .init(text[r.from..r.to]);
        while (g.nextAt()) |found| {
            const w = visor.graphemeWidth(found.bytes, method);
            // The cluster covering the column, or the first to start at it:
            // a cluster that takes no columns is somewhere a cursor can be.
            if (x + w > col or x >= col) return r.from + found.start;
            x += w;
        }
        return r.to;
    }

    /// The start of the cluster before `cursor`.
    pub fn prev(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        if (c == 0) return 0;
        // Clusters never cross a newline, so the search starts at the line.
        const from = lineStart(text, c - 1);
        var g: visor.Graphemes = .init(text[from..c]);
        var last: usize = from;
        while (g.nextAt()) |found| last = from + found.start;
        return last;
    }

    /// The end of the cluster at `cursor`.
    pub fn next(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        var g: visor.Graphemes = .init(text[c..]);
        const found = g.next() orelse return text.len;
        return c + found.len;
    }

    /// The start of the word before `cursor`: spaces and newlines skipped,
    /// then the word. Where erasing a word back from the cursor stops.
    ///
    /// A word is a run of clusters that do not begin with a space, a tab or
    /// a line break, so the answer is always where a cluster starts.
    pub fn wordStart(text: []const u8, cursor: usize) usize {
        var c = @min(cursor, text.len);
        while (true) {
            // Clusters never cross a newline, so each line is read on its own
            // from its start, the last word in it before the cursor kept.
            const from = lineStart(text, c);
            var it: visor.Graphemes = .init(text[from..c]);
            var word: ?usize = null;
            var last: ?usize = null;
            while (it.nextAt()) |g| {
                if (spaceCluster(g.bytes)) {
                    word = null;
                } else {
                    if (word == null) word = from + g.start;
                    last = word;
                }
            }
            if (last) |w| return w;
            if (from == 0) return 0;
            c = prev(text, from);
        }
    }

    /// The end of the word after `cursor`: spaces and newlines skipped, then
    /// the word. Where a word forward lands, and where erasing one stops.
    pub fn wordEnd(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        var it: visor.Graphemes = .init(text[c..]);
        var in_word = false;
        while (it.nextAt()) |g| {
            const space = spaceCluster(g.bytes);
            if (in_word and space) return c + g.start;
            if (!space) in_word = true;
        }
        return text.len;
    }

    fn spaceCluster(g: []const u8) bool {
        return isSpace(g[0]) or g[0] == '\t';
    }

    /// The start of the line the cursor is on, just after the newline
    /// before it.
    pub fn lineStart(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        return if (std.mem.lastIndexOfScalar(u8, text[0..c], '\n')) |nl| nl + 1 else 0;
    }

    /// The end of the line the cursor is on, just before the next newline
    /// and the carriage return that may come with it.
    pub fn lineEnd(text: []const u8, cursor: usize) usize {
        const c = @min(cursor, text.len);
        const nl = std.mem.indexOfScalarPos(u8, text, c, '\n') orelse return text.len;
        return if (nl > c and text[nl - 1] == '\r') nl - 1 else nl;
    }

    fn isSpace(b: u8) bool {
        return b == ' ' or b == '\n' or b == '\r';
    }

    /// Draws as many rows as the window has, moving `state.first` so the
    /// cursor's row is among them, and puts the terminal's cursor at the
    /// text cursor when `show_cursor` is on.
    pub fn draw(t: TextInput, win: visor.Window, state: *State) (std.mem.Allocator.Error || error{ InvalidHandle, InvalidCell })!void {
        if (win.rect().isEmpty()) return;
        const method = win.screen().method;
        const cols = win.cols();
        const height: usize = win.rows();
        const total = rowCount(t.text, cols, method);
        const cursor = place(t.text, cols, method, t.cursor);

        if (cursor.row < state.first) state.first = cursor.row;
        if (cursor.row >= state.first + height) state.first = cursor.row + 1 - height;
        // Text that shrank does not leave the view scrolled past its end.
        state.first = @min(state.first, total -| height);

        var it = rows(t.text, cols, method);
        var n: usize = 0;
        while (it.next()) |r| : (n += 1) {
            if (n < state.first) continue;
            const y = n - state.first;
            if (y >= height) break;
            // The row in up to three runs: before the selection, in it, after.
            const sel: Range = t.selection orelse .{ .start = r.to, .end = r.to };
            const a = std.math.clamp(@min(sel.start, sel.end), r.from, r.to);
            const b = std.math.clamp(@max(sel.start, sel.end), r.from, r.to);
            _ = try win.print(&.{
                .{ .text = t.text[r.from..a], .style = t.style },
                .{ .text = t.text[a..b], .style = t.selected_style },
                .{ .text = t.text[b..r.to], .style = t.style },
            }, .{ .row = @intCast(y), .wrap = .none });
        }
        if (t.show_cursor) {
            win.showCursor(@intCast(@min(cursor.col, cols -| 1)), @intCast(cursor.row - state.first));
        }
    }

    /// Text being edited, owned: the cursor, a selection, and the edits to
    /// undo and redo. Every operation is one a program maps a key to; none
    /// is mapped here.
    ///
    /// The cursor lands on cluster boundaries: every motion moves by whole
    /// clusters, and deleting by a motion removes whole clusters. Inserted
    /// bytes are taken as given and the cursor put after them, which is
    /// inside a cluster only when they were a letter typed before a mark
    /// already there.
    ///
    /// Undo goes back an edit at a time, and typing is one edit a word:
    /// clusters typed one after another join the edit before them until a
    /// word follows a space, and a run of deletions back or forward joins
    /// the same way. Any motion, selection, paste or undo ends the edit, and
    /// `seal` ends it for a program that wants its own boundary -- on a
    /// pause, say, which needs a clock this does not have.
    pub const Buffer = struct {
        _gpa: std.mem.Allocator,
        _text: std.ArrayList(u8) = .empty,
        _cursor: usize = 0,
        _anchor: ?usize = null,
        /// The column vertical moves keep to, set by the first of them.
        _goal: ?usize = null,
        /// Removed and inserted bytes of every edit kept, in order.
        _bytes: std.ArrayList(u8) = .empty,
        _edits: std.ArrayList(Edit) = .empty,
        /// How many edits are applied; the ones after are for redo.
        _done: usize = 0,
        /// Whether the last edit may take the next one into it.
        _open: bool = false,
        /// The most bytes of removed and inserted text kept for undo. The
        /// oldest edits go first; an edit larger than this is not kept.
        history_limit: usize = 1 << 20,

        /// Where a motion takes the cursor, by the same rules as the
        /// functions of `TextInput` that name it.
        pub const Motion = enum {
            /// One cluster back.
            left,
            /// One cluster forward.
            right,
            /// To the start of the word before the cursor.
            word_left,
            /// To the end of the word after the cursor.
            word_right,
            /// To the start of the line, after the newline before it.
            line_start,
            /// To the end of the line, before its newline.
            line_end,
            /// To the start of the text.
            start,
            /// To the end of the text.
            end,
        };

        const Kind = enum { typing, back, forward, other };

        const Edit = struct {
            at: usize,
            /// Where its bytes start in `_bytes`: the removed, then the
            /// inserted.
            bytes: usize,
            removed: usize,
            inserted: usize,
            cursor_before: usize,
            anchor_before: ?usize,
            kind: Kind,
        };

        /// An empty buffer.
        pub fn init(gpa: std.mem.Allocator) TextInput.Buffer {
            return .{ ._gpa = gpa };
        }

        /// A buffer holding `bytes`, the cursor at the end, nothing to undo.
        pub fn initText(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!TextInput.Buffer {
            var b: Buffer = .init(gpa);
            try b._text.appendSlice(gpa, bytes);
            b._cursor = bytes.len;
            return b;
        }

        pub fn deinit(b: *Buffer) void {
            b._text.deinit(b._gpa);
            b._bytes.deinit(b._gpa);
            b._edits.deinit(b._gpa);
            b.* = undefined;
        }

        /// The text, borrowed until the next edit.
        pub fn text(b: *const Buffer) []const u8 {
            return b._text.items;
        }

        /// The cursor, as a byte offset into the text.
        pub fn cursor(b: *const Buffer) usize {
            return b._cursor;
        }

        /// The selected bytes, in order, or null when nothing is selected.
        pub fn selection(b: *const Buffer) ?TextInput.Range {
            const anchor = b._anchor orelse return null;
            if (anchor == b._cursor) return null;
            return .{ .start = @min(anchor, b._cursor), .end = @max(anchor, b._cursor) };
        }

        /// The selected text, empty when nothing is, borrowed until the
        /// next edit: what a program copies.
        pub fn selectedText(b: *const Buffer) []const u8 {
            const sel = b.selection() orelse return "";
            return b._text.items[sel.start..sel.end];
        }

        /// The widget for this buffer: its text, its cursor and its
        /// selection, in the default styles.
        pub fn input(b: *const Buffer) TextInput {
            return .{ .text = b.text(), .cursor = b._cursor, .selection = b.selection() };
        }

        /// Where a motion lands from the cursor.
        pub fn target(b: *const Buffer, motion: Motion) usize {
            const t = b._text.items;
            return switch (motion) {
                .left => TextInput.prev(t, b._cursor),
                .right => TextInput.next(t, b._cursor),
                .word_left => TextInput.wordStart(t, b._cursor),
                .word_right => TextInput.wordEnd(t, b._cursor),
                .line_start => TextInput.lineStart(t, b._cursor),
                .line_end => TextInput.lineEnd(t, b._cursor),
                .start => 0,
                .end => t.len,
            };
        }

        /// Moves the cursor. With `extend`, the selection runs from where it
        /// started, or from the cursor, to where the cursor lands; without,
        /// the selection goes, and a step left or right from one lands on
        /// its own edge.
        pub fn move(b: *Buffer, motion: Motion, extend: bool) void {
            if (!extend) if (b.selection()) |sel| switch (motion) {
                .left, .right => {
                    b.land(if (motion == .left) sel.start else sel.end, false);
                    return;
                },
                else => {},
            };
            b.land(b.target(motion), extend);
        }

        /// Moves the cursor `by` rows of the text laid out `cols` wide, down
        /// for a positive count, keeping to the column the first of a run of
        /// such moves started at. Past the first or last row it stops there.
        pub fn moveRows(b: *Buffer, by: isize, cols: u16, method: visor.Method, extend: bool) void {
            const t = b._text.items;
            const here = place(t, cols, method, b._cursor);
            const goal = b._goal orelse here.col;
            const last = rowCount(t, cols, method) - 1;
            const row: usize = if (by < 0) here.row -| @abs(by) else @min(here.row +| @abs(by), last);
            b.land(at(t, cols, method, row, goal), extend);
            b._goal = goal;
        }

        /// Moves the cursor to a byte offset, which goes back to the start of
        /// the cluster it falls in: where a click lands, from `at`.
        pub fn moveTo(b: *Buffer, offset: usize, extend: bool) void {
            const t = b._text.items;
            const c = @min(offset, t.len);
            // The cluster containing `c` starts at or before it; its start is
            // the last boundary at or before `c` on its line.
            const from = lineStart(t, c);
            var it: visor.Graphemes = .init(t[from..]);
            var boundary = from;
            while (it.nextAt()) |g| {
                if (from + g.start > c) break;
                boundary = from + g.start;
            }
            b.land(if (c == t.len) c else boundary, extend);
        }

        /// Selects the whole text, the cursor at its end.
        pub fn selectAll(b: *Buffer) void {
            b._anchor = 0;
            b._cursor = b._text.items.len;
            b.endEdit();
        }

        /// Drops the selection and leaves the cursor where it is.
        pub fn selectNone(b: *Buffer) void {
            b._anchor = null;
            b.endEdit();
        }

        /// Inserts `bytes` at the cursor, in place of the selection when
        /// there is one, and puts the cursor after them.
        pub fn insert(b: *Buffer, bytes: []const u8) std.mem.Allocator.Error!void {
            if (b.selection()) |sel| return b.replace(sel.start, sel.end, bytes, .other);
            if (bytes.len == 0) return;
            var it: visor.Graphemes = .init(bytes);
            _ = it.next();
            const one = it.next() == null and bytes[0] != '\n' and bytes[0] != '\r';
            try b.replace(b._cursor, b._cursor, bytes, if (one) .typing else .other);
        }

        /// Deletes the selection when there is one, and otherwise the text
        /// between the cursor and where `motion` lands: `.left` is a
        /// backspace, `.word_left` erases a word back, `.line_end` kills to
        /// the end of the line.
        pub fn delete(b: *Buffer, motion: Motion) std.mem.Allocator.Error!void {
            if (b.selection()) |sel| return b.replace(sel.start, sel.end, "", .other);
            b._anchor = null;
            const to = b.target(motion);
            if (to == b._cursor) return;
            const kind: Kind = switch (motion) {
                .left => .back,
                .right => .forward,
                else => .other,
            };
            try b.replace(@min(to, b._cursor), @max(to, b._cursor), "", kind);
        }

        /// Replaces the whole text, as one edit that can be undone.
        pub fn replaceAll(b: *Buffer, bytes: []const u8) std.mem.Allocator.Error!void {
            b._anchor = null;
            try b.replace(0, b._text.items.len, bytes, .other);
        }

        /// Replaces the whole text and forgets every edit: a fresh input,
        /// after the text was sent, say.
        pub fn reset(b: *Buffer, bytes: []const u8) std.mem.Allocator.Error!void {
            b._text.clearRetainingCapacity();
            try b._text.appendSlice(b._gpa, bytes);
            b._cursor = bytes.len;
            b._anchor = null;
            b._goal = null;
            b.clearHistory();
        }

        /// Ends the edit being made, so the next starts an undo step of its
        /// own.
        pub fn seal(b: *Buffer) void {
            b._open = false;
        }

        /// Forgets every edit, done and undone.
        pub fn clearHistory(b: *Buffer) void {
            b._bytes.clearRetainingCapacity();
            b._edits.clearRetainingCapacity();
            b._done = 0;
            b._open = false;
        }

        /// Whether there is an edit to undo.
        pub fn canUndo(b: *const Buffer) bool {
            return b._done > 0;
        }

        /// Whether there is an undone edit to redo.
        pub fn canRedo(b: *const Buffer) bool {
            return b._done < b._edits.items.len;
        }

        /// Takes back the last edit, the cursor and selection put back as
        /// they were before it. False when there is nothing to undo.
        pub fn undo(b: *Buffer) std.mem.Allocator.Error!bool {
            if (b._done == 0) return false;
            const e = b._edits.items[b._done - 1];
            const removed = b._bytes.items[e.bytes..][0..e.removed];
            try b._text.ensureUnusedCapacity(b._gpa, e.removed -| e.inserted);
            b._text.replaceRangeAssumeCapacity(e.at, e.inserted, removed);
            b._done -= 1;
            b._cursor = e.cursor_before;
            b._anchor = e.anchor_before;
            b.endEdit();
            return true;
        }

        /// Makes the last edit undone again. False when there is nothing to
        /// redo.
        pub fn redo(b: *Buffer) std.mem.Allocator.Error!bool {
            if (b._done == b._edits.items.len) return false;
            const e = b._edits.items[b._done];
            const inserted = b._bytes.items[e.bytes + e.removed ..][0..e.inserted];
            try b._text.ensureUnusedCapacity(b._gpa, e.inserted -| e.removed);
            b._text.replaceRangeAssumeCapacity(e.at, e.removed, inserted);
            b._done += 1;
            b._cursor = e.at + e.inserted;
            b._anchor = null;
            b.endEdit();
            return true;
        }

        fn land(b: *Buffer, to: usize, extend: bool) void {
            if (extend) {
                if (b._anchor == null) b._anchor = b._cursor;
            } else b._anchor = null;
            b._cursor = to;
            b.endEdit();
        }

        fn endEdit(b: *Buffer) void {
            b._open = false;
            b._goal = null;
        }

        /// `text[from..to]` replaced by `bytes`, recorded first. Nothing
        /// changes when an allocation fails.
        fn replace(b: *Buffer, from: usize, to: usize, bytes: []const u8, kind: Kind) std.mem.Allocator.Error!void {
            try b._text.ensureUnusedCapacity(b._gpa, bytes.len -| (to - from));
            try b.record(from, b._text.items[from..to], bytes, kind);
            b._text.replaceRangeAssumeCapacity(from, to - from, bytes);
            b._cursor = from + bytes.len;
            b._anchor = null;
            b._goal = null;
            b._open = kind != .other;
        }

        fn record(b: *Buffer, at_: usize, removed: []const u8, inserted: []const u8, kind: Kind) std.mem.Allocator.Error!void {
            const gpa = b._gpa;
            // The edits that were undone go when a new one is made.
            const kept_bytes = if (b._done == 0) 0 else blk: {
                const e = b._edits.items[b._done - 1];
                break :blk e.bytes + e.removed + e.inserted;
            };
            const joined = b._open and b._done == b._edits.items.len and b._done > 0 and
                b.joins(b._edits.items[b._done - 1], at_, removed, inserted, kind);
            try b._bytes.ensureTotalCapacity(gpa, kept_bytes + removed.len + inserted.len);
            if (!joined) try b._edits.ensureTotalCapacity(gpa, b._done + 1);

            b._edits.shrinkRetainingCapacity(b._done);
            b._bytes.shrinkRetainingCapacity(kept_bytes);
            if (joined) {
                const last = &b._edits.items[b._done - 1];
                switch (kind) {
                    .typing => {
                        b._bytes.appendSliceAssumeCapacity(inserted);
                        last.inserted += inserted.len;
                    },
                    .back => {
                        b._bytes.insertSliceAssumeCapacity(last.bytes, removed);
                        last.removed += removed.len;
                        last.at = at_;
                    },
                    .forward => {
                        b._bytes.appendSliceAssumeCapacity(removed);
                        last.removed += removed.len;
                    },
                    .other => unreachable,
                }
            } else {
                const start = b._bytes.items.len;
                b._bytes.appendSliceAssumeCapacity(removed);
                b._bytes.appendSliceAssumeCapacity(inserted);
                b._edits.appendAssumeCapacity(.{
                    .at = at_,
                    .bytes = start,
                    .removed = removed.len,
                    .inserted = inserted.len,
                    .cursor_before = b._cursor,
                    .anchor_before = b._anchor,
                    .kind = kind,
                });
                b._done += 1;
            }
            b.trim();
        }

        /// Whether an edit joins the last one: typing that goes on where the
        /// last typing ended, until a word follows a space; a deletion back
        /// that ends where the last began; one forward from the same place.
        fn joins(b: *const Buffer, last: Edit, at_: usize, removed: []const u8, inserted: []const u8, kind: Kind) bool {
            if (kind != last.kind) return false;
            return switch (kind) {
                .typing => typing: {
                    if (last.removed != 0 or at_ != last.at + last.inserted) break :typing false;
                    const before = b._bytes.items[last.bytes + last.removed + last.inserted - 1];
                    break :typing !(spaceCluster(&.{before}) and !spaceCluster(inserted));
                },
                .back => at_ + removed.len == last.at,
                .forward => at_ == last.at,
                .other => false,
            };
        }

        /// Drops the oldest edits until what is kept fits the limit.
        fn trim(b: *Buffer) void {
            var drop: usize = 0;
            var bytes: usize = 0;
            const total = b._bytes.items.len;
            while (drop < b._edits.items.len and total - bytes > b.history_limit) : (drop += 1) {
                const e = b._edits.items[drop];
                bytes += e.removed + e.inserted;
            }
            if (drop == 0) return;
            std.mem.copyForwards(u8, b._bytes.items[0 .. total - bytes], b._bytes.items[bytes..]);
            b._bytes.shrinkRetainingCapacity(total - bytes);
            const left = b._edits.items.len - drop;
            std.mem.copyForwards(Edit, b._edits.items[0..left], b._edits.items[drop..]);
            b._edits.shrinkRetainingCapacity(left);
            for (b._edits.items) |*e| e.bytes -= bytes;
            b._done -= drop;
            // The last edit is gone when it alone was too large.
            if (b._done == 0) b._open = false;
        }
    };
};

const testing = std.testing;
const Harness = @import("../testing/widget_harness.zig").Harness;
const corpus = @import("corpus");

fn allRows(text: []const u8, cols: u16) ![]TextInput.Row {
    var list: std.ArrayList(TextInput.Row) = .empty;
    var it = TextInput.rows(text, cols, .unicode);
    while (it.next()) |r| try list.append(testing.allocator, r);
    return list.toOwnedSlice(testing.allocator);
}

test "rows break at newlines and before a word that would cross the width" {
    const text = "fix the bay filter\nthen the header of the crew bay please";
    const all = try allRows(text, 16);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqualStrings("fix the bay ", text[all[0].from..all[0].to]);
    try testing.expectEqualStrings("filter", text[all[1].from..all[1].to]);
    try testing.expect(all[1].hard);
    try testing.expectEqualStrings("then the header ", text[all[2].from..all[2].to]);
    try testing.expectEqualStrings("of the crew bay ", text[all[3].from..all[3].to]);
    try testing.expectEqualStrings("please", text[all[4].from..all[4].to]);
    // Every byte belongs to one row, in order.
    var seen: usize = 0;
    for (all) |r| {
        try testing.expectEqual(seen, r.from);
        seen = if (r.hard) r.to + 1 else r.to;
    }
    try testing.expectEqual(text.len, seen);

    // An empty text is one empty row; a word wider than the row is cut.
    try testing.expectEqual(@as(usize, 1), TextInput.rowCount("", 10, .unicode));
    const cut = try allRows("abcdefghijkl", 5);
    defer testing.allocator.free(cut);
    try testing.expectEqual(@as(usize, 3), cut.len);
    try testing.expectEqualStrings("fghij", "abcdefghijkl"[cut[1].from..cut[1].to]);
}

test "a wide cluster is two columns, and never splits or stalls a row" {
    const text = "ab\u{4e2d}\u{6587}cd";
    const two = try allRows(text, 3);
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("ab", text[two[0].from..two[0].to]);
    try testing.expectEqualStrings("\u{4e2d}", text[two[1].from..two[1].to]);
    // A row one column wide still takes the wide cluster rather than
    // looping on an empty row.
    try testing.expectEqual(@as(usize, 6), TextInput.rowCount(text, 1, .unicode));
    // A family emoji is one cluster of two columns, not five codepoints.
    const family = "\u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 2 }, TextInput.place(family, 10, .unicode, family.len));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(family, family.len));
    try testing.expectEqual(family.len, TextInput.next(family, 0));
}

test "the cursor has a row and a column, and a column has a byte" {
    const text = "one two three\nfour";
    // "one two " · "three" (hard) · "four"
    try testing.expectEqual(@as(usize, 3), TextInput.rowCount(text, 8, .unicode));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 4 }, TextInput.place(text, 8, .unicode, 4));
    // At the soft break the cursor stands at the next row's start.
    try testing.expectEqual(TextInput.Place{ .row = 1, .col = 0 }, TextInput.place(text, 8, .unicode, 8));
    // At a hard break's newline it stands at the end of its row.
    try testing.expectEqual(TextInput.Place{ .row = 1, .col = 5 }, TextInput.place(text, 8, .unicode, 13));
    try testing.expectEqual(TextInput.Place{ .row = 2, .col = 4 }, TextInput.place(text, 8, .unicode, text.len));
    try testing.expectEqual(@as(usize, 4), TextInput.at(text, 8, .unicode, 0, 4));
    try testing.expectEqual(@as(usize, 13), TextInput.at(text, 8, .unicode, 1, 9));
    try testing.expectEqual(@as(usize, 14), TextInput.at(text, 8, .unicode, 2, 0));
    try testing.expectEqual(@as(usize, 18), TextInput.at(text, 8, .unicode, 9, 9));
    // Steps, words, lines.
    try testing.expectEqual(@as(usize, 3), TextInput.prev(text, 4));
    try testing.expectEqual(@as(usize, 5), TextInput.next(text, 4));
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(text, 7));
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(text, 8));
    try testing.expectEqual(@as(usize, 14), TextInput.lineStart(text, 16));
    try testing.expectEqual(@as(usize, 13), TextInput.lineEnd(text, 3));
    // A step back over a newline lands on it, and at the start stays.
    try testing.expectEqual(@as(usize, 13), TextInput.prev(text, 14));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(text, 0));
    try testing.expectEqual(text.len, TextInput.next(text, text.len));
}

test "a combining mark moves with the letter it sits on" {
    const text = "e\u{301}x";
    try testing.expectEqual(@as(usize, 3), TextInput.next(text, 0));
    try testing.expectEqual(@as(usize, 0), TextInput.prev(text, 3));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 1 }, TextInput.place(text, 10, .unicode, 3));
}

test "a cluster that takes no columns is still a place the cursor can be" {
    const text = "a\tb";
    const p = TextInput.place(text, 8, .unicode, 1);
    try testing.expectEqual(@as(usize, 1), TextInput.at(text, 8, .unicode, p.row, p.col));
    try testing.expectEqual(@as(usize, 0), TextInput.at("\t", 8, .unicode, 0, 0));
}

test "a row too narrow for its one wide cluster keeps the clusters that take no room" {
    // A tab takes no columns here, so it shares the row with the wide
    // cluster that does not fit a one-column row anyway.
    const text = "\n\t\u{1f469}\u{200d}\u{1f680}";
    const all = try allRows(text, 1);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings(text[1..], text[all[1].from..all[1].to]);
}

test "a malformed byte is one cell and still has a row" {
    try testing.expectEqual(@as(usize, 1), TextInput.rowCount(&.{0xff}, 1, .unicode));
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 1 }, TextInput.place(&.{ 0xff, 'a' }, 10, .unicode, 1));
}

test "the input draws the rows around the cursor and puts the cursor there" {
    var h: Harness = try .init(testing.allocator, 8, 2);
    defer h.deinit();
    var state: TextInput.State = .{};
    const text = "one two three four";
    try (TextInput{ .text = text, .cursor = text.len }).draw(h.window(), &state);
    // "one two " · "three " · "four": the last two, with the cursor after
    // "four".
    try testing.expectEqual(@as(usize, 1), state.first);
    try h.expectFrame(
        \\three
        \\four
        \\
    );
    try testing.expect(h.screen.cursor.visible);
    try testing.expectEqual(@as(u16, 4), h.screen.cursor.col);
    try testing.expectEqual(@as(u16, 1), h.screen.cursor.row);

    // Home: the view follows the cursor back up.
    h.window().clear();
    try (TextInput{ .text = text, .cursor = 0 }).draw(h.window(), &state);
    try testing.expectEqual(@as(usize, 0), state.first);
    try h.expectFrame(
        \\one two
        \\three
        \\
    );
}

test "a carriage return and newline end a row together" {
    const text = "ab\r\ncd";
    const all = try allRows(text, 10);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("ab", text[all[0].from..all[0].to]);
    try testing.expect(all[0].hard);
    try testing.expectEqualStrings("cd", text[all[1].from..all[1].to]);
    try testing.expectEqual(@as(usize, 2), TextInput.lineEnd(text, 0));
    try testing.expectEqual(@as(usize, 2), TextInput.prev(text, 4));
    try testing.expectEqual(@as(usize, 4), TextInput.next(text, 2));
    // A cursor left between the two is on the first row's end.
    try testing.expectEqual(TextInput.Place{ .row = 0, .col = 2 }, TextInput.place(text, 10, .unicode, 3));
}

/// Pieces of typed and pasted text: words, spaces, newlines both ways, wide
/// and combined clusters, and bytes that are not UTF-8 at all.
const pieces = [_][]const u8{
    "a",    "word",     " ",        "  ",                         "\n",
    "\r\n", "\u{4e2d}", "e\u{301}", "\u{1f469}\u{200d}\u{1f680}", "\u{1f1e6}\u{1f1e7}",
    "\t",   "\xff",     "\xe4\xb8", "\u{26a0}\u{fe0f}",           "x.y/z",
};

/// What the layout property drew over the corpus, for the test that proves
/// it explores.
const Tally = struct {
    /// Which piece each part of the text was.
    pieces: corpus.Spread = .{},
    /// How long the text was, in pieces.
    parts: corpus.Spread = .{},
    /// How wide the window was.
    cols: corpus.Spread = .{},
    /// Which way it measured, cluster (1) or codepoint (0).
    method: corpus.Spread = .{},
};

fn layoutHolds(gpa: std.mem.Allocator, smith: *std.testing.Smith, tally: ?*Tally) !void {
    var dice: corpus.Dice = .init(smith);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const parts = dice.valueRangeAtMost(u8, 0, 60);
    var part: u8 = 0;
    while (part < parts and text.items.len < 200) : (part += 1) {
        const which = dice.index(pieces.len);
        if (tally) |tl| tl.pieces.add(which);
        try text.appendSlice(gpa, pieces[which]);
    }
    const t = text.items;
    const cols = dice.valueRangeAtMost(u16, 1, 12);
    const method: visor.Method = if (dice.value(bool)) .unicode else .wcwidth;
    if (tally) |tl| {
        tl.parts.add(part);
        tl.cols.add(cols);
        tl.method.add(@intFromBool(method == .unicode));
    }

    // The rows cover the text: every byte in exactly one, in order.
    var owned: usize = 0;
    var count: usize = 0;
    var it = TextInput.rows(t, cols, method);
    while (it.next()) |r| : (count += 1) {
        try testing.expectEqual(owned, r.from);
        try testing.expect(r.from <= r.to);
        // No row is wider than the width unless one cluster alone is: a row
        // over the width holds one cluster that takes columns, and any that
        // take none beside it.
        if (visor.width(t[r.from..r.to], method) > cols) {
            var g: visor.Graphemes = .init(t[r.from..r.to]);
            var wide: usize = 0;
            while (g.next()) |cluster| {
                if (visor.graphemeWidth(cluster, method) != 0) wide += 1;
            }
            try testing.expectEqual(@as(usize, 1), wide);
        }
        owned = it._at;
        if (!r.hard) try testing.expectEqual(r.to, it._at);
    }
    try testing.expect(it._done);
    try testing.expectEqual(t.len, owned);
    try testing.expectEqual(count, TextInput.rowCount(t, cols, method));

    // Every cluster boundary has a place, and the place leads back to it.
    var boundaries: visor.Graphemes = .init(t);
    var c: usize = 0;
    while (true) {
        const p = TextInput.place(t, cols, method, c);
        try testing.expect(p.row < count);
        const back = TextInput.at(t, cols, method, p.row, p.col);
        try testing.expect(back <= c);
        try testing.expectEqual(@as(u16, 0), visor.width(t[back..c], method));
        const n = TextInput.next(t, c);
        if (c < t.len) {
            try testing.expect(n > c);
            try testing.expectEqual(c, TextInput.prev(t, n));
        } else try testing.expectEqual(c, n);
        const found = boundaries.next() orelse break;
        c += found.len;
    }

    // Drawn into a small window with the cursor anywhere, the cursor shows
    // inside it.
    var h: Harness = try .init(gpa, cols, 3);
    defer h.deinit();
    var state: TextInput.State = .{ .first = dice.value(u8) };
    const cursor = dice.index(t.len + 1);
    try (TextInput{ .text = t, .cursor = cursor }).draw(h.window(), &state);
    try testing.expect(h.screen.cursor.visible);
    try testing.expect(h.screen.cursor.row < 3);
    try testing.expect(h.screen.cursor.col < cols);
    _ = try h.frame();
}

test "the layout covers every byte and every cluster has a place that leads back to it" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try layoutHolds(gpa, smith, null);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "the layout's corpus draws every piece, every width, both methods and long texts" {
    var t: Tally = .{};
    for (corpus.entries) |entry| {
        var smith: std.testing.Smith = .{ .in = entry };
        try layoutHolds(testing.allocator, &smith, &t);
    }
    try testing.expect(t.pieces.covers(0, pieces.len - 1));
    try testing.expect(t.cols.covers(1, 12));
    try testing.expect(t.method.covers(0, 1));
    try testing.expect(t.parts.least == 0 and t.parts.most >= 40);
}

test "input row iterator source and progress stay behind next" {
    inline for (.{ "text", "cols", "method", "at", "done" }) |field| {
        try testing.expect(!@hasField(TextInput.Rows, field));
    }
}

test "a word starts on a cluster, not inside one a space began" {
    // A combining mark on a space makes one cluster of the two; the word
    // after it starts after the whole cluster.
    const text = "x \u{301}y";
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(text, text.len));
}

const Edited = TextInput.Buffer;

fn typed(b: *Edited, text: []const u8) !void {
    var it: visor.Graphemes = .init(text);
    while (it.next()) |g| try b.insert(g);
}

test "a word forward ends after the word, past the spaces before it" {
    const text = "one  two\nthree";
    try testing.expectEqual(@as(usize, 3), TextInput.wordEnd(text, 0));
    try testing.expectEqual(@as(usize, 8), TextInput.wordEnd(text, 3));
    try testing.expectEqual(@as(usize, 14), TextInput.wordEnd(text, 8));
    try testing.expectEqual(text.len, TextInput.wordEnd(text, text.len));
    // Back across a line break to the word before it.
    try testing.expectEqual(@as(usize, 5), TextInput.wordStart(text, 9));
    try testing.expectEqual(@as(usize, 0), TextInput.wordStart("  \n ", 4));
    // A wide cluster and a family are words of one cluster each.
    const wide = "\u{4e2d} \u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}";
    try testing.expectEqual(@as(usize, 3), TextInput.wordEnd(wide, 0));
    try testing.expectEqual(@as(usize, 4), TextInput.wordStart(wide, wide.len));
}

test "typing, moving and deleting by the motions a program maps its keys to" {
    var b: Edited = .init(testing.allocator);
    defer b.deinit();
    try typed(&b, "hello wide \u{4e2d}\u{6587} world");
    try testing.expectEqualStrings("hello wide \u{4e2d}\u{6587} world", b.text());

    b.move(.word_left, false);
    try testing.expectEqual(@as(usize, 18), b.cursor());
    b.move(.left, false);
    b.move(.left, false);
    try testing.expectEqual(@as(usize, 14), b.cursor());
    try b.delete(.left);
    try testing.expectEqualStrings("hello wide \u{6587} world", b.text());
    try b.delete(.word_left);
    try testing.expectEqualStrings("hello \u{6587} world", b.text());
    b.move(.line_start, false);
    try b.delete(.word_right);
    try testing.expectEqualStrings(" \u{6587} world", b.text());
    b.move(.end, false);
    try b.delete(.line_start);
    try testing.expectEqualStrings("", b.text());
    // Deleting at an edge deletes nothing and is no edit.
    try b.delete(.left);
    try b.delete(.right);

    // A mark typed after a letter joins its cluster; a backspace takes both.
    try typed(&b, "e");
    try b.insert("\u{301}");
    try testing.expectEqual(@as(usize, 3), b.cursor());
    try b.delete(.left);
    try testing.expectEqualStrings("", b.text());
}

test "a selection is extended by moves, replaced by typing and deleted whole" {
    var b: Edited = try .initText(testing.allocator, "one two three");
    defer b.deinit();
    b.move(.start, false);
    b.move(.word_right, true);
    b.move(.word_right, true);
    try testing.expectEqualStrings("one two", b.selectedText());
    try testing.expectEqual(TextInput.Range{ .start = 0, .end = 7 }, b.selection().?);
    try b.insert("1");
    try testing.expectEqualStrings("1 three", b.text());
    try testing.expectEqual(@as(?TextInput.Range, null), b.selection());

    // Back over a selection's start, a step left lands on that start.
    b.move(.end, false);
    b.move(.word_left, true);
    try testing.expectEqualStrings("three", b.selectedText());
    b.move(.left, false);
    try testing.expectEqual(@as(usize, 2), b.cursor());
    try testing.expectEqual(@as(?TextInput.Range, null), b.selection());

    b.selectAll();
    try b.delete(.left);
    try testing.expectEqualStrings("", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("1 three", b.text());
    try testing.expectEqual(TextInput.Range{ .start = 0, .end = 7 }, b.selection().?);

    // A click inside a cluster lands at its start.
    try b.reset("e\u{301}x");
    b.moveTo(2, false);
    try testing.expectEqual(@as(usize, 0), b.cursor());
    b.moveTo(99, false);
    try testing.expectEqual(@as(usize, 4), b.cursor());
    b.selectNone();
    try testing.expect(!b.canUndo());
}

test "undo goes back a word of typing at a time, and redo forward again" {
    var b: Edited = .init(testing.allocator);
    defer b.deinit();
    try typed(&b, "fix the bay");
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("fix the ", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("fix ", b.text());
    try testing.expect(try b.redo());
    try testing.expectEqualStrings("fix the ", b.text());
    try testing.expectEqual(@as(usize, 8), b.cursor());

    // A run of backspaces is one edit, and so is a run of deletes forward.
    try typed(&b, "bay");
    b.seal();
    try b.delete(.left);
    try b.delete(.left);
    try b.delete(.left);
    try testing.expectEqualStrings("fix the ", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("fix the bay", b.text());
    b.move(.start, false);
    try b.delete(.right);
    try b.delete(.right);
    try testing.expectEqualStrings("x the bay", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("fix the bay", b.text());
    try testing.expectEqual(@as(usize, 0), b.cursor());

    // A new edit drops what was undone.
    try testing.expect(try b.undo());
    try testing.expect(b.canRedo());
    try b.insert("!");
    try testing.expect(!b.canRedo());
    try testing.expect(!(try b.redo()));

    // A paste is an edit of its own, and a motion ends the typing before it.
    try b.reset("");
    try typed(&b, "ab");
    b.move(.left, false);
    b.move(.right, false);
    try typed(&b, "cd");
    try b.insert("pasted\ntext");
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("abcd", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("ab", b.text());
    try testing.expect(try b.undo());
    try testing.expectEqualStrings("", b.text());
    try testing.expect(!(try b.undo()));
}

test "the history keeps the newest edits that fit its limit" {
    var b: Edited = .init(testing.allocator);
    defer b.deinit();
    b.history_limit = 8;
    try b.insert("aaaa");
    try b.insert("bbbb");
    try b.insert("cccc");
    try testing.expect(try b.undo());
    try testing.expect(try b.undo());
    try testing.expect(!(try b.undo()));
    try testing.expectEqualStrings("aaaa", b.text());
    // An edit larger than the limit is made and not kept.
    try b.insert("0123456789");
    try testing.expect(!b.canUndo());
    try testing.expectEqualStrings("aaaa0123456789", b.text());
}

test "up and down a row keep to the column the first move started at" {
    var b: Edited = try .initText(testing.allocator, "a long first line\nab\nthe third one");
    defer b.deinit();
    b.moveTo(7, false); // "a long |first", column 7
    b.moveRows(1, 40, .unicode, false);
    try testing.expectEqual(@as(usize, 20), b.cursor()); // end of "ab"
    b.moveRows(1, 40, .unicode, false);
    try testing.expectEqual(@as(usize, 28), b.cursor()); // "the thi|rd", column 7
    b.moveRows(5, 40, .unicode, false);
    try testing.expectEqual(@as(usize, 28), b.cursor());
    b.moveRows(-9, 40, .unicode, true);
    try testing.expectEqual(@as(usize, 7), b.cursor());
    try testing.expectEqualStrings("first line\nab\nthe thi", b.selectedText());
    // Wrapped rows count as rows: "a long " · "first " · "line".
    b.moveTo(0, false);
    b.moveRows(1, 7, .unicode, false);
    try testing.expectEqual(@as(usize, 7), b.cursor());
}

test "the input draws its selection in the selected style" {
    var b: Edited = try .initText(testing.allocator, "one two three");
    defer b.deinit();
    b.move(.word_left, false);
    b.move(.word_left, true);
    var h: Harness = try .init(testing.allocator, 8, 2);
    defer h.deinit();
    var state: TextInput.State = .{};
    try b.input().draw(h.window(), &state);
    try h.expectFrame(
        \\one two
        \\three
        \\
    );
    try testing.expect(!h.styleAt(3, 0).reverse);
    try testing.expect(h.styleAt(4, 0).reverse);
    try testing.expect(h.styleAt(6, 0).reverse);
    try testing.expect(h.styleAt(7, 0).reverse);
    try testing.expect(!h.styleAt(0, 1).reverse);
    try testing.expectEqual(@as(u16, 4), h.screen.cursor.col);
}

test "an edit that cannot allocate changes nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var b: Edited = try .initText(a, "one two");
            defer b.deinit();
            try typed(&b, " three");
            b.move(.word_left, true);
            try b.insert("3");
            try b.delete(.word_left);
            _ = try b.undo();
            _ = try b.undo();
            _ = try b.redo();
            try b.replaceAll("x");
        }
    }.run, .{});
}

test "a failed edit leaves the text, the cursor and the history as they were" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var b: Edited = try .initText(failing.allocator(), "abc");
    defer b.deinit();
    try b.insert("d");
    failing.fail_index = failing.alloc_index;
    const before = try testing.allocator.dupe(u8, b.text());
    defer testing.allocator.free(before);
    if (b.insert("a much longer insertion than any capacity held")) |_| {} else |_| {
        try testing.expectEqualStrings(before, b.text());
        try testing.expectEqual(@as(usize, 4), b.cursor());
        try testing.expect(try b.undo());
        try testing.expectEqualStrings("abc", b.text());
    }
}

/// Edits of every kind, at random, held to what undo and redo must give
/// back.
fn bufferHolds(gpa: std.mem.Allocator, smith: *std.testing.Smith) !void {
    var dice: corpus.Dice = .init(smith);
    var b: Edited = .init(gpa);
    defer b.deinit();
    // Every text the buffer held after an edit, in order.
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |t| gpa.free(t);
        seen.deinit(gpa);
    }
    try seen.append(gpa, try gpa.dupe(u8, ""));
    const motions = std.enums.values(Edited.Motion);
    for (0..dice.valueRangeAtMost(u8, 0, 60)) |_| {
        switch (dice.valueRangeAtMost(u8, 0, 5)) {
            0, 1 => try b.insert(pieces[dice.index(pieces.len)]),
            2 => try b.delete(motions[dice.index(motions.len)]),
            3 => b.move(motions[dice.index(motions.len)], dice.value(bool)),
            4 => b.moveRows(@as(isize, dice.valueRangeAtMost(u8, 0, 4)) - 2, dice.valueRangeAtMost(u16, 1, 12), .unicode, dice.value(bool)),
            else => b.seal(),
        }
        const t = b.text();
        try testing.expect(b.cursor() <= t.len);
        if (b.selection()) |sel| try testing.expect(sel.start < sel.end and sel.end <= t.len);
        if (!std.mem.eql(u8, seen.items[seen.items.len - 1], t)) try seen.append(gpa, try gpa.dupe(u8, t));
    }
    const final = try gpa.dupe(u8, b.text());
    defer gpa.free(final);

    // Each undo gives back a text the buffer held, further back each time,
    // and the last gives back the first.
    var index = seen.items.len - 1;
    while (try b.undo()) {
        // A selection replaced by the same bytes is an edit that changed
        // nothing, and undoing it changes nothing either.
        if (std.mem.eql(u8, seen.items[index], b.text())) continue;
        var found = index;
        while (found > 0 and !std.mem.eql(u8, seen.items[found - 1], b.text())) found -= 1;
        try testing.expect(found > 0);
        index = found - 1;
        try testing.expect(b.cursor() <= b.text().len);
    }
    try testing.expectEqualStrings("", b.text());
    while (try b.redo()) {}
    try testing.expectEqualStrings(final, b.text());
}

test "whatever is typed, moved and deleted, undo walks back and redo forward to the same text" {
    try std.testing.fuzz(testing.allocator, struct {
        fn one(gpa: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
            try bufferHolds(gpa, smith);
        }
    }.one, .{ .corpus = &corpus.entries });
}

test "from a cluster boundary, every motion lands on one" {
    const text = "e\u{301} \u{4e2d}x\r\n\u{1f469}\u{200d}\u{1f680}  word\n\t\u{1f1e6}\u{1f1e7}";
    var boundaries: [64]bool = @splat(false);
    var it: visor.Graphemes = .init(text);
    var at: usize = 0;
    while (it.next()) |g| : (at += g.len) boundaries[at] = true;
    boundaries[text.len] = true;
    var b: Edited = try .initText(testing.allocator, text);
    defer b.deinit();
    for (0..text.len + 1) |start| {
        if (!boundaries[start]) continue;
        for (std.enums.values(Edited.Motion)) |motion| {
            b.moveTo(start, false);
            b.move(motion, false);
            try testing.expect(boundaries[b.cursor()]);
        }
        b.moveTo(start, false);
        b.moveRows(1, 5, .unicode, false);
        try testing.expect(boundaries[b.cursor()]);
    }
}
