#!/usr/bin/env bash
# Run all sandbox-enablement conformance tests (bats-core).
# Walks .gaia/tests/sandbox/*.bats in lexicographic order.
# Exits 0 if all tests pass (skips are not failures), 1 if any fail.
#
# Prerequisites:
#   bats-core on PATH; install via:
#     brew install bats-core          (macOS)
#     apt-get install -y bats         (Debian/Ubuntu CI)
#     npx -y bats@latest              (fallback, any platform)
#
# The npm package is `bats`, not `bats-core`. The project is bats-core and the
# Homebrew formula is bats-core, but no `bats-core` package is published to npm,
# so that spelling resolves to an E404 rather than to a fallback.
#
# CI: wired into .github/workflows/audit-ci-tests.yml, gated on that workflow's
# `sandbox` paths-filter output. Two tests self-skip there by design: UAT-016
# needs a sandbox-capable runner, and the docs-link reachability check skips
# under CI so a third-party outage cannot red a declared-required context.
# `pnpm test:sandbox` recovers the docs-link check and nothing else. UAT-016
# additionally needs GAIA_SANDBOX_CAPABLE=1 and a repo-root .env, so a plain
# hand run still skips it; a green run here is not evidence that the OS-level
# enforcement path was exercised.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> .gaia/tests/sandbox/run-all.sh"

# Ensure bats is available; attempt npx fallback if not on PATH.
if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH; attempting: npx -y bats@latest"
  if command -v npx >/dev/null 2>&1; then
    # Run via npx; replace this process so $? propagates correctly.
    exec npx -y bats@latest "$HERE"/*.bats
  else
    echo "ERROR: bats not installed and npx not available. Install bats-core first." >&2
    exit 1
  fi
fi

for f in "$HERE"/*.bats; do
  echo "--> $(basename "$f")"
  bats "$f"
done

echo "==> all sandbox conformance tests passed"
