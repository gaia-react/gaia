#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the GAIA_HOOK_* globals are this library's output, read by the sourcing hook
#
# hook-payload.sh: one-jq reader for the fixed set of payload fields most
# Bash-path hooks need. Sourced, never executed; defines one function and does no
# work at source time. Bash 3.2 compatible.
#
#   gaia_hook_payload_read <raw-payload>
#
# Runs exactly one jq process and returns 0 with these globals set, or returns 1
# with every one of them set to "":
#
#   GAIA_HOOK_TOOL_NAME   .tool_name
#   GAIA_HOOK_EVENT       .hook_event_name
#   GAIA_HOOK_SESSION_ID  .session_id
#   GAIA_HOOK_CWD         .cwd
#   GAIA_HOOK_FILE_PATH   .tool_input.file_path
#   GAIA_HOOK_PATH        .tool_input.path
#   GAIA_HOOK_GLOB        .tool_input.glob
#   GAIA_HOOK_COMMAND     .tool_input.command
#
# Value rule, and the parity claim it buys: a JSON string with its trailing
# newlines stripped (embedded newlines, tabs, quotes, U+001F, and leading or
# trailing whitespace other than newlines are kept exactly); absent, null and
# false give ""; any other value gives its compact JSON text. Every hook's
# earlier preamble read was a command substitution of the form
# `x=$(jq -r '.x // ""')`, which strips all trailing newlines, so this reader
# yields the same bytes for every value a real payload carries. The one
# difference is that a non-string object or array prints compact rather than
# indented, which no real payload sends.
#
# Transport: jq emits each field followed by a NUL, then a sentinel record, and
# the shell reads the records with `read -d ''` in the current shell. A NUL
# inside a value is the one case bash variables cannot hold; it shifts the
# records, so the sentinel check (right record, then end of input) returns 1
# rather than handing a hook a misaligned field. A jq failure and a payload that
# is not a JSON object leave the sentinel missing and return 1 the same way.
# `tool_input` absent or not an object (a SessionStart payload) gives "" for the
# four `tool_input.*` fields.
#
# The function never calls `exit`, never prints, and leaves `set -e` and
# `pipefail` as it found them: every read is guarded.
#
# CALLER CONTRACT.
#   - Source it AFTER the jq-availability arm (`gaia_require_jq` in a blocking
#     hook, `command -v jq || exit 0` in an advisory one) and after every
#     early-exit or verb-arming gate that runs before the hook's first
#     fixed-set read, so a call the hook stands down on pays no load.
#   - Check the load with one function-presence test, `type
#     gaia_hook_payload_read`, never a `bash -n` parse check, so the load adds no
#     fork.
#   - On return 1, do exactly what the hook's failed jq read did before.
#   - A blocking hook that cannot load this file refuses with exit 2 and
#     `BLOCKED: <hook> cannot load lib/hook-payload.sh, so this call cannot be
#     checked. Fail-loud, not fail-open -- restore the library.`; an advisory
#     hook exits 0. The one named exception is red-verify-commit-check.sh, which
#     has no jq-availability arm, documents exit 0 when git, jq or node is
#     unavailable, and so exits 0 on a load failure too.
#   - Fields outside this fixed set stay as the hook's own extra jq reads.

[ -n "${GAIA_HOOK_PAYLOAD_SH:-}" ] && return 0
GAIA_HOOK_PAYLOAD_SH=1

GAIA_HOOK_TOOL_NAME=""
GAIA_HOOK_EVENT=""
GAIA_HOOK_SESSION_ID=""
GAIA_HOOK_CWD=""
GAIA_HOOK_FILE_PATH=""
GAIA_HOOK_PATH=""
GAIA_HOOK_GLOB=""
GAIA_HOOK_COMMAND=""

gaia_hook_payload_read() {
  local payload="$1"
  local sentinel="GAIA_HOOK_PAYLOAD_END"
  local tool_name event session_id working_directory file_path path glob command
  local sentinel_record
  local read_failed=0

  GAIA_HOOK_TOOL_NAME="" GAIA_HOOK_EVENT="" GAIA_HOOK_SESSION_ID="" GAIA_HOOK_CWD=""
  GAIA_HOOK_FILE_PATH="" GAIA_HOOK_PATH="" GAIA_HOOK_GLOB="" GAIA_HOOK_COMMAND=""

  {
    IFS= read -r -d '' tool_name || read_failed=1
    IFS= read -r -d '' event || read_failed=1
    IFS= read -r -d '' session_id || read_failed=1
    IFS= read -r -d '' working_directory || read_failed=1
    IFS= read -r -d '' file_path || read_failed=1
    IFS= read -r -d '' path || read_failed=1
    IFS= read -r -d '' glob || read_failed=1
    IFS= read -r -d '' command || read_failed=1
    IFS= read -r -d '' sentinel_record || read_failed=1
    # Anything after the sentinel means a value carried a NUL that happened to
    # line the records up, so a successful read here is a failure.
    if IFS= read -r -d '' _; then
      read_failed=1
    fi
  } < <(jq -j '
    def text: if type == "string" then .
              elif . == null or . == false then ""
              else tojson end;
    if type == "object" then
      (.tool_input | if type == "object" then . else {} end) as $input
      | ((.tool_name | text),
         (.hook_event_name | text),
         (.session_id | text),
         (.cwd | text),
         ($input.file_path | text),
         ($input.path | text),
         ($input.glob | text),
         ($input.command | text),
         "'"$sentinel"'")
      | ., "\u0000"
    else
      error("payload is not a JSON object")
    end
  ' <<<"$payload" 2>/dev/null)

  [ "$read_failed" -eq 0 ] || return 1
  [ "$sentinel_record" = "$sentinel" ] || return 1

  # Strip every trailing newline, the way a command substitution does.
  while [[ "$tool_name" == *$'\n' ]]; do tool_name="${tool_name%$'\n'}"; done
  while [[ "$event" == *$'\n' ]]; do event="${event%$'\n'}"; done
  while [[ "$session_id" == *$'\n' ]]; do session_id="${session_id%$'\n'}"; done
  while [[ "$working_directory" == *$'\n' ]]; do working_directory="${working_directory%$'\n'}"; done
  while [[ "$file_path" == *$'\n' ]]; do file_path="${file_path%$'\n'}"; done
  while [[ "$path" == *$'\n' ]]; do path="${path%$'\n'}"; done
  while [[ "$glob" == *$'\n' ]]; do glob="${glob%$'\n'}"; done
  while [[ "$command" == *$'\n' ]]; do command="${command%$'\n'}"; done

  GAIA_HOOK_TOOL_NAME="$tool_name"
  GAIA_HOOK_EVENT="$event"
  GAIA_HOOK_SESSION_ID="$session_id"
  GAIA_HOOK_CWD="$working_directory"
  GAIA_HOOK_FILE_PATH="$file_path"
  GAIA_HOOK_PATH="$path"
  GAIA_HOOK_GLOB="$glob"
  GAIA_HOOK_COMMAND="$command"
  return 0
}
