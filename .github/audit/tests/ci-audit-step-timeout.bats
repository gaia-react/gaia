#!/usr/bin/env bats
# Workflow-logic tests for the "Compute audit step timeout" step in
# .github/workflows/code-review-audit.yml.
#
# The step turns `budget_seconds` into the audit step's `timeout-minutes`. A
# job that reaches its own `timeout-minutes` is CANCELLED rather than failed,
# so `failure()` is false and the failed-run status backstop never runs,
# stranding the pull request with no GAIA-Audit status. The step therefore
# clamps its output under the job's limit so the audit step's own timeout,
# which counts as a failure, fires first. These tests execute the real `run:`
# body and pin the clamp against the job's limit as the workflow declares it.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  STEP='Compute audit step timeout'
}

# Extract one step's `run:` shell body from the workflow YAML and dedent it.
# A member of the family .gaia/scripts/check-step-body-extractor-roster.sh
# declares; read that file before changing what this helper extracts.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# The step's own `env:` value for AUDIT_STEP_MAX_MINUTES.
step_cap() {
  awk -v want="      - name: ${STEP}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && /^          AUDIT_STEP_MAX_MINUTES:/ { print $2; exit }
  ' "$WORKFLOW" | tr -d "'\""
}

# The audit job's `timeout-minutes`, the first four-space-indented one.
job_timeout() {
  awk '/^    timeout-minutes: / { print $2; exit }' "$WORKFLOW"
}

# run_step <budget_seconds>: runs the extracted body, prints the emitted
# minutes value on stdout and anything else the step printed on stderr.
run_step() {
  local body out="$BATS_TEST_TMPDIR/github_output"
  body="$(extract_step_body "$STEP")"
  : > "$out"
  BUDGET_SECONDS="$1" AUDIT_STEP_MAX_MINUTES="$(step_cap)" GITHUB_OUTPUT="$out" \
    bash "$body" >"$BATS_TEST_TMPDIR/stdout"
  sed -n 's/^minutes=//p' "$out"
}

@test "the step declares a cap strictly under the job's timeout-minutes" {
  local cap job
  cap="$(step_cap)"
  job="$(job_timeout)"
  [[ "$cap" =~ ^[0-9]+$ ]] || return 1
  [[ "$job" =~ ^[0-9]+$ ]] || return 1
  # Headroom for the setup steps before the audit and the push, status, and
  # comment steps after it.
  [ "$cap" -le $(( job - 10 )) ]
}

@test "default budget 1800s converts to 30 minutes, unclamped" {
  run run_step 1800
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]
  ! grep -q '::warning::' "$BATS_TEST_TMPDIR/stdout"
}

@test "a budget past the cap clamps to the cap and warns" {
  run run_step 7200
  [ "$status" -eq 0 ]
  [ "$output" = "$(step_cap)" ]
  grep -q '::warning::' "$BATS_TEST_TMPDIR/stdout"
}

@test "a budget of exactly the job's limit clamps rather than reaching it" {
  run run_step $(( $(job_timeout) * 60 ))
  [ "$status" -eq 0 ]
  [ "$output" -lt "$(job_timeout)" ]
}

@test "a budget at the cap is left as is" {
  run run_step $(( $(step_cap) * 60 ))
  [ "$status" -eq 0 ]
  [ "$output" = "$(step_cap)" ]
  ! grep -q '::warning::' "$BATS_TEST_TMPDIR/stdout"
}

@test "missing or zero budget still defaults to 30, and 1s still floors to 1" {
  run run_step ''
  [ "$output" = "30" ]
  run run_step 0
  [ "$output" = "30" ]
  run run_step 1
  [ "$output" = "1" ]
}
