#!/usr/bin/env bats
# UAT-004: when the diagnosed failure is a user-config issue,
#          the skill saves locally, prints remediation steps,
#          and does NOT offer or invoke gh.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"

# ---------------------------------------------------------------------------
# Diagnose helper (mirrors taxonomy.md § Diagnose branch)
#
# Returns "user-config" or "probable-bug" based on the given signals.
# ---------------------------------------------------------------------------

diagnose_branch() {
  local description="$1"
  local node_version="${2:-}"
  local dirty="${3:-false}"
  local has_missing_env_var="${4:-false}"

  # User-config signals (taxonomy.md § Diagnose branch):
  #   wrong Node version, missing required env var, dirty working tree

  # Dirty working tree blocks workflow
  if [[ "$dirty" == "true" ]]; then
    printf 'user-config'
    return 0
  fi

  # Missing required env var
  if [[ "$has_missing_env_var" == "true" ]]; then
    printf 'user-config'
    return 0
  fi

  # Wrong Node version (simplified: check if version string contains "14." or "16.")
  # Production logic compares against .nvmrc / engines.node range
  if printf '%s' "$node_version" | grep -qE '^v(14|16)\.'; then
    printf 'user-config'
    return 0
  fi

  printf 'probable-bug'
}

# ---------------------------------------------------------------------------
# User-config surrogate
#
# Simulates the runbook's user-config branch (forensics.md § 8):
#   - Saves the report locally (always)
#   - Prints remediation steps
#   - Does NOT offer or invoke gh
# ---------------------------------------------------------------------------

user_config_surrogate() {
  local workdir="$1"
  local class="${2:-init}"
  local remediation="${3:-Check your Node version and run nvm use.}"
  local timestamp="20260508T143022Z"

  mkdir -p "$workdir/.gaia/local/forensics"
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '## Symptom\nUser config issue.\n' > "$report_path"

  # Print remediation steps (not a GH issue offer)
  printf 'Remediation: %s\n' "$remediation"
  printf 'Report saved: .gaia/local/forensics/%s-%s.md\n' "$timestamp" "$class"
  # No AskUserQuestion, no gh invocation
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

@test "UAT-004: dirty working tree is diagnosed as user-config" {
  local branch
  branch="$(diagnose_branch "dirty working tree" "" "true" "false")"
  [[ "$branch" == "user-config" ]]
}

@test "UAT-004: missing required env var is diagnosed as user-config" {
  local branch
  branch="$(diagnose_branch "missing GITHUB_TOKEN" "" "false" "true")"
  [[ "$branch" == "user-config" ]]
}

@test "UAT-004: wrong Node version is diagnosed as user-config" {
  local branch
  branch="$(diagnose_branch "node version issue" "v14.21.0" "false" "false")"
  [[ "$branch" == "user-config" ]]
}

@test "UAT-004: correct Node version + clean tree = probable-bug" {
  local branch
  branch="$(diagnose_branch "hook misfired" "v20.11.0" "false" "false")"
  [[ "$branch" == "probable-bug" ]]
}

@test "UAT-004: user-config surrogate saves report locally" {
  user_config_surrogate "$WORKDIR" "init"
  local report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-init.md"
  [[ -f "$report" ]]
}

@test "UAT-004: user-config surrogate prints remediation steps" {
  local output
  output="$(user_config_surrogate "$WORKDIR" "init" "Run nvm use and retry.")"
  printf '%s' "$output" | grep -q 'Remediation'
}

@test "UAT-004: user-config surrogate does NOT invoke gh" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  cp "$LIB/stub-gh.sh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  export STUB_GH_CAPTURE_FILE="$CAPTURE_FILE"

  PATH="$stub_dir:$PATH" user_config_surrogate "$WORKDIR" "init" >/dev/null

  rm -rf "$stub_dir"

  # gh stub capture file must not exist (gh was never called)
  [[ ! -f "$CAPTURE_FILE" ]]
}

@test "UAT-004: user-config branch does not mention 'File a GitHub issue'" {
  local output
  output="$(user_config_surrogate "$WORKDIR" "hook" "Check .claude/settings.json hooks.")"
  # The user-config branch must not offer issue creation
  ! printf '%s' "$output" | grep -qi 'github issue'
}
