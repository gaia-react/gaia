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

# Root resolution, hoisted above the drain below because that block is itself
# hoisted above every early exit and so must not depend on any of them. Two
# values, because this hook spans two questions one root cannot answer:
#
#   _hook_root  WHERE this checkout's own libraries are, from this file's
#               on-disk location rather than the process working directory.
#               Used for both the resolver load here and the deferral lib
#               further down.
#   main_root   WHICH TREE the base-catch-up report belongs to. It is
#               main-anchored shared state: local-janitor.sh writes it under
#               gaia_resolve_main_root, so the reader names that same root
#               rather than resolving whatever tree the drain happens to run
#               in. From any directory below a checkout's root the two answers
#               differ outright. From a worktree ROOT they happen to agree,
#               but only through provisioning: provision-worktree.sh replaces
#               a linked worktree's .gaia/local with one symlink to main's, so
#               a working-directory-relative path landed on main's store by a
#               second mechanism rather than by naming it. That hook exists to
#               repair the symlink whenever it finds it broken, which is the
#               statement that it can be, so the drain does not rest on it.
#
# Bracketed in `set +e` because errexit is armed above, matching the deferral
# load below. The fallback chain ends at `pwd`, which is exactly what a bare
# repo-relative literal resolves to, so a checkout where neither the resolver
# nor git answers behaves as it did before the path was rooted at all.
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_main_root_lib="$_hook_root/.gaia/scripts/main-root-lib.sh"
set +e; [ -n "$_hook_root" ] && [ -f "$_main_root_lib" ] && . "$_main_root_lib" 2>/dev/null; set -e
main_root=''
if type gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root=''
fi
[ -n "$main_root" ] || main_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Drain the janitor's one-line base-catch-up report, if any. Delivered here
# because a UserPromptSubmit hook's stdout is injected into the conversation,
# which a SessionStart hook's exit-0 stderr is not. Read-and-delete, so the
# line surfaces exactly once. Never blocks: any failure is a silent skip.
# Placed above every early exit below (jq, work-tree, wiki/.state.json) so a
# checkout missing any of those still delivers the line; nothing has consumed
# stdin yet at this point.
catchup_report="$main_root/.gaia/local/cache/shared/wiki-base-catchup.report"
if [ -f "$catchup_report" ]; then
  head -n 1 "$catchup_report" 2>/dev/null || true
  rm -f "$catchup_report" 2>/dev/null || true
fi

command -v jq >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -f wiki/.state.json ] || exit 0

payload=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$session_id" ] || exit 0

# Deliberately bare, unlike the main-rooted report above. This marker is
# per-tree session state: it belongs to whichever checkout the session runs in,
# which is what a path relative to the working directory names here, because
# the `wiki/.state.json` test above has already exited from anywhere the
# working directory is not that checkout's root.
marker=".claude/wiki-drift-checked"
if [ -f "$marker" ] && grep -q "^session_id=$session_id$" "$marker" 2>/dev/null; then
  exit 0
fi

# GAIA CI deferral. When wiki.mode == "ci", local automatic triggers stand
# down so they don't collide with the cron-managed wiki run. The marker is
# NOT advanced here so a future config change still gets the drift check.
# Bracketed in `set +e` because errexit is armed above: an unparseable copy (an
# unresolved merge conflict, a truncated write) would otherwise abandon the hook
# at the load, before the `type` check below can degrade it to "not managed".
# Reuses the `_hook_root` resolved at the top of this file, which is this
# file's own on-disk location and never the process working directory: a bare
# test is false from anywhere below the repository root, and the `type` check
# reads that as a missing library. Through the ancestor rather than a lib
# child, for the reason block-main-destructive-git.sh states at the same load:
# the ancestor cannot fail, so no degrade branch is owed.
_defer_lib="$_hook_root/.claude/hooks/lib/gaia-ci-defer.sh"
set +e; [ -n "$_hook_root" ] && [ -f "$_defer_lib" ] && . "$_defer_lib" 2>/dev/null; set -e
if type gaia_ci_defer_if_managed >/dev/null 2>&1; then
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
