#!/usr/bin/env bash
# PreToolUse Edit/Write hook: deny direct edits to package lockfiles.
# Lockfile changes must come from `pnpm install` (or equivalent), never from
# manual edits — which routinely produce broken/inconsistent lockfiles.
set -euo pipefail

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[[ -n "$file_path" ]] || exit 0

base=$(basename "$file_path")

case "$base" in
  pnpm-lock.yaml)
    jq -n --arg r "BLOCKED: direct edits to pnpm-lock.yaml are forbidden. Run 'pnpm install' (or 'pnpm add/remove') and let pnpm regenerate the lockfile." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
    exit 0
    ;;
esac

exit 0
