#!/usr/bin/env bash
# Run all smoke scenarios, report pass/fail.
set -u

cd "$(dirname "$0")"

scenarios=(
  "01-meaningful-change.sh"
  "02-typo-only-skip.sh"
  "03-multi-commit-catchup.sh"
  "04-non-claude-merge.sh"
)

results=()
overall=0

for s in "${scenarios[@]}"; do
  printf '\n=== %s ===\n' "$s"
  if bash "./$s"; then
    results+=("PASS  $s")
  else
    results+=("FAIL  $s")
    overall=1
  fi
done

printf '\n=== Summary ===\n'
for r in "${results[@]}"; do
  printf '%s\n' "$r"
done

exit "$overall"
