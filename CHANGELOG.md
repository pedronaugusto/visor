# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- A failed frame write is retried as a complete repaint without losing text,
  damage, or image-layer changes.
- `Screen.writeCell` and `Window.writeCell` are replaced by `copyCell`, which
  names the source screen and safely re-interns pooled graphemes and links.
- Interning text or link targets borrowed from the same pool remains valid
  when growing that pool moves its backing allocation.
- Windows raw-mode setup restores the input console mode when configuring the
  output console fails.
- `Renderer.leave` unwinds terminal modes even when `Renderer.enter` stopped
  on a partial output write.
- Inserting an image layer re-places unchanged layers whose sorted z-position
  moved, preserving the declared stacking order.
- Word wrapping keeps the measured width of a word prefix consumed after an
  earlier break.
- The terminal emulator clamps large CSI scroll counts to the active region
  instead of trapping during signed conversion.
- Capability probing uses `Tc` and `RGB` for truecolour instead of treating a
  256-colour palette as direct RGB support.
- Capability probing sends a harmless kitty graphics query, allowing image
  layers to be enabled from the terminal's reply.
- Paragraph wrapping, alignment, horizontal scrolling, and row counts use the
  screen's configured width method; `rowCount` now takes that method.
- Canvas lines are clipped to the mark grid before rasterization, so distant
  off-canvas endpoints cannot leave gaps in the visible segment.
- Sparkline and bar-chart scaling handles the full `u64` value range without
  intermediate overflow.
- The terminal emulator reports OSC 8 allocation failures without consuming
  the link or silently writing following cells as unlinked text.
- Windows terminal opening closes the input console handle when opening the
  output console fails.
- Text fitting and wrapping compare exact internal widths, so strings beyond
  65,535 columns neither pass a saturated fit check nor overflow arithmetic.
- Scrollbar thumb sizing and positioning accepts the full public `usize`
  state range without intermediate overflow.
- Calendar weekday calculation covers the complete public `i32` year range.

## [0.1.0] - 2026-09-19

The first cut: a cell grid, a diff renderer, the terminal emulator the suite
checks them with, and a second module of widgets drawn on the grid.

### Added

- **The cell, the grid and the damage map.** A thirty-two byte `Cell`
  compared as memory: the grapheme in the cell up to six bytes and in a pool
  the screen owns beyond, the style `morse.Style`, the link an index into a
  table where the parameters are part of the identity. `Screen` keeps its own
  invariants — a wide cluster is a head and a covered column, overwriting
  either repairs the other, and one with a single column left becomes a
  spacer — so the widths across a row always sum to the row. Damage is marked
  only where a write changed a cell.

- **`Renderer.draw`**, a function of the previous frame, the screen and the
  capabilities to bytes: runs rather than cells, the cheaper of the diff and
  a whole row priced by emitting both into a writer that counts, the shortest
  cursor move by byte count, `EL` and `ECH` where a blank run is longer than
  the sequence that erases it, and no diff at all across a cluster the
  terminal may measure differently. `Renderer.Stats` counts what a frame
  cost.

- **`Window`**, a clipped view with `child`, `print`, `printSegment`,
  `writeCell`, `readCell`, `fill`, `clear`, `scroll`, `width`, `hit`,
  `showCursor`, `hideCursor` and `setCursorShape`. Printing never allocates.

- **`Layers`**, the kitty graphics protocol as an ordered stack the text pass
  never touches: a picture that moves is re-placed rather than deleted, one
  that leaves is deleted by name, and nothing waits for an acknowledgement.

- **`Caps`**, every field defaulting to what is safe on the oldest terminal,
  and `Caps.Probe`, which writes the questions and folds the answers in
  without reading an environment variable.

- **`Tty`**, this program's own terminal: raw mode, the alternate screen, the
  size, an opt-in resize signal, and `restoreGlobal` for a panic handler.

- **`Term`**, a terminal emulator as complete as the renderer's output,
  public because a program built on this package needs the same check.
  `expectScreensEqual` compares two grids cell by cell; `dumpScreen` and
  `dumpScreenStyles` write them out for a golden file.

- **`visor.widgets`**, the second module the base never imports. Immediate
  mode: a widget is a value built where it is drawn, handed a window, and
  gone by the end of the call; anything that survives the frame is a struct
  the caller owns and passes by pointer. `Layout` splits a rectangle by
  `fixed`, `percent`, `min`, `max` and `fill`, nested as deep as wanted, in
  one pass and with no solver. Then `Block`, `Paragraph`, `List`, `Table`,
  `Tabs`, `Gauge`, `LineGauge`, `Sparkline`, `BarChart`, `Chart`,
  `Scrollbar`, `Canvas` and `Calendar`. Every one of them is tested by
  drawing it into a grid, rendering the frame, feeding the bytes to the
  emulator and comparing the picture the terminal shows, so the suite proves
  the widget and the renderer together.

- **`zig build conformance`**, the round trip run a second time against a
  terminal emulator that is not this one's. The same four properties over the
  same committed corpus, read by column — every column's grapheme, width and
  style, the covered column of a wide cluster included — and twice, once with
  the terminal measuring by codepoint and once with it in mode 2027. It is a
  build of its own under `conformance/`, with its own manifest, so nothing
  that builds a program on this package ever fetches a terminal emulator. CI
  runs it on Linux and macOS.

- **`src/corpus.zig`**, the generated inputs both round trips replay, as a
  module of its own so the suite inside the package and the conformance build
  outside it are given the same bytes.

- **Two more examples**, both built and run by `zig build examples`:
  `examples/viewer.zig`, a file viewer with a sidebar, a scrollbar, a status
  line and a resize, and `examples/gallery.zig`, every widget drawn once.

- **`zig build test --fuzz` builds and runs.** Zig 0.16.0's test runner
  cannot compile a fuzzing binary with error tracing on, so the test modules
  turn it off; the ordinary suite is unaffected. Two real failures came out
  of the first search beyond the committed corpus, both fixed below.

### Fixed

- **A frame that had nothing to write wrote twelve bytes.** The cursor was
  hidden before the text pass and shown again after it, so a frame whose
  damage map named rows that had not really changed — which is every frame of
  a program that marks what it redrew rather than what it changed — cost the
  two mode sequences. The cursor is now hidden before the first byte the pass
  writes and not before, and a row is compared as the terminal would see it,
  so a link on a terminal with no OSC 8 is not a difference either.

- **A split whose spacing did not fit put parts outside the area.** Four
  parts with three cells between them in a rectangle two cells tall charged
  the spacing anyway and placed the later parts past the edge. Positions are
  clamped to the area, and a part with no room left is empty.
