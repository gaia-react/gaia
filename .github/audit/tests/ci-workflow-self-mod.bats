#!/usr/bin/env bats

# Guards the "Check workflow self-modification" step of
# .github/workflows/code-review-audit.yml.
#
# The step decides whether the audit runs at all. claude-code-action refuses to
# run when the workflow file on the PR branch differs from the copy on the
# repository's DEFAULT branch (a server-side token-exchange rejection carrying
# error_code workflow_not_found_on_default_branch), so the step exists to
# detect that condition first and skip cleanly with a truthful status instead of
# letting the abort path post a misleading one.
#
# The comparison ref is the whole contract: the default branch and this PR's own
# base ref disagree on any stacked PR, in both directions, and neither direction
# is visible from the step's `if:` expression. .github/audit/tests/ci-guard-paths.bats
# drives this step's OUTPUT through the guards that consume it; nothing there
# exercises how the output is computed. So this suite EXECUTES the real `run:`
# body extracted from the workflow YAML against a sandbox repo with a local bare
# "origin", the same way .github/audit/tests/self-heal-scope-gate.bats does.
#
# Assertion style per .claude/rules/bats-assertions.md.

DEFAULT_WORKFLOW='name: code-review-audit (default branch copy)'
STACKED_WORKFLOW='name: code-review-audit (stacked base copy)'
PR_WORKFLOW='name: code-review-audit (this PR edits it)'

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  BARE="$BATS_TEST_TMPDIR/origin.git"
  git init --quiet --bare "$BARE"

  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # The default branch: one audit workflow copy and one source file, so a head
  # commit can change source without changing the workflow.
  mkdir -p "$SANDBOX/.github/workflows" "$SANDBOX/app"
  printf '%s\n' "$DEFAULT_WORKFLOW" > "$SANDBOX/.github/workflows/code-review-audit.yml"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit --quiet -m "default branch"

  git -C "$SANDBOX" remote add origin "$BARE"
  git -C "$SANDBOX" push --quiet origin main

  STEP_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : > "$STEP_OUTPUT"
}

# Extract one step's `run:` shell body from the workflow YAML and dedent it.
# Matches the `- name:` line EXACTLY. Deliberately identical to the helper in
# .github/audit/tests/self-heal-scope-gate.bats (bats files do not share
# function definitions across files), so the two never disagree about what
# "extract the real step body" means.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && !/^        run: \|[[:space:]]*$/ { next }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# Extract one step's whole YAML block (its `- name:` line through the line
# before the next step's), for asserting on the `env:` it declares.
extract_step_block() {
  awk -v want="      - name: $1" '
    !grab && $0 == want { grab=1; print; next }
    grab && /^      - name: / { exit }
    grab { print }
  ' "$WORKFLOW"
}

# Run the extracted step body in the sandbox with the env it reads plus a real
# $GITHUB_OUTPUT. DEFAULT_BRANCH defaults to the sandbox's default branch.
run_self_mod_step() {
  local body="$1" head_sha="$2" default_branch="${3:-main}"
  ( cd "$SANDBOX" \
    && DEFAULT_BRANCH="$default_branch" \
       HEAD_SHA="$head_sha" \
       GITHUB_OUTPUT="$STEP_OUTPUT" \
       bash "$body" )
}

output_has() { grep -qF -- "$1" "$STEP_OUTPUT"; }

# Cut a base branch that edits the audit workflow, off the default branch.
cut_stacked_base() {
  git -C "$SANDBOX" checkout --quiet -b base-branch
  printf '%s\n' "$STACKED_WORKFLOW" > "$SANDBOX/.github/workflows/code-review-audit.yml"
  git -C "$SANDBOX" commit --quiet -am "base branch edits the audit workflow"
  git -C "$SANDBOX" push --quiet origin base-branch
}

@test "a PR stacked on a base that edits the workflow is detected, though its own diff does not touch it" {
  # The false negative the PR-base comparison produced. Base and head carry the
  # same workflow and both differ from the default branch, so a base..head diff
  # sees no workflow change and lets the audit run -- claude-code-action then
  # refuses, the abort path never fires, and the job posts "no fixes needed" for
  # an audit that never happened.
  local body head
  body="$(extract_step_body 'Check workflow self-modification')"
  cut_stacked_base
  git -C "$SANDBOX" checkout --quiet -b pr-head
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" commit --quiet -am "head changes source only"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_self_mod_step "$body" "$head"
  [ "$status" -eq 0 ]
  output_has "self_modified=true"
}

@test "a PR whose head matches the default branch is not blamed for its base's workflow edit" {
  # The false positive the PR-base comparison produced. The base edited the
  # workflow and the head restores the default branch's copy, so a base..head
  # diff reports a workflow change and skips the audit citing an edit this PR's
  # author never made.
  local body head
  body="$(extract_step_body 'Check workflow self-modification')"
  cut_stacked_base
  git -C "$SANDBOX" checkout --quiet -b pr-head
  printf '%s\n' "$DEFAULT_WORKFLOW" > "$SANDBOX/.github/workflows/code-review-audit.yml"
  git -C "$SANDBOX" commit --quiet -am "head restores the default branch workflow"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_self_mod_step "$body" "$head"
  [ "$status" -eq 0 ]
  output_has "self_modified=false"
}

@test "a PR that genuinely edits the audit workflow is detected" {
  local body head
  body="$(extract_step_body 'Check workflow self-modification')"
  git -C "$SANDBOX" checkout --quiet -b pr-head
  printf '%s\n' "$PR_WORKFLOW" > "$SANDBOX/.github/workflows/code-review-audit.yml"
  git -C "$SANDBOX" commit --quiet -am "head edits the audit workflow"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_self_mod_step "$body" "$head"
  [ "$status" -eq 0 ]
  output_has "self_modified=true"
}

@test "a PR touching only source, on an unstacked base, leaves the audit running" {
  local body head
  body="$(extract_step_body 'Check workflow self-modification')"
  git -C "$SANDBOX" checkout --quiet -b pr-head
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" commit --quiet -am "head changes source only"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_self_mod_step "$body" "$head"
  [ "$status" -eq 0 ]
  output_has "self_modified=false"
}

@test "an unresolvable default-branch ref fails the step instead of guessing" {
  # Either answer would be a lie: false runs an audit the action may refuse and
  # reports it complete; true skips citing an edit nobody can confirm.
  local body head
  body="$(extract_step_body 'Check workflow self-modification')"
  git -C "$SANDBOX" checkout --quiet -b pr-head
  echo "export const x = 2;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" commit --quiet -am "head changes source only"
  head="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_self_mod_step "$body" "$head" "no-such-default-branch"
  [ "$status" -ne 0 ]
  grep -qF 'origin/no-such-default-branch' <<<"$output"
  [ ! -s "$STEP_OUTPUT" ]
}

@test "the comparison ref is the default branch, and the PR base sha is gone from the step" {
  # Pins the ref itself. Both failure modes above are invisible in the step's
  # `if:` expression and in its output contract, so nothing else in the suite
  # notices the comparison quietly reverting to the PR's own base.
  local block
  block="$(extract_step_block 'Check workflow self-modification')"
  grep -qF 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' <<<"$block"
  grep -qF 'origin/${DEFAULT_BRANCH}' <<<"$block"
  grep -qF 'github.event.pull_request.base.sha' <<<"$block" && return 1
  grep -qF 'BASE_SHA' <<<"$block" && return 1
  true
}

@test "the skipped status names the default-branch mismatch and points at a rebase" {
  # A PR on a stale base trips this step without touching the workflow, so the
  # operator-facing reason has to name the real condition rather than assert an
  # edit the author never made.
  local block
  block="$(extract_step_block 'Status - skipped (workflow self-modification)')"
  grep -qF 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' <<<"$block"
  grep -qF 'rebase onto ${DEFAULT_BRANCH}' <<<"$block"
  grep -qF 'PR modifies the audit workflow itself' <<<"$block" && return 1
  true
}
