#!/usr/bin/env bats
#
# End-to-end proof of the worktree branch rename in
# .claude/skills/gaia/references/isolation.md (`## Worktree creation`): the
# harness cuts `worktree-<name with / as +>`, GAIA renames it to the canonical
# name straight away, and from then on local branch, remote branch, and PR head
# are one spelling.
#
# What it proves, in the section order below:
#   1. the rename leaves the worktree on the canonical branch, and the lib
#      classifies it
#   2. a plain `push -u` creates the canonical remote ref (no `worktree-*` ref)
#      and a later refspec-less `push` updates it
#   3. an argument-less PR lookup keyed on the current branch resolves
#   4. every one of those fails without the rename (can-fail twins)
#   5. `git worktree remove` leaves the renamed branch behind, and the
#      cleanup's `show-ref` plus `branch -D` is what removes it
#   6. the resume lookup input: `git worktree list --porcelain`
#   7. `block-main-destructive-git.sh` allows the rename from a worktree, and
#      still denies a commit on main (the hook is live in this scratch repo)
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/worktree-rename.bats
#
# Every expected value is a literal, so a regression in the flow cannot be
# mirrored by the assertion that checks it. The scratch repos live in
# $BATS_TEST_TMPDIR; nothing here touches the real checkout.

bats_require_minimum_version 1.5.0

WORKTREE_SPELLING='worktree-plan+plan-1-x'
CANONICAL='plan/plan-1-x'

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/block-main-destructive-git.sh"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  MAIN="$BATS_TEST_TMPDIR/main"
  WORKTREE="$BATS_TEST_TMPDIR/main/.claude/worktrees/$WORKTREE_SPELLING"

  git init --quiet --bare --initial-branch=main "$ORIGIN"
  git clone --quiet "$ORIGIN" "$MAIN" 2>/dev/null
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" checkout --quiet -b main
  printf '# readme\n' >"$MAIN/README.md"
  printf '.claude/worktrees/\n' >"$MAIN/.gitignore"
  git -C "$MAIN" add README.md .gitignore
  git -C "$MAIN" commit --quiet -m 'chore: init'
  git -C "$MAIN" push --quiet -u origin main

  # What EnterWorktree does: a worktree on `worktree-<name with / as +>`.
  git -C "$MAIN" worktree add --quiet -b "$WORKTREE_SPELLING" "$WORKTREE"

  # The stub gh answers `pr view` with no argument only when the worktree's
  # current branch is the PR head, the way gh resolves "this branch's PR".
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIRECTORY"
  cat >"$STUB_DIRECTORY/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = view ] && [ "$#" -eq 2 ]; then
  current="$(git branch --show-current)"
  if [ "$current" = "$RECORDED_PR_HEAD" ]; then
    printf 'PR #7 head %s\n' "$current"
    exit 0
  fi
  printf 'no pull requests found for branch "%s"\n' "$current" >&2
  exit 1
fi
exit 2
STUB
  chmod +x "$STUB_DIRECTORY/gh"
}

# commit_in_worktree <file>: one more commit on the worktree's branch.
commit_in_worktree() {
  printf '%s\n' "$1" >"$WORKTREE/$1"
  git -C "$WORKTREE" add "$1"
  git -C "$WORKTREE" commit --quiet -m "chore: add $1"
}

# apply_reference_rename: the isolation reference's exact plain commands, each
# value read by one command and typed into the next as a literal.
apply_reference_rename() {
  run git -C "$WORKTREE" rev-parse --show-toplevel
  [ "$status" -eq 0 ]
  run git -C "$WORKTREE" branch --show-current
  [ "$status" -eq 0 ]
  [ "$output" = "$WORKTREE_SPELLING" ]
  git -C "$WORKTREE" branch -m 'worktree-plan+plan-1-x' 'plan/plan-1-x'
}

# pr_lookup: the stubbed argument-less `gh pr view`, run from the worktree.
pr_lookup() {
  (
    cd "$WORKTREE" || exit 99
    PATH="$STUB_DIRECTORY:$PATH" RECORDED_PR_HEAD="$CANONICAL" gh pr view
  )
}

# run_hook <worktree-or-main dir> <command>: drive the guard as the harness does.
run_hook() {
  local payload
  payload="$(jq -n --arg command "$2" --arg directory "$1" \
    '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$1" "$payload" "$HOOK"
}

# --- 1. the rename ---

@test "after the rename the worktree is on the canonical branch" {
  apply_reference_rename
  run git -C "$WORKTREE" branch --show-current
  [ "$status" -eq 0 ]
  [ "$output" = "plan/plan-1-x" ]
}

@test "branch-name-lib classifies the renamed branch as plan plan-1" {
  apply_reference_rename
  run bash "$SCRIPTS_DIRECTORY/branch-name-lib.sh" classify plan/plan-1-x
  [ "$status" -eq 0 ]
  [ "$output" = "plan plan-1" ]
}

@test "a rename onto an existing canonical name fails and leaves the worktree spelling" {
  git -C "$MAIN" branch plan/plan-1-x
  run git -C "$WORKTREE" branch -m 'worktree-plan+plan-1-x' 'plan/plan-1-x'
  [ "$status" -ne 0 ]
  run git -C "$WORKTREE" branch --show-current
  [ "$output" = "worktree-plan+plan-1-x" ]
}

# --- 2. push ---

@test "a plain push -u creates the canonical remote ref and no worktree-* ref" {
  apply_reference_rename
  commit_in_worktree one.txt
  git -C "$WORKTREE" push --quiet -u origin plan/plan-1-x
  run git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'refs/heads/plan/plan-1-x' || return 1
  printf '%s\n' "$output" | grep -qF 'worktree-' && return 1
  true
}

@test "a later refspec-less push (push.default=simple) updates the canonical ref" {
  apply_reference_rename
  commit_in_worktree one.txt
  git -C "$WORKTREE" push --quiet -u origin plan/plan-1-x
  commit_in_worktree two.txt
  git -c push.default=simple -C "$WORKTREE" push --quiet
  run git -C "$ORIGIN" rev-parse refs/heads/plan/plan-1-x
  remote_sha="$output"
  run git -C "$WORKTREE" rev-parse HEAD
  [ "$output" = "$remote_sha" ]
}

# --- 3. PR lookup ---

@test "the argument-less PR lookup resolves after the rename" {
  apply_reference_rename
  run pr_lookup
  [ "$status" -eq 0 ]
  [ "$output" = "PR #7 head plan/plan-1-x" ]
}

# --- 4. can-fail twins: the same flow without the rename ---

@test "twin: without the rename the argument-less PR lookup does not resolve" {
  run pr_lookup
  [ "$status" -ne 0 ]
}

@test "twin: without the rename a refspec-less push after a renamed-remote push -u fails" {
  commit_in_worktree one.txt
  git -C "$WORKTREE" push --quiet -u origin 'worktree-plan+plan-1-x:plan/plan-1-x'
  commit_in_worktree two.txt
  run git -c push.default=simple -C "$WORKTREE" push
  [ "$status" -ne 0 ]
}

@test "twin: the stub itself resolves for the canonical head, so its refusal above is the branch name" {
  apply_reference_rename
  run pr_lookup
  [ "$status" -eq 0 ]
}

# --- 5. post-merge cleanup ---

@test "git worktree remove leaves the renamed branch; show-ref then branch -D removes it" {
  apply_reference_rename
  git -C "$MAIN" worktree remove --force "$WORKTREE"
  run git -C "$MAIN" branch --list plan/plan-1-x
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'plan/plan-1-x' || return 1
  run git -C "$MAIN" show-ref --verify --quiet refs/heads/plan/plan-1-x
  [ "$status" -eq 0 ]
  git -C "$MAIN" branch -D plan/plan-1-x
  run git -C "$MAIN" show-ref --verify --quiet refs/heads/plan/plan-1-x
  [ "$status" -ne 0 ]
  run git -C "$MAIN" branch --list plan/plan-1-x
  [ -z "$output" ]
}

@test "twin: skipping the delete leaves the branch behind" {
  apply_reference_rename
  git -C "$MAIN" worktree remove --force "$WORKTREE"
  run git -C "$MAIN" show-ref --verify --quiet refs/heads/plan/plan-1-x
  [ "$status" -eq 0 ]
}

@test "twin: show-ref exits non-zero once the branch is gone, so the delete is skipped" {
  git -C "$MAIN" worktree remove --force "$WORKTREE"
  git -C "$MAIN" branch -D 'worktree-plan+plan-1-x'
  run git -C "$MAIN" show-ref --verify --quiet refs/heads/plan/plan-1-x
  [ "$status" -ne 0 ]
}

# --- 6. resume lookup input ---

@test "worktree list --porcelain reports the canonical branch for the worktree path" {
  apply_reference_rename
  run git -C "$MAIN" worktree list --porcelain
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk -v path_suffix="/$WORKTREE_SPELLING" '
    /^worktree / { found = (substr($0, length($0) - length(path_suffix) + 1) == path_suffix) }
    found && /^branch refs\/heads\/plan\/plan-1-x$/ { hit = 1 }
    END { exit hit ? 0 : 1 }
  ' || return 1
  true
}

@test "twin: without the rename the porcelain branch field is the worktree spelling" {
  run git -C "$MAIN" worktree list --porcelain
  printf '%s\n' "$output" | grep -qxF 'branch refs/heads/plan/plan-1-x' && return 1
  printf '%s\n' "$output" | grep -qxF 'branch refs/heads/worktree-plan+plan-1-x' || return 1
  true
}

# --- 7. the main-checkout guard ---

@test "block-main-destructive-git allows the rename from a worktree while main is on main" {
  run git -C "$MAIN" branch --show-current
  [ "$output" = "main" ]
  run_hook "$WORKTREE" "git -C $WORKTREE branch -m worktree-plan+plan-1-x plan/plan-1-x"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'deny' && return 1
  true
}

@test "twin: the same guard denies a commit on main in this scratch repo" {
  run_hook "$MAIN" "git -C $MAIN commit -m 'chore: x'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '"permissionDecision":"deny"' || printf '%s' "$output" | grep -qF 'deny' || return 1
  true
}
