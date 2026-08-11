#!/usr/bin/env bats

# Tests for .claude/hooks/block-vitest-globals-tsconfig.sh.
#
# `vitest/globals` in tsconfig.json makes describe/expect/test ambient, which
# hides missing imports from the type checker and lets a test file that would
# not compile on its own pass. The guard blocks a write that puts that string
# into a tsconfig.json.
#
# MECHANISM: exit code, not JSON. This hook blocks by exiting 2 with a BLOCKED
# message on stderr and allows by exiting 0 silently, so the assertions here are
# `assert_blocked_by_exit` / `assert_allowed_by_exit`, not the `_by_json` pair
# its Edit|Write|MultiEdit siblings use. Under this contract the allow case is
# an assertion of silence, which is what makes the abstain tests below worth
# writing: a guard that had started blocking everything would still exit 0 on
# nothing at all.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-vitest-globals-tsconfig.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Several payloads below carry TypeScript config text with quotes of its own,
# so delivery goes through `invoke_hook` (helpers/run-hook.sh).
run_hook_edit() {
  local path="$1" new_string="$2"
  local json
  json=$(jq -n --arg p "$path" --arg s "$new_string" \
    '{tool_name: "Edit", tool_input: {file_path: $p, new_string: $s}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_write() {
  local path="$1" content="$2"
  local json
  json=$(jq -n --arg p "$path" --arg c "$content" \
    '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  invoke_hook "$json" "$HOOK_ABS"
}

# --- blocked: vitest/globals reaching a tsconfig.json ---

@test "an Edit adding vitest/globals to tsconfig.json is blocked" {
  run_hook_edit "tsconfig.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "a Write of a whole tsconfig.json containing vitest/globals is blocked" {
  # The Write tool carries its payload in `content`, not `new_string`; the
  # guard reads both, and a regression that dropped either arm would let one
  # of the two write paths through untouched.
  run_hook_write "tsconfig.json" '{"compilerOptions": {"types": ["vitest/globals"]}}'
  assert_blocked_by_exit
}

@test "the block is case-insensitive" {
  run_hook_edit "tsconfig.json" '"types": ["Vitest/Globals"]'
  assert_blocked_by_exit
}

@test "an absolute path to tsconfig.json is blocked" {
  run_hook_edit "/Users/you/projects/my-app/tsconfig.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "the block names the explicit-import remedy" {
  # The stderr text is the whole reason a block is better than a silent
  # failure: PreToolUse shows it to Claude, which then knows what to do
  # instead. A block carrying no remedy just stalls the edit.
  run_hook_edit "tsconfig.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
  grep -qF -- "import {describe, expect, test} from 'vitest'" <<<"$output"
}

# --- allowed: a tsconfig.json write with no vitest/globals ---

@test "an ordinary tsconfig.json edit is allowed" {
  run_hook_edit "tsconfig.json" '"strict": true'
  assert_allowed_by_exit
}

@test "a tsconfig.json edit naming vitest without /globals is allowed" {
  run_hook_edit "tsconfig.json" '"include": ["vitest.config.ts"]'
  assert_allowed_by_exit
}

# --- allowed: vitest/globals somewhere that is not a tsconfig.json ---

@test "vitest/globals in a source file is allowed" {
  run_hook_edit "app/components/Button/tests/index.test.tsx" "// vitest/globals"
  assert_allowed_by_exit
}

@test "vitest/globals in vitest.config.ts is allowed" {
  run_hook_edit "vitest.config.ts" "globals: false // not vitest/globals"
  assert_allowed_by_exit
}

# --- allowed: payloads the guard cannot read a path out of ---

@test "a payload with no file_path is a silent no-op" {
  invoke_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$HOOK_ABS"
  assert_allowed_by_exit
}

# --- the guard's literal boundaries, pinned so a change to either is visible ---

@test "a sibling tsconfig whose name is not literally tsconfig.json is not covered" {
  # The path test is a substring match on `tsconfig.json`, so tsconfig.node.json
  # and tsconfig.app.json fall outside it. Pinned as the guard's current reach,
  # not as desired behavior: if the match is ever widened, this test is the one
  # that says so.
  run_hook_edit "tsconfig.node.json" '"types": ["vitest/globals"]'
  assert_allowed_by_exit
}

@test "a MultiEdit carries its text in edits[], which the guard does not read" {
  # MultiEdit is in the registered matcher but its payload has neither
  # `new_string` nor `content` at the top level, so the guard reads "" and
  # abstains. Pinned as the guard's current reach; widening it to fold in
  # edits[] would flip this test, which is the point of writing it down.
  local json
  json=$(jq -n '{tool_name: "MultiEdit", tool_input: {file_path: "tsconfig.json", edits: [{old_string: "", new_string: "\"types\": [\"vitest/globals\"]"}]}}')
  invoke_hook "$json" "$HOOK_ABS"
  assert_allowed_by_exit
}

# --- structural ---

@test "block-vitest-globals-tsconfig.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-vitest-globals-tsconfig.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
