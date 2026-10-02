#!/usr/bin/env bats
# UAT-005: declining GH issue creation still saves the report locally;
#          no gh invocation occurs.
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIBRARY_DIRECTORY="$HERE/lib"

# ---------------------------------------------------------------------------
# Decline surrogate
#
# Simulates the runbook's "No, save locally only" branch:
#   - Writes the report to .gaia/local/forensics/
#   - Does NOT invoke gh
# ---------------------------------------------------------------------------

# Synthetic stand-in for `bash .gaia/scripts/main-root-lib.sh --tree-key`'s
# stdout (16 lowercase hex characters); this surrogate never invokes the real
# resolver, same as the fixed synthetic $timestamp below.
TREE_KEY_FIXTURE="deadbeefcafe1234"

decline_surrogate() {
  local work_directory="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  mkdir -p "$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE"
  local report_path="$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  printf 'Report: .gaia/local/forensics/%s/%s-%s.md\n' "$TREE_KEY_FIXTURE" "$timestamp" "$class"
  # No gh invocation here; this is the decline branch
}

setup() {
  WORK_DIRECTORY="$(mktemp -d)"
  CAPTURE_FILE="$WORK_DIRECTORY/gh-argv.txt"
}

teardown() {
  rm -rf "$WORK_DIRECTORY"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-005: declining issue creation saves the report file locally" {
  decline_surrogate "$WORK_DIRECTORY" "init"
  local report
  report="$WORK_DIRECTORY/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-init.md"
  [[ -f "$report" ]]
}

@test "UAT-005: declining issue creation prints the local report path" {
  local output
  output="$(decline_surrogate "$WORK_DIRECTORY" "hook")"
  printf '%s' "$output" | grep -q '\.gaia/local/forensics/'
}

@test "UAT-005: declining issue creation does NOT invoke gh" {
  # Build a stub gh that records any invocation
  local stub_directory
  stub_directory="$(mktemp -d)"
  cp "$LIBRARY_DIRECTORY/stub-gh.sh" "$stub_directory/gh"
  chmod +x "$stub_directory/gh"
  export STUB_GH_CAPTURE_FILE="$CAPTURE_FILE"

  # Run the decline surrogate with the stub on PATH
  PATH="$stub_directory:$PATH" decline_surrogate "$WORK_DIRECTORY" "update"

  rm -rf "$stub_directory"

  # The capture file should not exist (gh was never called)
  [[ ! -f "$CAPTURE_FILE" ]]
}

@test "UAT-005: local file exists and is non-empty after decline" {
  decline_surrogate "$WORK_DIRECTORY" "wiki-sync"
  local report="$WORK_DIRECTORY/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-wiki-sync.md"
  [[ -f "$report" ]]
  [[ -s "$report" ]]
}

@test "UAT-005: report path uses correct timestamp-class filename pattern" {
  local class="quality-gate"
  decline_surrogate "$WORK_DIRECTORY" "$class"
  local expected_path="$WORK_DIRECTORY/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-${class}.md"
  [[ -f "$expected_path" ]]
}

@test "UAT-005: report survives after surrogate exits (file is not cleaned up)" {
  decline_surrogate "$WORK_DIRECTORY" "scaffold"
  local report="$WORK_DIRECTORY/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-scaffold.md"
  # File must still be present after surrogate returns
  [[ -f "$report" ]]
}
