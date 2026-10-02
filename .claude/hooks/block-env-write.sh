#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny writes targeting `.env` files.
# Allowed: `.env.example` (committed placeholder).
# Closes the gap left by the Read-only deny rule in settings.json.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. This matcher cannot reach the jq
# install itself, so the refusal is unconditional within it and the call below
# passes no binding literal; the contract lives in
# .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-env-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the dotenv write guard' "$payload" tool_input

file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[[ -n "$file_path" ]] || exit 0

# Strip any trailing slash, take basename for matching.
base=$(basename "$file_path")

# Allow .env.example explicitly.
[[ "$base" == ".env.example" ]] && exit 0

# Deny .env, .env.local, .env.production, .env.development, etc.
if [[ "$base" == ".env" || "$base" == .env.* ]]; then
  jq -n --arg reason "BLOCKED: writes to '$file_path' are forbidden. .env files must remain gitignored and edited manually by the developer." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

exit 0
