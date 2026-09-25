#!/bin/bash
# local-janitor.sh, the wiki-landing catch-up for GAIA's machine-local
# working state.
#
# Side-effect only. A wiki landing whose merge outlasts the CLI's own bounded
# wait (`gaia wiki chain finish` / `wiki sync land` cuts a throwaway branch,
# pushes it, and enables auto-merge with `gh pr merge --auto`, a call that
# returns BEFORE the merge lands) leaves both a local wiki-sync/<date>-<sha>
# branch and a stale local base branch behind. This hook reconciles both, in
# order:
#   a. an existence gate. Everything below runs only when a local
#      wiki-sync/* branch is present at all, so an ordinary session pays
#      nothing for any of it.
#   b. a bounded, rate-limited `git fetch --prune` of origin. Bounded by
#      GAIA_WIKI_FETCH_TIMEOUT_SECONDS (default 5, floor 1, ceiling 30;
#      0 disables the fetch outright, and with it the reap in (c) and the
#      fast-forward in (d), both of which require evidence only a completed
#      fetch establishes) and rate-limited by
#      GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES (default 60, floor 5; 0 removes
#      the rate limit rather than disabling anything), with the attempt
#      timestamped BEFORE launch so a hung remote cannot buy an unbounded
#      retry every session. This fetch's effect is REPO-GLOBAL: refs and the
#      object store are shared across every linked worktree, so a
#      worktree-invoked fetch mutates state every tree observes. Tree
#      locality applies to the fast-forward in (d), which acts on $root, and
#      to nothing else.
#   c. a guarded reap of each wiki-sync/* branch whose upstream now reads
#      [gone]. [gone] does NOT prove a merge: it proves only that the remote
#      head ref is absent, and a pull request closed without merging and
#      then branch-deleted reads identically. So the reap refuses any branch
#      carrying work no remote-tracking ref has, tested by PATCH ID with
#      `git cherry` (the only test that can tell a squash-merged branch from
#      an abandoned one; ancestry cannot). That refusal is what (b) makes
#      necessary: with the sweep establishing [gone] itself on every
#      qualifying session, the state arrives routinely rather than
#      incidentally, so the reap needs its own evidence that the work
#      survived rather than inheriting it from whatever else happened to
#      prune. `git branch -D` (not -d): ancestry would refuse a squash merge
#      anyway. Gated on the fetch having COMPLETED, since a stale pre-fetch
#      enumeration establishes nothing.
#   d. a durable `--ff-only` fast-forward of the base branch to
#      origin/<base>, so the landing's own commit is actually present
#      locally. Purely local, no network call under any circumstance: (b)
#      already updated origin/<base> when it ran. Gated on HEAD being on
#      base, a clean working tree, base having an upstream, and the fetch
#      not being in an unknown state. Its safety comes from --ff-only itself
#      and not from the reap that happens to precede it: a fast-forward
#      against base's own upstream can only advance base to a commit the
#      remote already has, and it is a checkout-aware merge, never a bare
#      ref write.
#
# The catch-up obligation is DURABLE. A session that cannot discharge (d), a
# failing gate or a refused merge, records catchup_owed=1 in
# .gaia/local/cache/shared/wiki-base-catchup.state, and a later qualifying
# session retries with no new landing required. The obligation is one
# idempotent fact, so however many landings occur it collapses to at most one
# file; that is what bounds it, with no cap and no retention window. A
# fast-forward that was TRIED and failed additionally writes one line to
# .gaia/local/cache/shared/wiki-base-catchup.report, drained (read, then
# deleted, so it surfaces exactly once) by wiki-drift-check.sh, a
# UserPromptSubmit hook whose stdout reaches the conversation. A merely
# SKIPPED attempt is silent and leaves base byte-identical.
#
# Invoked from wiki-session-start.sh (a type:command SessionStart hook, the
# side-effect form Anthropic still permits; it injects NOTHING into
# context). Also runnable directly for testing:
#   bash .claude/hooks/local-janitor.sh
#
# Fail-safe: every gate above is cheap and local, the fast-forward is
# --ff-only against base's own upstream so it can only advance base to a
# commit the remote already has, a failing gate is a silent skip that leaves
# base byte-identical with the index and working tree untouched, and an
# attempt that was made and failed is reported through a channel that
# reaches the maintainer rather than swallowed. The hook always exits 0, so
# it cannot block a session start.
set -uo pipefail

# --- Two questions, not one: which tree am I, and where is main ------------
# `root` answers "which tree is invoking this run" -- the physically resolved
# git toplevel of the CURRENT checkout. The `current` branch-protect below
# needs exactly this: the tree actually running right now, never main's.
#
# `main_root` answers "where do the wiki-base catch-up state and report files
# actually live". A linked worktree's .gaia/local is one symlink to main's
# (D-011), so those files are conceptually always at main's tree, not the
# invoking one. Resolved via the shared resolver
# (.gaia/scripts/main-root-lib.sh), sourced beside this file via BASH_SOURCE
# the same way the other hooks that already depend on it do, rather than
# re-deriving "where is main" by hand.
#
# Repointing `root` itself at `gaia_resolve_main_root` was considered and
# rejected: the `current` guard exists to protect the INVOKING tree's
# branch, and swapping `root` wholesale would silently make it protect main's
# branch instead on every worktree-invoked run. The two questions get two
# variables, not one repointed one.
#
# Degrades to $root on any resolver failure or a missing sibling library --
# the same shape gaia-statusline.sh's STATE_ROOT fallback uses: an
# unresolvable main is not grounds to skip the catch-up, it just means this
# tree answers for itself (true for a fresh, not-yet-`git init` checkout, and
# for main's own run, where root already IS main).
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

main_root_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
if [ -f "$main_root_lib" ]; then
  # shellcheck source=/dev/null
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
# create .gaia/local: a fresh clone carrying an orphaned wiki-sync branch is
# swept regardless, and a `mkdir -p` from in here would recreate a directory
# that never existed. A skipped write is a silent no-op: a fresh clone with no
# .gaia/local is not a machine accumulating session-start cost, so its fetch
# simply runs on every session.
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
# Git-scoped: independent of .gaia/local, so a fresh clone carrying an
# orphaned wiki-sync branch is still swept before any .gaia/local exists.
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
# Full refname, stripped, never `--short`: a tag sharing the branch's name
# makes `--short` answer `heads/<branch>`, and the `[ "$current" = "$base" ]`
# gate below then misses, skipping the base fast-forward silently.
current=$(git -C "$root" symbolic-ref --quiet HEAD 2>/dev/null || true)
current=${current#refs/heads/}
branch_tracks=$(git -C "$root" for-each-ref \
  --format='%(refname:short) %(upstream:track)' refs/heads/ 2>/dev/null || true)

# Resolved once, unconditionally -- consumed by this sweep's guarded reap
# below AND by the durable-obligation fast-forward further down this file,
# which runs even in a session holding no wiki-sync/* branch at all (D2:
# origin/HEAD with a main fallback, matching defaultBranch's convention).
# SEC-011: shape-validated immediately, before any git call interpolates it.
# An unresolvable or unsafely-shaped base clears $base to empty; every
# consumer below treats an empty $base as "unanswerable, skip".
# Read the FULL refname and strip the full prefix, rather than asking for
# `--short` and stripping `origin/`. `--short` answers with the shortest
# UNAMBIGUOUS spelling, so a tag named `origin/main` makes it answer
# `remotes/origin/main`; the `origin/` strip then no longer matches and every
# consumer below is handed a base naming nothing. This is the same spelling
# .claude/hooks/lib/audit-base-provenance.sh already requires for the same
# reason.
base=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
base=${base#refs/remotes/origin/}
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
  # Knobs, the janitor's shipped clamp idiom. `0` is special-cased on BOTH knobs before the floor
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
      # Half B still runs, and nothing non-zero escapes,
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
    # Never `export` any of it: this process runs other `git`
    # calls (the reap and the fast-forward), and an exported
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
      # for the fast-forward in this same process to trip over. Remove only the
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
        cherry_out=$(git -C "$root" cherry --end-of-options "refs/remotes/origin/$base" "$ref" 2>/dev/null)
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
# fast-forward. Git-scoped like the rest of this sweep, independent of
# .gaia/local.
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
  && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null 2>&1 \
  && git -C "$root" merge-base --is-ancestor --end-of-options \
       "refs/remotes/origin/$base" "refs/heads/$base" 2>/dev/null; then
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
    if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null 2>&1; then
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
    ff_stderr=$(git -C "$root" merge --ff-only --end-of-options "refs/remotes/origin/$base" 2>&1 >/dev/null)
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

exit 0
