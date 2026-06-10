#!/usr/bin/env bats

# Tests for .claude/hooks/block-bare-test.sh.
#
# The hook blocks a bare `pnpm test` / `npm test` (and `run test` variant)
# without `--run`, those start vitest in watch mode and never exit in an agent
# context. A `--run` flag opts out (one-shot). Exit 2 = block (stderr shown to
# Claude); exit 0 = allow.
#
# The hook is a pure stdin->pattern->exit filter: it sources no lib and needs no
# git repo, so each test just pipes a synthetic PreToolUse JSON payload and
# asserts on the exit code (and, for blocks, the BLOCKED message on stderr).
#
# The matcher is command-position anchored (it splits on `| & ; ( )`, strips
# leading env-var prefixes, and acts only when `pnpm`/`npm` is the resulting
# command word), so the words appearing inside a quoted commit message or a
# `--body` string are NOT an invocation and must pass. The prose-mention cases
# below are the regression guard for the false positive that motivated the
# anchor: a `gh pr create --body "...pnpm test --run..."` and a
# `git commit -m "...pnpm test..."` were being denied.

setup() {
  HOOK=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/block-bare-test.sh
}

# Pipe a Bash PreToolUse payload for $1 to the hook and capture status/output.
run_hook() {
  local cmd="$1" payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "printf '%s' '$payload' | bash '$HOOK'"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- blocked: a real bare invocation starts watch mode ------------------------

@test "(a) bare pnpm test is blocked" {
  run_hook 'pnpm test'
  assert_blocked
}

@test "bare npm test is blocked" {
  run_hook 'npm test'
  assert_blocked
}

@test "bare pnpm run test is blocked" {
  run_hook 'pnpm run test'
  assert_blocked
}

@test "(e) env-prefixed FOO=bar pnpm test is blocked" {
  run_hook 'FOO=bar pnpm test'
  assert_blocked
}

@test "pnpm test after a separator is blocked (command position, not prose)" {
  run_hook 'echo hi && pnpm test'
  assert_blocked
}

@test "pnpm test inside a command substitution is blocked (it would run)" {
  run_hook 'echo $(pnpm test)'
  assert_blocked
}

# --- allowed: --run opts out of watch mode ------------------------------------

@test "(b) pnpm test --run <scope> is allowed" {
  run_hook 'pnpm test --run app/x'
  assert_allowed
}

@test "pnpm run test --run is allowed" {
  run_hook 'pnpm run test --run'
  assert_allowed
}

# --- allowed: prose mentions are not invocations (the fixed false positives) --

@test "(c) gh pr create --body mentioning pnpm test --run is allowed" {
  run_hook 'gh pr create --body "see `pnpm test --run` output"'
  assert_allowed
}

@test "(d) git commit -m mentioning pnpm test is allowed" {
  run_hook 'git commit -m "run pnpm test later"'
  assert_allowed
}

@test "git commit -m mentioning bare pnpm test (no --run) is allowed" {
  run_hook 'git commit -m "remember to run pnpm test"'
  assert_allowed
}

@test "echo of the phrase into a file is allowed" {
  run_hook 'echo "pnpm test" > notes.txt'
  assert_allowed
}

# --- allowed: the test: carve-out (a package script that exits on its own) ----

@test "(f) pnpm test:ci is allowed (test: token, not bare test)" {
  run_hook 'pnpm test:ci'
  assert_allowed
}

@test "(g) pnpm run test:lint-staged is allowed" {
  run_hook 'pnpm run test:lint-staged'
  assert_allowed
}

# --- allowed: unrelated commands ----------------------------------------------

@test "pnpm typecheck is allowed" {
  run_hook 'pnpm typecheck'
  assert_allowed
}

@test "an empty command is allowed" {
  run_hook ''
  assert_allowed
}
