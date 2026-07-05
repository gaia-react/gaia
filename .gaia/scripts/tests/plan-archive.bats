#!/usr/bin/env bats
# Tests for `.gaia/scripts/plan-archive.sh` (FC-1, plan-archival-colocation).
#
# Each test runs the script inside an isolated `git init`'d temp sandbox so
# its `git rev-parse --show-toplevel` resolves to the fixture root (not the
# GAIA repo root) and every prune/mv touches only throwaway fixtures.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../plan-archive.sh"
  [ -x "$SCRIPT" ] || skip "plan-archive.sh not executable"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"

  # Canonicalize via `pwd -P`: macOS resolves /tmp -> /private/tmp inside
  # `git rev-parse`, and the script derives its repo root the same way.
  # Absolute-path test arguments must match that resolved form byte-for-byte.
  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  # The spec-less arm shells out to cost-consolidate.sh at this fixed
  # repo-relative path; mirror it inside the sandbox so that call resolves
  # exactly like it does in a real checkout instead of silently no-op'ing.
  # The PLAN-NNN completion stamp likewise shells out to plan-ledger-update.sh,
  # which sources with-ledger-lock.sh from its own dir; both are copied here
  # so a PLAN-<digits> slug's stamp resolves instead of silently failing.
  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/cost-consolidate.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/cost-consolidate.sh"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/plan-ledger-update.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/with-ledger-lock.sh"
}

# Run the script with cwd inside the sandbox. Args pass through.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# seed_plan <rel_dir>: creates a plan folder (relative to $SANDBOX) with the
# canonical fixture set: SUMMARY.md, cost.md, KICKOFF.md, RUNNING, .work/x.
seed_plan() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir/.work"
  echo "summary" > "$dir/SUMMARY.md"
  echo "tokens" > "$dir/cost.md"
  echo "kickoff" > "$dir/KICKOFF.md"
  : > "$dir/RUNNING"
  echo "scratch" > "$dir/.work/x"
}

# assert_pruned_only <abs_dir>: the dir exists and contains exactly
# SUMMARY.md + cost.md (nothing else, including dotfiles).
assert_pruned_only() {
  local dir="$1" count
  [ -d "$dir" ]
  [ -f "$dir/SUMMARY.md" ]
  [ -f "$dir/cost.md" ]
  count="$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
}

# seed_plans_ledger <plan-row-json>: writes a one-row plans ledger at the
# sandbox's canonical .gaia/local/plans/ledger.json path.
seed_plans_ledger() {
  local row_json="$1"
  mkdir -p "$SANDBOX/.gaia/local/plans"
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<EOF
{
  "version": 1,
  "plans": [
    $row_json
  ]
}
EOF
}

# plan_row_field <field>: reads a field off the PLAN-005 row in the sandbox's
# plans ledger ("null" if absent).
plan_row_field() {
  local field="$1"
  jq -r --arg id "PLAN-005" --arg f "$field" \
    '.plans[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/.gaia/local/plans/ledger.json"
}

# --- 1. Spec-less prune + move ----------------------------------------------

@test "spec-less plan: pruned then moved to plans/archived/<slug>" {
  seed_plan ".gaia/local/plans/foo"
  run run_in_sandbox ".gaia/local/plans/foo"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/foo" ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/foo"
  [[ "$output" == *"Archived plan: moved .gaia/local/plans/foo -> .gaia/local/plans/archived/foo"* ]]
}

# --- 2. Colocated prune in place --------------------------------------------

@test "colocated plan: pruned in place, not moved" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/specs/SPEC-005/plan"
  [[ "$output" == *"Pruned colocated plan in place: .gaia/local/specs/SPEC-005/plan"* ]]
}

# --- 3. Colocated with plan-2 suffix ----------------------------------------

@test "colocated plan-2 revision: pruned in place, not moved" {
  seed_plan ".gaia/local/specs/SPEC-005/plan-2"
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/specs/SPEC-005/plan-2"
  [[ "$output" == *"Pruned colocated plan in place: .gaia/local/specs/SPEC-005/plan-2"* ]]
}

# --- 4. Missing SUMMARY.md / cost.md tolerated ----------------------------

@test "plan with neither SUMMARY.md nor cost.md prunes to empty" {
  mkdir -p "$SANDBOX/.gaia/local/plans/bare/.work"
  echo "kickoff" > "$SANDBOX/.gaia/local/plans/bare/KICKOFF.md"
  : > "$SANDBOX/.gaia/local/plans/bare/RUNNING"
  echo "scratch" > "$SANDBOX/.gaia/local/plans/bare/.work/x"
  run run_in_sandbox ".gaia/local/plans/bare"
  [ "$status" -eq 0 ]
  archived="$SANDBOX/.gaia/local/plans/archived/bare"
  [ -d "$archived" ]
  count="$(find "$archived" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ]
}

# --- 5. Refuse archived/ (no double-archive) --------------------------------

@test "refuses .gaia/local/plans/archived/<slug> (no double-archive)" {
  seed_plan ".gaia/local/plans/archived/foo"
  run run_in_sandbox ".gaia/local/plans/archived/foo"
  [ "$status" -eq 0 ]
  # Untouched: every seeded entry still present, nothing pruned or moved.
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/RUNNING" ]
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/.work/x" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 6. Refuse out-of-shape relative path -----------------------------------

@test "refuses a relative path outside .gaia/local" {
  mkdir -p "$SANDBOX/some/other/dir"
  : > "$SANDBOX/some/other/dir/file"
  run run_in_sandbox "some/other/dir"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/some/other/dir/file" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 7. No-clobber -----------------------------------------------------------

@test "no-clobber: pre-existing archive target leaves source pruned in place" {
  seed_plan ".gaia/local/plans/foo"
  mkdir -p "$SANDBOX/.gaia/local/plans/archived/foo"
  echo "old" > "$SANDBOX/.gaia/local/plans/archived/foo/SUMMARY.md"
  run run_in_sandbox ".gaia/local/plans/foo"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/foo"
  # The pre-existing archive target is untouched.
  [ "$(cat "$SANDBOX/.gaia/local/plans/archived/foo/SUMMARY.md")" = "old" ]
  [[ "$output" == *"already exists"* ]]
}

# --- 8. Non-existent input ----------------------------------------------------

@test "non-existent plan_dir: exit 0, stderr note, no side effects" {
  run run_in_sandbox ".gaia/local/plans/ghost"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/archived" ]
  [[ "$output" == *"does not exist"* ]]
}

# --- 9. Absolute-under-repo normalizes ---------------------------------------

@test "absolute path under repo root normalizes to the same end-state" {
  seed_plan ".gaia/local/plans/foo"
  run run_in_sandbox "$SANDBOX/.gaia/local/plans/foo"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/foo" ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/foo"
  [[ "$output" == *"Archived plan: moved .gaia/local/plans/foo -> .gaia/local/plans/archived/foo"* ]]
}

# --- 10. Absolute-outside-repo refuses ----------------------------------------

@test "absolute path outside repo root refuses" {
  OUTSIDE_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/outside.XXXXXX")"
  OUTSIDE="$(cd "$OUTSIDE_RAW" && pwd -P)"
  mkdir -p "$OUTSIDE/plan"
  : > "$OUTSIDE/plan/SUMMARY.md"
  run run_in_sandbox "$OUTSIDE/plan"
  [ "$status" -eq 0 ]
  [ -f "$OUTSIDE/plan/SUMMARY.md" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 11. Refuse "." slug (would resolve to plans/ itself, mass-deleting siblings) --

@test "refuses .gaia/local/plans/. (mass-delete guard)" {
  seed_plan ".gaia/local/plans/foo"
  mkdir -p "$SANDBOX/.gaia/local/plans/bar"
  : > "$SANDBOX/.gaia/local/plans/bar/marker"
  run run_in_sandbox ".gaia/local/plans/."
  [ "$status" -eq 0 ]
  # Untouched: sibling plan folders inside plans/ survive.
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/foo/.work/x" ]
  [ -f "$SANDBOX/.gaia/local/plans/bar/marker" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 12. Refuse ".." slug (would resolve to .gaia/local, mass-deleting plans+specs) -

@test "refuses .gaia/local/plans/.. (mass-delete guard)" {
  seed_plan ".gaia/local/plans/foo"
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  run run_in_sandbox ".gaia/local/plans/.."
  [ "$status" -eq 0 ]
  # Untouched: sibling trees under .gaia/local survive.
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/plan/KICKOFF.md" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 13. Refuse doubled trailing slash (empty slug, same mass-delete guard) --------

@test "refuses .gaia/local/plans// (doubled trailing slash / empty slug)" {
  seed_plan ".gaia/local/plans/foo"
  mkdir -p "$SANDBOX/.gaia/local/plans/bar"
  : > "$SANDBOX/.gaia/local/plans/bar/marker"
  run run_in_sandbox ".gaia/local/plans//"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/bar/marker" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 14. Well-formed slug with a single trailing slash still archives --------------

@test "trailing slash on a well-formed slug still archives correctly" {
  seed_plan ".gaia/local/plans/foo"
  run run_in_sandbox ".gaia/local/plans/foo/"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/foo" ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/foo"
  [[ "$output" == *"Archived plan: moved .gaia/local/plans/foo -> .gaia/local/plans/archived/foo"* ]]
}

# --- 15. Refuse specs-arm path escape via ".." spec segment ------------------------

@test "refuses .gaia/local/specs/../plan (spec-part path escape)" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  mkdir -p "$SANDBOX/.gaia/local/plan"
  : > "$SANDBOX/.gaia/local/plan/escaped-marker"
  run run_in_sandbox ".gaia/local/specs/../plan"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/plan/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plan/escaped-marker" ]
  [[ "$output" == *"refusing"* ]]
}

# --- 16. Spec-less archive gains a grand total, no SPEC section ------------------

@test "spec-less plan: archived cost.md gains a Total with no SPEC section" {
  local dir="$SANDBOX/.gaia/local/plans/bar"
  mkdir -p "$dir"
  echo "summary" > "$dir/SUMMARY.md"
  cat > "$dir/cost.md" <<'EOF'
# Cost: PLAN-009 / bar-slug

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 10 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 2 |
| **Total** | 14 |

**Est. cost (USD):** $0.10

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 20 |
| Cache write | 2 |
| Cache read | 2 |
| Output | 4 |
| **Total** | 28 |

**Est. cost (USD):** $0.20
EOF

  run run_in_sandbox ".gaia/local/plans/bar"
  [ "$status" -eq 0 ]
  archived="$SANDBOX/.gaia/local/plans/archived/bar/cost.md"
  [ -f "$archived" ]
  grep -qx '## Total' "$archived"
  grep -qF '**Est. cost (USD):** $0.30' "$archived"
  ! grep -qx '## SPEC' "$archived"
}

# --- 17. PLAN-NNN slug: archiving stamps the plans-ledger row completed (U3) -------

@test "PLAN-NNN slug: archiving stamps plans-ledger row to completed with completed_at" {
  seed_plan ".gaia/local/plans/PLAN-005"
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-005"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/PLAN-005"
  [ "$(plan_row_field status)" = "completed" ]
  [ "$(plan_row_field completed_at)" != "null" ]
  [ -n "$(plan_row_field completed_at)" ]
}

# --- 18. Legacy slug: archiving does not attempt a ledger stamp --------------------

@test "legacy slug (not PLAN-NNN): archiving does not attempt a ledger stamp" {
  seed_plan ".gaia/local/plans/cache-consolidation"
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/cache-consolidation"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/cache-consolidation"
  # Unrelated PLAN-005 row is untouched, proving no stray stamp fired.
  [ "$(plan_row_field status)" = "allocated" ]
}

# --- 19. Spec-colocated plan: archiving does not stamp any plans-ledger row --------

@test "spec-colocated plan: archiving does not stamp any plans-ledger row" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  ledger_before="$(cat "$SANDBOX/.gaia/local/plans/ledger.json")"
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/specs/SPEC-005/plan"
  [ "$(cat "$SANDBOX/.gaia/local/plans/ledger.json")" = "$ledger_before" ]
}

# --- 20. Best-effort: chokepoint failure (no matching row) never blocks archival ---

@test "PLAN-NNN with no matching ledger row: chokepoint fails but archive still exits 0" {
  seed_plan ".gaia/local/plans/PLAN-999"
  seed_plans_ledger '{"id":"PLAN-001","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-999"
  [ "$status" -eq 0 ]
  assert_pruned_only "$SANDBOX/.gaia/local/plans/archived/PLAN-999"
}
