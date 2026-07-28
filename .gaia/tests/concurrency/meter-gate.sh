#!/usr/bin/env bash
# meter-gate.sh - run the whole INV-7 concurrency meter and adjudicate every
# scenario against expected-status.txt. This is the form in which the meter
# gates CI (see README.md, "Armed as a required CI check").
#
# NOT the same contract as .gaia/tests/forensics/run-all.sh, despite the
# sibling shape: that script exits non-zero when any test fails. This one
# exits ZERO with scenarios failing, because the meter is red by design and
# its reds belong to phases that have not run yet. What it fails on is a
# DEVIATION from the recorded expectation, in either direction:
#
#   regression  an expected-pass scenario went red
#   progress    an expected-red scenario went green -- a real advance, and it
#               must be recorded in expected-status.txt and README.md rather
#               than silently absorbed into a green build
#   drift       a scenario ran that the manifest does not know, a manifest
#               entry did not run, the entry count no longer equals the frozen
#               target, or a scenario reported `skip`
#
# A `bats --filter` over the armed tranches was the alternative and is worse:
# it hides the red scenarios, and it makes a newly added scenario invisible by
# default. Running the whole suite and diffing against a checked-in expectation
# keeps every scenario in the reading.
#
# Run: bash .gaia/tests/concurrency/meter-gate.sh
# Prerequisites: bats-core on PATH. The suite drives node in three scenarios
# (C3-05, C4-04, C4-07), which need BOTH `pnpm install` at the repo root and
# `pnpm -C .gaia/cli install`; see README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SUITE="$HERE/concurrency.bats"
MANIFEST="$HERE/expected-status.txt"

echo "==> .gaia/tests/concurrency/meter-gate.sh"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: expected-status manifest not found at $MANIFEST" >&2
  exit 1
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats not installed. brew install bats-core / apt-get install -y bats" >&2
  exit 1
fi

work="$(mktemp -d -t meter-gate-XXXXXX)"
trap 'rm -rf "$work"' EXIT
tap="$work/observed.tap"

# The suite is EXPECTED to exit non-zero (reds by design), so its status is not
# the gate. Deviation from the manifest is. bats5.sh is the documented runner:
# on macOS it warns when bats would resolve bash 3.2 (a weaker signal than CI);
# on the ubuntu runner it is silent and calls bats directly.
set +e
bash "$ROOT/.gaia/scripts/bats5.sh" --tap "$SUITE" > "$tap" 2>&1
set -e

# Echo the run so a CI log carries the failure diagnostics, not just the verdict.
cat "$tap"
echo

# --- parse the TAP stream into "<id> <pass|fail|skip>" -----------------------
# A scenario line is `ok N C4-01: ...` / `not ok N C4-01: ...`; anything else
# (the plan line, `#` diagnostics) is not a scenario result. Ids are matched by
# shape rather than against a hardcoded list, so a renamed or added scenario
# surfaces as drift below instead of being quietly dropped here.
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

# --- parse the manifest into "<id> <pass|fail>" and read the target ----------
expected="$work/expected.txt"
target="$(awk '$1 == "target" { print $2 }' "$MANIFEST")"
awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  $1 == "target"  { next }
  { print $1 " " $2 }
' "$MANIFEST" | sort > "$expected"

if [ -z "$target" ]; then
  echo "ERROR: $MANIFEST declares no \`target\` line." >&2
  exit 1
fi

entries="$(wc -l < "$expected" | tr -d ' ')"
deviations=0

# The manifest's entry count IS the meter's denominator, so pinning it to the
# frozen target is what stops the denominator being shrunk to improve a
# reading: dropping a scenario from the manifest fails here, and raising the
# target without adding a scenario fails here too.
if [ "$entries" -ne "$target" ]; then
  echo "DRIFT: the manifest holds $entries entries but declares target $target." >&2
  echo "       The target moves upward only by the maintainer's word, and only" >&2
  echo "       for an added scenario (README.md, 'The target, stated up front')." >&2
  deviations=$((deviations + 1))
fi

# --- adjudicate every id in either file -------------------------------------
passing=0
while read -r id; do
  exp="$(awk -v k="$id" '$1 == k { print $2 }' "$expected")"
  obs="$(awk -v k="$id" '$1 == k { print $2 }' "$observed")"

  if [ -z "$exp" ]; then
    echo "DRIFT: $id ran but the manifest does not know it. Add it to" >&2
    echo "       expected-status.txt (and to README.md's scenario table), and" >&2
    echo "       raise \`target\` if it is a new scenario." >&2
    deviations=$((deviations + 1))
    continue
  fi

  if [ -z "$obs" ]; then
    echo "DRIFT: $id is in the manifest but did not report a result. Either the" >&2
    echo "       scenario was renamed or removed, or the suite died before" >&2
    echo "       reaching it. A scenario may not leave the denominator silently." >&2
    deviations=$((deviations + 1))
    continue
  fi

  case "$obs" in
    pass) passing=$((passing + 1)) ;;
    skip)
      echo "DRIFT: $id reported \`skip\`. skip is banned in this suite: it reports" >&2
      echo "       green, which is the opposite of what a red-by-design meter" >&2
      echo "       means. Install the dependency or assert the real property." >&2
      deviations=$((deviations + 1))
      continue
      ;;
  esac

  if [ "$obs" = "$exp" ]; then
    continue
  fi

  if [ "$exp" = "pass" ]; then
    echo "REGRESSION: $id was expected to pass and went red." >&2
    echo "            Its owning phase must preserve it; this is the signal, fix" >&2
    echo "            the cause rather than the expectation." >&2
  else
    echo "PROGRESS: $id was expected to fail and went green." >&2
    echo "          This is an advance and it must be recorded, not absorbed:" >&2
    echo "          flip its row in expected-status.txt and update the reading" >&2
    echo "          in README.md, in the same change that turned it." >&2
  fi
  deviations=$((deviations + 1))
done < <(cut -d' ' -f1 "$expected" "$observed" | sort -u)

echo "==> the meter reads $passing / $target"

if [ "$deviations" -ne 0 ]; then
  echo "==> FAILED: $deviations deviation(s) from expected-status.txt" >&2
  exit 1
fi

echo "==> every scenario matches expected-status.txt"
