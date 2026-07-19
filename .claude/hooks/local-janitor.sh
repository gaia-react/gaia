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
# best-effort runs two one-time, guarded cleanups: ledger-status-migrate.sh, so
# every sweep that reads a ledger row's status sees the unified vocabulary, and
# the residue sweep its own block further down documents. It then sweeps
# exactly nine things:
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
#   2. audit/<digest>.ok, the per-member audit/<digest>.<member>.ok, and
#      audit/<digest>.refused (and their per-member forms) -- the Code Audit
#      Team's earned and refused clearance markers. <digest> is a content
#      digest over exactly the files the audited member owns plus the shared
#      gate machinery, not a git object, so liveness is read off each
#      marker's own body: a marker is kept when its recorded tree (a plain
#      data field) is a live branch or worktree tip, or when it is still
#      within GAIA_AUDIT_MARKER_RETENTION_HOURS (default 72) of its own
#      recorded audited_at, or -- for the frontend earned marker only --
#      when its co-keyed disposition sidecar still holds a still-open
#      out-of-scope finding. Everything else is spent residue and is reaped:
#      any old-scheme (pre-digest) marker, any body lacking a `.digest`
#      field, the deleted carry-forward feature's `.carried` family, and the
#      CI-observability audit/<tree>.progress.log breadcrumb (a data
#      artifact, never re-keyed as if it were a clearance). The disposition
#      sidecar audit/<digest>.dispositions.json is reaped alongside its
#      marker unless its own digest is one still holding an open receipt.
#      2b. audit/<sha>.rerun.json carry-forward ledgers, on a DIFFERENT
#      signal. A ledger is keyed on the incremental base (a fork point),
#      which is an ancestor of the default branch, so no tree/branch
#      liveness test can ever prove it dead. It dies with the branch it
#      records instead: code-audit-frontend deletes it on a clean pass, so a
#      ledger outliving its branch belongs to a line abandoned before it ever
#      reached clean, and nothing else reaps it.
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
#   8. orphaned GAIA worktrees under .claude/worktrees/ whose branch upstream
#      is [gone] (the same provable-death signal sweep #1 uses for
#      wiki-sync/* branches) and whose working tree is clean. A crashed or
#      abandoned session leaves the worktree dir behind after its PR
#      squash-merges, and nothing else reclaims it. Never age-reap: there is
#      no session-liveness signal, so an old worktree may still be a live
#      long-running session. Teardown delegates to the WorktreeRemove hook's
#      own remove-worktree.sh so remove + branch-delete + parent-prune stays
#      defined in one place.
#   9. off-pattern outlier residue: anything NOT on an explicit per-root
#      allowlist, at the top level of .gaia/local plus the direct children
#      (maxdepth-1, mindepth-1, no deeper) of audit/ and cache/, once its
#      mtime clears GAIA_OUTLIER_RETENTION_DAYS (default 7, floor 2); OS junk
#      (.DS_Store, Thumbs.db, ._*) is reaped at any age. It never recurses
#      below maxdepth-1 to delete and never enters the ledger / self-managing
#      zones (telemetry/, red-ledger/, handoff/, plans/, specs/, debt/,
#      forensics/, and the audit/archived, audit/security, and
#      audit/comprehensive subtrees), nor follows a symlinked scope root from
#      a linked worktree. Two off-pattern writers get their own dedicated arms
#      instead of the blanket allowlist reap, each on its own floored knob:
#      audit/*.findings.json attached to sweep #2
#      (GAIA_AUDIT_FINDINGS_RETENTION_HOURS, default 72, floor 24) and
#      cache/gh-artifact-pr.json attached to sweep #5
#      (GAIA_CACHE_ARTIFACT_RETENTION_DAYS, default 2, floor 1).
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

# --- Sweep #9 allowlists (single source of truth) ---------------------------
#
# The completed per-writer census: every subsystem known to write to these
# three roots. Each array holds the exact names / globs a root's children
# must NOT be reaped for; a directory-typed entry carries a trailing "/"
# (matched only against a directory child, slash stripped before the glob
# compare) so one shared matcher (janitor_outlier_kept below) can read
# straight off these arrays with no parallel type list to drift out of sync.
# The disjoint-owner guard test reads these same arrays from source, so they
# are the single frozen source of truth for both what sweep #9 keeps and what
# the guard checks -- never re-derive them here.
JANITOR_OUTLIER_ALLOW_TOPLEVEL=(
  maintainer-statusline.sh .patched-statusline.sh .project-id
  .mentorship-swept setup-state.json declined-updates.json
  automation.json sandbox.json dep-audit-baseline.json setup-in-progress
  audit/ cache/ debt/ forensics/ handoff/ plans/ red-ledger/ specs/ telemetry/
  worktree-locks/ harden/
)
JANITOR_OUTLIER_ALLOW_AUDIT=(
  '*.ok' '*.refused' '*.carried' '*.dispositions.json' '*.progress.log'
  '*.rerun.json' '*.findings.json' worthiness.jsonl 'KNOWLEDGE-*.md'
  archived/ security/ comprehensive/
)
JANITOR_OUTLIER_ALLOW_CACHE=(
  'gate1-*.json' 'draft-*.md' draft.md 'spec-session-*.json' 'spec-chain-*.json'
  gh-artifact-pr.json version-check.lock v2-update-notes.md
  'audit-*/' wiki-promote/ uat-write/ shared/
)

# janitor_outlier_kept <name> <type: f|d> <allow-entries...>: exit 0 iff
# <name> (a file/dotfile when <type> is f, a directory when <type> is d)
# matches one of the given allowlist entries for its own type. See the array
# comment above for the trailing-"/" directory-entry convention.
janitor_outlier_kept() {
  local name="$1" etype="$2"
  shift 2
  local entry pattern
  for entry in "$@"; do
    case "$entry" in
      */)
        [ "$etype" = d ] || continue
        pattern="${entry%/}"
        ;;
      *)
        [ "$etype" = f ] || continue
        pattern="$entry"
        ;;
    esac
    # Deliberate glob match: $pattern holds an allowlist entry (e.g.
    # 'KNOWLEDGE-*.md'), never a literal to compare byte-for-byte.
    # shellcheck disable=SC2254
    case "$name" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# janitor_outlier_is_old <path> <days>: exit 0 iff <path>'s own mtime is older
# than <days>. `-maxdepth 0` bounds `find` to the path itself, so a
# directory's age is judged as one unit, never by its contents.
janitor_outlier_is_old() {
  [ -n "$(find "$1" -maxdepth 0 -mtime "+$2" 2>/dev/null)" ]
}

# janitor_sweep_outliers <local_dir>: the allowlist-based ninth sweep. Walks
# exactly three scope roots (top level of <local_dir>, its audit/, its
# cache/), each at maxdepth-1/mindepth-1, and reaps any child not on that
# root's allowlist once older than GAIA_OUTLIER_RETENTION_DAYS (OS junk at any
# age). Self-contained: reads its own knob, computes its own cutoff, resolves
# real directories only (never follows a symlinked scope root, so a run from
# a linked worktree never deletes another checkout's state, and never reaps a
# symlinked entry), and never recurses below maxdepth-1 to
# delete -- the one exception, a bounded one-level peek for a `renders.json`
# child, only ever KEEPS. No stdout; deletes in place; always returns 0.
janitor_sweep_outliers() {
  local scope_root="$1"
  [ -n "$scope_root" ] && [ -d "$scope_root" ] || return 0

  local outlier_days
  outlier_days="${GAIA_OUTLIER_RETENTION_DAYS:-7}"
  case "$outlier_days" in '' | *[!0-9]*) outlier_days=7 ;; esac
  [ "$outlier_days" -lt 2 ] && outlier_days=2

  local zone sroot child base etype candidate
  for zone in toplevel audit cache; do
    case "$zone" in
      toplevel) sroot="$scope_root" ;;
      audit)    sroot="$scope_root/audit" ;;
      cache)    sroot="$scope_root/cache" ;;
    esac
    [ -e "$sroot" ] || continue
    [ -L "$sroot" ] && continue   # never walk through a symlinked scope root
    [ -d "$sroot" ] || continue

    for child in "$sroot"/* "$sroot"/.[!.]*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      [ -L "$child" ] && continue   # never reap a symlinked entry
      base=${child##*/}
      if [ -d "$child" ]; then etype=d; else etype=f; fi

      # OS junk: reaped at any age, the only age-independent case.
      case "$base" in
        .DS_Store | Thumbs.db | ._*)
          rm -rf -- "$child"
          continue
          ;;
      esac

      candidate=1
      case "$zone" in
        toplevel)
          janitor_outlier_kept "$base" "$etype" ${JANITOR_OUTLIER_ALLOW_TOPLEVEL[@]+"${JANITOR_OUTLIER_ALLOW_TOPLEVEL[@]}"} && candidate=0
          ;;
        audit)
          janitor_outlier_kept "$base" "$etype" ${JANITOR_OUTLIER_ALLOW_AUDIT[@]+"${JANITOR_OUTLIER_ALLOW_AUDIT[@]}"} && candidate=0
          ;;
        cache)
          janitor_outlier_kept "$base" "$etype" ${JANITOR_OUTLIER_ALLOW_CACHE[@]+"${JANITOR_OUTLIER_ALLOW_CACHE[@]}"} && candidate=0
          # Bounded one-level renders.json protection: a not-otherwise-
          # allowlisted cache/ child directory still keeps if it
          # directly holds a renders.json file (a react-perf run dir, whose
          # own name is arbitrary). Only ever KEEPS, never reaps.
          if [ "$candidate" -eq 1 ] && [ "$etype" = d ] && [ -f "$child/renders.json" ]; then
            candidate=0
          fi
          ;;
      esac
      [ "$candidate" -eq 1 ] || continue

      janitor_outlier_is_old "$child" "$outlier_days" || continue
      if [ "$etype" = d ]; then
        rm -rf -- "$child"
      else
        rm -f -- "$child"
      fi
    done
  done
  return 0
}

# --- Isolation entrypoint (bats-only) ---------------------------------------
# GAIA_JANITOR_SWEEP_ONLY=outliers runs ONLY sweep #9 against $local_dir, then
# exits, skipping sweeps 2-8 and the one-time ledger-migrate / mentorship-
# cleanup blocks below so the bats suite can exercise sweep #9 with zero
# interference. Sweep #1 (git-branch-scoped, above the $local_dir guard) has
# already run by this point; it is a no-op on file-only isolation fixtures.
if [ "${GAIA_JANITOR_SWEEP_ONLY:-}" = outliers ]; then
  janitor_sweep_outliers "$local_dir"
  exit 0
fi

# --- One-time ledger status vocabulary migration ---------------------------
# Runs before the reap sweeps below so they read rows already on the unified
# vocabulary (ready|merged|abandoned) instead of a retired status.
migrate="$root/.gaia/scripts/ledger-status-migrate.sh"
[ -f "$migrate" ] && bash "$migrate" "$root" >/dev/null 2>&1 || true

# --- One-time mentorship-residue cleanup sweep -----------------------------
# Sentinel-guarded, idempotent, silent, best-effort. Deletes the off-repo
# mentorship store, the computed profile, the install id and the directory
# holding it, the display-rule memory file and its MEMORY.md pointer line, the
# in-repo opt-in config and its worktree symlink, the in-repo cloud stream, and
# the in-repo analytics reports. Never blocks a session.
sweep="$root/.gaia/scripts/mentorship-cleanup-sweep.sh"
[ -f "$sweep" ] && bash "$sweep" "$root" >/dev/null 2>&1 || true

# --- 2. Orphaned audit markers ---------------------------------------------
#
# A clearance marker's filename key is a 64-hex CONTENT DIGEST over exactly
# the files the audited member owns plus the shared gate machinery, not a git
# tree or commit sha, so the key resolves to no git object and no
# `cat-file`/`branch --contains` reachability call can ever answer "live" for
# one. Liveness is read off each marker's own JSON body instead, through
# three cheap, key-shape-agnostic keep-arms that never recompute a digest:
#
#   Keep-arm A (live-tree)        keep any new-scheme marker whose body
#     `.tree` (the real HEAD^{tree} recorded as plain data at write time) is
#     one of the once-computed live_trees (every local branch tip and linked
#     worktree HEAD). Preserves a marker for a live idle branch.
#   Keep-arm B (retention window) keep any new-scheme `.ok`/`.refused` marker
#     within GAIA_AUDIT_MARKER_RETENTION_HOURS (default 72) of its own
#     recorded `audited_at`, so a marker outlives the session that earned it
#     even once its tree falls off every branch tip.
#   Keep-arm C (open-receipt durability) keep a frontend `<digest>.ok` marker
#     together with its co-keyed `<digest>.dispositions.json` sidecar
#     whenever that sidecar still holds a still-open entry (disposition
#     "filed", or "pending" with pending_reason "definitive" -- the same
#     predicate the disposition seed-forward machinery uses), so a >72h idle
#     gap between audit rounds can never let a still-open out-of-scope
#     receipt age out from under a live predecessor.
#
# A marker is NEW-SCHEME iff its filename stem-before-first-dot is 64-hex AND
# its body's `.digest` equals that stem; only a new-scheme `.ok`/`.refused`
# marker is keep-eligible at all. Every old-scheme artifact -- a 40-hex
# tree/sha-keyed `.ok`/`.refused`, any `.carried` (the deleted carry-forward
# family), an old sha-keyed `<sha>.dispositions.json`, a `<tree>.progress.log`
# CI-observability breadcrumb (a data artifact, never re-keyed as if it were
# a clearance), or a body lacking `.digest` -- fails that structural test and
# is reaped, cheaply completing the cutover with no migration code.
#
# A digest-keyed `<digest>.dispositions.json` sidecar is kept iff its digest
# is in the open-receipt set (keep-arm C) OR a same-digest `.ok`/`.refused`
# marker was kept this same pass by arm A or B; otherwise it is reaped
# alongside its marker, preserving co-reap symmetry.
#
# One O(markers + sidecars) pass: live_trees is computed once, "now" and the
# retention window are computed once, and the open-receipt set is one bounded
# jq read per sidecar (there are few -- only the frontend files one). No git
# call and no digest recompute happens inside the per-marker loop.

# The live tree set: every tree an audit could still be merging. Local refs are
# shared across linked worktrees, and the audit drop-zone is symlinked into each
# of them, so a sweep launched from one worktree judges every worktree's
# markers. Collect the branch tips AND each worktree's HEAD (which covers a
# detached checkout no branch names) so a sweep here never reaps a live marker
# belonging to a parallel audit over there.
live_trees=$(
  {
    git -C "$root" for-each-ref --format='%(objectname)' refs/heads/ 2>/dev/null || true
    git -C "$root" worktree list --porcelain 2>/dev/null \
      | awk '$1 == "HEAD" { print $2 }' || true
  } | sort -u | while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    git -C "$root" rev-parse "${commit}^{tree}" 2>/dev/null || true
  done
)

# Retention window: computed ONCE here, never once per marker. A non-numeric
# override falls back to the default rather than disabling the window.
retention_hours="${GAIA_AUDIT_MARKER_RETENTION_HOURS:-72}"
case "$retention_hours" in '' | *[!0-9]*) retention_hours=72 ;; esac
retention_seconds=$(( retention_hours * 3600 ))
now_epoch=$(date -u +%s 2>/dev/null || echo 0)
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# janitor_digest_key <str>: exit 0 iff <str> is exactly 64 lowercase-hex
# characters, the new-scheme filename-key shape. Pure string test, no fork.
janitor_digest_key() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# janitor_new_scheme_fields <path> <expected_digest>: ONE jq fork. Prints
# "<tree>\t<audited_at-epoch>" on stdout ONLY when the body's `.digest`
# equals <expected_digest> (the new-scheme validity gate); prints nothing for
# an old-scheme body, an unparseable one, or a digest mismatch, so the caller
# falls through to reap on empty output alone. A malformed `audited_at`
# yields an empty epoch field (via jq `try`/`catch`) rather than failing the
# whole read, so a live-tree marker with a corrupt timestamp still keeps via
# keep-arm A.
janitor_new_scheme_fields() {
  jq -r --arg digest "$2" '
    if (.digest // empty) == $digest then
      (.tree // "") + "\t" +
      ((.audited_at // "") as $a
        | if $a == "" then ""
          else (try (($a | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | tostring) catch "")
          end)
    else empty end
  ' "$1" 2>/dev/null
}

# janitor_sidecar_has_open_receipt <path>: ONE jq fork. Exit 0 iff the
# sidecar holds at least one still-open entry, using the SAME predicate
# task-dispositions' disposition_seed_forward uses: disposition "filed", OR
# disposition "pending" with pending_reason "definitive".
janitor_sidecar_has_open_receipt() {
  jq -e '
    any(.findings[]?;
      ((.disposition // "") == "filed")
      or (((.disposition // "") == "pending") and ((.pending_reason // "") == "definitive"))
    )
  ' "$1" >/dev/null 2>&1
}

audit_dir="$local_dir/audit"
if [ -d "$audit_dir" ]; then
  # Keep-arm C precompute: the digests of every dispositions sidecar that
  # still holds a still-open entry. Only the frontend files a sidecar, so
  # this set is small: one bounded jq read per sidecar file, never per
  # marker. jq absent -> empty set, a no-op (a marker then survives only by
  # A/B); acceptable because the disposition GATE itself fails closed on jq
  # absence, so a lost receipt can never silently clear a merge that way.
  open_receipt_digests=""
  if [ "$have_jq" -eq 1 ]; then
    for sidecar in "$audit_dir"/*.dispositions.json; do
      [ -e "$sidecar" ] || continue          # glob did not match
      sbase=${sidecar##*/}
      sdigest=${sbase%%.*}
      janitor_digest_key "$sdigest" || continue
      if janitor_sidecar_has_open_receipt "$sidecar"; then
        open_receipt_digests="${open_receipt_digests}${sdigest}
"
      fi
    done
  fi

  # Digests of *.ok/*.refused markers this pass keeps by arm A or B, one per
  # line. A co-keyed sidecar checked further below (the glob visits every
  # *.ok/*.refused before any *.dispositions.json) uses this set as its
  # second keep condition, alongside the open-receipt set above.
  kept_marker_digests=""

  for marker in "$audit_dir"/*.ok "$audit_dir"/*.refused "$audit_dir"/*.carried \
                "$audit_dir"/*.dispositions.json "$audit_dir"/*.progress.log; do
    [ -e "$marker" ] || continue          # glob did not match
    base=${marker##*/}
    # An object id never contains a dot, so strip from the FIRST one -- the
    # same idiom the old tree/sha scheme used, now isolating the digest: the
    # plain <digest>.ok, the per-member <digest>.<member>.ok, and
    # <digest>.dispositions.json all resolve correctly.
    key=${base%%.*}
    keep=0

    case "$base" in
      *.ok | *.refused)
        if [ "$have_jq" -eq 1 ] && janitor_digest_key "$key"; then
          fields=$(janitor_new_scheme_fields "$marker" "$key")
          if [ -n "$fields" ]; then
            body_tree=${fields%%$'\t'*}
            body_epoch=${fields#*$'\t'}

            # Keep-arm A: the marker's own tree is a live branch/worktree tip.
            #
            # Match with a herestring, never `printf ... | grep -q`. Under
            # `pipefail`, `grep -q` exits the instant it matches, `printf`
            # then takes SIGPIPE, and the pipeline reports 141 -- so a MATCH
            # would read as a miss and this reaps the live marker it just
            # found. The herestring has no pipe, so grep's own status is the
            # answer.
            if [ -n "$body_tree" ] && [ -n "$live_trees" ] \
               && grep -qxF -- "$body_tree" <<< "$live_trees"; then
              keep=1
            fi
            # Keep-arm B: within the retention window of its own audited_at.
            if [ "$keep" -eq 0 ] && [ -n "$body_epoch" ]; then
              case "$body_epoch" in '' | *[!0-9]*) body_epoch="" ;; esac
              if [ -n "$body_epoch" ]; then
                age=$(( now_epoch - body_epoch ))
                if [ "$age" -ge 0 ] && [ "$age" -le "$retention_seconds" ]; then
                  keep=1
                fi
              fi
            fi
            # Keep-arm C: the frontend earned marker for a still-open
            # receipt. Only the infix-free <digest>.ok family files a
            # sidecar, so this never fires for a specialist or a refusal.
            if [ "$keep" -eq 0 ] && [ "$base" = "${key}.ok" ] \
               && [ -n "$open_receipt_digests" ] \
               && grep -qxF -- "$key" <<< "$open_receipt_digests"; then
              keep=1
            fi

            [ "$keep" -eq 1 ] && kept_marker_digests="${kept_marker_digests}${key}
"
          fi
        fi
        ;;
      *.dispositions.json)
        # Co-reap symmetry, amended for keep-arm C: a sidecar is kept iff its
        # digest is a still-open receipt, OR a same-digest marker survived
        # this same pass by arm A/B; otherwise it is reaped alongside its
        # marker. An old sha-keyed sidecar (never 64-hex) matches neither set
        # and falls straight through.
        if [ -n "$open_receipt_digests" ] && grep -qxF -- "$key" <<< "$open_receipt_digests"; then
          keep=1
        elif [ -n "$kept_marker_digests" ] && grep -qxF -- "$key" <<< "$kept_marker_digests"; then
          keep=1
        fi
        ;;
      *)
        # *.carried (the deleted carry-forward family) and *.progress.log (a
        # CI-observability breadcrumb, never a validity artifact) are always
        # spent residue under the digest scheme: nothing keeps either alive.
        ;;
    esac

    [ "$keep" -eq 1 ] && continue
    rm -f -- "$marker"
  done

  # 2b. Re-run carry-forward ledgers. These need a DIFFERENT liveness test
  # than the markers above: a ledger is keyed on the incremental base (the
  # fork point `git merge-base "$BASE_REF" HEAD`), not a branch tip or a
  # marker's recorded tree, and a fork point is an ancestor of the default
  # branch by construction, so no tree/branch liveness test can ever prove
  # one dead. The ledger's real death signal is the branch it was audited
  # for, which it records: code-audit-frontend deletes the ledger on a clean
  # pass, so one that outlives its branch belongs to a line abandoned before
  # it ever reached clean.
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

  # Findings-arm retention: floor-clamped like every other new knob (default
  # 72h, floor 24h). Distinct from GAIA_AUDIT_MARKER_RETENTION_HOURS above --
  # that knob keys off a marker body's own recorded audited_at field; this one
  # keys off plain file mtime, since a findings.json body carries only
  # schema/member/findings and no branch/tree to test liveness against.
  findings_hours="${GAIA_AUDIT_FINDINGS_RETENTION_HOURS:-72}"
  case "$findings_hours" in '' | *[!0-9]*) findings_hours=72 ;; esac
  [ "$findings_hours" -lt 24 ] && findings_hours=24
  find "$audit_dir" -maxdepth 1 -type f -name '*.findings.json' \
    -mmin +"$((findings_hours * 60))" -delete 2>/dev/null
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
      | telemetry) return 0 ;;
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

  # cache/gh-artifact-pr.json: mtime-only, on its own floor-clamped knob
  # (default 2d, floor 1d). It records a branch and session_id, but a
  # gh-artifact PR cache this old is stale regardless of which branch or
  # session produced it, so staleness alone is the reap signal.
  cache_artifact_days="${GAIA_CACHE_ARTIFACT_RETENTION_DAYS:-2}"
  case "$cache_artifact_days" in '' | *[!0-9]*) cache_artifact_days=2 ;; esac
  [ "$cache_artifact_days" -lt 1 ] && cache_artifact_days=1
  find "$cache_dir" -maxdepth 1 -type f -name 'gh-artifact-pr.json' \
    -mtime +"$cache_artifact_days" -delete 2>/dev/null
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

# --- 8. Orphaned merged worktrees under .claude/worktrees/ -----------------
# A GAIA plan/debt worktree whose PR squash-merged and whose remote head was
# pruned leaves its local branch marked [gone] -- the same provable-death signal
# sweep #1 uses for wiki-sync/* branches. A session that crashed or was
# abandoned after the merge but before ExitWorktree leaves the worktree dir
# behind, and nothing else reclaims it. Reap only such provably-dead worktrees:
# never age-reap (an old worktree may be a live long-running session, and there
# is no session-liveness signal to tell them apart). Teardown is delegated to
# the WorktreeRemove hook's own script so remove + branch-delete + parent-prune
# stays defined in one place.
#
# Resolve the MAIN checkout: worktrees register there and physically live under
# <main>/.claude/worktrees/, and this janitor may itself run from inside a
# worktree, so `root` is not necessarily main.
wt_common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$wt_common" ]; then
  case "$wt_common" in
    /*) wt_main_git="$wt_common" ;;
    *)  wt_main_git="$root/$wt_common" ;;
  esac
  wt_main="$(cd "$(dirname "$wt_main_git")" 2>/dev/null && pwd -P || true)"
  wt_reaper="$wt_main/.gaia/scripts/remove-worktree.sh"
  wt_current="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
  wt_current="$(cd "$wt_current" 2>/dev/null && pwd -P || printf '%s' "$wt_current")"
  wt_base="$wt_main/.claude/worktrees"
  if [ -n "$wt_main" ] && [ -f "$wt_reaper" ] && [ -d "$wt_base" ]; then
    # Enumerate worktrees from the main checkout: porcelain emits `worktree
    # <path>` then (for an attached checkout) `branch refs/heads/<name>`, or
    # `detached`. Emit `<path>\t<branch>` per worktree; a detached worktree
    # yields an empty branch and is skipped (no branch to test for [gone]).
    while IFS="$(printf '\t')" read -r wt_path wt_branch; do
      [ -n "$wt_path" ] || continue
      # Only GAIA worktrees under the main checkout's .claude/worktrees/.
      case "$wt_path" in "$wt_base"/*) ;; *) continue ;; esac
      # Never the current checkout (also protects a janitor run from inside one).
      [ "$wt_path" != "$wt_current" ] || continue
      # Detached HEAD has no branch to prove [gone] on: leave it.
      [ -n "$wt_branch" ] || continue
      # Provable death: upstream-track is exactly [gone].
      wt_track="$(git -C "$wt_main" for-each-ref \
        --format='%(upstream:track)' "refs/heads/$wt_branch" 2>/dev/null || true)"
      [ "$wt_track" = "[gone]" ] || continue
      # Never discard uncommitted working-tree changes.
      [ -z "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ] || continue
      # Reap via the WorktreeRemove hook's own teardown script (remove + branch
      # -D [never main/master] + empty parent-dir prune, all in one place).
      # jq-built, not printf-interpolated: a path containing `"` or `\` could
      # otherwise produce malformed or injected JSON.
      jq -nc --arg p "$wt_path" '{worktree_path:$p}' \
        | bash "$wt_reaper" >/dev/null 2>&1 || true
    done < <(
      # `worktree` line: substr, not $2 -- porcelain does not quote the path,
      # so a $2 split would truncate at the first space in the path.
      git -C "$wt_main" worktree list --porcelain 2>/dev/null | awk '
        $1=="worktree"{ p=substr($0,10); b="" }
        $1=="branch"{b=$2; sub(/^refs\/heads\//,"",b)}
        $1==""{ if(p!="") print p "\t" b; p=""; b="" }
        END{ if(p!="") print p "\t" b }
      '
    )
  fi
fi

# --- 9. Off-pattern outlier residue ----------------------------------------
janitor_sweep_outliers "$local_dir"

exit 0
