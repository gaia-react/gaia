#!/usr/bin/env bash
# Stop hook: end-of-session safety net. If the session committed but the wiki
# state SHA did not advance, inject a reminder to /wiki-sync before ending.
#
# Why: drift-check catches drift across sessions; this catches drift within.
# Together they ensure the wiki converges to HEAD before meaningful work
# proceeds. See .claude/plans/wiki-sync-system/README.md for the full contract.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
[ -d .git ] || exit 0
[ -f wiki/.state.json ] || exit 0

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
session_marker="$GIT_DIR/claude-session-start"
[ -f "$session_marker" ] || exit 0

payload=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$session_id" ] || exit 0

marker=".claude/wiki-safety-checked"
if [ -f "$marker" ] && grep -q "^session_id=$session_id$" "$marker" 2>/dev/null; then
  exit 0
fi

start_sha=$(cat "$session_marker" 2>/dev/null)
[ -n "$start_sha" ] || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

# Session made no commits → nothing to nag about
[ "$start_sha" = "$head_sha" ] && exit 0

# Reachability check (rebase, reset, shallow clone → bail silently)
git merge-base --is-ancestor "$start_sha" HEAD 2>/dev/null || exit 0

state_sha=$(jq -r '.last_evaluated_sha // empty' wiki/.state.json 2>/dev/null || echo "")
[ -n "$state_sha" ] || exit 0
case "$state_sha" in
  0000000000000000000000000000000000000000) exit 0 ;;
esac

# State advanced fully to current HEAD → nothing to nag.
[ "$state_sha" = "$head_sha" ] && exit 0

# Otherwise: session committed but state did not fully advance.
commits_this_session=$(git rev-list --count "$start_sha..HEAD" 2>/dev/null || echo 0)

printf '[wiki end-of-session] You committed %s times this session but the wiki state SHA did not advance. Review wiki/log.md and run /wiki-sync if needed before ending.\n' \
  "$commits_this_session"

mkdir -p .claude
{
  printf 'session_id=%s\n' "$session_id"
  printf 'checked_at=%s\n' "$(date -u +%FT%TZ)"
  printf 'commits_this_session=%s\n' "$commits_this_session"
} > "$marker"

exit 0
