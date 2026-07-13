#!/usr/bin/env bash
# Run the release-gate smoke harnesses, report pass/fail.
#
# Blocking lane (gates the release; sets the exit code): wiki-promote/run.sh,
# uat-write/run.sh, and telemetry-v1/run.sh. All three are deterministic
# structural harnesses with PASS/FAIL semantics, so they belong in the gate.
#
# Advisory lane (does NOT gate): wiki-sync/run.sh drives real `claude -p`
# sessions whose assertions ride on free-form LLM output, so they are inherently
# non-deterministic and cannot block a release on a coin-flip. It runs here for
# visibility and retries each scenario to absorb one-off variance, but its
# result never sets this driver's exit code. See wiki-sync/README.md.
#
# Every harness under smoke/ belongs to exactly one lane, and the lane lists
# below are the whole of it. The unclaimed-harness check at the bottom fails the
# run when a smoke/<feature>/run.sh exists that neither lane names: a harness no
# lane runs guards nothing while still looking like coverage.
#
# The observability/serena/ subtree (relocated from .gaia/tests/smoke/serena/
# per SPEC-005 §Resolutions Q8) is intentionally NOT run from here
# usage_scan.py is a measurement, not a test, and shouldn't gate a release.
set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADVISORY_LANE=(wiki-sync)
BLOCKING_LANE=(wiki-promote uat-write telemetry-v1)

results=()
overall=0

# Advisory: LLM-nondeterministic; runs for visibility, never gates the release.
for name in "${ADVISORY_LANE[@]}"; do
  run="$SMOKE_DIR/$name/run.sh"
  if [ ! -f "$run" ]; then
    results+=("ADVISORY  $name/run.sh missing (does not gate)")
    continue
  fi
  printf '\n=== %s/run.sh (ADVISORY, non-gating) ===\n' "$name"
  if bash "$run"; then
    results+=("PASS      $name/run.sh (advisory)")
  else
    results+=("ADVISORY  $name/run.sh failed after retries (does not gate)")
  fi
done

# Blocking: deterministic structural release-gate harnesses (PASS/FAIL). A
# missing one is a failure, not a skip: silently dropping a harness from the
# gate is the same lost coverage as never wiring it in.
for name in "${BLOCKING_LANE[@]}"; do
  run="$SMOKE_DIR/$name/run.sh"
  if [ ! -f "$run" ]; then
    results+=("FAIL      $name/run.sh missing")
    overall=1
    continue
  fi
  printf '\n=== %s/run.sh ===\n' "$name"
  if bash "$run"; then
    results+=("PASS      $name/run.sh")
  else
    results+=("FAIL      $name/run.sh")
    overall=1
  fi
done

# Unclaimed-harness check: every harness in the tree must be assigned to a lane.
shopt -s nullglob
for run in "$SMOKE_DIR"/*/run.sh; do
  name="$(basename "$(dirname "$run")")"
  claimed=0
  for known in "${ADVISORY_LANE[@]}" "${BLOCKING_LANE[@]}"; do
    if [ "$name" = "$known" ]; then
      claimed=1
      break
    fi
  done
  if [ "$claimed" -eq 0 ]; then
    results+=("FAIL      $name/run.sh runs in no lane; add it to run-all.sh")
    overall=1
  fi
done
shopt -u nullglob

printf '\n=== Summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

exit "$overall"
