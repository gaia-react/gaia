#!/usr/bin/env bash
# PostToolUse hook on Bash matching `git commit`. Inject a one-line nudge
# into Claude's context with the commit metadata + current wiki drift count.
#
# Why: keeps Claude informed about wiki staleness without spawning sub-Claude
# processes. The hook costs zero extra API; the nudge is read by the active
# session at its existing token budget. See plan README for the full contract.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
[ -d .git ] || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Match `git commit` but not commit-tree / commit-graph
grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+commit([[:space:]]|$)' <<<"$cmd" || exit 0
# Skip --amend
grep -qE -- '--amend([[:space:]]|=|$)' <<<"$cmd" && exit 0

# GAIA CI deferral. When wiki.mode == "ci", local automatic triggers stand
# down so they don't collide with the cron-managed wiki run.
. .claude/hooks/lib/gaia-ci-defer.sh 2>/dev/null && gaia_ci_defer_if_managed wiki || true

head_sha=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
subject=$(git log -1 --format='%s' 2>/dev/null) || exit 0
files_changed=$(git show --stat --format='' HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ files? changed' | awk '{print $1}')
files_changed="${files_changed:-?}"

# Skip wiki/merge commits
case "$subject" in
  "wiki: "*|"Merge "*) exit 0 ;;
esac

# Drift calculation
drift_msg=""
if [ -f wiki/.state.json ]; then
  state_sha=$(jq -r '.last_evaluated_sha // empty' wiki/.state.json 2>/dev/null)
  if [ -n "$state_sha" ] && [ "$state_sha" != "0000000000000000000000000000000000000000" ]; then
    if git merge-base --is-ancestor "$state_sha" HEAD 2>/dev/null; then
      drift=$(git rev-list --count "$state_sha..HEAD" 2>/dev/null || echo "?")
      drift_msg=" Wiki state is now $drift commits behind."
    fi
  fi
fi

# Quote-escape subject for the printf
escaped_subject=$(printf '%s' "$subject" | sed 's/"/\\"/g')

printf '[wiki nudge] Committed %s: "%s". %s files changed.%s /gaia wiki sync when convenient.\n' \
  "$head_sha" "$escaped_subject" "$files_changed" "$drift_msg"

exit 0
