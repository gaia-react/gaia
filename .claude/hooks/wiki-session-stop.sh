#!/usr/bin/env bash
# GAIA-owned Stop hook (merged: session-stop + safety-net).
#
# Two reminders share one git/jq pass:
#   1. WIKI_CHANGED, wiki/ files committed this session → prompt to refresh hot.md.
#   2. End-of-session safety net, session committed but wiki/.state.json did not
#      fully advance → nag to /gaia-wiki sync.
#
# Upstream contract: claude-obsidian/hooks/hooks.json::Stop. Why GAIA overrides:
# upstream diffs working tree vs HEAD, but its PostToolUse already auto-commits
# wiki/ changes, so its Stop diff is always empty and the refresh prompt never
# fires. We diff a session-start HEAD marker against HEAD instead. Reminder text
# uses GAIA's 200-word hot-cache cap (upstream caps at 500).

set -euo pipefail
trap 'exit 0' ERR

[ -d wiki ] || exit 0
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

session_marker="$GIT_DIR/claude-session-start"
[ -f "$session_marker" ] || exit 0

# GAIA CI deferral. When wiki.mode == "ci", local automatic triggers stand
# down so they don't collide with the cron-managed wiki run.
# The ERR trap is disarmed across the load, not merely `set +e`. The two are
# independent: the trap armed above fires on a failing command whatever errexit
# is set to, so an unparseable copy (an unresolved merge conflict, a truncated
# write) would fire it mid-source and exit 0 from inside the load, dropping the
# whole session-stop report, rather than degrading to "not managed" at the
# `type` check below. Rooted at this file's own on-disk location, never at the
# process working directory: a bare test is false from anywhere below the
# repository root, and the `type` check reads that as a missing library.
# Through the ancestor rather than a lib child, for the reason
# block-main-destructive-git.sh states at the same load: the ancestor cannot
# fail, so no degrade branch is owed.
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_defer_lib="$_hook_root/.claude/hooks/lib/gaia-ci-defer.sh"
trap - ERR
set +e
# shellcheck source=/dev/null
[ -n "$_hook_root" ] && [ -f "$_defer_lib" ] && . "$_defer_lib" 2>/dev/null
set -e
trap 'exit 0' ERR
if type gaia_ci_defer_if_managed >/dev/null 2>&1; then
  gaia_ci_defer_if_managed wiki || true
fi

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

# Reminder #1, wiki files modified this session → refresh hot cache.
#
# The listing is captured and matched from a here-string rather than piped into
# `grep -q`. A quiet grep exits at its first match and closes the pipe, the
# upstream `git log` takes SIGPIPE and exits 141, and `pipefail` promotes that
# to the pipeline's status -- so the `if` would take the FALSE branch BECAUSE a
# wiki path matched. A session's whole changed-path set is exactly the input
# that outruns the pipe buffer, and an early `wiki/` match is exactly the
# session this reminder exists for. `.gaia/scripts/lint-sigpipe-readers.sh` is
# the gate that keeps the shape from coming back.
session_paths="$(git log "$start_sha..HEAD" --name-only --pretty=format: 2>/dev/null || true)"
if grep -q '^wiki/' <<<"$session_paths"; then
  echo 'WIKI_CHANGED: Wiki pages were modified this session. Please update wiki/hot.md with a brief summary of what changed (under 200 words). Use the hot cache format: Last Updated, Key Recent Facts, Recent Changes, Active Threads. Keep it factual. Overwrite the file completely. It is a cache, not a journal.'
fi

# Reminder #2, safety net: did wiki state advance to HEAD?
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
        printf '[wiki end-of-session] You committed %s times this session but the wiki state SHA did not advance. Review wiki/log.md and run /gaia-wiki sync if needed before ending.\n' \
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
