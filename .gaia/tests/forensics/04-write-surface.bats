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
#   1. Creates the two allowed directories
#   2. Writes a fake report to .gaia/local/forensics/
#   3. Optionally writes to .gaia/local/telemetry/ (allowed)
#   4. Returns; does NOT write to any other path
# ---------------------------------------------------------------------------

runbook_surrogate() {
  local workdir="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  # Create allowed directories
  mkdir -p "$workdir/.gaia/local/forensics"
  mkdir -p "$workdir/.gaia/local/telemetry"

  # Write report to allowed path (the only write the runbook may do)
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  # Optionally write to telemetry (also allowed)
  printf 'forensics_invoked\n' > "$workdir/.gaia/local/telemetry/emit.log"
}

# ---------------------------------------------------------------------------
# Illegal write surrogate; simulates a buggy runbook that writes outside
# the allowlist; used to confirm the assertion logic catches violations.
# ---------------------------------------------------------------------------

illegal_write_surrogate() {
  local workdir="$1"
  # Write to an explicitly forbidden path
  printf 'leaked\n' > "$workdir/.claude/ILLEGAL_WRITE"
}

# ---------------------------------------------------------------------------
# Helper: list regular files under $workdir that are NOT in the two allowed
# write roots, sorted for a stable set comparison. Snapshot this before and
# after a surrogate run to detect writes by set difference.
# ---------------------------------------------------------------------------

list_write_surface() {
  local workdir="$1"

  find "$workdir" -type f \
    ! -path "$workdir/.gaia/local/forensics/*" \
    ! -path "$workdir/.gaia/local/telemetry/*" \
    2>/dev/null | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Helper: given a before-snapshot ($before, a file holding list_write_surface
# output) and the workdir, return files created outside the allowlist since the
# snapshot. Detection is by set difference (comm -13), independent of mtime
# granularity: a write landing in the same clock second as the snapshot is
# still caught.
# ---------------------------------------------------------------------------

find_write_violations() {
  local workdir="$1"
  local before="$2"

  list_write_surface "$workdir" | LC_ALL=C comm -13 "$before" -
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-008: runbook surrogate writes only to allowed paths" {
  local workdir
  workdir="$(mktemp -d)"

  # Initialize a minimal git repo so the surrogate can operate
  git -C "$workdir" init -q
  mkdir -p "$workdir/app" "$workdir/wiki" "$workdir/.claude"
  printf 'placeholder\n' > "$workdir/app/placeholder.ts"
  printf 'placeholder\n' > "$workdir/wiki/index.md"
  git -C "$workdir" add .
  git -C "$workdir" commit -q -m "initial"

  # Snapshot the write surface before the surrogate runs
  local before
  before="$(mktemp)"
  list_write_surface "$workdir" > "$before"

  # Run the allowed surrogate
  runbook_surrogate "$workdir" "init"

  # Find any writes outside the allowlist
  local violations
  violations="$(find_write_violations "$workdir" "$before")"

  rm -f "$before"
  rm -rf "$workdir"

  [[ -z "$violations" ]]
}

@test "UAT-008: writes to allowed .gaia/local/forensics/ path are detected as expected" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q
  mkdir -p "$workdir/.claude"

  local before
  before="$(mktemp)"
  list_write_surface "$workdir" > "$before"

  # Write to the allowed path
  mkdir -p "$workdir/.gaia/local/forensics"
  printf 'report\n' > "$workdir/.gaia/local/forensics/20260508T143022Z-init.md"

  # Find violations; should be empty because the write is in the allowlist
  local violations
  violations="$(find_write_violations "$workdir" "$before")"

  rm -f "$before"
  rm -rf "$workdir"

  [[ -z "$violations" ]]
}

@test "UAT-008: illegal write outside allowlist IS detected as a violation" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q
  mkdir -p "$workdir/.claude"

  local before
  before="$(mktemp)"
  list_write_surface "$workdir" > "$before"

  # Simulate an illegal write (outside the allowlist)
  illegal_write_surrogate "$workdir"

  local violations
  violations="$(find_write_violations "$workdir" "$before")"

  rm -f "$before"
  rm -rf "$workdir"

  # Violations must be non-empty (the test validates the detection logic)
  [[ -n "$violations" ]]
}

@test "UAT-008: writes to .gaia/local/telemetry/ are in the allowlist" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q

  local before
  before="$(mktemp)"
  list_write_surface "$workdir" > "$before"

  mkdir -p "$workdir/.gaia/local/telemetry"
  printf 'telemetry\n' > "$workdir/.gaia/local/telemetry/emit.log"

  local violations
  violations="$(find_write_violations "$workdir" "$before")"

  rm -f "$before"
  rm -rf "$workdir"

  [[ -z "$violations" ]]
}

@test "UAT-008: app/ and wiki/ and .claude/ directories show no writes after surrogate run" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q
  mkdir -p "$workdir/app" "$workdir/wiki" "$workdir/.claude"
  printf 'original\n' > "$workdir/app/index.ts"
  printf 'original\n' > "$workdir/wiki/index.md"
  printf 'original\n' > "$workdir/.claude/settings.json"
  git -C "$workdir" add .
  git -C "$workdir" commit -q -m "initial"

  local before
  before="$(mktemp)"
  list_write_surface "$workdir" > "$before"

  # Run the allowed surrogate (should not touch app/, wiki/, .claude/)
  runbook_surrogate "$workdir" "init"

  local violations
  violations="$(find_write_violations "$workdir" "$before")"

  rm -f "$before"
  rm -rf "$workdir"

  [[ -z "$violations" ]]
}
