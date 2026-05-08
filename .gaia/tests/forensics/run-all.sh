#!/usr/bin/env bash
# Run all forensics UAT fixture tests (bats-core).
# Walks .gaia/tests/forensics/*.bats in lexicographic order.
# Exits 0 if all tests pass, 1 if any fail.
#
# Prerequisites:
#   bats-core on PATH — install via:
#     brew install bats-core          (macOS)
#     apt-get install -y bats         (Debian/Ubuntu CI)
#     npx -y bats-core@latest         (fallback, any platform)
#
# CI: add the following step before this script in your workflow:
#   - run: bash .gaia/tests/forensics/run-all.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> .gaia/tests/forensics/run-all.sh"

# Ensure bats is available; attempt npx fallback if not on PATH.
if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH — attempting: npx -y bats-core@latest"
  if command -v npx >/dev/null 2>&1; then
    # Run via npx; replace this process so $? propagates correctly.
    exec npx -y bats-core@latest "$HERE"/*.bats
  else
    echo "ERROR: bats not installed and npx not available. Install bats-core first." >&2
    exit 1
  fi
fi

for f in "$HERE"/*.bats; do
  echo "--> $(basename "$f")"
  bats "$f"
done

echo "==> all forensics tests passed"
