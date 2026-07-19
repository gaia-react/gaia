#!/usr/bin/env bats
# Delete-sweep tests for plan-archive-abandoned.sh, the abandoned-status
# counterpart to plan-archive-merged.sh (see that suite for the merged path
# this mirrors) and the plans-side mirror of spec-archive-abandoned.bats.
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness seeds only the
# specs ledger. Instead mirrors plan-archive-merged.bats's self-copy sandbox
# pattern: copy the script under test plus its runtime deps
# (cost-represented.sh, ledger-path-lib.sh) into an isolated sandbox and seed
# the plans ledger explicitly, so every sweep touches only throwaway
# fixtures.
#
# Deletion is gated on cost representation, the same fail-closed gate the
# merged sweep uses. Unlike the merged sweep there is no consolidation gate
# and no wiki-promote drain check that blocks deletion: an abandoned folder
# reaps as one unit, but a pending wiki-promote defer flag is purged rather
# than orphaned (test 8 below).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]`. This suite uses `[ ... ]` and the
# assert_contains/refute_contains grep helpers below for everything but a
# test's last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SRC_LIB="$REPO_ROOT/.specify/extensions/gaia/lib"
  ARCHIVE_SRC="$SRC_LIB/plan-archive-abandoned.sh"
  [ -x "$ARCHIVE_SRC" ] || skip "plan-archive-abandoned.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib" "$SANDBOX/.gaia/scripts" \
    "$SANDBOX/.gaia/local/plans" "$SANDBOX/.gaia/local/telemetry" \
    "$SANDBOX/.gaia/local/cache/wiki-promote"

  cp "$ARCHIVE_SRC" "$SANDBOX/.specify/extensions/gaia/lib/plan-archive-abandoned.sh"
  chmod +x "$SANDBOX/.specify/extensions/gaia/lib/plan-archive-abandoned.sh"
  # Representation gate deps, copied so the gate resolves against this
  # sandbox's own cost ledger instead of the real repo's.
  cp "$REPO_ROOT/.gaia/scripts/cost-represented.sh" "$SANDBOX/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh" "$SANDBOX/.gaia/scripts/ledger-path-lib.sh"

  printf '{\n  "version": 1,\n  "plans": []\n}\n' > "$SANDBOX/.gaia/local/plans/ledger.json"
  : > "$SANDBOX/.gaia/local/telemetry/cost.jsonl"

  PLANS="$SANDBOX/.gaia/local/plans"
  LEDGER="$SANDBOX/.gaia/local/plans/ledger.json"
  COST_LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"

  # A fixed abandoned_at ("2026-01-02T00:00:00Z"), so every reap test below
  # needs the age gate collapsed to stay deterministic regardless of
  # wall-clock time. The age-gate tests re-export this per test.
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

_archive() {
  bash "$SANDBOX/.specify/extensions/gaia/lib/plan-archive-abandoned.sh" "$@"
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
  ( cd "$PLANS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# _seed_abandoned_plan <plan_id>: appends an abandoned ledger row AND writes
# the still-active folder shape (an abandoned plan is never reduced by
# sweep 3's plan-archive.sh, which only ever handles merged rows).
_seed_abandoned_plan() {
  local id="$1"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.plans += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", subject: $id, status: "abandoned", abandoned_at: "2026-01-02T00:00:00Z"}]' \
    "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
  mkdir -p "$PLANS/$id"
  cat > "$PLANS/$id/PLAN.md" <<EOF
# $id

Draft plan body.
EOF
}

# _seed_abandoned_row_only <plan_id>: an abandoned ledger row with NO folder
# (the archive-sweep skip-no-folder case).
_seed_abandoned_row_only() {
  local id="$1"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.plans += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", subject: $id, status: "abandoned", abandoned_at: "2026-01-02T00:00:00Z"}]' \
    "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
}

# _seed_merged_plan <plan_id>: a merged row + folder, to prove the abandoned
# sweep never touches it.
_seed_merged_plan() {
  local id="$1"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.plans += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", subject: $id, status: "merged", merged_at: "2026-01-02T00:00:00Z"}]' \
    "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
  mkdir -p "$PLANS/$id"
  printf 'summary\n' > "$PLANS/$id/SUMMARY.md"
}

# _seed_folder_only <plan_id>: a folder with no ledger row (the sweep is
# row-driven, so it stays active).
_seed_folder_only() {
  local id="$1"
  mkdir -p "$PLANS/$id"
  printf 'plan\n' > "$PLANS/$id/PLAN.md"
}

# _set_abandoned_at / _clear_abandoned_at <plan_id> [<iso>]: patch the seeded
# ledger row's abandoned_at, for age-window and fail-closed tests.
_set_abandoned_at() {
  local id="$1" iso="$2"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg ts "$iso" \
    '.plans |= map(if .id == $id then . + {abandoned_at: $ts} else . end)' \
    "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
}

_clear_abandoned_at() {
  local id="$1"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.plans |= map(if .id == $id then del(.abandoned_at) else . end)' \
    "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
}

# _days_ago <n>: portable ISO8601 timestamp n days in the past, computed with
# jq (never `date -d`/`date -j`), matching plan-archive-merged.bats.
_days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _plant_cost_md <plan_id> <fresh> <cwrite> <cread> <output> <session>: writes
# an `## Execution` cost.md section under the seeded folder.
_plant_cost_md() {
  local id="$1" fresh="$2" cwrite="$3" cread="$4" output="$5" session="$6"
  cat > "$PLANS/$id/cost.md" <<EOF
# Cost: $id

## Execution

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

# _seed_cost_row <plan_id> <session> <fresh> <cwrite> <cread> <output>:
# appends a cost.jsonl row keyed by plan_id, matching token-tally's schema.
_seed_cost_row() {
  local id="$1" session="$2" fresh="$3" cwrite="$4" cread="$5" output="$6"
  local total=$((fresh + cwrite + cread + output))
  jq -cn --arg id "$id" --arg sid "$session" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" --argjson total "$total" \
    '{schema_version: 1, kind: "execute", spec_id: null, plan_id: $id, plan_slug: null,
      session_id: $sid,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: $total, seq: 0, final: true, source: "test"}' \
    >> "$COST_LEDGER"
}

# --- 1: delete happy path (cost represented) ---------------------------------

@test "1: an abandoned row whose cost is represented is deleted; ledger stays abandoned" {
  _seed_abandoned_plan PLAN-001
  _plant_cost_md PLAN-001 100 10 5 20 sess-1
  _seed_cost_row PLAN-001 sess-1 100 10 5 20

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  [ "$(jq -r '.plans[0].status' "$LEDGER")" = "abandoned" ]
  [ "$(jq -r '.plans[0].abandoned_at' "$LEDGER")" = "2026-01-02T00:00:00Z" ]
}

# --- 2: single-id filter narrows the sweep -----------------------------------

@test "2: the single-id form deletes only the named plan" {
  _seed_abandoned_plan PLAN-001
  _seed_abandoned_plan PLAN-002

  run _archive "$SANDBOX" PLAN-001
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
  [ -d "$PLANS/PLAN-002" ]
}

# --- 3: representation gate blocks an unrepresented cost.md ------------------

@test "3: an unrepresented cost.md section blocks deletion; folder survives" {
  _seed_abandoned_plan PLAN-001
  _plant_cost_md PLAN-001 100 10 5 20 sess-1
  # No matching cost.jsonl row: unrepresented.

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left PLAN-001 folder for review"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

# --- 4: skip an abandoned row with no folder ---------------------------------

@test "4: an abandoned row with no active folder is a no-op" {
  _seed_abandoned_row_only PLAN-005

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
}

# --- 5: idempotent re-run -----------------------------------------------------

@test "5: re-running the sweep after deleting is a no-op" {
  _seed_abandoned_plan PLAN-001

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"

  before="$(_snapshot)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]
}

# --- 6: a merged row is never touched by the abandoned sweep ----------------

@test "6: a merged row is never touched by the abandoned sweep" {
  _seed_abandoned_plan PLAN-001
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  [ -f "$PLANS/PLAN-002/SUMMARY.md" ]
}

# --- 7: a folder without an abandoned ledger row is never deleted -----------

@test "7: a folder without an abandoned ledger row is never deleted" {
  _seed_abandoned_plan PLAN-001
  _seed_folder_only PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  [ -f "$PLANS/PLAN-002/PLAN.md" ]
}

# --- 8: a dangling wiki-promote defer flag is purged, not orphaned ----------

@test "8: reaping an abandoned row purges its wiki-promote defer flag too" {
  _seed_abandoned_plan PLAN-001
  printf '{"branch":"plan-1-x","deferred_at":"2026-01-02T00:00:00Z"}\n' \
    > "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  [ ! -e "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json" ]
  # The wiki-promote/ drop zone itself survives; only its stale entry is purged.
  [ -d "$SANDBOX/.gaia/local/cache/wiki-promote" ]
}

# --- 9: a wiki-promote defer flag survives when a gate keeps the folder ----

@test "9: a wiki-promote defer flag survives when the age gate keeps the folder" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30
  printf '{"branch":"plan-1-x","deferred_at":"2026-01-02T00:00:00Z"}\n' \
    > "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -d "$PLANS/PLAN-001" ]
  [ -f "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json" ]
}

# --- 10: no abandoned rows -> clean no-op ------------------------------------

@test "10: a repo with no abandoned rows produces no output and exits 0" {
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 11: age gate, within window -> kept -------------------------------------

@test "11: an abandoned folder within the retention window is kept, not deleted" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

# --- 12: age gate, past window + represented -> reaped -----------------------

@test "12: an abandoned folder past the retention window with represented cost is reaped" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  [ "$(jq -r '.plans[0].status' "$LEDGER")" = "abandoned" ]
}

# --- 13: age gate, past window but unrepresented -> kept ---------------------

@test "13: a folder past the retention window but unrepresented is kept" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 45)"
  _plant_cost_md PLAN-001 100 10 5 20 sess-1
  # No matching cost.jsonl row: unrepresented.
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left PLAN-001 folder for review"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

# --- 14/15: missing or unparseable abandoned_at -> kept regardless ----------

@test "14: an abandoned row with no abandoned_at is kept regardless of representation" {
  _seed_abandoned_plan PLAN-001
  _clear_abandoned_at PLAN-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

@test "15: an abandoned row with an unparseable abandoned_at is kept regardless of representation" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or abandoned_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

# --- 16/17: GAIA_SPEC_RETENTION_DAYS knob is honored, shared with the merged sweep

@test "16: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-abandoned represented folder" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "17: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old abandoned folder" {
  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

# --- 18: a non-numeric knob value falls back to the 30-day default ---------

@test "18: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  _seed_abandoned_plan PLAN-001
  _set_abandoned_at PLAN-001 "$(_days_ago 10)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _seed_abandoned_plan PLAN-002
  _set_abandoned_at PLAN-002 "$(_days_ago 45)"
  run _archive "$SANDBOX" PLAN-002
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-002"
}

# --- 19: no consolidation gate -- a bare PLAN.md folder still reaps ---------

@test "19: an abandoned folder holding only PLAN.md reaps with no consolidation gate" {
  _seed_abandoned_plan PLAN-001
  [ -f "$PLANS/PLAN-001/PLAN.md" ]
  [ ! -e "$PLANS/PLAN-001/SUMMARY.md" ]

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 abandoned plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}
