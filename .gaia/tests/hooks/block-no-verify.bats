#!/usr/bin/env bats

# Tests for .claude/hooks/block-no-verify.sh.
#
# The hook denies `git commit` / `git push` carrying a hook bypass so the
# Quality Gate floor (typecheck / lint / test, run by the Husky pre-commit
# hook) cannot be skipped. Bypass tokens: --no-verify, `-n` (commit only
# `push -n` is --dry-run), a falsy HUSKY= env prefix, and a `-c
# core.hooksPath=` override. Foreign-repo commands pass via the shared
# repo-scope helper.
#
# Each test drives the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the repo as the working directory (the hook loads
# .claude/hooks/lib/repo-scope.sh relative to cwd, so the helper is copied into
# the tmp repo). The hook always exits 0; allow vs deny is carried in stdout
# a deny emits `"permissionDecision": "deny"`, an allow emits nothing. The
# deny cases double as a jq/setup canary: a missing jq would exit early with no
# output and those assertions would fail rather than false-pass.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-no-verify.sh"

  REPO=$(mktemp -d -t no-verify-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  git -C "$REPO" checkout --quiet -b feature

  # The hook sources the repo-scope helper relative to cwd; give the tmp repo
  # a real copy so the foreign-repo bypass resolves.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOKS_SRC/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t no-verify-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

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

@test "git commit --no-verify is denied" {
  run_hook 'git commit --no-verify -m "x"'
  assert_denied
}

@test "git commit -n is denied" {
  run_hook 'git commit -n -m "x"'
  assert_denied
}

@test "git commit with bundled short flags -anm is denied" {
  run_hook 'git commit -anm "x"'
  assert_denied
}

@test "HUSKY=0 git commit is denied" {
  run_hook 'HUSKY=0 git commit -m "x"'
  assert_denied
}

@test "git -c core.hooksPath=/dev/null commit is denied" {
  run_hook 'git -c core.hooksPath=/dev/null commit -m "x"'
  assert_denied
}

@test "git push --no-verify is denied" {
  run_hook 'git push --no-verify'
  assert_denied
}

@test "HUSKY=0 git push is denied" {
  run_hook 'HUSKY=0 git push origin feature'
  assert_denied
}

# --- allowed ---

@test "plain git commit on a feature branch is allowed" {
  run_hook 'git commit -m "x"'
  assert_allowed
}

@test "git push -n (dry-run) is allowed" {
  run_hook 'git push -n origin feature'
  assert_allowed
}

@test "git push --dry-run is allowed" {
  run_hook 'git push --dry-run origin feature'
  assert_allowed
}

@test "plain git push on a feature branch is allowed" {
  run_hook 'git push origin feature'
  assert_allowed
}

@test "HUSKY=1 git commit is allowed (enabling is not a bypass)" {
  run_hook 'HUSKY=1 git commit -m "x"'
  assert_allowed
}

@test "home-repo git -C commit (no bypass) is allowed" {
  # Capital -C changes directory; it is not a bypass. The home repo's own
  # `git -C <home> commit` must pass; only lowercase `-c core.hooksPath=`
  # (the next test) carries a bypass.
  run_hook "git -C $REPO commit -m \"x\""
  assert_allowed
}

@test "foreign-repo commit with a bypass is allowed (out of scope)" {
  run_hook "git -C $FOREIGN commit --no-verify -m \"x\""
  assert_allowed
}

@test "a non-commit/push git command with a hooksPath override is ignored" {
  run_hook 'git -c core.hooksPath=/dev/null status'
  assert_allowed
}

@test "a non-git command is ignored" {
  run_hook 'pnpm run build'
  assert_allowed
}

# --- command-position anchoring: the words appear, but git is not the program ---

@test "grep with -n searching for the text 'git commit' is allowed" {
  # The reported false positive: -n belongs to grep, 'git commit' is the search
  # pattern. git is not in command position, so nothing fires.
  run_hook 'grep -n -e git commit app/foo.ts'
  assert_allowed
}

@test "echo of 'git commit' piped to grep -n is allowed" {
  run_hook 'echo git commit && grep -n foo bar'
  assert_allowed
}

@test "real git commit followed by grep -n is allowed (-n is grep's)" {
  # -n is scoped to the git segment; the grep on the other side of && is inert.
  run_hook 'git commit -m "x" && grep -n foo bar'
  assert_allowed
}

@test "tail -n over a file path containing 'commit' is allowed" {
  run_hook 'tail -n 5 git-commit-notes.txt'
  assert_allowed
}

# --- command-position anchoring still catches real bypasses ---

@test "git commit -n after an unrelated piped command is denied" {
  run_hook 'echo hi | git commit -n -m "x"'
  assert_denied
}

@test "bypass orphaned by a pipe inside the commit message is still denied" {
  # Segment-splitting on the quoted '|' would orphan --no-verify from its git
  # segment; the whole-command safety net re-asserts it.
  run_hook 'git commit -m "a|b" --no-verify'
  assert_denied
}
