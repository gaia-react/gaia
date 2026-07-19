#!/usr/bin/env bats
# UAT-013: when gh is not installed, save locally only with a one-line note,
#          exit zero, do not attempt any gh invocation.
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

# ---------------------------------------------------------------------------
# No-gh surrogate
#
# Simulates the runbook's gh-not-installed branch (forensics.md § 8):
#   - Detects gh absent via command -v
#   - Writes the report locally
#   - Prints one-line note
#   - Returns zero (never errors)
# ---------------------------------------------------------------------------

no_gh_surrogate() {
  local workdir="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  mkdir -p "$workdir/.gaia/local/forensics"
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  # Check if gh is on PATH (in production this gates the branch)
  if ! command -v gh >/dev/null 2>&1; then
    printf '`gh` not installed; report saved locally at .gaia/local/forensics/%s-%s.md\n' \
      "$timestamp" "$class"
    return 0
  fi

  # gh is installed; in production this would offer issue creation.
  # For this test we only care about the no-gh path.
  printf 'gh is installed (not the test scenario)\n'
  return 0
}

setup() {
  WORKDIR="$(mktemp -d)"
  # Build a PATH that has no gh binary. CLEAN_BIN is the ONLY entry;
  # /usr/bin and /bin are deliberately excluded because GitHub Actions
  # ubuntu-latest ships gh at /usr/bin/gh, which would defeat the test.
  CLEAN_BIN="$(mktemp -d)"
  # Populate with the binaries the surrogate needs. printf/command are bash
  # builtins; mkdir is the only external command exercised in the surrogate.
  for cmd in bash mkdir; do
    local real
    real="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real" ]]; then
      ln -sf "$real" "$CLEAN_BIN/$cmd" 2>/dev/null || true
    fi
  done
  NO_GH_PATH="$CLEAN_BIN"
}

teardown() {
  rm -rf "$WORKDIR" "$CLEAN_BIN"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-013: with gh not on PATH, surrogate exits zero" {
  local result=0
  PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "init" || result=$?
  [[ "$result" -eq 0 ]]
}

@test "UAT-013: with gh not on PATH, report is saved locally" {
  PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "hook"
  local report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-hook.md"
  [[ -f "$report" ]]
}

@test "UAT-013: with gh not on PATH, one-line note mentions gh not installed" {
  local output
  output="$(PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "update")"
  printf '%s' "$output" | grep -qi 'not installed'
}

@test "UAT-013: with gh not on PATH, one-line note includes the local path" {
  local output
  output="$(PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "wiki-sync")"
  printf '%s' "$output" | grep -q '\.gaia/local/forensics/'
}

@test "UAT-013: with gh not on PATH, output is exactly one line" {
  local output
  output="$(PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "scaffold")"
  # printf '%s\n' adds a trailing newline so wc -l counts the actual line.
  # $(command) strips trailing newlines, so we add one back for counting.
  local line_count
  line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [[ "$line_count" -eq 1 ]]
}

@test "UAT-013: surrogate never invokes gh even when gh is removed from PATH" {
  # Run the surrogate; if it tries to invoke gh it will fail (not on PATH)
  # and the result variable will be non-zero; but we assert it IS zero.
  local result=0
  PATH="$NO_GH_PATH" no_gh_surrogate "$WORKDIR" "quality-gate" >/dev/null 2>&1 || result=$?
  [[ "$result" -eq 0 ]]
}
