#!/usr/bin/env bats
# UAT-008: no writes occur outside .gaia/local/forensics/ and .gaia/local/telemetry/
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

setup() {
  # The temp repos below run `git commit`. CI runners have no ambient git
  # identity (`user.name`/`user.email`) and cannot derive one, so the commit
  # fails with an empty-ident error. Provide a deterministic identity via the
  # environment so the commit succeeds regardless of the runner's git config.
  export GIT_AUTHOR_NAME="Forensics Test" GIT_AUTHOR_EMAIL="forensics-test@example.com"
  export GIT_COMMITTER_NAME="Forensics Test" GIT_COMMITTER_EMAIL="forensics-test@example.com"
}

# ---------------------------------------------------------------------------
# Write-surface allowlist: shell harness that re-implements the runbook's
# write-surface constraint.
#
# Each test snapshots the set of files outside the two allowed write roots
# (via list_write_surface) before the surrogate runs, runs the surrogate,
# then diffs the after-set against the before-snapshot with comm to find
# writes outside the allowlist. Detection is by set difference, independent
# of mtime.
#
# The runbook_surrogate function:
#   1. Creates the two allowed directories (forensics/ nested one level under
#      a synthetic tree key, mirroring forensics.md step 7's
#      `bash .gaia/scripts/main-root-lib.sh --tree-key` resolution)
#   2. Writes a fake report to .gaia/local/forensics/<tree_key>/
#   3. Optionally writes to .gaia/local/telemetry/ (allowed)
#   4. Returns; does NOT write to any other path
# ---------------------------------------------------------------------------

# Synthetic stand-in for `bash .gaia/scripts/main-root-lib.sh --tree-key`'s
# stdout (16 lowercase hex characters); this surrogate never invokes the real
# resolver, same as the fixed synthetic $timestamp below.
TREE_KEY_FIXTURE="deadbeefcafe1234"

runbook_surrogate() {
  local work_directory="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  mkdir -p "$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE"
  mkdir -p "$work_directory/.gaia/local/telemetry"

  # Write report to allowed path (the only write the runbook may do)
  local report_path="$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  # Optionally write to telemetry (also allowed)
  printf 'forensics_invoked\n' > "$work_directory/.gaia/local/telemetry/emit.log"
}

# ---------------------------------------------------------------------------
# Illegal write surrogate; simulates a buggy runbook that writes outside
# the allowlist; used to confirm the assertion logic catches violations.
# ---------------------------------------------------------------------------

illegal_write_surrogate() {
  local work_directory="$1"
  # Write to an explicitly forbidden path
  printf 'leaked\n' > "$work_directory/.claude/ILLEGAL_WRITE"
}

# ---------------------------------------------------------------------------
# Helper: list regular files under $work_directory that are NOT in the two allowed
# write roots, sorted for a stable set comparison. Snapshot this before and
# after a surrogate run to detect writes by set difference.
# ---------------------------------------------------------------------------

list_write_surface() {
  local work_directory="$1"

  find "$work_directory" -type f \
    ! -path "$work_directory/.gaia/local/forensics/*" \
    ! -path "$work_directory/.gaia/local/telemetry/*" \
    2>/dev/null | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Helper: given a before-snapshot ($before, a file holding list_write_surface
# output) and the work_directory, return files created outside the allowlist since the
# snapshot. Detection is by set difference (comm -13), independent of mtime
# granularity: a write landing in the same clock second as the snapshot is
# still caught.
# ---------------------------------------------------------------------------

find_write_violations() {
  local work_directory="$1"
  local before="$2"

  list_write_surface "$work_directory" | LC_ALL=C comm -13 "$before" -
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-008: runbook surrogate writes only to allowed paths" {
  local work_directory
  work_directory="$(mktemp -d)"

  # Initialize a minimal git repo so the surrogate can operate
  git -C "$work_directory" init -q
  mkdir -p "$work_directory/app" "$work_directory/wiki" "$work_directory/.claude"
  printf 'placeholder\n' > "$work_directory/app/placeholder.ts"
  printf 'placeholder\n' > "$work_directory/wiki/index.md"
  git -C "$work_directory" add .
  git -C "$work_directory" commit -q -m "initial"

  # Snapshot the write surface before the surrogate runs
  local before
  before="$(mktemp)"
  list_write_surface "$work_directory" > "$before"

  # Run the allowed surrogate
  runbook_surrogate "$work_directory" "init"

  # Find any writes outside the allowlist
  local violations
  violations="$(find_write_violations "$work_directory" "$before")"

  rm -f "$before"
  rm -rf "$work_directory"

  [[ -z "$violations" ]]
}

@test "UAT-008: writes to allowed .gaia/local/forensics/ path are detected as expected" {
  local work_directory
  work_directory="$(mktemp -d)"
  git -C "$work_directory" init -q
  mkdir -p "$work_directory/.claude"

  local before
  before="$(mktemp)"
  list_write_surface "$work_directory" > "$before"

  # Write to the allowed path
  mkdir -p "$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE"
  printf 'report\n' > "$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-init.md"

  # Find violations; should be empty because the write is in the allowlist
  local violations
  violations="$(find_write_violations "$work_directory" "$before")"

  rm -f "$before"
  rm -rf "$work_directory"

  [[ -z "$violations" ]]
}

@test "UAT-008: illegal write outside allowlist IS detected as a violation" {
  local work_directory
  work_directory="$(mktemp -d)"
  git -C "$work_directory" init -q
  mkdir -p "$work_directory/.claude"

  local before
  before="$(mktemp)"
  list_write_surface "$work_directory" > "$before"

  # Simulate an illegal write (outside the allowlist)
  illegal_write_surrogate "$work_directory"

  local violations
  violations="$(find_write_violations "$work_directory" "$before")"

  rm -f "$before"
  rm -rf "$work_directory"

  # Violations must be non-empty (the test validates the detection logic)
  [[ -n "$violations" ]]
}

@test "UAT-008: writes to .gaia/local/telemetry/ are in the allowlist" {
  local work_directory
  work_directory="$(mktemp -d)"
  git -C "$work_directory" init -q

  local before
  before="$(mktemp)"
  list_write_surface "$work_directory" > "$before"

  mkdir -p "$work_directory/.gaia/local/telemetry"
  printf 'telemetry\n' > "$work_directory/.gaia/local/telemetry/emit.log"

  local violations
  violations="$(find_write_violations "$work_directory" "$before")"

  rm -f "$before"
  rm -rf "$work_directory"

  [[ -z "$violations" ]]
}

@test "UAT-008: app/ and wiki/ and .claude/ directories show no writes after surrogate run" {
  local work_directory
  work_directory="$(mktemp -d)"
  git -C "$work_directory" init -q
  mkdir -p "$work_directory/app" "$work_directory/wiki" "$work_directory/.claude"
  printf 'original\n' > "$work_directory/app/index.ts"
  printf 'original\n' > "$work_directory/wiki/index.md"
  printf 'original\n' > "$work_directory/.claude/settings.json"
  git -C "$work_directory" add .
  git -C "$work_directory" commit -q -m "initial"

  local before
  before="$(mktemp)"
  list_write_surface "$work_directory" > "$before"

  # Run the allowed surrogate (should not touch app/, wiki/, .claude/)
  runbook_surrogate "$work_directory" "init"

  local violations
  violations="$(find_write_violations "$work_directory" "$before")"

  rm -f "$before"
  rm -rf "$work_directory"

  [[ -z "$violations" ]]
}
