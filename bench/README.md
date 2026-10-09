# visor's benchmarks

visor's own measurements of its own calls, read on a quiet machine.

```sh
zig build bench
zig-out/bench/visor-bench --smoke
zig-out/bench/visor-bench --row text_wrap --samples 61
```

`zig build bench` builds one program, `visor-bench`, in ReleaseFast under
`zig-out/bench` and runs it with no arguments. A pass generates its inputs
(`corpus.zig`, into `corpus/` under the working directory), checks every
workload untimed at 8x4, 80x24, 120x40 and 200x60, then measures each one at
80x24, 120x40 and 200x60 with shakedown's `bench`. A row is a workload at a
size, named `<task>/<cols>x<rows>`, printed as one JSON line on standard
output: every sample in nanoseconds a frame, in the order taken, with the best,
median and p99, the frames a sample times, the commit and the machine. The pass
says what it checked on standard error. `--row <prefix>` limits the pass to the
rows whose name starts with it (`--row cell_writes/80x24`), `--samples <n>`
sets the samples a row keeps (31 by default), and `--smoke` checks every
workload at 8x4 alone and runs it once there, reading no clock; `zig build
test` runs it so, in the test's mode. `zig build bench-ab` runs two commits
against each other through the same rows.

A sample is at least ten milliseconds of frames, grown from one until it is, so
a workload that takes a microsecond is timed over ten thousand frames and one
that takes ten milliseconds over one. One workload, `style_heavy`, is the
exception: each of its frames restyles every cell before it draws, outside the
clock, so its sample is one draw and a sample too short to read is an error.

Every workload is checked and measured in a process of its own, the same
program again, so that none meets the heap another left:

- `visor-bench draw <task> check <cols> <rows> <frames>` checks one
  drawing-core workload (`draw.zig`): `cell_reads`, `buffer_diff`,
  `full_repaint`, `unchanged_diff`, `style_heavy`, `unchanged_idle`,
  `picture_layers` and `picture_unchanged`.
- `visor-bench ops`, the same arguments, checks one of the other 55 public
  operations (`ops.zig`): cell writes, printing, scrolling, resizing, links,
  the pools, width and wrapping, layout, every widget, Markdown, input, the
  emulator and the four picture protocols. `visor-bench ops list-tasks` names
  them. Their text inputs are read from the directory `VISOR_BENCH_CORPUS`
  names.
- `visor-bench measure <draw|ops> <task> <cols> <rows> <samples> <full|smoke>
  <prefix>` measures one of them, which is what the pass runs for each row.

`harness.zig` says what a workload is: a fixture built before any clock, the
frame the clock reads, and the evidence of the frames a check ran. A check
prints its evidence and a last line, `result\t<frames>\t<count>\t<bytes>`; the
checks do not trust visor's own emulator: `terminal.zig` is an independent
decoder for the bytes visor writes (text, RGB and bold SGR, cursor, erase,
scroll regions, OSC 8, kitty upload and placement) that reads widths from
uucode's tables rather than visor's rule, and every drawing-core frame is
replayed through it. `ops_check.zig` checks each operation's grid, value or
frames, and states an invariant where the layout is visor's own choice.
`pictures.zig` decodes sixel bands and palettes and the PNG, so all four picture
protocols agree on one red rectangle. The checks' Unicode properties are a
second uucode table in the same program, so visor's own table is the one a
consumer builds.
