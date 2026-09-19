//! A file viewer, built on the widgets, with no terminal involved.
//!
//! The second example in this repository and the one that is not about the
//! package's own internals: a sidebar of files, the chosen one shown with a
//! scrollbar beside it, tabs across the top, a status line under it, and a
//! resize in the middle. It draws into a grid, renders the frame, reads it
//! back through the emulator the package ships, and prints it — so `zig
//! build examples` runs the whole thing on a machine with no terminal at
//! all, and CI does.
//!
//! A real viewer replaces three things and nothing else: `Tty` for the
//! descriptor and the size, `morse.KeyParser` for the keys, and a read of a
//! real file for `files` below. Everything between the state and the bytes
//! is what is here.

const std = @import("std");
const visor = @import("visor");
const widgets = @import("visor.widgets");

/// What the viewer is showing, which is the whole of what it remembers
/// between frames.
const Viewer = struct {
    /// The files it can show.
    files: []const File,
    /// Which tab is open.
    tab: usize = 0,
    /// Which file is chosen, and where the sidebar has scrolled to.
    list: widgets.List.State = .{ .selected = 0 },
    /// How many rows down the chosen file is scrolled.
    scroll: usize = 0,
    /// How many rows of it the last frame had room for.
    page: u16 = 1,
    /// How many rows the chosen file takes at the last frame's width.
    rows: usize = 0,

    const File = struct {
        name: []const u8,
        body: []const u8,
    };

    /// The file being shown.
    fn current(v: Viewer) File {
        return v.files[v.list.selected orelse 0];
    }

    /// One screenful down, never past the end.
    fn pageDown(v: *Viewer) void {
        v.scroll = @min(v.scroll + v.page, v.rows -| v.page);
    }

    /// One screenful up.
    fn pageUp(v: *Viewer) void {
        v.scroll -|= v.page;
    }

    /// A different file, from the top.
    fn choose(v: *Viewer, which: usize) void {
        v.list.select(which);
        v.scroll = 0;
    }

    /// One frame, into the window it was given.
    fn draw(v: *Viewer, win: visor.Window) !void {
        win.clear();

        // The frame's shape: a row of tabs, the body, a status line.
        const rows = (widgets.Layout.vertical(&.{
            .{ .fixed = 1 },
            .{ .fill = 1 },
            .{ .fixed = 1 },
        })).splitFixed(3, .fromSize(win.size()));

        try (widgets.Tabs{
            .titles = &.{ "files", "search", "help" },
            .selected = v.tab,
        }).draw(win.child(.{
            .col = rows[0].col,
            .row = rows[0].row,
            .cols = rows[0].cols,
            .rows = rows[0].rows,
        }));

        // The body: a sidebar of files, and the chosen one beside it.
        const body = win.child(.{
            .col = rows[1].col,
            .row = rows[1].row,
            .cols = rows[1].cols,
            .rows = rows[1].rows,
        });
        const columns = (widgets.Layout.horizontal(&.{
            .{ .max = 18 },
            .{ .fill = 1 },
        })).splitFixed(2, .fromSize(body.size()));

        try v.drawSidebar(body.child(.{
            .col = columns[0].col,
            .row = columns[0].row,
            .cols = columns[0].cols,
            .rows = columns[0].rows,
        }));
        try v.drawFile(body.child(.{
            .col = columns[1].col,
            .row = columns[1].row,
            .cols = columns[1].cols,
            .rows = columns[1].rows,
        }));

        try v.drawStatus(win.child(.{
            .col = rows[2].col,
            .row = rows[2].row,
            .cols = rows[2].cols,
            .rows = rows[2].rows,
        }));
    }

    /// The list of files, framed.
    fn drawSidebar(v: *Viewer, win: visor.Window) !void {
        const inside = try (widgets.Block{
            .borders = .all,
            .glyphs = .rounded,
            .border_style = .{ .dim = true },
            .title = .{ .text = " files ", .style = .{ .bold = true } },
        }).draw(win);

        var items: [8]widgets.Item = undefined;
        for (v.files, 0..) |f, i| items[i] = .{ .text = f.name };
        try (widgets.List{
            .items = items[0..v.files.len],
            .marker = "\u{25b8} ",
            .selected_style = .{ .fg = .ansi(.cyan), .bold = true },
            .highlight_row = false,
        }).draw(inside, &v.list);
    }

    /// The chosen file, with a scrollbar down its right-hand edge.
    fn drawFile(v: *Viewer, win: visor.Window) !void {
        const file = v.current();
        const inside = try (widgets.Block{
            .borders = .all,
            .glyphs = .rounded,
            .border_style = .{ .dim = true },
            .title = .{ .text = file.name, .where = .center },
        }).draw(win);
        if (inside.rect.isEmpty()) return;

        // A column for the bar, and the text in what is left.
        const text_window = inside.child(.{ .cols = inside.cols() -| 1 });
        const bar = inside.child(.{ .col = inside.cols() -| 1, .cols = 1 });

        const paragraph: widgets.Paragraph = .{
            .lines = &.{.{ .text = file.body }},
            .scroll = v.scroll,
        };
        v.rows = paragraph.rowCount(text_window.cols());
        v.page = text_window.rows();
        try paragraph.draw(text_window);

        try (widgets.Scrollbar{}).draw(bar, .{
            .content = v.rows,
            .viewport = v.page,
            .position = v.scroll,
        });
    }

    /// Where in the file the viewer is, and what the keys do.
    fn drawStatus(v: *Viewer, win: visor.Window) !void {
        const shown = @min(v.scroll + v.page, v.rows);
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} {d}/{d}", .{
            v.current().name,
            shown,
            v.rows,
        }) catch "";

        try (widgets.LineGauge{
            .ratio = if (v.rows == 0) 1 else @as(f64, @floatFromInt(shown)) /
                @as(f64, @floatFromInt(v.rows)),
            .label = label,
            .label_style = .{ .bold = true },
        }).draw(win);

        const keys = "  j/k  page  q  quit";
        const at = win.cols() -| visor.width(keys, .unicode);
        _ = try win.printSegment(
            .{ .text = keys, .style = .{ .dim = true } },
            .{ .col = at, .wrap = .none },
        );
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // The files. A viewer with a terminal reads these; one without shows
    // its own source, which is the nearest thing to a real file that runs
    // the same on every machine.
    var viewer: Viewer = .{ .files = &.{
        .{ .name = "viewer.zig", .body = @embedFile("viewer.zig") },
        .{ .name = "notes.txt", .body =
        \\A second file, to have something to choose.
        \\
        \\The sidebar's selection is a struct this
        \\program owns. The list widget reads it,
        \\moves its offset when the selection would
        \\be off screen, and forgets it again.
        \\
        \\Nothing here wraps: a file viewer shows
        \\the lines the file has.
        },
        .{ .name = "empty", .body = "" },
    } };

    // The terminal this program would have been given. A real one comes
    // from `Tty.size`, and a resize arrives as an event.
    var size: visor.Size = .{ .cols = 76, .rows = 16 };

    var screen: visor.Screen = try .init(gpa, size);
    defer screen.deinit(gpa);
    screen.method = .unicode;
    var renderer: visor.Renderer = try .init(gpa, size);
    defer renderer.deinit(gpa);

    const caps: visor.Caps = .{ .width_method = .unicode, .truecolor = true, .osc8 = true };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The terminal that reads the frames back, so the example proves what
    // reached the screen rather than what was drawn into the grid.
    var term: visor.Term = try .init(gpa, size);
    defer term.deinit();
    term.setMethod(caps.width_method);

    // The frame.
    try viewer.draw(screen.window());
    try show(gpa, &renderer, &screen, &term, caps, &out, "the first frame");

    // Two pages down, which is what a key would have done.
    viewer.pageDown();
    viewer.pageDown();
    try viewer.draw(screen.window());
    try show(gpa, &renderer, &screen, &term, caps, &out, "two pages down");

    // A different file, from the top.
    viewer.choose(1);
    try viewer.draw(screen.window());
    try show(gpa, &renderer, &screen, &term, caps, &out, "a different file");

    // And the terminal made smaller. Everything that has to be resized is
    // resized in one place, and the next frame is drawn from the same
    // state: the widgets have no memory of the old size to be wrong about.
    size = .{ .cols = 54, .rows = 12 };
    try screen.resize(gpa, size);
    try renderer.resize(gpa, size);
    try term.resize(size);
    renderer.repaint();
    try viewer.draw(screen.window());
    try show(gpa, &renderer, &screen, &term, caps, &out, "resized to 54x12");
}

/// One frame: drawn, read back through the emulator, and printed.
fn show(
    gpa: std.mem.Allocator,
    renderer: *visor.Renderer,
    screen: *visor.Screen,
    term: *visor.Term,
    caps: visor.Caps,
    out: *std.Io.Writer.Allocating,
    what: []const u8,
) !void {
    out.clearRetainingCapacity();
    const stats = try renderer.draw(&out.writer, screen, caps);
    try term.feed(out.written());
    try visor.expectScreensEqual(screen, term.screen());

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try visor.dumpScreen(term.screen(), &text.writer);
    std.debug.print("\n{s} — {d} bytes, {d} cells in {d} runs\n{s}", .{
        what,
        stats.bytes,
        stats.cells,
        stats.runs,
        text.written(),
    });
}
