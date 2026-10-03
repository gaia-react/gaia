#!/usr/bin/env bash
# Claude probe: PreToolUse hook. Appends one JSON line per tool attempt to
# $GAIA_PROBE_LOG: tool name, tool_use_id, the file path the tool targets, and
# the session's permission mode.
#
# A Bash command is never logged. It can carry a secret, so the hook records
# only whether the command is a `git commit` (bash_git_commit) and which of
# run-probe.sh's scripted commits it is (the probe-commit-<x> marker in the
# commit message, probe_commit_marker), which is all the commit rows need.
#
# Argument 1 is the registering settings file's tag. Stands down when
# GAIA_PROBE_LOG is unset. Emits no decision: exit 0 with empty stdout leaves
# the permission outcome to the settings and the real GAIA hooks under test.
set -u

[ -n "${GAIA_PROBE_LOG:-}" ] || exit 0
probe_tag="${1:-untagged}"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"event":"ProbeError","hook":"PreToolUse","tag":"%s","reason":"jq unavailable"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi

payload="$(cat)"
line="$(printf '%s' "$payload" | jq -c --arg tag "$probe_tag" '{
  event: "PreToolUse",
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
  permission_mode: (.permission_mode // null)
}' 2>/dev/null)" || line=""

if [ -z "$line" ]; then
  printf '{"event":"ProbeError","hook":"PreToolUse","tag":"%s","reason":"payload not JSON"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi
printf '%s\n' "$line" >>"$GAIA_PROBE_LOG"
exit 0
