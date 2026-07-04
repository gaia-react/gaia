#!/bin/bash
# local-janitor.sh, bounded GC for .gaia/local working-state residue.
#
# Side-effect only: deletes working-state that GAIA subsystems leave behind and
# never self-prune. Invoked from wiki-session-start.sh (a type:command
# SessionStart hook, the side-effect form Anthropic still permits; it injects
# NOTHING into context). Also runnable directly for testing:
#   bash .claude/hooks/local-janitor.sh
#
# This is the BACKSTOP, not the owner. Each subsystem still owns its own
# lifecycle (audit.md prunes its KNOWLEDGE reports; plan.md self-cleans on
# merge). The janitor only removes residue whose death is PROVABLE, so it is
# safe to run unconditionally every session. It sweeps exactly five things:
#
#   1. local wiki-sync/<date>-<sha> branches whose upstream is [gone]. The wiki
#      landing CLI (`gaia wiki chain finish` / `wiki sync land`) cuts a throwaway
#      branch, pushes it, and enables auto-merge with `gh pr merge --auto`, a
#      call that returns BEFORE the merge lands, so the local branch can never be
#      deleted inline and nothing else reconciles it. Once the PR squash-merges,
#      GitHub deletes the remote head branch and a later `git fetch --prune`
#      drops the tracking ref, leaving the local branch upstream marked [gone].
#      That [gone] marker on a machine-generated, disposable wiki-sync/* branch
#      is the provable-death signal (the normal per-branch PR-merge cleanup runs
#      no `git branch -D` here because the landing is fire-and-forget). This
#      sweep is git-scoped, so it runs before the .gaia/local guard below.
#   2. audit/<sha>.ok and audit/<sha>.dispositions.json whose <sha> is neither
#      HEAD nor reachable from any local branch. A marker gates `gh pr merge`
#      only when its <sha> == HEAD; once the PR squash-merges to a new sha the
#      audited branch tip is orphaned (reflog-only) and the marker is spent.
#      A <sha> that is not a valid commit (bogus/garbage) is treated as dead.
#   3. plans/<slug>/ and colocated specs/<SPEC-ID>/plan[-N]/ dirs whose RUNNING
#      sentinel names a branch that no longer exists AND is not marked
#      DEFERRED/PAUSED/PARKED. Branch-gone + not-parked means the plan merged
#      and its self-cleanup never ran (interrupted run). Archived, not deleted,
#      via plan-archive.sh, so SUMMARY.md/tokens.md survive the sweep.
#   4. empty leftover dirs under .gaia/local, EXCEPT the structural drop-zones
#      tooling expects to find. Pruned with `rmdir`, so a non-empty dir can
#      never be removed even if the logic is wrong.
#   5. stale SPEC-workflow cache artifacts (gate1-*.json, draft-*.md,
#      spec-session-*.json, audit-*/) and react-perf run dirs (<run>/renders.json)
#      at the root of .gaia/local/cache, once older than 14 days. Age-gated
#      rather than reference-checked: a generous window survives a paused
#      multi-day authoring session while still reaping abandoned drafts and
#      forgotten profiling dumps that no other owner ever cleans up.
#
# Fail-safe by construction: any inability to PROVE death (no git, unreadable
# HEAD, unparseable sentinel) SKIPS that item. It never deletes live state, and
# always exits 0 so it cannot block a session start.
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

# --- 1. Merged-and-gone wiki-sync branches ---------------------------------
# Git-scoped: independent of .gaia/local, so it runs before that guard (a fresh
# clone can carry an orphaned wiki-sync branch before any .gaia/local exists).
# List every local branch with its upstream-track state, filter to the
# disposable wiki-sync/* class whose upstream is [gone], and hard-delete it.
# `git branch -D` (not -d): a squash merge leaves the branch tip un-merged by
# ancestry, so `-d` would refuse. Fail-safe: the current branch is never a
# delete candidate (checkout-protected by git anyway), an empty/[]/[ahead]/
# [behind] track is skipped (remote head still present), and any git failure
# leaves the branch untouched.
current=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
branch_tracks=$(git -C "$root" for-each-ref \
  --format='%(refname:short) %(upstream:track)' refs/heads/ 2>/dev/null || true)
if [ -n "$branch_tracks" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref=${line%% *}                        # branch name (no spaces in a ref)
    track=${line#"$ref"}; track=${track# }  # remainder: [gone]/[ahead N]/... token
    case "$ref" in wiki-sync/*) ;; *) continue ;; esac
    [ "$ref" = "$current" ] && continue
    [ "$track" = "[gone]" ] || continue
    git -C "$root" branch -D "$ref" >/dev/null 2>&1 || true
  done <<EOF
$branch_tracks
EOF
fi

local_dir="$root/.gaia/local"
[ -d "$local_dir" ] || exit 0

# --- 2. Orphaned audit markers ---------------------------------------------
head_sha=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
audit_dir="$local_dir/audit"
if [ -d "$audit_dir" ]; then
  for marker in "$audit_dir"/*.ok "$audit_dir"/*.dispositions.json; do
    [ -e "$marker" ] || continue          # glob did not match
    base=${marker##*/}
    sha=${base%.ok}; sha=${sha%.dispositions.json}

    keep=0
    # The one live marker is the one for the commit about to merge: HEAD.
    [ -n "$head_sha" ] && [ "$sha" = "$head_sha" ] && keep=1
    # Otherwise keep iff the sha is a real commit reachable from a local branch
    # (a still-open feature line); orphaned reflog-only tips fall through.
    if [ "$keep" -eq 0 ] && git -C "$root" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      [ -n "$(git -C "$root" branch --contains "$sha" 2>/dev/null)" ] && keep=1
    fi

    [ "$keep" -eq 1 ] && continue
    rm -f -- "$marker"
  done
fi

# --- 3. Completed-but-unswept plan dirs ------------------------------------
plans_dir="$local_dir/plans"
specs_dir="$local_dir/specs"
for running in "$root/.gaia/local/plans"/*/RUNNING "$root/.gaia/local/specs"/*/plan/RUNNING \
  "$root/.gaia/local/specs"/*/plan-*/RUNNING; do
  [ -f "$running" ] || continue
  plan_dir=${running%/RUNNING}
  # Defensive: only ever act on a proper child of plans/, or a colocated
  # specs/<SPEC-ID>/plan[-N] dir.
  case "$plan_dir" in
    "$plans_dir"/?* | "$specs_dir"/*/plan | "$specs_dir"/*/plan-*) ;;
    *) continue ;;
  esac
  # Never sweep an intentionally parked plan.
  grep -qiE 'status:[[:space:]]*(DEFERRED|PAUSED|PARKED)' "$running" 2>/dev/null && continue
  # Branch token: first whitespace-delimited word after 'branch:'.
  branch=$(sed -nE 's/^branch:[[:space:]]*([^[:space:]]+).*/\1/p' "$running" 2>/dev/null | head -1)
  [ -n "$branch" ] || continue          # unparseable sentinel -> skip
  # Branch still exists -> plan may be in-flight -> keep.
  git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 && continue
  # Death proven: archive (not delete) so SUMMARY.md/tokens.md survive.
  plan_rel="${plan_dir#"$root"/}"
  bash "$root/.gaia/scripts/plan-archive.sh" "$plan_rel" >/dev/null 2>&1 || true
done

# --- 4. Stray empty dirs (keep the structural drop-zones) ------------------
is_drop_zone() {
  case "$1" in
    audit | audit/archived | cache | debt | forensics | handoff | plans \
      | plans/archived | red-ledger | red-ledger/.tmp | specs | specs/archived \
      | telemetry | telemetry/cloud) return 0 ;;
    *) return 1 ;;
  esac
}
empties=$(find "$local_dir" -mindepth 1 -type d -empty 2>/dev/null | sort -r)
if [ -n "$empties" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rel=${d#"$local_dir"/}
    is_drop_zone "$rel" && continue
    rmdir "$d" 2>/dev/null
  done <<EOF
$empties
EOF
fi

# --- 5. Stale cache artifacts (age-gated; generous window so paused authoring survives) ---
# cache/ is a drop-zone (kept alive above), but its contents are still fair
# game once provably stale: 14 days is generous enough that a paused
# multi-day authoring session's live gate1/draft never gets reaped mid-flight.
cache_dir="$local_dir/cache"
if [ -d "$cache_dir" ]; then
  find "$cache_dir" -maxdepth 1 \( \
      -name 'gate1-*.json' -o -name 'draft-*.md' -o -name 'spec-session-*.json' \
    \) -type f -mtime +14 -delete 2>/dev/null
  find "$cache_dir" -maxdepth 1 -type d -name 'audit-*' -mtime +14 -exec rm -rf {} + 2>/dev/null
  # react-perf run dumps: a dir at cache root containing renders.json. `dirname`
  # over a `while read` loop instead of `find -printf` for BSD/macOS find portability.
  find "$cache_dir" -maxdepth 2 -name 'renders.json' -mtime +14 -print 2>/dev/null | \
    while IFS= read -r hit; do
      rm -rf -- "$(dirname "$hit")"
    done
fi

exit 0
