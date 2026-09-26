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

# A package the manifest takes by path while it is untagged
# (build.zig.zon's `.path`) lives beside the checkout: it is mounted where
# the manifest looks for it, read-only.
path_mounts=()
while IFS= read -r dep; do
    if [ ! -d "$dep" ]; then
        echo "ci/linux.sh: build.zig.zon takes $dep by path and it is not there" >&2
        exit 1
    fi
    inside=$(python3 -c 'import os, sys; print(os.path.normpath(os.path.join("/src", sys.argv[1])))' "$dep")
    path_mounts+=(-v "$(cd "$dep" && pwd):$inside:ro")
done < <(sed -n 's/.*\.path = "\([^"]*\)".*/\1/p' build.zig.zon)

run_in_linux() {
    docker run --rm -v "$PWD:/src:ro" ${path_mounts[@]+"${path_mounts[@]}"} -w /src "$image" "$@"
}

for mode in "${modes[@]}"; do
    echo "==> linux: zig build test -Doptimize=$mode"
    run_in_linux \
        zig build test -Doptimize="$mode" -p /tmp/zo \
        --cache-dir /tmp/zc --global-cache-dir /tmp/zg
done

echo "==> linux: zig fmt --check"
run_in_linux zig fmt --check build.zig build.zig.zon src examples

echo "all green on linux"
