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

# Per-tree session state, rooted at the acting tree rather than at the process
# working directory. Unlike its sibling in wiki-drift-check.sh this hook has no
# repository or state-file test above the marker, so it really is reached from
# any depth: a path relative to the working directory writes a SECOND marker
# per directory, under the same session id, and the once-per-session
# suppression this marker exists to provide stops holding. The resolver is
# loaded from this file's own on-disk location, and the fallback chain ends at
# `pwd`, which is what the bare literal resolved to, so the deliberate
# no-repository case (this hook nags on a path shape, not on a checkout) is
# unchanged. Bracketed in `set +e` because errexit is armed above.
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_main_root_lib="$_hook_root/.gaia/scripts/main-root-lib.sh"
set +e; [ -n "$_hook_root" ] && [ -f "$_main_root_lib" ] && . "$_main_root_lib" 2>/dev/null; set -e
tree_root=''
if type gaia_resolve_tree_root >/dev/null 2>&1; then
  tree_root="$(gaia_resolve_tree_root 2>/dev/null)" || tree_root=''
fi
[ -n "$tree_root" ] || tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

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
