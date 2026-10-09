#!/usr/bin/env bats
# Delete-sweep tests for spec-archive-merged.sh.
#
# The sweep is the safety net for the post-merge close: a merged SPEC whose
# folder still sits in the active specs dir (PR merged out-of-band, or an
# orchestrator that ended before its close) gets deleted by the pre-flight
# sweep of the next /gaia-spec or /gaia-plan run, once the retention window
# has passed. There is no early reap: --close is accepted and ignored.
#
# Deletion is gated on the usage ledger (`usage.sh represented`): a folder is
# only deleted once the ledger holds a gaia-spec close for its spec ref, and a
# gaia-plan close too when it holds a plan or plan-<N> subfolder.
# tmp-spec-repo.sh seeds an empty .gaia/local/telemetry/usage.jsonl and copies
# usage.sh with its libraries into every tmp repo so the gate resolves in
# isolation; tests append close rows with seed_close_row. A folder whose run
# the ledger does not record is kept and one stdout keep line names the ref and
# the recovery command.
#
# Sweep criteria: a ledger row with status "merged" AND an active folder AND
# an aged merged_at AND a passing usage-ledger gate. A merged row with no
# folder is skipped; a gate failure leaves the folder in place.
#
# Each test spins up its own tmp git repo via helpers/tmp-spec-repo.sh and
# tears it down; hermetic, no reliance on the real project ledger. The
# teardown uses the explicit-if form (the && idiom is a bats teardown
# footgun: a falsy first clause makes teardown itself "fail").
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".gaia/scripts/spec/spec-archive-merged.sh"
  SPECS=".gaia/local/specs"
  USAGE_LEDGER=".gaia/local/telemetry/usage.jsonl"
  # shellcheck source=helpers/usage-gate.sh
  . "$HELPERS/usage-gate.sh"
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

# _seed_close <ref> <workflow>: appends the close binding row (the shape
# `usage.sh record` writes) that `usage.sh represented` looks for, so the
# usage-ledger gate finds the run.
_seed_close() {
  seed_close_row "$REPO/.gaia/local/telemetry" "$1" "$2"
}

# _days_ago <days>: portable ISO8601 timestamp that many days in the past, computed with
# jq (never `date -d`/`date -j`, matching the project's cross-platform epoch
# rule; mirrors spec-abandon-empty.bats's old_ts/new_ts helpers).
_days_ago() {
  jq -rn --argjson days "$1" '(now - ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# _set_merged_at <repo> <spec_id> <iso>: patches the seeded ledger row's
# merged_at, for tests that need a specific age instead of the fixture's
# fixed date.
_set_merged_at() {
  local repo="$1" id="$2" iso="$3"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" --arg timestamp "$iso" \
    '.specs |= map(if .id == $id then . + {merged_at: $timestamp} else . end)' \
    "$repo/$SPECS/ledger.json" > "$temporary_file"
  mv "$temporary_file" "$repo/$SPECS/ledger.json"
}

# _clear_merged_at <repo> <spec_id>: removes merged_at from the seeded ledger
# row, for the missing-merged_at keep case.
_clear_merged_at() {
  local repo="$1" id="$2"
  local temporary_file; temporary_file="$(mktemp)"
  jq --arg id "$id" \
    '.specs |= map(if .id == $id then del(.merged_at) else . end)' \
    "$repo/$SPECS/ledger.json" > "$temporary_file"
  mv "$temporary_file" "$repo/$SPECS/ledger.json"
}

# --- 1: delete happy path (cost represented) ---------------------------------

@test "1: a merged row whose run is on the usage ledger is deleted; ledger stays merged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec

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
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-002 gaia-spec

  # All-ids sweep (both runs are on the usage ledger).
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
  [ ! -e "$REPO/$SPECS/archived" ]

  # Single-id form, exercised independently on a fresh repo.
  REPO2="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-003 --seed-merged-folder SPEC-004)"
  seed_close_row "$REPO2/.gaia/local/telemetry" spec:SPEC-003 gaia-spec
  seed_close_row "$REPO2/.gaia/local/telemetry" spec:SPEC-004 gaia-spec
  run bash "$REPO2/$ARCHIVE" "$REPO2" SPEC-003
  [ "$status" -eq 0 ]
  [ ! -e "$REPO2/$SPECS/SPEC-003" ]
  [ -d "$REPO2/$SPECS/SPEC-004" ]
  [ ! -e "$REPO2/$SPECS/archived" ]
  rm -rf "$REPO2"
}

# --- 6: the retired defer cache no longer blocks a reap ----------------------

@test "6: a leftover wiki-promote defer cache file beside a reapable spec no longer blocks its reap" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x"}\n' > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  # The sweep neither reads nor purges the retired path.
  [ -f "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json" ]
}

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
  _seed_close spec:SPEC-001 gaia-spec

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
  _seed_close spec:SPEC-001 gaia-spec

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
  _seed_close spec:SPEC-001 gaia-spec
  _seed_close spec:SPEC-002 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 2 merged SPEC folder(s): SPEC-001, SPEC-002"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}


@test "11: no specs/archived/ tree appears across delete and skip paths" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-merged-folder SPEC-001 --seed-merged SPEC-003)"
  _seed_close spec:SPEC-001 gaia-spec
  # SPEC-001: run recorded, deletes. SPEC-003: merged row with no folder, skipped.

  run _archive "$REPO"
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
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


@test "14: a merged folder past the retention window with its run recorded is reaped" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 45)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]

  # Ledger row stays merged; merged_at is a precondition, not set by the sweep.
  [ "$(jq -r '.specs[0].status' "$REPO/$SPECS/ledger.json")" = "merged" ]
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

@test "18: GAIA_SPEC_RETENTION_DAYS=0 reaps a just-merged recorded folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
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
  seed_close_row "$REPO2/.gaia/local/telemetry" spec:SPEC-002 gaia-spec
  _set_merged_at "$REPO2" SPEC-002 "$(_days_ago 45)"
  run bash "$REPO2/$ARCHIVE" "$REPO2"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-002"
  rm -rf "$REPO2"
}

# --- 21: --close is accepted and ignored: no early reap -----------------------

@test "21: a within-window consolidated folder stays kept with and without --close" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _set_merged_at "$REPO" SPEC-001 "$(_days_ago 2)"
  export GAIA_SPEC_RETENTION_DAYS=30

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-001 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

# --- 22: --close never bypasses the consolidation gate -----------------------

@test "22: --close does not bypass the consolidation gate" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-002)"
  rm -f "$REPO/$SPECS/SPEC-002/SUMMARY.md"

  run bash "$REPO/$ARCHIVE" "$REPO" SPEC-002 --close
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  [ -d "$REPO/$SPECS/SPEC-002" ]
}

# --- 23: consolidation gate keeps a SPEC.md-only folder regardless of age/cost -

@test "23: a folder holding SPEC.md with no SUMMARY.md is kept past the window even when its run is recorded" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  rm -f "$REPO/$SPECS/SPEC-001/SUMMARY.md"
  _seed_close spec:SPEC-001 gaia-spec
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
  _seed_close spec:SPEC-001 gaia-spec
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
  verify_source="$real_root/.gaia/scripts/summary-verify.sh"
  [ -f "$verify_source" ] || skip "summary-verify.sh not present yet"

  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  cp "$verify_source" "$REPO/.gaia/scripts/summary-verify.sh"
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

# --- 27: the liveness lock is reaped with the rest of the merged keyset -----

@test "27: a .lock file is reaped alongside the deleted merged folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec
  echo '{"spec_id":"SPEC-001"}' > "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"

  [ ! -e "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/.gaia/local/cache/spec-session-SPEC-001.lock" ]
}

@test "28: without ledger-lib.sh the sweep reaps nothing and says so; with it the same folder is reaped" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-spec

  mv "$REPO/.gaia/scripts/spec/ledger-lib.sh" "$REPO/ledger-lib.sh.aside"
  run --separate-stderr _archive "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "ledger-lib.sh is unusable; nothing swept" <<<"$stderr"
  [ -d "$REPO/$SPECS/SPEC-001" ]

  mv "$REPO/ledger-lib.sh.aside" "$REPO/.gaia/scripts/spec/ledger-lib.sh"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

@test "29: a run missing from the usage ledger leaves its folder, prints the keep line, and the sweep still reaps the next row" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002)"
  _seed_close spec:SPEC-002 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Kept .gaia/local/specs/SPEC-001: no gaia-spec run recorded for spec:SPEC-001; outside a live gaia-spec run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-spec --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001" ]
  [ ! -e "$REPO/$SPECS/SPEC-002" ]
}

@test "30: a missing usage ledger keeps the folder and the keep line names the ledger path" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  rm -f "$REPO/$USAGE_LEDGER"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept .gaia/local/specs/SPEC-001: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for spec:SPEC-001; once it reads, outside a live gaia-spec run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-spec --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

@test "31: a gaia-plan close alone does not clear a folder that needs its gaia-spec run" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  _seed_close spec:SPEC-001 gaia-plan

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept .gaia/local/specs/SPEC-001: no gaia-spec run recorded for spec:SPEC-001"
  [ -d "$REPO/$SPECS/SPEC-001" ]
}

@test "32: a folder holding a plan subfolder needs both the gaia-spec and the gaia-plan close" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  mkdir -p "$REPO/$SPECS/SPEC-001/plan"
  _seed_close spec:SPEC-001 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "Kept .gaia/local/specs/SPEC-001: no gaia-plan run recorded for spec:SPEC-001; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-001 --workflow gaia-plan --start <iso>"
  [ -d "$REPO/$SPECS/SPEC-001/plan" ]

  _seed_close spec:SPEC-001 gaia-plan
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  assert_contains "Deleted 1 merged SPEC folder(s): SPEC-001"
  [ ! -e "$REPO/$SPECS/SPEC-001" ]
}

@test "33: a plan-<N> subfolder also requires the gaia-plan close" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  mkdir -p "$REPO/$SPECS/SPEC-001/plan-2"
  _seed_close spec:SPEC-001 gaia-spec

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  refute_contains "Deleted"
  assert_contains "no gaia-plan run recorded for spec:SPEC-001"
  [ -d "$REPO/$SPECS/SPEC-001/plan-2" ]
}
