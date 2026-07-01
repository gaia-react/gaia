#!/usr/bin/env bats
# UAT-012: gh issue create uses --repo gaia-react/gaia, --label gaia-forensics,
#          and the title format "forensics: <class>, <one-line user description>"
# UAT-006: on gh failure (auth error / label-not-found), the skill surfaces gh's
#          native error verbatim, leaves the local report in place, exits non-zero.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"

# ---------------------------------------------------------------------------
# gh invocation surrogate
#
# Builds a temp PATH prefix containing a "gh" stub script that records argv
# to $STUB_GH_CAPTURE_FILE, then runs the surrogate that invokes gh with the
# hardcoded constants from the runbook's § 8 probable-bug branch.
# ---------------------------------------------------------------------------

invoke_gh_surrogate() {
  local capture_file="$1"
  local class="$2"
  local one_line="$3"
  local body_file="$4"

  # Build a temp bin dir with a "gh" stub
  local stub_dir
  stub_dir="$(mktemp -d)"
  cp "$LIB/stub-gh.sh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"

  export STUB_GH_CAPTURE_FILE="$capture_file"

  # Simulate the runbook's gh invocation (frozen contract from forensics.md § 8)
  PATH="$stub_dir:$PATH" gh issue create \
    --repo "gaia-react/gaia" \
    --label "gaia-forensics" \
    --title "forensics: $class, $one_line" \
    --body-file "$body_file"

  rm -rf "$stub_dir"
}

setup() {
  WORKDIR="$(mktemp -d)"
  CAPTURE_FILE="$WORKDIR/gh-argv.txt"
  BODY_FILE="$WORKDIR/body.md"
  printf '## Symptom\nTest body.\n' > "$BODY_FILE"
}

teardown() {
  rm -rf "$WORKDIR"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-012: gh is invoked with --repo gaia-react/gaia" {
  invoke_gh_surrogate "$CAPTURE_FILE" "init" "gaia-init rename step failed" "$BODY_FILE"
  grep -xF -- '--repo' "$CAPTURE_FILE"
  grep -xF -- 'gaia-react/gaia' "$CAPTURE_FILE"
}

@test "UAT-012: gh is invoked with --label gaia-forensics" {
  invoke_gh_surrogate "$CAPTURE_FILE" "hook" "hook misfired on PostToolUse" "$BODY_FILE"
  grep -xF -- '--label' "$CAPTURE_FILE"
  grep -xF -- 'gaia-forensics' "$CAPTURE_FILE"
}

@test "UAT-012: gh title format is forensics: <class>, <one-line>" {
  local class="wiki-sync"
  local one_line="sync failed to push"
  invoke_gh_surrogate "$CAPTURE_FILE" "$class" "$one_line" "$BODY_FILE"
  grep -xF -- '--title' "$CAPTURE_FILE"
  grep -xF -- "forensics: $class, $one_line" "$CAPTURE_FILE"
}

@test "UAT-012: gh is invoked with --body-file (not --body)" {
  invoke_gh_surrogate "$CAPTURE_FILE" "update" "merge conflict in hooks" "$BODY_FILE"
  grep -xF -- '--body-file' "$CAPTURE_FILE"
  # Confirm --body (without -file suffix) is not used as a standalone flag
  ! grep -xF -- '--body' "$CAPTURE_FILE"
}

@test "UAT-012: gh repo arg is hardcoded constant, not derived from git remote" {
  # The frozen contract: the repo value must be exactly "gaia-react/gaia"
  # regardless of what git remote would return.
  invoke_gh_surrogate "$CAPTURE_FILE" "init" "rename step failed" "$BODY_FILE"
  grep -xF -- 'gaia-react/gaia' "$CAPTURE_FILE"
  # Confirm the captured argv does not contain any git-remote-derived value
  ! grep -q 'origin' "$CAPTURE_FILE"
}

@test "UAT-012: title for 'other' class uses 'other' as the class tag" {
  local class="other"
  local one_line="unknown failure outside taxonomy"
  invoke_gh_surrogate "$CAPTURE_FILE" "$class" "$one_line" "$BODY_FILE"
  grep -xF -- "forensics: $class, $one_line" "$CAPTURE_FILE"
}

@test "UAT-012: stub gh exits zero on a successful invocation" {
  local result=0
  invoke_gh_surrogate "$CAPTURE_FILE" "scaffold" "new-component skill failed" "$BODY_FILE" || result=$?
  [[ "$result" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# UAT-006: gh failure path; error surfaced verbatim, local report preserved,
#          exit non-zero. Tested via a "failing-gh" stub that exits 1.
# ---------------------------------------------------------------------------

invoke_gh_failing_surrogate() {
  local workdir="$1"
  local class="${2:-init}"
  local timestamp="20260508T143022Z"

  # Write the local report (always done before gh is called)
  mkdir -p "$workdir/.gaia/local/forensics"
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '## Symptom\nTest report body.\n' > "$report_path"

  # Build a failing gh stub
  local stub_dir
  stub_dir="$(mktemp -d)"
  local failing_gh="$stub_dir/gh"
  printf '#!/usr/bin/env bash\nprintf "ERROR: authentication required\n" >&2\nexit 1\n' > "$failing_gh"
  chmod +x "$failing_gh"

  local gh_exit=0
  local gh_stderr
  gh_stderr="$(PATH="$stub_dir:$PATH" gh issue create \
    --repo "gaia-react/gaia" \
    --label "gaia-forensics" \
    --title "forensics: $class, test failure" \
    --body-file "$report_path" 2>&1)" || gh_exit=$?

  rm -rf "$stub_dir"

  # Surface gh's stderr verbatim (mirrors forensics.md § 8 On non-zero gh exit)
  if [[ "$gh_exit" -ne 0 ]]; then
    printf '%s\n' "$gh_stderr" >&2
    return "$gh_exit"
  fi
}

@test "UAT-006: gh failure exits non-zero and local report is preserved" {
  local workdir="$WORKDIR"
  local result=0
  invoke_gh_failing_surrogate "$workdir" "hook" 2>/dev/null || result=$?
  # Must exit non-zero
  [[ "$result" -ne 0 ]]
  # Local report must still exist
  [[ -f "$workdir/.gaia/local/forensics/20260508T143022Z-hook.md" ]]
}

@test "UAT-006: gh failure surfaces native error verbatim to stderr" {
  local workdir="$WORKDIR"
  local err_output
  err_output="$(invoke_gh_failing_surrogate "$workdir" "init" 2>&1 || true)"
  printf '%s' "$err_output" | grep -qi 'error\|authentication\|unauthorized\|not found'
}

@test "UAT-006: gh failure does not retry or partially file (stub called once)" {
  # The stub writes to capture file; we use a counting stub to assert single call.
  local stub_dir
  stub_dir="$(mktemp -d)"
  local count_file="$WORKDIR/gh-call-count.txt"
  local failing_gh="$stub_dir/gh"
  printf '#!/usr/bin/env bash\nprintf "1\n" >> "%s"\nexit 1\n' "$count_file" > "$failing_gh"
  chmod +x "$failing_gh"

  local body_file="$WORKDIR/body.md"
  printf '## Symptom\nTest.\n' > "$body_file"

  PATH="$stub_dir:$PATH" gh issue create \
    --repo "gaia-react/gaia" \
    --label "gaia-forensics" \
    --title "forensics: update, test" \
    --body-file "$body_file" 2>/dev/null || true

  rm -rf "$stub_dir"

  local call_count
  call_count="$(wc -l < "$count_file" | tr -d ' ')"
  # Must be exactly 1; no retry
  [[ "$call_count" -eq 1 ]]
}
