#!/usr/bin/env bats
# Folder-layout tests for the SPEC artifact migration + path machinery
# (Contract C7). A SPEC artifact lives at .gaia/local/specs/<id>/SPEC.md;
# the migration script spec-folderize.sh moves any legacy flat
# .gaia/local/specs/SPEC-NNN.md (and archived/SPEC-NNN.md) into that shape.
#
# Each test spins up its own tmp git repo via helpers/tmp-spec-repo.sh and
# tears it down — hermetic, no reliance on the real project ledger. The
# teardown uses the explicit-if form (the && idiom is a bats teardown
# footgun: a falsy first clause makes teardown itself "fail").

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ALLOC=".specify/extensions/gaia/lib/spec-allocator.sh"
  FOLDERIZE=".specify/extensions/gaia/lib/spec-folderize.sh"
  RENUMBER=".specify/extensions/gaia/lib/spec-renumber.sh"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Deterministic snapshot of the specs tree: relative paths + per-file sha,
# sorted. Used to assert "nothing changed" across idempotent / dry-run runs.
_snapshot() {
  local root="$1"
  ( cd "$root/.gaia/local/specs" 2>/dev/null \
      && find . -type f -print0 2>/dev/null \
         | sort -z \
         | xargs -0 shasum 2>/dev/null ) || true
}

# --- 1: folderize happy path -------------------------------------------------

@test "1: folderize migrates flat + archived specs into folders, contents byte-identical" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --seed-flat SPEC-001 --seed-flat SPEC-002 --seed-archived-flat SPEC-000)"
  cd "$REPO"

  c1="$(cat "$REPO/.gaia/local/specs/SPEC-001.md")"
  c2="$(cat "$REPO/.gaia/local/specs/SPEC-002.md")"
  c0="$(cat "$REPO/.gaia/local/specs/archived/SPEC-000.md")"

  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO'"
  [ "$status" -eq 0 ]

  # Foldered shape exists.
  [ -f "$REPO/.gaia/local/specs/SPEC-001/SPEC.md" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-002/SPEC.md" ]
  [ -f "$REPO/.gaia/local/specs/archived/SPEC-000/SPEC.md" ]

  # No flat files remain.
  [ ! -e "$REPO/.gaia/local/specs/SPEC-001.md" ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-002.md" ]
  [ ! -e "$REPO/.gaia/local/specs/archived/SPEC-000.md" ]

  # Contents moved byte-for-byte.
  [ "$(cat "$REPO/.gaia/local/specs/SPEC-001/SPEC.md")" = "$c1" ]
  [ "$(cat "$REPO/.gaia/local/specs/SPEC-002/SPEC.md")" = "$c2" ]
  [ "$(cat "$REPO/.gaia/local/specs/archived/SPEC-000/SPEC.md")" = "$c0" ]
}

# --- 2: idempotent re-run ----------------------------------------------------

@test "2: re-running folderize on an already-foldered tree is a no-op" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-001 --seed-flat SPEC-002)"
  cd "$REPO"

  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO'"
  [ "$status" -eq 0 ]

  before="$(_snapshot "$REPO")"
  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]] || [ -z "$output" ]
  after="$(_snapshot "$REPO")"
  [ "$before" = "$after" ]
}

# --- 3: dry-run --------------------------------------------------------------

@test "3: --dry-run prints the plan and changes nothing" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-001)"
  cd "$REPO"

  before="$(_snapshot "$REPO")"
  run bash -c "bash '$REPO/$FOLDERIZE' --dry-run '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mv "* ]]
  [[ "$output" == *"SPEC-001/SPEC.md"* ]]

  # Tree stays flat — no folder created, flat file untouched.
  [ -f "$REPO/.gaia/local/specs/SPEC-001.md" ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-001/SPEC.md" ]
  after="$(_snapshot "$REPO")"
  [ "$before" = "$after" ]
}

# --- 4: no specs -------------------------------------------------------------

@test "4: no flat specs — exit 0, stderr 'nothing to migrate'" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  cd "$REPO"
  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}

# --- 5: conflict -------------------------------------------------------------

@test "5: flat + foldered for same id — exit 4, both paths in stderr, neither modified" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-003 --seed-folder SPEC-003)"
  cd "$REPO"

  flat_before="$(cat "$REPO/.gaia/local/specs/SPEC-003.md")"
  fold_before="$(cat "$REPO/.gaia/local/specs/SPEC-003/SPEC.md")"

  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO' 2>&1 1>/dev/null"
  [ "$status" -eq 4 ]
  [[ "$output" == *"SPEC-003.md"* ]]
  [[ "$output" == *"SPEC-003/SPEC.md"* ]]

  # Neither file modified.
  [ "$(cat "$REPO/.gaia/local/specs/SPEC-003.md")" = "$flat_before" ]
  [ "$(cat "$REPO/.gaia/local/specs/SPEC-003/SPEC.md")" = "$fold_before" ]
}

# --- 6: tracked vs untracked -------------------------------------------------

@test "6: untracked specs migrate via mv; tracked specs via git mv" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-001 --seed-flat SPEC-002)"
  cd "$REPO"

  # The helper commits all seeded files in its init commit, so both flats
  # start tracked. Untrack SPEC-002 (keep the working file) so the two
  # branches of the tracked-vs-untracked detection are both exercised:
  # SPEC-001 stays tracked, SPEC-002 becomes a typical gitignored adopter spec.
  git -C "$REPO" rm --quiet --cached .gaia/local/specs/SPEC-002.md
  [ -f "$REPO/.gaia/local/specs/SPEC-002.md" ]

  run bash -c "bash '$REPO/$FOLDERIZE' '$REPO'"
  [ "$status" -eq 0 ]

  # Tracked file moved with git mv — git now tracks the new path, not the old.
  git -C "$REPO" ls-files --error-unmatch .gaia/local/specs/SPEC-001/SPEC.md
  run bash -c "git -C '$REPO' ls-files --error-unmatch .gaia/local/specs/SPEC-001.md"
  [ "$status" -ne 0 ]

  # Untracked file simply moved; still untracked at the new path.
  [ -f "$REPO/.gaia/local/specs/SPEC-002/SPEC.md" ]
  run bash -c "git -C '$REPO' ls-files --error-unmatch .gaia/local/specs/SPEC-002/SPEC.md"
  [ "$status" -ne 0 ]
}

# --- 7: allocator over foldered specs ----------------------------------------

@test "7a: highest reads foldered SPEC.md; next does not create a folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-004)"
  cd "$REPO"
  bash "$REPO/$FOLDERIZE" "$REPO" >/dev/null 2>&1

  run bash -c "bash '$REPO/$ALLOC' highest '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-004" ]

  run bash -c "bash '$REPO/$ALLOC' next '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-005" ]
  # `next` only appends a ledger row — it must NOT create the folder.
  [ ! -e "$REPO/.gaia/local/specs/SPEC-005" ]
  [ "$(jq -r '.specs[-1].id' "$REPO/.gaia/specs.json")" = "SPEC-005" ]
}

@test "7b: in_progress ledger-first wins over a foldered fallback artifact" {
  # Ledger has an in-progress row for SPEC-009; a foldered SPEC-013/SPEC.md
  # is also status:in-progress. Ledger order wins per Contract C3.
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-inprogress SPEC-009 --seed-folder SPEC-013)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-009" ]
}

@test "7c: in_progress fallback reads a foldered status:in-progress artifact" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-013)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-013" ]
}

# --- 8: renumber folder ------------------------------------------------------

@test "8a: renumber renames the folder; SPEC.md keeps its name; siblings ride along" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-002)"
  cd "$REPO"
  # A sibling artifact in the same folder must move with the folder.
  echo "report body" > "$REPO/.gaia/local/specs/SPEC-002/REPORT.md"

  run bash -c "bash '$REPO/$RENUMBER' '$REPO' SPEC-002 SPEC-005"
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/.gaia/local/specs/SPEC-002" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-005/SPEC.md" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-005/REPORT.md" ]
  [ "$(cat "$REPO/.gaia/local/specs/SPEC-005/REPORT.md")" = "report body" ]
  # Inner SPEC.md frontmatter id rewritten.
  grep -q '^spec_id: SPEC-005$' "$REPO/.gaia/local/specs/SPEC-005/SPEC.md"
}

@test "8b: renumber collision guard fires when the target folder exists" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-002 --seed-folder SPEC-005)"
  cd "$REPO"
  run bash -c "bash '$REPO/$RENUMBER' '$REPO' SPEC-002 SPEC-005"
  [ "$status" -eq 4 ]
  # Source folder untouched on a refused renumber.
  [ -f "$REPO/.gaia/local/specs/SPEC-002/SPEC.md" ]
}

# --- 9: round-trip -----------------------------------------------------------

@test "9: flat -> folderize -> next -> renumber -> archive round-trip" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-flat SPEC-001 --seed-flat SPEC-002)"
  cd "$REPO"

  # 1. Migrate flat -> foldered.
  bash "$REPO/$FOLDERIZE" "$REPO" >/dev/null 2>&1
  [ -f "$REPO/.gaia/local/specs/SPEC-001/SPEC.md" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-002/SPEC.md" ]

  # 2. next allocates the right id (highest folder is 002 -> next is 003).
  run bash -c "bash '$REPO/$ALLOC' next '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-003" ]

  # 3. renumber a foldered spec.
  run bash -c "bash '$REPO/$RENUMBER' '$REPO' SPEC-002 SPEC-010"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-002" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-010/SPEC.md" ]

  # 4. Simulate the spec-close folder move to archived/<id>/.
  mkdir -p "$REPO/.gaia/local/specs/archived"
  mv "$REPO/.gaia/local/specs/SPEC-010" "$REPO/.gaia/local/specs/archived/SPEC-010"
  [ -f "$REPO/.gaia/local/specs/archived/SPEC-010/SPEC.md" ]
  [ ! -e "$REPO/.gaia/local/specs/SPEC-010" ]

  # 5. highest ignores archived/ on the filesystem scan: only SPEC-001 is an
  #    active foldered artifact, but the ledger still carries SPEC-003 and the
  #    renumbered SPEC-010 row — the allocator's highest is ledger ∪ branches ∪
  #    active folders, never archived/ (mindepth/maxdepth 2 stops at <id>/).
  run bash -c "find '$REPO/.gaia/local/specs' -mindepth 2 -maxdepth 2 -type f -name SPEC.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPEC-001/SPEC.md"* ]]
  [[ "$output" != *"archived/SPEC-010/SPEC.md"* ]]
}

# --- 10: read-only modes take no lock and create no folder -------------------

@test "10: highest / in_progress over foldered specs take no lock, create no folder" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-007)"
  cd "$REPO"

  before="$(_snapshot "$REPO")"
  run bash -c "bash '$REPO/$ALLOC' highest '$REPO'"
  [ "$status" -eq 0 ]
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/.gaia/specs.lock" ]
  [ ! -e "$REPO/.gaia/specs.lock.d" ]
  # No new folder created by a read-only mode.
  after="$(_snapshot "$REPO")"
  [ "$before" = "$after" ]
}
