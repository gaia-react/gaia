#!/usr/bin/env bash
# Run all wiki-sync smoke scenarios, report pass/fail.
# Walks .claude-tests/smoke/wiki-sync/*.sh in lexicographic order.
#
# The serena/ subtree is intentionally NOT run from here — usage_scan.py
# is a measurement, not a test, and shouldn't gate a release.
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

printf '\n=== Summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

exit "$overall"
