#!/usr/bin/env bats

# Tests for .claude/hooks/block-invalid-pr-title.sh, the PreToolUse guard that
# runs CI's PR title lint (commitlint on "<title> (#<number>)") before a
# `gh pr create` or `gh pr edit` reaches GitHub. Exit 2 = block, 0 = allow.
#
# The length boundary is driven through `gh pr edit <N>`, whose number the hook
# takes from the command, so the 100-character edge is exact whatever the
# repository's PR count is. Every deny is paired with an allow one character
# (or one spelling) away, so a hook that blocks everything or nothing fails.
#
# Lives beside the other commitlint suites because it runs the REAL commitlint
# binary, which only the commitlint leg of .github/workflows/audit-ci-tests.yml
# installs. A missing commitlint FAILS setup_file rather than skipping.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup_file() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  if [ ! -x "$REPO_ROOT/node_modules/.bin/commitlint" ]; then
    printf 'commitlint is not installed at %s: run pnpm install\n' \
      "$REPO_ROOT/node_modules/.bin/commitlint" >&3
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required\n' >&3
    return 1
  }
}

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK="$REPO_ROOT/.claude/hooks/block-invalid-pr-title.sh"
  # shellcheck source=../helpers/hook-registration.sh
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  SCRATCH=""
}

teardown() {
  if [ -n "${SCRATCH:-}" ]; then
    rm -rf "$SCRATCH"
  fi
  return 0
}

# title_of_length <n>: a valid `feat: ` title exactly n characters long.
title_of_length() {
  local padding_length=$(($1 - 6)) padding
  padding=$(printf '%*s' "$padding_length" '' | tr ' ' a)
  printf 'feat: %s' "$padding"
}

run_hook() {
  local payload
  payload=$(jq -nc --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "${2:-$HOOK}"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the length boundary: title + " (#2570)" against the 100 limit -----------

@test "a 93-character title with a 4-digit number is blocked" {
  run_hook "gh pr edit 2570 --title \"$(title_of_length 93)\""
  assert_blocked
  grep -qF -- 'current length is 101' <<<"$output"
}

@test "a 92-character title with a 4-digit number is allowed" {
  run_hook "gh pr edit 2570 --title \"$(title_of_length 92)\""
  assert_allowed
}

@test "the denial shows the subject it checked, suffix included" {
  run_hook "gh pr edit 2570 --title \"$(title_of_length 93)\""
  grep -qF -- "Checked as: $(title_of_length 93) (#2570)" <<<"$output"
}

# --- the rest of the lint, not only length ------------------------------------

@test "a title with an unknown type is blocked" {
  run_hook 'gh pr create --title "bogus: do a thing" --body x'
  assert_blocked
  grep -qF -- 'type-enum' <<<"$output"
}

@test "a short conventional title is allowed on create" {
  run_hook 'gh pr create --title "feat(hooks): add a guard" --body x'
  assert_allowed
}

@test "a title far past the limit is blocked on create" {
  run_hook "gh pr create --title \"$(title_of_length 120)\" --body x"
  assert_blocked
}

# --- title spellings ----------------------------------------------------------

@test "-t is read as the title" {
  run_hook "gh pr edit 2570 -t '$(title_of_length 93)'"
  assert_blocked
}

@test "--title= is read as the title" {
  run_hook "gh pr edit 2570 --title=\"$(title_of_length 93)\""
  assert_blocked
}

@test "the last title wins, as in gh" {
  run_hook "gh pr edit 2570 --title \"$(title_of_length 93)\" --title \"feat: short\""
  assert_allowed
}

@test "a PR URL supplies the number on edit" {
  run_hook "gh pr edit https://github.com/o/r/pull/2570 --title \"$(title_of_length 92)\""
  assert_allowed
}

# --- where the command sits in the tool call ----------------------------------

@test "a create after git push && is read" {
  run_hook "git push -u origin feat/x && gh pr create --title \"$(title_of_length 120)\" --body-file b"
  assert_blocked
}

@test "a create on the line after a comment is read" {
  run_hook $'# open the PR\ngh pr create --title "bogus: x"'
  assert_blocked
}

@test "a create inside a heredoc body is data, not a command" {
  run_hook $'cat > notes.md <<\'EOF\'\ngh pr create --title "bogus: x"\nEOF'
  assert_allowed
}

@test "a create inside a --body substitution is data" {
  run_hook $'gh pr create --title "feat: x" --body "$(cat <<\'EOF\'\ngh pr create --title "bogus: y"\nEOF\n)"'
  assert_allowed
}

@test "a quoted mention of the verb is not a command" {
  run_hook "echo 'gh pr create --title \"bogus: x\"'"
  assert_allowed
}

# --- what is left to CI -------------------------------------------------------

@test "a title the shell expands is allowed" {
  run_hook 'gh pr create --title "$(git log -1 --format=%s)" --body x'
  assert_allowed
}

@test "a PR in another repository is allowed" {
  run_hook "gh pr create -R other/repo --title \"$(title_of_length 120)\" --body x"
  assert_allowed
}

@test "other gh pr verbs are allowed" {
  run_hook 'gh pr view 12 --json title'
  assert_allowed
}

@test "a Monitor call stands down" {
  local payload
  payload=$(jq -nc '{tool_name: "Monitor", tool_input: {command: "gh pr create --title \"bogus: x\""}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
  assert_allowed
}

@test "with no commitlint installed the hook allows, and blocks the same call with it" {
  local title
  title=$(title_of_length 120)
  run_hook "gh pr create --title \"$title\" --body x"
  assert_blocked
  SCRATCH=$(mktemp -d -t pr-title-hook-XXXXXX)
  mkdir -p "$SCRATCH/.claude/hooks"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$SCRATCH/.claude/hooks/lib"
  cp "$HOOK" "$SCRATCH/.claude/hooks/"
  run_hook "gh pr create --title \"$title\" --body x" "$SCRATCH/.claude/hooks/block-invalid-pr-title.sh"
  assert_allowed
}

@test "a commitlint that cannot run is allowed, one that reports problems is blocked" {
  SCRATCH=$(mktemp -d -t pr-title-hook-XXXXXX)
  mkdir -p "$SCRATCH/.claude/hooks" "$SCRATCH/node_modules/.bin"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$SCRATCH/.claude/hooks/lib"
  cp "$HOOK" "$SCRATCH/.claude/hooks/"
  local scratch_hook="$SCRATCH/.claude/hooks/block-invalid-pr-title.sh"
  local stub="$SCRATCH/node_modules/.bin/commitlint"
  printf '#!/bin/sh\necho "env: node: No such file or directory" >&2\nexit 127\n' >"$stub"
  chmod +x "$stub"
  run_hook 'gh pr create --title "feat: ok" --body x' "$scratch_hook"
  assert_allowed
  printf '#!/bin/sh\necho "found 1 problems, 0 warnings"\nexit 1\n' >"$stub"
  run_hook 'gh pr create --title "feat: ok" --body x' "$scratch_hook"
  assert_blocked
}

# --- --fill -------------------------------------------------------------------

@test "--fill without a title is blocked" {
  run_hook 'gh pr create --fill'
  assert_blocked
  grep -qF -- '--title' <<<"$output"
}

@test "--fill with a title is checked on the title and allowed" {
  run_hook 'gh pr create --fill --title "feat: ok"'
  assert_allowed
}

# --- registration -------------------------------------------------------------

@test "the hook is registered on the PreToolUse Bash|Monitor matcher" {
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-invalid-pr-title.sh
}

# --- the one-jq payload reader ---

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'gh pr create --title bad' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/block-invalid-pr-title.sh"
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-invalid-pr-title.sh cannot load lib/hook-payload.sh' <<<"$output"
}

@test "a non-arming Bash payload spawns exactly one jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-invalid-pr-title.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}
