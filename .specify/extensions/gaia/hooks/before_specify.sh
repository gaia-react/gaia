#!/usr/bin/env bash
# before_specify.sh - Constitution placeholder check + resume-vs-start-new prompt + session marker.
#
# Reads JSON payload from stdin (or $SPECKIT_HOOK_PAYLOAD env var) per
# .specify/extensions/gaia/lib/hook-payload.md.
#
# Returns one of:
#   {"action": "proceed"}
#   {"action": "block",  "reason": "..."}
#   {"action": "prompt", "prompt": "...", "default": "..."}
#
# UATs: UAT-007 (constitution placeholder block), UAT-013 (resume-vs-start-new prompt).
set -euo pipefail

# --- jq availability ---
if ! command -v jq > /dev/null 2>&1; then
  printf '{"action":"block","reason":"before_specify.sh requires jq; install jq and retry."}\n'
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
  printf '{"action":"block","reason":"before_specify.sh: empty payload (expected JSON on stdin or $SPECKIT_HOOK_PAYLOAD)."}\n'
  exit 0
fi

# Validate JSON.
if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  printf '{"action":"block","reason":"before_specify.sh: payload is not valid JSON."}\n'
  exit 0
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
branch="$(printf '%s' "$payload" | jq -r '.branch // "unknown"')"
user_answer="$(printf '%s' "$payload" | jq -r '.user_answer // ""')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  printf '{"action":"block","reason":"before_specify.sh: payload.cwd is missing or not a directory."}\n'
  exit 0
fi

# --- Step 1: Constitution placeholder check (UAT-007) ---
# spec-kit ships .specify/memory/constitution.md with placeholder values that
# must be populated before useful specs are produced. Block if any sentinel remains.
constitution="$cwd/.specify/memory/constitution.md"

if [ -f "$constitution" ]; then
  # Sentinel patterns derived from spec-kit's default constitution template.
  # Match: [PLACEHOLDER], <TODO>, <TBD>, [FILL_IN], TBD as a token, [Constitution governs ...] sentinels.
  if grep -qE '\[PLACEHOLDER\]|<TODO>|<TBD>|\[FILL_IN\]|FIXME' "$constitution" \
     || grep -qE '(^|[^A-Za-z<])TBD([^A-Za-z>]|$)' "$constitution" \
     || grep -qE '\[\[[A-Z_]+\]\]' "$constitution"; then
    jq -n --arg reason "spec-kit constitution at .specify/memory/constitution.md still contains placeholder values. Run /speckit.constitution and re-invoke /gaia spec." \
      '{action:"block", reason:$reason}'
    exit 0
  fi
else
  # Missing constitution is also a precondition failure - same UAT-007 spirit.
  jq -n --arg reason "spec-kit constitution at .specify/memory/constitution.md is missing. Run /speckit.constitution before /gaia spec." \
    '{action:"block", reason:$reason}'
  exit 0
fi

# --- Step 2: Resume-vs-start-new prompt (UAT-013) ---
# If a SPEC with status: in-progress exists in .gaia/local/specs/, prompt the user.
# When the wrapper re-invokes the hook with .user_answer set, skip the prompt
# (the wrapper has already collected the choice).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
allocator="$script_dir/../lib/spec-allocator.sh"

in_progress="none"
if [ -x "$allocator" ]; then
  in_progress="$("$allocator" in_progress "$cwd" 2>/dev/null || echo "none")"
fi

if [ "$in_progress" != "none" ] && [ -z "$user_answer" ]; then
  jq -n --arg id "$in_progress" \
    '{
      action: "prompt",
      prompt: ("Resume " + $id + ", or start new (leaves " + $id + " open)?"),
      default: "resume"
    }'
  exit 0
fi

# --- Step 3: Write session-start marker into .gaia/local/cache/ ---
# Records branch, timestamp, and user's resume choice. Used by after_specify.sh
# write-surface audit to determine the time window for modified-file detection.
cache_dir="$cwd/.gaia/local/cache"
mkdir -p "$cache_dir"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
session_file="$cache_dir/session-$ts.json"

resume_choice="${user_answer:-none}"
if [ "$in_progress" = "none" ]; then
  resume_choice="new"
fi

jq -n \
  --arg branch "$branch" \
  --arg started_at "$ts" \
  --arg resume_choice "$resume_choice" \
  --arg in_progress "$in_progress" \
  '{
    branch: $branch,
    started_at: $started_at,
    resume_choice: $resume_choice,
    in_progress_spec: $in_progress
  }' > "$session_file"

# Maintain a stable pointer so after_specify.sh can find the active session
# without scanning timestamps.
printf '%s\n' "$session_file" > "$cache_dir/active-session"

# --- Step 4: proceed ---
printf '{"action":"proceed"}\n'
exit 0
