#!/usr/bin/env bats
# Tests for `.claude/hooks/debt-sentinel-touch.sh`, the PostToolUse Bash hook
# that arms the debt-count staleness sentinel after a debt-count-mutating `gh`
# command (`gh issue create` / `gh pr merge` / `gh issue close` / `gh issue
# reopen`). Arming the sentinel makes the open `tech-debt` count recompute on the
# next statusline tick instead of waiting on the refresher's 6h TTL.
#
# Each test runs the hook inside a throwaway git repo (the hook writes the
# sentinel relative to CWD and reads `.claude/hooks/lib/repo-scope.sh` relative to
# CWD; the tmp repo omits that lib, so the repo-scope guard is skipped and a
# matching command proceeds).

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/debt-sentinel-touch.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"
  SENTINEL_REL=".gaia/local/debt/refresh-requested"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

# run_hook <command>: feed a PostToolUse Bash payload carrying <command> to the
# hook, from inside a fresh tmp repo. Leaves $REPO set for assertions.
run_hook() {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  local input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1")
  run bash -c "printf '%s' '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
}

assert_armed() { [ -f "$REPO/$SENTINEL_REL" ]; }
assert_not_armed() { [ ! -f "$REPO/$SENTINEL_REL" ]; }

@test "gh issue create arms the sentinel" {
  run_hook 'gh issue create --label tech-debt --label severity:suggestion --body-file /tmp/b.md'
  assert_armed
}

@test "gh issue close arms the sentinel" {
  run_hook 'gh issue close 590'
  assert_armed
}

@test "gh issue reopen arms the sentinel" {
  run_hook 'gh issue reopen 590'
  assert_armed
}

@test "gh pr merge still arms the sentinel (regression)" {
  run_hook 'gh pr merge 42 --auto --squash'
  assert_armed
}

@test "arms after a shell separator" {
  run_hook 'git status && gh issue close 590'
  assert_armed
}

@test "non-Bash tool: no-op, not armed" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  input=$(jq -n '{tool_name:"Edit",tool_input:{file_path:"x"}}')
  run bash -c "printf '%s' '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  assert_not_armed
}

@test "gh issue view: non-mutating, not armed" {
  run_hook 'gh issue view 590'
  assert_not_armed
}

@test "gh issue list: non-mutating, not armed" {
  run_hook 'gh issue list --label tech-debt --state open'
  assert_not_armed
}

@test "gh pr create: not a merge, not armed" {
  run_hook 'gh pr create --title x --body y'
  assert_not_armed
}

@test "close mentioned inside a --body string is not a real invocation" {
  run_hook 'gh pr create --body "remember to gh issue close 590 later"'
  assert_not_armed
}
