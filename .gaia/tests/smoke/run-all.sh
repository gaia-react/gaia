#!/usr/bin/env bash
# Run the release-gate smoke harnesses, report pass/fail.
#
# Blocking lane (gates the release; sets the exit code): wiki-promote/run.sh
# and uat-write/run.sh. Both are deterministic structural harnesses with
# PASS/FAIL semantics, so they belong in the gate.
#
# Advisory lane (does NOT gate): wiki-sync/run.sh drives real `claude -p`
# sessions whose assertions ride on free-form LLM output, so they are inherently
# non-deterministic and cannot block a release on a coin-flip. It runs here for
# visibility and retries each scenario to absorb one-off variance, but its
# result never sets this driver's exit code. See wiki-sync/README.md.
#
# The two lane lists below are the whole of the harness tree, in both
# directions: a harness a lane names must exist, and a harness in the tree must
# be named by a lane. Either half breaking fails the run. A harness no lane runs
# guards nothing while still reading as coverage, and a lane naming a harness
# that is gone has silently lost the coverage it claims. Note the asymmetry:
# only an advisory harness's RESULT is non-gating; its ABSENCE is a config error
# in this file, not a coin-flip, so it fails like any other.
#
# The observability/serena/ subtree (relocated from .gaia/tests/smoke/serena/
# per SPEC-005 §Resolutions Q8) is intentionally NOT run from here
# usage_scan.py is a measurement, not a test, and shouldn't gate a release.
set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADVISORY_LANE=(wiki-sync)
BLOCKING_LANE=(wiki-promote uat-write)

results=()
overall=0

# Arrays are expanded with the offset-guard `${arr[@]+"${arr[@]}"}` throughout:
# on bash 3.2.57 (stock macOS /bin/bash) a bare "${arr[@]}" of an EMPTY array
# aborts under `set -u`. Neither lane is empty today, but emptying one (deleting
# the sole advisory harness, say) must not abort this driver before it reaches
# the blocking lane. That abort exits 1, indistinguishable from a harness that
# ran and failed, and bash 4.4+ does not reproduce it, so it would read as a
# real failure on macOS and pass clean on Linux CI. See
# .gaia/scripts/lint-hook-array-guard.sh for the class.

# A release gate with nothing in it is not a pass. Emptying the blocking lane
# while the harnesses are also deleted would otherwise print an empty summary
# and exit 0, verifying nothing.
if [ "${#BLOCKING_LANE[@]}" -eq 0 ]; then
  printf 'FAIL: BLOCKING_LANE is empty; this driver would gate on nothing.\n' >&2
  exit 1
fi

missing_harness() {
  results+=("FAIL      $1/run.sh named by a lane but missing from the tree")
  overall=1
}

# Advisory: LLM-nondeterministic; its result never gates the release.
for name in ${ADVISORY_LANE[@]+"${ADVISORY_LANE[@]}"}; do
  run="$SMOKE_DIR/$name/run.sh"
  if [ ! -f "$run" ]; then
    missing_harness "$name"
    continue
  fi
  printf '\n=== %s/run.sh (ADVISORY, non-gating) ===\n' "$name"
  if bash "$run"; then
    results+=("PASS      $name/run.sh (advisory)")
  else
    results+=("ADVISORY  $name/run.sh failed after retries (does not gate)")
  fi
done

# Blocking: deterministic structural release-gate harnesses (PASS/FAIL).
for name in ${BLOCKING_LANE[@]+"${BLOCKING_LANE[@]}"}; do
  run="$SMOKE_DIR/$name/run.sh"
  if [ ! -f "$run" ]; then
    missing_harness "$name"
    continue
  fi
  printf '\n=== %s/run.sh ===\n' "$name"
  rc=0
  bash "$run" || rc=$?
  case "$rc" in
    0)
      results+=("PASS      $name/run.sh")
      ;;
    2)
      # The driver honors exit 2 as "missing prerequisite" rather than a failed
      # assertion, so a maintainer who skipped `pnpm install` does not read it
      # as "the feature is broken". A harness exits 2 when a build artifact or
      # dependency it needs (e.g. .gaia/cli/gaia, node_modules/.bin/tsx) is
      # absent; others exit 1 (via pre-flight or their summary) and land in the
      # branch below. Either way it gates: an unverified harness cannot clear a
      # release.
      results+=("FAIL      $name/run.sh prerequisite missing (exit 2; run pnpm install)")
      overall=1
      ;;
    *)
      results+=("FAIL      $name/run.sh")
      overall=1
      ;;
  esac
done

# Every harness in the tree must be named by a lane above.
shopt -s nullglob
for run in "$SMOKE_DIR"/*/run.sh; do
  name="$(basename "$(dirname "$run")")"
  claimed=0
  for known in ${ADVISORY_LANE[@]+"${ADVISORY_LANE[@]}"} ${BLOCKING_LANE[@]+"${BLOCKING_LANE[@]}"}; do
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
for r in ${results[@]+"${results[@]}"}; do
  printf '%s\n' "$r"
done

exit "$overall"
