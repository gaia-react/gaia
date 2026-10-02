#!/usr/bin/env bash
# Run all distribution-validation scenarios, report pass/fail.
# Walks .gaia/tests/distribution/*.sh in lexicographic order, excluding
# run-all.sh itself and anything under lib/. Naming
# convention is NN-name.sh so order is deterministic.
#
# Each scenario runs in a separate `bash` subprocess so one scenario's
# `set -e` exit does not abort the loop. Exits 0 if all PASS, 1 if any
# FAIL or if no scenarios were found.
set -u

DISTRIBUTION_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
candidates=("$DISTRIBUTION_DIRECTORY"/*.sh)
shopt -u nullglob

scenarios=()
for scenario in ${candidates[@]+"${candidates[@]}"}; do
  name="$(basename "$scenario")"
  [ "$name" = "run-all.sh" ] && continue
  scenarios+=("$scenario")
done

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "No scenarios found in $DISTRIBUTION_DIRECTORY" >&2
  exit 1
fi

results=()
overall=0

for scenario in ${scenarios[@]+"${scenarios[@]}"}; do
  name="$(basename "$scenario")"
  printf '\n=== %s ===\n' "$name"
  if bash "$scenario"; then
    results+=("PASS  $name")
  else
    results+=("FAIL  $name")
    overall=1
  fi
done

printf '\n=== Summary ===\n'
for result in ${results[@]+"${results[@]}"}; do
  printf '%s\n' "$result"
done

exit "$overall"
