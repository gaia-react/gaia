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
# safe to run unconditionally every session. Before the sweeps below, it also
# best-effort runs the one-time ledger-status-migrate.sh, so every sweep that
# reads a ledger row's status sees the unified vocabulary. It then sweeps
# exactly eight things:
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
#   2. audit/<sha>.ok, audit/<sha>.dispositions.json, and the per-member
#      audit/<sha>.<member>.ok, whose <sha> is neither HEAD nor reachable from
#      any local branch. A marker gates `gh pr merge` only when its <sha> ==
#      HEAD; once the PR squash-merges to a new sha the audited branch tip is
#      orphaned (reflog-only) and the marker is spent. A <sha> that is not a
#      valid commit (bogus/garbage) is treated as dead.
#      2b. audit/<sha>.rerun.json carry-forward ledgers, on a DIFFERENT signal.
#      A ledger is keyed on the incremental base (a fork point), which is an
#      ancestor of the default branch, so reachability can never prove it dead.
#      It dies with the branch it records instead: code-audit-frontend deletes
#      it on a clean pass, so a ledger outliving its branch belongs to a line
#      abandoned before it ever reached clean, and nothing else reaps it.
#   3. plans/<slug>/ and colocated specs/<SPEC-ID>/plan[-N]/ dirs whose RUNNING
#      sentinel names a branch that no longer exists AND is not marked
#      DEFERRED/PAUSED/PARKED. Branch-gone + not-parked alone is not enough to
#      delete: the folder's durable identity record must also confirm it
#      terminal (a plans/ledger.json PLAN-NNN row at status merged, or a
#      specs/ledger.json row at status merged for a colocated plan). No row,
#      a non-terminal status, or a ledger-less free-form plan slug skips the
#      item and leaves it for a human decision. Only a confirmed-terminal
#      folder is handed to plan-archive.sh, which reduces or deletes it
#      (gated again there on cost representation).
#   4. empty leftover dirs under .gaia/local, EXCEPT the structural drop-zones
#      tooling expects to find. Pruned with `rmdir`, so a non-empty dir can
#      never be removed even if the logic is wrong.
#   5. stale SPEC-workflow cache artifacts (gate1-*.json, draft-*.md,
#      spec-session-*.json, spec-chain-*.json, audit-*/) and react-perf run dirs
#      (<run>/renders.json) at the root of .gaia/local/cache, once older than 14
#      days. A spec-chain-*.json is the spec→plan chain guard's per-session
#      sentinel (block-spec-plan-chain.sh); it is keyed on session_id, so an old
#      one can never match a live session and is inert long before it is stale.
#      All of them are age-gated
#      rather than reference-checked: a generous window survives a paused
#      multi-day authoring session while still reaping abandoned drafts and
#      forgotten profiling dumps that no other owner ever cleans up.
#   6. merged SPEC folders whose merged_at has aged past the retention window
#      (GAIA_SPEC_RETENTION_DAYS, default 30) AND whose cost is fully
#      represented. A merged SPEC folder is kept at merge and reaped only once
#      it clears both gates; this sweep is a thin delegation to
#      spec-archive-merged.sh, which owns both gates, symmetric with how
#      sweep #3 delegates plan-folder deletes to plan-archive.sh.
#   7. merged spec-less plan folders (reduced to SUMMARY.md + cost.json by
#      sweep #3's plan-archive.sh delegation) whose merged_at has aged past
#      the same retention window AND whose cost is fully represented. A thin
#      delegation to plan-archive-merged.sh, which owns both gates,
#      symmetric with sweep #6's spec-folder delegation.
#   8. telemetry/cloud/events-*.jsonl older than 14 days. The cloud stream has
#      no other reaper: `gaia mentorship purge` deliberately leaves it alone
#      (it purges mentorship data, and the cloud projection is a separate
#      consented stream), and telemetry/cloud is a structural drop-zone, so
#      sweep #4 keeps the directory alive without ever touching its contents.
#      Age-gated on the same 14-day window as sweep #5.
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

# --- One-time ledger status vocabulary migration ---------------------------
# Runs before the reap sweeps below so they read rows already on the unified
# vocabulary (ready|merged|abandoned) instead of a retired status.
migrate="$root/.gaia/scripts/ledger-status-migrate.sh"
[ -f "$migrate" ] && bash "$migrate" "$root" >/dev/null 2>&1 || true

# --- 2. Orphaned audit markers ---------------------------------------------
head_sha=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
audit_dir="$local_dir/audit"
if [ -d "$audit_dir" ]; then
  for marker in "$audit_dir"/*.ok "$audit_dir"/*.dispositions.json; do
    [ -e "$marker" ] || continue          # glob did not match
    base=${marker##*/}
    # A sha never contains a dot, so strip from the FIRST one. That resolves
    # every suffix family uniformly: the plain <sha>.ok and
    # <sha>.dispositions.json, and the per-member <sha>.<member>.ok the Code
    # Audit Team writes. Peeling only the trailing .ok would leave
    # "<sha>.<member>", which resolves to no commit, so a LIVE member marker at
    # HEAD would read as dead and be deleted out from under the merge gate.
    sha=${base%%.*}

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

  # 2b. Re-run carry-forward ledgers. These need a DIFFERENT liveness test than
  # the markers above: a ledger is keyed on the incremental base (the fork point
  # `git merge-base "$BASE_REF" HEAD`), not a branch tip, and a fork point is an
  # ancestor of the default branch by construction, so `branch --contains` always
  # answers "reachable" and the reachability test above can never reap one. The
  # ledger's real death signal is the branch it was audited for, which it records:
  # code-audit-frontend deletes the ledger on a clean pass, so one that outlives
  # its branch belongs to a line abandoned before it ever reached clean.
  # Fail-safe: no jq, an unparseable ledger, or no recorded branch skips the file.
  for ledger in "$audit_dir"/*.rerun.json; do
    [ -e "$ledger" ] || continue          # glob did not match
    command -v jq >/dev/null 2>&1 || break
    ledger_branch=$(jq -r '.branch // empty' "$ledger" 2>/dev/null)
    [ -n "$ledger_branch" ] || continue   # unparseable / no branch -> skip
    # Branch still exists -> the audit line may be in-flight -> keep.
    git -C "$root" rev-parse --verify --quiet "refs/heads/$ledger_branch" \
      >/dev/null 2>&1 && continue
    rm -f -- "$ledger"
  done
fi

# --- 3. Completed-but-unswept plan dirs ------------------------------------
plans_dir="$local_dir/plans"
specs_dir="$local_dir/specs"
plans_ledger="$plans_dir/ledger.json"
specs_ledger="$specs_dir/ledger.json"
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

  # Terminal-ledger + identity gate: branch-gone alone never authorizes a
  # delete once archive is no longer the reversible fallback. Only a folder
  # whose durable identity record is confirmed terminal proceeds; any
  # inability to resolve that record (no jq, unreadable ledger, no row, a
  # non-terminal status, or a ledger-less free-form slug) skips the item.
  terminal=0
  case "$plan_dir" in
    "$plans_dir"/*)
      plan_slug=${plan_dir#"$plans_dir"/}
      case "$plan_slug" in
        PLAN-*)
          plan_num="${plan_slug#PLAN-}"
          case "$plan_num" in
            ''|*[!0-9]*) ;;  # not a PLAN-NNN shape -> no durable identity
            *)
              if command -v jq >/dev/null 2>&1 && [ -f "$plans_ledger" ]; then
                row_status=$(jq -r --arg id "$plan_slug" \
                  '.plans[]? | select(.id == $id) | .status // empty' \
                  "$plans_ledger" 2>/dev/null | head -1)
                [ "$row_status" = "merged" ] && terminal=1
              fi
              ;;
          esac
          ;;
        *) ;;  # free-form slug: no durable identity (FC-4) -> never delete
      esac
      ;;
    *)
      # Colocated specs/<SPEC-ID>/plan[-N]: identity is the parent SPEC.
      spec_rel=${plan_dir#"$specs_dir"/}
      spec_id=${spec_rel%%/*}
      if command -v jq >/dev/null 2>&1 && [ -f "$specs_ledger" ]; then
        row_status=$(jq -r --arg id "$spec_id" \
          '.specs[]? | select(.id == $id) | .status // empty' \
          "$specs_ledger" 2>/dev/null | head -1)
        [ "$row_status" = "merged" ] && terminal=1
      fi
      ;;
  esac
  [ "$terminal" -eq 1 ] || continue

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
      -o -name 'spec-chain-*.json' \
    \) -type f -mtime +14 -delete 2>/dev/null
  find "$cache_dir" -maxdepth 1 -type d -name 'audit-*' -mtime +14 -exec rm -rf {} + 2>/dev/null
  # react-perf run dumps: a dir at cache root containing renders.json. `dirname`
  # over a `while read` loop instead of `find -printf` for BSD/macOS find portability.
  find "$cache_dir" -maxdepth 2 -name 'renders.json' -mtime +14 -print 2>/dev/null | \
    while IFS= read -r hit; do
      rm -rf -- "$(dirname "$hit")"
    done
fi

# --- 6. Age-reap merged SPEC folders past the retention window -------------
# Merged SPEC folders are kept at merge and reaped only once merged past the
# retention window (GAIA_SPEC_RETENTION_DAYS, default 30) AND cost-represented.
# The age + cost gates live in spec-archive-merged.sh, so this is a thin
# delegation, symmetric with sweep #3's plan-archive.sh delegation. Fail-open:
# a missing script is a silent no-op, and the script itself always exits 0.
archive_merged="$root/.specify/extensions/gaia/lib/spec-archive-merged.sh"
if [ -x "$archive_merged" ] || [ -f "$archive_merged" ]; then
  bash "$archive_merged" "$root" >/dev/null 2>&1 || true
fi

# --- 7. Age-reap merged spec-less plan folders past the retention window ---
archive_plan="$root/.specify/extensions/gaia/lib/plan-archive-merged.sh"
if [ -x "$archive_plan" ] || [ -f "$archive_plan" ]; then
  bash "$archive_plan" "$root" >/dev/null 2>&1 || true
fi

# --- 8. Stale cloud telemetry events (age-gated, same window as sweep 5) ----
# telemetry/cloud is a drop-zone (kept alive by sweep 4), but nothing reaps its
# contents: `gaia mentorship purge` documents that it never touches the cloud
# stream, so events-*.jsonl accumulates for the life of the checkout. The
# janitor owns the rotation, on the same generous 14-day window sweep 5 uses.
# Name-scoped to events-*.jsonl, so anything else in the drop-zone survives.
cloud_dir="$local_dir/telemetry/cloud"
if [ -d "$cloud_dir" ]; then
  find "$cloud_dir" -maxdepth 1 -name 'events-*.jsonl' -type f -mtime +14 -delete 2>/dev/null
fi

exit 0
