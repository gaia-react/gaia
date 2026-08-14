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

# MultiEdit's text lives in edits[], one {old_string, new_string} per entry, so
# a single-string helper cannot express the multi-edit case the guard has to
# scan: each argument after the path becomes one edit's new_string.
run_hook_multiedit() {
  local path="$1"
  shift
  local json
  json=$(jq -n --arg p "$path" --args \
    '{tool_name: "MultiEdit", tool_input: {file_path: $p, edits: [$ARGS.positional[] | {old_string: "", new_string: .}]}}' \
    "$@")
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

@test "every JSON spelling of the slash is blocked" {
  # The escape lives in the file content, not the transport: the payload's own
  # JSON encoding is decoded before the content match runs, so what reaches the
  # match is literally `vitest\/globals` or `vitest\u002fglobals`. A tsconfig
  # loader decodes each to the same banned string, so a match taking the literal
  # slash alone lets two spellings of one config through, silently: the block is
  # this hook's only output, so an evasion is indistinguishable from a write
  # that had nothing to block.
  #
  # Assertions are inlined rather than delegated to assert_blocked_by_exit for
  # the reason the family-spelling loop above states: that helper leans on
  # errexit, which an `||` list disables for the whole function body.
  for spelling in 'vitest/globals' 'vitest\/globals' 'vitest\u002fglobals' 'Vitest\U002FGlobals'; do
    run_hook_edit "tsconfig.json" "\"types\": [\"$spelling\"]"
    [ "$status" -eq 2 ] || { echo "not blocked for $spelling (status=$status)" >&2; return 1; }
    grep -qF -- 'BLOCKED' <<<"$output" || { echo "no BLOCKED reason for $spelling" >&2; return 1; }
  done
}

@test "an escaped slash elsewhere in a tsconfig is allowed" {
  # The abstain half of the widened match: a backslash-escaped path separator is
  # ordinary in a tsconfig, so widening the alternation must not turn every one
  # of them into a block.
  run_hook_edit "tsconfig.json" '"paths": {"@app\/*": ["app/*"]}'
  assert_allowed_by_exit
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

# --- the guard's reach: the tsconfig family, and all three payload shapes ---

@test "a sibling tsconfig in the tsconfig*.json family is covered" {
  # A Vite-shaped project splits its config across tsconfig.node.json and
  # tsconfig.app.json, where `vitest/globals` makes describe/expect ambient
  # exactly as it does in the root tsconfig.json.
  run_hook_edit "tsconfig.node.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "a nested tsconfig.build.json is covered" {
  run_hook_edit "packages/web/tsconfig.build.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "any within-segment spelling between tsconfig and .json is covered" {
  # Not an enumeration of the spellings seen so far: the match takes the whole
  # path segment, so a dash, an underscore, and no separator at all are one case
  # rather than three (the dot spelling is pinned above). Enumerating them is
  # unbounded; taking the segment closes the class.
  #
  # Both assertions are inlined rather than delegated to assert_blocked_by_exit:
  # that helper leans on errexit for its status check, and calling a function in
  # an `||` list disables errexit for the function's whole body, which would
  # leave the loop asserting only that BLOCKED appeared. Inlined, each failing
  # branch returns on its own and names the spelling that failed.
  for path in tsconfig-base.json tsconfig_base.json tsconfigbase.json; do
    run_hook_edit "$path" '"types": ["vitest/globals"]'
    [ "$status" -eq 2 ] || { echo "not blocked for $path (status=$status)" >&2; return 1; }
    grep -qF -- 'BLOCKED' <<<"$output" || { echo "no BLOCKED reason for $path" >&2; return 1; }
  done
}

@test "the path match is case-insensitive" {
  # On a case-insensitive filesystem a mixed-case path resolves to the real
  # config, so a case-sensitive match is a live bypass rather than a cosmetic
  # gap: the write lands in tsconfig.json and describe/expect go ambient. The
  # content match beside it has always been case-insensitive; both halves of the
  # decision agree.
  for path in TSConfig.json TSCONFIG.JSON tsconfig.JSON Tsconfig.node.json; do
    run_hook_edit "$path" '"types": ["vitest/globals"]'
    [ "$status" -eq 2 ] || { echo "not blocked for $path (status=$status)" >&2; return 1; }
    grep -qF -- 'BLOCKED' <<<"$output" || { echo "no BLOCKED reason for $path" >&2; return 1; }
  done
}

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
  # The family pattern cannot cross a path separator, so a directory named
  # tsconfig does not pull every .json beneath it into the guard.
  run_hook_edit "config/tsconfig/other.json" '"types": ["vitest/globals"]'
  assert_allowed_by_exit
}

@test "a MultiEdit adding vitest/globals in edits[] is blocked" {
  # MultiEdit is in the registered matcher and carries neither `new_string` nor
  # `content` at the top level: its text lives in edits[].new_string, so a
  # guard reading only the top-level fields scans "" and allows the write.
  run_hook_multiedit "tsconfig.json" '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "a MultiEdit is blocked on any edit in the array, not just the first" {
  run_hook_multiedit "tsconfig.json" '"strict": true' '"types": ["vitest/globals"]'
  assert_blocked_by_exit
}

@test "an ordinary MultiEdit to tsconfig.json is allowed" {
  # The abstain half of the widened read: folding edits[] in must not turn the
  # guard into one that blocks every MultiEdit reaching a tsconfig.
  run_hook_multiedit "tsconfig.json" '"strict": true' '"target": "ES2022"'
  assert_allowed_by_exit
}

@test "an edits[] entry of the wrong type does not swallow a later match" {
  # Indexing a non-object aborts the whole jq read, which empties the scanned
  # text and allows the write, so the per-entry read is guarded independently of
  # the iteration. Unreachable through MultiEdit's real schema, so this pins the
  # read against a malformed payload rather than a live bypass.
  local json
  json=$(jq -n '{tool_name: "MultiEdit", tool_input: {file_path: "tsconfig.json", edits: ["bad", {old_string: "", new_string: "\"types\": [\"vitest/globals\"]"}]}}')
  invoke_hook "$json" "$HOOK_ABS"
  assert_blocked_by_exit
}

# --- structural ---

@test "block-vitest-globals-tsconfig.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-vitest-globals-tsconfig.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
