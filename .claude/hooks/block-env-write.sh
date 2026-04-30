#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes targeting `.env` files.
# Allowed: `.env.example` (committed placeholder).
# Closes the gap left by the Read-only deny rule in settings.json.
set -euo pipefail

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[[ -n "$file_path" ]] || exit 0

# Strip any trailing slash, take basename for matching.
base=$(basename "$file_path")

# Allow .env.example explicitly.
[[ "$base" == ".env.example" ]] && exit 0

# Deny .env, .env.local, .env.production, .env.development, etc.
if [[ "$base" == ".env" || "$base" == .env.* ]]; then
  jq -n --arg r "BLOCKED: writes to '$file_path' are forbidden. .env files must remain gitignored and edited manually by the developer." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

exit 0
