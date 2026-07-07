#!/usr/bin/env bats
# Canonical-status-vocabulary tests for the SPEC ledger.
#
# Three concerns:
#   1. Behavioral guard: ledger-update.sh (the single chokepoint for ledger
#      writes) accepts the four canonical statuses {draft, ready, merged,
#      abandoned}, and rejects anything else (including the retired
#      specified/archived/in-progress/allocated/completed values) with exit 6.
#      This guard ships to adopters, so it protects every tool-path write on
#      every clone.
#   2. Auto-fix: spec-reconcile.sh renames a known-misnamed status (shipped ->
#      merged) to canonical through that same chokepoint, and leaves an
#      unrecognized status untouched (logging it). This repairs the hand-edit /
#      backfill vector the guard cannot see (raw edits bypass the chokepoint),
#      and it also ships to adopters (runs on every /gaia-spec).
#   3. Data integrity: the real project .gaia/local/specs/ledger.json carries no
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
  # Statuses ledger-update.sh accepts: the four canonical unified values.
  WRITABLE="draft ready merged abandoned"
  # Retired values the guard now rejects (superseded by the unified vocabulary).
  RETIRED="specified archived in-progress allocated completed"
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
    "$REPO/.gaia/local/specs/ledger.json" > "$tmp"
  mv "$tmp" "$REPO/.gaia/local/specs/ledger.json"
}

@test "1: non-canonical status is rejected with exit 6" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [[ "$output" == *"non-canonical status 'shipped'"* ]]
}

@test "2: a rejected patch leaves the ledger byte-for-byte unchanged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  before="$(cat "$REPO/.gaia/local/specs/ledger.json")"
  run _ledger_update "$REPO" SPEC-001 '{"status":"shipped"}'
  [ "$status" -eq 6 ]
  [ "$(cat "$REPO/.gaia/local/specs/ledger.json")" = "$before" ]
}

@test "3: every writable status (the unified vocabulary) is accepted" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  for s in $WRITABLE; do
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$s\"}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.specs[0].status' "$REPO/.gaia/local/specs/ledger.json")" = "$s" ]
  done
}

@test "3b: every retired status is rejected with exit 6" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  for s in $RETIRED; do
    run _ledger_update "$REPO" SPEC-001 "{\"status\":\"$s\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$s'" <<<"$output"
  done
}

@test "4: a status-less patch (merged_at only) passes the guard" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _ledger_update "$REPO" SPEC-001 '{"merged_at":"2026-01-02T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.specs[0].merged_at' "$REPO/.gaia/local/specs/ledger.json")" = "2026-01-02T00:00:00Z" ]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/local/specs/ledger.json")" = "draft" ]
}

@test "5: spec-reconcile renames a planted 'shipped' row to 'merged'" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  _plant_status SPEC-001 shipped
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized SPEC-001: shipped -> merged"* ]]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/local/specs/ledger.json")" = "merged" ]
}

@test "6: spec-reconcile leaves an unrecognized status untouched and warns" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  _plant_status SPEC-001 bogus-status
  run _reconcile "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognized status bogus-status"* ]]
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/local/specs/ledger.json")" = "bogus-status" ]
}

@test "7: the real project ledger carries only writable statuses" {
  root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  ledger="$root/.gaia/local/specs/ledger.json"
  [ -f "$ledger" ] || ledger="$root/.gaia/specs.json"   # legacy fallback until cutover
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

# --- 8: the SPEC-artifact frontmatter axis stays distinct from the ledger axis
#
# lint.sh validates a wholly separate status axis (the SPEC artifact's own
# authoring lifecycle, in-progress|reopened|closed), never the ledger-row
# vocabulary this suite covers. Belt-and-suspenders: confirms the ledger
# guard's unified vocabulary was never leaked into lint.sh's enum. The
# branch-keyed token-tally resolver half of this regression (the `^branch:`
# match) is already covered by .gaia/tests/hooks/token-tally-git-op.bats;
# not re-tested here.

_lint_fixture() {
  local status_val="$1"
  cat <<EOF
---
spec_id: SPEC-999
type: feature
status: $status_val
immutable: true
wiki_promote_default: ask
chain_trigger: none
intent: test intent
success_criteria: test criteria
uats: []
scope_boundaries: test scope
clarifications: none
research_summary: none
created: 2026-01-01
updated: 2026-01-01
---

# Test SPEC
EOF
}

@test "8: lint.sh accepts status in-progress and rejects status ready (bad_status)" {
  root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  lint="$root/.specify/extensions/gaia/lib/lint.sh"
  fixture="$(mktemp)"

  _lint_fixture "in-progress" > "$fixture"
  run bash "$lint" "$fixture"
  [ "$status" -eq 0 ]

  _lint_fixture "ready" > "$fixture"
  run bash "$lint" "$fixture"
  [ "$status" -eq 1 ]
  grep -qF '"bad_status"' <<<"$output"

  rm -f "$fixture"
}
