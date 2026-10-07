//! What this terminal can do.
//!
//! Every field defaults to the answer that is safe on the oldest terminal, so
//! a `Caps{}` renders correctly everywhere and cheaply nowhere. Filling it in
//! is the caller's: `Probe` writes the questions, the caller reads the
//! answers on its own clock with its own timeout, and hands each one back.
//!
//! No environment variable is read here, ever — not `TERM`, not `COLORTERM`,
//! not `TERM_PROGRAM`. Every one of those is a guess about a terminal that
//! could have been asked. A caller that would rather guess sets the field
//! itself, or reads `COLORTERM` and `NO_COLOR` and hands them to
//! `guessColor`; this file will not do it behind them.
//!
//! What this file will never hold: a terminfo reader, a capability database,
//! a table of terminal names, or a timeout. One name is read, and it is a
//! protocol's: a terminal that calls itself iTerm2 draws iTerm2's inline
//! images, which no question asks about.

const std = @import("std");
const morse = @import("dependencies.zig").morse;
const textmod = @import("text.zig");

/// What this terminal can do. Every field is safe at its default.
pub const Caps = struct {
    /// How the terminal measures text. `wcwidth` until it says otherwise,
    /// and the one value both the measuring code and the drift rule read.
    width_method: textmod.Method = .wcwidth,
    /// Whether the terminal takes `38;2;r;g;b`. Without it the renderer
    /// writes each direct colour as the nearest one the terminal has, which
    /// is a better approximation than most terminals make of their own.
    truecolor: bool = false,
    /// How many colours the terminal says it has, its `Co` capability, or
    /// null until it says. 256 is the palette and not direct colour; 8 and
    /// 16 are the theme slots.
    colors: ?u32 = null,
    /// Whether the user asked for no colour at all. Nothing here reads
    /// `NO_COLOR`; a caller that honours it sets this, or has `guessColor`
    /// set it.
    no_color: bool = false,
    /// The colours to draw in, chosen by the caller, over whatever
    /// `colorProfile` would have worked out from the fields above.
    color_profile: ?morse.Color.Profile = null,
    /// What the terminal's sixteen theme slots look like, which is what a
    /// colour is matched against on a 16-colour terminal; xterm's when null.
    /// `Palette.slots` gives them from the terminal's answers. Borrowed, so
    /// a `Caps` stays small enough to hand down by value: the caller keeps
    /// them alive, and a frame drawn after they change redraws what they
    /// change.
    slot_colors: ?*const morse.Color.Slots = null,
    /// Whether the terminal needs the semicolon spelling of the underline
    /// sub-parameters rather than the colon one.
    legacy_sgr: bool = false,
    /// Synchronised output, mode 2026: the terminal holds the screen still
    /// until the frame is finished.
    sync: bool = false,
    /// Whether the terminal would rather not be given mode 2026 at all.
    ///
    /// At least one terminal implements the mode and asks programs not to
    /// use it, on the grounds that the long frames it exists for are exactly
    /// the ones it handles worst. There is no way to ask; a caller that
    /// knows which terminal it is talking to sets this.
    sync_unwanted: bool = false,
    /// OSC 8 hyperlinks.
    osc8: bool = false,
    /// In-band resize reports, mode 2048.
    in_band_resize: bool = false,
    /// The text sizing protocol's explicit width, so a cluster's width is
    /// told to the terminal rather than agreed with it.
    ///
    /// Under `.wcwidth` the renderer states the width of every cluster the
    /// two models disagree about, and a row holding one is diffed like any
    /// other rather than repainted whole; under `.explicit` it states the
    /// width of everything but ASCII, and the terminal's own tables stop
    /// mattering at all. Under `.unicode` nothing is stated, because the
    /// terminal already agrees.
    explicit_width: bool = false,
    /// Text drawn at more than one cell's size, through the same protocol.
    /// A grapheme the screen holds at a scale goes out as one sequence and
    /// its block is never written; without this, it is drawn at its own
    /// size and the rest of the block blank.
    scaled_text: bool = false,
    /// The kitty keyboard protocol.
    kitty_keyboard: bool = false,
    /// The kitty graphics protocol.
    kitty_graphics: bool = false,
    /// Sixel graphics: the device attributes claim attribute 4.
    sixel: bool = false,
    /// How many colour registers a sixel image may use, as the terminal
    /// answered XTSMGRAPHICS. 256 until it says otherwise, which is what a
    /// terminal drawing sixels has today; a VT340's 16 is said when asked.
    sixel_registers: u16 = 256,
    /// The widest sixel image the terminal draws, in pixels, as it answered
    /// XTSMGRAPHICS; zero when it did not say.
    sixel_max_width: u32 = 0,
    /// The tallest, the same way.
    sixel_max_height: u32 = 0,
    /// iTerm2's inline images, `OSC 1337 ; File`. This probe uses XTVERSION
    /// and sets this only for a terminal
    /// that calls itself iTerm2 (XTVERSION); a caller that knows another
    /// terminal draws them -- WezTerm, mintty, Konsole -- sets it itself.
    iterm_images: bool = false,
    /// The picture protocol frames use, chosen by the caller; null leaves
    /// the choice to `pictures`.
    picture_protocol: ?Pictures = null,
    /// Mouse reports in pixels, mode 1016.
    sgr_pixels: bool = false,

    //=====================================================================
    // What the render pass may use. Each of these changes which bytes a
    // frame is made of, and none of them may be guessed.
    //=====================================================================

    /// Back colour erase: an erase fills with the background colour in
    /// effect rather than with the terminal's default. The renderer only
    /// erases in the default style, so this decides nothing today and is
    /// here because an erase in a coloured style is the next thing to want.
    bce: bool = false,
    /// `ECH`, erase character.
    ech: bool = true,
    /// `REP`, repeat the last graphic character.
    rep: bool = false,
    /// `SU` and `SD`, scroll the region up and down.
    su: bool = false,
    /// `IL` and `DL`, insert and delete lines.
    il: bool = false,
    /// `HPA`, absolute column positioning.
    hpa: bool = true,
    /// `DECSTBM`, a scrolling region narrower than the screen.
    decstbm: bool = false,
    /// Whether to look for a frame whose rows moved and write it as a
    /// scroll rather than as a repaint.
    ///
    /// Off by default and deliberately: hashing both frames costs a fifth of
    /// a full repaint's emit on every frame, and pays only on the frames
    /// where rows really moved. A caller whose program scrolls — a log, a
    /// pager, an editor — turns it on; one that draws a dashboard does not.
    /// It also needs `decstbm` and `su` unless the region is the whole
    /// screen.
    scroll_detection: bool = false,
    /// Mode 8452: after a sixel, the cursor is left to the right of the
    /// graphic rather than below it, so a picture can reach the bottom row
    /// without the screen scrolling under it. `enter` turns it on when
    /// frames draw sixels; without it a sixel picture stops a row short of
    /// the bottom.
    sixel_cursor_right: bool = false,

    /// How a picture reaches the screen.
    pub const Pictures = enum {
        /// As cells: sextants, half blocks, braille. No picture protocol.
        cells,
        /// Sixel: the pixels in the escape code, drawn into the cells under
        /// them, sent again whenever they are drawn again.
        sixel,
        /// iTerm2's inline images: a PNG file, scaled by the terminal to the
        /// cells it is drawn in, sent again whenever it is drawn again.
        iterm,
        /// The kitty protocol: pixels the terminal keeps under an id, placed
        /// above or below the text.
        kitty,
    };

    /// The picture protocol a frame uses: `picture_protocol` when the
    /// caller chose one, else the best the terminal has -- kitty, then
    /// iTerm2, then sixel, then cells.
    ///
    /// Kitty first because the terminal keeps the pixels and a picture
    /// that moves or is covered costs a command, not the picture again;
    /// iTerm2 before sixel because it is a file in full colour scaled by the
    /// terminal, where a sixel is at most 256 colours scaled here.
    pub fn pictures(c: Caps) Pictures {
        if (c.picture_protocol) |chosen| return chosen;
        if (c.kitty_graphics) return .kitty;
        if (c.iterm_images) return .iterm;
        if (c.sixel) return .sixel;
        return .cells;
    }

    /// Apply a caller-supplied TERM_PROGRAM value; no environment is read.
    pub fn termProgram(c: *Caps, name: []const u8) void {
        if (std.mem.eql(u8, name, "iTerm.app")) c.iterm_images = true;
    }

    /// The colours the renderer draws in: `color_profile` when the caller
    /// chose, no colour under `no_color`, direct colour with `truecolor`, and
    /// otherwise what `colors` says -- the palette from 256, the sixteen slots
    /// from 8. With none of them known, the 256-colour palette: every
    /// terminal in use for a decade has it, while direct colour needs
    /// evidence -- `Tc` or `RGB`, a `Co` of 2^24, or `COLORTERM` through
    /// `guessColor`.
    ///
    /// Every colour of every cell is fitted to this before it is compared
    /// with the last frame or written (`morse.Color.fit`), so two colours a
    /// terminal shows the same are no difference worth a byte. A colour
    /// already in the form the profile shows is left as it is, which is how
    /// a theme gives its own colours for a poorer terminal: pick them by
    /// this profile.
    pub fn colorProfile(c: Caps) morse.Color.Profile {
        if (c.color_profile) |profile| return profile;
        if (c.no_color) return .none;
        if (c.truecolor) return .rgb;
        const n = c.colors orelse return .palette;
        if (n >= 1 << 24) return .rgb;
        if (n >= 256) return .palette;
        if (n >= 8) return .ansi;
        return .none;
    }

    /// Folds in the two environment variables colour is conventionally
    /// given by, read by the caller: `COLORTERM` of `truecolor` or `24bit`
    /// says direct colour, and a `NO_COLOR` that is set and not empty asks
    /// for none (no-color.org). Pass null for a variable that is not set.
    /// Learns only what they say and unlearns nothing.
    pub fn guessColor(c: *Caps, colorterm: ?[]const u8, no_color: ?[]const u8) void {
        if (colorterm) |v| {
            if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) c.truecolor = true;
        }
        if (no_color) |v| {
            if (v.len > 0) c.no_color = true;
        }
    }

    /// What the terminal can do, asked: `morse.Probe`'s questions, and its
    /// answers folded into a `Caps`.
    ///
    /// The questions are morse's, in morse's order, slow and forwarded ones
    /// first and the primary device attributes last. That answer proves the
    /// input path works and is not the end of the answers: a multiplexer can
    /// give it at once while a question it forwarded is still on its way. So
    /// the probe is settled when every question it asked has been answered,
    /// or when the device attributes have come and the terminal has then
    /// been quiet for the caller's quiet period, on the caller's clock.
    /// Silence to a single question is the answer "no", which is why they
    /// are asked together and why nothing here waits.
    ///
    /// The same write asks the colours and sizes a program folds into
    /// `Palette` and `Winsize`; hand every event to all three.
    pub const Probe = struct {
        /// Private: the questions, morse's. `questions.graphics_id` has no default:
        /// the program chooses an id it never sends a picture under, because
        /// the graphics answer is told from an answer about a picture by
        /// this id alone.
        own_questions: morse.Probe,
        /// Private: what the answers have said so far.
        caps: Caps = .{},
        /// Private: which questions have been answered.
        answered: std.EnumSet(morse.Probe.Question) = .empty,
        /// Private: when the last answer came, on the caller's clock; null
        /// before the first.
        last_answer: ?std.Io.Timestamp = null,

        /// A fresh probe for these questions. Feed is the only answer writer.
        pub fn init(asked: morse.Probe) Caps.Probe {
            return .{ .own_questions = asked };
        }

        /// Requested questions, by value.
        pub fn questions(p: *const Probe) morse.Probe {
            return p.own_questions;
        }

        /// Learned capabilities, by value; application overrides belong outside the probe.
        pub fn capabilities(p: *const Probe) Caps {
            return p.caps;
        }

        /// Whether an answer to this requested question has arrived.
        pub fn hasAnswered(p: *const Probe, question: morse.Probe.Question) bool {
            return p.answered.contains(question);
        }

        /// Last answer on the caller's clock, or null before the first.
        pub fn lastAnswer(p: *const Probe) ?std.Io.Timestamp {
            return p.last_answer;
        }

        /// Asks every question, in one write.
        pub fn write(p: *const Probe, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try p.own_questions.write(w);
        }

        /// Folds one event from the input in: the answers to the questions,
        /// read. Anything else is ignored, because a terminal answering a
        /// question nobody asked is not this package's problem to diagnose.
        pub fn feed(p: *Probe, event: morse.Event, now: std.Io.Timestamp) void {
            const question = morse.probeAnswered(event) orelse return;
            if (!p.own_questions.asks(question)) return;
            // A graphics answer about one of the program's pictures answers
            // nothing here.
            if (question == .graphics and event.reply.graphics.id != p.own_questions.graphics_id) return;
            p.answered.insert(question);
            p.last_answer = now;
            const reply = switch (event) {
                .reply => |r| r,
                else => return,
            };
            switch (reply) {
                .mode => |m| {
                    // The question is whether the terminal has the mode, and
                    // DECRQM answers whether it is on. Set, reset and
                    // permanently set are a terminal that has it -- one asked
                    // before anything turned it on answers reset -- and not
                    // recognised and permanently reset are one that does not.
                    const has = switch (m.state) {
                        .set, .reset, .permanently_set => true,
                        .not_recognized, .permanently_reset => false,
                    };
                    // Synchronised output is a bracket written around a frame,
                    // in-band resize reports are turned on by `enter`, and
                    // pixel mouse reports by whoever asks for the mouse:
                    // none is on when asked about.
                    if (m.mode == morse.syncOutput.number) p.caps.sync = has;
                    if (m.mode == morse.inBandResize.number) p.caps.in_band_resize = has;
                    if (m.mode == morse.Mouse.Encoding.sgr_pixels.number()) p.caps.sgr_pixels = has;
                    // A terminal that measures clusters whatever anyone asks
                    // answers permanently set; one that can be asked will be,
                    // by `enter`.
                    if (m.mode == morse.unicodeCore.number) p.caps.width_method = if (has) .unicode else .wcwidth;
                    if (m.mode == morse.sixelCursorRight.number) p.caps.sixel_cursor_right = has;
                },
                .device_attributes => |da| p.caps.sixel = da.has(4),
                .version => |name| p.caps.iterm_images = std.mem.startsWith(u8, name, "iTerm2 ") or std.mem.eql(u8, name, "iTerm2"),
                .sixel_graphics => |g| if (g.ok()) switch (g.item) {
                    // At least two, or there is no picture to draw; and no
                    // more than one image can define.
                    .color_registers => p.caps.sixel_registers = @intCast(std.math.clamp(g.value, 2, morse.sixel_palette_max)),
                    .geometry => {
                        p.caps.sixel_max_width = g.value;
                        p.caps.sixel_max_height = g.height;
                    },
                },
                .kitty_keyboard => p.caps.kitty_keyboard = true,
                .capability => |c| {
                    var it = c.iterator();
                    while (it.next()) |capability| {
                        var name: [8]u8 = undefined;
                        const n = capability.decodeName(&name) catch continue;
                        if (c.known and
                            (std.mem.eql(u8, n, "Tc") or std.mem.eql(u8, n, "RGB")))
                        {
                            p.caps.truecolor = true;
                        }
                        if (c.known and p.own_questions.color_count and std.mem.eql(u8, n, "Co")) {
                            var value: [10]u8 = undefined;
                            const v = capability.decodeValue(&value) catch continue;
                            p.caps.colors = std.fmt.parseInt(u32, v, 10) catch continue;
                        }
                    }
                },
                // Any answer to the question, `OK` or an error, is a
                // terminal that speaks the protocol; an answer about some
                // other image is not an answer to it.
                .graphics => p.caps.kitty_graphics = true,
                else => {},
            }
        }

        /// Whether every question asked has been answered, after which no
        /// answer is owed.
        pub fn complete(p: *const Probe) bool {
            for (std.enums.values(morse.Probe.Question)) |q| {
                if (p.own_questions.asks(q) and !p.answered.contains(q)) return false;
            }
            return true;
        }

        /// Whether to stop waiting: every question answered, or the device
        /// attributes answered and nothing more for `quiet` since the last
        /// answer, on the caller's clock. The caller's overall timeout still
        /// ends a probe the terminal never answers at all.
        pub fn settled(p: *const Probe, now: std.Io.Timestamp, quiet: std.Io.Duration) bool {
            if (p.complete()) return true;
            if (!p.answered.contains(.device_attributes)) return false;
            const last = p.last_answer orelse now;
            return now.nanoseconds -| last.nanoseconds >= quiet.nanoseconds;
        }
    };
};

const testing = std.testing;

test "the defaults are what is safe on the oldest terminal" {
    const c: Caps = .{};
    try testing.expectEqual(textmod.Method.wcwidth, c.width_method);
    inline for (.{
        c.truecolor,      c.no_color,       c.legacy_sgr,     c.sync,
        c.osc8,           c.kitty_keyboard, c.kitty_graphics, c.sgr_pixels,
        c.in_band_resize, c.explicit_width, c.scaled_text,
    }) |flag| try testing.expect(!flag);
}

test "the probe asks morse's questions, in morse's order, and nothing of its own" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const p: Caps.Probe = .init(.{ .graphics_id = 1 });
    try p.write(&out);
    var theirs_buf: [512]u8 = undefined;
    var theirs: std.Io.Writer = .fixed(&theirs_buf);
    try (morse.Probe{ .graphics_id = 1 }).write(&theirs);
    try testing.expectEqualStrings(theirs.buffered(), out.buffered());
    // Among them the ones a `Caps` is made of, and the one always answered
    // last.
    const asked = out.buffered();
    for ([_][]const u8{ "\x1b[?2026$p", "\x1b[?2027$p", "\x1b[?2048$p", "\x1b[?1016$p", "\x1bP+q5463\x1b\\", "\x1bP+q524742\x1b\\", "\x1bP+q436f\x1b\\", "\x1b_Ga=q,i=1," }) |q| {
        try testing.expect(std.mem.find(u8, asked, q) != null);
    }
    try testing.expect(std.mem.endsWith(u8, asked, "\x1b[c"));
}

test "a mode the terminal answers set or reset is one it has, and not recognised is one it lacks" {
    // What a terminal with each of them says before anything turned them
    // on: reset. That is a yes.
    for ([_][]const u8{ "1", "2", "3" }) |state| {
        var p: Caps.Probe = .init(.{ .graphics_id = 1 });
        var buf: [4][32]u8 = undefined;
        p.feed(answer(try std.mem.print(&buf[0], "\x1b[?2026;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[1], "\x1b[?2027;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[2], "\x1b[?2048;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[3], "\x1b[?1016;{s}$y", .{state})), ms(0));
        try testing.expect(p.caps.sync);
        try testing.expectEqual(textmod.Method.unicode, p.caps.width_method);
        try testing.expect(p.caps.in_band_resize);
        try testing.expect(p.caps.sgr_pixels);
    }
    for ([_][]const u8{ "0", "4" }) |state| {
        var p: Caps.Probe = .init(.{ .graphics_id = 1 });
        p.caps = .{ .sync = true, .width_method = .unicode, .in_band_resize = true, .sgr_pixels = true };
        var buf: [4][32]u8 = undefined;
        p.feed(answer(try std.mem.print(&buf[0], "\x1b[?2026;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[1], "\x1b[?2027;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[2], "\x1b[?2048;{s}$y", .{state})), ms(0));
        p.feed(answer(try std.mem.print(&buf[3], "\x1b[?1016;{s}$y", .{state})), ms(0));
        try testing.expect(!p.caps.sync);
        try testing.expectEqual(textmod.Method.wcwidth, p.caps.width_method);
        try testing.expect(!p.caps.in_band_resize);
        try testing.expect(!p.caps.sgr_pixels);
    }
}

test "the device attributes answer does not settle the probe while a forwarded answer may still come" {
    // A multiplexer answers the device attributes itself while a question it
    // forwarded is still on its way: the probe waits for the caller's quiet
    // period after the last answer, on the caller's clock.
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1b[?2026;1$y"), ms(100));
    try testing.expect(!p.settled(ms(100), .fromMilliseconds(50)));
    p.feed(answer("\x1b[?62;4;22c"), ms(110));
    try testing.expect(!p.settled(ms(120), .fromMilliseconds(50)));
    // The forwarded answer lands, and the quiet period starts again.
    p.feed(answer("\x1b]11;rgb:1e1e/1e1e/2e2e\x07"), ms(150));
    try testing.expect(!p.settled(ms(180), .fromMilliseconds(50)));
    try testing.expect(p.settled(ms(200), .fromMilliseconds(50)));
    // Without the device attributes no quiet period settles it: silence
    // there is a terminal that has not answered yet, for the caller's own
    // timeout to end.
    var q: Caps.Probe = .init(.{ .graphics_id = 1 });
    q.feed(answer("\x1b[?2026;1$y"), ms(0));
    try testing.expect(!q.settled(ms(10_000), .fromMilliseconds(50)));
}

test "a probe answered in full is settled at once" {
    var p: Caps.Probe = .init(.{
        .graphics_id = 1,
        .cursor_position = false,
        .foreground_color = false,
        .background_color = false,
        .cursor_color = false,
        .color_scheme = false,
        .unicode_core = false,
        .in_band_resize = false,
        .mouse_pixels = false,
        .kitty_keyboard = false,
        .modify_other_keys = false,
        .graphics = false,
        .extra_cursors = false,
        .truecolor = false,
        .color_count = false,
        .version = false,
        .text_area_cells = false,
        .cell_pixels = false,
        .secondary_device_attributes = false,
        .sixel_cursor_right = false,
        .sixel_registers = false,
        .sixel_geometry = false,
    });
    p.feed(answer("\x1b[?62;4;22c"), ms(5));
    try testing.expect(!p.complete());
    p.feed(answer("\x1b[?2026;2$y"), ms(6));
    try testing.expect(p.complete() and p.settled(ms(6), .fromMilliseconds(1000)));
    try testing.expect(p.caps.sync);
}

test "an unrecognised reply changes nothing" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    const before = p.caps;
    p.feed(answer("nonsense"), ms(0));
    p.feed(answer("\x1b["), ms(0));
    p.feed(answer(""), ms(0));
    try testing.expectEqual(before, p.caps);
    try testing.expect(!p.settled(ms(1000), .fromMilliseconds(0)));
}

test "a 256-colour count is not evidence of truecolor" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    // XTGETTCAP reply: "Co" = "256", both halves in hex.
    p.feed(answer("\x1bP1+r436f=323536\x1b\\"), ms(0));
    try testing.expect(!p.caps.truecolor);
}

test "a colour count is folded in, and picks the profile" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1bP1+r436f=323536\x1b\\"), ms(0));
    try testing.expect(p.hasAnswered(.color_count));
    try testing.expectEqual(@as(?std.Io.Timestamp, ms(0)), p.lastAnswer());
    try testing.expectEqual(@as(?u32, 256), p.caps.colors);
    try testing.expectEqual(morse.Color.Profile.palette, p.caps.colorProfile());
}

test "the colour profile, from what is known" {
    const Profile = morse.Color.Profile;
    try testing.expectEqual(Profile.palette, (Caps{}).colorProfile());
    try testing.expectEqual(Profile.rgb, (Caps{ .truecolor = true }).colorProfile());
    try testing.expectEqual(Profile.rgb, (Caps{ .colors = 1 << 24 }).colorProfile());
    try testing.expectEqual(Profile.palette, (Caps{ .colors = 256 }).colorProfile());
    try testing.expectEqual(Profile.ansi, (Caps{ .colors = 88 }).colorProfile());
    try testing.expectEqual(Profile.ansi, (Caps{ .colors = 8 }).colorProfile());
    try testing.expectEqual(Profile.none, (Caps{ .colors = 2 }).colorProfile());
    try testing.expectEqual(Profile.none, (Caps{ .truecolor = true, .no_color = true }).colorProfile());
    // The caller's choice is the answer, whatever else is known.
    try testing.expectEqual(Profile.palette, (Caps{ .truecolor = true, .color_profile = .palette }).colorProfile());
    try testing.expectEqual(Profile.rgb, (Caps{ .no_color = true, .color_profile = .rgb }).colorProfile());
}

test "COLORTERM and NO_COLOR say what they say and no more" {
    var c: Caps = .{};
    c.guessColor(null, null);
    try testing.expectEqual(Caps{}, c);
    c.guessColor("256color", "");
    try testing.expectEqual(Caps{}, c);
    c.guessColor("truecolor", null);
    try testing.expect(c.truecolor and !c.no_color);
    c = .{};
    c.guessColor("24bit", "1");
    try testing.expect(c.truecolor and c.no_color);
    try testing.expectEqual(morse.Color.Profile.none, c.colorProfile());
}

test "a truecolor-specific capability enables truecolor" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1bP1+r5463\x1b\\"), ms(0));
    try testing.expect(p.caps.truecolor);
}

test "the graphics answer is the one carrying the id the program chose" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    // An answer about a picture is not an answer to the question.
    p.feed(answer("\x1b_Gi=31;OK\x1b\\"), ms(0));
    try testing.expect(!p.caps.kitty_graphics);
    // A refusal of the question still says the protocol is there.
    p.feed(answer("\x1b_Gi=1;EINVAL:dimensions required\x1b\\"), ms(0));
    try testing.expect(p.caps.kitty_graphics);
}

/// An answer as the input reads it: a reply when it is one, the bytes
/// framed and unread when it is not.
fn answer(bytes: []const u8) morse.Event {
    if (morse.Reply.parse(bytes)) |r| return .{ .reply = r };
    return .{ .unhandled = bytes };
}

test "a probe ignores disabled questions without extending its quiet period" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1, .sync_output = false, .unicode_core = false });
    p.feed(answer("\x1b[?62;4;22c"), ms(100));
    p.feed(answer("\x1b[?2026;1$y"), ms(140));
    p.feed(answer("\x1b[?2027;1$y"), ms(145));
    try testing.expect(!p.caps.sync);
    try testing.expectEqual(textmod.Method.wcwidth, p.caps.width_method);
    try testing.expect(!p.answered.contains(.sync_output));
    try testing.expect(!p.answered.contains(.unicode_core));
    try testing.expectEqual(@as(?std.Io.Timestamp, ms(100)), p.last_answer);
    try testing.expect(p.settled(ms(150), .fromMilliseconds(50)));
}

test "probe quiet time spans the signed clock range" {
    var probe: Caps.Probe = .init(.{ .graphics_id = 1 });
    probe.feed(answer("\x1b[?62;4;22c"), ms(std.math.minInt(i64)));
    try testing.expect(probe.settled(ms(std.math.maxInt(i64)), .fromMilliseconds(50)));
    probe.last_answer = ms(std.math.maxInt(i64));
    try testing.expect(!probe.settled(ms(std.math.minInt(i64)), .fromMilliseconds(50)));
}

test "the picture protocol is kitty, then iTerm2, then sixel, then cells, unless the caller chose" {
    try testing.expectEqual(Caps.Pictures.cells, (Caps{}).pictures());
    try testing.expectEqual(Caps.Pictures.sixel, (Caps{ .sixel = true }).pictures());
    try testing.expectEqual(Caps.Pictures.iterm, (Caps{ .sixel = true, .iterm_images = true }).pictures());
    try testing.expectEqual(Caps.Pictures.kitty, (Caps{ .sixel = true, .iterm_images = true, .kitty_graphics = true }).pictures());
    // The caller's choice stands, even one the terminal never claimed.
    try testing.expectEqual(Caps.Pictures.sixel, (Caps{ .kitty_graphics = true, .picture_protocol = .sixel }).pictures());
    try testing.expectEqual(Caps.Pictures.cells, (Caps{ .kitty_graphics = true, .picture_protocol = .cells }).pictures());
    try testing.expectEqual(Caps.Pictures.iterm, (Caps{ .picture_protocol = .iterm }).pictures());
}

test "sixels are the device attributes' attribute 4, and their registers and size are XTSMGRAPHICS's" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1b[?62;22c"), ms(0));
    try testing.expect(!p.caps.sixel);
    p.feed(answer("\x1b[?65;4;6;22c"), ms(0));
    try testing.expect(p.caps.sixel);
    try testing.expectEqual(Caps.Pictures.sixel, p.caps.pictures());

    try testing.expectEqual(@as(u16, 256), p.caps.sixel_registers);
    p.feed(answer("\x1b[?1;0;16S"), ms(0));
    try testing.expectEqual(@as(u16, 16), p.caps.sixel_registers);
    // More than one image can define is as many as it can.
    p.feed(answer("\x1b[?1;0;1024S"), ms(0));
    try testing.expectEqual(@as(u16, 256), p.caps.sixel_registers);
    // A refusal says nothing about the number.
    p.feed(answer("\x1b[?1;3;0S"), ms(0));
    try testing.expectEqual(@as(u16, 256), p.caps.sixel_registers);
    p.feed(answer("\x1b[?2;0;1000;800S"), ms(0));
    try testing.expectEqual(@as(u32, 1000), p.caps.sixel_max_width);
    try testing.expectEqual(@as(u32, 800), p.caps.sixel_max_height);
    try testing.expect(p.hasAnswered(.sixel_registers) and p.hasAnswered(.sixel_geometry));

    p.feed(answer("\x1b[?8452;2$y"), ms(0));
    try testing.expect(p.caps.sixel_cursor_right);
    p.feed(answer("\x1b[?8452;0$y"), ms(0));
    try testing.expect(!p.caps.sixel_cursor_right);
}

test "iTerm2's images are a terminal calling itself iTerm2, and nothing else" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1bP>|WezTerm 20240203-110809-5046fc22\x1b\\"), ms(0));
    try testing.expect(!p.caps.iterm_images);
    p.feed(answer("\x1bP>|iTerm2X 1.0\x1b\\"), ms(0));
    try testing.expect(!p.caps.iterm_images);
    p.feed(answer("\x1bP>|iTerm2 3.5.4\x1b\\"), ms(0));
    try testing.expect(p.caps.iterm_images);
    try testing.expectEqual(Caps.Pictures.iterm, p.caps.pictures());
}

test "TERM_PROGRAM is supplied by the caller and recognizes iTerm.app exactly" {
    var caps: Caps = .{};
    caps.termProgram("WezTerm");
    try testing.expect(!caps.iterm_images);
    caps.termProgram("iTerm.app-extra");
    try testing.expect(!caps.iterm_images);
    caps.termProgram("iTerm.app");
    try testing.expectEqual(Caps.Pictures.iterm, caps.pictures());
}

test "picture probe replies stay within the register bound under arbitrary input" {
    try testing.fuzz(testing.allocator, struct {
        fn one(_: std.mem.Allocator, smith: *testing.Smith) !void {
            var p: Caps.Probe = .init(.{ .graphics_id = 1 });
            var bytes: [512]u8 = undefined;
            const n = smith.slice(&bytes);
            p.feed(answer(bytes[0..n]), ms(0));
            const caps = p.capabilities();
            try testing.expect(caps.sixel_registers >= 2 and caps.sixel_registers <= morse.sixel_palette_max);
            // The reply parser and question ownership stay with morse;
            // folding any unhandled input cannot make pictures available.
            if (morse.Reply.parse(bytes[0..n]) == null) try testing.expectEqual(Caps.Pictures.cells, caps.pictures());
        }
    }.one, .{ .corpus = &.{ "\x1b[?65;4c", "\x1b[?1;0;16S", "\x1b[?2;0;1000;800S", "\x1bP>|iTerm2 3.5.4\x1b\\", "\x1b[?1;0;4294967295S", "\x1b[?1;0;-1S" } });
}

test "a colour count arriving after DA1 extends the quiet period" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1 });
    p.feed(answer("\x1b[?62;4;22c"), ms(100));
    p.feed(answer("\x1bP1+r436f=3136\x1b\\"), ms(140));
    try testing.expect(p.hasAnswered(.color_count));
    try testing.expectEqual(@as(?u32, 16), p.capabilities().colors);
    try testing.expectEqual(morse.Color.Profile.ansi, p.capabilities().colorProfile());
    try testing.expect(!p.settled(ms(150), .fromMilliseconds(50)));
    try testing.expect(p.settled(ms(190), .fromMilliseconds(50)));
}

test "a refused or invalid colour count leaves the count unknown" {
    for ([_][]const u8{
        "\x1bP0+r436f\x1b\\",
        "\x1bP1+r436f\x1b\\",
        "\x1bP1+r436f=6e6f\x1b\\",
        "\x1bP1+r436f=34323934393637323936\x1b\\",
    }) |bytes| {
        var p: Caps.Probe = .init(.{ .graphics_id = 1 });
        p.feed(answer(bytes), ms(10));
        try testing.expect(p.hasAnswered(.color_count));
        try testing.expectEqual(@as(?u32, null), p.capabilities().colors);
        try testing.expectEqual(@as(?std.Io.Timestamp, ms(10)), p.lastAnswer());
    }
}

test "a disabled colour count changes neither caps nor quiet time" {
    var p: Caps.Probe = .init(.{ .graphics_id = 1, .color_count = false });
    p.feed(answer("\x1b[?62;4;22c"), ms(100));
    p.feed(answer("\x1bP1+r436f=3136\x1b\\"), ms(140));
    try testing.expect(!p.hasAnswered(.color_count));
    try testing.expectEqual(@as(?u32, null), p.capabilities().colors);
    try testing.expectEqual(@as(?std.Io.Timestamp, ms(100)), p.lastAnswer());
    try testing.expect(p.settled(ms(150), .fromMilliseconds(50)));
}

/// A test's clock reading, in milliseconds.
fn ms(n: i64) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, n) * std.time.ns_per_ms };
}
