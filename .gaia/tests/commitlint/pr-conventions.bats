#!/usr/bin/env bats

# Tests for .github/workflows/pr-conventions.yml, run the way the workflow runs
# them: each step's `run:` body is extracted from the YAML into a scratch script
# and executed with the step's `env:` values exported, so a drift between the
# workflow text and what these tests drive shows up here instead of on a pull
# request.
#
# Every refusal is paired with an acceptance on the same step, so a step that
# refuses everything (or nothing) fails a test. The Dependabot skip is proven
# with a `pnpm` stub that records its calls, so "commitlint was not invoked" is
# an assertion rather than an inference.
#
# Like commitlint-config.bats this suite needs the root workspace's
# node_modules (the real commitlint binary), so it lives outside the
# directories .gaia/tests/bats-shards.sh discovers and runs on the commitlint
# leg of .github/workflows/audit-ci-tests.yml. A missing commitlint FAILS
# setup_file rather than skipping.

setup_file() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  if [ ! -x "$REPO_ROOT/node_modules/.bin/commitlint" ]; then
    printf 'commitlint is not installed at %s: run pnpm install\n' \
      "$REPO_ROOT/node_modules/.bin/commitlint" >&3
    return 1
  fi
  if ! command -v pnpm >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'pnpm and jq are required\n' >&3
    return 1
  fi
}

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  WORKFLOW="$REPO_ROOT/.github/workflows/pr-conventions.yml"
  [ -f "$WORKFLOW" ]
}

# step_field <step name> <run|env>: prints the step's `run:` body (dedented) or
# its `env:` key names, one per line. Reads the step from its `- name:` line to
# the next step.
step_field() {
  awk -v header="      - name: $1" -v field="$2" '
    $0 == header { found = 1; next }
    found && /^      - / { exit }
    found && field == "run" && /^        run: \|$/ { in_run = 1; next }
    found && field == "run" && in_run {
      if ($0 ~ /^          /) { sub(/^          /, ""); print; next }
      if ($0 == "") { print ""; next }
      exit
    }
    found && field == "env" && /^        env:$/ { in_env = 1; next }
    found && field == "env" && in_env {
      if ($0 ~ /^          [A-Z_]+:/) { key = $1; sub(/:$/, "", key); print key; next }
      exit
    }
  ' "$WORKFLOW"
}

# write_step <step name> <file>: writes the extracted run body to <file> and
# fails when it is empty, so a renamed step cannot make every test vacuous.
write_step() {
  step_field "$1" run > "$2"
  [ -s "$2" ]
}

STEP_BRANCH="Validate the head branch name"
STEP_CANARY="Prove commitlint rejects a retired type"
STEP_TITLE="Lint the PR title as the squash subject"
STEP_TYPE="Match the title type to the branch type"

# A pnpm stub that records its argv and exits 0, for the skip assertions.
make_pnpm_stub() {
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
  mkdir -p "$STUB_BIN"
  : > "$PNPM_LOG"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
cat > /dev/null
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
}

# run_branch <head ref>
run_branch() {
  write_step "$STEP_BRANCH" "$BATS_TEST_TMPDIR/branch.sh"
  cd "$REPO_ROOT" || return 1
  HEAD_REF="$1" run bash "$BATS_TEST_TMPDIR/branch.sh"
}

# run_title <title> <number> <author> [path prefix]
run_title() {
  write_step "$STEP_TITLE" "$BATS_TEST_TMPDIR/title.sh"
  cd "$REPO_ROOT" || return 1
  PATH="${4:+$4:}$PATH" PR_TITLE="$1" PR_NUMBER="$2" PR_AUTHOR="$3" run bash "$BATS_TEST_TMPDIR/title.sh"
}

# run_type <head ref> <title> <author>
run_type() {
  write_step "$STEP_TYPE" "$BATS_TEST_TMPDIR/type.sh"
  cd "$REPO_ROOT" || return 1
  HEAD_REF="$1" PR_TITLE="$2" PR_AUTHOR="$3" run bash "$BATS_TEST_TMPDIR/type.sh"
}

# --- structure -------------------------------------------------------------

@test "workflow: each step's env block declares exactly the values its script reads" {
  [ "$(step_field "$STEP_BRANCH" env | tr '\n' ' ')" = "HEAD_REF " ]
  [ "$(step_field "$STEP_TITLE" env | tr '\n' ' ')" = "PR_TITLE PR_NUMBER PR_AUTHOR " ]
  [ "$(step_field "$STEP_TYPE" env | tr '\n' ' ')" = "HEAD_REF PR_TITLE PR_AUTHOR " ]
}

@test "workflow: no run body interpolates an expression" {
  local step_name checked=0
  for step_name in "$STEP_BRANCH" "$STEP_CANARY" "$STEP_TITLE" "$STEP_TYPE"; do
    step_field "$step_name" run > "$BATS_TEST_TMPDIR/body.sh"
    [ -s "$BATS_TEST_TMPDIR/body.sh" ]
    grep -qF '${{' "$BATS_TEST_TMPDIR/body.sh" && return 1
    checked=$((checked + 1))
  done
  [ "$checked" -eq 4 ]
}

@test "workflow: every uses is pinned to a 40-hex SHA with a version comment" {
  local line count=0
  while IFS= read -r line; do
    case "$line" in
      *"uses: ./"*) continue ;;
    esac
    printf '%s\n' "$line" | grep -Eq 'uses: [^@ ]+@[0-9a-f]{40} # v[0-9]' || {
      printf 'unpinned: %s\n' "$line" >&3
      return 1
    }
    count=$((count + 1))
  done < <(grep -E '^ +- uses: |^ +uses: ' "$WORKFLOW")
  [ "$count" -ge 1 ]
}

@test "workflow: default-deny permissions, read-only job, timeout, naming" {
  grep -qx 'permissions: {}' "$WORKFLOW"
  grep -qx '      contents: read' "$WORKFLOW"
  grep -Eq '^    timeout-minutes: [0-9]+$' "$WORKFLOW"
  grep -qx 'name: PR Conventions' "$WORKFLOW"
  grep -qx '    name: Conventions check (PR title and head branch) (advisory)' "$WORKFLOW"
  grep -qF 'pull_request_target' <(grep -v '^#' "$WORKFLOW") && return 1
  grep -qF 'secrets.' <(grep -v '^#' "$WORKFLOW") && return 1
  true
}

# --- branch step -----------------------------------------------------------

@test "branch step: REFUSES a worktree spelling and names the rename fix" {
  run_branch 'worktree-plan+plan-023-x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"branch -m"* ]]
}

@test "branch step: REFUSES an unknown prefix and a wrong-case prefix" {
  local head_ref
  for head_ref in 'feature/x' 'Fix/x'; do
    run_branch "$head_ref"
    if [ "$status" -ne 1 ]; then
      printf 'expected refusal of %s, got status %s\n' "$head_ref" "$status" >&3
      return 1
    fi
  done
}

@test "branch step: ACCEPTS every canonical shape" {
  local head_ref checked=0
  for head_ref in \
    'plan/plan-023-conventional-commits-naming' \
    'fix/2450-statusline-nudge' \
    'dependabot/npm_and_yarn/foo-1.2.3' \
    'wiki/sync-2026-10-03-abc1234' \
    'forensics/12-hook'; do
    run_branch "$head_ref"
    if [ "$status" -ne 0 ]; then
      printf 'expected acceptance of %s, got status %s: %s\n' "$head_ref" "$status" "$output" >&3
      return 1
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -eq 5 ]
}

# --- canary step -----------------------------------------------------------

@test "canary step: exits 0 with the real config" {
  write_step "$STEP_CANARY" "$BATS_TEST_TMPDIR/canary.sh"
  cd "$REPO_ROOT" || return 1
  run bash "$BATS_TEST_TMPDIR/canary.sh"
  [ "$status" -eq 0 ]
}

@test "canary step: FAILS when the config allows every type" {
  local scratch="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch"
  ln -s "$REPO_ROOT/node_modules" "$scratch/node_modules"
  cp "$REPO_ROOT/package.json" "$scratch/package.json"
  cat > "$scratch/commitlint.config.mjs" <<'CONFIG'
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {'type-enum': [0]},
};
CONFIG
  # `pnpm exec commitlint` forwards to the real binary, which reads the scratch
  # directory's config; the real pnpm would first re-verify a lockfile this
  # scratch directory does not carry.
  make_pnpm_stub
  cat > "$STUB_BIN/pnpm" <<STUB
#!/bin/sh
shift 2
exec "$REPO_ROOT/node_modules/.bin/commitlint" "\$@"
STUB
  write_step "$STEP_CANARY" "$BATS_TEST_TMPDIR/canary.sh"
  cd "$scratch" || return 1
  PATH="$STUB_BIN:$PATH" run bash "$BATS_TEST_TMPDIR/canary.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commitlint accepted a retired type"* ]]
}

@test "canary step: FAILS when commitlint errors without naming type-enum" {
  make_pnpm_stub
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
cat > /dev/null
echo "ERR_PNPM_BROKEN install" >&2
exit 1
STUB
  write_step "$STEP_CANARY" "$BATS_TEST_TMPDIR/canary.sh"
  cd "$REPO_ROOT" || return 1
  PATH="$STUB_BIN:$PATH" run bash "$BATS_TEST_TMPDIR/canary.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without naming the type-enum rule"* ]]
}

# --- title step ------------------------------------------------------------

@test "title step: REFUSES a title with no type and a retired type" {
  run_title 'Fix the thing' 2451 stevensacks
  [ "$status" -ne 0 ]
  run_title 'debt(x): y' 2451 stevensacks
  [ "$status" -ne 0 ]
  [[ "$output" == *"type-enum"* ]]
}

@test "title step: REFUSES a title whose squash subject passes 100 characters" {
  local title
  title="feat: $(printf 'a%.0s' $(seq 1 86))"
  [ "${#title}" -eq 92 ]
  [ "${#title}" -le 100 ]
  [ "$(printf '%s (#%s)' "$title" 12345 | wc -c | tr -d ' ')" -eq 101 ]
  run_title "$title" 12345 stevensacks
  [ "$status" -ne 0 ]
  [[ "$output" == *"header-max-length"* ]]
}

@test "title step: ACCEPTS a conforming title" {
  run_title 'feat(harness): enforce conventional commits and canonical branch names' 2451 stevensacks
  [ "$status" -eq 0 ]
}

@test "title step: SKIPS Dependabot without invoking commitlint" {
  local dependabot_title='ci(deps): bump chromaui/action from 18.8.1 to 18.9.4 in the github-actions group across 1 directory'
  [ "${#dependabot_title}" -eq 99 ]
  make_pnpm_stub
  PNPM_LOG="$PNPM_LOG" run_title "$dependabot_title" 2452 'dependabot[bot]' "$STUB_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping the title lint for Dependabot"* ]]
  [ ! -s "$PNPM_LOG" ]
}

@test "title step: the same 99-character title from a human is REFUSED" {
  local dependabot_title='ci(deps): bump chromaui/action from 18.8.1 to 18.9.4 in the github-actions group across 1 directory'
  run_title "$dependabot_title" 2452 stevensacks
  [ "$status" -ne 0 ]
  [[ "$output" == *"header-max-length"* ]]
}

@test "title step: the stub records a commitlint call for a human author" {
  make_pnpm_stub
  PNPM_LOG="$PNPM_LOG" run_title 'feat: x' 7 stevensacks "$STUB_BIN"
  [ "$status" -eq 0 ]
  grep -qF 'exec commitlint --verbose' "$PNPM_LOG"
}

@test "title step: shell metacharacters in a title run nothing" {
  local sentinel="$BATS_TEST_TMPDIR/pwned"
  run_title "feat: \$(touch $sentinel) \`touch $sentinel\`" 9 stevensacks
  [ ! -e "$sentinel" ]
}

# --- type-match step -------------------------------------------------------

@test "type step: ACCEPTS a title type equal to the plan branch type" {
  local scenario checked=0
  for scenario in \
    'feat/plan-024-x|feat(harness): y' \
    'feat/spec-005-cards|feat!: y' \
    'fix/plan-024-x|fix: y'; do
    run_type "${scenario%%|*}" "${scenario#*|}" stevensacks
    if [ "$status" -ne 0 ]; then
      printf 'expected acceptance of %s: %s\n' "$scenario" "$output" >&3
      return 1
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
}

@test "type step: REFUSES a mismatched type and names both types and the fix" {
  run_type 'feat/plan-024-x' 'fix: y' stevensacks
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"declares type feat"* ]]
  [[ "$output" == *"title has type fix"* ]]
  [[ "$output" == *"retitle"* ]]
}

@test "type step: passes a legacy plan branch with any title" {
  run_type 'plan/plan-023-conventional-commits-naming' 'fix: y' stevensacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no change type"* ]]
}

@test "type step: passes a non-plan branch with any title" {
  run_type 'fix/2450-statusline-nudge' 'feat: y' stevensacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no change type"* ]]
}

@test "type step: SKIPS Dependabot even when the types differ" {
  run_type 'feat/plan-024-x' 'fix: y' 'dependabot[bot]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping the type match for Dependabot"* ]]
}
