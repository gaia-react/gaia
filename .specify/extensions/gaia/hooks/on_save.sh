#!/usr/bin/env bash
# on_save.sh - Chain-trigger prompt to /gaia plan after SPEC save.
#
# Reads JSON payload from stdin (or $SPECKIT_HOOK_PAYLOAD env var) per
# .specify/extensions/gaia/lib/hook-payload.md.
#
# Behavior:
#   1. First invocation (no .user_answer in payload): emit a prompt asking
#      whether to chain into /gaia plan now. Default "yes".
#   2. Second invocation (wrapper re-invokes with .user_answer = "yes"|"no"|"defer"|...):
#      append a JSONL telemetry record {spec_id, choice, timestamp} to
#      .gaia/local/telemetry/chain-decisions.jsonl, then return proceed.
#      The wrapper dispatches /gaia plan only when the user explicitly answered yes.
#
# UATs: UAT-010 (chain-trigger prompt with default yes; explicit confirm only).
set -euo pipefail

# --- jq availability ---
if ! command -v jq > /dev/null 2>&1; then
  printf '{"action":"block","reason":"on_save.sh requires jq; install jq and retry."}\n'
  exit 0
fi

# --- Read payload from stdin or env var fallback ---
payload=""
if [ -n "${SPECKIT_HOOK_PAYLOAD:-}" ]; then
  payload="$SPECKIT_HOOK_PAYLOAD"
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi

if [ -z "$payload" ]; then
  printf '{"action":"block","reason":"on_save.sh: empty payload (expected JSON on stdin or $SPECKIT_HOOK_PAYLOAD)."}\n'
  exit 0
fi

# Validate JSON.
if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  printf '{"action":"block","reason":"on_save.sh: payload is not valid JSON."}\n'
  exit 0
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
spec_id="$(printf '%s' "$payload" | jq -r '.spec_id // ""')"
spec_path="$(printf '%s' "$payload" | jq -r '.spec_path // ""')"
user_answer="$(printf '%s' "$payload" | jq -r '.user_answer // ""')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  printf '{"action":"block","reason":"on_save.sh: payload.cwd is missing or not a directory."}\n'
  exit 0
fi

if [ -z "$spec_path" ]; then
  printf '{"action":"block","reason":"on_save.sh: payload.spec_path is required (the persisted SPEC artifact)."}\n'
  exit 0
fi

# Derive spec_id from spec_path filename if the payload omitted it.
if [ -z "$spec_id" ]; then
  spec_filename="${spec_path##*/}"
  spec_id="${spec_filename%.md}"
fi

# --- Step 1: First pass - emit chain-trigger prompt (UAT-010) ---
if [ -z "$user_answer" ]; then
  jq -n --arg id "$spec_id" \
    '{
      action: "prompt",
      prompt: ($id + " saved. Trigger /gaia plan now?"),
      default: "yes"
    }'
  exit 0
fi

# --- Step 2: Second pass - record telemetry decision ---
# Lazily create .gaia/local/telemetry/ if missing, then append a JSONL record.
telemetry_dir="$cwd/.gaia/local/telemetry"
mkdir -p "$telemetry_dir"

telemetry_file="$telemetry_dir/chain-decisions.jsonl"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -nc \
  --arg spec_id "$spec_id" \
  --arg choice "$user_answer" \
  --arg timestamp "$ts" \
  '{spec_id: $spec_id, choice: $choice, timestamp: $timestamp}' \
  >> "$telemetry_file"

# --- Step 3: proceed regardless of choice ---
# The wrapper inspects the user_answer separately and dispatches /gaia plan
# only on explicit yes. The hook's job is to record + unblock the lifecycle.
printf '{"action":"proceed"}\n'
exit 0
