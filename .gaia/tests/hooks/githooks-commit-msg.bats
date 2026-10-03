#!/usr/bin/env bats

# Tests for .githooks/commit-msg.
#
# The hook hands the commit message file to commitlint and refuses the commit
# when commitlint rejects it or cannot run at all. A guard that silently passes
# when its tool is missing reports clean having checked nothing, so the
# missing-tool case is its own refusal.
#
# Git runs the hook directly through core.hooksPath, so these tests run it
# directly too.
#
# `pnpm` is stubbed onto PATH, so the suite needs no node_modules and runs
# anywhere. The stub answers the `--version` probe and the `--edit` run with
# exit codes the test sets, and records every argv. Real commitlint behavior is
# commitlint-config.bats.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.githooks/commit-msg"

  # Physical path: the hook takes its root from `git rev-parse --show-toplevel`,
  # which resolves symlinks (macOS /var is a link to /private/var).
  SANDBOX=$(cd "$(mktemp -d -t githooks-commit-msg-XXXXXX)" && pwd -P)
  git -C "$SANDBOX" init --quiet --initial-branch=main

  MESSAGE_FILE="$SANDBOX/COMMIT_EDITMSG"
  printf 'feat: add a thing\n' > "$MESSAGE_FILE"

  PNPM_LOG="$SANDBOX/pnpm.log"
  STUB_BIN="$SANDBOX/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
case " $* " in
  *" --version "*) exit "${STUB_VERSION_EXIT:-0}" ;;
  *" --edit "*) exit "${STUB_EDIT_EXIT:-0}" ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
  : > "$PNPM_LOG"
}

teardown() {
  rm -rf "$SANDBOX"
}

# Runs the hook $1 (default: the real one) from the sandbox repo, as git does.
run_hook() {
  local hook="${1:-$HOOK_ABSOLUTE_PATH}"
  cd "$SANDBOX" || return 1
  PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" run "$hook" "$MESSAGE_FILE"
}

# Succeeds only when the stub recorded an `--edit` call that carries the
# message file path, the argument the whole hook exists to pass through.
edit_argument_was_recorded() {
  grep -qF -- "--edit $MESSAGE_FILE" "$PNPM_LOG"
}

@test "commit-msg: REFUSES when commitlint rejects the message, and names the convention page" {
  STUB_EDIT_EXIT=1 run_hook
  [ "$status" -ne 0 ]
  [[ "$output" == *"wiki/decisions/Naming Conventions.md"* ]]
}

@test "commit-msg: passes when commitlint accepts, and hands it the message file" {
  run_hook
  [ "$status" -eq 0 ]
  edit_argument_was_recorded
}

@test "commit-msg: REFUSES and names pnpm install when commitlint cannot run" {
  STUB_VERSION_EXIT=1 run_hook
  [ "$status" -ne 0 ]
  [[ "$output" == *"pnpm install"* ]]
}

@test "commit-msg: a missing commitlint never reaches the --edit run" {
  STUB_VERSION_EXIT=1 run_hook
  [ "$status" -ne 0 ]
  grep -qF -- "--edit" "$PNPM_LOG" && return 1
  true
}

@test "commit-msg: the pass-through assertion can fail (hook with the argument dropped)" {
  local broken_hook="$SANDBOX/commit-msg-broken"
  sed 's/--edit "\$1"/--edit/' "$HOOK_ABSOLUTE_PATH" > "$broken_hook"
  # The mutation must have changed the hook, or this twin proves nothing.
  cmp -s "$HOOK_ABSOLUTE_PATH" "$broken_hook" && return 1
  # Git runs the hook directly, so the copy needs the executable bit.
  chmod +x "$broken_hook"

  run_hook "$broken_hook"
  [ "$status" -eq 0 ]
  edit_argument_was_recorded && return 1
  true
}
