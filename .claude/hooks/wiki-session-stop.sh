#!/usr/bin/env bash
# GAIA-owned Stop hook (merged: session-stop + safety-net).
#
# Two reminders share one git/jq pass:
#   1. WIKI_CHANGED — wiki/ files committed this session → prompt to refresh hot.md.
#   2. End-of-session safety net — session committed but wiki/.state.json did not
#      fully advance → nag to /wiki-sync.
#
# Upstream contract: claude-obsidian/hooks/hooks.json::Stop. Why GAIA overrides:
# upstream diffs working tree vs HEAD, but its PostToolUse already auto-commits
# wiki/ changes, so its Stop diff is always empty and the refresh prompt never
# fires. We diff a session-start HEAD marker against HEAD instead. Reminder text
# uses GAIA's 200-word hot-cache cap (upstream caps at 500).

set -euo pipefail
trap 'exit 0' ERR

[ -d wiki ] || exit 0
[ -d .git ] || exit 0
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

session_marker="$GIT_DIR/claude-session-start"
[ -f "$session_marker" ] || exit 0

start_sha=$(cat "$session_marker" 2>/dev/null) || exit 0
[ -n "$start_sha" ] || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

# No commits since session start — nothing to do.
[ "$start_sha" = "$head_sha" ] && exit 0

# Marker SHA must be reachable from HEAD; otherwise rebase/reset/shallow — reset marker.
if ! git merge-base --is-ancestor "$start_sha" HEAD 2>/dev/null; then
  echo "$head_sha" > "$session_marker"
  exit 0
fi

# Reminder #1 — wiki files modified this session → refresh hot cache.
if git log "$start_sha..HEAD" --name-only --pretty=format: 2>/dev/null | grep -q '^wiki/'; then
  echo 'WIKI_CHANGED: Wiki pages were modified this session. Please update wiki/hot.md with a brief summary of what changed (under 200 words). Use the hot cache format: Last Updated, Key Recent Facts, Recent Changes, Active Threads. Keep it factual. Overwrite the file completely. It is a cache, not a journal.'
fi

# Reminder #2 — safety net: did wiki state advance to HEAD?
if command -v jq >/dev/null 2>&1 && [ -f wiki/.state.json ]; then
  payload=$(cat 2>/dev/null || echo "")
  session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")

  if [ -n "$session_id" ]; then
    safety_marker=".claude/wiki-safety-checked"
    if ! { [ -f "$safety_marker" ] && grep -q "^session_id=$session_id$" "$safety_marker" 2>/dev/null; }; then
      state_sha=$(jq -r '.last_evaluated_sha // empty' wiki/.state.json 2>/dev/null || echo "")
      if [ -n "$state_sha" ] \
        && [ "$state_sha" != "0000000000000000000000000000000000000000" ] \
        && [ "$state_sha" != "$head_sha" ]; then

        commits_this_session=$(git rev-list --count "$start_sha..HEAD" 2>/dev/null || echo 0)
        printf '[wiki end-of-session] You committed %s times this session but the wiki state SHA did not advance. Review wiki/log.md and run /wiki-sync if needed before ending.\n' \
          "$commits_this_session"

        mkdir -p .claude
        {
          printf 'session_id=%s\n' "$session_id"
          printf 'checked_at=%s\n' "$(date -u +%FT%TZ)"
          printf 'commits_this_session=%s\n' "$commits_this_session"
        } > "$safety_marker"
      fi
    fi
  fi
fi

# Advance the session marker so repeated Stops in the same session don't re-prompt.
echo "$head_sha" > "$session_marker"
exit 0
