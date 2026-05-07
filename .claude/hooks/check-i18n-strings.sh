#!/bin/bash
# Advisory check: warn about potential hardcoded strings in JSX.
# Once-per-session via marker file (mirrors wiki-drift-check.sh pattern).
# Exit 0 always (advisory, non-blocking).

set -euo pipefail
trap 'exit 0' ERR

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null || echo "")

# Only check page and component files
if ! echo "$file_path" | grep -qE 'app/(pages|components)/.*\.tsx$'; then
  exit 0
fi

session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$session_id" ] || exit 0

marker=".claude/i18n-strings-checked"
if [ -f "$marker" ] && grep -q "^session_id=$session_id$" "$marker" 2>/dev/null; then
  exit 0
fi

# Reminder (non-blocking)
echo "Reminder: Ensure all user-facing strings use t() from useTranslation(). Add keys to all language files." >&2

mkdir -p .claude
{
  printf 'session_id=%s\n' "$session_id"
  printf 'checked_at=%s\n' "$(date -u +%FT%TZ)"
} > "$marker"

exit 0
