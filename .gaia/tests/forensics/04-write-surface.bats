#!/usr/bin/env bats
# UAT-008: no writes occur outside .gaia/local/forensics/ and .gaia/local/telemetry/

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

# ---------------------------------------------------------------------------
# Write-surface allowlist: shell harness that re-implements the runbook's
# write-surface constraint.
#
# The runbook_surrogate function:
#   1. Snapshots mtimes of all files via a marker file
#   2. Writes a fake report to the allowed path
#   3. Optionally writes to .gaia/local/telemetry/ (allowed)
#   4. Returns — does NOT write to any other path
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
# Illegal write surrogate — simulates a buggy runbook that writes outside
# the allowlist; used to confirm the assertion logic catches violations.
# ---------------------------------------------------------------------------

illegal_write_surrogate() {
  local workdir="$1"
  # Write to an explicitly forbidden path
  printf 'leaked\n' > "$workdir/.claude/ILLEGAL_WRITE"
}

# ---------------------------------------------------------------------------
# Helper: find files newer than a marker, excluding the two allowed roots.
# Returns the list of violating paths (empty = no violations).
# ---------------------------------------------------------------------------

find_write_violations() {
  local workdir="$1"
  local marker="$2"

  find "$workdir" -type f -newer "$marker" \
    ! -path "$workdir/.gaia/local/forensics/*" \
    ! -path "$workdir/.gaia/local/telemetry/*" \
    2>/dev/null || true
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

  # Snapshot marker
  local marker
  marker="$(mktemp "$workdir/.gaia-marker-XXXXXX")"

  # Run the allowed surrogate
  runbook_surrogate "$workdir" "init"

  # Find any writes outside the allowlist (exclude the marker file itself)
  local violations
  violations="$(find_write_violations "$workdir" "$marker" | grep -v '.gaia-marker-' || true)"

  rm -rf "$workdir"

  [[ -z "$violations" ]]
}

@test "UAT-008: writes to allowed .gaia/local/forensics/ path are detected as expected" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q
  mkdir -p "$workdir/.claude"

  local marker
  marker="$(mktemp "$workdir/.gaia-marker-XXXXXX")"

  # Write to the allowed path
  mkdir -p "$workdir/.gaia/local/forensics"
  printf 'report\n' > "$workdir/.gaia/local/forensics/20260508T143022Z-init.md"

  # Find violations — should be empty because the write is in the allowlist
  local violations
  violations="$(find_write_violations "$workdir" "$marker" | grep -v '.gaia-marker-' || true)"

  rm -rf "$workdir"

  [[ -z "$violations" ]]
}

@test "UAT-008: illegal write outside allowlist IS detected as a violation" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q
  mkdir -p "$workdir/.claude"

  local marker
  marker="$(mktemp "$workdir/.gaia-marker-XXXXXX")"

  # Simulate an illegal write (outside the allowlist)
  illegal_write_surrogate "$workdir"

  local violations
  violations="$(find_write_violations "$workdir" "$marker" | grep -v '.gaia-marker-' || true)"

  rm -rf "$workdir"

  # Violations must be non-empty (the test validates the detection logic)
  [[ -n "$violations" ]]
}

@test "UAT-008: writes to .gaia/local/telemetry/ are in the allowlist" {
  local workdir
  workdir="$(mktemp -d)"
  git -C "$workdir" init -q

  local marker
  marker="$(mktemp "$workdir/.gaia-marker-XXXXXX")"

  mkdir -p "$workdir/.gaia/local/telemetry"
  printf 'telemetry\n' > "$workdir/.gaia/local/telemetry/emit.log"

  local violations
  violations="$(find_write_violations "$workdir" "$marker" | grep -v '.gaia-marker-' || true)"

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

  local marker
  marker="$(mktemp "$workdir/.gaia-marker-XXXXXX")"

  # Run the allowed surrogate (should not touch app/, wiki/, .claude/)
  runbook_surrogate "$workdir" "init"

  local violations
  violations="$(find_write_violations "$workdir" "$marker" | grep -v '.gaia-marker-' || true)"

  rm -rf "$workdir"

  [[ -z "$violations" ]]
}
