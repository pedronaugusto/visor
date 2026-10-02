"""Shared reporting/build helpers; no benchmark clock is read here."""
import datetime
import hashlib
import io
import json
import os
import pathlib
import platform
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parent
BUILD = ROOT / 'build'
PINS = json.loads((ROOT / 'revisions.json').read_text())

def run(argv, **kwargs):
    subprocess.run([str(a) for a in argv], check=True, cwd=ROOT, **kwargs)

def capture(argv, **kwargs):
    return subprocess.check_output([str(a) for a in argv], cwd=ROOT, text=True, **kwargs).strip()

def snapshots():
    for side in ('before', 'after'):
        commit = PINS[side]
        assert capture(['git', 'rev-parse', commit + '^{commit}']) == commit
        dest = BUILD / 'revisions' / side
        marker = dest / '.bench-revision'
        if not marker.exists() or marker.read_text().strip() != commit:
            if dest.exists():
                import shutil
                shutil.rmtree(dest)
            dest.mkdir(parents=True)
            data = subprocess.check_output(['git', 'archive', commit], cwd=REPO)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                archive.extractall(dest, filter='data')
            marker.write_text(commit + '\n')
    # A moved main requires an intentional pin update, never a silent B change.
    if capture(['git', 'rev-parse', 'main']) != PINS['after']:
        raise SystemExit('main has moved: refresh revisions.json and merge main into bench before measuring')

def tools_setup():
    os.environ.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', PYTHONDONTWRITEBYTECODE='1', HOMEBREW_NO_AUTO_UPDATE='1')
    os.environ['BENCH_MODE'] = 'smoke' if '--smoke' in __import__('sys').argv else 'full'
    zig = os.environ.get('ZIG', 'zig')
    if capture([zig, 'version']) != '0.16.0':
        raise SystemExit('Use Zig 0.16.0 (set ZIG to its executable)')
    for key, path in {'CARGO_HOME':'cargo-home', 'CARGO_TARGET_DIR':'cargo-target',
                      'RUSTUP_HOME':'rustup', 'ZIG_GLOBAL_CACHE_DIR':'zig-global-cache'}.items():
        dest = BUILD / path
        dest.mkdir(parents=True, exist_ok=True)
        os.environ[key] = str(dest)
    rustup = os.environ.get('RUSTUP', 'rustup')
    probe = subprocess.run([rustup, 'run', '1.93.0', 'rustc', '--version'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if probe.returncode:
        if '--smoke' not in __import__('sys').argv:
            raise SystemExit('Missing prepared Rust toolchain; run bench/quiet.sh --smoke')
        run([rustup, 'toolchain', 'install', '1.93.0', '--profile', 'minimal', '--no-self-update'])
    return zig, [rustup, 'run', '1.93.0']

def machine(zig, rust):
    info = {'os': platform.system(), 'os_release': platform.release(), 'architecture': platform.machine(),
            'logical_cpus': os.cpu_count(), 'load_average': list(os.getloadavg()),
            'zig': capture([zig, 'version']), 'rustc': capture(rust + ['rustc', '--version']),
            'cargo': capture(rust + ['cargo', '--version']), 'python': platform.python_version()}
    if platform.system() == 'Darwin':
        for key in ('hw.model', 'hw.memsize', 'machdep.cpu.brand_string', 'hw.physicalcpu', 'hw.logicalcpu',
                    'hw.perflevel0.physicalcpu', 'hw.perflevel1.physicalcpu'):
            p = subprocess.run(['sysctl', '-n', key], capture_output=True, text=True)
            if p.returncode == 0:
                info[key] = p.stdout.strip()
        info['macos'] = capture(['sw_vers', '-productVersion'])
        p = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True)
        # Keep only power source/battery information, never user/host names.
        info['power'] = p.stdout.strip()
    return info

def finish(package, smoke, info, rows, correctness, versions, estimate):
    stamp = datetime.datetime.now(datetime.timezone.utc)
    dest = ROOT / 'results' / stamp.date().isoformat()
    dest.mkdir(parents=True, exist_ok=True)
    label = ('smoke-' if smoke else 'pass-') + stamp.strftime('%H%M%SZ')
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted((ROOT / 'src').rglob('*'))
                     if p.is_file() and '__pycache__' not in p.parts and 'target' not in p.parts}
    for name in ('build.zig', 'build.zig.zon', 'revisions.json', 'versions.json'):
        p = ROOT / name
        if p.exists(): source_hashes[name] = hashlib.sha256(p.read_bytes()).hexdigest()
    payload = {'package': package, 'mode': 'smoke' if smoke else 'full', 'status': 'passed',
               'date_utc': stamp.isoformat(), 'revisions': PINS,
               'harness_commit': capture(['git', 'rev-parse', 'HEAD']),
               'harness_dirty': bool(capture(['git', 'status', '--porcelain', '--untracked-files=no'])),
               'source_sha256': source_hashes, 'machine': info, 'versions': versions,
               'estimated_duration': estimate, 'correctness': correctness, 'samples': rows}
    if smoke:
        assert all(r.get('ns') is None for r in rows)
    (dest / (label + '.json')).write_text(json.dumps(payload, indent=2) + '\n')
    lines = [f'# {package} {"smoke" if smoke else "quiet pass"}', '',
             'Passed. No harness benchmark clocks sampled; no timing results. Native library profiling counters are not retrieved or recorded.' if smoke else 'Raw samples and paired summaries are in the accompanying JSON.', '',
             f'Before: `{PINS["before"]}`. After: `{PINS["after"]}`.',
             f'Estimated quiet-window duration (not measured): {estimate}.', '',
             '## Machine', '', '```json', json.dumps(info, indent=2), '```', '',
             '## Workloads', '', '| Library | Workload | Iteration | Status | Units | Nanoseconds |',
             '| --- | --- | --- | --- | --- | --- |']
    for r in rows:
        lines.append(f'| {r["library"]} | {r["workload"]} | {r["iteration"]} | {r["status"]} | {r.get("units", "")} | {r.get("ns") if r.get("ns") is not None else ""} |')
    if not smoke:
        from statistics import median
        lines += ['', '## Paired before/after', '', '| Workload | Median B/A | Pairs |', '| --- | --- | --- |']
        groups = {}
        for r in rows:
            if r['library'] in (package + '-before', package) and r.get('ns'):
                key = (r['workload'], r.get('chunk_bytes'), r.get('cols'), r.get('rows'), r['iteration'])
                groups.setdefault(key, {})[r['library']] = r['ns']
        ratios = {}
        for key, pair in groups.items():
            if len(pair) == 2:
                group = str(key[:-1])
                ratios.setdefault(group, []).append(pair[package] / pair[package + '-before'])
        for key, values in ratios.items():
            lines.append(f'| {key} | {median(values):.4f} | {len(values)} |')
    lines += ['', 'Correctness details and native counts are in the accompanying JSON.']
    (dest / (label + '.md')).write_text('\n'.join(lines) + '\n')
    print(f'Passed: {len(rows)} samples; results/{dest.name}/{label}.md and .json')
