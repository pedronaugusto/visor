#!/usr/bin/env bash
#
# visor — README.md's Usage block is what ci/readme_usage.sh produces.
#
# The block is delimited in the document by the two GENERATED markers; this
# script rebuilds the file with the region replaced and diffs it against what
# is committed, so the snippet cannot drift from the example CI runs.
#
# Usage: ci/check-readme.sh          # diffs, exit 1 on drift
#        ci/check-readme.sh --write  # rewrites README.md in place

set -euo pipefail
cd "$(dirname "$0")/.."

generated=$(ci/readme_usage.sh)

updated=$(BLOCK="$generated" python3 - <<'PY'
import os
import pathlib
import sys

BEGIN = "<!-- BEGIN GENERATED ci/readme_usage.sh -->"
END = "<!-- END GENERATED -->"

text = pathlib.Path("README.md").read_text(encoding="utf-8")
before, marker, rest = text.partition(BEGIN)
if not marker:
    sys.exit("README.md: missing %s" % BEGIN)
_, marker, after = rest.partition(END)
if not marker:
    sys.exit("README.md: missing %s" % END)

sys.stdout.write(before + BEGIN + "\n" + os.environ["BLOCK"] + "\n" + END + after)
PY
)

if [ "${1-}" = "--write" ]; then
    printf '%s' "$updated" > README.md
    exit 0
fi

if ! printf '%s' "$updated" | diff -u README.md - ; then
    echo
    echo "README.md's Usage block is out of date. Run ci/check-readme.sh --write" >&2
    exit 1
fi
