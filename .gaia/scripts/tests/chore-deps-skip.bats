#!/usr/bin/env bats
# .gaia/scripts/chore-deps-skip.sh: the shared chore(deps) predicate, and the
# three CI workflow steps that feed it a changed-path list.
#
# The predicate itself decides on a subject plus a changed-path list on
# stdin. Each workflow step is responsible for computing that list (a `git
# diff` scoped to the right range) and handing it to the predicate as a
# here-string, never a live pipe. The workflow tests below extract and
# execute the real `run:` body from each workflow file against a sandbox
# repo, so they exercise shipped code rather than a description of it.
#
# Assertion style per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  PREDICATE="$REPO_ROOT/.gaia/scripts/chore-deps-skip.sh"
  # A missing predicate is a real regression (a rename or deletion), not an
  # environment gap, so this suite fails rather than skips: a skip here would
  # green the whole file with nothing checked (guards-must-fail.md).
  [ -f "$PREDICATE" ] || { echo "missing $PREDICATE" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# Predicate truth table
# -----------------------------------------------------------------------------

@test "predicate truth table" {
  run bash "$PREDICATE" 'chore(deps): x' <<<$'package.json\npnpm-lock.yaml'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run bash "$PREDICATE" 'chore(deps-dev): x' <<<'pnpm-workspace.yaml'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run bash "$PREDICATE" 'chore(deps): x' <<<$'.gaia/cli/package.json\n.gaia/cli/pnpm-lock.yaml\n.gaia/cli/pnpm-workspace.yaml'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  run bash "$PREDICATE" 'chore(deps): x' <<<$'package.json\napp/x.ts'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE" 'chore(deps): x' <<<''
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE" 'chore(deps): x' </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE" 'fix: x' <<<'package.json'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE" 'chore: bump' <<<'package.json'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  # Nested manifest, not on the list: decided.
  run bash "$PREDICATE" 'chore(deps): x' <<<'app/foo/package.json'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE" 'chore(deps): x' <<<'test/fixtures/pnpm-lock.yaml'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  run bash "$PREDICATE"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  # Blank lines ignored, not counted.
  run bash "$PREDICATE" 'chore(deps): x' <<<$'\npackage.json\n\npnpm-lock.yaml\n'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # Exact match only.
  run bash "$PREDICATE" 'chore(deps): x' <<<'./package.json'
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]

  # stdin fully drained even on a non-matching title, so a `set -o pipefail`
  # caller piping a live writer directly in never sees SIGPIPE.
  run bash -c "set -o pipefail; seq 1 5000 | bash '$PREDICATE' 'fix: x' >/dev/null"
  [ "$status" -eq 0 ]
}

@test "closed stdin (not just empty) prints false and exits 0" {
  run bash -c "bash '$PREDICATE' 'chore(deps): x' <&-"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# -----------------------------------------------------------------------------
# Workflow waiver steps: extract and execute the real `run:` body against a
# sandbox repo.
# -----------------------------------------------------------------------------

# Extract one step's `run:` shell body from a workflow YAML and dedent it.
# Matches the `- name:` line EXACTLY, and stops at the NEXT step boundary at
# the same indent regardless of that step's own first key (`- name:`,
# `- uses:`, `- if:`), since not every step in every workflow leads with
# `name:`. No bats file shares this across files, each keeps its own copy of
# what "extract the real step body" means.
extract_step_body() {
  local workflow="$1" step_name="$2" out="$BATS_TEST_TMPDIR/step-$$.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$workflow" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# Run an extracted step body under `bash -e` in $SANDBOX with the given
# env assignments (NAME=value, one per remaining arg), predicate on PATH at
# .gaia/scripts/chore-deps-skip.sh, GITHUB_OUTPUT at a fresh temp file.
# Prints two lines, "rc=<n>" then "skip=<value>" (value may be empty when
# GITHUB_OUTPUT never got a skip= line). Command substitution runs the whole
# function in a subshell, so the caller reads both off the captured output
# rather than off a variable this function sets, which a subshell cannot
# leak back to the caller's own shell.
run_step_capture() {
  local body="$1"; shift
  local gh_output="$BATS_TEST_TMPDIR/gh-output-$$-$RANDOM" rc=0 skip=""
  : > "$gh_output"
  ( cd "$SANDBOX" && env "$@" GITHUB_OUTPUT="$gh_output" bash -e "$body" ) || rc=$?
  skip="$(awk -F= '$1 == "skip" { v = $2 } END { print v }' "$gh_output")"
  printf 'rc=%s\nskip=%s\n' "$rc" "$skip"
}

# Parse "skip=" or "rc=" out of run_step_capture's two-line output.
field() { sed -n "s/^${2}=//p" <<<"$1"; }

setup_sandbox_repo() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$PREDICATE" "$SANDBOX/.gaia/scripts/chore-deps-skip.sh"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  git -C "$SANDBOX" add .gaia/scripts/chore-deps-skip.sh
  git -C "$SANDBOX" commit --quiet -m "init"
}

commit_file() {
  local path="$1" content="$2" message="${3:-commit $1}"
  mkdir -p "$SANDBOX/$(dirname "$path")"
  printf '%s\n' "$content" > "$SANDBOX/$path"
  git -C "$SANDBOX" add "$path"
  git -C "$SANDBOX" commit --quiet -m "$message"
}

@test "tests.yml 'Check chore-deps title' body is non-empty and executes" {
  tests_body="$(extract_step_body "$REPO_ROOT/.github/workflows/tests.yml" "Check chore-deps title")"
  [ -n "$tests_body" ]
}

@test "tests.yml 'Check chore-deps title': an unknown PR_BASE_SHA exits 0 with skip=false" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/tests.yml" "Check chore-deps title")"
  [ -n "$body" ]
  setup_sandbox_repo
  commit_file package.json '{}'
  result="$(run_step_capture "$body" PR_TITLE="chore(deps): bump x" "PR_BASE_SHA=0000000000000000000000000000000000dead" "EVENT_NAME=pull_request")"
  [ "$(field "$result" rc)" -eq 0 ]
  [ "$(field "$result" skip)" = "false" ]
}

@test "tests.yml 'Check chore-deps title': manifest-only diff skips, an app/ change does not" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/tests.yml" "Check chore-deps title")"
  [ -n "$body" ]
  setup_sandbox_repo
  base="$(git -C "$SANDBOX" rev-parse HEAD)"
  commit_file package.json '{}'
  result="$(run_step_capture "$body" PR_TITLE="chore(deps): bump x" "PR_BASE_SHA=$base" "EVENT_NAME=pull_request")"
  [ "$(field "$result" skip)" = "true" ]

  commit_file app/x.ts "export const x = 1;"
  result="$(run_step_capture "$body" PR_TITLE="chore(deps): bump x" "PR_BASE_SHA=$base" "EVENT_NAME=pull_request")"
  [ "$(field "$result" skip)" = "false" ]
}

@test "tests.yml 'Check chore-deps title': workflow_dispatch never skips" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/tests.yml" "Check chore-deps title")"
  [ -n "$body" ]
  setup_sandbox_repo
  base="$(git -C "$SANDBOX" rev-parse HEAD)"
  commit_file package.json '{}'
  result="$(run_step_capture "$body" PR_TITLE="chore(deps): bump x" "PR_BASE_SHA=$base" "EVENT_NAME=workflow_dispatch")"
  [ "$(field "$result" skip)" = "false" ]
}

@test "chromatic.yml 'Check chore-deps commit' body is non-empty and executes" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/chromatic.yml" "Check chore-deps commit")"
  [ -n "$body" ]
}

# chromatic.yml reads a subject off HEAD directly and needs a real remote
# (refs/remotes/origin/main) for the branch-vs-default-branch range, so it
# gets its own sandbox with a bare remote.
setup_chromatic_sandbox() {
  setup_sandbox_repo
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init --quiet --bare "$REMOTE"
  git -C "$SANDBOX" remote add origin "$REMOTE"
  git -C "$SANDBOX" push --quiet origin main
  git -C "$SANDBOX" update-ref refs/remotes/origin/main "$(git -C "$SANDBOX" rev-parse main)"
}

@test "chromatic.yml: a feature branch, manifest-only, skips; plus an app/ change does not" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/chromatic.yml" "Check chore-deps commit")"
  [ -n "$body" ]
  setup_chromatic_sandbox
  git -C "$SANDBOX" checkout --quiet -b feature
  commit_file package.json '{}' "chore(deps): bump x"
  result="$(run_step_capture "$body" "DEFAULT_BRANCH=main" "REF_NAME=feature" "BEFORE=")"
  [ "$(field "$result" skip)" = "true" ]

  commit_file app/x.ts "export const x = 1;" "chore(deps): bump x"
  result="$(run_step_capture "$body" "DEFAULT_BRANCH=main" "REF_NAME=feature" "BEFORE=")"
  [ "$(field "$result" skip)" = "false" ]
}

@test "chromatic.yml: a manifest-only last commit on a branch whose earlier commit changed app/ does not skip" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/chromatic.yml" "Check chore-deps commit")"
  [ -n "$body" ]
  setup_chromatic_sandbox
  git -C "$SANDBOX" checkout --quiet -b feature
  commit_file app/x.ts "export const x = 1;" "unrelated change"
  commit_file package.json '{}' "chore(deps): bump x"
  result="$(run_step_capture "$body" "DEFAULT_BRANCH=main" "REF_NAME=feature" "BEFORE=")"
  [ "$(field "$result" skip)" = "false" ]
}

@test "chromatic.yml: on the default branch, an all-zero BEFORE does not skip" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/chromatic.yml" "Check chore-deps commit")"
  [ -n "$body" ]
  setup_chromatic_sandbox
  commit_file package.json '{}' "chore(deps): bump x"
  result="$(run_step_capture "$body" "DEFAULT_BRANCH=main" "REF_NAME=main" "BEFORE=0000000000000000000000000000000000000000")"
  [ "$(field "$result" skip)" = "false" ]
}

@test "chromatic.yml: on the default branch, BEFORE=parent and a manifest-only commit skips" {
  body="$(extract_step_body "$REPO_ROOT/.github/workflows/chromatic.yml" "Check chore-deps commit")"
  [ -n "$body" ]
  setup_chromatic_sandbox
  parent="$(git -C "$SANDBOX" rev-parse HEAD)"
  commit_file package.json '{}' "chore(deps): bump x"
  result="$(run_step_capture "$body" "DEFAULT_BRANCH=main" "REF_NAME=main" "BEFORE=$parent")"
  [ "$(field "$result" skip)" = "true" ]
}
