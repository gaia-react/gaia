#!/usr/bin/env bash
# meter-gate.sh - run the whole INV-7 concurrency meter and fail on any
# scenario that is not an unconditional `ok`, or when bats itself exits
# non-zero (a run killed partway reports only the scenarios it reached). This
# is the form in which the meter gates CI (see README.md, "CI").
#
# NOT the same contract as .gaia/tests/forensics/run-all.sh, despite the
# sibling shape: that script exits non-zero when any test fails. This one
# also fails on a `skip`: skip is banned in this suite, because a skipped
# scenario reports green, which is the opposite of what this meter means.
# C3-05, C4-04, and C4-07 need node + pnpm rather than skipping past the
# property they exist to prove.
#
# Run: bash .gaia/tests/concurrency/meter-gate.sh
# Prerequisites: bats-core on PATH. The suite drives node in three scenarios
# (C3-05, C4-04, C4-07), which need BOTH `pnpm install` at the repo root and
# `pnpm -C .gaia/cli install`; see README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SUITE="$HERE/concurrency.bats"

echo "==> .gaia/tests/concurrency/meter-gate.sh"

if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats not installed. brew install bats-core / apt-get install -y bats" >&2
  exit 1
fi

work="$(mktemp -d -t meter-gate-XXXXXX)"
trap 'rm -rf "$work"' EXIT
tap="$work/observed.tap"

# bats5.sh is the documented runner: on macOS it warns when bats would
# resolve bash 3.2 (a weaker signal than CI); on the ubuntu runner it is
# silent and calls bats directly.
set +e
bash "$ROOT/.gaia/scripts/bats5.sh" --tap "$SUITE" > "$tap" 2>&1
bats_rc=$?
set -e

# Echo the run so a CI log carries the failure diagnostics, not just the verdict.
cat "$tap"
echo

# --- parse the TAP stream into "<id> <pass|fail|skip>" -----------------------
# A scenario line is `ok N C4-01: ...` / `not ok N C4-01: ...`; anything else
# (the plan line, `#` diagnostics) is not a scenario result. Ids are matched by
# shape rather than against a hardcoded list, so a renamed or added scenario
# is read the same as every other.
observed="$work/observed.txt"
: > "$observed"
awk '
  /^(ok|not ok) [0-9]+ / {
    status = ($1 == "ok") ? "pass" : "fail"
    line = $0
    if (line ~ /# ?[Ss][Kk][Ii][Pp]/) status = "skip"
    if (match(line, /C[0-9]+-[0-9]+/)) {
      print substr(line, RSTART, RLENGTH) " " status
    } else {
      print "UNNAMED " status
    }
  }
' "$tap" | sort > "$observed"

if [ ! -s "$observed" ]; then
  echo "ERROR: the suite produced no scenario results. It did not run." >&2
  exit 1
fi

total="$(wc -l < "$observed" | tr -d ' ')"
failures=0

while IFS=' ' read -r id status; do
  case "$status" in
    pass) continue ;;
    skip)
      echo "FAIL: $id reported \`skip\`. skip is banned in this suite: it reports" >&2
      echo "      green, which is the opposite of what this meter means." >&2
      echo "      Install the dependency or assert the real property." >&2
      ;;
    *)
      echo "FAIL: $id reported \`$status\`." >&2
      ;;
  esac
  failures=$((failures + 1))
done < "$observed"

echo "==> the meter ran $total scenario(s)"

if [ "$bats_rc" -ne 0 ] && [ "$failures" -eq 0 ]; then
  echo "==> FAILED: bats exited $bats_rc with no failing scenario; the run did" >&2
  echo "    not complete, so scenarios after the break never reported" >&2
  exit 1
fi

if [ "$failures" -ne 0 ]; then
  echo "==> FAILED: $failures scenario(s) did not report ok" >&2
  exit 1
fi

echo "==> every scenario reported ok"
