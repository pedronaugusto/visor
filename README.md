# visor

[![CI](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml)

visor is a cell grid and a diff renderer for programs that draw their own
screen. You draw into a grid; it writes the shortest run of bytes that moves
the terminal from the frame it is showing to the one it should be showing. A
second module, `visor.widgets`, holds a layout solver and nineteen widgets
drawn on that grid, and the base never imports it.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs. CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const std = @import("std");
const visor = @import("visor");

// What the terminal can do. Nothing here reads an environment
// variable: `Caps.Probe` writes the questions, the caller reads the
// answers on its own clock, and a caller that would rather assume
// sets the fields itself.
const caps: visor.Caps = .{
    .width_method = .unicode,
    .truecolor = true,
    .osc8 = true,
    .sync = true,
};

// The grid, and the renderer that remembers what the terminal was
// last shown. One allocator each, taken here and never again.
const size: visor.Size = .{ .cols = 40, .rows = 7 };
var screen: visor.Screen = try .init(gpa, size);
defer screen.deinit();
screen.method = caps.width_method;

var renderer: visor.Renderer = try .init(gpa, size);
defer renderer.deinit();

// Drawing code holds a window and nothing else. A child is clipped to
// its parent, and a border is drawn as the child is made, so what
// comes back is the inside of the frame.
const root = screen.window();
const panel = root.child(.{
    .col = 1,
    .row = 1,
    .cols = 30,
    .rows = 5,
    .border = .{ .where = .all, .glyphs = .rounded, .style = .{ .dim = true } },
});

// Runs of styled text, wrapped. `print` says where it stopped and can
// allocate for an unseen grapheme longer than six bytes.
const link = try screen.link("https://ziglang.org", "id=1");
_ = try panel.print(&.{
    .{ .text = "visor ", .style = .{ .bold = true } },
    .{ .text = "draws a grid", .style = .{ .fg = .ansi(.cyan) } },
    .{ .text = "\n" },
    .{ .text = "ziglang.org", .style = .{ .underline = .single }, .link = link },
}, .{ .wrap = .word });

// A wide grapheme takes two columns and the grid knows it: the second
// one is a tail, and nothing can be written into it by accident.
try panel.write(0, 2, "\u{4e2d}", .{ .fg = .rgb(0x9a, 0xe0, 0xd5) }, .none);

// Where the cursor should end the frame, in this window's own
// coordinates.
panel.showCursor(12, 2);
panel.setCursorShape(.bar);

// The frame. `draw` writes the difference between what the terminal
// was last shown and this, allocates nothing, and never flushes: the
// caller decides when the bytes leave.
var buffer: std.Io.Writer.Allocating = .init(gpa);
defer buffer.deinit();
const stats = try renderer.draw(&buffer.writer, &screen, null, caps);

// `Stats` is what makes a budget a test rather than a comment, and
// what tells a caller how big a write buffer a frame wants.
std.debug.print("frame: {d} bytes, {d} cells in {d} runs, {d} moves\n", .{
    stats.bytes, stats.cells, stats.runs, stats.moves,
});

// Drawn again with nothing changed, the renderer writes nothing at
// all. That is not an optimisation, it is the property the whole
// design is checked against.
var second: std.Io.Writer.Allocating = .init(gpa);
defer second.deinit();
std.debug.assert((try renderer.draw(&second.writer, &screen, null, caps)).bytes == 0);

// And this is how a program built on visor tests its own screens: the
// emulator reads the bytes back into a grid, and the two are compared
// cell by cell, covered columns included.
var term: visor.Term = try .init(gpa, size);
defer term.deinit();
term.setMethod(caps.width_method);
try term.feed(buffer.written());
try visor.expectScreensEqual(&screen, term.screen());

// The grid as text, one row a line, for a golden file or a failing
// test to be read from.
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try visor.dumpScreen(term.screen(), &out.writer);
std.debug.print("{s}", .{out.written()});

// Every sequence visor writes comes from morse, which it re-exports
// whole: one fetch, and everything under the grid is reachable.
var control: [128]u8 = undefined;
var w: std.Io.Writer = .fixed(&control);
try visor.morse.mouse(&w, .{ .motion = .press });
```
<!-- END GENERATED -->

Three more examples are built and run by the same command.
[`examples/viewer.zig`](examples/viewer.zig) is a file viewer on the widgets —
a sidebar, a scrollbar, a status line and a resize —
[`examples/gallery.zig`](examples/gallery.zig) draws every widget once, and
[`examples/progress.zig`](examples/progress.zig) is a screen of two rows at
the prompt, in inline mode, that prints finished steps above itself, grows
to three and leaves its last frame in the history.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/visor
```

```zig
const visor_dep = b.dependency("visor", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("visor", visor_dep.module("visor"));
exe.root_module.addImport("visor.widgets", visor_dep.module("visor.widgets"));
```

One fetch, three modules. `visor` is the grid and the renderer;
`visor.widgets` is the layout solver and the widgets, and a program that wants
only the base leaves the second line out. `morse` comes with it, re-exported
as `visor.morse`, and is also available as `visor_dep.module("morse")` for a
program that wants the writers on their own.

Three dependencies: [`morse`](https://github.com/pedronaugusto/morse) for
every escape sequence written and every reply parsed,
[`conduit`](https://github.com/pedronaugusto/conduit) for the terminal's own
calls — raw mode and the way back, the size, the device's name — of which only
its `conduit.tty` module is imported, which on Linux links no C library, and
`uucode` for grapheme segmentation and width. All are pinned by commit. `uucode` builds its tables
at build time, and visor asks for six fields and no more — `grapheme_break`
and `grapheme_break_no_control` for where one cluster ends and the next begins,
`wcwidth_standalone` and `wcwidth_zero_in_grapheme` for what a codepoint is
worth on its own and inside a cluster, and `is_emoji_modifier_base` and
`is_emoji_vs_base` for skin tone and the presentation selector. That is one
slow first build and then a cached table. A program that configures `uucode`
itself should keep these six and add its own, or the two configurations build
two sets of tables.

**Allocation.** One allocator, taken at `Screen.init` and `Renderer.init`.
`draw` allocates nothing. With `commit = false`, `print` only measures and
allocates nothing. Committed printing and `Screen.write` can allocate for a
grapheme longer than six bytes the screen has not seen before, and say so
with a `try`. Interning new links, pool compaction and resizing can allocate.
The owned-copy helpers allocate through the copy's allocator.

Text and link targets returned by the screen are borrowed. Inline text
lives in its cell; pooled text and targets live in growable pools, so
interning unrelated text or links can invalidate their slices even when the
cell is unchanged. Compaction, resize and deinitialization can invalidate
pool slices too. `dupeTextAt` and `dupeTextOf` make copies the caller frees
with the copy's allocator; `dupeTarget` returns an `OwnedTarget` whose
`target()` lends const URI and params and `deinit` frees them. These copies survive later drawing.

## The API

| | |
|---|---|
| The grid's contents | `Cell`, `Cell.Text`, `Cell.Kind`, `Cell.Shape`, `Style`, `Color`, `Underline`, `Link`, `Target`. |
| Colours as the terminal shows them | `Palette` — `ask`, `update`, `resolve`, `known` — `Rgb`, `mix`. |
| The grid | `Screen` — `init`, `deinit`, `dimensions`, `resize`, `copyCell`, `readCell`, `rowAt`, `diff`, `cell`, `writeOwnedCell`, `writeOwnedCellUnchecked`, `write`, `writeScaled`, `fill`, `clear`, `scroll`, `intern`, `link`, `compactPool`, `damageAll`, `window`, `textAt`, `textOf`, `target`, `dupeTextAt`, `dupeTextOf`, `dupeTarget`, `headOf`, and the fields `cursor`, `pointer`, `method`. `Cursor`, `Damage`, `Span`. |
| The views | `Window` — `screen`, `rect`, `ink`, `child`, `sub`, `inked`, `print`, `printSegment`, `copyCell`, `readCell`, `writeOwnedCell`, `writeOwnedCellUnchecked`, `write`, `writeScaled`, `fill`, `clear`, `scroll`, `width`, `hit`, `linkAt`, `copyText`, `showCursor`, `hideCursor`, `setCursorShape`, `cols`, `rows`, `size`. `Window.Segment`, `Window.Print`, `Window.PrintOptions`, `Window.ChildOptions`, `Window.Border`, `Window.Ink` and its `Stroke`. `Rect`, `Point`, `Size`. |
| Measuring text | `Method`, `Wrap`, `Graphemes`, `width`, `graphemeWidth`, `Parts`, `combinesOnly`, `disagrees`, `wrap`, `Row`, `fit`, `fitEnd`. |
| The render pass | `Renderer` — `init`, `deinit`, `dimensions`, `entered`, `resize`, `draw`, `printAbove`, `repaint`, `repaintRow`, `enter`, `setCaps`, `setModes`, `untrustCursor`, `leave`. `Renderer.Stats`, `Renderer.PrintError`, `Mode`, `Modes`. |
| What the terminal can do | `Caps`, `Caps.Pictures`, `Caps.pictures`, `Caps.termProgram`, `Caps.Probe` — `init`, `questions`, `capabilities`, `hasAnswered`, `lastAnswerMs`, `write`, `feed`, `complete`, `settled`. |
| Pictures | `Image`, `Image.State`, `Layer`, `Layer.Order`, `Layers` — `init`, `deinit`, `images`, `declarations`, `placements`, `hasFrameWork`, `answerPolicy`, `fallbackCount`, `configureSharedMemory`, `configureSize`, `storeSixel`, `storeIterm`, `inlineChanged`, `transmit`, `ready`, `ack`, `free`, `freeAll`, `retire`, `declare`, `undeclare`, `image`, `clear`, `repaint`, `count`, `emit`, `commitFrame` — `Transmit`, `Replacement` — `send`, `settle`, `declare`, `canSend`, `current`, `pending`, `takeDirty`, `retire` — `ImageIds`. |
| This program's terminal | `Tty` — `open`, `adopt`, `close`, `raw`, `restore`, `enter`, `leave`, `size`, `writer`, `read`, `inputFile`, `ioContext`, `watchResize`, `unwatchResize`, `resized`, `resizeFile`, `drainResize`. `restoreGlobal`, `Panic`. `Input` — `init`, `next`, `nextWithin`, `mousePixels`, `setMousePixels`, `Input.Options`. `Winsize` — `cellSize`, `locate`, `update`, `resized` — `Pixels`, `CellSize`, `MouseLocation`. `Session`, `ProbeWait`. |
| Testing your own screens | `Term` — `init`, `deinit`, `setMethod`, `feed`, `screen`, `position`, `savedCursor`, `graphics`, `resize`, `dump`, `dumpStyles`. `expectScreensEqual`, `dumpScreen`, `dumpScreenWith` and `DumpOptions`, `dumpScreenStyles`, `firstDifference`. |
| Everything under it | `visor.morse`, whole. |

### `visor.widgets`

| | |
|---|---|
| Layout | `Layout` — `horizontal`, `vertical`, `split`, `splitFixed`, `repeat`, `fitCount`, and the fields `direction`, `constraints`, `spacing`, `margin`. `Constraint` — `fixed`, `percent`, `min`, `max`, `fill`. `Direction`, `Padding`, `Align`, `place`, `offset`. |
| The widgets | `Block` (borders, corners, titles, padding, and the window inside), `Paragraph` (wrap, alignment, scroll, `Rows` iterator), `Markdown` (owned `Document` with its `cells` and `alignments`, caller `Theme`, `Rows` iterator with `columns`, `TableLine`, `Quoted` line iterator, wrap, scroll, code scrolling, GFM tables and task lists), `Edges` (styled items at both edges of a row), `List` — `draw`, `visible` — with `List.State`, `List.Segment` and `List.Visible`, `Table` — `draw`, `visible` — with `Table.State`, `Table.Row` and `Table.Visible`, `Tree` — `draw`, `visible`, `rowCount`, `rowOf`, `nodeAt`, `parentOf`, `hasChildren`, `isShown`, `shownAncestor`, `firstShown`, `lastShown`, `nextShown`, `previousShown` — with `Tree.Node` (depth, and open as the program keeps it), `Tree.State` (`next`, `previous`, `first`, `last`, `parent`, `child`), `Tree.Guides`, `Tree.Symbols` and `Tree.Visible`, `Tabs`, `Gauge`, `LineGauge`, `Sparkline`, `BarChart`, `Chart`, `Scrollbar` and `Scrollbar.State`, `Canvas`, `Calendar`, `TextInput` (layout, selection drawn in its own style) and `TextInput.State`, `TextInput.Buffer` — `init`, `initText`, `deinit`, `text`, `cursor`, `selection`, `selectedText`, `input`, `target`, `move`, `moveRows`, `moveTo`, `selectAll`, `selectNone`, `insert`, `delete`, `replaceAll`, `reset`, `undo`, `redo`, `canUndo`, `canRedo`, `seal`, `clearHistory`, and the field `history_limit` — with `TextInput.Buffer.Motion` and `TextInput.Range`, `Keys`, `Rule`, `Sextants`. Beside them: `Item`, `Line`, `Bar`, `Dataset`, `Axis`, `Marker`, `Date`, `sextant`. |
| Scrolling | `Scroll` and `Scroll.State`: which rows of something longer a view shows, held still while it grows. |
| The base, re-exported | `widgets.visor`, so a file that draws does not need both imports. |

### Canvas

`Canvas` draws points, lines, rectangle outlines, circles, discs, polylines
and maps in plot coordinates. A map is a slice of separate contours supplied
by the caller; there is no bundled geographic dataset. The existing
`painter(window)` writes cells immediately, with braille, sextants, blocks,
half blocks, dots or bars. Its y bounds name the bottom and top.

```zig
const widgets = @import("visor.widgets");
const canvas: widgets.Canvas = .{
    .x_bounds = .{ 0, 100 }, .y_bounds = .{ 0, 100 }, .marker = .sextant,
};
const shapes: []const widgets.Canvas.Shape = &.{
    .{ .geometry = .{ .circle = .{ 50, 50, 30 } },
       .paint = .{ .rgba = .{ 255, 200, 0, 255 } } },
    .{ .geometry = .{ .line = .{ 0, 0, 100, 100 } },
       .paint = .{ .blend = .additive } },
};
try canvas.draw(window, shapes, .{}); // cells

var surface = try widgets.Canvas.Surface.init(gpa, 640, 320);
defer surface.deinit();
try canvas.draw(window, shapes, .{
    .caps = caps,
    .picture = .{ .surface = &surface, .layers = &layers,
                 .writer = writer, .image = image_id },
});
```

With kitty or sixel graphics and picture resources, `draw` clears the surface,
rasterizes antialiased shapes and transmits and declares a picture beneath
text through `Layers`. Without them it draws the same shapes as cells.
Paint width is in output pixels; cell marks remain binary and use paint's
RGB foreground. Pixel blending is straight-alpha source-over (`normal`)
or saturated RGB light and alpha sums (`additive`). No glow or colour
policy is built in. Invalid coordinates draw nothing; strokes are clipped
before pixel iteration, including coverage just outside the plot.

The caller owns the surface, image ids and retirement. For repeated frames,
`canvas.raster(&surface)` paints without clearing or sending: pass its RGBA
`pixels()` and `dimensions().width` / `dimensions().height` through
`Replacement.send` and declare the replacement as usual. This keeps picture acknowledgements and swaps with
the same owner as every other picture. Surface owns its allocator, dimensions
and storage; `pixels()` lends const bytes
and `pixelsMut()` lends bytes for editing. `resize(width, height)` prepares a
cleared allocation before changing dimensions. Surface pixels stay borrowed
until `resize` or `deinit`; no painter reallocates them. `Sextants` weights picture brightness
and foreground RGB by alpha when showing an RGBA picture in cells. `examples/gallery.zig` draws cells
and rasterizes pixels with these primitives.

### Markdown

`Markdown.Rows.init(&document, cols, method)` iterates the exact rows used
by drawing and `rowCount`. Each row carries `start`/`end` ranges into
`document.text()`, borrowed `text` and overlapping `spans`, `block_index`,
`first`, and a `block` value describing its kind, quote `depth`, list
`marker`, `indent`, `task`, heading level, `table` and optional opening
`fence` (character, count and info string). Borrows live until the Document is deinitialized;
iteration allocates nothing. Code rows remain verbatim and unwrapped.

`Markdown.Document` reads text once and owns its source and runs. Its
`source()`, `text()`, `spans()` and `blocks()` return const slices borrowed
until `deinit`; span and block ranges index `text()`. A widget
borrows it, takes a `Theme`, and draws to the window's width. `rowCount(cols,
method)` uses the same rows as `draw`, without allocation. Keep the document
until its widgets are finished, then call `deinit`. Drawing can allocate for
screen links and long graphemes, but never for parsing or layout.

`Markdown.Quoted.init(source)` reads a source line by line by the same quote
and fence rules, for a program that shows it line by line: `next()` gives each
line's `text`, its `body` with the quote markers off, its quote `depth`, and
whether it is `code` in a fenced block (with the `fence`, and whether the line
`opens` or `closes` it). It borrows the source and allocates nothing.

```zig
var document = try widgets.Markdown.Document.init(gpa,
    "# Notes\n> A **strong** point and [a link](https://ziglang.org).\n"
    ++ "\n- first item\n- second item\n\n```zig\nconst x = 1;\n```",
);
defer document.deinit();
const markdown: widgets.Markdown = .{
    .document = &document,
    .theme = .{
        .heading = @splat(.{ .bold = true }),
        .strong = .{ .bold = true }, .emphasis = .{ .italic = true },
        .code = .{ .dim = true }, .inline_code = .{ .reverse = true },
        .link = .{ .underline = .single }, .quote = .{ .dim = true },
    },
    .scroll = 0,
};
try markdown.draw(window);
const rows = markdown.rowCount(window.cols(), screen.method);
```

The reader accepts the following subset; it is not CommonMark:

- Paragraphs join adjacent source lines with a space and wrap at words,
  splitting long words only between grapheme clusters. Blank lines keep a
  blank row. Inline markup is read within each source line.
- One to six leading `#` characters followed by a space or end of line make
  a heading.
- Repeated `>` prefixes, after at most three spaces, make nested quotes.
  Each level draws a bar and a space, including on wrapped rows. At narrow
  widths bars clip and leave no room for text.
- `-`, `+`, `*`, or up to nine digits followed by `.` or `)`, then a space,
  make list items. Space indentation nests them; wrapped and indented
  continuation lines use the marker's hanging indent. Markers keep their
  spelling. Four spaces or a leading tab otherwise start indented code.
- Three or more backticks or tildes open fenced code. A closing fence uses
  the same character, at least the opening length, and only spaces after
  it. Fence lines and language labels are hidden; unfinished fences keep
  reading code. In a quoted fence only its container prefixes are removed.
- Code is verbatim and clipped, never wrapped or parsed as prose. Tabs draw
  to four-column stops. `scroll_columns` scrolls code between whole clusters.
- Paired `*` or `_` give emphasis; doubled markers give strong emphasis.
  These may nest, up to 32 levels. Underscores inside words stay literal.
  Backtick spans use matching run lengths and keep their content literal.
  Backslash escapes ASCII punctuation. Unmatched markers remain text.
- `[label](target)` links accept balanced target parentheses and no whitespace
  or title; labels can carry inline styles. `<http://…>` and `<https://…>`
  are autolinks. They become OSC 8 links through `Screen.link`. Targets with
  terminal control bytes remain unlinked text.
- Three or more matching `-`, `*` or `_` characters, with optional spaces
  between them, draw a horizontal rule.
- A list item whose text begins `[ ]`, `[x]` or `[X]` and a space is a task;
  the block's `task` says whether it is done, and the mark draws as `[ ]` or
  `[x]` in the `task` or `task_done` style, wrapped text hanging under the
  item's text.
- A row with a pipe in it and under it a delimiter row of as many cells (at
  least one hyphen each, a colon at either end for the alignment) begin a GFM
  table. Every line after them is a row up to a blank line or the start of a
  heading, rule, list item, quote level or fence; a row with fewer cells gets
  empty ones and one with more loses the extra. `\|` is a pipe in a cell,
  inside a code span too. The reader keeps the cells in `Document.cells()`
  and the alignments in `Document.alignments()`; a `table` block says where
  its own begin. The spec's table and task list examples (GFM 0.29,
  198–205 and 279–280) are part of the suite.
- A table draws its columns side by side, `│` between them and a `─┼─` rule
  under the header, in the `table_header` and `table_border` styles. Each
  column is as wide as its widest cell when they all fit; otherwise columns
  narrower than an even share keep their width and the rest share what is
  left, their cells wrapped at words and every row as tall as its tallest
  cell. Rows carry a `table` line saying which row and which of its lines
  they are, and `Rows.columns()` the widths. The first `table_columns` (64)
  columns are drawn.

There are no images, HTML, reference links, setext headings, footnotes,
strikethrough, autolinks without angle brackets, syntax highlighting or
filesystem link resolution.
Unsupported syntax stays text. The caller supplies every style; the default
roles are neutral. Inline roles add enabled attributes to their block's
style and replace colours they set. Quote, marker and rule roles style their
own structural marks. `examples/gallery.zig` includes a themed document.

## Design

`Date.init(year, month, day)` checks Gregorian month and day invariants and
returns `InvalidDate` for a date that does not exist. `year()`, `month()` and
`day()` read its components; today and selected days use these checked values.

`dumpScreenStyles` writes padded base-62 IDs, most significant digit first.
Every ID in the legend and grid uses the fewest digits needed for the whole
legend: one through 62 styles, two through 3,844, and more for larger legends.

**A stored cell is thirty-two bytes and is compared as memory.** The grapheme lives
in the cell when it is six bytes or fewer, which covers every
single-codepoint cluster and a base with a combining mark, and in a pool the
screen owns when it is longer. The style is `morse.Style`, which has a
defined layout and no padding, so a whole row is one `memcmp` rather than a
field comparison per cell. Nothing in a cell is undefined, and a colour's
unused channels are zeroed on the way in, so comparing the memory and
comparing the meaning are the same answer.

A checked cell copies forty-eight bytes and binds pooled text and links to their issuing generation; the grid keeps thirty-two bytes per cell.
`Screen.diff` yields changed positions without copying checked cells; `Row.diff` yields changed columns and `Row.eql` compares whole rows. They use the same pool identity semantics as `Cell.eql`: equal pooled contents in different generations differ. The iterators borrow both screens until iteration ends; neither screen may change, compact, resize or be destroyed during that borrow.

Cells read from the screen carry checked text and link handles. The grid and
renderer store compact cells; Screen owns their pool identity. Screen and
Renderer geometry is read through `dimensions()` and changed through `resize`.
Term owns its grid, allocator and stream state. `screen()` and `graphics()`
lend read-only views; `position()` and `savedCursor()` return copied positions.
Feed bytes and resize through the terminal so its cursor, links and grid stay
together.

Session owns coordinated size, capabilities and probe progress. Read them
through `windowSize()`, `capabilities()` and `probe()`; change them through
`handle`, `resize` and `setCaps`. `screen()`, `renderer()` and `layers()` lend
the component owners for painting, terminal entry and pictures. Session owns
their lifetime and coordinated resize.

Renderer pen, cursor, width method, frame flags and cleanup intent are internal.
`entered()` returns a copy of the requested configuration, including partial
entry. A second live `enter` returns `AlreadyEntered` before writing or changing
state; leave before entering again. `Session.enter` also preserves the parser
on refusal. Use `enter`, `setModes`, `setCaps`, `repaint` and `untrustCursor` to
change terminal state.

Allocation, pool identity, damage and renderer work buffers are internal
`_` storage, owned by their initialized value. Row access returns
a borrowed row with `len()` and checked `get(col)` values; writes go through
Screen rather than mutable row slices. Pooled handles carry their issuing generation. Compaction
and resize invalidate retained handles; another screen cannot use them.
`textOf`, cell writes, fills and copies return `InvalidHandle` before using a
stale or foreign handle; `target` returns null. Inline text and `Link.none`
are portable. Use `copyCell` with the source screen to transfer a live cell,
or the owned-copy helpers to keep content through compaction. Raw pools and
renderer baselines are internal storage, with `_` field names. Raw pool
constructors and raw text resolution are not public APIs.

Raw `Cell` and `Cell.Text` values are untrusted input. `Screen.cell(value)`
checks one printable UTF-8 cluster, its shape and pool handles and returns a
canonical cell or `InvalidCell` / `InvalidHandle`. Checked placement, fills
and copies apply the same precondition before changing the grid. `write`
and `writeScaled` ignore empty input and initial controls, and reject
nonprinting or multi-cluster glyphs; invalid UTF-8 is still replaced with the replacement character. `intern` stores
bytes; validation happens when those bytes become a cell.

`Screen.writeOwnedCellUnchecked` and its Window counterpart are the bridge
for another terminal's measured cells: handles stay checked, while the
caller guarantees the glyph, shape and canonical text bytes. The source
terminal's width is kept even when the parent would measure it differently.

`Window` checks the whole glyph or scaled cell extent before direct writes
and copies. Multi-cell fills use the fill rectangle as their boundary.
A placement that cannot fit leaves the grid alone.

`Screen.link` refuses C0 controls and DEL in a URI or params with
`error.ControlInText` before interning. Ordinary UTF-8 is kept unchanged.

`Layers.init(allocator)` captures the allocator for its images, placements and
compression storage. `transmit`, `declare`, `retire` and `deinit`, and the
`Replacement` operations using those layers, take no allocator. Metadata
accessors return borrowed, read-only slices; fields prefixed `_` are internal.

`Layers.configureSharedMemory(io)` allows pictures through shared memory;
pass null to disable it. The same Io preserves the terminal's learned answer.
Each outstanding object owns its cleanup Io, so changing configuration cannot
lose cleanup, and an older object's reply cannot settle a new configuration.
The Io must outlive those objects. Names come from one atomic process-wide
namespace and are never reused.

Window keeps its screen and clipped rectangle together behind `screen()` and
`rect()`. `ink()` borrows the drawing policy. Construct views through `Screen.window()`, `child` and `sub`, and
apply ink through `inked`. Recreate windows after their screen is resized.

Damage owns its row storage behind marking and clearing methods; `rowCount()`
returns its extent. Its allocation API is unmanaged: pass the init allocator
to `resize` and `deinit`.

Text and visual-row iterators keep their source, cursor and refill state
internal. Construct them through `init` or `TextInput.rows`, and advance
through `next` / `nextAt`. Reconstruct an iterator to start another traversal.

**Damage is conservative.** A write marks a cell only when it changes it. If
another write restores the displayed value before drawing, the mark remains:
the screen does not duplicate the renderer's previous-frame baseline. The
renderer compares every named row with that baseline and emits nothing when
the row was restored. The grid fuzz checks that damage never under-reports.

**Changed cells go out as runs.** A contiguous run gets one cursor move and
one style pen. Across an unchanged gap, the renderer counts the bytes for its
text, style and link transitions through the next changed cell and compares
them with the shortest cursor move; the cheaper path decides whether the run
continues.

**A row is written whole when the diff would cost more.** Both are priced by
counting their exact text, style, link, erase and cursor-move bytes, so the
choice takes no extra emit pass.

The renderer caches 1,024 SGR transitions in buckets of sixteen, checking
both styles on every hit. Recurring RGB transitions can share a bucket
without replacing one another; full buckets replace entries in turn.

**A blank run is erased, not painted.** A row blank to its end is `EL`, four
bytes whatever the width; a blank run longer than the sequence that erases it
is `ECH`, which leaves the cursor where it was.

**A run of one glyph is the glyph and a count.** Where the terminal has `REP`,
a rule, a gauge or a row of padding goes out as one glyph and a repeat, when
the count saves more than it costs. A cluster of more than one codepoint is
never repeated, because what a terminal repeats after one is its last
codepoint.

**The cursor move is a search.** Every candidate is costed in bytes — the
absolute move, the column, the row, the four relative moves, the carriage
return, and backspaces — and the shortest wins, with the absolute move as the
tie-break, because it is the one that is right whatever the terminal did with
the last one.

**Measured by codepoint, the grid holds what such a terminal shows.** A
terminal that measures by codepoint gives every codepoint that takes columns
cells of its own and joins the ones that take none to the cell before them,
so the astronaut that is a woman, a joiner and a rocket is a woman in two
columns and a rocket in the next two. `graphemeWidth` counts it that way and
`Screen.write` puts such a cluster in those cells, so the grid never claims a
cluster in two columns that the terminal spreads over four.

**Measured by cluster, cells drawn apart stay apart.** A terminal in mode
2027 joins a codepoint to the cell on the left of the cursor wherever the
break rules find no break, whatever was drawn when: a regional indicator
beside another is a flag, a skin tone beside a thumb is that thumb's tone,
and a spacing mark joins anything. A cell that would join its neighbour goes
out with the mode off around it, so the terminal measures it by codepoint and
gives it a cell of its own, and such a codepoint is never repeated with `REP`.

**A row the terminal might measure differently is never diffed.** Whether the
two width models disagree about a cluster is worked out once, when the cell is
written, and a row holding one is repainted whole from an absolute position
with the cursor not trusted afterwards — because an over-measured cluster runs
past the margin and wraps, so the following rows are a row out as well as a
column. A change of width method repaints every row that has ever held one.
Under mode 2027 the models agree and the re-anchor is skipped. Where the
terminal takes the text sizing protocol, the cluster goes out with its width
stated instead, and the row is diffed like any other; `.explicit` states the
width of everything but ASCII, and the terminal's own tables stop mattering.

**Wide graphemes are in the grid, not inferred at render time.** A wide
cluster is a head and a covered column, always adjacent; overwriting either
repairs the other; one with a single column left becomes a spacer, which the
diff can tell from a space someone asked for.

**Scaled text is a block the grid knows about.** `writeScaled` draws a
grapheme at up to seven cells' height through the text sizing protocol: the
head and a block of covered cells, as many rows tall as the scale and as many
columns wide as the scale times the width. Writing into any cell of the block
clears the whole of it, as a terminal does; the renderer writes the head as
one sequence and never touches the block; and on a terminal without the
protocol the grapheme is drawn at its own size with the rest of the block
blank.

`fitEnd(text, cols, ellipsis, method)` keeps the suffix, cut at a grapheme
boundary, with room for a leading ellipsis. As with `fit`, write the ellipsis
yourself only when the returned slice is shorter than the input.

**Inline mode addresses nothing by row number.** A screen entered inline
takes its rows from the row the cursor is on, the terminal scrolling for the
ones that do not fit, and saves an origin there with `DECSC`. Every move after
that is relative — to the cursor, or to the origin restored when the cursor
is not trusted — and the cheaper of the two is what is written. Growing
takes more rows the same way, shrinking gives them back blank, and `leave`
puts the cursor on the row below with the last frame still showing. A
scrolling region is an absolute thing, so scroll detection is off.

`Renderer.printAbove(writer, lines, screen, layers, caps)` prints rows above
an inline screen in the same frame that draws it: a line of log, a task that
finished, a message done changing, above a view that is still live. The rows
of `lines`, a grid as wide as the screen drawn with any window or widget, are
written from the origin down, each ended by a carriage return and a line feed,
so rows that reach the bottom of the terminal scroll it and go up into its
scrollback like any other output; the screen's rows are then taken again under
them and the screen drawn against the blank rows it stands on, priced as any
frame is. Outside inline mode it returns `NotInline` and writes nothing.

**The way out undoes the way in, and nothing else.** `enter` takes the
screen and the input modes the program asked for; `leave` turns off exactly
those, in reverse. The kitty keyboard flags are a stack per screen, so they
are pushed after the switch to the alternate screen and popped before the
switch back. The mouse is one motion and one encoding, as the terminal keeps
it: `enter` puts it in exactly the state asked for, whatever was on before,
`setModes` changes only the setting that differs, the old mode off before the
new one on, and `leave` turns off that motion and that encoding. Focus
reports are a mode of their own. A screen entered through `Tty.enter` is
undone by `Tty.leave()` or `restore`; `restoreGlobal` and the panic handler
restore every registered terminal from a buffer on the stack.
`Tty` owns its descriptors, saved mode, renderer borrow and resize watcher.
`ioContext()` returns the captured Io by value; use its methods for lifecycle
changes. Keep `Tty` at a stable address, and its entered renderer alive and at a stable
address until restoration. Call terminal registration and restoration from
one thread. A program that dies leaves the shell with its keyboard, its
mouse and its cursor.

**Synchronised output brackets a frame, not a session.** Mode 2026 left on for
a program's lifetime makes the terminal repaint at whatever timeout it
invented, which is ten frames a second on the tightest of them. `draw` writes
the bracket, into its own buffer, and keeps it only when the frame turns out
too large for the terminal to take in one read; `leave` writes the closing
half whether or not it wrote the opening one.

**The grid is text; the pictures are beside it.** A `Screen` holds cells
and nothing else, and a program that shows pictures keeps its `Layers` next
to it and hands both to `Renderer.draw`, which is the one that orders them.

`Caps.pictures()` chooses kitty, iTerm2, sixel, then cells. Set
`Caps.picture_protocol` to override that order, including forcing cells.
The probe learns sixel from DA1 attribute 4, its register count and pixel
limits from XTSMGRAPHICS, and iTerm2 from XTVERSION. A caller honoring the
environment passes its `TERM_PROGRAM` value to `caps.termProgram(value)`;
only `iTerm.app` enables iTerm2. Visor reads no environment itself.

`Layers.storeSixel(id, image)` retains a copy of morse's pixels and palette;
`Layers.storeIterm(id, file_bytes, part_bytes)` retains an encoded PNG, JPEG
or another terminal-supported file. Zero `part_bytes` uses one OSC; a
nonzero value uses morse's multipart writer. Declare and retire these ids
through the same `Layer` and `Layers` methods as kitty pictures. Encoders
and protocol byte counts remain morse's; visor adds no protocol encoder.
Pass `Layers.configureSize(winsize)` the probe's geometry before drawing;
`Session.layers()` supplies its current size. Sixels are clipped to the
placement's explicit cell rectangle and terminal pixel limits, using
`Winsize.cellSize()`; unknown pixel geometry suppresses sixels. Their
source rectangle crops pixels before morse quantizes to the supported
palette. iTerm2 files are fitted to the explicit cell rectangle, clipped
to the grid, without preserving aspect ratio. Neither inline path supports
pixel placement offsets; supply a prepared image and a nonzero rectangle.

Inline pictures are stored here rather than in a terminal id. A changed
placement or text damage invalidates the text baseline, restores the grid
and sends every declared inline picture again after the text pass. This
also handles removal, scroll, resize, repaint and failed output. An
unchanged frame still writes nothing. These protocols paint over the
cells they occupy; `under` orders inline pictures but cannot put them
under independent text as kitty does. Sixels reserve the bottom row when
cursor-right mode is unavailable. With reported mode 8452 support,
`Renderer.enter` enables it and `leave` undoes it. Inline files request
`doNotMoveCursor`; the renderer restores its own cursor after either path.
`Canvas.Picture.sixel_palette` supplies the palette when a canvas chooses
sixel. An iTerm2 canvas uses the cell fallback; an application with an image
file places it through `storeIterm`.

**The text pass never writes a graphics command and never deletes a
kitty placement.** A picture that moves is re-placed under the same image and
placement id, which the protocol replaces without flicker; one that leaves is
deleted by name after the frame's placements, with its pixels kept, so a
picture swapped for another is covered before it goes. `Layers` sends the
pixels too — chunked, deflated when that helps, quiet unless asked — and frees
them, so a program writes no graphics command of its own. Nothing waits on the
terminal's word unless asked to: an image sent quietly is shown at once.
A direct transmission asking for an answer is shown on the answer or when the
caller's grace period runs out, and a terminal that never answers is not waited
for twice. A shared-memory trial needs its own answer; silence refuses that
picture and releases its object.

`Replacement` keeps a current picture while a new one is in flight. Share an
`ImageIds` range between replacements, with the probe's graphics id excluded.
Construct it through `init` and issue ids through `acquire`; bounds and the
allocation cursor are internal.
`send` takes pixels and transmit options; `declare` takes the placement and
caller-supplied time and grace. Pass graphics replies to `Layers.ack` and call
`declare` again. Its result says another frame is needed while waiting;
`current()` and `pending()` return copied ids; ownership changes through the
replacement methods. `takeDirty` asks for new pixels after a refusal. A swap places the new picture,
drops the old placement, then frees its pixels inside `commitFrame(w, caps)`.
The renderer calls that itself; callers of `emit` call it after their frame
reaches the writer. Failed writes retain retirement for the next attempt.

**A picture on the same machine goes through shared memory.** With
`Layers.configureSharedMemory(io)` called, the pixels are put in a shared memory object and
only its name goes through the terminal's input: no deflate, no base64, and a
picture that cost a frame costs a copy (a full-screen picture on a 4K display,
from about 15 ms to under 3). The first one asks for an answer; an error, or no
answer within the grace period, turns the medium off for this configuration, and that picture
is refused so the program sends it again in the escape code, which is what a
terminal on another machine, over ssh, gets from then on. An object the
terminal did not read is unlinked, never left behind.

**After a resize, nothing on the terminal is taken as known.** A terminal
that changes size keeps what fitted, cuts it, moves its rows up with the
cursor, or takes in a frame drawn at the old size after it changed, and says
nothing about which. So `Renderer.resize`, like `repaint`, forgets the
previous frame: the next `draw` writes every row whole, a row with nothing on
it erased to the end of the line rather than taken to be blank already, and
places every picture again, a placement with the same ids replacing the one
the terminal kept wherever it went. There is no erase of the whole display
first, because that takes every picture down with it. A program that hears of
its size in band (mode 2048) hears of it after the terminal's grid changed,
so its next frame lands on the new grid. The signal can come before the grid
changes, and a frame drawn in that gap stays wrong until the next repaint, so
`enter` turns 2048 on wherever `Caps.in_band_resize` says the terminal has
it.

`Renderer.setCaps(w, caps)` changes capabilities while the screen stays in
place, writing only the mode differences and repainting on the next draw.
Leaving and entering a renderer that has drawn also repaints text and pictures.

**A cell's pixel size is the terminal's word, not a division.** The
operating system and a resize report give the text area, which a terminal may
pad, so the area divided by the grid is a little too large and the error grows
toward the right edge. `Winsize` keeps the area and the cell apart, takes the
cell only from the terminal's answer to `CSI 16 t`, and when it has to divide
it says so.

`Winsize.locate(mouse)` returns its zero-based column and row and fractions
`x` and `y` within that cell. Pixel reports use the fractional `CellSize`;
cell reports point to the middle. Unknown pixel size returns null.

**Input is morse's events, read.** `Input.next` reads the terminal, frames
the bytes with `morse.KeyParser` and hands back the parser's events as they
are: a key, the mouse, and an answer to a question read as a typed `reply` —
a colour, a size, a mode, a graphics acknowledgement — which `Palette`,
`Winsize`, `Caps.Probe` and `Layers.ack` take as they come, so nothing is
parsed twice, nothing is dropped on the way and there is no second event
type. The lone `ESC` is settled on the caller's timeout, on Windows too; a
resize wakes the wait through a pipe the signal handler writes to and comes
back as the same `resize` event an in-band report is, with pixels. It starts
no thread and keeps no clock: it blocks on the caller's `std.Io`, and
cancelling the task it runs in is what stops it. `Input.nextWithin` is the
same read with the caller's deadline beside it, null when the deadline passes
in silence, which is how a probe's quiet period is waited out without a
second task or a cancelled read.

`Input.init` borrows both buffers and refuses an empty read buffer with
`error.EmptyReadBuffer`; use `try` when constructing it. The parser buffer
must hold at least `morse.KeyParser.min_buffer` bytes, and the read buffer
at least one. Both buffers and the `Tty` must outlive the reader.

**Nothing is guessed.** No terminfo, no capability database, and no
environment variable read — not `TERM`, not `COLORTERM`, not `NO_COLOR`.
`Caps.Probe` writes morse's probe and folds the answers in, including the
colour count `Co` into `Caps.colors`, and is settled
when every question is answered or, after the device attributes, when the
terminal has been quiet for the caller's quiet period; a caller who would
rather trust the environment configures a separate `Caps` value, or hands
`COLORTERM` and `NO_COLOR` to `Caps.guessColor`. Colours are drawn in what
`Caps.colorProfile` says the terminal shows: direct colour, the 256-colour
palette, the sixteen theme slots, or none. Every colour is fitted to it with
`morse.Color.fit` before it is compared or written, matched against the
terminal's own slots when `Palette.slots` has them. With nothing known it is
the 256-colour palette; direct colour needs evidence. Probe
questions and learned progress are internal; construct it with `init`, feed
answers, and read copied capabilities and `hasAnswered` / `lastAnswerMs`. A mode the terminal
answers set or reset is one it has: nothing has turned synchronised output or
in-band resize reports on when the probe asks, so a terminal that has them
answers reset.

`Session.init(gpa, winsize, questions)` holds the screen, renderer, `Winsize`,
`Caps.Probe` and `Layers` together. Its component methods lend the owners; size, capabilities and probe progress
are read through const queries.
Pass terminal events to `handle(w, event, now_ms)`, which says a frame is due;
keys and application policy are still yours. Housekeeping is retained if
capability output fails; a later event retries that output without replaying
the input. Drain the batch, call `resize(w)` once, paint `screen()`, then
`draw(w)` and flush your writer. Both grids follow
the last resize; an unchanged in-band report repaints too, and each resize
asks for the cell's pixel size again. `setModes(w, parser, modes)` keeps pixel
mouse parsing in step with the requested encoding. `setCaps` lets the caller
apply its own overrides after a probe answer. With `Input`, use
`renderer().setModes` and `Input.setMousePixels` together; `Session.setModes`
is the convenience for a caller-owned morse parser. Input keeps its parser,
buffers and unread bytes internal.

`ProbeWait.init(now_ms, timeout_ms, quiet_ms).remaining(probe, now_ms)` gives
the next read's budget, or null when done. It owns no clock or read: an early
key can be handled by the application while forwarded probe replies arrive.
`examples/live.zig` shows the loop; run it with `zig build live`. The examples
step runs its `--check` path without a terminal.

**A frame is one write.** `draw` writes to a `*std.Io.Writer` and never
flushes it, so batching is yours. `Stats.bytes` says how large the buffer
wants to be.

The writer is the caller's, and `draw` never flushes. Between frames, one-off
sequences must not paint, move the cursor, change SGR or a link, or change
tracked modes. Queries, clipboard writes and notifications fit that contract.
After moving the cursor, call `Renderer.untrustCursor()` so the next move is
absolute. Painting or changing SGR or a link also needs `repaint`; change
tracked modes through `setModes` or `setCaps` so `leave` can undo them.

**A widget is a value, and the caller keeps what survives the frame.** It is
built where it is drawn, handed a window, and gone by the end of the call.
What has to be remembered between frames — a list's selection, a table's
scroll, where a scrollbar is — is a separate struct the program owns and
passes by pointer; the widget reads it, moves it when the selection would
otherwise be off screen, and forgets it. There is no retained tree, no
callback and no focus model, so there is nothing to keep in step with the
program's own state.

**A program's look is an ink, not a pass over the screen.** A look that
depends on where a cell lands -- every other row faded, a region brought up
from the background -- or that watches what is drawn cannot be said in a
widget's style options, and drawing a widget on a scratch screen to restyle
its cells afterwards costs an allocation and a comparison of every cell. A
window may carry a `Window.Ink`, a function the program owns that turns the
style a cell was written in into the style it is drawn in, given where on
the screen it lands and what it holds. Children inherit it, every write goes
through it, and widgets know nothing of it. It is held by pointer so a
window stays three words, and with none a write pays one branch: on a page
of widgets that is below what moving the same code elsewhere in the binary
costs, which is as far as a measurement can see.

**Layout is splitting, not solving.** A rectangle is divided by fixed sizes,
percentages, floors, ceilings and shares of what is left, in one pass over
the constraints, with no allocation and no cache; splits nest because a part
is a rectangle like any other. A general constraint solver is a package of
its own.

## Scope

- **No widgets in the base.** They are a second module, which `visor` never imports.
- **No event loop and no threads.** A base layer that owns the loop cannot be used by a program that already has one. `Input` is a read, not a loop: the program decides where it runs and what an event means.
- **No widget whose substance is handling keys, focus or a clock.** Those are three quarters event handling, and the program has the loop. `Keys` shows which keys work and handles none; `TextInput` says where the cursor lands, and `TextInput.Buffer` does the edit a key asks for (insert, delete by a motion, select, undo, redo, on whole clusters), but which key asks for which is the program's.
- **No constraint solver.** Fixed, percent, floor, ceiling and share cover what a screen layer owes.
- **No colour degraded to a profile.** A program that asks for sixteen colours gets sixteen colours.
- **Pictures without decoding.** Kitty placements, sixel pixels and iTerm2 encoded image files share `Layers`; cell pictures use the widgets. Visor does not decode or encode image files. iTerm2 source cropping and pixel offsets must be applied by the caller before storage; inline protocols paint in declaration order and do not offer kitty's independent text-underlay placements.
- **Two places for a screen.** The alternate screen, or inline at the prompt, with rows printed above it into the scrollback. Inline mode knows no row of the terminal by number: it has no scroll detection, and after the terminal itself is resized its origin is wherever the terminal put the saved cursor.

## Platforms

| Platform | Tested |
| --- | --- |
| Linux | `ubuntu-latest` in CI, four optimize modes |
| macOS | `macos-latest` in CI, four optimize modes |
| Windows | `windows-latest` in CI, four optimize modes |

Everything but `tty` is arithmetic and bytes, so the same source builds
wherever Zig does; `zig build check -Dtarget=...` compiles both suites and
the examples without running them, and CI does that for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.
[`ci/linux.sh`](ci/linux.sh) runs the suite in Docker from any machine; it is
a local script and no CI job calls it.

`Tty` is the one file that reaches the operating system, through
`conduit.tty`, which owns the terminal's calls for this package and for
programs that run a child on a pseudo-terminal alike. It is compiled on all
three platforms in CI, and on Linux and macOS the suite runs it against a
pseudo-terminal conduit opens: the size with its pixels, entering and leaving,
the panic path's way back, and a resize waking `Input`. The Windows half is
compiled and not run.

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs both suites and the examples under
`std.testing.allocator`, so a leak or an invalid free fails the test rather
than the process, and CI runs it in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall on each of the three platforms.

The headline test is a round trip. Random grid operations are drawn, the bytes
are fed to the emulator this package ships, and the grid it rebuilt is
compared with the one that was drawn — cell by cell, covered columns included,
because a grid compared as a string is exactly where a covered column goes
missing. Four properties come out of the one generator: the terminal shows the
screen, a second draw writes nothing at all, a repaint recovers from a
previous frame corrupted on purpose, and a terminal given one repaint of the
final screen agrees with the terminal given every frame. All four run three
times: against a terminal measuring by codepoint, a terminal measuring by
cluster, and a terminal measuring by codepoint that is told every width,
because the rule that repaints a drifting row exists for the case where the
two disagree, and the protocol is the other way to settle it. The first three
run again for an inline screen, taken at a cursor the prompt left somewhere
down a taller terminal and growing and shrinking between frames, with the
rows above it and the cursor below it at the end checked too. And once more
across resizes: the terminal takes a new size first and keeps what fitted,
frames drawn at the old size land after it, a drag passes through sizes the
program never hears of, and the next frame at the size the program was told
must leave the terminal showing exactly the screen.

`zig build conformance` runs the same four properties again, over the same
inputs, against a terminal emulator that is not this one's. `Term` ships with
this package, so a property that compares the renderer with it compares two
readings of the same specifications by the same hand; the conformance build
compares the renderer with the terminal inside a shipping emulator, read
through its own grid — every column's grapheme, its width, its style and its
link, with two links that differ only by their `id` being two links. It is a
build of its own under `conformance/`, with its own manifest pinning that
emulator by commit, so nothing that builds a program on this package fetches
one. The resize property runs there too, against the emulator's own resize,
with pictures placed and moved across it and checked where the emulator has
them; and the probe's questions go to the emulator and its answers back. CI
runs it on Linux and macOS.

Every widget is tested the same way round: drawn into a grid, rendered to
bytes, fed to the emulator, and the picture the terminal shows compared with
the picture it should be — then drawn again, which must write nothing. A test
that asserts on the cells a widget wrote has proved half of what a program
runs.

The pictures get the same treatment: random placements, moves, deletions,
stacking changes and acknowledgements over the layers, with text drawn beside
them, checking that a frame with nothing new writes nothing, that the text
pass is whole before the first graphics command, and that a deletion happens
only for a picture that left and names it alone.

Input and typed text are fuzzed as well: random streams, pushed through a
pipe and read in pieces of every size, must come out of `Input` as the events
the parser makes of the whole stream; and random text — wide and combined
clusters, both kinds of line end, bytes that are not UTF-8 — must lay out in
`TextInput` with every byte in exactly one row and every cluster boundary a
place that leads back to itself. Random edits to a `TextInput.Buffer` must undo
back through texts it held, in order, to the first, and redo to the last; trees
of random shape, opened at random, must walk as a slow reading of the same
nodes says; random Markdown sources of pipes, delimiter cells, task marks and
inline markup must keep every range in bounds and draw the rows they count.

Rows printed above an inline screen are fuzzed against the emulator — any rows
on any screen at any place in the terminal read back above it — and run once
more against the second emulator with its scrollback on, where every row
printed must be found, in order, above the screen. The reader's tables and task
lists are held to the GFM spec's own examples, written back as the HTML
cmark-gfm writes.

Beside it: byte-exact tests on what each mechanism writes, a grid fuzz that
checks the invariants and the damage map after every operation, a
`checkAllAllocationFailures` pass on `init`, `resize`, `intern` and
`compactPool`, and budgets — a full repaint at 120×40 writes fewer than 8 100
bytes, a frame in which one cell changed fewer than 64, and a frame in which
nothing changed writes nothing. The generated corpus in `src/corpus.zig` runs
on every push, and both builds replay the same bytes; `zig build test --fuzz`
keeps searching beyond it. Every property reads its input through
`corpus.Dice`: under the fuzzer each answer is the fuzzer's, and on a replayed
entry the answers come from a generator the entry seeds. The standard
library's `Smith` answers a ranged question from eight bytes and gives the
lowest value whenever they are out of range, so random bytes asked for a size
answer one column and one row. Each property has a test beside it that
replays the corpus with its draws counted and fails unless they cover every
size, every operation and every grapheme it can ask for.

What a frame costs, measured here on a 200 by 50 grid of 10,000 cells, ReleaseFast
on an Apple M3 Max, best of five passes of a thousand frames each:

| Frame | Time | Bytes |
|---|---|---|
| The whole grid repainted | 170 µs | 43,404 |
| 100 cells changed at random | 69 µs | 4,047 |
| The grid scrolled one row, repainted | 267 µs | 43,304 |
| The same, with `Caps.scroll_detection` | 154 µs | 878 |
| A page of widgets drawn into a blank grid | 257 µs | 2,445 |
| Nothing changed | 0 | 0 |

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).
