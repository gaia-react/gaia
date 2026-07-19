#!/usr/bin/env bats
# Delete-sweep tests for spec-archive-abandoned.sh, the abandoned-status
# counterpart to spec-archive-merged.sh (see that script's own suite,
# spec-archive-merged.bats, for the merged path this mirrors).
#
# Deletion is gated on cost representation (cost_folder_represented, sourced
# from .gaia/scripts/cost-represented.sh), the same fail-closed gate the
# merged sweep uses. tmp-spec-repo.sh seeds an empty
# .gaia/local/telemetry/cost.jsonl and copies of cost-represented.sh /
# ledger-path-lib.sh into every tmp repo so the gate resolves in isolation.
#
# Sweep criteria: a ledger row with status "abandoned" AND an active folder
# AND abandoned_at past the retention window AND a passing representation
# gate. Unlike the merged sweep there is no consolidation gate and no
# wiki-promote drain check: an abandoned folder reaps as one unit.
#
# Each test spins up its own tmp git repo via helpers/tmp-spec-repo.sh and
# tears it down; hermetic, no reliance on the real project ledger.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]`. This suite uses `[ ... ]` and the
# assert_contains/refute_contains grep helpers below for everything but a
# test's last statement.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".specify/extensions/gaia/lib/spec-archive-abandoned.sh"
  SPECS=".gaia/local/specs"
  TELEMETRY=".gaia/local/telemetry/spec-pacing.jsonl"
  LEDGER=".gaia/local/telemetry/cost.jsonl"
  # --seed-abandoned-folder stamps a fixed abandoned_at
  # ("2026-01-02T00:00:00Z") rather than "just abandoned", so every delete
  # test below needs the age gate collapsed to stay deterministic regardless
  # of wall-clock time. The age-gate tests re-export this per test.
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_archive() {
  bash "$REPO/$ARCHIVE" "$@"
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

_snapshot() {
  ( cd "$REPO/$SPECS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# _plant_cost_md <spec_id> <fresh> <cwrite> <cread> <output> <session>:
# mirrors spec-archive-merged.bats's helper of the same shape.
_plant_cost_md() {
  local id="$1" fresh="$2" cwrite="$3" cread="$4" output="$5" session="$6"
  cat > "$REPO/$SPECS/$id/cost.md" <<EOF
# Cost: $id

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | $fresh |
| Cache write | $cwrite |
| Cache read | $cread |
| Output | $output |

**Est. cost (USD):** \$1.23

Session \`$session\` · generated 2026-07-05T10:00:00Z
EOF
}

_seed_cost_row() {
  local id="$1" session="$2" fresh="$3" cwrite="$4" cread="$5" output="$6"
  local total=$((fresh + cwrite + cread + output))
  jq -cn --arg id "$id" --arg sid "$session" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" --argjson total "$total" \
    '{schema_version: 1, kind: "spec", spec_id: $id, plan_id: null, plan_slug: null,
      session_id: $sid,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: $total, seq: 0, final: true, source: "test"}' \
    >> "$REPO/$LEDGER"
}

_days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _set_abandoned_at <repo> <spec_id> <iso>: patches the seeded ledger row's
# abandoned_at, for tests that need a specific age instead of the fixture's
# fixed date.
_set_abandoned_at() {
  local repo="$1" id="$2" iso="$3"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg ts "$iso" \
    '.specs |= map(if .id == $id then . + {abandoned_at: $ts} else . end)' \
    "$repo/$SPECS/ledger.json" > "$tmp"
  mv "$tmp" "$repo/$SPECS/ledger.json"
}

_clear_abandoned_at() {
  local repo="$1" id="$2"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.specs |= map(if .id == $id then del(.abandoned_at) else . end)' \
    "$repo/$SPECS/ledger.json" > "$tmp"
  mv "$tmp" "$repo/$SPECS/ledger.json"
}

# --- 1: delete happy path (cost represented) ---------------------------------

@test "1: an abandoned row whose cost is represented is deleted; ledger stays abandoned" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  _seed_cost_row SPEC-001 sess-1 100 10 5 20

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  [ "$(jq -r '.specs[0].status' "$REPO/$SPECS/ledger.json")" = "abandoned" ]
  [ "$(jq -r '.specs[0].abandoned_at' "$REPO/$SPECS/ledger.json")" = "2026-01-02T00:00:00Z" ]
}

# --- 2: single-id form ---------------------------------------------------------

@test "2: the single-id form deletes only the named id" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-abandoned-folder SPEC-001 --seed-abandoned-folder SPEC-002)"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -d "$REPO/$SPECS/SPEC-002" ]
}

# --- 3: representation gate blocks an unrepresented cost.md -------------------

@test "3: an unrepresented cost.md section blocks deletion; folder survives" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  # No matching cost.jsonl row: the SPEC section is unrepresented.

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left SPEC-001 folder for review"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 4: skip an abandoned row with no folder -----------------------------------

@test "4: an abandoned row with no active folder is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned SPEC-005)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
}

# --- 5: idempotent re-run -------------------------------------------------------

@test "5: re-running the sweep after deleting is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]
}

# --- 6: only abandoned rows with folders are swept; merged rows are untouched -

@test "6: a merged row is never touched by the abandoned sweep" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-abandoned-folder SPEC-001 --seed-merged-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # SPEC-002 (merged) untouched: still active, never deleted by this script.
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
}

# --- 7: a folder without an abandoned ledger row is never deleted -------------

@test "7: a folder without an abandoned ledger row is never deleted" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001 --seed-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
}

# --- 8: multiple abandoned folders in one sweep --------------------------------

@test "8: two abandoned folders are deleted together with a combined summary" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-abandoned-folder SPEC-001 --seed-abandoned-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 abandoned SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}

# --- 9: no ledger -> clean no-op -------------------------------------------------

@test "9: a repo with no abandoned rows produces no output and exits 0" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 10: age gate, within window -> kept -----------------------------------------

@test "10: an abandoned folder within the retention window is kept, not deleted" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 11: age gate, past window + represented -> reaped ---------------------------

@test "11: an abandoned folder past the retention window with represented cost is reaped" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]

  [ "$(jq -r '.specs[0].status' "$REPO/$SPECS/ledger.json")" = "abandoned" ]
}

# --- 12: age gate, past window but unrepresented -> kept -------------------------

@test "12: a folder past the retention window but unrepresented is kept" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 45)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left SPEC-001 folder for review"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 13/14: missing or unparseable abandoned_at -> kept regardless of age --------

@test "13: an abandoned row with no abandoned_at is kept regardless of representation" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _clear_abandoned_at "$REPO" SPEC-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

@test "14: an abandoned row with an unparseable abandoned_at is kept regardless of representation" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 15/16: GAIA_SPEC_RETENTION_DAYS knob is honored, shared with the merged sweep

@test "15: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-abandoned represented folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

@test "16: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old abandoned folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

# --- 17: a non-numeric knob value falls back to the 30-day default --------------

@test "17: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 10)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  REPO2="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-002)"
  _set_abandoned_at "$REPO2" SPEC-002 "$(_days_ago 45)"
  run bash "$REPO2/$ARCHIVE" "$REPO2"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-002"
  rm -rf "$REPO2"
}

# --- 18: telemetry event on reap -------------------------------------------------

@test "18: deleting appends a spec_abandoned_reaped telemetry event" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]

  [ -f "$REPO/$TELEMETRY" ]
  last="$(tail -n 1 "$REPO/$TELEMETRY")"
  [ "$(printf '%s' "$last" | jq -r '.event')" = "spec_abandoned_reaped" ]
  [ "$(printf '%s' "$last" | jq -r '.spec_id')" = "SPEC-001" ]
  [ -n "$(printf '%s' "$last" | jq -r '.ts')" ]
}

# --- 19: no consolidation gate -- a bare AUDIT.md folder still reaps -----------

@test "19: an abandoned folder holding only AUDIT.md reaps with no consolidation gate" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
  [ ! -e "$REPO/$SPECS/SPEC-001/SUMMARY.md" ]

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

# --- 20: a dangling wiki-promote defer flag is purged, not orphaned -----------

@test "20: reaping an abandoned row purges its wiki-promote defer flag too" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x","deferred_at":"2026-01-02T00:00:00Z"}\n' \
    > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json" ]
  # The wiki-promote/ drop zone itself survives; only its stale entry is purged.
  [ -d "$REPO/.gaia/local/cache/wiki-promote" ]
}

# --- 21: a wiki-promote defer flag survives when a gate keeps the folder -----

@test "21: a wiki-promote defer flag survives when the age gate keeps the folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-abandoned-folder SPEC-001)"
  _set_abandoned_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x","deferred_at":"2026-01-02T00:00:00Z"}\n' \
    > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -d "$REPO/$SPECS/SPEC-001" ]
  [ -f "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json" ]
}
