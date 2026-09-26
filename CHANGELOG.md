# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Winsize`, `Pixels` and `CellSize`: the terminal's grid, its text area in
  pixels, and one cell in pixels, kept apart. `Winsize.update` folds a resize
  event (from the signal or in band) and the answers to `CSI 14 t`, `16 t` and
  `18 t`; `cellSize` returns the cell the terminal reported, or the text area
  divided by the grid flagged as not reported, because a terminal that pads
  its text area makes the division too large. A resize forgets a reported
  cell: it is also what a change of font looks like.
- `Tty.adopt`, a `Tty` over a file the program already has open.
- `Modes`: the input a program asks for on the way in — kitty keyboard flags,
  mouse reports, focus, bracketed paste and colour-scheme reports.
  `Renderer.enter` takes them and `leave` undoes exactly those, in reverse:
  the keyboard flags are pushed after the switch to the alternate screen and
  popped before the switch back, because the stack is per screen. The mouse
  is a `?morse.Mouse`, one motion and one encoding as the terminal keeps
  them: `enter` puts the terminal's mouse in exactly that state whatever was
  on, and the way out turns that motion and that encoding off. Focus is a
  field of its own, mode 1004. `Renderer.setModes` changes them mid-session,
  writing only what differs — for the mouse, the old motion or encoding off
  before the new one on — and `leave` undoes what is on at the time.
- `Input`: the terminal's input, read. `next` reads the `Tty`, frames the
  bytes with `morse.KeyParser` and hands back morse's own events one at a
  time — the mouse as `mouse` and every answer to a question as a typed
  `reply`, so a program parses nothing twice and keeps values rather than
  bytes copied under a cap. A lone `ESC`, `ESC [` or `ESC O` waits the caller's
  timeout for the rest of a sequence and is then the key it also is; the end
  of the stream settles whatever was pending before it reports
  `EndOfStream`. It starts no thread: `next` blocks on the caller's `std.Io`
  and is stopped by cancelling the task it runs in, so nothing has to be
  written to the terminal to wake it. A property test feeds random streams
  through a pipe in reads of one to thirty-two bytes and checks the events
  are the parser's over the whole stream.
- `Tty.watchResize`, `unwatchResize`, `resized` and `resizeFile`: a
  `SIGWINCH` handler that writes one byte into a pipe. `Input` waits on the
  pipe beside the terminal and turns a wake into the same `resize` event an
  in-band report is, with the size and pixels the operating system has when
  it is read; a burst of signals is one event. `resized` is the same wake,
  asked without blocking, for a program with a loop of its own.
- `Tty.inputFile`, the file keys and replies arrive on.
- `Layers.repaint`: the next frame places every declared picture again, as
  though the terminal could have moved or dropped any of them. `Renderer`
  calls it on every repaint.
- The conformance build replays the corpus through the same generator as
  the package's suite, proves that it explores, and draws every grapheme
  across resizes too.
- Round-trip properties across resizes, in the package's own suite and
  against the second emulator: the terminal resized first and keeping what
  fitted, frames at the old size landing after it, drags through sizes the
  program never hears of, and pictures placed across them. The conformance
  build also puts the probe's questions to the emulator.
- `Layers` owns an image's whole life, so a program writes no graphics
  command itself. `transmit` sends pixels under an id, chunked, deflated when
  that makes them smaller, and quiet unless an answer is asked for; `ready`
  says whether a layer can show it — at once when sent quietly, on the
  terminal's word when an answer was asked for, or when the caller's grace
  period runs out, after which a terminal that has never answered is not
  waited for again; `free` takes the pixels and every placement away, and
  `freeAll` does it for every image on the way out. `Image.State`,
  `Layers.answers` and `Layers.fallbacks` say where things stand. The layer
  fuzz sends, answers and frees between frames.
- `Palette`, `mix` and `Rgb`: what the terminal's colours look like.
  `Palette.ask` writes the questions for the foreground, the background and
  the sixteen slots; `update` folds the answers in; `resolve` turns any
  colour into the RGB it is drawn in, or null while its slot is unanswered,
  with the standard cube and grey ramp above the sixteen. `mix` is the step
  between two colours, which is what a tint toward the background is.
- `Window.ink`, `Window.inked` and `Window.Ink`: a program's look applied to
  every cell a window writes. The ink is a function the program owns, given
  each stroke -- where on the screen it lands, how many columns it covers,
  what it holds and the style it was written in -- and answering the style
  it is drawn in; it may also watch the strokes, to light what is drawn in a
  bright style. Children inherit it, and a widget drawn through an inked
  window is the widget drawn plain with the look applied after, with no
  scratch screen. With no ink a write pays one branch; on a page of widgets
  the difference is below what the same code moved within the binary costs.
- `Window.linkAt`, the OSC 8 target under a cell — what a click there opens,
  with no table of where links were drawn, because a cell carries its link —
  and `Window.copyText`, one row's text between two columns as the terminal
  shows it, for a selection.
- In `visor.widgets`:
  - `TextInput`, text being typed laid out as rows with the cursor as a place
    in them. The layout is public — `rows`, `rowCount`, `place`, `at`,
    `prev`, `next`, `wordStart`, `lineStart`, `lineEnd` — because the program
    moving the cursor and the widget drawing it must agree on every break.
    Every byte belongs to exactly one row; widths are by cluster, so a wide
    or combined character moves as one. `draw` keeps the cursor's row in
    view through `TextInput.State`. Fuzzed.
  - `Scroll`, which rows of something longer a view shows: anchored at the
    bottom it follows the live end, and scrolled back it holds the rows on
    screen still while more arrive; anchored at the top it is a document.
    `Scroll.State` is the offset and the length it was taken against.
  - `Keys`, the keys that work here beside what they do, in one row, with
    `width` for a program deciding what to drop on a short row.
  - `Rule`, a line across a window or down it, in the glyph and style given.
  - `Sextants` and `sextant`: a picture in cells, two by three pixels a cell,
    for a terminal that draws no pictures; and `Marker.sextant` for `Canvas`.
  - `Block.corners`: corner marks with no lines between them, which take no
    room from the inside.
  - `List` draws the row a person picks from. An `Item` may be runs in
    styles of their own (`segments`, each a `List.Segment` that may start at
    a column and take at most so many), text against the right edge
    (`aside`), and rows under the first (`below`). The list has a
    `marker_style` for both markers, a `gap` after them, an `ellipsis` for
    what is cut, an `aside_gap`, and `text_min`, how far the text gives way
    to the aside before the aside is cut instead. `selected_style` may be
    null, for a program that styles the chosen item's runs itself.
    `List.visible` says which items a window shows and how many it does not,
    for a head that says "N more". A test draws a picker by hand at
    worked-out columns and through the list and finds the same cells, and
    the conformance build reads a list back from the second emulator.
  - `Layout.repeat`, parts of one size with the spacing between them and the
    cells that do not divide left at the end, so a grid of columns lines up
    whatever their number; and `Layout.fitCount`, how many parts of at least
    a width fit.
  - `Tabs.divider_style` may be null, which spaces the titles apart by the
    divider's columns without drawing over what is there.
  - `Sparkline.mode = .level`: each point the nearest of the eight heights,
    never nothing, which is the sparkline a line of text wants.
- `Tty.enter` and `Tty.leave`: raw mode and a renderer's `enter` in one call,
  and the way back. A screen entered this way is undone by `Tty.restore`,
  `Tty.close`, `restoreGlobal` and `Panic` too — modes, alternate screen and
  cursor before the terminal's mode — through a buffer on the stack and a
  write that cannot fail. `Renderer.deinit` takes a renderer off that path.

### Changed

- `Tty` builds on conduit's terminal primitives (`conduit.tty`) for raw
  mode, the way back, the size and the device's name, instead of its own
  copies of the same calls, and the suite's pseudo-terminal is conduit's.
  The dependency is taken by path while conduit is unreleased; the module
  visor imports links no C library on Linux. On Windows the input handle
  no longer asks for window-size records, which a terminal-sequence read
  never returns.
- **Breaking:** the renderer's own steps -- `prevRow`, `shiftPrev`,
  `hideForWrite`, `price`, `setStyle`, `setLink` -- are no longer public
  methods of `Renderer`. They were public only so the scroll detection in
  another file could call them, which made them part of the API by accident.
- **Breaking:** `Palette.update`, `Winsize.update` and `Caps.Probe.feed`
  take the typed replies `Input` hands back (`Event.reply`) rather than
  bytes to parse; `Caps.Probe.feed` takes a `morse.Event`.
- **Breaking:** `graphemeWidth` returns a `u16`. Measured by codepoint a
  cluster is the sum of its codepoints' widths, no longer clamped at two,
  because a terminal that measures that way gives each codepoint that takes
  columns cells of its own. `Parts` names those cells and `combinesOnly`
  says whether a cluster is one of them.
- **Breaking:** `Tabs.spanOf`, `Tabs.indexAt` and `Tabs.width` take the
  width method, so the spans a program hit-tests are the ones drawn on its
  screen.
- **Breaking:** `Tty.size` returns a `Winsize`, with the text area in pixels
  where the operating system has it, instead of a `Size`.
- **Breaking:** `Renderer.enter(w, caps, mode, modes)` takes the input modes
  as a fourth argument; `.{}` asks for none, as before.
- **Breaking:** `Tty.onResize` is gone. `watchResize` replaces it: a
  handler that only writes to a pipe, which a program reads through `Input`
  or asks with `resized`, rather than a function of the program's run in a
  signal context.
- **Breaking:** an image is named by the id the program chooses (`i=`),
  not by a number the terminal turns into an id. A program that picks its
  ids needs no answer to name a picture, sending new pixels to an id
  replaces them rather than leaving the old ones behind, and freeing one is
  exact. `Image.number`, `Image.acked` and `Image.handle` are gone, and so is
  `Layers.declareImage`: `transmit` records the image. `Layers.ack` matches
  by id and ignores an answer about any other.
- `dumpScreenStyles` names any number of styles. Past sixty-two every id is
  two characters, in the legend and the grid alike, where before the
  sixty-third style printed `?`. A cell's OSC 8 link is part of its style and
  is printed last as ` link=<uri>`, and the column a wide grapheme covers
  prints the id of the cell that covers it. The format is written out in the
  function's documentation, for programs that write the same dump from
  another renderer. **Breaking:** it and `Term.dumpStyles` can fail with
  `error.OutOfMemory`, on the screen's own allocator.
- A layer's placement is written before a departed layer's deletion, so a
  picture replaced by one under another id is covered before it goes.
- **Breaking:** `Caps.Probe` asks `morse.Probe`'s questions, in morse's
  order, and settles the way morse says a probe must: the device
  attributes answer proves the input path works and is not the end of the
  answers, because a multiplexer can give it while a question it forwarded
  is still on its way. `Caps.Probe.questions` is the `morse.Probe` asked
  (so the same write asks the colours and sizes for `Palette` and
  `Winsize`); `feed(event, now_ms)` records when the last answer came;
  `complete()` says every question asked has been answered; and
  `settled(now_ms, quiet_ms)` is complete, or the device attributes
  answered and quiet since the last answer for the caller's quiet period,
  on the caller's clock. The probe's own set of questions and its settling
  on DA1 are gone.
- **Breaking:** `Caps.Probe` has a `graphics_id` with no default, carried by
  the graphics question in place of the fixed 31, and only an answer carrying
  it sets `kitty_graphics`: an answer about one of the program's pictures is
  not an answer to the question.
- `Tty.open` on macOS opens the terminal under its device name when a
  standard stream is on it, rather than as `/dev/tty`, which the kernel's
  `poll` there cannot wait on.

### Fixed

- **The properties had been testing almost nothing.** `std.testing.Smith`
  reads eight bytes for every value and answers the lowest in range when
  those bytes are out of it, and it ends a loop at the first byte that is not
  zero, so every replayed entry drew a one-by-one grid and not one frame,
  and the input pump drew an empty stream.
  Every property -- the round trips, the pump, the text input's layout and
  the split -- now reads through `corpus.Dice`, which answers a replayed
  entry from a generator the entry seeds and hands every question to the
  fuzzer under `--fuzz`, and a test beside each one fails unless the corpus
  draws the whole of every range. The resize property draws everything the
  others do, scaled text and clusters the width models disagree about
  included. What that found is below.
- Text drawn at a scale could be left torn in the grid after a scroll. When
  a scroll moved one block's head beside another block, clearing the torn
  block blanked the other block's cells inside its rectangle. `heal` now
  decides heads in reading order, a cell belongs to the first head that
  keeps it, and a cleared head gives back only its own cells.
- Scroll detection could choose a region whose edge ran through text drawn
  more than one row tall. The rows inside moved and the rest of the block
  did not, and the terminal cleared the block it no longer held whole. Such
  a region is now refused and the frame drawn the ordinary way.
- Bytes that are not UTF-8 could swallow the text after them. `Graphemes`
  decoded an ill-formed sequence through the byte that ended it, so a
  sequence cut short before a flag took the flag's first byte and left three
  stray continuation bytes. It now decodes the way a terminal does, one
  replacement character for each maximal subpart, and the next codepoint is
  whole. Found by the text input's fuzz.
- **Measured by codepoint, a cluster of several wide codepoints was drawn
  over the cells after it.** The grid held the astronaut (a woman, a joiner
  and a rocket) as one cell two columns wide; a terminal measuring by
  codepoint shows the woman in two columns and the rocket in the next two,
  over whatever the grid had there. `Screen.write` now puts such a cluster in
  the cells the terminal gives it, and `Term` prints it the same way. Found
  by the conformance round trip once its generator explored.
- On a screen one column wide measuring clusters, a mark after its base was
  lost: the second emulator joins a codepoint to the cell under a cursor
  waiting to wrap only past the first column. A base and its marks in that
  one column now go out with mode 2027 off around them, and a terminal
  measuring by codepoint joins the marks to the base there.
- Tabs, List, Table, Gauge, BarChart, Chart and Calendar measured their
  text by cluster whatever the screen measured by, so on a terminal
  measuring by codepoint a marker, a label or an alignment could be off by a
  column for every cluster the two measures disagree about. Every widget now
  measures the way the window's screen does.
- **Text was left on the screen after a resize.** A resize or a repaint gave
  the renderer a blank previous frame, and a row the new frame held blank was
  skipped as already blank, so whatever the terminal still showed there -- a
  label on the row it moved from, a frame drawn at the old size landing after
  the terminal changed -- stayed. The previous frame is now forgotten on a
  repaint (and on `repaintRow` for that row), so every row is written, a
  blank one erased to the end of the line. `Term.resize` keeps what fits, as
  a terminal's alternate screen does, instead of clearing, which is what hid
  this from the suite. A failed frame's retry now erases its blank rows too.
- **A picture could be left where a resize put it.** The terminal moves a
  placement with its row, or drops it with the row; the renderer took the
  placement to be where it had put it. Every declared picture is placed again
  on a repaint.
- **`Caps.Probe` read a terminal that has synchronised output or in-band
  resize reports as one without them.** Both are off when the probe asks, so
  such a terminal answers reset, and the probe took reset for no. Set, reset
  and permanently set now all mean the terminal has the mode. With it,
  `enter` turns in-band resize reports on where the terminal has them, and
  frames are bracketed where they are large enough.
- A wide grapheme moved beside another's covered column (a scroll whose
  rectangle holds the head and not the column) left that column carrying the
  other grapheme's text and style. The column is now the new head's.
- Bytes that are not UTF-8, written into the grid, reached the terminal as
  they were and were measured as something they were not. `Screen.write` and
  `writeScaled` now store the replacement character for them, which is what
  a terminal would have drawn. Found by the text input's fuzz.
- The way out (`Tty.restore`, `restoreGlobal`, the panic handler) put the
  terminal's mode back only after all output had been read, so a program
  exiting or panicking on a terminal that had stopped reading waited for
  ever. The mode now goes back at once, and unread input is thrown away
  first, so a late answer to a probe does not land in the shell.
- `wrap` by word broke a row one word early when the space that crossed the
  edge was itself the break: "ab cd efg" at five columns came out "ab",
  "cd ef", "g" instead of "ab cd", "efg".
- Measured by codepoint (`.wcwidth`), a nonspacing or enclosing mark, a
  variation selector and a joiner counted a column each; `wcwidth(3)` counts
  them as nothing, so "e" and a combining acute measured two.
- Entering with mouse modes, or changing them with `setModes`, could leave
  the terminal reporting no mouse at all: the modes went out in ascending
  order, and a terminal resets the motion it reports when any of 1000, 1002
  and 1003 goes off after another went on. `Modes.mouse` is now morse's
  `Mouse`, one motion and one encoding, and nothing written after an `h` can
  reset its setting.
- `wrap` left an empty row before a cluster wider than the whole row; the
  cluster now takes a row of its own.
- `Tty.open` did not compile on macOS: Zig's libc bindings there have no
  `tcgetpgrp`. The foreground group is asked by ioctl, and a test now calls
  `open` so a platform it fails to compile on is caught by the suite.

## [0.2.1] - 2026-09-20

### Fixed

- `visor.version` said `0.1.0` in 0.2.0. It now says what the manifest says, and the test that checks it reads the manifest instead of a literal beside the constant.

## [0.2.0] - 2026-09-20

Inline mode, `REP`, explicit widths and scaled text, the render pass priced
arithmetically instead of emitted twice, and a fuzz over the image layers.

### Added

- `Caps.rep` is read: on a terminal with `REP`, a run of one narrow
  single-codepoint glyph in one style is written as the glyph and a repeat
  count, and `Stats.repeated` counts the cells it stood for. The emulator
  understands the sequence.
- `Caps.explicit_width` is read: a cluster the two width models disagree
  about is written with its width stated through OSC 66, and its row is
  diffed rather than repainted whole; under `Method.explicit` every cluster
  but ASCII is. `Stats.told` counts them. The emulator takes the width it is
  told, and the round trip runs a third time against a terminal measuring by
  codepoint that is told every width.
- `Caps.scaled_text` is read, and there is text to read it for:
  `Screen.writeScaled` and `Window.writeScaled` draw a grapheme at a scale of
  up to seven, as a head and a block of covered cells that `Cell.Shape.scale`
  and `Cell.rows` describe and `Screen.headOf` finds. Writing into any cell
  of the block clears it whole. The renderer writes the head as one OSC 66
  and never touches the block, `Stats.scaled` counts them, and without the
  capability the grapheme is drawn at its own size with the block blank. The
  emulator draws the block, and the round trip's generator writes scaled
  text. `Cell.width` now returns the columns a cell covers at its scale, as a
  `u4`; `Cell.glyphWidth` is the width before scaling.
- Inline mode. `Renderer.enter` with `Mode.inline` takes the screen's rows
  from the row the cursor is on, the terminal scrolling for the ones that do
  not fit, and saves an origin there; every move after that is relative to
  the cursor or to the restored origin, whichever is cheaper. `resize` takes
  more rows or gives them back blank on the next draw, a repaint starts from
  a blank screen at the origin, and `leave` puts the cursor on the row below
  with the last frame still showing. Scroll detection is off inline. The
  round trip runs for inline screens, and `examples/progress.zig` is one.
- The conformance build compares every column's link with the second
  emulator's, URI and `id` both, where before it compared the grapheme, the
  width and the style and let a link go unchecked.
- The image layers are fuzzed: random placements, moves, deletions, stacking
  changes and acknowledgements over the layers, with the checks that a frame
  with nothing new writes nothing, that the text pass is whole before the
  first graphics command, and that a deletion happens only for a picture that
  left and names it alone.

### Changed

- Built on morse 0.5.0.

### Removed

- `error.InlineModeUnsupported`, which `Renderer.enter` no longer returns.

### Fixed

- Row and run planning counts the exact output arithmetically instead of
  emitting candidates into counting writers, removing repeated render passes
  from changed frames without changing their bytes. Safe damage spans,
  printable ASCII measurement, and repeated SGR transitions reuse facts the
  renderer already knows as well.
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
- Layout splitting clips rectangles that cross the `u16` coordinate edge
  instead of trapping while narrowing their endpoints.
- The exported package version reports `0.1.0`, matching the manifest and
  released changelog.
- Damage is documented as a conservative change hint; restoring a cell before
  drawing is filtered against the renderer's previous-frame baseline.
- Diff runs bridge unchanged cells only when their actual text, style, and
  link bytes cost no more than moving the cursor over them.

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
