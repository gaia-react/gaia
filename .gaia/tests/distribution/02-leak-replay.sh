#!/usr/bin/env bash
# 02-leak-replay.sh
#
# Re-runs `gaia release scrub` on the staged tree as a defense-in-depth
# check. The same scrub already ran during build-staging.sh; running it
# twice on a clean tree must produce a clean result both times.
#
# This catches:
#   - non-idempotent scrub transforms (a regression class)
#   - staging tree mutations between scrub runs
#   - allowlist drift if the test fixture path differs from release.yml
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STAGING="$(mktemp -d -t gaia-dist-leak-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Re-run scrub as a leak-only pass. The first invocation already ran inside
# build-staging.sh; running again on a clean tree should be a no-op.
SCRUB_OUTPUT="$(mktemp)"
trap 'rm -rf "$STAGING" "$SCRUB_OUTPUT"' EXIT
if ! "$PROJECT_ROOT/.gaia/cli/gaia" release scrub "$STAGING" --json > "$SCRUB_OUTPUT" 2>&1; then
  log "Second scrub pass failed:"
  cat "$SCRUB_OUTPUT" >&2
  fail "scrub regression detected on second pass"
  exit 1
fi

# Parse JSON: assert blocks_stripped == 0 (first pass already stripped),
# leaks == [].
require_cmd jq "jq required for parsing scrub --json output"
BLOCKS=$(jq -r '.marker_strip.blocks_stripped' "$SCRUB_OUTPUT")
LEAK_COUNT=$(jq -r '.leaks | length' "$SCRUB_OUTPUT")
UNBALANCED_COUNT=$(jq -r '.unbalanced_markers | length' "$SCRUB_OUTPUT")

if [ "$BLOCKS" != "0" ]; then
  log "Second scrub pass stripped $BLOCKS marker block(s) — first pass missed them or tree was mutated"
  fail "scrub is not idempotent ($BLOCKS additional blocks stripped on rerun)"
  exit 1
fi

if [ "$UNBALANCED_COUNT" != "0" ]; then
  log "Unbalanced marker(s) detected:"
  jq -r '.unbalanced_markers[] | "  \(.file):\(.line) \(.reason)"' "$SCRUB_OUTPUT" >&2
  fail "$UNBALANCED_COUNT unbalanced marker(s)"
  exit 1
fi

if [ "$LEAK_COUNT" != "0" ]; then
  log "Leaks detected on rerun:"
  jq -r '.leaks[] | "  [\(.check)] \(.file):\(.line) \(.match)"' "$SCRUB_OUTPUT" >&2
  fail "$LEAK_COUNT leak(s) detected"
  exit 1
fi

# Belt-and-suspenders: also assert the post-build-staging tree contains
# no marker fragments that the strip should have caught.
MARKER_FRAGMENTS=$(grep -rn 'gaia:maintainer-only' "$STAGING" 2>/dev/null || true)
if [ -n "$MARKER_FRAGMENTS" ]; then
  log "Marker fragments survived strip:"
  printf '%s\n' "$MARKER_FRAGMENTS" >&2
  fail "marker fragments present in staging tree"
  exit 1
fi

pass "leak-replay clean (0 blocks, 0 leaks, 0 unbalanced markers)"
