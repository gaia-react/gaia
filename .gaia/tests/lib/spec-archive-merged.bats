#!/usr/bin/env bats
# Delete-sweep tests for spec-archive-merged.sh (UAT-004, COV-006, DP-003).
#
# The sweep is the safety net for the SPEC close flow: a merged SPEC whose
# folder still sits in the active specs dir (PR merged out-of-band, or a stale
# session that never ran close) gets deleted on the next /gaia-spec run. The
# SPEC close command's own single-id delete delegates to the same script, so
# both entry points share one gate.
#
# Deletion is gated on cost representation (cost_folder_represented, sourced
# from .gaia/scripts/cost-represented.sh): a folder is only deleted once every
# cost.md phase section under it is value-represented by a matching cost.jsonl
# row. tmp-spec-repo.sh seeds an empty .gaia/local/telemetry/cost.jsonl and
# copies of cost-represented.sh / ledger-path-lib.sh into every tmp repo so the
# gate resolves in isolation; individual tests append rows to exercise it. A
# folder with no cost.md at all is automatically represented (nothing to
# lose), so most fixtures below need no ledger row.
#
# Sweep criteria: a ledger row with status "merged" AND an active folder AND
# no pending wiki-promote drain cache AND a passing representation gate. A
# merged row with no folder is skipped; a spec with a drain cache is left for
# the close flow; a gate failure leaves the folder in place for review.
#
# Each test spins up its own tmp git repo via helpers/tmp-spec-repo.sh and
# tears it down; hermetic, no reliance on the real project ledger. The
# teardown uses the explicit-if form (the && idiom is a bats teardown
# footgun: a falsy first clause makes teardown itself "fail").
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on
# macOS's system bash 3.2). This suite uses `[ ... ]` and the
# assert_contains/refute_contains grep helpers below for everything but a
# test's last statement.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".specify/extensions/gaia/lib/spec-archive-merged.sh"
  SPECS=".gaia/local/specs"
  LEDGER=".gaia/local/telemetry/cost.jsonl"
  # --seed-merged-folder stamps a fixed merged_at ("2026-01-02T00:00:00Z")
  # rather than "just merged", so every delete test below needs the age gate
  # collapsed to stay deterministic regardless of wall-clock time. The
  # age-gate tests re-export this per test to exercise the window itself.
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

# Deterministic snapshot of the specs tree: relative paths + per-file sha,
# sorted. Used to assert "nothing changed" across idempotent / skip runs.
_snapshot() {
  ( cd "$REPO/$SPECS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# _plant_cost_md <spec_id> <fresh> <cwrite> <cread> <output> <session>: writes
# a `## SPEC` cost.md section under the seeded folder, mirroring
# token-tally.sh's render_tally_body bucket-table + Session line shape.
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

# _seed_cost_row <spec_id> <session> <fresh> <cwrite> <cread> <output>: appends
# a cost.jsonl row matching the schema token-tally.sh / cost-backfill.sh write,
# so the representation gate finds it for <spec_id>.
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

# _days_ago <n>: portable ISO8601 timestamp n days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule; mirrors spec-abandon-empty.bats's old_ts/new_ts helpers).
_days_ago() {
  jq -rn --argjson n "$1" '(now - ($n * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _set_merged_at <repo> <spec_id> <iso>: patches the seeded ledger row's
# merged_at, for tests that need a specific age instead of the fixture's
# fixed date.
_set_merged_at() {
  local repo="$1" id="$2" iso="$3"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg ts "$iso" \
    '.specs |= map(if .id == $id then . + {merged_at: $ts} else . end)' \
    "$repo/$SPECS/ledger.json" > "$tmp"
  mv "$tmp" "$repo/$SPECS/ledger.json"
}

# _clear_merged_at <repo> <spec_id>: removes merged_at from the seeded ledger
# row, for the missing-merged_at keep case.
_clear_merged_at() {
  local repo="$1" id="$2"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" \
    '.specs |= map(if .id == $id then del(.merged_at) else . end)' \
    "$repo/$SPECS/ledger.json" > "$tmp"
  mv "$tmp" "$repo/$SPECS/ledger.json"
}

# --- 1: delete happy path (cost represented) ---------------------------------

@test "1: a merged row whose cost is represented is deleted; ledger stays merged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  _seed_cost_row SPEC-001 sess-1 100 10 5 20

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  # Ledger row untouched: still merged, merged_at unchanged (the stamp is a
  # precondition, not set by this sweep).
  [ "$(jq -r '.specs[0].status' "$REPO/$SPECS/ledger.json")" = "merged" ]
  [ "$(jq -r '.specs[0].merged_at' "$REPO/$SPECS/ledger.json")" = "2026-01-02T00:00:00Z" ]
}

# --- 2: both entry points delete, neither leaves an archived/ copy ----------

@test "2: the all-ids sweep and the single-id form both delete with no archived/ copy" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002)"

  # All-ids sweep (both have no cost.md, so both are automatically represented).
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  # Single-id form, exercised independently on a fresh repo.
  REPO2="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-003 --seed-merged-folder SPEC-004)"
  run bash "$REPO2/$ARCHIVE" "$REPO2" SPEC-003
  [ "$status" -eq 0 ]
  [ ! -e "$REPO2/$SPECS/SPEC-003" ]
  [ -d "$REPO2/$SPECS/SPEC-004" ]
  [ ! -e "$REPO2/$SPECS/archived" ]
  rm -rf "$REPO2"
}

# --- 3: spec-close delegation ordering (structural, no execution) ----------

@test "3: spec-close flips the ledger before delegating to the single-id sweep" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --show-toplevel)"
  SPEC_CLOSE="$REPO_ROOT/.specify/extensions/gaia/commands/spec-close.md"
  [ -f "$SPEC_CLOSE" ]

  flip_line="$(grep -n 'ledger-update.sh' "$SPEC_CLOSE" | head -1 | cut -d: -f1)"
  sweep_line="$(grep -n 'spec-archive-merged.sh' "$SPEC_CLOSE" | tail -1 | cut -d: -f1)"
  [ -n "$flip_line" ]
  [ -n "$sweep_line" ]
  [ "$flip_line" -lt "$sweep_line" ]

  sweep_call="$(grep -n 'spec-archive-merged.sh' "$SPEC_CLOSE" | tail -1)"
  grep -qF '"$PWD"' <<<"$sweep_call"
  grep -qF '"$SPEC_ID"' <<<"$sweep_call"
}

# --- 5: representation gate blocks an unrepresented cost.md ------------------

@test "5: an unrepresented cost.md section blocks deletion; folder survives" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  # No matching cost.jsonl row: the SPEC section is unrepresented.

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left SPEC-001 folder for review"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
  [ ! -e "$REPO/$SPECS/archived" ]
}

# --- 6: skip when a drain cache is pending -----------------------------------

@test "6: a merged spec with a pending wiki-promote drain cache is left active" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x"}\n' > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
  [ ! -e "$REPO/$SPECS/archived" ]
}

# --- 7: skip a merged row with no folder -------------------------------------

@test "7: a merged row with no active folder is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged SPEC-005)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ ! -e "$REPO/$SPECS/archived" ]
}

# --- 8: idempotent re-run ----------------------------------------------------

@test "8: re-running the sweep after deleting is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  after="$(_snapshot)"
  [ "$before" = "$after" ]
}

# --- 9: only merged rows with folders are swept ------------------------------

@test "9: a folder without a merged ledger row is never deleted" {
  # SPEC-001: merged row + folder (gets deleted). SPEC-002: folder only, no
  # ledger row (the sweep is row-driven, so it stays active).
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001 --seed-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # SPEC-002 untouched: still active, never deleted.
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
}

# --- 10: multiple merged folders in one sweep --------------------------------

@test "10: two merged folders are deleted together with a combined summary" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 merged SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}

# --- 11: no archived/ tree, ever, across delete/block/skip in one run -------

@test "11: no specs/archived/ tree appears across delete, block, and skip paths" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002 --seed-merged SPEC-003)"
  _plant_cost_md SPEC-002 100 10 5 20 sess-1
  # SPEC-001: no cost.md, deletes. SPEC-002: unrepresented cost.md, blocked.
  # SPEC-003: merged row with no folder, skipped.

  run _archive "$REPO"
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ -d "$REPO/$SPECS/SPEC-002" ]
  [ ! -e "$REPO/$SPECS/archived" ]
}

# --- 12: no ledger -> clean no-op --------------------------------------------

@test "12: a repo with no merged rows produces no output and exits 0" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 13: age gate, within window -> kept -------------------------------------

@test "13: a merged folder within the retention window is kept, not deleted" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

# --- 14: age gate, past window + represented -> reaped -----------------------

@test "14: a merged folder past the retention window with represented cost is reaped" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]

  # Ledger row stays merged; merged_at is a precondition, not set by the sweep.
  [ "$(jq -r '.specs[0].status' "$REPO/$SPECS/ledger.json")" = "merged" ]
}

# --- 15: age gate, past window but unrepresented -> kept ---------------------

@test "15: a folder past the retention window but unrepresented is kept" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  # No matching cost.jsonl row: the SPEC section is unrepresented.
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "cost not fully represented in cost.jsonl; left SPEC-001 folder for review"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

# --- 16/17: missing or unparseable merged_at -> kept regardless of age/rep ---

@test "16: a merged row with no merged_at is kept regardless of representation" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _clear_merged_at "$REPO" SPEC-001
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

@test "17: a merged row with an unparseable merged_at is kept regardless of representation" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "not-a-timestamp"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "SPEC-001 within retention window (or merged_at missing/unparseable); kept"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

# --- 18/19: GAIA_SPEC_RETENTION_DAYS knob is honored --------------------------

@test "18: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-merged represented folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 0)"
  export GAIA_SPEC_RETENTION_DAYS=0

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

@test "19: GAIA_SPEC_RETENTION_DAYS=99999 keeps an old merged folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 400)"
  export GAIA_SPEC_RETENTION_DAYS=99999

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

# --- 20: a non-numeric knob value falls back to the 30-day default ----------

@test "20: a non-numeric GAIA_SPEC_RETENTION_DAYS falls back to the 30-day default" {
  export GAIA_SPEC_RETENTION_DAYS="abc"

  # Within the 30-day fallback: kept (proves the fallback isn't 0).
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 10)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  # Past the 30-day fallback: reaped (proves the fallback isn't unbounded).
  REPO2="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-002)"
  _set_merged_at "$REPO2" SPEC-002 "$(_days_ago 45)"
  run bash "$REPO2/$ARCHIVE" "$REPO2"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-002"
  rm -rf "$REPO2"
}

# --- 21: --close bypasses the age gate only -----------------------------------

@test "21: --close reaps a within-window consolidated folder; without --close it stays kept" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001 --close
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

# --- 22: --close never bypasses the cost or consolidation gates --------------

@test "22: --close does not bypass the cost gate or the consolidation gate" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002)"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  # No matching cost.jsonl row for SPEC-001: unrepresented.
  rm -f "$REPO/$SPECS/SPEC-002/SUMMARY.md"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-002 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-002" ]
}

# --- 23: consolidation gate keeps a SPEC.md-only folder regardless of age/cost -

@test "23: a folder holding SPEC.md with no SUMMARY.md is kept past the window even when cost-represented" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  rm -f "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  _plant_cost_md SPEC-001 100 10 5 20 sess-1
  _seed_cost_row SPEC-001 sess-1 100 10 5 20
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"

  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
}

@test "24: a folder holding only AUDIT.md (no SPEC.md, no SUMMARY.md) is kept" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  rm -f "$REPO/$SPECS/SPEC-001/SPEC.md" "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  printf '# Audit\n' > "$REPO/$SPECS/SPEC-001/AUDIT.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"

  [ -f "$REPO/$SPECS/SPEC-001/AUDIT.md" ]
}

@test "25: a folder already reduced to SUMMARY.md (no SPEC.md) passes the consolidation gate" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  rm -f "$REPO/$SPECS/SPEC-001/SPEC.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

# --- 26: real delegation to summary-verify.sh, not just the fallback --------

@test "26: prefers summary-verify.sh when present; a malformed but non-empty SUMMARY.md is kept" {
  real_root="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --show-toplevel)"
  verify_src="$real_root/.gaia/scripts/summary-verify.sh"
  [ -f "$verify_src" ] || skip "summary-verify.sh not present yet"

  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  cp "$verify_src" "$REPO/.gaia/scripts/summary-verify.sh"
  # SPEC.md is already seeded; overwrite SUMMARY.md with non-empty but
  # malformed content (no frontmatter/H1). A plain [ -s SUMMARY.md ] fallback
  # would wrongly pass this; only real delegation to summary-verify.sh
  # catches the malformed shape.
  printf 'not frontmatter, not well-formed\n' > "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "consolidation never ran; kept SPEC-001"
}
