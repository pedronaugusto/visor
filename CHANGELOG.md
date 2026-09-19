# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **`Term`**, a terminal emulator as complete as the renderer's output,
  public because a program built on this package needs the same check.
  `expectScreensEqual` compares two grids cell by cell; `dumpScreen` and
  `dumpScreenStyles` write them out for a golden file.
- **`Window`**, a clipped view with `child`, `print`, `printSegment`,
  `writeCell`, `readCell`, `fill`, `clear`, `scroll`, `width`, `hit`,
  `showCursor`, `hideCursor` and `setCursorShape`. Printing never allocates.
- **`Layers`**, kitty graphics as an ordered stack the text pass never
  touches: a picture that moves is re-placed rather than deleted, one that
  leaves is deleted by name, and nothing waits for an acknowledgement.
- **`Tty`**, this program's own terminal: raw mode, the alternate screen, the
  size, an opt-in resize signal, and `restoreGlobal` for a panic handler.
- **`Caps`**, every field defaulting to what is safe on the oldest terminal,
  and `Caps.Probe`, which writes the questions and folds the answers in
  without reading an environment variable.
- **`zig build conformance`**, the round trip run a second time against a
  terminal emulator that is not this one's. The same four properties over the
  same committed corpus, read by column -- every column's grapheme, width and
  style, the covered column of a wide cluster included -- and twice, once with
  the terminal measuring by codepoint and once with it in mode 2027. It is a
  build of its own under `conformance/`, with its own manifest, so nothing
  that builds a program on this package ever fetches a terminal emulator. CI
  runs it on Linux and macOS.
- **`src/corpus.zig`**, the generated inputs both round trips replay, as a
  module of its own so the suite inside the package and the conformance build
  outside it are given the same bytes.
- **`visor.widgets`**, an empty second module the base never imports.
