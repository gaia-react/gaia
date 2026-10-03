#!/usr/bin/env bash
# Claude probe: InstructionsLoaded hook. Appends one JSON line per event to
# $GAIA_PROBE_LOG naming the instruction file that loaded and why.
#
# Argument 1 is the tag of the settings file that registered this hook
# (root-settings, root-local, frontend-settings, frontend-local), so a line
# also says which settings source was live. Logs only file_path, load_reason,
# trigger_file_path and memory_type from the payload; never file contents.
#
# Stands down (exit 0, writes nothing) when GAIA_PROBE_LOG is unset, so a
# probe entry left in a scratch tree is inert outside a probe run. Never emits
# a decision, so it cannot change what the session does.
set -u

[ -n "${GAIA_PROBE_LOG:-}" ] || exit 0
probe_tag="${1:-untagged}"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"event":"ProbeError","hook":"InstructionsLoaded","tag":"%s","reason":"jq unavailable"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi

payload="$(cat)"
line="$(printf '%s' "$payload" | jq -c --arg tag "$probe_tag" '{
  event: "InstructionsLoaded",
  tag: $tag,
  file_path: (.file_path // null),
  load_reason: (.load_reason // null),
  trigger_file_path: (.trigger_file_path // null),
  memory_type: (.memory_type // null)
}' 2>/dev/null)" || line=""

if [ -z "$line" ]; then
  printf '{"event":"ProbeError","hook":"InstructionsLoaded","tag":"%s","reason":"payload not JSON"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi
printf '%s\n' "$line" >>"$GAIA_PROBE_LOG"
exit 0
