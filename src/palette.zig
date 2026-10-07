//! What the terminal's colours look like, and colours mixed from them.
//!
//! A colour this package writes is a name the terminal resolves: the default
//! foreground, one of sixteen slots the user's theme fills, an entry of the
//! 256-colour palette, or an exact RGB. A program that wants a colour a
//! little way from the background — a faded line, a hover, a tint that
//! reads on a light theme and a dark one — has to know what those names look
//! like here. `Palette` holds what the terminal said when asked, and
//! `resolve` turns a colour into the RGB it is drawn in; `mix` is the step
//! between two of them.
//!
//! Nothing here asks on its own or waits: `ask` writes the questions, the
//! answers arrive on the input stream among the keys, and `update` folds each
//! one in. Until a slot is answered it is unknown, and `resolve` says so
//! rather than guessing a theme.

const std = @import("std");
const morse = @import("dependencies.zig").morse;

const Color = morse.Color;
const Writer = std.Io.Writer;

/// A colour as eight bits a channel.
pub const Rgb = morse.Rgb;

/// `t` of the way from `from` to `to`, rounded to the nearest step. `t` is
/// clamped to zero and one, so a fraction a caller computed past either end
/// is the end.
pub fn mix(from: Rgb, to: Rgb, t: f32) Rgb {
    const k = @min(@max(t, 0), 1);
    return .{
        .r = channel(from.r, to.r, k),
        .g = channel(from.g, to.g, k),
        .b = channel(from.b, to.b, k),
    };
}

fn channel(a: u8, b: u8, t: f32) u8 {
    const x: f32 = @floatFromInt(a);
    const y: f32 = @floatFromInt(b);
    return @intFromFloat(@round(x + (y - x) * t));
}

/// The terminal's colours, as it reported them.
pub const Palette = struct {
    /// The default foreground, from OSC 10, or null until it answered.
    fg: ?Rgb = null,
    /// The default background, from OSC 11.
    bg: ?Rgb = null,
    /// The sixteen slots, from OSC 4.
    entries: [16]?Rgb = @splat(null),

    /// Which way a colour is being read: `.default` is a different colour in
    /// front of the text and behind it.
    pub const Role = enum { fg, bg };

    /// Asks the terminal for its foreground, its background and its sixteen
    /// slots, in one write. The answers come back on the input stream, for
    /// `update`.
    pub fn ask(w: *Writer) Writer.Error!void {
        try morse.queryColor(w, .foreground);
        try morse.queryColor(w, .background);
        var i: u8 = 0;
        while (i < 16) : (i += 1) try morse.queryPaletteColor(w, i);
    }

    /// Folds one input event in: an answer about the foreground, the
    /// background or one of the sixteen slots. Returns whether anything
    /// changed; every other event is left alone.
    pub fn update(p: *Palette, event: morse.Event) bool {
        const reply = switch (event) {
            .reply => |r| r,
            else => return false,
        };
        switch (reply) {
            .color => |report| {
                const slot: *?Rgb = switch (report.target) {
                    .foreground => &p.fg,
                    .background => &p.bg,
                    .cursor => return false,
                };
                return set(slot, report.color.to8());
            },
            .palette => |report| {
                if (report.index >= 16) return false;
                return set(&p.entries[report.index], report.color.to8());
            },
            else => return false,
        }
    }

    fn set(slot: *?Rgb, to: Rgb) bool {
        if (slot.*) |was| if (std.meta.eql(was, to)) return false;
        slot.* = to;
        return true;
    }

    /// What `color` looks like on this terminal, read as `role`, or null
    /// while the slot it names has not been answered.
    ///
    /// Above the sixteen slots the 256-colour palette is the one every
    /// terminal ships — a six-level cube and a grey ramp — which a program
    /// could redefine and almost none does.
    pub fn resolve(p: *const Palette, color: Color, role: Role) ?Rgb {
        return switch (color.kind) {
            .default => switch (role) {
                .fg => p.fg,
                .bg => p.bg,
            },
            .ansi => p.entries[@backingInt(color.toAnsi())],
            .palette => morse.paletteRgb(color.index()) orelse p.entries[color.index()],
            .rgb => color.toRgb(),
        };
    }

    /// The sixteen slots for `Caps.slot_colors`, which a colour is matched
    /// against on a 16-colour terminal: each as the terminal answered, and
    /// xterm's for any it has not. Null until it has answered one.
    pub fn slots(p: *const Palette) ?morse.Color.Slots {
        var out = morse.Color.xterm_slots;
        var any = false;
        for (p.entries, &out) |entry, *slot| if (entry) |rgb| {
            slot.* = rgb;
            any = true;
        };
        return if (any) out else null;
    }

    /// Whether the terminal has said what its foreground and background are,
    /// which is what a colour mixed toward either needs.
    pub fn known(p: *const Palette) bool {
        return p.fg != null and p.bg != null;
    }
};

const testing = std.testing;

test "a mix is the step between two colours, rounded and clamped" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectEqual(black, mix(black, white, 0));
    try testing.expectEqual(white, mix(black, white, 1));
    try testing.expectEqual(Rgb{ .r = 128, .g = 128, .b = 128 }, mix(black, white, 0.5));
    try testing.expectEqual(white, mix(black, white, 7));
    try testing.expectEqual(black, mix(black, white, -1));
    // The arithmetic a program tints with: 44 per cent of the way from the
    // background to the foreground.
    const bg: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
    const fg: Rgb = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 };
    try testing.expectEqual(Rgb{ .r = 0x6b, .g = 0x6f, .b = 0x85 }, mix(bg, fg, 0.44));
}

test "the terminal's answers fold in, and a colour resolves to what it looks like" {
    var p: Palette = .{};
    try testing.expect(!p.known());
    try testing.expectEqual(@as(?Rgb, null), p.resolve(.default, .fg));

    try testing.expect(p.update(answer("\x1b]10;rgb:cdcd/d6d6/f4f4\x1b\\")));
    try testing.expect(p.update(answer("\x1b]11;rgb:1e1e/1e1e/2e2e\x07")));
    try testing.expect(p.update(answer("\x1b]4;1;rgb:f3/8b/a8\x1b\\")));
    try testing.expect(!p.update(answer("\x1b]4;1;rgb:f3/8b/a8\x1b\\")));
    try testing.expect(!p.update(answer("\x1b[?62c")));
    try testing.expect(!p.update(.{ .key = .{ .key = .escape } }));
    try testing.expect(p.known());

    try testing.expectEqual(Rgb{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }, p.resolve(.default, .fg).?);
    try testing.expectEqual(Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, p.resolve(.default, .bg).?);
    try testing.expectEqual(Rgb{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, p.resolve(.ansi(.red), .fg).?);
    try testing.expectEqual(Rgb{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, p.resolve(.palette(1), .fg).?);
    try testing.expectEqual(@as(?Rgb, null), p.resolve(.ansi(.green), .fg));
    try testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, p.resolve(.rgb(1, 2, 3), .bg).?);
}

test "above the sixteen slots the palette is the cube and the ramp" {
    const p: Palette = .{};
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, p.resolve(.palette(16), .fg).?);
    try testing.expectEqual(Rgb{ .r = 255, .g = 135, .b = 0 }, p.resolve(.palette(208), .fg).?);
    try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, p.resolve(.palette(231), .fg).?);
    try testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, p.resolve(.palette(232), .fg).?);
    try testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, p.resolve(.palette(255), .fg).?);
}

test "the slots are the terminal's where it answered and xterm's where it did not" {
    var p: Palette = .{};
    try testing.expectEqual(@as(?morse.Color.Slots, null), p.slots());
    try testing.expect(p.update(answer("\x1b]4;1;rgb:f3/8b/a8\x1b\\")));
    const slots = p.slots().?;
    try testing.expectEqual(Rgb{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, slots[1]);
    try testing.expectEqual(morse.Color.xterm_slots[0], slots[0]);
    try testing.expectEqual(morse.Color.xterm_slots[15], slots[15]);
}

test "asking is one write of eighteen questions" {
    var buffer: [512]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try Palette.ask(&out);
    const asked = out.buffered();
    try testing.expect(std.mem.startsWith(u8, asked, "\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]4;0;?\x1b\\"));
    try testing.expect(std.mem.endsWith(u8, asked, "\x1b]4;15;?\x1b\\"));
    try testing.expectEqual(@as(usize, 18), std.mem.count(u8, asked, "?\x1b\\"));
}

/// A reply as the input reads it.
fn answer(bytes: []const u8) morse.Event {
    return .{ .reply = morse.Reply.parse(bytes).? };
}
