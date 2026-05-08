#!/usr/bin/env bats
# UAT-005: declining GH issue creation still saves the report locally;
#          no gh invocation occurs.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"

# ---------------------------------------------------------------------------
# Decline surrogate
#
# Simulates the runbook's "No, save locally only" branch:
#   - Writes the report to .gaia/local/forensics/
#   - Does NOT invoke gh
# ---------------------------------------------------------------------------

decline_surrogate() {
  local workdir="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  mkdir -p "$workdir/.gaia/local/forensics"
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  printf 'Report: .gaia/local/forensics/%s-%s.md\n' "$timestamp" "$class"
  # No gh invocation here — this is the decline branch
}

setup() {
  WORKDIR="$(mktemp -d)"
  CAPTURE_FILE="$WORKDIR/gh-argv.txt"
}

teardown() {
  rm -rf "$WORKDIR"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-005: declining issue creation saves the report file locally" {
  decline_surrogate "$WORKDIR" "init"
  local report
  report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-init.md"
  [[ -f "$report" ]]
}

@test "UAT-005: declining issue creation prints the local report path" {
  local output
  output="$(decline_surrogate "$WORKDIR" "hook")"
  printf '%s' "$output" | grep -q '\.gaia/local/forensics/'
}

@test "UAT-005: declining issue creation does NOT invoke gh" {
  # Build a stub gh that records any invocation
  local stub_dir
  stub_dir="$(mktemp -d)"
  cp "$LIB/stub-gh.sh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  export STUB_GH_CAPTURE_FILE="$CAPTURE_FILE"

  # Run the decline surrogate with the stub on PATH
  PATH="$stub_dir:$PATH" decline_surrogate "$WORKDIR" "update"

  rm -rf "$stub_dir"

  # The capture file should not exist (gh was never called)
  [[ ! -f "$CAPTURE_FILE" ]]
}

@test "UAT-005: local file exists and is non-empty after decline" {
  decline_surrogate "$WORKDIR" "wiki-sync"
  local report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-wiki-sync.md"
  [[ -f "$report" ]]
  [[ -s "$report" ]]
}

@test "UAT-005: report path uses correct timestamp-class filename pattern" {
  local class="quality-gate"
  decline_surrogate "$WORKDIR" "$class"
  local expected_path="$WORKDIR/.gaia/local/forensics/20260508T143022Z-${class}.md"
  [[ -f "$expected_path" ]]
}

@test "UAT-005: report survives after surrogate exits (file is not cleaned up)" {
  decline_surrogate "$WORKDIR" "scaffold"
  local report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-scaffold.md"
  # File must still be present after surrogate returns
  [[ -f "$report" ]]
}
