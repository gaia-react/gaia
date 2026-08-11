#!/usr/bin/env bats

# Tests for .claude/hooks/check-story-exists.sh.
#
# Advisory PreToolUse nudge: when a component's index.tsx is written and no
# sibling tests/index.stories.tsx exists, remind that the story is missing. It
# blocks nothing and always exits 0, so its only observable behavior is the
# stderr line -- which means a break is silent, and the reminder simply stops
# arriving for every component written from then on.
#
# Unlike its i18n sibling this hook has no session marker: it fires on every
# qualifying write and goes quiet the moment the story exists. The existence
# check resolves relative to the working directory, so every scenario runs in a
# throwaway directory via `invoke_hook_in`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/check-story-exists.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  WORK=$(mktemp -d -t gaia-story-hook-XXXXXX)
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $WORK to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

run_hook_edit() {
  local path="$1"
  local json
  json=$(jq -n --arg p "$path" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $p}}')
  invoke_hook_in "$WORK" "$json" "$HOOK_ABS"
}

# --- the reminder fires when the story is missing ---

@test "a component index.tsx with no story emits the reminder" {
  run_hook_edit "app/components/Button/index.tsx"
  [ "$status" -eq 0 ]
  grep -qF -- "Consider adding a Storybook story" <<<"$output"
}

@test "the reminder names the exact path the story belongs at" {
  # A nudge that does not spell the destination leaves the reader to rederive
  # the tests/ convention, which is the whole thing it exists to carry.
  run_hook_edit "app/components/Button/index.tsx"
  [ "$status" -eq 0 ]
  grep -qF -- "app/components/Button/tests/index.stories.tsx" <<<"$output"
}

# --- silent once the story exists ---

@test "a component index.tsx with a story present is silent" {
  mkdir -p "$WORK/app/components/Button/tests"
  : > "$WORK/app/components/Button/tests/index.stories.tsx"
  run_hook_edit "app/components/Button/index.tsx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a story under the wrong sibling name does not satisfy the check" {
  # tests/index.stories.tsx is the convention; a story parked anywhere else is
  # not the file the scaffolding and the audit tooling look for.
  mkdir -p "$WORK/app/components/Button/tests"
  : > "$WORK/app/components/Button/tests/Button.stories.tsx"
  run_hook_edit "app/components/Button/index.tsx"
  [ "$status" -eq 0 ]
  grep -qF -- "Consider adding a Storybook story" <<<"$output"
}

# --- silent on everything outside the watched surface ---

@test "a component file that is not index.tsx is a silent no-op" {
  run_hook_edit "app/components/Button/styles.tsx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a page index.tsx is a silent no-op" {
  run_hook_edit "app/pages/Public/HomePage/index.tsx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a component test file is a silent no-op" {
  run_hook_edit "app/components/Button/tests/index.test.tsx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a nested component directory is outside the guard's single-segment reach" {
  # The path test allows exactly one segment between app/components/ and
  # index.tsx, so a nested component gets no nudge. Pinned as the guard's
  # current reach, not as desired behavior.
  run_hook_edit "app/components/Form/Field/index.tsx"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- degenerate payloads never block ---

@test "a payload with no file_path is a silent no-op" {
  invoke_hook_in "$WORK" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed JSON on stdin never blocks the write" {
  invoke_hook_in "$WORK" 'not json' "$HOOK_ABS"
  [ "$status" -eq 0 ]
}

# --- structural ---

@test "check-story-exists.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/check-story-exists.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
