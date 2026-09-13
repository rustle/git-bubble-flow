#!/usr/bin/env bash
# Conformance harness: runs the bats suite against the Swift binary through the
# same multi-call symlinks a real install provides, so the tests exercise the
# installed shape rather than a bespoke test entry point.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if ! command -v bats >/dev/null 2>&1; then
    echo "ERROR: bats not found. Install it:" >&2
    echo "  macOS:         brew install bats-core" >&2
    echo "  Ubuntu/Debian: apt-get install bats" >&2
    echo "  Or run the suite in the container: make conformance" >&2
    exit 1
fi

configuration="${CONFIGURATION:-debug}"
binary="${BUBBLE_FLOW_BINARY:-}"
if [[ -z "$binary" ]]; then
    echo "Building git-bubble-flow ($configuration)..."
    swift build -c "$configuration" --product git-bubble-flow
    binary="$(swift build -c "$configuration" --show-bin-path)/git-bubble-flow"
fi

if [[ ! -x "$binary" ]]; then
    echo "ERROR: not an executable: $binary" >&2
    exit 1
fi
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"

# One symlink per git subcommand, exactly what the Homebrew formula installs.
shim_dir="$(mktemp -d)"
trap 'rm -rf "$shim_dir"' EXIT
for shim in git-verify-bubble git-land-bubble git-rebase-bubble git-bubble-absorb bubble-flow-setup; do
    ln -s "$binary" "$shim_dir/$shim"
done

export PATH="$shim_dir:$PATH"
export BUBBLE_FLOW_BINARY="$binary"
export BUBBLE_FLOW_SHIMS="$shim_dir"

echo "Binary under test: $binary"
echo "Shims:             $shim_dir"
echo ""
echo "=== Integration (conformance) ==="
bats test/integration/
echo ""
echo "=== Unit (packaging shape) ==="
bats test/unit/
