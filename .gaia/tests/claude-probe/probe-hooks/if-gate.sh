#!/usr/bin/env bash
# Claude probe: a hook handler registered behind an `if` rule. Appends one
# IfGate line per spawn to $GAIA_PROBE_LOG, so a line is the observation that
# Claude Code's `if` matching let this handler run for that call.
#
# Usage (from a settings handler): if-gate.sh <tag> <hook event> <rule slug>
# inject-probe-fixtures.sh registers one handler per rule under test; the
# slug names the rule the handler's `if` holds, and `dedup` names the two
# same-command handlers whose spawn count shows whether the runtime dedups
# them. The arguments are logged as given; the hook never reads its own `if`.
#
# Never logs the command, which can carry a secret: only the probe-if-<marker>
# a hook-if scenario command carries. Stands down when GAIA_PROBE_LOG is
# unset. Emits no decision.
set -u

[ -n "${GAIA_PROBE_LOG:-}" ] || exit 0
probe_tag="${1:-untagged}"
hook_event="${2:-unknown}"
rule_slug="${3:-unknown}"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"event":"ProbeError","hook":"IfGate","tag":"%s","reason":"jq unavailable"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi

payload="$(cat)"
line="$(printf '%s' "$payload" | jq -c --arg tag "$probe_tag" --arg hook_event "$hook_event" --arg rule_slug "$rule_slug" '{
  event: "IfGate",
  hook_event: $hook_event,
  rule_slug: $rule_slug,
  tag: $tag,
  tool_use_id: (.tool_use_id // null),
  probe_if_marker: ([(.tool_input.command // "") | capture("probe-if-(?<marker>m[0-9][0-9][a-z]?)")][0].marker // null)
}' 2>/dev/null)" || line=""

if [ -z "$line" ]; then
  printf '{"event":"ProbeError","hook":"IfGate","tag":"%s","reason":"payload not JSON"}\n' "$probe_tag" >>"$GAIA_PROBE_LOG"
  exit 0
fi
printf '%s\n' "$line" >>"$GAIA_PROBE_LOG"
exit 0
