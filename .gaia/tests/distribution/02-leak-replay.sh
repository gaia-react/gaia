#!/usr/bin/env bash
# 02-leak-replay.sh
#
# Re-runs `gaia-maintainer release scrub` on the staged tree as a
# defense-in-depth check. The same scrub already ran during
# build-staging.sh; running it twice on a clean tree must produce a clean
# result both times.
#
# This catches:
#   - non-idempotent scrub transforms (a regression class), asserted over
#     every mutating transform's own count rather than marker-strip's alone
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
if ! "$PROJECT_ROOT/.gaia/cli/gaia-maintainer" release scrub "$STAGING" --json > "$SCRUB_OUTPUT" 2>&1; then
  log "Second scrub pass failed:"
  cat "$SCRUB_OUTPUT" >&2
  fail "scrub regression detected on second pass"
  exit 1
fi

# Parse JSON: every mutation counter must read 0 (the first pass already did
# the work), leaks == [], unbalanced_markers == [].
require_cmd jq "jq required for parsing scrub --json output"
LEAK_COUNT=$(jq -r '.leaks | length' "$SCRUB_OUTPUT")
UNBALANCED_COUNT=$(jq -r '.unbalanced_markers | length' "$SCRUB_OUTPUT")

# Idempotence is asserted over EVERY mutating transform, and the set of them
# is DERIVED from the report rather than listed here. Each transform reports
# under its own object key with a numeric count of what it changed, so
# enumerating the report's numeric fields covers a transform added later with
# no edit to this file.
#
# Deriving is the point, not a convenience. A hand-maintained list of counters
# is the same shape `.gaia/release-scrub.yml` records as having recurred five
# times before the leak-check scopes stopped being lists, and it had already
# rotted here once: this harness read `marker_strip.blocks_stripped` alone
# while three other transforms mutated unasserted. A list would rot here next.
MUTATION_COUNTERS="$(jq -r '
  to_entries[]
  | select(.value | type == "object")
  | .key as $transform
  | .value
  | to_entries[]
  | select(.value | type == "number")
  | "\($transform).\(.key)=\(.value)"
' "$SCRUB_OUTPUT")"

# Two fail-closed guards on the derivation itself, because an enumeration that
# comes back short reads exactly like a clean run. The first catches the report
# losing its shape wholesale; the second catches one transform's counter being
# removed or retyped, which would otherwise drop silently out of the
# enumeration while its sibling counters still read 0. A counter merely
# RENAMED needs no guard: it is still enumerated, under its new name, and
# still has to read 0.
if [ -z "$MUTATION_COUNTERS" ]; then
  log "scrub --json report:"
  cat "$SCRUB_OUTPUT" >&2
  fail "no mutation counters found in the scrub report; its shape changed"
  exit 1
fi

COUNTERLESS="$(jq -r '
  to_entries[]
  | select(.value | type == "object")
  | select([.value | to_entries[] | select(.value | type == "number")] | length == 0)
  | .key
' "$SCRUB_OUTPUT")"
if [ -n "$COUNTERLESS" ]; then
  log "Transform section(s) reporting no numeric counter:"
  printf '%s\n' "$COUNTERLESS" >&2
  fail "a scrub transform stopped reporting a count; idempotence is unverifiable for it"
  exit 1
fi

NONZERO_COUNTERS="$(printf '%s\n' "$MUTATION_COUNTERS" | grep -v '=0$' || true)"
if [ -n "$NONZERO_COUNTERS" ]; then
  log "Second scrub pass mutated the tree; first pass missed it or the tree changed between passes:"
  printf '%s\n' "$NONZERO_COUNTERS" | sed 's/^/  /' >&2
  fail "scrub is not idempotent ($(printf '%s' "$NONZERO_COUNTERS" | tr '\n' ' '))"
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
MARKER_FRAGMENTS=$(grep -rnE 'gaia:maintainer-only:(start|end)' "$STAGING" 2>/dev/null || true)
if [ -n "$MARKER_FRAGMENTS" ]; then
  log "Marker fragments survived strip:"
  printf '%s\n' "$MARKER_FRAGMENTS" >&2
  fail "marker fragments present in staging tree"
  exit 1
fi

# Name the counters actually checked, so a green run shows its own coverage
# rather than leaving the reader to assume the derivation found anything.
pass "leak-replay clean (0 leaks, 0 unbalanced markers; $(printf '%s' "$MUTATION_COUNTERS" | tr '\n' ' '))"
