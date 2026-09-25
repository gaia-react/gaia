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

# --- the guard's reach: a substring match on the path ---

@test "a name merely containing tsconfig is covered too" {
  # The match is deliberately a substring rather than a whole-basename anchor:
  # tsc reads whatever config `-p` or `extends` names, so a non-canonical name
  # can be a live config, and this guard blocks with a remedy rather than
  # failing a build. Over-blocking here costs a message; under-blocking costs
  # the ambient-types erosion the guard exists to stop.
  run_hook_edit "notatsconfig.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "a json file under a directory called tsconfig is not a tsconfig" {
  # The substring match requires the literal "tsconfig.json" run, so a
  # directory named tsconfig with an unrelated file inside it does not match.
  run_hook_edit "config/tsconfig/other.json" '"types": ["vitest/globals"]'
  assert_allowed_by_exit
}

# --- structural ---

@test "block-vitest-globals-tsconfig.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' block-vitest-globals-tsconfig.sh
}
