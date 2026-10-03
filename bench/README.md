# visor benchmark preparation

Run `./bench/quiet.sh --smoke` from the repository root to build both package
revisions, ratatui and notcurses; run full-size untimed correctness checks;
then execute each available workload once on an **8×4** grid. Smoke reads no
harness benchmark clock and records no timings. Notcurses maintains intrinsic
profiling counters internally; they are not retrieved, reported or recorded.
On an idle machine, `./bench/quiet.sh` runs the complete timed pass. On macOS
the entry point prevents sleep during the pass.

Allow **15 minutes per package** in the quiet window; expected warm-cache
execution is about **1–5 minutes** after smoke preparation, an estimate rather than a measured
duration. First source downloads/compilation can add several minutes. Builds
and correctness finish before timed workloads begin. Results are plain
Markdown plus JSON under `bench/results/<UTC-date>/smoke-<time>.*` or
`pass-<time>.*`. Build caches, dependencies and results are ignored by Git.
The harness lives on `bench`, created from current main; main has no harness.

## Revisions and order

`revisions.json` fixes A at `4ef702d25f50b37906146582d6ee0ca3ae57934b`, the last
first-parent main commit before **2026-09-30 00:00:00 +01:00**, and B at
`398c7449fff6fd4c3db8c77833a2e585eb4447f6` on `diff` (`after_ref`). The explicit midnight cutoff avoids Git's bare date
inheriting the time of day. The runner extracts exact `git archive` snapshots into ignored
`build/revisions/` directories. The after build consumes the remote archive
and Zig hash in `build.zig.zon`, with its own pinned dependencies. Refresh the pins and `after_ref` when the target moves; a silently changed
local target ref fails the run. `after_ref` defaults to `main` for older pins.

Every workload runs **A, B, applicable comparisons, A, B, applicable
comparisons …**, seven rounds at **120×40** and **200×60**, with **1,000 frames
per sample**. Builds, input generation, output reporting, image transmission,
and initial warm frames are outside the interval. Glyphs, style choices,
changed cells and picture positions are identical at both package revisions.

Minimal compatibility code adapts allocator arguments on Screen/Renderer/
Layers cleanup and declaration/transmission, default Layers construction to
`Layers.init`, and the new fallible `writeOwnedCell`. The after revision uses public `Screen.diff` for `buffer_diff`; the before
revision uses `readCell`/`Cell.eql` because it has no owner comparison API.
Both use `readCell`/`Cell.eql` for the separate `cell_reads` diagnostic.
Neither workload reads a private storage layout. The old package
does not re-export `Transmit`, so identical option literals are passed to the
native public transmission calls. No package implementation is changed.

## Workloads and useful comparisons

| Workload | visor before/after | ratatui | notcurses |
| --- | --- | --- | --- |
| `buffer_diff` | Native owner diff after; public cell equality before; every 97th cell changed | `Buffer.diff` over the same prepared cells | Unavailable: no equivalent pure diff API |
| `cell_reads` | Public checked cell reads and equality over the same prepared screens | Unavailable: visor read diagnostic | Unavailable: no equivalent pure diff API |
| `full_repaint` | Force complete repaint of a prepared frame | Empty baseline diff + Crossterm backend | Render/rasterize after a different complete baseline |
| `unchanged_diff` | Mark all rows damaged, then compare equal cells | Equal buffer diff + backend | Render/rasterize the unchanged plane |
| `style_heavy` | Change every cell's RGB and bold; glyphs stay fixed | Same alternating styled buffers + backend | Same alternating styled plane + rasterizer |
| `unchanged_idle` | Retained screen with no new damage | Unavailable: its buffer API still requires diff | Unavailable: its render API still scans/composites |
| `picture_layers` | Move one pre-transmitted 16×16 RGBA picture between two columns | Unavailable: no picture-layer API | Unavailable in the fixed headless profile |
| `picture_unchanged` | Re-declare the same picture placement | Unavailable: no picture-layer API | Unavailable in the fixed headless profile |

These are drawing-core jobs, excluding widgets, frame construction and terminal
I/O. Native allocation/representation policies remain part of the measurement.
The visor after pure diff iterates changed positions inside the screen owners;
its before fallback and the separate `cell_reads` diagnostic scan exported
public cells. Ratatui's native diff allocates its update list. This is a public-API job comparison, not
a claim that their internal algorithms or cell representations are identical.
Ratatui's backend may emit style resets for an empty diff; output bytes expose
that policy while the oracle verifies that no cell changes.

Style-heavy visor uses one Screen owner: alternating independent Screen owners
would force current-main handle invalidation and introduce an artificial full
repaint. Public cell writes prepare each style frame outside its per-draw clock;
ratatui likewise clocks only prepared-buffer diff/encoding. Other visor/ratatui
workloads use one clock pair per batch. Notcurses frame preparation is also
excluded: complete/style-changing frames use per-frame clocks, and unchanged
diff uses one clock pair per batch. Timer overhead is part of these samples;
read native counts and scope alongside comparisons.

Notcurses **3.0.17** is built unchanged as a minimal core with multimedia off,
using a committed RGB-only terminfo profile and no controlling terminal. Its
`ncpile_render_to_buffer` returned empty frames in the correctness check because
that pinned implementation omits postpaint. The adapter instead calls the
working public `ncpile_render` + `ncpile_rasterize`, capturing `write` calls to
a dedicated sink into a reserved/reused memory buffer. Other writes retain
libc behavior. Its native signal masking, composition and intrinsic profiling
remain part of that job. No encoder or renderer logic is patched. Its returned
wire frames pass the same independent glyph/style oracle as the other tools.
See the [public API](https://notcurses.com/notcurses_render.3.html) and the
[pinned implementation](https://github.com/dankamongmen/notcurses/blob/v3.0.17/src/lib/render.c).

Picture frames include declaration, placement diff, encoding and frame commit;
transmission/base64, compression, image generation, acknowledgements and actual
terminal ingestion are outside the measured interval. The same ID, placement,
cell rectangle and pixels are used before/after. A graphics comparison with
notcurses would need a separately controlled capability/terminal profile; this
harness marks it unavailable. No cross-library picture speed ratio is implied.

## Builds and checks

Zig **0.16.0**, Rust **1.93.0**, Python **3.12+**, rustup, a C compiler, CMake,
make, pkg-config, tic and libunistring development files are required. On macOS,
CMake/pkgconf/libunistring can be provided by Homebrew; the runner reads its
prefix without installing packages. `ZIG`, `RUSTUP`, `PYTHON`, and `CC` may
select tools. Ratatui **0.30.1**, Crossterm **0.29.0**, direct and transitive
Rust dependencies are pinned by the manifest and lockfile. Notcurses and
ncurses **6.6** source archives are SHA-256 checked through `versions.json`.
Rust toolchains, static ncurses/notcurses libraries and their caches are built
locally. Dependency installation explicitly suppresses terminal database
installation; only the committed profile is compiled into an ignored directory.
No source paths, user names or host names are recorded in branch files.

Zig uses ReleaseFast; Rust uses cargo release; C/notcurses use optimized Release.
Builds use one job each. Correctness runs at **8×4, 120×40 and 200×60**, three
transitions each, before the smoke/timed workloads. `verify.py` independently
replays ASCII, SGR RGB/bold, cursor, erase and kitty transmission/placement
commands, then checks every cell against a generated intent. Unrecognized
commands fail. Pure diff counts are checked independently. Picture checks
validate the exact RGBA payload, image identity, placement rectangle, moves,
and unchanged declarations. Checksums let corresponding frames be compared
across revisions/libraries without requiring identical wire encodings.

JSON records pinned revisions, harness commit/source hashes, tool versions,
machine OS/CPU/memory/power/load information, correctness evidence, raw samples
in execution order, unavailable comparisons, output bytes, native cell counts
where exposed, and null time fields for smoke. Markdown records machine info,
workloads and (only for a full pass) paired B/A medians. No timing results are
committed. Earlier measurements from a busy machine are not reproduced or
claimed here; the prepared quiet pass will provide fresh evidence.

See [QUIET-PREP.md](QUIET-PREP.md) for the preparation contract and duration estimate.
