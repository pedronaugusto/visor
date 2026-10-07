# visor's benchmarks

visor's own measurements of its own calls. They run on a quiet machine and
never in CI; CI only compiles them (`zig build check`). They build on Linux
and macOS.

```sh
zig build bench -Doptimize=ReleaseFast
zig-out/bench/visor-bench --smoke
zig-out/bench/visor-bench --runs 7
```

`zig build bench` installs three programs in `zig-out/bench`:

- `visor-draw <task> <check|smoke|full> <cols> <rows> <iterations>` runs one
  drawing-core workload (`draw.zig`): `cell_reads`, `buffer_diff`,
  `full_repaint`, `unchanged_diff`, `style_heavy`, `unchanged_idle`,
  `picture_layers` and `picture_unchanged`.
- `visor-ops`, the same arguments, runs one of the other 55 public operations
  (`ops.zig`): cell writes, printing, scrolling, resizing, links, the pools,
  width and wrapping, layout, every widget, Markdown, input, the emulator and
  the four picture protocols. `visor-ops list-tasks` names them.
- `visor-bench` generates the inputs (`corpus.zig`, into `zig-out/bench/corpus`),
  then checks every workload untimed at 8x4, 80x24, 120x40 and 200x60, then
  times each one `--runs` rounds at 80x24, 120x40 and 200x60, 1,000 frames a
  sample, and prints the median time a frame and the bytes a frame wrote.
  `--smoke` runs each workload once on an 8x4 grid after the checks and reads
  no clock; `--only <workload>` runs one.

A program's last line is `result\t<frames>\t<count>\t<bytes>\t<ns>`; a check
run prints its evidence before it. The checks do not trust visor's own
emulator: `terminal.zig` is an independent decoder for the bytes visor writes
(text, RGB and bold SGR, cursor, erase, scroll regions, OSC 8, kitty upload
and placement) that reads widths from uucode's tables rather than visor's
rule, and every drawing-core frame is replayed through it. `ops_check.zig`
checks each operation's grid, value or frames, and states an invariant where
the layout is visor's own choice. `pictures.zig` decodes sixel bands and
palettes and the PNG, so all four picture protocols agree on one red
rectangle.
