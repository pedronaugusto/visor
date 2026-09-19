#!/usr/bin/env bash
#
# visor — the suite on Linux, from a machine that is not one.
#
# CI runs Linux, macOS and Windows on every push; this is the same Linux job
# reachable before the push, because "it passed on my Mac" is not a claim
# about a package whose users are mostly on Linux. The image is built from
# ci/linux.Dockerfile and cached by tag, so only the first run downloads a
# compiler.
#
# The cache directories are inside the container, not the bind mount: a
# .zig-cache written by a Linux build and then read by a macOS one is a
# confusing way to lose an afternoon.
#
# Usage: ci/linux.sh            # Debug and ReleaseSafe
#        ci/linux.sh --all      # all four optimize modes

set -euo pipefail
cd "$(dirname "$0")/.."

image=visor-linux-zig-0.16.0

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> building $image"
    docker build -f ci/linux.Dockerfile -t "$image" ci
fi

modes=(Debug ReleaseSafe)
if [ "${1-}" = "--all" ]; then
    modes=(Debug ReleaseSafe ReleaseFast ReleaseSmall)
fi

for mode in "${modes[@]}"; do
    echo "==> linux: zig build test -Doptimize=$mode"
    docker run --rm -v "$PWD:/src:ro" -w /src "$image" \
        zig build test -Doptimize="$mode" -p /tmp/zo \
        --cache-dir /tmp/zc --global-cache-dir /tmp/zg
done

echo "==> linux: zig fmt --check"
docker run --rm -v "$PWD:/src:ro" -w /src "$image" \
    zig fmt --check build.zig build.zig.zon src examples

echo "all green on linux"
