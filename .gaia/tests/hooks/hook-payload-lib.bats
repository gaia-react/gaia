#!/usr/bin/env bats

# Tests for .claude/hooks/lib/hook-payload.sh, the shared one-jq payload reader.
#
# The reader's claim is byte parity with the per-field `$(jq -r '.x // ""')`
# reads it replaces, one jq process per call, and a loud return 1 (never a
# misaligned field) on anything it cannot read. Each case drives one property.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/hook-payload-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  HOOK_PAYLOAD_LIBRARY="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.claude/hooks/lib/hook-payload.sh"
  # shellcheck disable=SC1090
  . "$HOOK_PAYLOAD_LIBRARY"
}

# assert_all_fields_empty: every exported global is "".
assert_all_fields_empty() {
  [ -z "$GAIA_HOOK_TOOL_NAME" ] || return 1
  [ -z "$GAIA_HOOK_EVENT" ] || return 1
  [ -z "$GAIA_HOOK_SESSION_ID" ] || return 1
  [ -z "$GAIA_HOOK_CWD" ] || return 1
  [ -z "$GAIA_HOOK_FILE_PATH" ] || return 1
  [ -z "$GAIA_HOOK_PATH" ] || return 1
  [ -z "$GAIA_HOOK_GLOB" ] || return 1
  [ -z "$GAIA_HOOK_COMMAND" ] || return 1
}

# command_from_payload <payload>: the legacy per-field read the reader replaces.
command_from_payload() {
  local value
  value=$(printf '%s' "$1" | jq -r '.tool_input.command // ""')
  printf '%s' "$value"
}

@test "reads every field from a PreToolUse Bash payload" {
  local payload='{"session_id":"s-1","cwd":"/work/tree","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
  gaia_hook_payload_read "$payload"
  [ "$GAIA_HOOK_TOOL_NAME" = "Bash" ]
  [ "$GAIA_HOOK_EVENT" = "PreToolUse" ]
  [ "$GAIA_HOOK_SESSION_ID" = "s-1" ]
  [ "$GAIA_HOOK_CWD" = "/work/tree" ]
  [ "$GAIA_HOOK_COMMAND" = "git status" ]
  [ -z "$GAIA_HOOK_FILE_PATH" ]
  [ -z "$GAIA_HOOK_PATH" ]
  [ -z "$GAIA_HOOK_GLOB" ]
}

@test "reads every field from a Read payload" {
  local payload='{"session_id":"s-2","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}'
  gaia_hook_payload_read "$payload"
  [ "$GAIA_HOOK_TOOL_NAME" = "Read" ]
  [ "$GAIA_HOOK_FILE_PATH" = "/etc/hosts" ]
  [ "$GAIA_HOOK_SESSION_ID" = "s-2" ]
  [ "$GAIA_HOOK_CWD" = "/c" ]
  [ -z "$GAIA_HOOK_COMMAND" ]
  [ -z "$GAIA_HOOK_PATH" ]
  [ -z "$GAIA_HOOK_GLOB" ]
}

@test "reads every field from a Grep payload" {
  local payload='{"session_id":"s-3","cwd":"/g","hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"x","path":"/src","glob":"*.ts"}}'
  gaia_hook_payload_read "$payload"
  [ "$GAIA_HOOK_TOOL_NAME" = "Grep" ]
  [ "$GAIA_HOOK_PATH" = "/src" ]
  [ "$GAIA_HOOK_GLOB" = "*.ts" ]
  [ -z "$GAIA_HOOK_FILE_PATH" ]
  [ -z "$GAIA_HOOK_COMMAND" ]
}

@test "reads every field from a PostToolUse payload" {
  local payload='{"session_id":"s-4","cwd":"/p","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh pr view 1"},"tool_response":{"stdout":"ok"}}'
  gaia_hook_payload_read "$payload"
  [ "$GAIA_HOOK_EVENT" = "PostToolUse" ]
  [ "$GAIA_HOOK_TOOL_NAME" = "Bash" ]
  [ "$GAIA_HOOK_COMMAND" = "gh pr view 1" ]
  [ "$GAIA_HOOK_SESSION_ID" = "s-4" ]
  [ "$GAIA_HOOK_CWD" = "/p" ]
}

@test "a command with newlines, a unit separator, tabs, quotes and edge spaces round-trips byte for byte" {
  local expected=$'  line one\nsecond\tline with "double" and \'single\' quotes\x1fafter-separator  '
  local payload
  payload=$(jq -cn --arg command "$expected" '{tool_name:"Bash",tool_input:{command:$command}}')
  gaia_hook_payload_read "$payload"
  [ "$(printf '%s' "$GAIA_HOOK_COMMAND" | od -An -c)" = "$(printf '%s' "$expected" | od -An -c)" ]
  [ "$GAIA_HOOK_COMMAND" = "$expected" ]
}

@test "trailing newlines are stripped exactly as a command substitution strips them" {
  local payload='{"tool_name":"Bash","tool_input":{"command":"first\nsecond\n\n"}}'
  gaia_hook_payload_read "$payload"
  local legacy
  legacy=$(command_from_payload "$payload")
  [ "$GAIA_HOOK_COMMAND" = "$legacy" ]
  [ "$GAIA_HOOK_COMMAND" = $'first\nsecond' ]
}

@test "a lone trailing newline is stripped like the legacy read" {
  local payload='{"tool_name":"Bash","tool_input":{"command":"git status\n"}}'
  gaia_hook_payload_read "$payload"
  [ "$GAIA_HOOK_COMMAND" = "$(command_from_payload "$payload")" ]
  [ "$GAIA_HOOK_COMMAND" = "git status" ]
}

@test "absent, null and false fields give the empty string" {
  gaia_hook_payload_read '{"tool_name":null,"session_id":false,"tool_input":{"command":null,"path":false}}'
  assert_all_fields_empty
  gaia_hook_payload_read '{}'
  assert_all_fields_empty
}

@test "tool_input absent or not an object gives empty tool_input fields" {
  gaia_hook_payload_read '{"tool_name":"Bash","hook_event_name":"SessionStart"}'
  [ "$GAIA_HOOK_TOOL_NAME" = "Bash" ]
  [ "$GAIA_HOOK_EVENT" = "SessionStart" ]
  [ -z "$GAIA_HOOK_COMMAND" ]
  gaia_hook_payload_read '{"tool_name":"Bash","tool_input":"just a string"}'
  [ "$GAIA_HOOK_TOOL_NAME" = "Bash" ]
  [ -z "$GAIA_HOOK_COMMAND" ]
  gaia_hook_payload_read '{"tool_name":"Bash","tool_input":[1,2]}'
  [ -z "$GAIA_HOOK_COMMAND" ]
}

@test "a number gives its digits" {
  gaia_hook_payload_read '{"session_id":12345,"tool_input":{"command":0}}'
  [ "$GAIA_HOOK_SESSION_ID" = "12345" ]
  [ "$GAIA_HOOK_COMMAND" = "0" ]
}

@test "an object gives compact JSON" {
  gaia_hook_payload_read '{"tool_input":{"command":{"a": 1, "b": [true, "x"]}}}'
  [ "$GAIA_HOOK_COMMAND" = '{"a":1,"b":[true,"x"]}' ]
}

@test "true gives the text true" {
  gaia_hook_payload_read '{"tool_name":true}'
  [ "$GAIA_HOOK_TOOL_NAME" = "true" ]
}

@test "invalid JSON returns 1 with every variable empty" {
  gaia_hook_payload_read '{"tool_name":"Bash","tool_input":{"command":"x"}}'
  run gaia_hook_payload_read 'not json {'
  [ "$status" -eq 1 ]
  gaia_hook_payload_read 'not json {' && return 1
  assert_all_fields_empty
}

@test "a JSON array returns 1 with every variable empty" {
  gaia_hook_payload_read '{"tool_name":"Bash"}'
  gaia_hook_payload_read '[{"tool_name":"Bash"}]' && return 1
  assert_all_fields_empty
}

@test "an empty payload returns 1 with every variable empty" {
  gaia_hook_payload_read '{"tool_name":"Bash"}'
  gaia_hook_payload_read '' && return 1
  assert_all_fields_empty
}

@test "a second JSON value after the object returns 1" {
  gaia_hook_payload_read '{"tool_name":"Bash"} {"tool_name":"Read"}' && return 1
  assert_all_fields_empty
}

@test "a command carrying a JSON NUL returns 1, so the sentinel check is live" {
  gaia_hook_payload_read '{"tool_name":"Bash","tool_input":{"command":"a\u0000b"}}' && return 1
  assert_all_fields_empty
}

@test "a NUL in a middle field returns 1 instead of misaligning the later fields" {
  gaia_hook_payload_read '{"tool_name":"Bash","cwd":"/a\u0000b","tool_input":{"command":"git status"}}' && return 1
  assert_all_fields_empty
}

@test "exactly one jq process runs per call" {
  local shim_directory="$BATS_TEST_TMPDIR/shim"
  local real_jq
  real_jq="$(command -v jq)"
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$BATS_TEST_TMPDIR/calls.log"
  PATH="$shim_directory:$PATH"

  gaia_hook_payload_read '{"tool_name":"Bash","session_id":"s","cwd":"/c","hook_event_name":"PreToolUse","tool_input":{"command":"ls","file_path":"/f"}}'
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log" | tr -d ' ')" = "1" ]
  [ "$GAIA_HOOK_COMMAND" = "ls" ]

  gaia_hook_payload_read 'not json' && return 1
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log" | tr -d ' ')" = "2" ]
}

@test "a caller under set -euo pipefail is never aborted, on success or failure" {
  run bash -c '
    set -euo pipefail
    . "$1"
    gaia_hook_payload_read "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\\n\"}}"
    [ "$GAIA_HOOK_COMMAND" = "ls" ]
    for bad in "not json" "[1]" "" "{\"tool_input\":{\"command\":\"a\\u0000b\"}}"; do
      if gaia_hook_payload_read "$bad"; then echo "unexpected success: $bad"; exit 9; fi
    done
    echo survived
  ' _ "$HOOK_PAYLOAD_LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "survived" ]
}

@test "the function prints nothing on success or failure" {
  run gaia_hook_payload_read '{"tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run gaia_hook_payload_read 'not json'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "sourcing twice is harmless and keeps the function working" {
  # shellcheck disable=SC1090
  . "$HOOK_PAYLOAD_LIBRARY"
  # shellcheck disable=SC1090
  . "$HOOK_PAYLOAD_LIBRARY"
  gaia_hook_payload_read '{"tool_name":"Bash"}'
  [ "$GAIA_HOOK_TOOL_NAME" = "Bash" ]
}

@test "a failed read after a good one clears the previous values" {
  gaia_hook_payload_read '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$GAIA_HOOK_COMMAND" = "ls" ]
  gaia_hook_payload_read 'oops' && return 1
  assert_all_fields_empty
}

@test "the library parses under the stock macOS bash" {
  if [ ! -x /bin/bash ]; then skip "no /bin/bash"; fi
  run /bin/bash -n "$HOOK_PAYLOAD_LIBRARY"
  [ "$status" -eq 0 ]
}
