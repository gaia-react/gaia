#!/usr/bin/env bash
# Claude probe: PostToolUse hook. Appends one JSON line per tool call that ran
# to $GAIA_PROBE_LOG: tool name, tool_use_id, and the file path it targeted.
# PostToolUse fires only after the permission check let the call through, so
# a line here is the observation "allowed and executed".
#
# A Read line here is also what verifies a lazy-discovery scenario's Read
# before run-probe.sh issues the listing turn.
#
# For a Bash call it records the probe-if-<marker> a hook-if scenario command
# carries (probe_if_marker). A PostToolUse hook_if row is judged only on this
# line: a call denied at PreToolUse, or one that failed and fired
# PostToolUseFailure, has a PreToolUse line and none here.
#
# Logs no tool input beyond the path and no tool output. Argument 1 is the
# registering settings file's tag. Stands down when GAIA_PROBE_LOG is unset.
set -u

[ -n "${GAIA_PROBE_LOG:-}" ] || exit 0
probe_tag="${1:-untagged}"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"event":"ProbeError","hook":"PostToolUse","tag":"%s","reason":"jq unavailable"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi

payload="$(cat)"
line="$(printf '%s' "$payload" | jq -c --arg tag "$probe_tag" '{
  event: "PostToolUse",
  tag: $tag,
  tool_name: (.tool_name // null),
  tool_use_id: (.tool_use_id // null),
  file_path: (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // null),
  bash_git_commit: (if .tool_name == "Bash"
    then ((.tool_input.command // "") | test("(^|[;&|(]|\\s)git\\s+commit(\\s|$)"))
    else null end),
  probe_commit_marker: (if .tool_name == "Bash"
    then ([(.tool_input.command // "") | capture("probe-commit-(?<marker>[a-z])")][0].marker // null)
    else null end),
  probe_if_marker: (if .tool_name == "Bash"
    then ([(.tool_input.command // "") | capture("probe-if-(?<marker>m[0-9][0-9][a-z]?)")][0].marker // null)
    else null end)
}' 2>/dev/null)" || line=""

if [ -z "$line" ]; then
  printf '{"event":"ProbeError","hook":"PostToolUse","tag":"%s","reason":"payload not JSON"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi
printf '%s\n' "$line" >>"$GAIA_PROBE_LOG"
exit 0
