# visor architecture

Visor exposes a terminal drawing base and a widget module. Widgets import the
base; the base never imports widgets. Consumers fetch morse for terminal
sequences, conduit.tty for terminal calls and uucode for Unicode properties.
Preflight and shakedown are lazy dependencies reached only by visor's own
build, tests and benchmarks. Corpus data is not published to consumers.

## Benchmark ownership

Visor owns workload definitions, generated inputs, fixture construction and
independent behavior checks. Shakedown owns benchmark timing, warmup, batching,
statistics, JSONL provenance and comparison. Preflight owns benchmark build,
smoke and A/B steps through `Config.bench`. There is no vendored benchmark
library or build-time patch of a dependency.

The entry point creates inputs and checks drawing frames and operation
evidence outside measurement. Each workload runs in a separate process to
isolate its fixtures and widget state. Each operation prepares its fixtures,
then supplies its original measured loop as a shared benchmark callback.
Process startup, file reads, fixture construction and reporting do not become
part of that loop. Workload names include grid dimensions; units remain frames.

Callbacks retain observable results and prepared context across shared warmup
and samples. Count-based guards remain correctness tests. JSONL emitted by the
shared module is validated before the entry point forwards it; child failures,
malformed evidence and incorrect frame counts fail the pass.

A workload whose original boundary requires untimed work between measured
operations needs a shared API that can express that boundary. It must fail
explicitly until the shared owner supports it; adding a local timer or silently
including that work would break ownership or comparability. `style_heavy`
requires this seam because it restyles the screen outside each measured draw.
