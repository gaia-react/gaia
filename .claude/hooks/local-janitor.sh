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
# safe to run unconditionally every session. It sweeps exactly three things:
#
#   1. audit/<sha>.ok and audit/<sha>.dispositions.json whose <sha> is neither
#      HEAD nor reachable from any local branch. A marker gates `gh pr merge`
#      only when its <sha> == HEAD; once the PR squash-merges to a new sha the
#      audited branch tip is orphaned (reflog-only) and the marker is spent.
#      A <sha> that is not a valid commit (bogus/garbage) is treated as dead.
#   2. plans/<slug>/ whose RUNNING sentinel names a branch that no longer
#      exists AND is not marked DEFERRED/PAUSED/PARKED. Branch-gone + not-parked
#      means the plan merged and its self-cleanup never ran (interrupted run).
#   3. empty leftover dirs under .gaia/local, EXCEPT the structural drop-zones
#      tooling expects to find. Pruned with `rmdir`, so a non-empty dir can
#      never be removed even if the logic is wrong.
#
# Fail-safe by construction: any inability to PROVE death (no git, unreadable
# HEAD, unparseable sentinel) SKIPS that item. It never deletes live state, and
# always exits 0 so it cannot block a session start.
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
local_dir="$root/.gaia/local"
[ -d "$local_dir" ] || exit 0

# --- 1. Orphaned audit markers ---------------------------------------------
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

# --- 2. Completed-but-unswept plan dirs ------------------------------------
plans_dir="$local_dir/plans"
if [ -d "$plans_dir" ]; then
  for running in "$plans_dir"/*/RUNNING; do
    [ -f "$running" ] || continue
    plan_dir=${running%/RUNNING}
    # Defensive: only ever act on a proper child of plans/.
    case "$plan_dir" in "$plans_dir"/?*) ;; *) continue ;; esac
    # Never sweep an intentionally parked plan.
    grep -qiE 'status:[[:space:]]*(DEFERRED|PAUSED|PARKED)' "$running" 2>/dev/null && continue
    # Branch token: first whitespace-delimited word after 'branch:'.
    branch=$(sed -nE 's/^branch:[[:space:]]*([^[:space:]]+).*/\1/p' "$running" 2>/dev/null | head -1)
    [ -n "$branch" ] || continue          # unparseable sentinel -> skip
    # Branch still exists -> plan may be in-flight -> keep.
    git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 && continue
    rm -rf -- "$plan_dir"
  done
fi

# --- 3. Stray empty dirs (keep the structural drop-zones) ------------------
is_drop_zone() {
  case "$1" in
    audit | audit-ledger | cache | debt | forensics | handoff | plans \
      | red-ledger | red-ledger/.tmp | specs | specs/archived \
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

exit 0
