#!/usr/bin/env bash
# UserPromptSubmit hook: detect drift between wiki/.state.json and HEAD,
# inject a once-per-session reminder if drifted.
#
# Why: the wiki only stays accurate if drift is surfaced. Hooks are read-only
# consumers of state; only /gaia-wiki sync writes wiki/.state.json. See
# wiki/concepts/Wiki Sync.md for the full contract.

set -euo pipefail

# Best-effort: any internal failure exits 0. Never block prompt submission.
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
[ -d .git ] || exit 0
[ -f wiki/.state.json ] || exit 0

payload=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$session_id" ] || exit 0

marker=".claude/wiki-drift-checked"
if [ -f "$marker" ] && grep -q "^session_id=$session_id$" "$marker" 2>/dev/null; then
  exit 0
fi

# GAIA CI deferral. When wiki.mode == "ci", local automatic triggers stand
# down so they don't collide with the cron-managed wiki run. The marker is
# NOT advanced here so a future config change still gets the drift check.
if [ -f .claude/hooks/lib/gaia-ci-defer.sh ]; then
  . .claude/hooks/lib/gaia-ci-defer.sh
  gaia_ci_defer_if_managed wiki || true
fi

state_sha=$(jq -r '.last_evaluated_sha // empty' wiki/.state.json 2>/dev/null || echo "")
[ -n "$state_sha" ] || exit 0
case "$state_sha" in
  0000000000000000000000000000000000000000|"") exit 0 ;;
esac

# Sha must be reachable from HEAD (silently bail on rebased/unreachable history)
git merge-base --is-ancestor "$state_sha" HEAD 2>/dev/null || exit 0

# Exclude the sync's own bookkeeping commit. `gaia wiki sync land` records
# last_evaluated_sha = HEAD *before* writing its `wiki: sync through <sha>`
# commit, so that commit always lands one ahead of the SHA the sync just
# recorded. Counting it nags the maintainer to re-sync the instant a sync
# finishes, where the next sync only SKIPs it as self-referential. Drop it so
# the nudge reflects genuine un-evaluated work, not the sync's own footprint.
drift_count=$(git rev-list --count --invert-grep --grep='^wiki: sync through ' "$state_sha..HEAD" 2>/dev/null || echo 0)
short_sha=$(git rev-parse --short "$state_sha" 2>/dev/null || echo "$state_sha")

if [ "$drift_count" -gt 0 ]; then
  printf '[wiki state] HEAD is %s commits ahead of last evaluated SHA (%s). Run /gaia-wiki sync to evaluate, or proceed if you will address this elsewhere.\n' \
    "$drift_count" "$short_sha"
fi

mkdir -p .claude
{
  printf 'session_id=%s\n' "$session_id"
  printf 'checked_at=%s\n' "$(date -u +%FT%TZ)"
  printf 'drift_count=%s\n' "$drift_count"
} > "$marker"

exit 0
