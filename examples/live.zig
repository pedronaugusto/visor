//! A caller-owned live loop: probe, drain input, resize once, paint, draw,
//! flush. `zig build live` runs it in a terminal; `--check` runs the same
//! frame path without one, so the ordinary examples step can check it.
const std = @import("std");
const visor = @import("visor");
const morse = visor.morse;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |arg| if (std.mem.eql(u8, arg, "--check")) return check(init.gpa);
    const io = init.io;
    var tty = try visor.Tty.open(io);
    defer tty.close(io);
    var session = try visor.Session.init(init.gpa, try tty.size(), .{ .graphics_id = try morse.QueryImageId.fromRaw(1) });
    defer session.deinit();
    // Register the way out before entry, including a partial entry.
    // glint-ignore: Z026 -- leaving is best effort at the end of the program; a failure has nowhere left to be reported
    defer tty.leave(io) catch {};
    try tty.enter(io, session.renderer(), session.capabilities(), .alt, .{ .paste = true });
    try tty.watchResize();
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = tty.writer(io, &output_buffer);
    const w = &output.interface;
    var parser_buffer: [4096]u8 = undefined;
    var read_buffer: [4096]u8 = undefined;
    var input = try visor.Input.init(&tty, .{
        .parser_buffer = &parser_buffer,
        .read_buffer = &read_buffer,
        .escape = .fromMilliseconds(20),
    });
    try session.probe().write(w);
    try w.flush();
    const wait = visor.ProbeWait.init(now(io), .fromMilliseconds(500), .fromMilliseconds(50));
    var count: usize = 0;
    while (wait.remaining(session.probe(), now(io))) |budget| {
        const event = (try input.nextWithin(io, .{ .duration = .{
            .raw = budget,
            .clock = .awake,
        } })) orelse continue;
        if (quit(event)) return;
        if (event == .key or event == .text) count += 1;
        _ = try session.handle(w, event, now(io));
        try w.flush();
    }
    input.setMousePixels(false);
    try session.renderer().setModes(w, .{
        .paste = true,
        .keyboard = if (session.capabilities().kitty_keyboard) .{ .disambiguate_escape_codes = true } else null,
    });
    while (true) {
        _ = try session.resize(w);
        try paint(&session, count);
        _ = try session.draw(w);
        try w.flush();
        var event = try input.next(io);
        while (true) {
            if (quit(event)) return;
            if (event == .key or event == .text) count += 1;
            _ = try session.handle(w, event, now(io));
            event = (try input.nextWithin(io, .{ .duration = .{
                .raw = .fromMilliseconds(0),
                .clock = .awake,
            } })) orelse break;
        }
    }
}

fn quit(event: morse.Event) bool {
    if (event != .key or event.key.kind == .release) return false;
    return event.key.matches(.{ .char = 'q' }, .{}) or event.key.matches(.escape, .{}) or
        event.key.matches(.{ .char = 'c' }, .{ .ctrl = true });
}

fn now(io: std.Io) std.Io.Timestamp {
    return .now(io, .awake);
}

fn paint(session: *visor.Session, count: usize) !void {
    const win = session.screen().window();
    win.clear();
    var line: [128]u8 = undefined;
    const text = try std.mem.print(&line, "Input events: {d}\nResize the terminal. q, Escape or Ctrl+C leaves.", .{count});
    _ = try win.printSegment(.{ .text = text }, .{});
}

fn check(gpa: std.mem.Allocator) !void {
    var session = try visor.Session.init(gpa, .{ .cells = .{ .cols = 60, .rows = 3 } }, .{ .graphics_id = try morse.QueryImageId.fromRaw(1) });
    defer session.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try session.handle(&out.writer, .{ .resize = .{ .cols = 50, .rows = 4 } }, .zero);
    _ = try session.resize(&out.writer);
    try paint(&session, 3);
    _ = try session.draw(&out.writer);
    if (session.screen().dimensions().cols != 50 or out.written().len == 0) return error.ExampleFailed;
    if (!quit(.{ .key = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } } })) return error.ExampleFailed;
}
