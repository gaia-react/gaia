#!/usr/bin/env bats
# Delete-sweep tests for plan-archive-merged.sh, the plans-side mirror of
# spec-archive-merged.sh (see spec-archive-merged.bats for the shared design
# notes: age gate, consolidation gate, representation gate).
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness seeds only the
# specs ledger. Instead mirrors the self-copy sandbox pattern from
# .gaia/scripts/tests/plan-archive.bats: copy the script under test plus its
# runtime deps (cost-represented.sh, ledger-path-lib.sh) into an isolated
# sandbox and seed the plans ledger explicitly, so every sweep touches only
# throwaway fixtures.
#
# By the time a plan reaches this sweep it has already been reduced to
# SUMMARY.md + cost.json by plan-archive.sh, so the seeded happy-path fixture
# is SUMMARY.md-only (no SPEC.md); the consolidation-gate tests below add
# SPEC.md back in to exercise the defensive keep case.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SOURCE_LIBRARY_DIRECTORY="$REPO_ROOT/.gaia/scripts/spec"
  ARCHIVE_SOURCE="$SOURCE_LIBRARY_DIRECTORY/plan-archive-merged.sh"
  [ -x "$ARCHIVE_SOURCE" ] || skip "plan-archive-merged.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  mkdir -p "$SANDBOX/.gaia/scripts/spec" "$SANDBOX/.gaia/scripts" \
    "$SANDBOX/.gaia/local/plans" "$SANDBOX/.gaia/local/telemetry"

  cp "$ARCHIVE_SOURCE" "$SANDBOX/.gaia/scripts/spec/plan-archive-merged.sh"
  chmod +x "$SANDBOX/.gaia/scripts/spec/plan-archive-merged.sh"
  cp "$SOURCE_LIBRARY_DIRECTORY/ledger-lib.sh" "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
  # Representation gate deps, copied so the gate resolves against this
  # sandbox's own cost ledger instead of the real repo's.
  cp "$REPO_ROOT/.gaia/scripts/cost-represented.sh" "$SANDBOX/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh" "$SANDBOX/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$SANDBOX/.gaia/scripts/main-root-lib.sh"

  printf '{\n  "version": 1,\n  "plans": []\n}\n' > "$SANDBOX/.gaia/local/plans/ledger.json"
  : > "$SANDBOX/.gaia/local/telemetry/cost.jsonl"

  PLANS="$SANDBOX/.gaia/local/plans"
  LEDGER="$SANDBOX/.gaia/local/plans/ledger.json"
  COST_LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"

  # A fixed merged_at ("2026-01-02T00:00:00Z"), so every reap test below needs
  # the age gate collapsed to stay deterministic regardless of wall-clock
  # time. The age-gate tests re-export this per test to exercise the window.
  export GAIA_SPEC_RETENTION_DAYS=0
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

_archive() {
  bash "$SANDBOX/.gaia/scripts/spec/plan-archive-merged.sh" "$@"
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

# _seed_merged_plan <plan_id>: appends a merged ledger row AND writes the
# already-consolidated folder shape (SUMMARY.md only), the sweep's
# happy-path fixture.
_seed_merged_plan() {
  local id="$1"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.plans += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", subject: $id, status: "merged", merged_at: "2026-01-02T00:00:00Z"}]' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
  mkdir -p "$PLANS/$id"
  cat > "$PLANS/$id/SUMMARY.md" <<EOF
---
wiki_promote_default: ask
wiki_promote_targets: []
---
# $id

Consolidated summary body.
EOF
}

# _seed_merged_row_only <plan_id>: a merged ledger row with NO folder (the
# archive-sweep skip-no-folder case).
_seed_merged_row_only() {
  local id="$1"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.plans += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", subject: $id, status: "merged", merged_at: "2026-01-02T00:00:00Z"}]' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
}

# _seed_folder_only <plan_id>: a folder with no ledger row (the sweep is
# row-driven, so it stays active).
_seed_folder_only() {
  local id="$1"
  mkdir -p "$PLANS/$id"
  printf 'summary\n' > "$PLANS/$id/SUMMARY.md"
}

# _set_merged_at / _clear_merged_at <plan_id> [<iso>]: patch the seeded
# ledger row's merged_at, for age-window and fail-closed tests.
_set_merged_at() {
  local id="$1" iso="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --arg timestamp "$iso" \
    '.plans |= map(if .id == $id then . + {merged_at: $timestamp} else . end)' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
}

_clear_merged_at() {
  local id="$1"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.plans |= map(if .id == $id then del(.merged_at) else . end)' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
}

# _set_pr_number <plan_id> <number>: stamp the confirmed pr_number on a row.
_set_pr_number() {
  local id="$1" number="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --argjson number "$number" \
    '.plans |= map(if .id == $id then . + {pr_number: $number} else . end)' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
}

# _set_status <plan_id> <status>: rewrite a row's status.
_set_status() {
  local id="$1" new_status="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --arg value "$new_status" \
    '.plans |= map(if .id == $id then . + {status: $value} else . end)' \
    "$LEDGER" > "$temporary_file"
  mv "$temporary_file" "$LEDGER"
}

# _days_ago <days>: portable ISO8601 timestamp that many days in the past, computed with
# jq (never `date -d`/`date -j`), matching spec-archive-merged.bats.
_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _seed_cost_row <plan_id> <session> <fresh> <cache_write> <cache_read> <output>:
# appends a cost.jsonl row keyed by plan_id, matching token-tally's schema.
_seed_cost_row() {
  local id="$1" session="$2" fresh="$3" cache_write="$4" cache_read="$5" output="$6"
  local total=$((fresh + cache_write + cache_read + output))
  jq -cn --arg id "$id" --arg session_id "$session" \
    --argjson fresh "$fresh" --argjson cache_write "$cache_write" \
    --argjson cache_read "$cache_read" --argjson output "$output" --argjson total "$total" \
    '{schema_version: 1, kind: "execute", spec_id: null, plan_id: $id, plan_slug: null,
      session_id: $session_id,
      buckets: {fresh_input: $fresh, cache_write: $cache_write, cache_read: $cache_read, output: $output},
      total: $total, seq: 0, final: true, source: "test"}' \
    >> "$COST_LEDGER"
}

# --- 1: delete happy path (SUMMARY.md-only, cost represented) ---------------

@test "1: a merged row whose cost is represented is deleted; ledger row untouched" {
  _seed_merged_plan PLAN-001
  _seed_cost_row PLAN-001 sess-1 100 10 5 20

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  # Ledger row untouched: still merged, merged_at unchanged (the stamp is a
  # precondition, not set by this sweep).
  [ "$(jq -r '.plans[0].status' "$LEDGER")" = "merged" ]
  [ "$(jq -r '.plans[0].merged_at' "$LEDGER")" = "2026-01-02T00:00:00Z" ]
}

# --- 2: single-id filter narrows the sweep -----------------------------------

@test "2: the single-id form deletes only the named plan" {
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX" PLAN-001
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
  [ -d "$PLANS/PLAN-002" ]
}

# --- 5: the retired defer cache no longer blocks a reap ----------------------

@test "5: a leftover wiki-promote defer cache file beside a reapable plan no longer blocks its reap" {
  _seed_merged_plan PLAN-001
  mkdir -p "$SANDBOX/.gaia/local/cache/wiki-promote"
  printf '{"branch":"plan-1-x"}\n' > "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  # The sweep neither reads nor purges the retired path.
  [ -f "$SANDBOX/.gaia/local/cache/wiki-promote/PLAN-001.json" ]
}


@test "6: a merged row with no active folder is a no-op" {
  _seed_merged_row_only PLAN-005

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
}

# --- 7: idempotent re-run ----------------------------------------------------

@test "7: re-running the sweep after deleting is a no-op" {
  _seed_merged_plan PLAN-001

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 8: only merged rows with folders are swept ------------------------------

@test "8: a folder without a merged ledger row is never deleted" {
  _seed_merged_plan PLAN-001
  _seed_folder_only PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"

  [ ! -e "$PLANS/PLAN-001" ]
  # PLAN-002 untouched: still active, never deleted.
  [ -f "$PLANS/PLAN-002/SUMMARY.md" ]
}

# --- 9: multiple merged folders in one sweep --------------------------------

@test "9: two merged folders are deleted together with a combined summary" {
  _seed_merged_plan PLAN-001
  _seed_merged_plan PLAN-002

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 merged plan folder(s): PLAN-001, PLAN-002"
  [ ! -e "$PLANS/PLAN-001" ]
  [ ! -e "$PLANS/PLAN-002" ]
}

# --- 10: no merged rows -> clean no-op ---------------------------------------

@test "10: a repo with no merged rows produces no output and exits 0" {
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 11: age gate, within window -> kept -------------------------------------

@test "11: a merged folder within the retention window is kept, not deleted" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}


@test "12: a merged folder past the retention window with represented cost is reaped" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]

  [ "$(jq -r '.plans[0].status' "$LEDGER")" = "merged" ]
}


# --- 14/15: missing or unparseable merged_at -> kept regardless -------------

@test "14: a merged row with no merged_at is kept regardless of representation" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

@test "15: a merged row with an unparseable merged_at is kept regardless of representation" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "PLAN-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}

# --- 16/17: GAIA_SPEC_RETENTION_DAYS knob is honored --------------------------

@test "16: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-merged represented folder" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "17: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old merged folder" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]
}


@test "18: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  # Within the 30-day fallback: kept (proves the fallback isn't 0).
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 10)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  # Past the 30-day fallback: reaped (proves the fallback isn't unbounded).
  _seed_merged_plan PLAN-002
  _set_merged_at PLAN-002 "$(_days_ago 45)"
  run _archive "$SANDBOX" PLAN-002
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-002"
}

# --- 19: --close is accepted and ignored: no early reap ----------------------

@test "19: a within-window PLAN-007 stays kept with and without --close" {
  _seed_merged_plan PLAN-007
  _set_merged_at PLAN-007 "$(_days_ago 2)"
  _set_pr_number PLAN-007 2601
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX" PLAN-007
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-007" ]

  run _archive "$SANDBOX" PLAN-007 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-007" ]
}

@test "20: --close does not bypass the consolidation gate" {
  _seed_merged_plan PLAN-002
  rm -f "$PLANS/PLAN-002/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-002/SPEC.md"

  run _archive "$SANDBOX" PLAN-002 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-002" ]
}

# --- 21: consolidation gate keeps a SPEC.md/no-SUMMARY.md shape -------------

@test "21: a folder holding SPEC.md with no SUMMARY.md is kept past the window even when cost-represented (defensive)" {
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  _seed_cost_row PLAN-001 sess-1 100 10 5 20
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"

  [ -f "$PLANS/PLAN-001/SPEC.md" ]
}

# --- 22: real delegation to summary-verify.sh, not just the fallback -------

@test "22: prefers summary-verify.sh when present; a malformed but non-empty SUMMARY.md is kept" {
  [ -f "$REPO_ROOT/.gaia/scripts/summary-verify.sh" ] || skip "summary-verify.sh not present yet"
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"

  _seed_merged_plan PLAN-001
  printf '# Spec\n' > "$PLANS/PLAN-001/SPEC.md"
  # Non-empty but malformed content (no frontmatter/H1). A plain
  # [ -s SUMMARY.md ] fallback would wrongly pass this; only real delegation
  # to summary-verify.sh catches the malformed shape.
  printf 'not frontmatter, not well-formed\n' > "$PLANS/PLAN-001/SUMMARY.md"
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
}

# --- 23-24: the two reap arms -----------------------------------------------

@test "23: confirmed arm: a row with pr_number and an aged merged_at is reaped; inside the window it is kept" {
  _seed_merged_plan PLAN-001
  _set_pr_number PLAN-001 2601
  export GAIA_SPEC_RETENTION_DAYS=30

  _set_merged_at PLAN-001 "$(_days_ago 2)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_merged_at PLAN-001 "$(_days_ago 45)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "24: legacy arm: a merged row with no pr_number and an aged merged_at is reaped; inside the window it is kept" {
  _seed_merged_plan PLAN-001
  [ "$(jq -r '.plans[0].pr_number // "none"' "$LEDGER")" = "none" ]
  export GAIA_SPEC_RETENTION_DAYS=30

  _set_merged_at PLAN-001 "$(_days_ago 2)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_merged_at PLAN-001 "$(_days_ago 45)"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

@test "25: a legacy row with a missing merged_at is kept" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "26: a legacy row with an unparseable merged_at is kept" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "last tuesday"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "27: a ready row (no merged_at) with an otherwise reapable folder is kept, with or without a pr_number" {
  _seed_merged_plan PLAN-001
  _clear_merged_at PLAN-001
  _set_status PLAN-001 ready
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]

  _set_pr_number PLAN-001 2601
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

@test "27b: a ready row that carries a stale aged merged_at is still never a candidate" {
  _seed_merged_plan PLAN-001
  _set_status PLAN-001 ready
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$PLANS/PLAN-001" ]
}

# --- 28: the consolidation gate covers PROGRESS.md --------------------------

@test "28: a confirmed folder holding PROGRESS.md and no SUMMARY.md is kept; with a verified SUMMARY.md it is reaped" {
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
  _seed_merged_plan PLAN-001
  _set_pr_number PLAN-001 2601
  _seed_cost_row PLAN-001 sess-1 100 10 5 20
  summary_text="$(cat "$PLANS/PLAN-001/SUMMARY.md")"
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '## Phase 1\n' > "$PLANS/PLAN-001/PROGRESS.md"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
  [ -f "$PLANS/PLAN-001/PROGRESS.md" ]

  printf '%s\n' "$summary_text" > "$PLANS/PLAN-001/SUMMARY.md"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged plan folder(s): PLAN-001"
  [ ! -e "$PLANS/PLAN-001" ]
}

# --- 29: a folder with no SUMMARY.md is never reaped ------------------------

@test "29: an aged, cost-represented folder holding only plan files and no SUMMARY.md is kept" {
  _seed_merged_plan PLAN-001
  rm -f "$PLANS/PLAN-001/SUMMARY.md"
  printf '# Plan\n' > "$PLANS/PLAN-001/PLAN.md"
  _seed_cost_row PLAN-001 sess-1 100 10 5 20
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept PLAN-001"
  [ -f "$PLANS/PLAN-001/PLAN.md" ]
}

@test "30: without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped" {
  _seed_merged_plan PLAN-001
  _set_merged_at PLAN-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  mv "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh" "$SANDBOX/ledger-lib.sh.aside"
  run --separate-stderr _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  grep -qF "ledger-lib.sh is unusable; nothing swept" <<<"$stderr"
  [ -f "$PLANS/PLAN-001/SUMMARY.md" ]

  mv "$SANDBOX/ledger-lib.sh.aside" "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
  run _archive "$SANDBOX"
  [ "$status" -eq 0 ]
  [ ! -e "$PLANS/PLAN-001" ]
}
