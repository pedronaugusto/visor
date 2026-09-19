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
//! the frame path allocates nothing: `writeCell` does not, `print` does not,
//! `draw` does not. `Screen.write` allocates only for a grapheme longer than
//! six bytes that the screen has not seen before.
//!
//! Every escape sequence this package writes comes from `morse`, which is
//! re-exported whole, so a consumer fetches one thing and a reviewer can
//! check the rule with `grep`. The width tables come from `uucode`, pinned
//! with the field list the README prints.
//!
//! Nothing here reads an environment variable, starts a thread, installs a
//! signal handler, or keeps a clock. `Caps` says what the terminal can do
//! and the caller fills it in — from `Caps.Probe`, which asks the terminal,
//! or from anywhere else it likes.

const std = @import("std");

const cell_mod = @import("cell.zig");
const caps_mod = @import("caps.zig");
const damage_mod = @import("damage.zig");
const geom_mod = @import("geom.zig");
const layer_mod = @import("layer.zig");
const pool_mod = @import("pool.zig");
const render_mod = @import("render.zig");
const screen_mod = @import("screen.zig");
const term_mod = @import("term.zig");
const text_mod = @import("text.zig");
const tty_mod = @import("tty.zig");
const window_mod = @import("window.zig");

/// The writers and parsers this package stands on, re-exported whole.
///
/// One fetch, one import: a program that wants a hyperlink or the clipboard
/// or the kitty keyboard protocol reaches them through here rather than
/// adding a second dependency.
pub const morse = @import("morse");

/// The semantic version of this package, as a string.
pub const version = "0.0.0";

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
/// An OSC 8 target, as an index into the screen's link table.
pub const Link = cell_mod.Link;
/// The target a `Link` names: a URI and the parameters beside it.
pub const Target = pool_mod.Target;

//=========================================================================
// The grid and the views of it.
//=========================================================================

/// The grid: cells, size, cursor, the grapheme pool, the link table, the
/// damage map and the layers.
pub const Screen = screen_mod.Screen;
/// Where the terminal's cursor should end the frame.
pub const Cursor = screen_mod.Cursor;
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
/// The columns one cluster takes: 0, 1 or 2.
pub const graphemeWidth = text_mod.graphemeWidth;
/// Whether the two width models disagree about a cluster.
pub const disagrees = text_mod.disagrees;
/// Breaks a string into rows of at most so many columns.
pub const wrap = text_mod.wrap;
/// One row a wrap produced.
pub const Row = text_mod.Row;
/// The prefix of a string that fits, with the ellipsis counted.
pub const fit = text_mod.fit;

//=========================================================================
// Pictures.
//=========================================================================

/// Bytes the terminal was sent.
pub const Image = layer_mod.Image;
/// A picture on the screen: an image, a rectangle, and a place in the stack.
pub const Layer = layer_mod.Layer;
/// What this frame shows.
pub const Layers = layer_mod.Layers;

//=========================================================================
// The terminal, and a terminal to test against.
//=========================================================================

/// This program's own terminal, for a program that wants one.
pub const Tty = tty_mod.Tty;
/// Puts the one open terminal back. Allocates nothing, fails at nothing.
pub const restoreGlobal = tty_mod.restoreGlobal;
/// A panic handler that calls `restoreGlobal` and then Zig's. Yours to
/// install; never installed behind your back.
pub const Panic = tty_mod.Panic;

/// A terminal emulator just wide enough to check a renderer: it consumes
/// what `draw` wrote and rebuilds a `Screen`.
pub const Term = term_mod.Term;
/// Two screens compared cell by cell, naming the first that differs.
pub const expectScreensEqual = term_mod.expectScreensEqual;
/// The first cell two screens disagree about, read by column, or null.
pub const firstDifference = term_mod.firstDifference;
/// A screen as text, one row a line.
pub const dumpScreen = term_mod.dumpScreen;
/// A screen's styles as one identifier a cell, with the legend above.
pub const dumpScreenStyles = term_mod.dumpScreenStyles;

test {
    _ = cell_mod;
    _ = caps_mod;
    _ = damage_mod;
    _ = geom_mod;
    _ = layer_mod;
    _ = pool_mod;
    _ = render_mod;
    _ = @import("scroll.zig");
    _ = screen_mod;
    _ = term_mod;
    _ = text_mod;
    _ = tty_mod;
    _ = window_mod;
    _ = @import("roundtrip.zig");
    _ = @import("bench.zig");
}
