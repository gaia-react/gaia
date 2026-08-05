#!/usr/bin/env bash
# Shared harness for the .gaia/tests/hooks bats suites: one quote-safe hook
# invocation, and one assertion pair per deny mechanism.
#
# Source it from `setup()`, never `setup_file()`. bats runs `setup_file` in a
# separate process, so functions defined there are invisible to test bodies:
#
#   setup() {
#     . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
#     HOOK_ABS="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/x.sh"
#   }
#
# A suite keeps its own payload-building wrapper and calls the invocation here
# to deliver it, so `run_hook`-style suite-local names never collide with these.
#
# WHY THE PAYLOAD IS POSITIONAL. `invoke_hook` passes the payload and the hook
# path as arguments to the inner `bash -c`, rather than interpolating them into
# an outer quoted string. Interpolation is not a style choice: a fixture
# carrying a quote of its own terminates the wrapper early and the hook then
# reads a DIFFERENT payload than the one the fixture spells. The hook denies for
# the wrong reason, or never parses the payload at all, and the test greens
# having proved nothing about the case it is named for.
#
# ASSERTION PAIRS ARE NAMED FOR THE MECHANISM, not for the verdict, because the
# suites here test hooks with two incompatible deny contracts. A generic
# `assert_denied` hides which contract is under test, and a suite that picks the
# wrong one asserts against a mechanism its hook never uses.
#
# Every form below is bash-3.2 safe per .claude/rules/bats-assertions.md: `[ ]`
# for status and emptiness, `grep -qF` for a substring, `<positive> && return 1`
# for an absence. A bare `[[ ]]` and a `!`-negation both fail to fail on a
# non-final assertion line.

# invoke_hook PAYLOAD HOOK
# Pipes PAYLOAD to HOOK, capturing status/output through bats' `run`.
invoke_hook() {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$2"
}

# invoke_hook_in DIR PAYLOAD HOOK
# Same, with DIR as the working directory. Hooks that resolve their own
# libraries or repo state relative to cwd need this rather than `invoke_hook`.
invoke_hook_in() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$1" "$2" "$3"
}

# --- mechanism 1: the exit code carries the verdict ------------------------
# The hook blocks by exiting 2 with a BLOCKED message, and allows by exiting 0
# silently. PreToolUse reads exit 2 as a block and shows the message to Claude.
# Under this contract a hook says nothing at all when it allows, so the allow
# assertion is an assertion of silence.

assert_blocked_by_exit() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

assert_allowed_by_exit() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- mechanism 2: JSON on stdout carries the verdict -----------------------
# The hook always exits 0; a deny is a `"permissionDecision": "deny"` field in
# the JSON it writes to stdout, and an allow writes no deny. A suite whose hook
# is additionally silent on an allow asserts that on top of the pair here,
# rather than trading this assertion for that one.

assert_denied_by_json() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed_by_json() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}
