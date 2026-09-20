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
    explicit_width: bool = false,
    /// Text drawn at more than one cell's size.
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

    /// The questions, as bytes.
    ///
    /// `write` asks them all in one go and ends with a primary device
    /// attributes request, which every terminal answers: when that answer
    /// arrives, everything a terminal was going to say has been said, and
    /// `settled` returns true. Silence to any single question is the answer
    /// "no", which is why they are asked together and why nothing here
    /// waits.
    pub const Probe = struct {
        /// What the questions have answered so far.
        caps: Caps = .{},
        /// Whether the closing DA1 reply has come back.
        done: bool = false,

        /// Writes every question, DA1 last.
        pub fn write(_: *const Probe, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try morse.queryMode(w, morse.syncOutput.number);
            try morse.queryMode(w, morse.unicodeCore.number);
            try morse.queryMode(w, morse.inBandResize.number);
            try morse.kittyKeyboardQuery(w);
            try morse.queryCapability(w, "Tc");
            try morse.queryCapability(w, "RGB");
            try morse.queryVersion(w);
            try morse.queryGraphics(w, 31);
            try morse.queryDeviceAttributes(w);
        }

        /// Folds one reply in. Anything unrecognised is ignored, because a
        /// terminal answering a question nobody asked is not this package's
        /// problem to diagnose.
        pub fn feed(p: *Probe, bytes: []const u8) void {
            if (morse.parseModeReply(bytes)) |reply| {
                const on = reply.state == .set or reply.state == .permanently_set;
                if (reply.mode == morse.syncOutput.number) p.caps.sync = on;
                if (reply.mode == morse.inBandResize.number) p.caps.in_band_resize = on;
                if (reply.mode == morse.unicodeCore.number) {
                    // Not "is the mode set". A terminal that measures
                    // clusters whatever anyone asks answers permanently set;
                    // one that cannot answers permanently reset. Set, reset
                    // and permanently set all mean clusters are measured,
                    // because a terminal that can be asked will be; not
                    // recognised and permanently reset mean they are not.
                    p.caps.width_method = switch (reply.state) {
                        .set, .reset, .permanently_set => .unicode,
                        .not_recognized, .permanently_reset => .wcwidth,
                    };
                }
                return;
            }
            if (morse.parseKittyKeyboardReply(bytes)) |_| {
                p.caps.kitty_keyboard = true;
                return;
            }
            if (morse.parseCapabilityReply(bytes)) |reply| {
                var it = reply.iterator();
                while (it.next()) |capability| {
                    var name: [8]u8 = undefined;
                    const n = capability.decodeName(&name) catch continue;
                    if (reply.known and
                        (std.mem.eql(u8, n, "Tc") or std.mem.eql(u8, n, "RGB")))
                    {
                        p.caps.truecolor = true;
                    }
                }
                return;
            }
            if (morse.parseGraphicsResponse(bytes)) |_| {
                p.caps.kitty_graphics = true;
                return;
            }
            if (morse.parseDeviceAttributes(bytes)) |da| {
                // A terminal that reports sixel support reports graphics of
                // some kind; the kitty protocol is answered for separately.
                p.done = true;
                _ = da;
                return;
            }
        }

        /// Whether the closing DA1 answer has come back, after which no
        /// further reply is expected.
        pub fn settled(p: *const Probe) bool {
            return p.done;
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

test "the probe asks its questions and ends with the one always answered" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const p: Caps.Probe = .{};
    try p.write(&out);
    const asked = out.buffered();
    try testing.expect(std.mem.indexOf(u8, asked, "\x1b[?2026$p") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "\x1b[?2027$p") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "\x1b[?2048$p") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "\x1bP+q5463\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "\x1bP+q524742\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, asked, "\x1b_G") != null);
    try testing.expect(std.mem.endsWith(u8, asked, "\x1b[c"));
}

test "a mode reply turns its field on and a reset one turns it off" {
    var p: Caps.Probe = .{};
    p.feed("\x1b[?2026;1$y");
    try testing.expect(p.caps.sync);
    p.feed("\x1b[?2026;2$y");
    try testing.expect(!p.caps.sync);
    p.feed("\x1b[?2027;1$y");
    try testing.expectEqual(textmod.Method.unicode, p.caps.width_method);
    p.feed("\x1b[?2048;1$y");
    try testing.expect(p.caps.in_band_resize);
}

test "the probe settles on the device attributes answer and not before" {
    var p: Caps.Probe = .{};
    p.feed("\x1b[?2026;1$y");
    try testing.expect(!p.settled());
    p.feed("\x1b[?62;4;22c");
    try testing.expect(p.settled());
}

test "an unrecognised reply changes nothing" {
    var p: Caps.Probe = .{};
    const before = p.caps;
    p.feed("nonsense");
    p.feed("\x1b[");
    p.feed("");
    try testing.expectEqual(before, p.caps);
    try testing.expect(!p.settled());
}

test "a 256-colour count is not evidence of truecolor" {
    var p: Caps.Probe = .{};
    // XTGETTCAP reply: "Co" = "256", both halves in hex.
    p.feed("\x1bP1+r436f=323536\x1b\\");
    try testing.expect(!p.caps.truecolor);
}

test "a truecolor-specific capability enables truecolor" {
    var p: Caps.Probe = .{};
    p.feed("\x1bP1+r5463\x1b\\");
    try testing.expect(p.caps.truecolor);
}
