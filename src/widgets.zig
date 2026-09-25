//! Widgets on `visor`.
//!
//! A widget is a value built where it is drawn, handed a window, and gone by
//! the end of the call. There is no retained tree, no callback, no focus
//! model and no loop: a program drawing a frame already has all four, and a
//! widget set that brings its own takes the program's away.
//!
//! Anything that has to survive the frame is a second struct the caller
//! owns and passes by pointer — a list's selection and scroll, a table's,
//! a scrollbar's position. The widget reads it, may move it to keep the
//! selection on screen, and forgets it.
//!
//! Nothing here allocates on its own. The calls that write text return an
//! error because the screen interns a grapheme longer than six bytes, which
//! is the one allocation anywhere on the frame path.
//!
//! This module imports `visor`. `visor` never imports this one: a base layer
//! that depends on its widgets is not a base layer.

const std = @import("std");

/// The base this is drawn on, re-exported so a program that imports the
/// widgets has the grid, the window and the styles without a second import.
pub const visor = @import("visor");

/// The version of this module, which is the version of the package.
pub const version = visor.version;

const layout_mod = @import("widgets/layout.zig");

//=========================================================================
// Layout.
//=========================================================================

/// A rectangle split into parts along one axis.
pub const Layout = layout_mod.Layout;
/// How much of an axis one part of a split takes.
pub const Constraint = layout_mod.Constraint;
/// Which way a split runs.
pub const Direction = layout_mod.Direction;
/// Cells taken off the four sides of a rectangle.
pub const Padding = layout_mod.Padding;
/// Where something sits in the space it was given.
pub const Align = layout_mod.Align;
/// A rectangle of a given size placed in an area, aligned along both axes.
pub const place = layout_mod.place;
/// How far into an outer length something of an inner length starts.
pub const offset = layout_mod.offset;

//=========================================================================
// The widgets.
//=========================================================================

/// A frame, a title and padding around a window.
pub const Block = @import("widgets/block.zig").Block;
/// Lines of text, wrapped, aligned and scrolled.
pub const Paragraph = @import("widgets/paragraph.zig").Paragraph;
/// Items in a column, with a selection that scrolls itself into view.
pub const List = @import("widgets/list.zig").List;
/// Rows in columns, with a header and a selection.
pub const Table = @import("widgets/table.zig").Table;
/// Titles in a row, one of them chosen.
pub const Tabs = @import("widgets/tabs.zig").Tabs;
/// A proportion, as a bar across a rectangle.
pub const Gauge = @import("widgets/gauge.zig").Gauge;
/// A proportion, as a line one row tall.
pub const LineGauge = @import("widgets/gauge.zig").LineGauge;
/// A series as one row of blocks.
pub const Sparkline = @import("widgets/sparkline.zig").Sparkline;
/// Named values as bars.
pub const BarChart = @import("widgets/barchart.zig").BarChart;
/// Datasets on axes, as lines or as points.
pub const Chart = @import("widgets/chart.zig").Chart;
/// Where a viewport is in something longer.
pub const Scrollbar = @import("widgets/scrollbar.zig").Scrollbar;
/// A plane to draw shapes on, in the caller's own coordinates.
pub const Canvas = @import("widgets/canvas.zig").Canvas;
/// One month, as weeks in rows.
pub const Calendar = @import("widgets/calendar.zig").Calendar;
/// Text being typed, laid out as rows, with the cursor as a place in them.
pub const TextInput = @import("widgets/text_input.zig").TextInput;
/// Which rows of something longer a view shows, held still while it grows.
pub const Scroll = @import("widgets/scroll.zig").Scroll;
/// The keys that work here, each beside what it does.
pub const Keys = @import("widgets/keys.zig").Keys;
/// A line across a window or down it.
pub const Rule = @import("widgets/rule.zig").Rule;
/// A picture drawn in cells, two by three pixels a cell.
pub const Sextants = @import("widgets/sextants.zig").Sextants;
/// The block sextant for a pattern of six lit pixels.
pub const sextant = @import("widgets/sextants.zig").sextant;

/// The marks a canvas can draw with, and how many of them fit in a cell.
pub const Marker = @import("widgets/canvas.zig").Marker;
/// A dataset on a chart, and how it is drawn.
pub const Dataset = @import("widgets/chart.zig").Dataset;
/// One side of a chart: its bounds, its title and its labels.
pub const Axis = @import("widgets/chart.zig").Axis;
/// One bar of a bar chart.
pub const Bar = @import("widgets/barchart.zig").Bar;
/// One row of a table.
pub const Row = @import("widgets/table.zig").Row;
/// One line of a paragraph.
pub const Line = @import("widgets/paragraph.zig").Line;
/// One item of a list.
pub const Item = @import("widgets/list.zig").Item;
/// A day, as a calendar counts them.
pub const Date = @import("widgets/calendar.zig").Date;

test {
    _ = layout_mod;
    _ = @import("widgets/block.zig");
    _ = @import("widgets/paragraph.zig");
    _ = @import("widgets/list.zig");
    _ = @import("widgets/table.zig");
    _ = @import("widgets/tabs.zig");
    _ = @import("widgets/gauge.zig");
    _ = @import("widgets/sparkline.zig");
    _ = @import("widgets/barchart.zig");
    _ = @import("widgets/chart.zig");
    _ = @import("widgets/scrollbar.zig");
    _ = @import("widgets/canvas.zig");
    _ = @import("widgets/calendar.zig");
    _ = @import("widgets/harness.zig");
    _ = @import("widgets/text_input.zig");
    _ = @import("widgets/scroll.zig");
    _ = @import("widgets/keys.zig");
    _ = @import("widgets/rule.zig");
    _ = @import("widgets/sextants.zig");
    std.testing.refAllDecls(@This());
}
