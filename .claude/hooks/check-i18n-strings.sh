#!/bin/bash
# Advisory check: warn about potential hardcoded strings in JSX.
# Once-per-session via marker file (mirrors wiki-drift-check.sh pattern).
# Exit 0 always (advisory, non-blocking).

set -euo pipefail
trap 'exit 0' ERR

payload=$(cat)
# Advisory, so this stands down rather than refusing: the arm a blocking hook
# takes instead is .claude/hooks/lib/jq-availability.sh.
command -v jq >/dev/null 2>&1 || exit 0

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null || echo "")

# Only check page and component files
if ! grep -qE 'app/(pages|components)/.*\.tsx$' <<<"$file_path"; then
  exit 0
fi

session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$session_id" ] || exit 0

# Per-tree session state. Rooted at the checkout rather than at the process
# working directory: this hook has no repository or state-file test above the
# marker, so it is reached from any depth, and a path relative to the working
# directory would write a SECOND marker per directory under the same session
# id, dropping the once-per-session suppression this marker exists to provide.
# The fallback ends at `pwd`, the deliberate no-repository case (this hook nags
# on a path shape, not on a checkout).
tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

marker="$tree_root/.claude/i18n-strings-checked"
if [ -f "$marker" ] && grep -q "^session_id=$session_id$" "$marker" 2>/dev/null; then
  exit 0
fi

# Reminder (non-blocking)
echo "Reminder: Ensure all user-facing strings use t() from useTranslation(). Add keys to all language files." >&2

mkdir -p "$tree_root/.claude"
{
  printf 'session_id=%s\n' "$session_id"
  printf 'checked_at=%s\n' "$(date -u +%FT%TZ)"
} > "$marker"

exit 0
