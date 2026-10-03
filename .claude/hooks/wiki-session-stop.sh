#!/usr/bin/env bash
# GAIA-owned Stop hook.
#
# WIKI_CHANGED: wiki/ content changed this session, so prompt to refresh hot.md.
#
# Upstream contract: claude-obsidian/hooks/hooks.json::Stop. Why GAIA overrides:
# claude-obsidian 2.x does not auto-commit wiki edits, so neither a diff against
# HEAD nor a commit-range check sees every change alone. We check both: wiki/
# commits since the session-start HEAD marker, and uncommitted wiki/ content
# that differs from the baseline wiki-session-start.sh recorded, so a tree that
# was already dirty at start stays quiet. Reminder text uses GAIA's 200-word
# hot-cache cap (upstream caps at 500).

set -euo pipefail
trap 'exit 0' ERR

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -d "$root/wiki" ] || exit 0
git_directory=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || exit 0

reminder='WIKI_CHANGED: Wiki pages were modified this session. Please update wiki/hot.md with a brief summary of what changed (under 200 words). Use the hot cache format: Last Updated, Key Recent Facts, Recent Changes, Active Threads. Keep it factual. Overwrite the file completely. It is a cache, not a journal.'
reminder_printed=0

# Runs before every early exit below, so a missing session marker cannot hide
# uncommitted edits. Fail-open: without the library the check is skipped.
_hook_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
if [ -f "$_hook_directory/lib/wiki-dirty-fingerprint.sh" ]; then
  . "$_hook_directory/lib/wiki-dirty-fingerprint.sh"
  dirty_baseline_file="$git_directory/claude-session-wiki-dirty"
  current_fingerprint=$(gaia_wiki_dirty_fingerprint "$root")
  if [ -f "$dirty_baseline_file" ]; then
    baseline_fingerprint=$(cat "$dirty_baseline_file" 2>/dev/null || true)
    if [ -n "$current_fingerprint" ] && [ "$current_fingerprint" != "$baseline_fingerprint" ]; then
      echo "$reminder"
      reminder_printed=1
    fi
  fi
  printf '%s' "$current_fingerprint" > "$dirty_baseline_file"
fi

session_marker="$git_directory/claude-session-start"
[ -f "$session_marker" ] || exit 0

start_sha=$(cat "$session_marker" 2>/dev/null) || exit 0
[ -n "$start_sha" ] || exit 0
head_sha=$(git -C "$root" rev-parse HEAD 2>/dev/null) || exit 0

# No commits since session start, nothing to do.
[ "$start_sha" = "$head_sha" ] && exit 0

# Marker SHA must be reachable from HEAD; otherwise rebase/reset/shallow, reset marker.
if ! git -C "$root" merge-base --is-ancestor "$start_sha" HEAD 2>/dev/null; then
  echo "$head_sha" > "$session_marker"
  exit 0
fi

# Wiki files modified this session → refresh hot cache.
#
# The listing is captured and matched from a here-string rather than piped into
# `grep -q`. A quiet grep exits at its first match and closes the pipe, the
# upstream `git log` takes SIGPIPE and exits 141, and `pipefail` promotes that
# to the pipeline's status -- so the `if` would take the FALSE branch BECAUSE a
# wiki path matched. A session's whole changed-path set is exactly the input
# that outruns the pipe buffer, and an early `wiki/` match is exactly the
# session this reminder exists for.
session_paths="$(git -C "$root" log "$start_sha..HEAD" --name-only --pretty=format: 2>/dev/null || true)"
if [ "$reminder_printed" -eq 0 ] && grep -q '^wiki/' <<<"$session_paths"; then
  echo "$reminder"
fi

# Advance the session marker so repeated Stops in the same session don't re-prompt.
echo "$head_sha" > "$session_marker"
exit 0
