#!/usr/bin/env bash
#
# visor — README.md's Usage snippet, extracted from examples/usage.zig.
#
# A code snippet in a README is a claim about how the library is used, and
# nothing compiles it. This one is a region of an example that `zig build
# examples` builds AND runs, so `ci/check-readme.sh` comparing this output
# against the document is what keeps the two the same thing.
#
# Usage: ci/readme_usage.sh          # writes the fenced block to stdout

set -uo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
import pathlib
import sys

source = pathlib.Path("examples/usage.zig")
text = source.read_text(encoding="utf-8")

MARKER = "// --- README:usage ---"
parts = text.split(MARKER)
if len(parts) != 3:
    sys.exit(
        "%s: expected exactly two %s markers, found %d"
        % (source, MARKER, len(parts) - 1)
    )

# The imports are the lines a reader needs that cannot live inside main, so
# they are read from the file too rather than written out here.
imports = [
    line
    for line in text.splitlines()
    if line.startswith('const std = @import("std");')
    or line.startswith('const visor = @import("visor");')
]
if len(imports) != 2:
    sys.exit("%s: expected one std import and one visor import" % source)

body = []
for line in parts[1].splitlines():
    # The region sits inside main; the README shows it at the left margin.
    body.append(line[4:] if line.startswith("    ") else line)

print("```zig")
print("\n".join(imports))
print()
print("\n".join(body).strip("\n"))
print("```")
PY
