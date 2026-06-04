#!/usr/bin/env bash
# Run the release-gate smoke harnesses, report pass/fail.
#
# Blocking lane (gates the release; sets the exit code): wiki-promote/run.sh and
# uat-write/run.sh. Both are deterministic structural harnesses with PASS/FAIL
# semantics, so they belong in the gate.
#
# Advisory lane (does NOT gate): wiki-sync/run.sh drives real `claude -p`
# sessions whose assertions ride on free-form LLM output, so they are inherently
# non-deterministic and cannot block a release on a coin-flip. It runs here for
# visibility and retries each scenario to absorb one-off variance, but its
# result never sets this driver's exit code. See wiki-sync/README.md.
#
# The observability/serena/ subtree (relocated from .gaia/tests/smoke/serena/
# per SPEC-005 §Resolutions Q8) is intentionally NOT run from here
# usage_scan.py is a measurement, not a test, and shouldn't gate a release.
set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

results=()
overall=0

# Advisory: wiki-sync E2E (LLM-nondeterministic; never gates the release).
WIKI_SYNC_RUN="$SMOKE_DIR/wiki-sync/run.sh"
if [ -f "$WIKI_SYNC_RUN" ]; then
  printf '\n=== wiki-sync/run.sh (ADVISORY, non-gating) ===\n'
  if bash "$WIKI_SYNC_RUN"; then
    results+=("PASS      wiki-sync/run.sh (advisory)")
  else
    results+=("ADVISORY  wiki-sync/run.sh failed after retries (does not gate)")
  fi
fi

# Blocking: deterministic structural release-gate harness (PASS/FAIL).
WIKI_PROMOTE_RUN="$SMOKE_DIR/wiki-promote/run.sh"
if [ -x "$WIKI_PROMOTE_RUN" ]; then
  printf '\n=== wiki-promote/run.sh ===\n'
  if bash "$WIKI_PROMOTE_RUN"; then
    results+=("PASS      wiki-promote/run.sh")
  else
    results+=("FAIL      wiki-promote/run.sh")
    overall=1
  fi
fi

# Blocking: uat-write structural smoke (matches wiki-promote shape).
UAT_WRITE_RUN="$SMOKE_DIR/uat-write/run.sh"
if [ -x "$UAT_WRITE_RUN" ]; then
  printf '\n=== uat-write/run.sh ===\n'
  if bash "$UAT_WRITE_RUN"; then
    results+=("PASS      uat-write/run.sh")
  else
    results+=("FAIL      uat-write/run.sh")
    overall=1
  fi
fi

printf '\n=== Summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

exit "$overall"
