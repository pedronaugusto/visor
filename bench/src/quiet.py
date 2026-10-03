#!/usr/bin/env python3
import argparse
import json
import subprocess
import os
import sys
from quiet_support import ROOT, BUILD, PINS, run, tools_setup, snapshots, machine, finish
from verify import verify

p = argparse.ArgumentParser(description='Complete visor quiet pass; --smoke never samples benchmark clocks')
p.add_argument('--smoke', action='store_true')
p.add_argument('--check-prepared', action='store_true', help='Verify artifacts without building or measuring')
args = p.parse_args()
sys.path.insert(0, str(ROOT))
from prepared import Prepared
prepared = Prepared(ROOT, BUILD)
if not args.smoke:
    from quiet_support import capture
    if capture(['git','rev-parse',PINS.get('after_ref', 'main')]) != PINS['after']:
        raise SystemExit('after ref has moved: refresh revisions.json before measuring')
    prepared.check()
if args.check_prepared:
    raise SystemExit(0)
zig, rust = tools_setup()
if args.smoke:
    snapshots()
    run([zig, 'build', '-j1', '-Doptimize=ReleaseFast', '--prefix', BUILD / 'zig-out'])
    run(rust + ['cargo', 'build', '-j1', '--release', '--locked', '--manifest-path', 'src/rust/Cargo.toml'])
    run([sys.executable, "src/prepare_notcurses.py"])
prepared.require(BUILD/'zig-out/bin')
prepared.require(BUILD/'cargo-target/release/visor-comparison')
prepared.require(BUILD/'notcurses-bench')
prepared.require(BUILD/'terminfo')
info = machine(zig, rust)
from quiet_support import capture
info["cc"] = capture([os.environ.get("CC", "cc"), "--version"]).splitlines()[0]
info["cmake"] = capture(["cmake", "--version"]).splitlines()[0]
if sys.platform == "darwin": info["libunistring"] = capture(["brew", "list", "--versions", "libunistring"])
TASKS = ['buffer_diff', 'full_repaint', 'unchanged_diff', 'style_heavy', 'unchanged_idle', 'picture_layers', 'picture_unchanged']

def invoke(side, task, mode, cols, rows, iterations):
    binary = BUILD / ("notcurses-bench" if side == "notcurses" else 'cargo-target/release/visor-comparison' if side == 'ratatui' else
                      'zig-out/bin/visor-before' if side == 'visor-before' else 'zig-out/bin/visor-after')
    env = os.environ.copy()
    if side == 'notcurses':
        env.update(TERMINFO=str(BUILD / 'terminfo'), TERMINFO_DIRS=str(BUILD / 'terminfo'),
                   TERM='xterm-direct', COLUMNS=str(cols), LINES=str(rows))
        env.pop('NO_COLOR', None)
    lines = subprocess.check_output([str(binary), task, mode, str(cols), str(rows), str(iterations)],
                                    text=True, env=env, stdin=subprocess.DEVNULL, start_new_session=True).splitlines()
    assert lines[-1].startswith('result\t'), (side, task, lines)
    count, cells, written, ns = map(int, lines[-1].split('\t')[1:])
    assert count == iterations
    if mode != 'full': assert ns == 0
    return {'units':count, 'native_count':cells if cells >= 0 else None, 'output_bytes':written, 'ns':ns if mode == 'full' else None}, lines[:-1]

# Full-size correctness is untimed. Independently replay every output frame;
# generated ASCII/RGB/bold intents are identical at each implementation.
checks = []
for cols, rows in [(8, 4), (120, 40), (200, 60)]:
    for task in TASKS:
        sides = ['visor-before', 'visor'] + (['ratatui'] if task in TASKS[:4] else []) + (['notcurses'] if task in TASKS[1:4] else [])
        for side in sides:
            result, frames = invoke(side, task, 'check', cols, rows, 3)
            evidence = verify(task, cols, rows, frames, result)
            checks.append({'library':side, 'workload':task, 'cols':cols, 'rows':rows, **evidence})
reps = 1 if args.smoke else 7
sizes = [(8, 4)] if args.smoke else [(120, 40), (200, 60)]
iterations = 1 if args.smoke else 1000
samples = []
for cols, rows in sizes:
    for task in TASKS:
        for rep in range(1, reps + 1):
            for side in ['visor-before', 'visor'] + (['ratatui'] if task in TASKS[:4] else []) + (['notcurses'] if task in TASKS[1:4] else []):
                result, frames = invoke(side, task, 'smoke' if args.smoke else 'full', cols, rows, iterations)
                samples.append({'library':side, 'workload':task, 'cols':cols, 'rows':rows,
                                'iteration':rep, 'status':'smoke' if args.smoke else 'measured', **result})
# Explicit unavailable rows keep capability exclusions visible in both artifacts.
for task in TASKS[4:]:
    samples.append({'library':'ratatui', 'workload':task, 'iteration':0, 'status':'unavailable: no equivalent retained-screen or picture-layer API', 'ns':None})
for task in ['buffer_diff', 'unchanged_idle', 'picture_layers', 'picture_unchanged']:
    samples.append({'library':'notcurses', 'workload':task, 'iteration':0,
                    'status':'unavailable: no equivalent pure diff or retained-screen API; headless profile has no picture protocol negotiation', 'ns':None})
correctness = {'checks':checks, 'count':len(checks), 'oracle':'Independent ASCII, SGR, cursor, erase and kitty placement decoder',
               'notcurses':'Public render+rasterize API, dedicated sink redirected to memory; fixed RGB terminfo; no terminal opened. Native profiling counters are not retrieved or recorded.'}
finish('visor', args.smoke, info, samples, correctness, json.loads((ROOT / 'versions.json').read_text()),
       '1–5 minutes quiet-only; see bench/QUIET-PREP.md for counts and assumptions')

if args.smoke: prepared.write()
