#!/usr/bin/env bats

# Tests for .claude/hooks/block-lockfile-edit.sh.
#
# A lockfile is generated, never hand-written: an edited pnpm-lock.yaml is
# routinely inconsistent with the manifest it claims to lock. The guard denies
# Edit / Write / MultiEdit whose target BASENAME is `pnpm-lock.yaml`, at any
# depth and under any prefix, and abstains on everything else.
#
# WHY THE ABSTAIN CASES CARRY THEIR WEIGHT HERE. This guard's failure mode is
# silent in both directions and the deny is the loud half: the hook always
# exits 0, so a broken match prints nothing, blocks nothing, and lets the edit
# it exists to stop simply succeed. Nothing observable changes. So the deny
# cases below prove the guard fires and the abstain cases prove it is a match
# rather than a blanket, which together make the guard demonstrably able to
# fail rather than assumed working.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-lockfile-edit.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Payload delivery goes through `invoke_hook` (helpers/run-hook.sh) rather than
# an interpolated string, so a fixture path carrying a quote of its own reaches
# the hook as spelled.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  invoke_hook "$json" "$HOOK_ABS"
}

# --- denied: the lockfile itself, by basename, at any depth ---

@test "Edit on pnpm-lock.yaml is denied" {
  run_hook_edit "Edit" "pnpm-lock.yaml"
  assert_denied_by_json
}

@test "Write on pnpm-lock.yaml is denied" {
  run_hook_edit "Write" "pnpm-lock.yaml"
  assert_denied_by_json
}

@test "MultiEdit on pnpm-lock.yaml is denied" {
  run_hook_edit "MultiEdit" "pnpm-lock.yaml"
  assert_denied_by_json
}

@test "Edit on ./pnpm-lock.yaml is denied" {
  run_hook_edit "Edit" "./pnpm-lock.yaml"
  assert_denied_by_json
}

@test "Edit on an absolute path ending /pnpm-lock.yaml is denied" {
  run_hook_edit "Edit" "/Users/you/projects/my-app/pnpm-lock.yaml"
  assert_denied_by_json
}

@test "Edit on a nested workspace pnpm-lock.yaml is denied" {
  run_hook_edit "Edit" "packages/ui/pnpm-lock.yaml"
  assert_denied_by_json
}

@test "the denial names the regeneration command, not just the prohibition" {
  # The reason string is the whole user-facing payload of this hook: a deny
  # that does not say `pnpm install` leaves the operator with no next step.
  run_hook_edit "Edit" "pnpm-lock.yaml"
  assert_denied_by_json
  grep -qF -- "pnpm install" <<<"$output"
}

# --- allowed: everything else ---

@test "Write on package.json is allowed" {
  run_hook_edit "Write" "package.json"
  assert_allowed_by_json
}

@test "Edit on pnpm-lock.yaml.bak is allowed" {
  run_hook_edit "Edit" "pnpm-lock.yaml.bak"
  assert_allowed_by_json
}

@test "Edit on pnpm-workspace.yaml is allowed" {
  run_hook_edit "Edit" "pnpm-workspace.yaml"
  assert_allowed_by_json
}

@test "Edit on a path merely CONTAINING pnpm-lock.yaml as a directory is allowed" {
  # The guard matches the basename, so a directory of that name is not the
  # lockfile and its contents are not this hook's business.
  run_hook_edit "Edit" "fixtures/pnpm-lock.yaml/notes.md"
  assert_allowed_by_json
}

@test "Edit on an ordinary source file is allowed" {
  run_hook_edit "Edit" "app/components/Button/index.tsx"
  assert_allowed_by_json
}

# --- allowed: payloads the guard cannot read a path out of ---

@test "a payload with no file_path is a silent no-op" {
  invoke_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty file_path is a silent no-op" {
  run_hook_edit "Edit" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- structural ---

@test "block-lockfile-edit.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command | contains(".claude/hooks/block-lockfile-edit.sh"))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
