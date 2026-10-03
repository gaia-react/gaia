#!/usr/bin/env bash
# Claude probe: SessionStart hook. Appends one JSON line to $GAIA_PROBE_LOG
# recording CLAUDE_PROJECT_DIR, the hook's working directory, and the git
# toplevel of that directory (the CLAUDE_PROJECT_DIR|pwd|toplevel triple).
#
# Argument 1 is the tag of the settings file that registered this hook. A
# line carrying a tag is the observation that the tagged settings file was a
# live settings source for the session; the hook rows read registration from
# that file's snapshot.
#
# Stands down when GAIA_PROBE_LOG is unset. Never emits a decision or
# additionalContext.
set -u

[ -n "${GAIA_PROBE_LOG:-}" ] || exit 0
probe_tag="${1:-untagged}"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"event":"ProbeError","hook":"SessionStart","tag":"%s","reason":"jq unavailable"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi

payload="$(cat)"
session_source="$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)" || session_source=""
working_directory="$(pwd -P)"
toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=""

jq -nc \
  --arg tag "$probe_tag" \
  --arg source "$session_source" \
  --arg project_dir "${CLAUDE_PROJECT_DIR:-}" \
  --arg pwd "$working_directory" \
  --arg toplevel "$toplevel" \
  '{event: "SessionStart", tag: $tag, source: $source,
    claude_project_dir: $project_dir, pwd: $pwd, toplevel: $toplevel}' >>"$GAIA_PROBE_LOG"
exit 0
