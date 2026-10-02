#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
    exec caffeinate -dims "${PYTHON:-python3}" src/quiet.py "$@"
fi
exec "${PYTHON:-python3}" src/quiet.py "$@"
