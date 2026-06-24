#!/usr/bin/env bats
# Auto-archive-merged sweep tests for spec-archive-merged.sh.
#
# The sweep is the safety net for the /gaia-spec close flow: a merged SPEC whose
# folder still sits in the active specs dir (PR merged out-of-band, or a "Keep
# in place" disposition) gets moved into .gaia/local/specs/archived/ on the next
# /gaia-spec run. It mirrors spec-close.md Step 4 (stamp SPEC.md frontmatter,
# move the folder) and Step 6 (emit a spec_closed telemetry event), and leaves
# the ledger row at "merged" (disposition lives on the artifact, not the ledger,
# per wiki/concepts/GAIA Spec.md "Ledger status vocabulary").
#
# Sweep criteria: a ledger row with status "merged" AND an active folder AND no
# pending wiki-promote drain cache. A merged row with no folder is skipped; a
# spec with a drain cache is left for the close flow.
#
# Each test spins up its own tmp git repo via helpers/tmp-spec-repo.sh and tears
# it down; hermetic, no reliance on the real project ledger. The teardown uses
# the explicit-if form (the && idiom is a bats teardown footgun: a falsy first
# clause makes teardown itself "fail").

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ARCHIVE=".specify/extensions/gaia/lib/spec-archive-merged.sh"
  SPECS=".gaia/local/specs"
  TELEMETRY=".gaia/local/telemetry/spec-pacing.jsonl"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_archive() {
  bash "$REPO/$ARCHIVE" "$@"
}

# Deterministic snapshot of the specs tree: relative paths + per-file sha,
# sorted. Used to assert "nothing changed" across idempotent / skip runs.
_snapshot() {
  ( cd "$REPO/$SPECS" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# --- 1: archive happy path ---------------------------------------------------

@test "1: a merged row with an active folder is archived; ledger stays merged" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archived 1 merged SPEC(s): SPEC-001"* ]]

  # Folder moved under archived/; active path gone.
  [ -f "$REPO/$SPECS/archived/SPEC-001/SPEC.md" ]
  [ ! -e "$REPO/$SPECS/SPEC-001" ]

  # Frontmatter stamped: status -> archived, archived_at present, everything
  # else (immutable: true, spec_id) preserved verbatim.
  archived="$REPO/$SPECS/archived/SPEC-001/SPEC.md"
  grep -q '^status: archived$' "$archived"
  grep -qE '^archived_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$archived"
  grep -q '^immutable: true$' "$archived"
  grep -q '^spec_id: SPEC-001$' "$archived"
  # The pre-archive status line is gone (replaced, not duplicated).
  [ "$(grep -c '^status:' "$archived")" -eq 1 ]

  # Ledger row is untouched: still merged (disposition lives on the artifact).
  [ "$(jq -r '.specs[0].status' "$REPO/.gaia/specs.json")" = "merged" ]
}

# --- 2: skip when a drain cache is pending -----------------------------------

@test "2: a merged spec with a pending wiki-promote drain cache is left active" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  mkdir -p "$REPO/.gaia/local/cache/wiki-promote"
  printf '{"branch":"spec-1-x"}\n' > "$REPO/.gaia/local/cache/wiki-promote/SPEC-001.json"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Archived"* ]]

  # Folder stays put; nothing archived.
  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
  [ ! -e "$REPO/$SPECS/archived/SPEC-001" ]
  # Frontmatter untouched (still the pre-archive status).
  grep -q '^status: specified$' "$REPO/$SPECS/SPEC-001/SPEC.md"
}

# --- 3: skip a merged row with no folder -------------------------------------

@test "3: a merged row with no active folder is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged SPEC-005)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Archived"* ]]
  [ ! -e "$REPO/$SPECS/archived" ]
}

# --- 4: idempotent re-run ----------------------------------------------------

@test "4: re-running the sweep after archiving is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archived 1 merged SPEC(s): SPEC-001"* ]]

  before="$(_snapshot)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Archived"* ]]
  after="$(_snapshot)"
  [ "$before" = "$after" ]
}

# --- 5: telemetry emission ---------------------------------------------------

@test "5: archiving appends a spec_closed telemetry event (disposition archive)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]

  [ -f "$REPO/$TELEMETRY" ]
  last="$(tail -n 1 "$REPO/$TELEMETRY")"
  [ "$(printf '%s' "$last" | jq -r '.event')" = "spec_closed" ]
  [ "$(printf '%s' "$last" | jq -r '.spec_id')" = "SPEC-001" ]
  [ "$(printf '%s' "$last" | jq -r '.disposition')" = "archive" ]
  [ "$(printf '%s' "$last" | jq -r '.drained')" = "false" ]
  [ -n "$(printf '%s' "$last" | jq -r '.ts')" ]
}

# --- 6: only merged rows with folders are swept ------------------------------

@test "6: a folder without a merged ledger row is not archived" {
  # SPEC-001: merged row + folder (gets archived). SPEC-002: folder only, no
  # ledger row (the sweep is row-driven, so it stays active).
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001 --seed-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archived 1 merged SPEC(s): SPEC-001"* ]]

  [ -f "$REPO/$SPECS/archived/SPEC-001/SPEC.md" ]
  # SPEC-002 untouched: still active, never archived.
  [ -f "$REPO/$SPECS/SPEC-002/SPEC.md" ]
  [ ! -e "$REPO/$SPECS/archived/SPEC-002" ]
}

# --- 7: multiple merged folders in one sweep ---------------------------------

@test "7: two merged folders are archived together with a combined summary" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-merged-folder SPEC-001 --seed-merged-folder SPEC-002)"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Archived 2 merged SPEC(s): SPEC-001, SPEC-002"* ]]
  [ -f "$REPO/$SPECS/archived/SPEC-001/SPEC.md" ]
  [ -f "$REPO/$SPECS/archived/SPEC-002/SPEC.md" ]
}

# --- 8: never clobber an existing archive target -----------------------------

@test "8: an existing archived folder for the same id blocks the move and warns" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-merged-folder SPEC-001)"
  # Plant a pre-existing archived folder for the same id.
  mkdir -p "$REPO/$SPECS/archived/SPEC-001"
  printf 'prior archive\n' > "$REPO/$SPECS/archived/SPEC-001/SPEC.md"

  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Archived"* ]]
  [[ "$output" == *"already has an archived folder"* ]]

  # Active folder left in place; the prior archive is not overwritten.
  [ -f "$REPO/$SPECS/SPEC-001/SPEC.md" ]
  [ "$(cat "$REPO/$SPECS/archived/SPEC-001/SPEC.md")" = "prior archive" ]
}

# --- 9: no ledger -> clean no-op ---------------------------------------------

@test "9: a repo with no merged rows produces no output and exits 0" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  run _archive "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
