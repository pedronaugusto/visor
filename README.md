# visor

[![CI](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/visor/actions/workflows/ci.yml)

visor is a cell grid and a diff renderer for programs that draw their own
screen. You draw into a grid; it writes the shortest run of bytes that moves
the terminal from the frame it is showing to the one it should be showing.

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

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/visor
```

```zig
const visor_dep = b.dependency("visor", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("visor", visor_dep.module("visor"));
```

One fetch. `morse` comes with it, re-exported as `visor.morse`, and is also
available as `visor_dep.module("morse")` for a program that wants the writers
on their own.

Two dependencies: [`morse`](https://github.com/pedronaugusto/morse) for every
escape sequence written and every reply parsed, and `uucode` for grapheme
segmentation and width. `uucode` is pinned by commit. `morse` is a path
dependency while 0.4.0 is unreleased, and becomes a pinned commit the day it
is tagged. `uucode` builds its tables at build time, so
visor asks for six fields and no more:

| Field | For |
| --- | --- |
| `grapheme_break` | Where one cluster ends and the next begins |
| `grapheme_break_no_control` | The same, with control characters out of the way |
| `wcwidth_standalone` | A codepoint's width on its own |
| `wcwidth_zero_in_grapheme` | Whether it adds width inside a cluster |
| `is_emoji_modifier_base` | Skin tone and the cluster it joins |
| `is_emoji_vs_base` | The presentation selector, which widens what it follows |

That costs about 75 KB of read-only data and one slow first build; the tables
are cached after it. A program that configures `uucode` itself should keep
these six and add its own, or the two configurations build two sets of tables.

**Allocation.** One allocator, taken at `Screen.init` and `Renderer.init`.
After that the frame path takes none: `writeCell` does not allocate, `print`
does not allocate, `draw` does not allocate. `Screen.write` allocates only
for a grapheme longer than six bytes the screen has not seen before, and says
so with a `try`. Resizing allocates.

## The API

**The grid's contents.** `Cell`, `Cell.Text`, `Cell.Kind`, `Cell.Shape`,
`Style`, `Color`, `Underline`, `Link`, `Target`.

**The grid.** `Screen` — `init`, `deinit`, `resize`, `writeCell`, `readCell`,
`write`, `fill`, `clear`, `scroll`, `intern`, `link`, `compactPool`,
`damageAll`, `window`, `textAt`, `textOf`, `target`, and the fields `cursor`,
`pointer`, `layers`, `damage`, `method`. `Cursor`, `Damage`, `Span`.

**The views.** `Window` — `child`, `print`, `printSegment`, `writeCell`,
`readCell`, `write`, `fill`, `clear`, `scroll`, `width`, `hit`, `showCursor`,
`hideCursor`, `setCursorShape`, `cols`, `rows`, `size`. `Window.Segment`,
`Window.Print`, `Window.PrintOptions`, `Window.ChildOptions`,
`Window.Border`. `Rect`, `Point`, `Size`.

**Measuring text.** `Method`, `Wrap`, `Graphemes`, `width`, `graphemeWidth`,
`disagrees`, `wrap`, `Row`, `fit`.

**The render pass.** `Renderer` — `init`, `deinit`, `resize`, `draw`,
`repaint`, `repaintRow`, `enter`, `leave`. `Renderer.Stats`, `Mode`.

**What the terminal can do.** `Caps`, `Caps.Probe`.

**Pictures.** `Image`, `Layer`, `Layer.Order`, `Layers`.

**This program's terminal.** `Tty` — `open`, `close`, `raw`, `restore`,
`size`, `writer`, `read`, `onResize`. `restoreGlobal`, `Panic`.

**Testing your own screens.** `Term` — `init`, `deinit`, `setMethod`, `feed`,
`screen`, `resize`, `dump`, `dumpStyles`. `expectScreensEqual`, `dumpScreen`,
`dumpScreenStyles`.

**Everything under it.** `visor.morse`, whole.

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
printing them again is shorter than stepping over them. A move per changed
cell costs more than repainting the whole screen, and at a hundred per cent
changed it costs six times more.

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

## Scope

- **No widgets.** `visor.widgets` is a second module in this repository, and
  the base never imports it.
- **No event loop and no threads.** A base layer that owns the loop cannot be
  used by a program that already has one.
- **No layout solver.** `Rect` splitting covers what a base layer owes.
- **No colour degraded to a profile.** A program that asks for sixteen colours
  gets sixteen colours.
- **No inline mode yet.** The alternate screen only; `enter` says so rather
  than half doing it.
- **One graphics protocol.** Kitty, as ordered layers. Sixel and the
  half-block fallbacks are not here.

## Platforms

| Platform | Tested |
| --- | --- |
| Linux | `ubuntu-latest` in CI, four optimize modes |
| macOS | `macos-latest` in CI, four optimize modes |
| Windows | `windows-latest` in CI, four optimize modes |

Everything but `tty` is arithmetic and bytes, so the same source builds
wherever Zig does; cross-compilation is checked for seven targets. `Tty` is
the one file that calls an operating system, and its Windows half is compiled
in CI but not yet exercised on a console.

## Testing

`zig build test` runs the suite and the examples under
`std.testing.allocator`, so a leak or an invalid free fails the test rather
than the process, in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall.

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

Beside it: byte-exact tests on what each mechanism writes, a grid fuzz that
checks the invariants and the damage map after every operation, a
`checkAllAllocationFailures` pass on `init`, `resize`, `intern` and
`compactPool`, and budgets — a full repaint at 120×40 writes fewer than 8 100
bytes, a frame in which one cell changed fewer than 64, and a frame in which
nothing changed writes nothing, asserted rather than measured. The generated
corpus runs on every push; `zig build test --fuzz` keeps searching beyond it.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).