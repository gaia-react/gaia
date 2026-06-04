#!/usr/bin/env bash
# Advisory runner for the wiki-sync E2E smoke scenarios.
#
# These scenarios drive real `claude -p` sessions through `/gaia-wiki sync`.
# Their assertions ride on free-form LLM output: which wiki page got created,
# the exact words logged to wiki/log.md, whether a prose answer happens to
# mention "drift". Even with the deterministic CLI provisioned, that output is
# not reproducible run-to-run, so these scenarios MUST NOT gate a release.
#
# This is the ADVISORY lane:
#   - bounded retries absorb one-off LLM variance (a scenario that passes on
#     any attempt counts as PASS),
#   - the captured claude session output is surfaced on a final failure (the
#     scenarios write it to $TMP/claude-sync.log and dump it via their EXIT
#     trap, so a real defect is diagnosable),
#   - run-all.sh invokes this but never lets its result set the gate exit code.
#
# Cost: each attempt spawns 1-2 billable Sonnet sessions (~$0.10 each). With
# the default of 2 attempts, the worst case is twice that per scenario.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
export GAIA_REPO

# Bounded retries. One retry by default; override with WIKI_SYNC_MAX_ATTEMPTS.
MAX_ATTEMPTS="${WIKI_SYNC_MAX_ATTEMPTS:-2}"

shopt -s nullglob
scenarios=("$SCRIPT_DIR"/[0-9][0-9]-*.sh)
shopt -u nullglob

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "No wiki-sync scenarios found in $SCRIPT_DIR" >&2
  exit 1
fi

results=()
overall=0

for s in "${scenarios[@]}"; do
  name="$(basename "$s")"
  printf '\n=== %s (up to %d attempt(s)) ===\n' "$name" "$MAX_ATTEMPTS"
  attempt=1
  passed=0
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    printf -- '--- attempt %d/%d ---\n' "$attempt" "$MAX_ATTEMPTS"
    if out="$(bash "$s" 2>&1)"; then
      printf '%s\n' "$out"
      passed=1
      break
    fi
    # Surface the failed attempt's output (includes the captured claude
    # session log dumped by the scenario's EXIT trap) so failures are
    # diagnosable rather than blackholed.
    printf '%s\n' "$out"
    attempt=$((attempt + 1))
  done
  if [ "$passed" -eq 1 ]; then
    results+=("PASS  $name (attempt $attempt/$MAX_ATTEMPTS)")
  else
    results+=("FAIL  $name (exhausted $MAX_ATTEMPTS attempt(s); output above)")
    overall=1
  fi
done

printf '\n=== wiki-sync advisory summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

if [ "$overall" -ne 0 ]; then
  printf '\nwiki-sync advisory: one or more scenarios failed after retries.\n' >&2
  printf 'This lane is ADVISORY (LLM-nondeterministic); it does not block the release gate.\n' >&2
fi

# Honest exit code for a maintainer running this directly; run-all.sh treats it
# as advisory and does not gate on it.
exit "$overall"
