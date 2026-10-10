//! A cell grid, a diff renderer and the terminal, for a program that draws
//! its own screen.
//!
//! A program keeps a `Screen`, draws into it through `Window`s as often as
//! it likes, and calls `Renderer.draw` once a frame. What comes out is the
//! shortest run of bytes that moves the terminal from the frame it is
//! showing to the frame it should be showing, written to a
//! `*std.Io.Writer` the caller owns and flushes.
//!
//! One allocator, taken at `Screen.init` and `Renderer.init`. After that,
//! `draw` allocates nothing. Measurement-only printing (`commit = false`)
//! allocates nothing; committed printing and `Screen.write` can allocate
//! for a grapheme longer than six bytes the screen has not seen before.
//!
//! Every escape sequence this package writes comes from `morse`, which is
//! re-exported whole, so a consumer fetches one thing and a reviewer can
//! check the rule with `grep`. The width tables come from `uucode`, pinned
//! with the field list the README prints.
//!
//! The drawing core reads no environment variable, starts no thread,
//! installs no signal handler and keeps no clock. The optional terminal
//! adapter installs SIGWINCH handling when asked through `Tty.watchResize`.
//! `Caps` says what the terminal can do and the caller fills it in — from
//! `Caps.Probe`, which asks the terminal, or from anywhere else it likes.
//!
//! `widgets` is a layout solver and widgets drawn on the grid. They build on
//! the files above and nothing above builds on them.

const std = @import("std");

const cell_mod = @import("cell.zig");
const caps_mod = @import("caps.zig");
const damage_mod = @import("damage.zig");
const geom_mod = @import("geom.zig");
const input_mod = @import("input.zig");
const layer_mod = @import("layer.zig");
const palette_mod = @import("palette.zig");
const pool_mod = @import("pool.zig");
const render_mod = @import("render.zig");
const session_mod = @import("session.zig");
const screen_mod = @import("screen.zig");
const term_mod = @import("term.zig");
const text_mod = @import("text.zig");
const tty_mod = @import("tty.zig");
const window_mod = @import("screen.zig").window_api;
const winsize_mod = @import("winsize.zig");

/// The writers and parsers this package stands on, re-exported whole.
///
/// One fetch, one import: a program that wants a hyperlink or the clipboard
/// or the kitty keyboard protocol reaches them through here rather than
/// adding a second dependency.
pub const morse = @import("dependencies.zig").morse;

//=========================================================================
// The grid's contents.
//=========================================================================

/// One cell: its grapheme, its style, its link, its width and its kind.
pub const Cell = cell_mod.Cell;
/// Everything SGR can say about a cell. `morse.Style`, re-exported: there is
/// no second style type here.
pub const Style = cell_mod.Style;
/// A colour, in the forms SGR can spell.
pub const Color = cell_mod.Color;
/// Which underline a cell carries.
pub const Underline = cell_mod.Underline;
/// An OSC 8 handle bound to the generation of its issuing link pool.
pub const Link = cell_mod.Link;
/// The pool identity carried by a pooled Text or Link.
pub const PoolGeneration = cell_mod.PoolGeneration;
/// A byte address within a grapheme pool.
pub const GraphemeOffset = cell_mod.GraphemeOffset;
/// A position within a link table.
pub const LinkIndex = cell_mod.LinkIndex;
/// The byte length returned by Text.length.
pub const ByteLength = cell_mod.ByteLength;
/// The target a `Link` names: a URI and the parameters beside it.
pub const Target = pool_mod.Target;
/// An independent link target, released with its `deinit`.
pub const OwnedTarget = pool_mod.OwnedTarget;
/// A colour as eight bits a channel.
pub const Rgb = palette_mod.Rgb;
/// What the terminal's colours look like, as it reported them.
pub const Palette = palette_mod.Palette;
/// The step between two colours.
pub const mix = palette_mod.mix;

//=========================================================================
// The grid and the views of it.
//=========================================================================

/// The grid: cells, size, cursor, the grapheme pool, the link table and the
/// damage map. Pictures belong to the Layers kept beside it.
pub const Screen = screen_mod.Screen;
/// Where the terminal's cursor should end the frame.
pub const Cursor = screen_mod.Cursor;
/// A cell a screen refuses: a stale or foreign handle, or a glyph or shape
/// that is not one printable cluster by the screen's width method.
pub const CellError = screen_mod.Screen.CellError;
/// What drawing into a screen, a window or a widget can fail with:
/// `CellError`, and the allocation interning a new grapheme can need.
pub const DrawError = screen_mod.Screen.DrawError;
/// An offset, clipped view of a `Screen`. The only thing drawing code holds.
pub const Window = window_mod.Window;
/// A rectangle of cells.
pub const Rect = geom_mod.Rect;
/// A place on the grid.
pub const Point = geom_mod.Point;
/// How big something is, in cells.
pub const Size = geom_mod.Size;
/// Which cells changed since the last frame was written.
pub const Damage = damage_mod.Damage;
/// The columns of one row that changed.
pub const Span = damage_mod.Span;

//=========================================================================
// The render pass.
//=========================================================================

/// The last frame, and the style, link and cursor the terminal is in.
pub const Renderer = render_mod.Renderer;
/// What a full-screen program takes on the way in.
pub const Mode = render_mod.Mode;
/// The input a program asks the terminal for: keyboard flags, mouse, focus,
/// paste and colour-scheme reports.
pub const Modes = render_mod.Modes;
/// What this terminal can do. Every field is safe at its default.
pub const Caps = caps_mod.Caps;

//=========================================================================
// Measuring text.
//=========================================================================

/// How the terminal measures: by codepoint, by cluster, or because it was
/// told.
pub const Method = text_mod.Method;
/// How a line that does not fit is broken.
pub const Wrap = text_mod.Wrap;
/// An iterator over grapheme clusters.
pub const Graphemes = text_mod.Graphemes;
/// The columns a string takes.
pub const width = text_mod.width;
/// The columns one cluster takes: 0, 1 or 2 measured whole, the sum of its
/// codepoints' measured by codepoint.
pub const graphemeWidth = text_mod.graphemeWidth;
/// The cells a terminal measuring by codepoint puts one cluster in.
pub const Parts = text_mod.Parts;
/// Whether a cluster is a base and codepoints that take no column of their
/// own, one cell whichever way it is measured.
pub const combinesOnly = text_mod.combinesOnly;
/// Whether the two width models disagree about a cluster.
pub const disagrees = text_mod.disagrees;
/// Breaks a string into rows of at most so many columns.
pub const wrap = text_mod.wrap;
/// One row a wrap produced.
pub const Row = text_mod.Row;
/// The prefix of a string that fits, with the ellipsis counted.
pub const fit = text_mod.fit;
/// The suffix that fits beside a leading ellipsis, cut at a cluster boundary.
pub const fitEnd = text_mod.fitEnd;

//=========================================================================
// Pictures.
//=========================================================================

/// Bytes the terminal was sent.
pub const Image = layer_mod.Image;
/// A picture on the screen: an image, a rectangle, and a place in the stack.
pub const Layer = layer_mod.Layer;
/// What this frame shows.
pub const Layers = layer_mod.Layers;
/// Options for sending pixels through Layers or Replacement.
pub const Transmit = layer_mod.Transmit;
/// One picture replaced without a gap, on caller-supplied time.
pub const Replacement = layer_mod.Replacement;
/// A rotating range of image ids that skips the graphics probe.
pub const ImageIds = layer_mod.ImageIds;

//=========================================================================
// The terminal, and a terminal to test against.
//=========================================================================

/// This program's own terminal, for a program that wants one.
pub const Tty = tty_mod.Tty;
/// The terminal's input, read and framed: morse's events, one at a time,
/// with the lone escape settled on the caller's timeout and a resize woken
/// out of the wait.
pub const Input = input_mod.Input;
/// The screen, renderer, size, probe and pictures held as a caller-owned value.
pub const Session = session_mod.Session;
/// A probe wait budget measured on caller-supplied time.
pub const ProbeWait = session_mod.ProbeWait;
/// How big the terminal is: the grid, and what it has said about pixels.
pub const Winsize = winsize_mod.Winsize;
/// A size in pixels, zero where unknown.
pub const Pixels = winsize_mod.Pixels;
/// One cell in pixels, and whether the terminal said so or it was worked
/// out from the text area.
pub const CellSize = winsize_mod.CellSize;
/// A mouse cell and its fraction, counted from zero.
pub const MouseLocation = winsize_mod.MouseLocation;
/// Puts every registered terminal back, including its renderer's modes.
/// Allocates nothing, fails at nothing.
pub const restoreGlobal = tty_mod.restoreGlobal;
/// A panic handler that calls `restoreGlobal` and then Zig's. Yours to
/// install; never installed behind your back.
pub const Panic = tty_mod.Panic;

/// A terminal emulator just wide enough to check a renderer: it consumes
/// what `draw` wrote and rebuilds a `Screen`.
pub const Term = term_mod.Term;
/// Two screens compared cell by cell, naming the first that differs.
pub const expectScreensEqual = term_mod.expectScreensEqual;
/// What `expectScreensEqual` fails with when the screens differ.
pub const ExpectError = term_mod.ExpectError;
/// The first cell two screens disagree about, read by column, or null.
pub const firstDifference = term_mod.firstDifference;
/// A screen as text, one row a line.
pub const dumpScreen = term_mod.dumpScreen;
/// What `dumpScreen` writes for a covered column.
pub const DumpOptions = term_mod.DumpOptions;
/// A screen's styles as one identifier a cell, with the legend above.
pub const dumpScreenStyles = term_mod.dumpScreenStyles;

//=========================================================================
// The widgets.
//=========================================================================

/// A layout solver and the widgets, drawn on the grid above. They build on
/// this file's names and nothing here builds on them.
pub const widgets = @import("widgets.zig");

test {
    _ = cell_mod;
    _ = caps_mod;
    _ = damage_mod;
    _ = geom_mod;
    _ = input_mod;
    _ = layer_mod;
    _ = palette_mod;
    _ = pool_mod;
    _ = render_mod;
    _ = @import("render/moved_rows_test.zig");
    _ = @import("screen_test.zig");
    _ = @import("window_test.zig");
    _ = @import("layer_test.zig");
    _ = @import("layer/shm.zig");
    _ = screen_mod;
    _ = session_mod;
    _ = term_mod;
    _ = text_mod;
    _ = tty_mod;
    _ = window_mod;
    _ = winsize_mod;
    _ = @import("testing/roundtrip_test.zig");
    _ = @import("corpus");
    _ = @import("testing/render_budget_test.zig");
}

test "transmission options have one public name" {
    const how: Transmit = .{ .width = 1, .height = 1, .compress = false };
    try std.testing.expect(Transmit == layer_mod.Transmit);
    var layers = Layers.init(std.testing.allocator);
    defer layers.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    _ = try layers.transmit(&out.writer, 1, &.{ 0, 0, 0, 255 }, how);
    try std.testing.expectEqual(@as(usize, 1), layers.images().len);
}

/// Whether a value of `T` holds a `std.Io`, looking `depth` levels into its
/// fields, payloads and what it points at.
fn keepsIo(comptime T: type, comptime depth: u8) bool {
    if (T == std.Io) return true;
    if (depth == 0) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_types) |Field| {
            if (keepsIo(Field, depth - 1)) break true;
        } else false,
        .@"union" => |info| for (info.field_types) |Field| {
            if (keepsIo(Field, depth - 1)) break true;
        } else false,
        .optional => |info| keepsIo(info.child, depth - 1),
        .pointer => |info| keepsIo(info.child, depth - 1),
        .array => |info| keepsIo(info.child, depth - 1),
        .error_union => |info| keepsIo(info.payload, depth - 1),
        else => false,
    };
}

const visor = @This();

test "no value of this package keeps a std.Io: a call that waits takes the caller's" {
    const offenders = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var names: []const u8 = "";
        for (@typeInfo(visor).@"struct".decl_names) |name| {
            const decl = @field(visor, name);
            if (@TypeOf(decl) == type and keepsIo(decl, 6)) names = names ++ " " ++ name;
        }
        break :blk names;
    };
    try std.testing.expectEqualStrings("", offenders);
}
