#!/usr/bin/env bash
# Run all distribution-validation scenarios, report pass/fail.
# Walks .claude-tests/distribution/*.sh in lexicographic order, excluding
# run-all.sh itself and anything under lib/ or diagnostic/. Naming
# convention is NN-name.sh so order is deterministic.
#
# Each scenario runs in a separate `bash` subprocess so one scenario's
# `set -e` exit does not abort the loop. Exits 0 if all PASS, 1 if any
# FAIL or if no scenarios were found.
set -u

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
candidates=("$DIST_DIR"/*.sh)
shopt -u nullglob

scenarios=()
for s in "${candidates[@]}"; do
  name="$(basename "$s")"
  [ "$name" = "run-all.sh" ] && continue
  scenarios+=("$s")
done

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "No scenarios found in $DIST_DIR" >&2
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
