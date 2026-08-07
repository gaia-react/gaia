#!/bin/bash
# local-janitor.sh, bounded session-start GC and reconciliation for GAIA's
# machine-local working state.
#
# Side-effect only, and two kinds of side effect. It deletes working state that
# GAIA subsystems leave behind and never self-prune, and it reconciles the one
# residue deletion alone cannot resolve: a wiki landing whose merge outlasts the
# CLI's own bounded wait leaves both a local branch and a stale local base
# branch, and neither is fixed by removing a file. That reconciliation is the
# hook's only network call and its only advance of a branch somebody has
# checked out; both are confined to sweep #1 and both are bounded. Invoked
# from wiki-session-start.sh (a type:command
# SessionStart hook, the side-effect form Anthropic still permits; it injects
# NOTHING into context). Also runnable directly for testing:
#   bash .claude/hooks/local-janitor.sh
#
# This is the BACKSTOP, not the owner. Each subsystem still owns its own
# lifecycle (audit.md prunes its KNOWLEDGE reports; plan.md self-cleans on
# merge). The janitor only removes residue whose death is PROVABLE, and its one
# reconciling step is gated and --ff-only, so it is safe to run unconditionally
# every session. Before the sweeps below, it also
# best-effort runs two one-time, guarded cleanups: ledger-status-migrate.sh, so
# every sweep that reads a ledger row's status sees the unified vocabulary, and
# the residue sweep its own block further down documents. It then sweeps
# exactly nine things:
#
#   1. the wiki landing's local residue: a merged-and-gone
#      wiki-sync/<date>-<sha> branch, AND the base branch that landing left
#      behind. The wiki landing CLI (`gaia wiki chain finish` /
#      `wiki sync land`) cuts a throwaway branch, pushes it, and enables
#      auto-merge with `gh pr merge --auto`, a call that returns BEFORE the
#      merge lands. The merge gate routinely outlasts any wait that fits in one
#      CLI invocation, so on the common path the local branch is not deleted
#      inline and the local base branch does not advance. This sweep does four
#      things, in order:
#        a. an existence gate. Everything below runs only when a local
#           wiki-sync/* branch is present at all, so an ordinary session pays
#           nothing for any of it.
#        b. a bounded, rate-limited `git fetch --prune` of origin. Bounded by
#           GAIA_WIKI_FETCH_TIMEOUT_SECONDS (default 5, floor 1, ceiling 30;
#           0 disables the fetch outright, and with it the reap in (c) and
#           the fast-forward in (d), both of which require evidence only a
#           completed fetch establishes) and rate-limited by
#           GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES (default 60, floor 5; 0
#           removes the rate limit rather than disabling anything), with the
#           attempt timestamped BEFORE launch so a hung remote cannot buy an
#           unbounded retry every session. This fetch's effect is REPO-GLOBAL:
#           refs and the object store are shared across every linked worktree,
#           so a worktree-invoked fetch mutates state every tree observes. Tree
#           locality applies to the fast-forward in (d), which acts on $root,
#           and to nothing else.
#        c. a guarded reap of each wiki-sync/* branch whose upstream now reads
#           [gone]. [gone] does NOT prove a merge: it proves only that the
#           remote head ref is absent, and a pull request closed without
#           merging and then branch-deleted reads identically. So the reap
#           refuses any branch carrying work no remote-tracking ref has, tested
#           by PATCH ID with `git cherry` (the only test that can tell a
#           squash-merged branch from an abandoned one; ancestry cannot). That
#           refusal is what (b) makes necessary: with the sweep establishing
#           [gone] itself on every qualifying session, the state arrives
#           routinely rather than incidentally, so the reap needs its own
#           evidence that the work survived rather than inheriting it from
#           whatever else happened to prune. `git branch -D` (not -d):
#           ancestry would refuse a squash merge anyway. Gated on the fetch
#           having COMPLETED, since a stale pre-fetch enumeration establishes
#           nothing.
#        d. a durable `--ff-only` fast-forward of the base branch to
#           origin/<base>, so the landing's own commit is actually present
#           locally. Purely local, no network call under any circumstance:
#           (b) already updated origin/<base> when it ran. Gated on HEAD being
#           on base, a clean working tree, base having an upstream, and the
#           fetch not being in an unknown state. Its safety comes from
#           --ff-only itself and not from the reap that happens to precede it:
#           a fast-forward against base's own upstream can only advance base to
#           a commit the remote already has, and it is a checkout-aware merge,
#           never a bare ref write.
#      The catch-up obligation is DURABLE. A session that cannot discharge (d),
#      a failing gate or a refused merge, records catchup_owed=1 in
#      .gaia/local/cache/shared/wiki-base-catchup.state, and a later qualifying
#      session retries with no new landing required. The obligation is one
#      idempotent fact, so however many landings occur it collapses to at most
#      one file; that is what bounds it, with no cap and no retention window.
#      A fast-forward that was TRIED and failed additionally writes one line to
#      .gaia/local/cache/shared/wiki-base-catchup.report, drained (read, then
#      deleted, so it surfaces exactly once) by wiki-drift-check.sh, a
#      UserPromptSubmit hook whose stdout reaches the conversation. A merely
#      SKIPPED attempt is silent and leaves base byte-identical. This sweep is
#      git-scoped, so it runs before the .gaia/local guard below.
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
#      spec-session-*.json, spec-session-*.lock, spec-chain-*.json, audit-*/)
#      and react-perf run dirs
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
#      sweep #3 delegates plan-folder deletes to plan-archive.sh. The same
#      knob and cost gate, on the same folder-delete shape, also reap
#      ABANDONED SPEC folders whose abandoned_at has aged past the window: a
#      thin delegation to the sibling spec-archive-abandoned.sh. An abandoned
#      SPEC has no implementing PR to fall back on as its durable record, but
#      it is abandoned for a definitive reason and revisiting one past the
#      window is vanishingly unlikely, so the same clock applies; unlike the
#      merged path there is no consolidation gate, so the whole folder reaps
#      as one unit; a dangling wiki-promote defer flag (implement ran before
#      abandonment) is purged rather than guarded on, since no close flow is
#      ever coming to drain it.
#   7. merged spec-less plan folders (reduced to SUMMARY.md + cost.json by
#      sweep #3's plan-archive.sh delegation) whose merged_at has aged past
#      the same retention window AND whose cost is fully represented. A thin
#      delegation to plan-archive-merged.sh, which owns both gates,
#      symmetric with sweep #6's spec-folder delegation. The same knob and
#      cost gate, on the same folder-delete shape, also reap ABANDONED
#      spec-less plan folders whose abandoned_at has aged past the window: a
#      thin delegation to the sibling plan-archive-abandoned.sh, symmetric
#      with sweep #6's spec-side abandoned delegation. No plan row is stamped
#      `abandoned` today (the status is reserved but no shipped path sets
#      it), so this delegation currently has no candidates to act on.
#   8. orphaned GAIA worktrees under .claude/worktrees/ whose branch upstream
#      is [gone] (the same upstream-absent signal sweep #1 reads for
#      wiki-sync/* branches), whose working tree is clean, AND whose branch
#      is not named by a live RUNNING plan sentinel. The sentinel is
#      gitignored, so it is invisible to both git-level checks above it; a
#      crashed session with an in-flight plan can otherwise read as
#      provably dead. Checked in both the worktree's own .gaia/local/ and
#      main's: for a properly linked worktree these are the same physical
#      directory (.gaia/local is one symlink to main's) and this is a
#      harmless double read, but a worktree nobody has linked -- provisioning
#      failed, or never ran -- still has its own real, unconnected
#      .gaia/local, and only the worktree-side scan sees a live plan sentinel
#      written there. A crashed or abandoned session leaves the worktree dir
#      behind after its PR squash-merges, and nothing else reclaims it.
#      Never age-reap: there is
#      no session-liveness signal, so an old worktree may still be a live
#      long-running session. Teardown runs inline: the harness owns worktree
#      creation and removal for a live session, but this sweep reaps worktrees
#      no session is in, so there is no session-scoped hook to delegate to,
#      and the janitor does its own remove + branch-delete + parent-prune.
#      Sweep #1's prune-fetch runs earlier in this same process and makes
#      [gone] routinely resolvable, so this sweep fires from a session-start
#      run far more often than it would on its own. Its own guards are what
#      bound that: only worktrees under the main checkout's .claude/worktrees/,
#      never the current checkout, never a detached HEAD, a clean working tree
#      required, and never a branch a live RUNNING plan sentinel names.
#   9. off-pattern outlier residue: at the top level of .gaia/local plus the
#      direct children (maxdepth-1, mindepth-1, no deeper) of audit/ and
#      cache/, every child is put to the state registry
#      (.gaia/state-registry.json, read through gaia_registry_recognizes in
#      .gaia/scripts/state-registry-lib.sh): a child the registry recognizes
#      (a live entry or a named residue path) is kept, silently; a child the
#      registry does NOT recognize is left in place and reported on stderr,
#      never deleted -- the registry is the single answer to "may I reap
#      this?", not a hardcoded allowlist. OS junk (.DS_Store, Thumbs.db,
#      ._*) is the one exception, reaped at any age regardless of the
#      registry. The sweep never recurses below maxdepth-1 -- the three
#      zones it walks never include telemetry/, red-ledger/, handoff/,
#      plans/, specs/, debt/, forensics/, or harden/ -- and
#      never follows a symlinked scope root from a linked worktree. Two
#      off-pattern writers still get their own dedicated reap arms
#      elsewhere, unrelated to this sweep's registry consultation:
#      audit/*.findings.json attached to sweep #2
#      (GAIA_AUDIT_FINDINGS_RETENTION_HOURS, default 72, floor 24) and
#      cache/gh-artifact-pr*.json attached to sweep #5
#      (GAIA_CACHE_ARTIFACT_RETENTION_DAYS, default 2, floor 1; the glob also
#      covers the pre-4.2 unkeyed cache/gh-artifact-pr.json some machines
#      may still carry -- see sweep #5's own comment for why).
#
# Fail-safe by construction, on both kinds of side effect. On the deleting
# side: any inability to PROVE death (no git, unreadable HEAD, unparseable
# sentinel) SKIPS that item, so live state is never deleted. On the
# reconciling side, where a working-tree mutation is not a deletion and that
# argument does not reach: every gate is cheap and local, the fast-forward is
# --ff-only against base's own upstream so it can only advance base to a
# commit the remote already has, a failing gate is a silent skip that leaves
# base byte-identical with the index and working tree untouched, and an
# attempt that was made and failed is reported through a channel that reaches
# the maintainer rather than swallowed. Either way the hook always exits 0, so
# it cannot block a session start.
set -uo pipefail

# --- Two questions, not one: which tree am I, and where is main ------------
# `root` answers "which tree is invoking this run" -- the physically resolved
# git toplevel of the CURRENT checkout. Sweep #1's `current` branch-protect
# below, and every worktree-teardown git call in sweep #8, need exactly this:
# the tree actually running right now, never main's.
#
# `main_root` answers "where does .gaia/local actually live". A linked
# worktree's .gaia/local is one symlink to main's (D-011), so the sweeps that
# walk .gaia/local below are conceptually always asking for main's tree, not
# the invoking one. Resolved via the shared resolver
# (.gaia/scripts/main-root-lib.sh), sourced beside this file via BASH_SOURCE
# the same way the ~14 other hooks that already depend on it do, rather than
# re-deriving "where is main" a fifteenth time by hand.
#
# Repointing `root` itself at `gaia_resolve_main_root` was considered and
# rejected: sweep #1's `current` guard exists to protect the INVOKING tree's
# branch, and swapping `root` wholesale would silently make it protect main's
# branch instead on every worktree-invoked run. The two questions get two
# variables, not one repointed one.
#
# Degrades to $root on any resolver failure or a missing sibling library --
# the same shape gaia-statusline.sh's STATE_ROOT fallback uses: an
# unresolvable main is not grounds to skip every sweep, it just means this
# tree answers for itself (true for a fresh, not-yet-`git init` checkout, and
# for main's own run, where root already IS main).
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

main_root_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
if [ -f "$main_root_lib" ]; then
  # shellcheck disable=SC1091
  . "$main_root_lib" 2>/dev/null || true
fi
main_root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  main_root="$(gaia_resolve_main_root "$root" 2>/dev/null || true)"
fi
[ -n "$main_root" ] || main_root="$root"

# --- Breadcrumb helpers for the durable wiki-base catch-up obligation ------
# Shared by this sweep (last_fetch_at) and the fast-forward further down this
# same file (catchup_owed). Read-modify-write via a temp file + `mv`, so a
# concurrent session never observes a half-written file. Deliberately never
# create .gaia/local: sweep #1 runs ABOVE the `[ -d "$local_dir" ] || exit 0`
# guard just below, so that a fresh clone carrying an orphaned wiki-sync
# branch is still swept; a `mkdir -p` from in here would recreate the
# directory that guard tests and silently arm every later sweep on a checkout
# that previously exited early. A skipped write is a silent no-op, never a
# sweep abort: a fresh clone with no .gaia/local is not a machine
# accumulating session-start cost, so its fetch simply runs on every session.
wiki_catchup_state_file="$main_root/.gaia/local/cache/shared/wiki-base-catchup.state"

# Prints one key's value, or nothing when the file, its directory, or the key
# itself is absent. Never fails.
wiki_catchup_state_get() {
  local key="$1"
  [ -f "$wiki_catchup_state_file" ] || return 0
  sed -n "s/^${key}=//p" "$wiki_catchup_state_file" 2>/dev/null | head -1
  return 0
}

# Sets one key, preserving every other key already on file.
wiki_catchup_state_set() {
  local key="$1" value="$2" tmp
  [ -d "$main_root/.gaia/local" ] || return 0
  mkdir -p "$main_root/.gaia/local/cache/shared" 2>/dev/null || return 0
  tmp="${wiki_catchup_state_file}.tmp.$$"
  { [ -f "$wiki_catchup_state_file" ] && grep -v "^${key}=" "$wiki_catchup_state_file" 2>/dev/null
    printf '%s=%s\n' "$key" "$value"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$wiki_catchup_state_file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# Removes one key, preserving every other key. Same no-op rule as `_set`.
# Not called from this sweep: it drains `catchup_owed`, which the
# durable-obligation fast-forward further down this file writes and reads.
# shellcheck disable=SC2329
wiki_catchup_state_unset() {
  local key="$1" tmp
  [ -f "$wiki_catchup_state_file" ] || return 0
  tmp="${wiki_catchup_state_file}.tmp.$$"
  { grep -v "^${key}=" "$wiki_catchup_state_file" 2>/dev/null || true; } >"$tmp" \
    && mv -f "$tmp" "$wiki_catchup_state_file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# --- 1. Merged-and-gone wiki-sync branches ---------------------------------
# Git-scoped: independent of .gaia/local, so it runs before that guard (a fresh
# clone can carry an orphaned wiki-sync branch before any .gaia/local exists).
# List every local branch with its upstream-track state. `[gone]` only
# materializes after a `git fetch --prune`, so when a wiki-sync/* branch is
# present at all this sweep runs its own bounded, rate-limited prune-fetch of
# `origin` (below) before re-reading that state, then hard-deletes each
# `[gone]` branch whose work is already fully represented upstream (checked
# via `git cherry`, since a squash merge leaves the branch tip unreachable by
# ancestry alone). `git branch -D` (not -d): ancestry would refuse a squash
# merge anyway. Fail-safe throughout: the current branch is never a delete
# candidate, an empty/[ahead]/[behind] track is skipped (remote head still
# present), an unanswerable cherry read keeps the branch, and any git failure
# leaves the branch untouched.
current=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
branch_tracks=$(git -C "$root" for-each-ref \
  --format='%(refname:short) %(upstream:track)' refs/heads/ 2>/dev/null || true)

# Resolved once, unconditionally -- consumed by this sweep's guarded reap
# below AND by the durable-obligation fast-forward further down this file,
# which runs even in a session holding no wiki-sync/* branch at all (D2:
# origin/HEAD with a main fallback, matching defaultBranch's convention).
# SEC-011: shape-validated immediately, before any git call interpolates it.
# An unresolvable or unsafely-shaped base clears $base to empty; every
# consumer below treats an empty $base as "unanswerable, skip".
base=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
base=${base#origin/}
[ -n "$base" ] || base=main
case "$base" in
  -* | *' '* | '') base="" ;;
  *[!A-Za-z0-9._/-]*) base="" ;;
esac

# The two fetch-state flags, initialized before any branch of this sweep can
# be taken: the hook runs `set -uo pipefail`, so a later read of an unset
# variable is fatal, and the fast-forward further down needs both even in a
# session that takes none of the branches below.
fetch_attempted=0
fetch_ok=0

# Set when THIS session's reap loop below encounters a [gone] wiki-sync/*
# branch, whether it deletes it or the cherry check refuses to. Read by
# half B further down this file: it is one of the two triggers ("owed OR
# half A reconciled a branch") for attempting the fast-forward, alongside a
# `catchup_owed=1` breadcrumb a previous session left behind. Same
# initialize-before-any-branch requirement as the two flags above.
branch_reconciled=0

wiki_sync_present=0
if [ -n "$branch_tracks" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref=${line%% *}
    case "$ref" in wiki-sync/*) wiki_sync_present=1; break ;; esac
  done <<EOF
$branch_tracks
EOF
fi

if [ "$wiki_sync_present" -eq 1 ]; then
  # Knobs, the janitor's shipped clamp idiom (see GAIA_AUDIT_FINDINGS_RETENTION_HOURS
  # and GAIA_CACHE_ARTIFACT_RETENTION_DAYS elsewhere in this file for the exact
  # idiom this copies). `0` is special-cased on BOTH knobs before the floor
  # clamp, but means something different on each: the timeout knob's `0`
  # disables the fetch outright, while the min-interval knob's `0` removes the
  # rate limit rather than disabling anything -- a `0` swallowed by the floor
  # clamp would suppress the very fetch that knob's opt-out exists to allow.
  wiki_fetch_timeout="${GAIA_WIKI_FETCH_TIMEOUT_SECONDS:-5}"
  case "$wiki_fetch_timeout" in '' | *[!0-9]*) wiki_fetch_timeout=5 ;; esac
  if [ "$wiki_fetch_timeout" -ne 0 ]; then
    [ "$wiki_fetch_timeout" -lt 1 ] && wiki_fetch_timeout=1
    [ "$wiki_fetch_timeout" -gt 30 ] && wiki_fetch_timeout=30
  fi

  wiki_fetch_min_interval="${GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES:-60}"
  case "$wiki_fetch_min_interval" in '' | *[!0-9]*) wiki_fetch_min_interval=60 ;; esac
  if [ "$wiki_fetch_min_interval" -ne 0 ]; then
    [ "$wiki_fetch_min_interval" -lt 5 ] && wiki_fetch_min_interval=5
  fi

  do_fetch=1
  [ "$wiki_fetch_timeout" -ne 0 ] || do_fetch=0
  if [ "$do_fetch" -eq 1 ]; then
    git -C "$root" remote get-url origin >/dev/null 2>&1 || do_fetch=0
  fi
  if [ "$do_fetch" -eq 1 ] && [ "$wiki_fetch_min_interval" -ne 0 ]; then
    last_fetch_at=$(wiki_catchup_state_get last_fetch_at)
    case "$last_fetch_at" in '' | *[!0-9]*) last_fetch_at="" ;; esac
    if [ -n "$last_fetch_at" ]; then
      # 10# forces base 10 on both operands below. The digits-only guards above
      # admit a zero-padded value, and bare arithmetic reads 08 and 09 as
      # invalid octal. That is an expansion error, not a failed assignment:
      # bash unwinds to the top level, abandoning every enclosing compound
      # command, so the rest of half A (this fetch and the reap below) is
      # skipped outright while execution resumes at the next top-level block.
      # Half B and sweeps 2 through 9 still run, and nothing non-zero escapes,
      # so the loss is invisible from the exit status.
      elapsed=$(($(date -u +%s) - 10#$last_fetch_at))
      min_interval_secs=$((10#$wiki_fetch_min_interval * 60))
      [ "$elapsed" -lt "$min_interval_secs" ] && do_fetch=0
    fi
  fi

  if [ "$do_fetch" -eq 1 ]; then
    # Record the attempt BEFORE launching, so a hung remote whose kill path
    # itself misbehaves does not buy an unbounded retry every session.
    wiki_catchup_state_set last_fetch_at "$(date -u +%s)"
    # shellcheck disable=SC2034 # read by the fast-forward gate further down this file
    fetch_attempted=1

    # Prompt suppression is a PER-INVOCATION PREFIX on this one command.
    # Never `export` any of it: this process runs six delegated `bash`
    # children and every later sweep's own git calls, and an exported
    # GIT_TERMINAL_PROMPT / GIT_SSH_COMMAND would reach all of them.
    # GIT_SSH_COMMAND EXTENDS the adopter's own value rather than replacing
    # it, and GIT_ASKPASS/SSH_ASKPASS point at `true` (a no-op binary) so a
    # credential helper cannot open a dialog. `core.askPass` in the adopter's
    # own git config is overridden for this invocation only, via `-c`; their
    # config file is never written. An agent-mediated confirmation (a
    # 1Password/Secretive SSH agent, a FIDO `sk-` key wanting a physical
    # touch) is NOT suppressible this way; the bounded wait below is the only
    # guaranteed bound against it.
    #
    # `set -m` (job control) around the background launch, restored right
    # after: verified empirically against this repo's supported bash range
    # (3.2 and 5.x on macOS, both put the backgrounded job in its own process
    # group) that this is what lets `kill -TERM -$fetch_pid` below reach a
    # grandchild (`git-remote-https` / `ssh`) too, not just the immediate git
    # process. A non-interactive shell does not do this by default.
    set -m
    GIT_TERMINAL_PROMPT=0 \
      GIT_ASKPASS=true \
      SSH_ASKPASS=true \
      SSH_ASKPASS_REQUIRE=never \
      GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new" \
      git -C "$root" -c core.askPass= fetch --prune --quiet origin >/dev/null 2>&1 &
    fetch_pid=$!
    set +m

    waited=0
    while [ "$waited" -lt "$wiki_fetch_timeout" ]; do
      kill -0 "$fetch_pid" 2>/dev/null || break
      sleep 1
      waited=$((waited + 1))
    done

    if kill -0 "$fetch_pid" 2>/dev/null; then
      # Expired. `disown` first: on bash 3.2, `set -m` job control prints an
      # unsuppressible "<pid> Terminated: 15" line to the shell's own stderr
      # (not the backgrounded command's, so no per-command redirect catches
      # it) the moment the kill below signals the job; bash 5 stays silent
      # for the same sequence. Dropping the job-table entry before the kill
      # avoids the notification outright, and it is safe only here: this
      # timeout branch never reads the backgrounded fetch's own exit status
      # (the `wait` below is `|| true`), unlike the non-timeout branch further
      # down, which needs a real exit status from `wait` to set fetch_ok and
      # would silently always read success if disowned the same way.
      disown "$fetch_pid" 2>/dev/null || true
      # Kill the whole subtree via the negated pid (the process GROUP
      # `set -m` put the job in above); fall back to the direct pid if the
      # group signal is refused for any reason.
      kill -TERM -"$fetch_pid" 2>/dev/null || kill -TERM "$fetch_pid" 2>/dev/null || true
      sleep 1
      kill -KILL -"$fetch_pid" 2>/dev/null || kill -KILL "$fetch_pid" 2>/dev/null || true
      wait "$fetch_pid" 2>/dev/null || true
      # A killed fetch can leave .git/FETCH_HEAD.lock or shallow.lock behind
      # for a later sweep in this same process to trip over. Remove only the
      # fetch's own locks, never index.lock (a concurrent human `git` may
      # legitimately hold that one). The two locks live in different
      # directories from a linked worktree: FETCH_HEAD.lock is per-worktree
      # (--absolute-git-dir on $root), while shallow.lock belongs to the
      # shared clone state that lives in the main checkout's own .git dir.
      # Targeting --absolute-git-dir on $root for both would strand the main
      # checkout's shallow.lock behind a worktree-invoked kill, at a path
      # that cannot exist under the worktree's own git dir. Reached via
      # $main_root (the shared resolver's answer, from the top of this file)
      # rather than a hand-rolled --git-common-dir derivation: $main_root is
      # by construction never itself a linked worktree, so its own
      # --absolute-git-dir already IS the common dir shallow.lock lives in,
      # with no relative/absolute normalization needed.
      git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null || true)
      git_common_dir=$(git -C "$main_root" rev-parse --absolute-git-dir 2>/dev/null || true)
      [ -n "$git_dir" ] && rm -f "$git_dir/FETCH_HEAD.lock" 2>/dev/null
      [ -n "$git_common_dir" ] && rm -f "$git_common_dir/shallow.lock" 2>/dev/null
      true
    else
      wait "$fetch_pid" 2>/dev/null && fetch_ok=1
    fi
  fi

  # The reap depends on [gone] having been freshly established by THIS
  # sweep's own fetch (a stale pre-fetch enumeration cannot be reused), so it
  # is gated on fetch_ok=1 alone. On the timeout path (fetch_attempted=1,
  # fetch_ok=0) this performs neither the reap nor -- further down this same
  # file -- the durable-obligation fast-forward: a fetch that did not
  # complete has established nothing.
  if [ "$fetch_ok" -eq 1 ]; then
    branch_tracks=$(git -C "$root" for-each-ref \
      --format='%(refname:short) %(upstream:track)' refs/heads/ 2>/dev/null || true)
    if [ -n "$branch_tracks" ] && [ -n "$base" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        ref=${line%% *}                        # branch name (no spaces in a ref)
        track=${line#"$ref"}; track=${track# }  # remainder: [gone]/[ahead N]/... token
        # The glob is a conservative superset of the CLI verb's
        # WIKI_SYNC_BRANCH regex, not an exact mirror: it only requires ONE
        # hex character where the regex demands 7-40, so a name like
        # `wiki-sync/2026-08-09-a` is glob-eligible but invisible to the
        # await verb. That is safe here because the cherry check and the
        # `[gone]` track state below are what actually gate the delete, not
        # this glob alone. Validated before any destructive step (SEC-011).
        case "$ref" in
          wiki-sync/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9a-f]*) ;;
          *) continue ;;
        esac
        [ "$ref" = "$current" ] && continue
        [ "$track" = "[gone]" ] || continue
        # shellcheck disable=SC2034 # read by half B, further down this file
        branch_reconciled=1

        # Refuse the reap when the branch carries work no remote-tracking ref
        # has. `git cherry` compares by PATCH ID, not by ancestry, the only
        # test that can tell a squash-merged branch (its patch is upstream
        # under a new sha) from one whose PR closed without merging (its
        # patch is upstream nowhere) -- an ancestry test cannot, a squash
        # merge leaves the branch tip unreachable from origin/$base exactly
        # like an abandoned branch. Fail-safe: an unanswerable question keeps
        # the branch. Known limitation: a chain branch carrying several
        # commits whose squash does not patch-match any single commit reads
        # as `+` and lingers rather than being reaped; lingering is the safe
        # direction, bounded by the minimum-interval knob, and the durable
        # catch-up obligation is carried by a breadcrumb, not by the branch,
        # so a lingering branch never blocks the fast-forward.
        # Capture cherry's own exit status, not grep's: a missing origin/$base
        # (origin/HEAD unset locally, base falls back to a literal "main" that
        # does not exist on this remote) makes cherry fail and print nothing,
        # which is indistinguishable from a genuine zero-commits-ahead result
        # once piped through `grep -c` alone. Only a clean cherry run answers
        # the question; anything else keeps the branch, per the comment above.
        cherry_out=$(git -C "$root" cherry --end-of-options "origin/$base" "$ref" 2>/dev/null)
        cherry_status=$?
        [ "$cherry_status" -eq 0 ] || continue
        unpushed=$(printf '%s\n' "$cherry_out" | grep -c '^+')
        [ "$unpushed" -eq 0 ] || continue

        git -C "$root" branch -D -- "$ref" >/dev/null 2>&1 || true
      done <<EOF
$branch_tracks
EOF
    fi
  fi
fi

# --- Half B: the durable-obligation fast-forward ---------------------------
# Advances base to origin/base with a checkout-aware `git merge --ff-only`.
# Purely local -- no network call under any circumstance -- so it is attempted
# whether or not this session holds a wiki-sync/* branch at all: half A's
# fetch already updated origin/$base when it ran, and nothing here re-hits the
# network. Two independent triggers, per the frozen gate chain: THIS session's
# reap loop reconciled a [gone] branch (branch_reconciled=1), OR a previous
# session left the catchup_owed=1 breadcrumb because it could not complete the
# fast-forward. Git-scoped like the rest of sweep #1, so it runs above the
# .gaia/local existence guard just below.
#
# Safety argument (and the one this comment does NOT make): --ff-only against
# base's own upstream can only advance base to a commit the remote already
# has. This is NOT built on "[gone] proves a merge" -- [gone] proves only that
# the remote head ref is absent; a PR closed without merging then
# branch-deleted reads identically. The fast-forward's own safety comes from
# --ff-only itself, not from the reap that happened to precede it.
#
# Drain first, independent of any fast-forward attempt: a purely local,
# no-network read of whether base is already at or ahead of its upstream. Safe
# to run whether or not this session is even checked out on base.
owed=$(wiki_catchup_state_get catchup_owed)
if [ "$owed" = "1" ] && [ -n "$base" ] \
  && git -C "$root" rev-parse --verify --quiet "refs/heads/$base" >/dev/null 2>&1 \
  && git -C "$root" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1 \
  && git -C "$root" merge-base --is-ancestor --end-of-options \
       "origin/$base" "refs/heads/$base" 2>/dev/null; then
  wiki_catchup_state_unset catchup_owed
  rm -f "$main_root/.gaia/local/cache/shared/wiki-base-catchup.report" 2>/dev/null || true
  owed=""
fi

attempt_ff=0
[ "$owed" = "1" ] && attempt_ff=1
[ "$branch_reconciled" -eq 1 ] && attempt_ff=1

if [ "$attempt_ff" -eq 1 ] && [ -n "$base" ]; then
  # Gates, all cheap and local, all silent when they fail (a failing gate is a
  # SKIP: no report, exit 0, base byte-identical, index and working tree
  # untouched -- distinct from a TRIED-and-failed fast-forward, which reports).
  ff_ready=1
  [ "$current" = "$base" ] || ff_ready=0   # empty $current (detached) fails here too

  if [ "$ff_ready" -eq 1 ]; then
    [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] || ff_ready=0
  fi

  base_upstream=""
  if [ "$ff_ready" -eq 1 ]; then
    if git -C "$root" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
      base_upstream=$(git -C "$root" for-each-ref \
        --format='%(upstream)' "refs/heads/$base" 2>/dev/null)
    fi
    [ -n "$base_upstream" ] || ff_ready=0
  fi

  if [ "$ff_ready" -eq 1 ] && [ "$fetch_attempted" -eq 1 ] && [ "$fetch_ok" -ne 1 ]; then
    ff_ready=0
  fi

  if [ "$ff_ready" -eq 1 ]; then
    # SEC-011: $base was shape-validated once, above, before any git call
    # interpolated it; --end-of-options additionally stops a ref that starts
    # with `-` from ever being read as a flag. Capture stderr only (the
    # `2>&1 >/dev/null` order): stdout is discarded, stderr lands in $ff_stderr
    # for the report below, and NOTHING reaches this hook's own stdout/stderr
    # either way.
    ff_stderr=$(git -C "$root" merge --ff-only --end-of-options "origin/$base" 2>&1 >/dev/null)
    ff_status=$?
    if [ "$ff_status" -eq 0 ]; then
      wiki_catchup_state_unset catchup_owed
      rm -f "$main_root/.gaia/local/cache/shared/wiki-base-catchup.report" 2>/dev/null || true
    else
      # Coverage is every non-skip FAILURE, not divergence alone: an untracked
      # file the incoming commit would overwrite, a held index.lock, and a
      # transient git error all reproduce the same silent stale base. Derived
      # from the failed merge's own stderr; defaults to "git error".
      reason="git error"
      case "$ff_stderr" in
        *"Not possible to fast-forward"*) reason="divergence" ;;
        *"untracked working tree files would be overwritten"*) reason="untracked collision" ;;
        *"index.lock"*) reason="index locked" ;;
      esac
      wiki_catchup_state_set catchup_owed 1
      # Same never-create-.gaia/local rule as the breadcrumb helpers: this
      # write is skipped silently on a checkout that never had .gaia/local.
      if [ -d "$main_root/.gaia/local" ]; then
        mkdir -p "$main_root/.gaia/local/cache/shared" 2>/dev/null
        # Temp-file-plus-mv, same idiom wiki_catchup_state_set uses above: a
        # plain truncating redirect leaves a window where wiki-drift-check.sh
        # (a separate process draining this file: read, then delete) can
        # observe it mid-truncate as blank and lose the refusal permanently.
        # `mv -f` is atomic, so a concurrent drain either sees the old
        # content or the new content, never neither.
        report_file="$main_root/.gaia/local/cache/shared/wiki-base-catchup.report"
        report_tmp="${report_file}.tmp.$$"
        printf '[wiki base] fast-forward of %s to origin/%s refused (%s); local base is behind. Resolve by hand; the next qualifying session retries.\n' \
          "$base" "$base" "$reason" \
          > "$report_tmp" 2>/dev/null && mv -f "$report_tmp" "$report_file" 2>/dev/null
        rm -f "$report_tmp" 2>/dev/null
      fi
    fi
  else
    # A gate declined the attempt outright: the obligation persists (or is
    # newly recorded) so a later qualifying session retries. Silent: no
    # report, nothing on stdout or stderr.
    wiki_catchup_state_set catchup_owed 1
  fi
fi

local_dir="$root/.gaia/local"
[ -d "$local_dir" ] || exit 0

# --- Sweep #9's reap predicate: the state registry, not a hardcoded list ---
#
# "May I reap this off-pattern child?" is answered by the state registry
# (.gaia/state-registry.json) through gaia_registry_recognizes, the one
# consumer-facing predicate .gaia/scripts/state-registry-lib.sh exposes for
# exactly this question. Sourced from THIS file's own sibling .gaia/scripts/
# (via BASH_SOURCE), never from $root: $root is whatever checkout the janitor
# happens to be running against (a bats fixture, a linked worktree), while
# this file and .gaia/scripts/state-registry-lib.sh ship together, so the
# library is always found beside the janitor regardless of which tree's
# .gaia/local it is sweeping. The library locates the registry itself, via
# the resolver, independent of where it was sourced from.
#
# Fail-safe by the library's own contract: jq unavailable or the registry
# unreadable makes gaia_registry_recognizes return "recognized" (exit 0), so
# a broken registry degrades to "sweep #9 reaps and reports nothing", never
# to "sweep #9 reaps everything it cannot classify" -- see
# state-registry-lib.sh's own header for the fail-safe contract.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.gaia/scripts/state-registry-lib.sh"

# janitor_sweep_outliers <local_dir>: the ninth sweep. Walks exactly three
# scope roots (top level of <local_dir>, its audit/, its cache/), each at
# maxdepth-1/mindepth-1, and for every child asks the state registry whether
# it is recognized (a live entry or a named residue path). A recognized child
# is kept, silently; an unrecognized child is reported on stderr and left in
# place -- report, never reap. OS junk is the one exception, reaped at any
# age regardless of the registry. Self-contained: resolves real directories
# only (never follows a symlinked scope root, so a run from a linked worktree
# never touches another checkout's state, and never reaps a symlinked entry),
# and never recurses below maxdepth-1 -- the one exception, a bounded
# one-level peek for a `renders.json` child, only ever KEEPS. No stdout;
# deletes only OS junk; always returns 0.
janitor_sweep_outliers() {
  local scope_root="$1"
  [ -n "$scope_root" ] && [ -d "$scope_root" ] || return 0

  # Probe the registry ONCE per invocation, not once per child: each
  # gaia_registry_path resolution forks git several times (through the
  # main-root resolver), so asking gaia_registry_recognizes per child would
  # scale git-fork cost with the number of children in .gaia/local. When the
  # registry is unusable (no jq, no registry file, unresolvable root) the
  # fail-safe answer is "recognized" for every child regardless of which
  # child is asked, so one probe answers it for the whole sweep. A usable
  # registry still asks gaia_registry_recognizes per child below, since only
  # it knows a given child's own match.
  local registry_usable=1
  gaia_registry_path >/dev/null 2>&1 || registry_usable=0

  local zone sroot child base etype relpath
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

      # OS junk: reaped at any age, the only case the registry never governs.
      case "$base" in
        .DS_Store | Thumbs.db | ._*)
          rm -rf -- "$child"
          continue
          ;;
      esac

      if [ "$registry_usable" -eq 0 ]; then
        continue   # registry unusable: fail-safe recognizes everything
      fi

      case "$zone" in
        toplevel) relpath="$base" ;;
        audit)    relpath="audit/$base" ;;
        cache)    relpath="cache/$base" ;;
      esac

      if gaia_registry_recognizes "$relpath" "$etype"; then
        continue   # recognized (live or residue): kept, silently
      fi

      # Bounded one-level renders.json protection: a not-otherwise-recognized
      # cache/ child directory still keeps if it directly holds a
      # renders.json file (a react-perf run dir, whose own name is arbitrary
      # and never itself a registry entry). Only ever KEEPS.
      if [ "$zone" = cache ] && [ "$etype" = d ] && [ -f "$child/renders.json" ]; then
        continue
      fi

      # Unrecognized: report, never reap.
      printf 'local-janitor: sweep #9: unrecognized %s not in the state registry, left in place: %s\n' \
        "$etype" "$child" >&2
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
# shared across linked worktrees, and a linked worktree's whole .gaia/local is
# one symlink to the main checkout's, so the audit drop-zone is literally the
# same directory in every tree and a sweep launched from one worktree judges
# every worktree's markers. Collect the branch tips AND each worktree's HEAD (which covers a
# detached checkout no branch names) so a sweep here never reaps a live marker
# belonging to a parallel audit over there.
#
# Reliability, not just contents: the two enumeration commands are captured with
# their exit status, not swallowed by `|| true`. An empty live_trees set is an
# inability to prove LIFE, which the marker loop must never read as proof of
# death. When either enumeration fails (a transient git error, lock contention,
# a broken checkout), live_trees_reliable is 0 and keep-arm A below keeps every
# new-scheme marker rather than reap a clearance whose tree it could not check.
live_trees_reliable=1
refs_raw=$(git -C "$root" for-each-ref --format='%(objectname)' refs/heads/ 2>/dev/null) \
  || live_trees_reliable=0
wt_raw=$(git -C "$root" worktree list --porcelain 2>/dev/null) \
  || live_trees_reliable=0
live_trees=""
if [ "$live_trees_reliable" -eq 1 ]; then
  live_trees=$(
    {
      printf '%s\n' "$refs_raw"
      printf '%s\n' "$wt_raw" | awk '$1 == "HEAD" { print $2 }'
    } | sort -u | while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      git -C "$root" rev-parse "${commit}^{tree}" 2>/dev/null || true
    done
  )
fi

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

            # Keep-arm A: the marker's own tree is a live branch/worktree tip,
            # OR the live-tree set could not be reliably enumerated this run
            # (git failed), in which case the tree cannot be proven dead and
            # the fail-safe keeps the marker rather than reap a clearance a
            # parallel audit may still need.
            #
            # Match with a herestring, never `printf ... | grep -q`. Under
            # `pipefail`, `grep -q` exits the instant it matches, `printf`
            # then takes SIGPIPE, and the pipeline reports 141 -- so a MATCH
            # would read as a miss and this reaps the live marker it just
            # found. The herestring has no pipe, so grep's own status is the
            # answer.
            if [ -n "$body_tree" ]; then
              if [ "$live_trees_reliable" -eq 0 ]; then
                keep=1
              elif [ -n "$live_trees" ] \
                 && grep -qxF -- "$body_tree" <<< "$live_trees"; then
                keep=1
              fi
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
# The structural drop-zones -- directories GAIA tooling expects to find and
# writes into, kept even when momentarily empty -- are declared in the state
# registry (.gaia/state-registry.json) and read here via gaia_registry_drop_zones
# (from the state-registry lib sourced above) as `path<TAB>match` rows, each
# tested against an empty dir's relpath via _gaia_registry_pattern_matches --
# the same matcher gaia_registry_recognizes/gaia_registry_classify use, never a
# hand-rolled literal-string test. This is what lets a keyed per-tree subdir
# (e.g. red-ledger/<tree_key>/, declared as a glob row) survive alongside a
# bare literal container. Fail-safe: an unreadable or empty drop-zone list
# skips the sweep, so a run that cannot classify the skeleton keeps every
# empty dir rather than rmdir a structural one it could not identify.
drop_zones="$(gaia_registry_drop_zones 2>/dev/null)" || drop_zones=""
if [ -n "$drop_zones" ]; then
  empties=$(find "$local_dir" -mindepth 1 -type d -empty 2>/dev/null | sort -r)
  if [ -n "$empties" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      rel=${d#"$local_dir"/}
      is_drop_zone=0
      while IFS="$(printf '\t')" read -r dz_path dz_match; do
        [ -n "$dz_path" ] || continue
        _gaia_registry_pattern_matches "$rel" "$dz_path" "$dz_match" && { is_drop_zone=1; break; }
      done <<<"$drop_zones"
      [ "$is_drop_zone" -eq 1 ] && continue
      rmdir "$d" 2>/dev/null
    done <<EOF
$empties
EOF
  fi
fi

# --- 5. Stale cache artifacts (age-gated; generous window so paused authoring survives) ---
# cache/ is a drop-zone (kept alive above), but its contents are still fair
# game once provably stale: 14 days is generous enough that a paused
# multi-day authoring session's live gate1/draft never gets reaped mid-flight.
cache_dir="$local_dir/cache"
if [ -d "$cache_dir" ]; then
  find "$cache_dir" -maxdepth 1 \( \
      -name 'gate1-*.json' -o -name 'draft-*.md' -o -name 'spec-session-*.json' \
      -o -name 'spec-session-*.lock' \
    \) -type f -mtime +14 -delete 2>/dev/null
  find "$cache_dir" -maxdepth 1 -type d -name 'audit-*' -mtime +14 -exec rm -rf {} + 2>/dev/null
  # react-perf run dumps: a dir at cache root containing renders.json. `dirname`
  # over a `while read` loop instead of `find -printf` for BSD/macOS find portability.
  find "$cache_dir" -maxdepth 2 -name 'renders.json' -mtime +14 -print 2>/dev/null | \
    while IFS= read -r hit; do
      rm -rf -- "$(dirname "$hit")"
    done
fi

# --- 5b. Main-only cache globs, swept at MAIN's cache, never the invoking tree's ---
# cache/spec-chain-*.json and cache/gh-artifact-pr*.json are both registry
# main-only (spec-chain-guard / gh-artifact-pr-cache in
# .gaia/state-registry.json): their sole writers (block-spec-plan-chain.sh,
# gh-artifact-lib.sh's gaia_gh_artifact_cache_dir) always resolve MAIN's root
# before writing, so a worktree-invoked sweep has to target
# $main_root/.gaia/local/cache too -- never $cache_dir above, which is this
# INVOKING tree's own .gaia/local/cache, empty for these two files on every
# tree but main. Split out of the tree-scoped glob above rather than folded
# in: the rest of that glob (gate1/draft/spec-session) is registry ephemeral
# and genuinely IS the writing tree's own working state, so it stays where it
# is written.
main_cache_dir="$main_root/.gaia/local/cache"
if [ -d "$main_cache_dir" ]; then
  find "$main_cache_dir" -maxdepth 1 -type f -name 'spec-chain-*.json' \
    -mtime +14 -delete 2>/dev/null

  # cache/gh-artifact-pr*.json: mtime-only, on its own floor-clamped knob
  # (default 2d, floor 1d). The glob is the family pattern for "every
  # gh-artifact breadcrumb", not a special case bolted on for migration: it
  # covers the current per-branch filename (cache/gh-artifact-pr.<branch
  # -slug>.json) AND the pre-4.2 unkeyed cache/gh-artifact-pr.json some
  # machines may still carry from before this file was keyed. Sweep #9
  # (off-pattern outlier residue, above) reports an unrecognized cache/ child
  # on stderr and never reaps it -- report-not-delete, by design -- so an old
  # unkeyed file left outside this arm's reach would nag on every session
  # start with nothing able to clear it; folding it into this arm's own glob
  # is the difference between an orphan that ages out in a couple of days
  # and one that lives forever. Each matched file records a branch and
  # session_id, but a gh-artifact PR cache this old is stale regardless of
  # which branch or session produced it, so staleness alone is the reap
  # signal.
  cache_artifact_days="${GAIA_CACHE_ARTIFACT_RETENTION_DAYS:-2}"
  case "$cache_artifact_days" in '' | *[!0-9]*) cache_artifact_days=2 ;; esac
  [ "$cache_artifact_days" -lt 1 ] && cache_artifact_days=1
  find "$main_cache_dir" -maxdepth 1 -type f -name 'gh-artifact-pr*.json' \
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
archive_abandoned="$root/.specify/extensions/gaia/lib/spec-archive-abandoned.sh"
if [ -x "$archive_abandoned" ] || [ -f "$archive_abandoned" ]; then
  bash "$archive_abandoned" "$root" >/dev/null 2>&1 || true
fi

# --- 7. Age-reap merged spec-less plan folders past the retention window ---
archive_plan="$root/.specify/extensions/gaia/lib/plan-archive-merged.sh"
if [ -x "$archive_plan" ] || [ -f "$archive_plan" ]; then
  bash "$archive_plan" "$root" >/dev/null 2>&1 || true
fi
archive_plan_abandoned="$root/.specify/extensions/gaia/lib/plan-archive-abandoned.sh"
if [ -x "$archive_plan_abandoned" ] || [ -f "$archive_plan_abandoned" ]; then
  bash "$archive_plan_abandoned" "$root" >/dev/null 2>&1 || true
fi

# --- 8. Orphaned merged worktrees under .claude/worktrees/ -----------------
# A GAIA plan/debt worktree whose PR squash-merged and whose remote head was
# pruned leaves its local branch marked [gone] -- the same provable-death signal
# sweep #1 uses for wiki-sync/* branches. A session that crashed or was
# abandoned after the merge but before ExitWorktree leaves the worktree dir
# behind, and nothing else reclaims it. Reap only such provably-dead worktrees:
# never age-reap (an old worktree may be a live long-running session, and there
# is no session-liveness signal to tell them apart). Teardown runs inline here:
# the harness owns worktree creation and removal for a live session, but this
# sweep reaps worktrees no session is in, so there is no session-scoped hook to
# delegate to, and the janitor does its own remove + branch-delete +
# parent-prune.
#
# Resolve the MAIN checkout via the shared resolver: worktrees register there
# and physically live under <main>/.claude/worktrees/, and this janitor may
# itself run from inside a worktree, so `root` is not necessarily main. An
# unresolvable main root skips this sweep outright rather than guessing --
# unlike the file-level `main_root` above (which degrades to `root`), reaping
# a worktree against a wrongly-assumed root is destructive, so this sweep has
# nothing safe to fall back to.
wt_main=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  wt_main="$(gaia_resolve_main_root "$root" 2>/dev/null || true)"
fi
wt_current="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
wt_current="$(cd "$wt_current" 2>/dev/null && pwd -P || printf '%s' "$wt_current")"
wt_base="$wt_main/.claude/worktrees"
if [ -n "$wt_main" ] && [ -d "$wt_base" ]; then
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
    # [gone] does NOT prove a merge: it proves only that the remote head ref
    # is absent, and sweep #1's own repo-global prune-fetch (above) now
    # manufactures this signal for EVERY branch whose remote head is gone,
    # not only wiki-sync/* ones. A branch whose PR squash-merged (GitHub
    # auto-deletes the head branch) reads identically to one whose PR closed
    # without merging; ancestry cannot tell them apart, only a PATCH-ID
    # comparison against origin/$base can. That comparison is over the
    # branch's COMBINED diff, because a squash merge lands the whole branch as
    # ONE upstream commit: a per-commit test matches none of a branch's
    # commits once the squash collapses two of them, and matches nothing at
    # all for the audit gate's empty trailer commit. Refuse the reap when the
    # branch carries work no remote-tracking ref has. Fail-safe: every
    # question this cannot answer from git keeps the worktree -- an
    # unresolvable/unsafely-shaped $base (cleared to empty above), an
    # unresolvable merge base, a failed read of any kind, an empty patch id on
    # a branch that is ahead, and a bounded scan that ends without a match.
    #
    # The cheap refusals run first. A dirty working tree and a live plan
    # sentinel each refuse outright, so an ordinary session pays nothing for
    # the merge-evidence reads on a candidate they already spare. Every gate
    # here is a refusal, so their order changes cost and nothing else.
    #
    # Never discard uncommitted working-tree changes. This read's own exit
    # status is checked before its output: git status exits non-zero on a
    # worktree it cannot read while printing nothing, and taking that silence
    # for "clean" would PERMIT the reap.
    wt_status_out=$(git -C "$wt_path" status --porcelain 2>/dev/null)
    wt_status_rc=$?
    [ "$wt_status_rc" -eq 0 ] || continue
    [ -z "$wt_status_out" ] || continue
    # Never reap a branch named by a live RUNNING plan sentinel. The
    # sentinel is gitignored, so it is invisible to both git checks above:
    # a plan can be genuinely in-flight on a branch that reads [gone] +
    # clean. Scanned in both the worktree's own .gaia/local/ and main's.
    # For a PROPERLY LINKED worktree these are the same physical directory
    # (.gaia/local is one symlink to main's, D-011) and this is a harmless
    # double read. They are genuinely different directories for a worktree
    # that is not yet linked -- provisioning failed or has not run, or (as
    # this candidate itself may be, mid-teardown-evaluation) a worktree
    # nobody ever linked -- whose .gaia/local is still its own real,
    # unconnected directory. Scanning only main's would miss a live plan
    # sentinel written there and reap a session's whole worktree out from
    # under it, so both locations are scanned regardless of which state
    # this candidate is in. Same parse idiom as sweep #3.
    wt_live=0
    for wt_running in "$wt_path/.gaia/local/plans"/*/RUNNING \
      "$wt_path/.gaia/local/specs"/*/plan/RUNNING \
      "$wt_path/.gaia/local/specs"/*/plan-*/RUNNING \
      "$wt_main/.gaia/local/plans"/*/RUNNING \
      "$wt_main/.gaia/local/specs"/*/plan/RUNNING \
      "$wt_main/.gaia/local/specs"/*/plan-*/RUNNING; do
      [ -f "$wt_running" ] || continue
      wt_running_branch=$(sed -nE 's/^branch:[[:space:]]*([^[:space:]]+).*/\1/p' \
        "$wt_running" 2>/dev/null | head -1)
      if [ "$wt_running_branch" = "$wt_branch" ]; then
        wt_live=1
        break
      fi
      # An unparseable sentinel under the worktree's OWN tree names no
      # branch but still proves something is running there -- this guard
      # fails toward sparing, since a false "dead" reading deletes
      # someone's work. The same case under main's tree names no worktree
      # either, so it cannot be attributed to this one; that gap is real
      # and left uncovered rather than papered over.
      case "$wt_running" in
        "$wt_path"/*) [ -z "$wt_running_branch" ] && { wt_live=1; break; } ;;
      esac
    done
    [ "$wt_live" -eq 0 ] || continue
    # An unresolvable or unsafely-shaped base answers nothing.
    [ -n "$base" ] || continue
    # The fork point the branch is measured from.
    wt_mb=$(git -C "$wt_main" merge-base --end-of-options \
      "origin/$base" "refs/heads/$wt_branch" 2>/dev/null)
    wt_mb_rc=$?
    [ "$wt_mb_rc" -eq 0 ] || continue
    [ -n "$wt_mb" ] || continue
    # How much the branch carries, and what it carries as one combined diff.
    # --no-ext-diff/--no-textconv neutralize user diff configuration: an
    # external differ or a textconv filter could otherwise empty the diff at
    # exit 0 and manufacture the reap signal below. Each read's success is its
    # own exit status, never inherited and never softened with `|| true`,
    # which would turn a failed read back into the empty-output case.
    wt_ahead=$(git -C "$wt_main" rev-list --count --end-of-options \
      "$wt_mb..refs/heads/$wt_branch" 2>/dev/null)
    wt_ahead_rc=$?
    [ "$wt_ahead_rc" -eq 0 ] || continue
    wt_diff=$(git -C "$wt_main" diff --no-ext-diff --no-textconv --end-of-options \
      "$wt_mb" "refs/heads/$wt_branch" 2>/dev/null)
    wt_diff_rc=$?
    [ "$wt_diff_rc" -eq 0 ] || continue
    # --verbatim, never the default whitespace-normalizing mode (and never
    # --stable, which git rejects alongside it): normalization gives an
    # unpushed formatting-only commit the same id as the upstream squash, so
    # the default mode would reap and destroy that commit. The diff lives in a
    # shell variable rather than a temp file, so there is no predictable path
    # to guard and nothing to clean up.
    wt_pid_out=$(printf '%s\n' "$wt_diff" | git -C "$wt_main" patch-id --verbatim 2>/dev/null)
    wt_pid_rc=$?
    [ "$wt_pid_rc" -eq 0 ] || continue
    if [ -z "$wt_diff" ]; then
      # Zero commits ahead: the branch's tree IS the merge base's tree, it
      # holds nothing a deletion could lose, and both reads above succeeded,
      # so the reap proceeds without an upstream match. One or more commits
      # ahead with an empty combined diff means the branch holds commits that
      # cancel out, whose content is real and unreachable once the branch is
      # deleted, so that question is unanswerable and the worktree stays.
      # Emptiness alone is never the signal, in either arm.
      [ "$wt_ahead" -eq 0 ] || continue
    else
      # patch-id prints two fields and only the first is the id; the second
      # differs between reads. An empty id is a failed read, never a match --
      # and that check belongs HERE rather than above, because patch-id over
      # an empty diff prints nothing at exit 0, which would make the
      # zero-commits-ahead reap above unreachable.
      wt_pid=${wt_pid_out%%[[:space:]]*}
      [ -n "$wt_pid" ] || continue
      # One bounded pipeline over <merge-base>..origin/$base rather than a
      # per-commit show loop, with --no-merges so a merge commit cannot
      # contribute a spurious id. The bound is git log's own -n: `head -n`
      # would close the pipe and raise SIGPIPE 141 under this file's pipefail,
      # silently disabling the guard. wt_up_rc covers the whole two-command
      # pipeline, which pipefail makes sufficient -- $? is the leftmost
      # non-zero status, so neither read can be masked by the other -- and
      # splitting it would mean materializing up to 1000 commits' patches into
      # a shell variable. This is the one status here derived from a pipeline.
      wt_up_ids=$(git -C "$wt_main" log -p --no-merges --no-ext-diff --no-textconv \
        --format='commit %H' -n 1000 --end-of-options "$wt_mb..origin/$base" 2>/dev/null \
        | git -C "$wt_main" patch-id --verbatim 2>/dev/null)
      wt_up_rc=$?
      [ "$wt_up_rc" -eq 0 ] || continue
      # The ids are materialized before this loop reads them: breaking out of
      # a loop fed by a LIVE pipe closes it and raises SIGPIPE 141 on git log,
      # the same silently-disabled-guard failure `head -n` would cause.
      wt_match=0
      while read -r wt_up_id _; do
        [ -n "$wt_up_id" ] || continue
        if [ "$wt_up_id" = "$wt_pid" ]; then
          wt_match=1
          break
        fi
      done <<UPSTREAM_IDS
$wt_up_ids
UPSTREAM_IDS
      [ "$wt_match" -eq 1 ] || continue
    fi
    # Tear down inline: remove the worktree, delete its now-detached branch,
    # and prune the empty parent dirs a slashed name leaves behind. $wt_branch
    # is already in hand from the porcelain parse above, so there is no
    # branch re-read here, and the current-checkout guard above already rules
    # out git's own "refuses to remove the tree it is standing in" case.
    #
    # git also refuses a SINGLE --force against a worktree its own lock still
    # marks `locked ... initializing` -- what a session killed mid-`git
    # worktree add` leaves behind. Only a double --force clears that lock, so
    # step 1 retries with one before falling back to prune: a reaper that
    # cannot clear a wedged entry is a reaper that silently stops reaping it,
    # forever.
    if ! git -C "$wt_main" worktree remove --force "$wt_path" >/dev/null 2>&1; then
      git -C "$wt_main" worktree remove --force --force "$wt_path" >/dev/null 2>&1 || true
      if [ -e "$wt_path" ]; then
        git -C "$wt_main" worktree prune >/dev/null 2>&1 || true
        # Idempotent: an already-gone path is success; anything else is left
        # alone rather than force-deleted.
        [ -e "$wt_path" ] && continue
      fi
    fi
    # Never the default branch.
    if [ "$wt_branch" != "main" ] && [ "$wt_branch" != "master" ]; then
      git -C "$wt_main" branch -D "$wt_branch" >/dev/null 2>&1 || true
    fi
    # Walk up only within $wt_base, stopping at the first non-empty dir.
    wt_parent="$(dirname "$wt_path")"
    while [ "$wt_parent" != "$wt_base" ] && [ "${wt_parent#"$wt_base"/}" != "$wt_parent" ]; do
      rmdir "$wt_parent" 2>/dev/null || break
      wt_parent="$(dirname "$wt_parent")"
    done
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

# --- 9. Off-pattern outlier residue ----------------------------------------
janitor_sweep_outliers "$local_dir"

exit 0
