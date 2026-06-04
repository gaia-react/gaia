#!/usr/bin/env bats

# Tests for .claude/hooks/block-main-destructive-git.sh.
#
# The hook blocks commits to main/master, force-push to main/master, and any
# plain `git push` originating from main/master (PR-only flow). It fires only on
# a real `git` INVOCATION in command position — command text that merely
# mentions `git commit` / `git push` (a grep pattern, an echo string, an
# argument to another program) does not trip it. Foreign-repo commands pass via
# the shared repo-scope helper.
#
# Each test drives the hook as the harness does: a PreToolUse JSON payload on
# stdin, run with the repo as the working directory (the hook resolves the
# current branch from cwd and loads .claude/hooks/lib/repo-scope.sh relative to
# cwd). The hook always exits 0; allow vs deny is carried in stdout.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-main-destructive-git.sh"

  REPO=$(mktemp -d -t block-main-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # The hook sources the repo-scope helper relative to cwd — give the tmp repo
  # a real copy so the foreign-repo bypass resolves.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOKS_SRC/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t block-main-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

on_main() { git -C "$REPO" checkout --quiet main; }
on_feature() { git -C "$REPO" checkout --quiet -B feature; }

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

assert_denied() {
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

# --- denied ---

@test "git commit on main is denied" {
  on_main
  run_hook 'git commit -m "x"'
  assert_denied
}

@test "plain git push from main is denied" {
  on_main
  run_hook 'git push'
  assert_denied
}

@test "git push origin main (refspec) is denied from a feature branch" {
  on_feature
  run_hook 'git push origin main'
  assert_denied
}

@test "force-push to main is denied from a feature branch" {
  on_feature
  run_hook 'git push --force origin main'
  assert_denied
}

@test "home-repo git -C commit on main is denied" {
  on_main
  run_hook "git -C $REPO commit -m \"x\""
  assert_denied
}

# --- allowed ---

@test "git commit on a feature branch is allowed" {
  on_feature
  run_hook 'git commit -m "x"'
  assert_allowed
}

@test "git push origin feature from a feature branch is allowed" {
  on_feature
  run_hook 'git push origin feature'
  assert_allowed
}

@test "plain git push from a feature branch is allowed" {
  on_feature
  run_hook 'git push'
  assert_allowed
}

@test "foreign-repo commit is allowed even though it targets main" {
  on_main
  run_hook "git -C $FOREIGN commit -m \"x\""
  assert_allowed
}

@test "a non-git command is ignored" {
  on_main
  run_hook 'pnpm run build'
  assert_allowed
}

# --- command-position anchoring: the words appear, but git is not the program ---

@test "grep for the text 'git commit' is allowed on main" {
  on_main
  run_hook 'grep -n -e git commit app/foo.ts'
  assert_allowed
}

@test "echo of 'git push origin main' is allowed on main" {
  on_main
  run_hook 'echo "git push origin main"'
  assert_allowed
}

@test "echo 'git commit' piped to grep is allowed on main" {
  on_main
  run_hook 'echo git commit && grep -n foo bar'
  assert_allowed
}

# --- command-position anchoring still catches real invocations ---

@test "git commit after an unrelated piped command is denied on main" {
  on_main
  run_hook 'echo hi | git commit -m "x"'
  assert_denied
}

@test "git push origin main after && is denied" {
  on_feature
  run_hook 'true && git push origin main'
  assert_denied
}
