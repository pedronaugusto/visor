# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Keep dirty row counts with their spans so clean frames need no damage scan or clear.

- Copy checked cell payloads in contiguous ranges and compare their words without dropping pool identities.

- Reject undeclared dependencies, duplicate layer membership and imports of source executables.

- Check named source layers, cycles, entry files and dependency owners during source CI.

- Keep drawing policies below their owners and assemble integration tests above them.
- Resolve Markdown document types without importing their own file.
- Give terminal and Unicode dependencies one source owner.

- Bound local Zig build caches before builds, retaining downloaded packages and tools.
- Pin conduit at confirmed per-child scope completion and fallible private-scope release.

- The root restoreGlobal documentation names every registered terminal it restores.
- Session retains size reports and graphics acknowledgements before retrying capability output that can fail.
- Morse is pinned at 904d3a5, with timing tests on bench and astral AltGr text decoded by the same modifier rule.
- Breaking: Input.init returns error.EmptyReadBuffer for empty read storage; callers must handle its error union.
- Terminal documentation distinguishes Tty ownership from the descriptor use of shared-memory pictures.
- Window documents the screen-owned allocations that committed printing can make.
- Winsize owns cell-pixel invalidation for changed geometry from size replies as well as resize events.
- Resize handlers preserve the interrupted thread's errno when a libc pipe write fails.
- The root documentation scopes signal-free drawing to the core and names Tty.watchResize as the explicit signal-handler opt-in.
- Resize watching withdraws handler borrows before closing either pipe end so teardown cannot write to a closed or reused descriptor.
- Block titles keep whole glyphs between the frame sides, including when clipped.
- Late graphics replies cannot make failed images ready before retransmission.
- Breaking: Renderer.enter and Session.enter refuse a second live or partial entry with AlreadyEntered; Error and Session.Error include it, and leave is required before re-entry.
- Session retains learned capabilities across failed output and retries them on the next event until accepted or superseded by caller policy.
- Retrying failed Renderer mode or capability changes resumes commands not yet accepted without repeating an accepted keyboard push.
- Breaking: Window keeps its clipped screen, rectangle and ink internal; screen() borrows the owner, rect() returns a copy, ink() borrows the drawing policy, and child, sub and inked construct views.
- Breaking: TextInput.Rows keeps borrowed text and iteration progress internal; construct through TextInput.rows and advance with next.
- Breaking: Markdown.Rows keeps document, wrapping configuration and block progress internal; use init and next.
- Breaking: Paragraph.Rows keeps borrowed text, wrapping configuration and refill state internal; use init and next.
- Breaking: Graphemes and Parts keep borrowed source and iteration progress internal; construct with init and advance through next or nextAt.
- Breaking: Damage row storage is internal; rowCount() returns its extent and marking, clearing and resize own its mutations.
- Breaking: OwnedTarget keeps its allocator and retained slices internal; init owns copying and target() lends the target read-only.
- Breaking: ImageIds keeps its validated range, excluded probe id and allocation cursor internal; use init and acquire.
- Breaking: Replacement picture ownership and refusal state are internal; current() and pending() return copied ids.
- Breaking: Caps.Probe owns its questions and answer progress internally; init and const queries replace literals and mutable fields.
- Breaking: Input framing, parser and buffer state are internal; use mousePixels() and setMousePixels() to match requested mouse encoding.
- Breaking: Tty descriptors, saved modes, renderer association and resize watcher are internal; ioContext() returns its captured Io by value.
- Breaking: Canvas.Surface owns allocation and geometry internally; dimensions() copies its size, pixels() and pixelsMut() borrow its bytes, and resize commits cleared storage atomically.
- Breaking: Term allocation, grid and stream state are internal; screen(), position(), savedCursor() and graphics() provide const views or values.
- Breaking: Session allocation and coordinated state are internal; screen(), renderer() and layers() borrow components, while windowSize(), capabilities() and probe() query state.
- Breaking: Renderer terminal state is internal; entered() returns the requested configuration by value, and mutations go through its methods.
- List selection finds its visible suffix in one backward height scan instead of repeatedly rescanning the range.
- Terminal mode cleanup remembers partially written changes and avoids repeating an accepted keyboard pop.
- Failed image transmissions remain refused and freeable instead of becoming ready through silence or grace.
- Custom border drawing refuses malformed glyphs through checked placement instead of treating caller input as unreachable.
- The allocation-free drawing test observes the allocators captured by both owners and refuses new allocations and resizes after warmup.
- Screen fills and Window placement share whole-cell clipping so a wide or scaled fill stays inside its requested rectangle.
- List and Table bound visible ranges even when the viewport has no body rows.
- Wrapping and Window printing treat CRLF as one hard line break, including when clipping the rest of a line.
- Input deadline tests count reads, cancellation and the supplied budget on a synthetic clock instead of asserting wall-clock elapsed time.
- Breaking: Screen pools, allocation, geometry, pool identity and damage, and Renderer allocation, geometry, work buffers and baseline/link storage are internal; use dimensions(), resize and checked cell access.
- Replacement.settle advances acknowledgements and grace without creating a placement.
- Breaking: Canvas.Picture borrows Surface and Layers without a redundant allocator field.
- visor.Transmit names the transmission options accepted by Layers and Replacement.
- Markdown.Rows exposes the same borrowed visual ranges as drawing, with inline spans, block structure and opening fence metadata.
- Breaking: Markdown.Document owns internal parsing storage and exposes source, text, spans and blocks as borrowed const slices.
- ASCII batching checks its first cell against the Unicode neighbour so a prepend cannot join across grid cells.
- Codepoint measurement gives Unicode prepend characters their standalone column rather than dropping them as combining marks.
- Terminal scroll margins share zero-default parsing and check their order after clipping to the grid.
- Calendar measurement and drawing both leave invalid months empty.
- List and Table share bounded navigation so moving backward also clamps selections after items disappear.
- Resize rebuilds pools from the clipped and repaired grid so discarded cells retain no text or links.
- Raster strokes and ellipses keep finite extreme coordinates and tiny radii through their distance calculations.
- Breaking: Screen.cell, placement, copying, printing and widget drawing check glyphs and shapes with InvalidCell; terminal bridges use explicitly unchecked placement while pool handles remain checked.
- Breaking: Date uses checked init(year, month, day) construction and component accessors instead of mutable calendar literals.
- Breaking: Style dumps use as many padded base-62 digits per cell as their legend needs, including more than two beyond 3,844 styles.
- Breaking: Layers requires init(allocator); deinit, transmit, declare and retire, and Replacement.send, declare and retire, take no allocator, and mutable lists and metadata give way to images(), declarations(), placements(), answerPolicy() and fallbackCount().
- Breaking: Cell is forty-eight bytes while grids store thirty-two-byte cells; Screen.cells and rowAtMut are replaced by readCell, rowAt().len()/get() and checked placement operations.
- Window checks complete text and cell extents before placement, copying or multi-cell fills can cross a child boundary.
- Sextants weights RGBA brightness and cell colour by alpha so transparent pixels leave cells alone.
- Markdown reads a documented subset into an owned document and renders themed prose, quotes, lists, verbatim code and screen links to width.
- Canvas draws shared plotting shapes into antialiased RGBA pictures with normal or additive blending, or into terminal cells.
- Conformance properties use checked cell placement and support focused test selection through the package build.
- Documentation names the state owners and distinguishes inline text from pooled handle lifetimes.
- Restoring the terminal emulator's saved cursor clamps it to the resized grid.
- Growing terminal clusters and scaled text compare wide extents before narrowing at the u16 edge.
- The terminal emulator normalizes zero coordinates and clips line counts before narrowing them.
- POSIX restoration restores raw mode before best-effort output and never waits for output space.
- Canvas coordinates reject nonfinite input and keep finite extremes through normalization and line clipping.
- Probe quiet time and picture grace time saturate elapsed time across the signed clock range.
- Tabs share wide span arithmetic between measurement, drawing and hit testing.
- Bar charts check their label gutter and centred labels before narrowing coordinates.
- Wide rules stop before their last glyph crosses the coordinate edge.
- A line gauge whose label fills the row leaves no room for its gap.
- Sextant pictures check that their pixels exist before multiplying dimensions.
- Key strips saturate their widths and spacing without overflowing intermediate sums.
- Navigation and anchored scrolling clamp state without overflowing at the usize edge.
- Paragraph scrolling skips whole wide clusters at the u16 column edge.
- Charts check label and legend margins before narrowing their dimensions.
- Layout clips areas before padding, placement or repetition, and divides part counts without narrowing their totals.
- Picture placements convert to one-based terminal coordinates in u32 at the u16 edge.
- A failed session resize preserves both grids, pool handles and borrowed content until their new storage is ready.
- Silence to a direct image transmission never makes an unread shared-memory picture ready.
- Resizing the terminal emulator retains its open OSC 8 target, including before a cell uses it.
- Breaking: Layers.configureSharedMemory replaces mutable shared-memory configuration and the SharedMemory export; private object owners retain their cleanup Io, and names use a process-wide namespace.
- Breaking: pooled Text and Link handles carry their pool generation; placement, copying, printing, widget drawing and textOf can return InvalidHandle, Link.at, Text.atOffset and Text.slice are removed, and inlineSlice resolves inline text.
- Probe replies to disabled questions leave capabilities and the quiet period unchanged.
- Cell placement and printing compare wide extents before narrowing at the u16 coordinate edge.
- A failed terminal leave or flush keeps the mode intent for restoration through the saved descriptor.
- Rendering a different screen repaints even when its pooled cell IDs coincide, including when a screen address is reused.
- A failed resize preserves the screen, its pool identities, borrowed slices and damage.
- Printing documents its allocation rule: measurement allocates nothing; committing can allocate for unseen graphemes longer than six bytes.
- Breaking: `Screen.deinit`, `resize`, `compactPool`, `intern` and `link`, and `Renderer.deinit` and `resize`, use their captured allocator without another allocator argument.
- Borrowed text and target slices state their pool lifetime; `dupeTextAt`, `dupeTextOf` and `dupeTarget` make independent copies for retention.
- Breaking: image transmission can return `PayloadTooLarge`; shared memory reserves its owner and checks the protocol size before creating an object.
- Breaking: Tty.leave() releases its own renderer without an argument; Tty.enter can return AlreadyEntered, and raw terminals must stay at a stable address until restored, with their renderer alive.
- Pool compaction repaints text and pictures, including when resize compacts the pools.
- `zig build test -Dtest-filter=…` runs only matching tests.

## [0.4.0] - 2026-09-30

### Changed

- On morse 0.7.0.
- `Screen.link` refuses C0 controls and DEL in the URI and its params
  before interning them.
- Re-entering a renderer that was used repaints its text and pictures.

### Added

- `Session` holds the screen, renderer, size, caps, probe and layers,
  coalesces resizes and keeps mouse parsing in step; `ProbeWait` runs on
  caller-supplied time. A live-loop example runs on POSIX and Windows.
- `Renderer.setCaps` changes capabilities without leaving the screen.
- `Replacement` keeps one picture in flight and swaps it on
  acknowledgement or after a grace, with ids from an `ImageIds` range;
  `commitFrame(w, caps)` frees retired pictures, including in a frame with
  nothing else to draw.
- `Renderer.untrustCursor` forgets a cursor moved between frames; the
  renderer and the README state what a caller's one-off writes may change.
- `Winsize.locate` maps a mouse report to its cell and the fraction within
  it, from the fractional cell size.
- `fitEnd` keeps a text's end on a grapheme boundary beside a leading
  ellipsis.

## [0.3.0] - 2026-09-29

### Added

- **`Edges`: items at both edges of one line.** The right items keep their
  width; the left are clipped a `gap` before them. `Edges.width` measures a
  run of items the way the row does.
- **`Paragraph.Rows`**, the iterator `Paragraph` draws and counts with, so a
  caller that lays out wrapped text can keep its own data per row without
  wrapping it a second time.
- **`Table` has List's marker style and window.** `Table.marker_style`
  draws the marker, and the blank beside every other row, in a style of its
  own; `Table.visible(rows, &state)` says which rows a window that tall
  shows under its header, and how many it does not, with the offset moved
  as `draw` moves it. A table drawn by hand at worked-out columns and the
  same table drawn by `Table` are held to the same cells.
- **Pictures through shared memory.** `Layers.shared_memory`, set by a
  program whose terminal may be on the same machine, puts each picture in a
  POSIX shared memory object (`shm_open`, or `/dev/shm` on Linux without
  libc) and sends its name (`t=s`) instead of the pixels: no deflate and no
  base64 on the program's thread. The medium is tried on the first picture and
  turned off for good on an error or silence, that picture refused so it is
  sent again in the escape code; an object the terminal did not read is
  unlinked.
- **`Caps.sgr_pixels` is answered.** The probe asks for mode 1016 with the
  other modes, and a terminal that has it (set or reset) sets the field, so a
  program knows before it asks for the mouse in pixels.
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
- Each `Tty` that watches for a resize owns its pipe (`resizeFile`,
  `drainResize`), so two terminals watching each hear the signal and one
  stopping does not take the other's wake away; the handler goes in with the
  first watcher and the one it replaced comes back with the last.
- `Layers.repaint`: the next frame places every declared picture again, as
  though the terminal could have moved or dropped any of them. `Renderer`
  calls it on every repaint.
- The dump format is pinned byte for byte in the suite, on a screen that
  uses a bright ANSI name, a palette background, a truecolour foreground, a
  curly underline in a palette colour, a link, every attribute and a wide
  cluster's covered column; and the ids past sixty-two are pinned in order.
  A program keeping its goldens in the dump need not test the format
  itself.
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
- `dumpScreenWith` and `DumpOptions`: the grid as text with a filler written
  for a wide cluster's covered column, so every line is as many characters as
  the grid has columns, for a program that reads a column back by its place
  in the line. `dumpScreen`'s documentation said it wrote such a filler, which
  it never did; it holds each cluster once, as before, and now says so.
- `Rule.gap`: cells left as they are between two glyphs, a spaced rule that
  reads as broken rather than drawn.
- `Window.sub`: the child over a rectangle of the window's own cells, the
  shape `Layout.split` and `Layout.repeat` hand back, clipped to the window.
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
    null, for a program that styles the chosen item's runs itself, and so
    may `style`, which leaves the rows as they are and writes only the
    markers and the runs: a list laid over a panel whose ground is not the
    list's to set.
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
- `Input.nextWithin`: the next event, or null when the caller's timeout
  passes first. What is buffered is handed over even past the deadline, and a
  lone `ESC` still waiting at it stays held for the next read, so a wait that
  ends on silence — a probe's quiet period after the device attributes —
  needs no second task and loses nothing to a cancelled read.
- `Tty.enter` and `Tty.leave`: raw mode and a renderer's `enter` in one call,
  and the way back. A screen entered this way is undone by `Tty.restore`,
  `Tty.close`, `restoreGlobal` and `Panic` too — modes, alternate screen and
  cursor before the terminal's mode — through a buffer on the stack and a
  write that cannot fail. `Renderer.deinit` takes a renderer off that path.

### Changed

- **A cell of printable ASCII beside another is known to stay apart
  without the break tables.** `text.joinsCell`, which the renderer asks for
  every cell it writes or prices on a terminal measuring clusters, answers
  that case at once: printable ASCII is Grapheme_Cluster_Break Other on both
  sides, which always breaks. The answer is the one the rules give, checked
  for every printable pair after every kind of cluster before it. A frame of
  a scrolled 200x50 grid takes 23% less time.
- **The scroll detector hashes a row in stretches of cells.** On a terminal
  without OSC 8 or scaled text, what it shows was fed to the hash one cell
  at a time, and the hash's streaming state cost more than the hashing. The
  hashes are the same; a scrolled 200x50 frame with detection on takes 19%
  less time.
- **A row the diff would write as one run is painted without being
  priced.** Where a changed row keeps a few cells, the renderer priced the
  diff and the paint in full before writing either. When the first cell
  changed and the run planner bridges every unchanged gap after it, the
  diff is the paint byte for byte, so it is painted at once; the bytes are
  the same as before on every frame. A frame of a scrolled 200x50 grid
  takes 20% less time.
- `Tty` builds on conduit's terminal primitives (`conduit.tty`) for raw
  mode, the way back, the size and the device's name, instead of its own
  copies of the same calls, and the suite's pseudo-terminal is conduit's.
  The dependency is pinned by commit until conduit's next release; the
  module visor imports links no C library on Linux. On Windows the input handle
  no longer asks for window-size records, which a terminal-sequence read
  never returns.
- **Breaking:** `Screen` no longer holds the pictures. The grid is text,
  and a program that shows pictures keeps a `Layers` beside its screen and
  passes it to `Renderer.draw(w, screen, layers, caps)`, null when it shows
  none, since the renderer is what orders the text pass before the first
  graphics command.
- **Breaking:** a table's row is `Table.Row`; `widgets.Row` is gone, so the
  one `Row` a program meets is `visor.Row`, the row a wrap produced. The
  renderer's scroll detection lives in `moved_rows.zig`, which leaves
  `Scroll` meaning one thing: the widget.
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

- **The test emulator repeats what the pinned emulator repeats.** `REP`
  after a cluster printed the cluster's last codepoint again, a mark
  alone; libghostty-vt repeats the codepoint that began the cell (`e` +
  U+0301 then `CSI 2 b` is two more `e`), and joins the copies as it would
  any codepoint printed. The renderer repeats no cluster, so no output
  moves; `Term` is what the tests read a frame through.

- **A cluster that would join the cell on its left reaches a clustering
  terminal in a cell of its own, where mode 2027 off cannot keep it there.**
  A flag beside a lone regional indicator went out as it was, and a
  terminal measuring clusters joined the flag's first indicator to the
  lone one; measured by codepoint the flag takes four columns, so turning
  the mode off would not do. The left cell's columns are written blank,
  the cluster after them, then the left cell again, which joins nothing to
  its right (`Renderer.Stats.rejoined` counts them). A cluster that would
  join a blank as well is written as before.

- **Cells a clustering terminal would join stay apart.** A terminal in mode
  2027 joins a codepoint to the cell on the left of the cursor wherever the
  break rules find no break, so two regional indicators, a thumb and a skin
  tone, or anything and a spacing mark, drawn in cells of their own, showed
  as one cell. Such a cell now goes out with mode 2027 off around it, and a
  codepoint that would join its own copy is never repeated with `REP`.
  `Term`, the package's own emulator, joins the way the conformance build's
  emulator does, and the round trip draws these clusters in both.
- **A frame past 1024 bytes is bracketed.** The synchronised-output bracket
  was kept only for a frame larger than 8 KiB, on the reasoning that a
  smaller one reaches the terminal in one read. It does not: macOS's
  pseudo-terminal hands the terminal a write 1024 bytes at a time, so a
  frame of a few kilobytes arrived in pieces a terminal could draw between.
  `sync_gate` is 1024.
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
- On Windows a lone `ESC` waited for the next key: the wait was the read,
  with no timeout. It now waits on the console's input handle for the
  caller's timeout first, passing over input records a read would not
  return, and settles the key as it does elsewhere.
- `Layers.transmit` allocated a buffer to deflate into on every call. The
  buffer is kept with the layers and reused, so sending pictures frame
  after frame allocates nothing once it has grown to the largest.
- `visor.version` was a literal kept equal to the manifest by a test. It is
  read from `build.zig.zon` at build time and documented as what it is:
  the last release the source is or descends from, with what has changed
  since under `[Unreleased]`.
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
- **A disagreement the conformance build reports fails it.** The build
  printed a disagreement with `std.debug.print` and returned an error, so a
  test that expected the error -- the link test provoking one on purpose --
  printed "link disagrees" and passed, and a report could sit beside a pass.
  Reports now go through `std.log.err`, which fails the test that logged
  them whatever it returns; a test that provokes a disagreement asks where
  it is without reporting it.
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
