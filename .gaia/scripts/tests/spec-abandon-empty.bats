#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/spec-abandon-empty.sh`: the guarded
# sweep that retires a never-authored SPEC draft to the terminal `abandoned`
# ledger status. Every test runs the real script against an isolated fixture
# ledger, never the GAIA repo's own `.gaia/local/specs/ledger.json`.
#
# Assertion style note: no bare `[[ ... ]]` for substring/prefix checks (see
# .claude/rules/bats-assertions.md) -- a failing one does not fail the test on
# macOS's default bash 3.2. This suite uses only `[ ... ]`, `grep`, and an
# explicit `return 1`.

setup() {
  LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.specify/extensions/gaia/lib" && pwd)"
  REPO_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.gaia/scripts" && pwd)"
  SCRIPT="$LIB_DIR/spec-abandon-empty.sh"
  LEDGER_UPDATE="$LIB_DIR/ledger-update.sh"
  [ -x "$SCRIPT" ] || skip "spec-abandon-empty.sh not executable"

  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  mkdir -p "$SANDBOX/.gaia/local/specs" "$SANDBOX/.gaia/local/cache" "$SANDBOX/.gaia/scripts"
  # The scripts under test now resolve the main checkout via
  # ledger-path-lib.sh/main-root-lib.sh, which requires a real git repo
  # (fail-closed, no operand fallback); a plain mktemp -d is not one.
  git -C "$SANDBOX" init --quiet --initial-branch=main
  cp "$REPO_SCRIPTS/ledger-path-lib.sh" "$REPO_SCRIPTS/main-root-lib.sh" "$SANDBOX/.gaia/scripts/"
  chmod +x "$SANDBOX/.gaia/scripts/ledger-path-lib.sh" "$SANDBOX/.gaia/scripts/main-root-lib.sh"
  LEDGER="$SANDBOX/.gaia/local/specs/ledger.json"
}

# old_ts / new_ts: portable ISO8601 timestamps well outside / inside the
# guard age, computed with jq (never `date -d`/`date -j`, matching the
# project's cross-platform epoch rule).
old_ts() {
  jq -rn '(now - 90000) | strftime("%Y-%m-%dT%H:%M:%SZ")' # ~25h ago
}

new_ts() {
  jq -rn '(now - 60) | strftime("%Y-%m-%dT%H:%M:%SZ")' # ~1m ago
}

# seed_ledger <json-specs-array>: writes the ledger with the given specs array.
seed_ledger() {
  printf '{"version": 1, "specs": %s}\n' "$1" > "$LEDGER"
}

status_of() {
  jq -r --arg id "$1" '.specs[] | select(.id == $id) | .status' "$LEDGER"
}

# --- 1. Flips a fully empty, aged draft --------------------------------------

@test "flips an empty draft older than the guard age to abandoned" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-001", allocated_at: $ts, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-001)" = "abandoned" ]
  grep -qF -- "Abandoned 1 never-authored draft(s): SPEC-001" <<<"$output"
}

@test "stamps abandoned_at on the flipped row" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-001", allocated_at: $ts, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  abandoned_at="$(jq -r '.specs[0].abandoned_at // empty' "$LEDGER")"
  [ -n "$abandoned_at" ]
}

# --- 2. Leaves a draft with a draft cache untouched (any age) ----------------

@test "leaves a draft with a draft-<id>.md cache untouched" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-002", allocated_at: $ts, status: "draft"}]')"
  echo "in progress" > "$SANDBOX/.gaia/local/cache/draft-SPEC-002.md"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-002)" = "draft" ]
  [ -z "$output" ]
}

# --- 3. Leaves a draft with a SPEC.md untouched ------------------------------

@test "leaves a draft with a SPEC.md untouched" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-003", allocated_at: $ts, status: "draft"}]')"
  mkdir -p "$SANDBOX/.gaia/local/specs/SPEC-003"
  echo "# SPEC" > "$SANDBOX/.gaia/local/specs/SPEC-003/SPEC.md"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-003)" = "draft" ]
  [ -z "$output" ]
}

# --- 4. Leaves a draft with a gate-1 snapshot untouched ----------------------

@test "leaves a draft with a gate1-<id>.json snapshot untouched" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-004", allocated_at: $ts, status: "draft"}]')"
  echo '{}' > "$SANDBOX/.gaia/local/cache/gate1-SPEC-004.json"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-004)" = "draft" ]
  [ -z "$output" ]
}

# --- 5. Leaves an empty draft younger than the guard age untouched ----------

@test "leaves an empty draft younger than the guard age untouched" {
  seed_ledger "$(jq -nc --arg ts "$(new_ts)" '[{id: "SPEC-005", allocated_at: $ts, status: "draft"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-005)" = "draft" ]
  [ -z "$output" ]
}

# --- 6. Leaves a non-draft row untouched -------------------------------------

@test "leaves a specified (non-draft) row untouched even if empty and aged" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-006", allocated_at: $ts, status: "specified"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-006)" = "specified" ]
  [ -z "$output" ]
}

# --- 7. Unparseable allocated_at is treated as NOT aged ----------------------

@test "treats an unparseable allocated_at as not aged (never guesses)" {
  seed_ledger '[{"id": "SPEC-007", "allocated_at": "not-a-date", "status": "draft"}]'
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-007)" = "draft" ]
  [ -z "$output" ]
}

# --- 8. Missing allocated_at is treated as NOT aged --------------------------

@test "treats a missing allocated_at as not aged (never guesses)" {
  seed_ledger '[{"id": "SPEC-008", "status": "draft"}]'
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-008)" = "draft" ]
  [ -z "$output" ]
}

# --- 9. Multiple eligible drafts flip in one pass ----------------------------

@test "flips multiple eligible drafts in one pass, leaves ineligible ones" {
  seed_ledger "$(jq -nc --arg old "$(old_ts)" --arg new "$(new_ts)" '[
    {id: "SPEC-010", allocated_at: $old, status: "draft"},
    {id: "SPEC-011", allocated_at: $old, status: "draft"},
    {id: "SPEC-012", allocated_at: $new, status: "draft"}
  ]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-010)" = "abandoned" ]
  [ "$(status_of SPEC-011)" = "abandoned" ]
  [ "$(status_of SPEC-012)" = "draft" ]
  grep -qF -- "SPEC-010" <<<"$output"
  grep -qF -- "SPEC-011" <<<"$output"
}

# --- 10. No ledger: exit 0, silent, no side effects --------------------------

@test "no ledger file: exit 0, silent" {
  rm -f "$LEDGER"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
}

# --- 11. No draft rows at all: exit 0, silent --------------------------------

@test "ledger with no draft rows: exit 0, silent" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-013", allocated_at: $ts, status: "merged"}]')"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 12. Missing repo_root argument: exit 0, usage to stderr -----------------

@test "missing repo_root argument: exit 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- 13. Flip flows through the real ledger-update.sh chokepoint ------------

@test "the flip is rejected if ledger-update.sh's status guard would reject it" {
  # Sanity: ledger-update.sh itself accepts "abandoned" directly (the
  # chokepoint this sweep depends on), confirming the sweep and the guard
  # agree on the vocabulary rather than each hardcoding it separately.
  seed_ledger '[{"id": "SPEC-014", "status": "draft"}]'
  run bash "$LEDGER_UPDATE" "$SANDBOX" SPEC-014 '{"status":"abandoned"}'
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-014)" = "abandoned" ]
}

# --- 14. Orphan lock is removed when a ghost row is abandoned ---------------

@test "removes the orphan .lock file when a ghost draft is abandoned" {
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-015", allocated_at: $ts, status: "draft"}]')"
  echo '{"spec_id":"SPEC-015"}' > "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-015)" = "abandoned" ]
  [ ! -e "$SANDBOX/.gaia/local/cache/spec-session-SPEC-015.lock" ]
}

# --- 15. A lone lock never rescues a ghost (negative guard) -----------------

@test "a lone .lock file does not rescue an otherwise-empty ghost draft from abandonment" {
  # A dead session's lock is precisely the ghost shape; the emptiness guard
  # never grows a fourth (`.lock`) check, so this row is abandoned exactly
  # like a lock-free ghost would be.
  seed_ledger "$(jq -nc --arg ts "$(old_ts)" '[{id: "SPEC-016", allocated_at: $ts, status: "draft"}]')"
  echo '{"spec_id":"SPEC-016"}' > "$SANDBOX/.gaia/local/cache/spec-session-SPEC-016.lock"
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$(status_of SPEC-016)" = "abandoned" ]
}
