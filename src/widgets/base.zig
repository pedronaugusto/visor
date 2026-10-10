//! What the widgets draw on: the base's names, taken from the files that
//! own them.
//!
//! A widget reaches the grid, the window and the text measures through
//! here as `visor.Window`, `visor.Rect`, and so on, the same spelling a
//! program using the package writes. It is the one place the widgets look
//! down at the base, and `src/visor.zig`, which re-exports the widgets, is
//! not where they look: the base is a layer under them and never imports
//! them.

const cell = @import("../cell.zig");
const caps = @import("../caps.zig");
const geom = @import("../geom.zig");
const layer = @import("../layer.zig");
const render = @import("../render.zig");
const screen = @import("../screen.zig");
const term = @import("../term.zig");
const text = @import("../text.zig");
const winsize = @import("../winsize.zig");

/// The writers and parsers the package stands on.
pub const morse = @import("../dependencies.zig").morse;

pub const Style = cell.Style;
pub const Color = cell.Color;
pub const Underline = cell.Underline;
pub const Link = cell.Link;

pub const Screen = screen.Screen;
pub const DrawError = screen.Screen.DrawError;
pub const Window = screen.window_api.Window;
pub const Rect = geom.Rect;
pub const Size = geom.Size;

pub const Renderer = render.Renderer;
pub const Caps = caps.Caps;

pub const Method = text.Method;
pub const Wrap = text.Wrap;
pub const Graphemes = text.Graphemes;
pub const Row = text.Row;
pub const width = text.width;
pub const graphemeWidth = text.graphemeWidth;
pub const wrap = text.wrap;
pub const fit = text.fit;

pub const Layer = layer.Layer;
pub const Layers = layer.Layers;
pub const Pixels = winsize.Pixels;

pub const Term = term.Term;
pub const expectScreensEqual = term.expectScreensEqual;
pub const dumpScreen = term.dumpScreen;
