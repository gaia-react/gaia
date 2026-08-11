#!/usr/bin/env bats

# Tests for .claude/hooks/check-i18n-strings.sh.
#
# Advisory PreToolUse nudge: when a page or component .tsx is written, remind
# once per session that user-facing strings belong behind t(). It blocks
# nothing -- it always exits 0 and carries its whole payload on stderr -- so
# there is no deny to assert. What CAN break is the reminder firing on the
# wrong files, firing on every edit instead of once, or going silent entirely,
# and each of those is invisible in normal use. The tests below pin all three.
#
# The once-per-session marker (.claude/i18n-strings-checked) is written
# relative to the working directory, so every scenario runs in a throwaway
# directory via `invoke_hook_in` rather than in the repo.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/check-i18n-strings.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  WORK=$(mktemp -d -t gaia-i18n-hook-XXXXXX)
  MARKER="$WORK/.claude/i18n-strings-checked"
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $WORK to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

run_hook_edit() {
  local path="$1" session="$2"
  local json
  json=$(jq -n --arg p "$path" --arg s "$session" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Edit", tool_input: {file_path: $p}}')
  invoke_hook_in "$WORK" "$json" "$HOOK_ABS"
}

# --- the reminder fires on a page or component .tsx ---

@test "a page .tsx write emits the reminder and records the session" {
  run_hook_edit "app/pages/Public/HomePage/index.tsx" S1
  [ "$status" -eq 0 ]
  grep -qF -- "t() from useTranslation()" <<<"$output"
  [ -f "$MARKER" ]
  grep -qF -- "session_id=S1" "$MARKER"
}

@test "a component .tsx write emits the reminder" {
  run_hook_edit "app/components/Button/index.tsx" S1
  [ "$status" -eq 0 ]
  grep -qF -- "t() from useTranslation()" <<<"$output"
}

@test "a nested component .tsx write emits the reminder" {
  run_hook_edit "app/components/Form/Field/index.tsx" S1
  [ "$status" -eq 0 ]
  grep -qF -- "t() from useTranslation()" <<<"$output"
}

@test "an absolute path under app/pages still emits the reminder" {
  run_hook_edit "/Users/you/projects/my-app/app/pages/Public/HomePage/index.tsx" S1
  [ "$status" -eq 0 ]
  grep -qF -- "t() from useTranslation()" <<<"$output"
}

# --- once per session, then silent ---

@test "a second write in the same session is silent" {
  run_hook_edit "app/pages/Public/HomePage/index.tsx" S1
  [ -n "$output" ]

  run_hook_edit "app/components/Button/index.tsx" S1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a write in a NEW session emits again and re-records the session" {
  run_hook_edit "app/pages/Public/HomePage/index.tsx" S1
  [ -n "$output" ]

  run_hook_edit "app/pages/Public/HomePage/index.tsx" S2
  [ "$status" -eq 0 ]
  grep -qF -- "t() from useTranslation()" <<<"$output"
  grep -qF -- "session_id=S2" "$MARKER"
}

# --- silent on everything outside the watched surface ---

@test "a non-tsx file under app/components is a silent no-op" {
  run_hook_edit "app/components/Button/index.ts" S1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$MARKER" ]
}

@test "a .tsx outside app/pages and app/components is a silent no-op" {
  run_hook_edit "app/routes/_public+/home.tsx" S1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$MARKER" ]
}

@test "a service file is a silent no-op" {
  run_hook_edit "app/services/gaia/users/requests.ts" S1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- degenerate payloads never block and never write a marker ---

@test "a watched path with no session_id is a silent no-op" {
  # Without a session the once-per-session contract cannot be honored, so the
  # hook declines rather than nagging on every single edit.
  local json
  json=$(jq -n '{tool_name: "Edit", tool_input: {file_path: "app/pages/Public/HomePage/index.tsx"}}')
  invoke_hook_in "$WORK" "$json" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$MARKER" ]
}

@test "a payload with no file_path is a silent no-op" {
  invoke_hook_in "$WORK" '{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"ls"}}' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed JSON on stdin never blocks the edit" {
  # The contract, not the mechanism: a payload-shape change must never turn an
  # advisory nudge into a failed tool call. Two independent guards uphold it --
  # the jq reads absorb their own failure, and an ERR trap catches whatever
  # they miss -- so this asserts the outcome rather than either one of them.
  # Removing both is what reddens it.
  invoke_hook_in "$WORK" 'not json' "$HOOK_ABS"
  [ "$status" -eq 0 ]
}

# --- structural ---

@test "check-i18n-strings.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/check-i18n-strings.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
