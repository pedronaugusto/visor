# visor

[![CI](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml)

visor is a cell grid and a diff renderer for programs that draw their own
screen. You draw into a grid; it writes the shortest run of bytes that moves
the terminal from the frame it is showing to the one it should be showing. A
second module, `visor.widgets`, holds a layout solver and seventeen widgets
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
defer screen.deinit(gpa);
screen.method = caps.width_method;

var renderer: visor.Renderer = try .init(gpa, size);
defer renderer.deinit(gpa);

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

// Runs of styled text, wrapped. `print` never allocates and says
// where it stopped.
const link = try screen.link(gpa, "https://ziglang.org", "id=1");
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
the prompt, in inline mode, that grows to three and leaves its last frame in
the history.

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
After that the frame path takes none: `print` does not allocate and `draw`
does not allocate. `Screen.write` allocates only for
a grapheme longer than six bytes the screen has not seen before, and says so
with a `try`. Resizing allocates.

## The API

| | |
|---|---|
| The grid's contents | `Cell`, `Cell.Text`, `Cell.Kind`, `Cell.Shape`, `Style`, `Color`, `Underline`, `Link`, `Target`. |
| Colours as the terminal shows them | `Palette` — `ask`, `update`, `resolve`, `known` — `Rgb`, `mix`. |
| The grid | `Screen` — `init`, `deinit`, `resize`, `copyCell`, `readCell`, `write`, `writeScaled`, `fill`, `clear`, `scroll`, `intern`, `link`, `compactPool`, `damageAll`, `window`, `textAt`, `textOf`, `target`, `headOf`, and the fields `cursor`, `pointer`, `damage`, `method`. `Cursor`, `Damage`, `Span`. |
| The views | `Window` — `child`, `sub`, `inked`, `print`, `printSegment`, `copyCell`, `readCell`, `write`, `writeScaled`, `fill`, `clear`, `scroll`, `width`, `hit`, `linkAt`, `copyText`, `showCursor`, `hideCursor`, `setCursorShape`, `cols`, `rows`, `size`. `Window.Segment`, `Window.Print`, `Window.PrintOptions`, `Window.ChildOptions`, `Window.Border`, `Window.Ink` and its `Stroke`. `Rect`, `Point`, `Size`. |
| Measuring text | `Method`, `Wrap`, `Graphemes`, `width`, `graphemeWidth`, `Parts`, `combinesOnly`, `disagrees`, `wrap`, `Row`, `fit`. |
| The render pass | `Renderer` — `init`, `deinit`, `resize`, `draw`, `repaint`, `repaintRow`, `enter`, `setModes`, `leave`. `Renderer.Stats`, `Mode`, `Modes`. |
| What the terminal can do | `Caps`, `Caps.Probe` — `write`, `feed`, `complete`, `settled`. |
| Pictures | `Image`, `Image.State`, `Layer`, `Layer.Order`, `Layers` — `transmit`, `ready`, `ack`, `free`, `freeAll`, `declare`, `undeclare`, `image`, `clear`, `repaint`, `count` — `Transmit`. |
| This program's terminal | `Tty` — `open`, `adopt`, `close`, `raw`, `restore`, `enter`, `leave`, `size`, `writer`, `read`, `inputFile`, `watchResize`, `unwatchResize`, `resized`, `resizeFile`, `drainResize`. `restoreGlobal`, `Panic`. `Input` — `init`, `next`, `nextWithin`, `Input.Options`. `Winsize` — `cellSize`, `update`, `resized` — `Pixels`, `CellSize`. |
| Testing your own screens | `Term` — `init`, `deinit`, `setMethod`, `feed`, `screen`, `resize`, `dump`, `dumpStyles`. `expectScreensEqual`, `dumpScreen`, `dumpScreenStyles`, `firstDifference`. |
| Everything under it | `visor.morse`, whole. |

### `visor.widgets`

| | |
|---|---|
| Layout | `Layout` — `horizontal`, `vertical`, `split`, `splitFixed`, `repeat`, `fitCount`, and the fields `direction`, `constraints`, `spacing`, `margin`. `Constraint` — `fixed`, `percent`, `min`, `max`, `fill`. `Direction`, `Padding`, `Align`, `place`, `offset`. |
| The widgets | `Block` (borders, corners, titles, padding, and the window inside), `Paragraph` (wrap, alignment, scroll), `List` — `draw`, `visible` — with `List.State`, `List.Segment` and `List.Visible`, `Table` with `Table.State` and `Table.Row`, `Tabs`, `Gauge`, `LineGauge`, `Sparkline`, `BarChart`, `Chart`, `Scrollbar` and `Scrollbar.State`, `Canvas`, `Calendar`, `TextInput` and `TextInput.State`, `Keys`, `Rule`, `Sextants`. Beside them: `Item`, `Line`, `Bar`, `Dataset`, `Axis`, `Marker`, `Date`, `sextant`. |
| Scrolling | `Scroll` and `Scroll.State`: which rows of something longer a view shows, held still while it grows. |
| The base, re-exported | `widgets.visor`, so a file that draws does not need both imports. |

## Design

**A cell is thirty-two bytes and is compared as memory.** The grapheme lives
in the cell when it is six bytes or fewer, which covers every
single-codepoint cluster and a base with a combining mark, and in a pool the
screen owns when it is longer. The style is `morse.Style`, which has a
defined layout and no padding, so a whole row is one `memcmp` rather than a
field comparison per cell. Nothing in a cell is undefined, and a colour's
unused channels are zeroed on the way in, so comparing the memory and
comparing the meaning are the same answer.

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

**Inline mode addresses nothing by row number.** A screen entered inline
takes its rows from the row the cursor is on, the terminal scrolling for the
ones that do not fit, and saves an origin there with `DECSC`. Every move after
that is relative — to the cursor, or to the origin restored when the cursor
is not trusted — and the cheaper of the two is what is written. Growing
takes more rows the same way, shrinking gives them back blank, and `leave`
puts the cursor on the row below with the last frame still showing. A
scrolling region is an absolute thing, so scroll detection is off.

**The way out undoes the way in, and nothing else.** `enter` takes the
screen and the input modes the program asked for; `leave` turns off exactly
those, in reverse. The kitty keyboard flags are a stack per screen, so they
are pushed after the switch to the alternate screen and popped before the
switch back. The mouse is one motion and one encoding, as the terminal keeps
it: `enter` puts it in exactly the state asked for, whatever was on before,
`setModes` changes only the setting that differs, the old mode off before the
new one on, and `leave` turns off that motion and that encoding. Focus
reports are a mode of their own. A screen entered through `Tty.enter` is
undone the same way by `restoreGlobal` and the panic handler, from a buffer
on the stack, so a program that dies leaves the shell with its keyboard, its
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

**The text pass never writes a graphics command and never deletes a
placement.** A picture that moves is re-placed under the same image and
placement id, which the protocol replaces without flicker; one that leaves is
deleted by name after the frame's placements, with its pixels kept, so a
picture swapped for another is covered before it goes. `Layers` sends the
pixels too — chunked, deflated when that helps, quiet unless asked — and frees
them, so a program writes no graphics command of its own. Nothing waits on the
terminal's word unless asked to: an image sent quietly is shown at once, and
one sent asking for an answer is shown on the answer or when the caller's grace
period runs out, and a terminal that never answers is not waited for twice.

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

**A cell's pixel size is the terminal's word, not a division.** The
operating system and a resize report give the text area, which a terminal may
pad, so the area divided by the grid is a little too large and the error grows
toward the right edge. `Winsize` keeps the area and the cell apart, takes the
cell only from the terminal's answer to `CSI 16 t`, and when it has to divide
it says so.

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

**Nothing is guessed.** No terminfo, no capability database, and no
environment variable read — not `TERM`, not `COLORTERM`, not `NO_COLOR`.
`Caps.Probe` writes morse's probe and folds the answers in, and is settled
when every question is answered or, after the device attributes, when the
terminal has been quiet for the caller's quiet period; a caller who would
rather trust the environment sets the fields itself. A mode the terminal
answers set or reset is one it has: nothing has turned synchronised output or
in-band resize reports on when the probe asks, so a terminal that has them
answers reset.

**A frame is one write.** `draw` writes to a `*std.Io.Writer` and never
flushes it, so batching is yours. `Stats.bytes` says how large the buffer
wants to be.

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
- **No widget whose substance is handling keys, focus or a clock.** Those are three quarters event handling, and the program has the loop. `Keys` shows which keys work and handles none; `TextInput` says where the cursor lands and moves it for no key.
- **No constraint solver.** Fixed, percent, floor, ceiling and share cover what a screen layer owes.
- **No colour degraded to a profile.** A program that asks for sixteen colours gets sixteen colours.
- **One graphics protocol.** The kitty protocol, as ordered layers; there is no second picture path.
- **Two places for a screen.** The alternate screen, or inline at the prompt. Inline mode knows no row of the terminal by number: it has no scroll detection, and after the terminal itself is resized its origin is wherever the terminal put the saved cursor.

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
place that leads back to itself.

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
