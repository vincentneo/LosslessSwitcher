#!/bin/bash
set -euo pipefail
# Supply the pinned Sweep.swift source from the resolved Swift package checkout.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/Sweep/Sources/Sweep/Sweep.swift" >&2
    exit 2
fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sweep_source="$1"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -emit-module -emit-library -module-name Sweep "$sweep_source" \
    -o "$test_dir/libSweep.dylib" -emit-module-path "$test_dir/Sweep.swiftmodule"
xcrun swiftc -I "$test_dir" -L "$test_dir" -lSweep \
    "$repo_root/Quality/CMPlayerStuff.swift" "$repo_root/Tests/Regression/main.swift" \
    -o "$test_dir/regression"
DYLD_LIBRARY_PATH="$test_dir" "$test_dir/regression"
