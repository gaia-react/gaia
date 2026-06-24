#!/usr/bin/env bats
# Canonical-status-vocabulary tests for the SPEC ledger.
#
# Three concerns:
#   1. Behavioral guard: ledger-update.sh (the single chokepoint for ledger
#      writes) accepts the four canonical statuses {draft, specified, merged,
#      archived} plus the tolerated legacy in-progress, and rejects anything
#      else with exit 6. This guard ships to adopters, so it protects every
#      tool-path write on every clone.
#   2. Auto-fix: spec-reconcile.sh renames a known-misnamed status (shipped ->
#      merged) to canonical through that same chokepoint, and leaves an
#      unrecognized status untouched (logging it). This repairs the hand-edit /
#      backfill vector the guard cannot see (raw edits bypass the chokepoint),
#      and it also ships to adopters (runs on every /gaia-spec).
#   3. Data integrity: the real project .gaia/specs.json carries no
#      off-vocabulary status row.
#
# Canonical vocabulary is documented in wiki/concepts/GAIA Spec.md
# ("Ledger status vocabulary"). Keep WRITABLE below in sync with that section.
#
# Each behavioral test spins up its own tmp git repo via
# helpers/tmp-spec-repo.sh and tears it down; hermetic, no reliance on the
# real project ledger. The teardown uses the explicit-if form (the && idiom is
# a bats teardown footgun: a falsy first clause makes teardown itself "fail").

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  # Statuses ledger-update.sh accepts: the four canonical values plus the
  # tolerated legacy in-progress.
  WRITABLE="draft specified merged archived in-progress"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_ledger_update() {
  bash "$REPO/.specify/extensions/gaia/lib/ledger-update.sh" "$@"
}

_reconcile() {
  bash "$REPO/.specify/extensions/gaia/lib/spec-reconcile.sh" "$@"
}

# Raw-write a status onto a row, bypassing the guard. Used to plant a
# pre-guard off-vocabulary row that the guard itself would refuse to create.
_plant_status() {
  local id="$1" status="$2" tmp
  tmp="$(mktemp)"
  jq --arg id "$id" --arg s "$status" \
    '.specs |= map(if .id == $id then .status = $s else . end)' \
    "$REPO/.gaia/specs.json" > "$tmp"
  mv "$tmp" "$REPO/.gaia/specs.json"
}

@test "1: non-canonical status is rejected with exit 6" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [[ "$output" == *"non-canonical status 'shipped'"* ]]
}

@test "2: a rejected patch leaves the ledger byte-for-byte unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  before="$(cat "$REPO/.gaia/specs.json")"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [ "$(cat "$REPO/.gaia/specs.json")" = "$before" ]
}

@test "3: every writable status (canonical + legacy in-progress) is accepted" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  for s in $WRITABLE; do
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$s\"}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.specs[0].status' "$REPO/.gaia/specs.json")" = "$s" ]
  done
}

@test "4: a status-less patch (merged_at only) passes the guard" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _ledger_update "$REPO" SPEC-001 '{"merged_at":"2026-01-02T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.specs[0].merged_at' "$REPO/.gaia/specs.json")" = "2026-01-02T00:00:00Z" ]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/specs.json")" = "draft" ]
}

@test "5: spec-reconcile renames a planted 'shipped' row to 'merged'" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  _plant_status SPEC-001 shipped
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized SPEC-001: shipped -> merged"* ]]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/specs.json")" = "merged" ]
}

@test "6: spec-reconcile leaves an unrecognized status untouched and warns" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  _plant_status SPEC-001 bogus-status
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognized status bogus-status"* ]]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/specs.json")" = "bogus-status" ]
}

@test "7: the real project ledger carries only writable statuses" {
  root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  ledger="$root/.gaia/specs.json"
  [ -f "$ledger" ] || skip "no project ledger at $ledger"
  bad="$(jq -r --arg writable "$WRITABLE" '
    ($writable | split(" ")) as $ok
    | .specs[] | select(.status as $s | $ok | index($s) | not)
    | .id + ":" + (.status // "null")
  ' "$ledger")"
  [ -z "$bad" ] || {
    echo "off-vocabulary ledger rows: $bad" >&2
    false
  }
}
