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
//! itself; this file will not do it behind them.
//!
//! What this file will never hold: a terminfo reader, a capability database,
//! a table of terminal names, or a timeout.

const std = @import("std");
const morse = @import("morse");
const textmod = @import("text.zig");

/// What this terminal can do. Every field is safe at its default.
pub const Caps = struct {
    /// How the terminal measures text. `wcwidth` until it says otherwise,
    /// and the one value both the measuring code and the drift rule read.
    width_method: textmod.Method = .wcwidth,
    /// Whether the terminal takes `38;2;r;g;b`. A terminal without it
    /// approximates the colour from its palette rather than losing it, so
    /// this only decides whether asking is worth the bytes.
    truecolor: bool = false,
    /// Whether the user asked for no colour at all. Nothing here reads
    /// `NO_COLOR`; a caller that honours it sets this.
    no_color: bool = false,
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
    /// graphic rather than below it. The difference between knowing where
    /// the cursor is and asking.
    sixel_cursor_right: bool = false,

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
        /// The questions, morse's. `questions.graphics_id` has no default:
        /// the program chooses an id it never sends a picture under, because
        /// the graphics answer is told from an answer about a picture by
        /// this id alone.
        questions: morse.Probe,
        /// What the answers have said so far.
        caps: Caps = .{},
        /// Which questions have been answered.
        answered: std.EnumSet(morse.Probe.Question) = .initEmpty(),
        /// When the last answer came, on the caller's clock, in
        /// milliseconds; null before the first.
        last_ms: ?i64 = null,

        /// Asks every question, in one write.
        pub fn write(p: *const Probe, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try p.questions.write(w);
        }

        /// Folds one event from the input in: the answers to the questions,
        /// read. Anything else is ignored, because a terminal answering a
        /// question nobody asked is not this package's problem to diagnose.
        pub fn feed(p: *Probe, event: morse.Event, now_ms: i64) void {
            const question = morse.probeAnswered(event) orelse return;
            // A graphics answer about one of the program's pictures answers
            // nothing here.
            if (question == .graphics and event.reply.graphics.id != p.questions.graphics_id) return;
            p.answered.insert(question);
            p.last_ms = now_ms;
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
                    // and in-band resize reports are turned on by `enter`:
                    // neither is on when asked about.
                    if (m.mode == morse.syncOutput.number) p.caps.sync = has;
                    if (m.mode == morse.inBandResize.number) p.caps.in_band_resize = has;
                    // A terminal that measures clusters whatever anyone asks
                    // answers permanently set; one that can be asked will be,
                    // by `enter`.
                    if (m.mode == morse.unicodeCore.number) p.caps.width_method = if (has) .unicode else .wcwidth;
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
                if (p.questions.asks(q) and !p.answered.contains(q)) return false;
            }
            return true;
        }

        /// Whether to stop waiting: every question answered, or the device
        /// attributes answered and nothing more for `quiet_ms` since the
        /// last answer, on the caller's clock. The caller's overall timeout
        /// still ends a probe the terminal never answers at all.
        pub fn settled(p: *const Probe, now_ms: i64, quiet_ms: i64) bool {
            if (p.complete()) return true;
            if (!p.answered.contains(.device_attributes)) return false;
            return now_ms - (p.last_ms orelse now_ms) >= quiet_ms;
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
    const p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    try p.write(&out);
    var theirs_buf: [512]u8 = undefined;
    var theirs: std.Io.Writer = .fixed(&theirs_buf);
    try (morse.Probe{ .graphics_id = 1 }).write(&theirs);
    try testing.expectEqualStrings(theirs.buffered(), out.buffered());
    // Among them the ones a `Caps` is made of, and the one always answered
    // last.
    const asked = out.buffered();
    for ([_][]const u8{ "\x1b[?2026$p", "\x1b[?2027$p", "\x1b[?2048$p", "\x1bP+q5463\x1b\\", "\x1bP+q524742\x1b\\", "\x1b_Ga=q,i=1," }) |q| {
        try testing.expect(std.mem.indexOf(u8, asked, q) != null);
    }
    try testing.expect(std.mem.endsWith(u8, asked, "\x1b[c"));
}

test "a mode the terminal answers set or reset is one it has, and not recognised is one it lacks" {
    // What a terminal with each of them says before anything turned them
    // on: reset. That is a yes.
    for ([_][]const u8{ "1", "2", "3" }) |state| {
        var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
        var buf: [3][32]u8 = undefined;
        p.feed(answer(try std.fmt.bufPrint(&buf[0], "\x1b[?2026;{s}$y", .{state})), 0);
        p.feed(answer(try std.fmt.bufPrint(&buf[1], "\x1b[?2027;{s}$y", .{state})), 0);
        p.feed(answer(try std.fmt.bufPrint(&buf[2], "\x1b[?2048;{s}$y", .{state})), 0);
        try testing.expect(p.caps.sync);
        try testing.expectEqual(textmod.Method.unicode, p.caps.width_method);
        try testing.expect(p.caps.in_band_resize);
    }
    for ([_][]const u8{ "0", "4" }) |state| {
        var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
        p.caps = .{ .sync = true, .width_method = .unicode, .in_band_resize = true };
        var buf: [3][32]u8 = undefined;
        p.feed(answer(try std.fmt.bufPrint(&buf[0], "\x1b[?2026;{s}$y", .{state})), 0);
        p.feed(answer(try std.fmt.bufPrint(&buf[1], "\x1b[?2027;{s}$y", .{state})), 0);
        p.feed(answer(try std.fmt.bufPrint(&buf[2], "\x1b[?2048;{s}$y", .{state})), 0);
        try testing.expect(!p.caps.sync);
        try testing.expectEqual(textmod.Method.wcwidth, p.caps.width_method);
        try testing.expect(!p.caps.in_band_resize);
    }
}

test "the device attributes answer does not settle the probe while a forwarded answer may still come" {
    // A multiplexer answers the device attributes itself while a question it
    // forwarded is still on its way: the probe waits for the caller's quiet
    // period after the last answer, on the caller's clock.
    var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    p.feed(answer("\x1b[?2026;1$y"), 100);
    try testing.expect(!p.settled(100, 50));
    p.feed(answer("\x1b[?62;4;22c"), 110);
    try testing.expect(!p.settled(120, 50));
    // The forwarded answer lands, and the quiet period starts again.
    p.feed(answer("\x1b]11;rgb:1e1e/1e1e/2e2e\x07"), 150);
    try testing.expect(!p.settled(180, 50));
    try testing.expect(p.settled(200, 50));
    // Without the device attributes no quiet period settles it: silence
    // there is a terminal that has not answered yet, for the caller's own
    // timeout to end.
    var q: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    q.feed(answer("\x1b[?2026;1$y"), 0);
    try testing.expect(!q.settled(10_000, 50));
}

test "a probe answered in full is settled at once" {
    var p: Caps.Probe = .{ .questions = .{
        .graphics_id = 1,
        .cursor_position = false,
        .foreground_color = false,
        .background_color = false,
        .cursor_color = false,
        .color_scheme = false,
        .unicode_core = false,
        .in_band_resize = false,
        .kitty_keyboard = false,
        .modify_other_keys = false,
        .graphics = false,
        .extra_cursors = false,
        .truecolor = false,
        .version = false,
        .text_area_cells = false,
        .cell_pixels = false,
        .secondary_device_attributes = false,
    } };
    p.feed(answer("\x1b[?62;4;22c"), 5);
    try testing.expect(!p.complete());
    p.feed(answer("\x1b[?2026;2$y"), 6);
    try testing.expect(p.complete() and p.settled(6, 1000));
    try testing.expect(p.caps.sync);
}

test "an unrecognised reply changes nothing" {
    var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    const before = p.caps;
    p.feed(answer("nonsense"), 0);
    p.feed(answer("\x1b["), 0);
    p.feed(answer(""), 0);
    try testing.expectEqual(before, p.caps);
    try testing.expect(!p.settled(1000, 0));
}

test "a 256-colour count is not evidence of truecolor" {
    var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    // XTGETTCAP reply: "Co" = "256", both halves in hex.
    p.feed(answer("\x1bP1+r436f=323536\x1b\\"), 0);
    try testing.expect(!p.caps.truecolor);
}

test "a truecolor-specific capability enables truecolor" {
    var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    p.feed(answer("\x1bP1+r5463\x1b\\"), 0);
    try testing.expect(p.caps.truecolor);
}

test "the graphics answer is the one carrying the id the program chose" {
    var p: Caps.Probe = .{ .questions = .{ .graphics_id = 1 } };
    // An answer about a picture is not an answer to the question.
    p.feed(answer("\x1b_Gi=31;OK\x1b\\"), 0);
    try testing.expect(!p.caps.kitty_graphics);
    // A refusal of the question still says the protocol is there.
    p.feed(answer("\x1b_Gi=1;EINVAL:dimensions required\x1b\\"), 0);
    try testing.expect(p.caps.kitty_graphics);
}

/// An answer as the input reads it: a reply when it is one, the bytes
/// framed and unread when it is not.
fn answer(bytes: []const u8) morse.Event {
    if (morse.Reply.parse(bytes)) |r| return .{ .reply = r };
    return .{ .unhandled = bytes };
}
