#!/usr/bin/env bash
# Run all release-gate smoke scenarios, report pass/fail.
# Walks .gaia/tests/smoke/wiki-sync/*.sh in lexicographic order, then
# invokes wiki-promote/run.sh and uat-write/run.sh; both are structural
# release-gate harnesses with PASS/FAIL semantics, so they belong in this
# driver.
#
# The observability/serena/ subtree (relocated from .gaia/tests/smoke/serena/
# per SPEC-005 §Resolutions Q8) is intentionally NOT run from here
# usage_scan.py is a measurement, not a test, and shouldn't gate a release.
set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIKI_SYNC_DIR="$SMOKE_DIR/wiki-sync"

shopt -s nullglob
scenarios=("$WIKI_SYNC_DIR"/*.sh)
shopt -u nullglob

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "No scenarios found in $WIKI_SYNC_DIR" >&2
  exit 1
fi

results=()
overall=0

for s in "${scenarios[@]}"; do
  name="$(basename "$s")"
  printf '\n=== %s ===\n' "$name"
  if bash "$s"; then
    results+=("PASS  $name")
  else
    results+=("FAIL  $name")
    overall=1
  fi
done

# Run the wiki-promote structural smoke (release-gate harness; PASS/FAIL).
WIKI_PROMOTE_RUN="$SMOKE_DIR/wiki-promote/run.sh"
if [ -x "$WIKI_PROMOTE_RUN" ]; then
  printf '\n=== wiki-promote/run.sh ===\n'
  if bash "$WIKI_PROMOTE_RUN"; then
    results+=("PASS  wiki-promote/run.sh")
  else
    results+=("FAIL  wiki-promote/run.sh")
    overall=1
  fi
fi

# Run the uat-write structural smoke (matches wiki-promote shape).
UAT_WRITE_RUN="$SMOKE_DIR/uat-write/run.sh"
if [ -x "$UAT_WRITE_RUN" ]; then
  printf '\n=== uat-write/run.sh ===\n'
  if bash "$UAT_WRITE_RUN"; then
    results+=("PASS  uat-write/run.sh")
  else
    results+=("FAIL  uat-write/run.sh")
    overall=1
  fi
fi

printf '\n=== Summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

exit "$overall"
