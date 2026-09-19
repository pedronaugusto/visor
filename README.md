# visor

[![CI](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml)

visor is a cell grid and a diff renderer for programs that draw their own
screen. You draw into a grid; it writes the shortest run of bytes that moves
the terminal from the frame it is showing to the one it should be showing. A
second module, `visor.widgets`, holds a layout solver and thirteen widgets
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
const stats = try renderer.draw(&buffer.writer, &screen, caps);

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
std.debug.assert((try renderer.draw(&second.writer, &screen, caps)).bytes == 0);

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
var control: [64]u8 = undefined;
var w: std.Io.Writer = .fixed(&control);
try visor.morse.mouse(&w, .{ .press = true, .sgr = true });
```
<!-- END GENERATED -->

Two more examples are built and run by the same command.
[`examples/viewer.zig`](examples/viewer.zig) is a file viewer on the widgets —
a sidebar, a scrollbar, a status line and a resize — and
[`examples/gallery.zig`](examples/gallery.zig) draws every widget once.

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

Two dependencies: [`morse`](https://github.com/pedronaugusto/morse) for every
escape sequence written and every reply parsed, and `uucode` for grapheme
segmentation and width. `morse` is a path dependency while 0.4.0 is
unreleased, and becomes a pinned commit the day it is tagged; `uucode` is
pinned by commit already. `uucode` builds its tables at build time, and visor
asks for six fields and no more — `grapheme_break` and
`grapheme_break_no_control` for where one cluster ends and the next begins,
`wcwidth_standalone` and `wcwidth_zero_in_grapheme` for what a codepoint is
worth on its own and inside a cluster, and `is_emoji_modifier_base` and
`is_emoji_vs_base` for skin tone and the presentation selector. That is one
slow first build and then a cached table. A program that configures `uucode`
itself should keep these six and add its own, or the two configurations build
two sets of tables.

**Allocation.** One allocator, taken at `Screen.init` and `Renderer.init`.
After that the frame path takes none: `writeCell` does not allocate, `print`
does not allocate, `draw` does not allocate. `Screen.write` allocates only for
a grapheme longer than six bytes the screen has not seen before, and says so
with a `try`. Resizing allocates.

## The API

| | |
|---|---|
| The grid's contents | `Cell`, `Cell.Text`, `Cell.Kind`, `Cell.Shape`, `Style`, `Color`, `Underline`, `Link`, `Target`. |
| The grid | `Screen` — `init`, `deinit`, `resize`, `writeCell`, `readCell`, `write`, `fill`, `clear`, `scroll`, `intern`, `link`, `compactPool`, `damageAll`, `window`, `textAt`, `textOf`, `target`, and the fields `cursor`, `pointer`, `layers`, `damage`, `method`. `Cursor`, `Damage`, `Span`. |
| The views | `Window` — `child`, `print`, `printSegment`, `writeCell`, `readCell`, `write`, `fill`, `clear`, `scroll`, `width`, `hit`, `showCursor`, `hideCursor`, `setCursorShape`, `cols`, `rows`, `size`. `Window.Segment`, `Window.Print`, `Window.PrintOptions`, `Window.ChildOptions`, `Window.Border`. `Rect`, `Point`, `Size`. |
| Measuring text | `Method`, `Wrap`, `Graphemes`, `width`, `graphemeWidth`, `disagrees`, `wrap`, `Row`, `fit`. |
| The render pass | `Renderer` — `init`, `deinit`, `resize`, `draw`, `repaint`, `repaintRow`, `enter`, `leave`. `Renderer.Stats`, `Mode`. |
| What the terminal can do | `Caps`, `Caps.Probe`. |
| Pictures | `Image`, `Layer`, `Layer.Order`, `Layers`. |
| This program's terminal | `Tty` — `open`, `close`, `raw`, `restore`, `size`, `writer`, `read`, `onResize`. `restoreGlobal`, `Panic`. |
| Testing your own screens | `Term` — `init`, `deinit`, `setMethod`, `feed`, `screen`, `resize`, `dump`, `dumpStyles`. `expectScreensEqual`, `dumpScreen`, `dumpScreenStyles`, `firstDifference`. |
| Everything under it | `visor.morse`, whole. |

### `visor.widgets`

| | |
|---|---|
| Layout | `Layout` — `horizontal`, `vertical`, `split`, `splitFixed`, and the fields `direction`, `constraints`, `spacing`, `margin`. `Constraint` — `fixed`, `percent`, `min`, `max`, `fill`. `Direction`, `Padding`, `Align`, `place`, `offset`. |
| The widgets | `Block` (borders, titles, padding, and the window inside), `Paragraph` (wrap, alignment, scroll), `List` and `List.State`, `Table` and `Table.State`, `Tabs`, `Gauge`, `LineGauge`, `Sparkline`, `BarChart`, `Chart`, `Scrollbar` and `Scrollbar.State`, `Canvas`, `Calendar`. Beside them: `Item`, `Line`, `Row`, `Bar`, `Dataset`, `Axis`, `Marker`, `Date`. |
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

**Damage is exact in both directions.** A write marks a cell only when it
changes it, so a row is dirty exactly when its contents differ from what was
drawn. A map that under-reports is a rendering bug you see once a week and
cannot reproduce; one that over-reports is a frame that cost more than it
should. The grid fuzz checks both.

**Changed cells go out as runs.** A contiguous run gets one cursor move and
one style pen, and the run bridges up to four unchanged cells because
printing them again is shorter than stepping over them.

**A row is written whole when the diff would cost more.** Both are priced by
emitting them into a writer that counts and discards, so the answer is the
real byte count rather than a model of one.

**A blank run is erased, not painted.** A row blank to its end is `EL`, four
bytes whatever the width; a blank run longer than the sequence that erases it
is `ECH`, which leaves the cursor where it was.

**The cursor move is a search.** Every candidate is costed in bytes — the
absolute move, the column, the row, the four relative moves, the carriage
return, and backspaces — and the shortest wins, with the absolute move as the
tie-break, because it is the one that is right whatever the terminal did with
the last one.

**A row the terminal might measure differently is never diffed.** Whether the
two width models disagree about a cluster is worked out once, when the cell is
written, and a row holding one is repainted whole from an absolute position
with the cursor not trusted afterwards — because an over-measured cluster runs
past the margin and wraps, so the following rows are a row out as well as a
column. A change of width method repaints every row that has ever held one.
Under mode 2027 the models agree and the re-anchor is skipped.

**Wide graphemes are in the grid, not inferred at render time.** A wide
cluster is a head and a covered column, always adjacent; overwriting either
repairs the other; one with a single column left becomes a spacer, which the
diff can tell from a space someone asked for.

**Synchronised output brackets a frame, not a session.** Mode 2026 left on for
a program's lifetime makes the terminal repaint at whatever timeout it
invented, which is ten frames a second on the tightest of them. `draw` writes
the bracket, into its own buffer, and keeps it only when the frame turns out
too large for the terminal to take in one read; `leave` writes the closing
half whether or not it wrote the opening one.

**The text pass never writes a graphics command and never deletes a
placement.** A picture that moves is re-placed under the same image and
placement id, which the protocol replaces without flicker; one that leaves is
deleted by name, and its bytes are kept. Nothing waits for an acknowledgement:
a placement names the number the program chose, and the acknowledgement, when
it comes, upgrades that to the id the terminal assigned.

**Nothing is guessed.** No terminfo, no capability database, and no
environment variable read — not `TERM`, not `COLORTERM`, not `NO_COLOR`.
`Caps.Probe` writes the questions and folds the answers in; a caller who would
rather trust the environment sets the fields itself.

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

**Layout is splitting, not solving.** A rectangle is divided by fixed sizes,
percentages, floors, ceilings and shares of what is left, in one pass over
the constraints, with no allocation and no cache; splits nest because a part
is a rectangle like any other. A general constraint solver is a package of
its own.

## Scope

- **No widgets in the base.** They are a second module, which `visor` never imports.
- **No event loop and no threads.** A base layer that owns the loop cannot be used by a program that already has one.
- **No widget whose substance is keys, focus or a clock.** Those are three quarters event handling, and the program has the loop.
- **No constraint solver.** Fixed, percent, floor, ceiling and share cover what a screen layer owes.
- **No colour degraded to a profile.** A program that asks for sixteen colours gets sixteen colours.
- **One graphics protocol.** The kitty protocol, as ordered layers; there is no second picture path.

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

`Tty` is the one file that calls an operating system. It is compiled on all
three platforms in CI and opened by nothing in the suite, so no half of it has
been run against a real terminal yet; the alternate screen, raw mode and the
inline mode `enter` refuses are the work still open there.

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
final screen agrees with the terminal given every frame. All four run twice,
against a terminal measuring by codepoint and a terminal measuring by cluster,
because the rule that repaints a drifting row exists for the case where the
two disagree.

`zig build conformance` runs the same four properties again, over the same
inputs, against a terminal emulator that is not this one's. `Term` ships with
this package, so a property that compares the renderer with it compares two
readings of the same specifications by the same hand; the conformance build
compares the renderer with the terminal inside a shipping emulator, read
through its own grid — every column's grapheme, its width and its style. It is
a build of its own under `conformance/`, with its own manifest pinning that
emulator by commit, so nothing that builds a program on this package fetches
one. CI runs it on Linux and macOS.

Every widget is tested the same way round: drawn into a grid, rendered to
bytes, fed to the emulator, and the picture the terminal shows compared with
the picture it should be — then drawn again, which must write nothing. A test
that asserts on the cells a widget wrote has proved half of what a program
runs.

Beside it: byte-exact tests on what each mechanism writes, a grid fuzz that
checks the invariants and the damage map after every operation, a
`checkAllAllocationFailures` pass on `init`, `resize`, `intern` and
`compactPool`, and budgets — a full repaint at 120×40 writes fewer than 8 100
bytes, a frame in which one cell changed fewer than 64, and a frame in which
nothing changed writes nothing. The generated corpus in `src/corpus.zig` runs
on every push, and both builds replay the same bytes; `zig build test --fuzz`
keeps searching beyond it.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).