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

  # Canonicalize via `pwd -P`: macOS resolves /tmp -> /private/tmp inside
  # `git rev-parse`, and the script derives its repo root the same way.
  # Absolute-path test arguments must match that resolved form byte-for-byte.
  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet
}

# Run the script with cwd inside the sandbox. Args pass through.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# seed_plan <rel_dir>: creates a plan folder (relative to $SANDBOX) with the
# canonical fixture set: SUMMARY.md, tokens.md, KICKOFF.md, RUNNING, .work/x.
seed_plan() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir/.work"
  echo "summary" > "$dir/SUMMARY.md"
  echo "tokens" > "$dir/tokens.md"
  echo "kickoff" > "$dir/KICKOFF.md"
  : > "$dir/RUNNING"
  echo "scratch" > "$dir/.work/x"
}

# assert_pruned_only <abs_dir>: the dir exists and contains exactly
# SUMMARY.md + tokens.md (nothing else, including dotfiles).
assert_pruned_only() {
  local dir="$1" count
  [ -d "$dir" ]
  [ -f "$dir/SUMMARY.md" ]
  [ -f "$dir/tokens.md" ]
  count="$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
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

# --- 4. Missing SUMMARY.md / tokens.md tolerated ----------------------------

@test "plan with neither SUMMARY.md nor tokens.md prunes to empty" {
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
