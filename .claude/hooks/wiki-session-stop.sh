#!/usr/bin/env bash
# GAIA-owned Stop hook.
#
# WIKI_CHANGED: wiki/ files committed this session, so prompt to refresh hot.md.
#
# Upstream contract: claude-obsidian/hooks/hooks.json::Stop. Why GAIA overrides:
# upstream diffs working tree vs HEAD, but its PostToolUse already auto-commits
# wiki/ changes, so its Stop diff is always empty and the refresh prompt never
# fires. We diff a session-start HEAD marker against HEAD instead. Reminder text
# uses GAIA's 200-word hot-cache cap (upstream caps at 500).

set -euo pipefail
trap 'exit 0' ERR

[ -d wiki ] || exit 0
git_directory=$(git rev-parse --git-dir 2>/dev/null) || exit 0

session_marker="$git_directory/claude-session-start"
[ -f "$session_marker" ] || exit 0

start_sha=$(cat "$session_marker" 2>/dev/null) || exit 0
[ -n "$start_sha" ] || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

# No commits since session start, nothing to do.
[ "$start_sha" = "$head_sha" ] && exit 0

# Marker SHA must be reachable from HEAD; otherwise rebase/reset/shallow, reset marker.
if ! git merge-base --is-ancestor "$start_sha" HEAD 2>/dev/null; then
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
session_paths="$(git log "$start_sha..HEAD" --name-only --pretty=format: 2>/dev/null || true)"
if grep -q '^wiki/' <<<"$session_paths"; then
  echo 'WIKI_CHANGED: Wiki pages were modified this session. Please update wiki/hot.md with a brief summary of what changed (under 200 words). Use the hot cache format: Last Updated, Key Recent Facts, Recent Changes, Active Threads. Keep it factual. Overwrite the file completely. It is a cache, not a journal.'
fi

# Advance the session marker so repeated Stops in the same session don't re-prompt.
echo "$head_sha" > "$session_marker"
exit 0
