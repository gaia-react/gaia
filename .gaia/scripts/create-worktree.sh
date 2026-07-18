#!/usr/bin/env bash
# WorktreeCreate hook: creates a git worktree under .claude/worktrees/ and sets
# up GAIA shared-state symlinks. Claude Code fires this hook and waits for the
# worktree path on stdout before the agent starts. A registered WorktreeCreate
# hook replaces the harness's default `git worktree` logic entirely.
#
# Input:  JSON on stdin. The harness sends the worktree name under `.name`
#         (legacy/HTTP variants used `.worktree_name`); no base ref or target
#         path is included, so this hook derives both. Common fields
#         (session_id, cwd, hook_event_name, ...) are present but unused.
# Output: absolute worktree path on stdout.
# Exit:   0 on success with path; non-zero aborts worktree creation.
#
# Concurrency: create-and-cleanup runs under a per-worktree-name lock, so two
# sessions racing on the same name serialize instead of one deleting the other's
# in-flight checkout; unrelated names still create in parallel.

set -euo pipefail

# Shared flock/mkdir mutex helper (macOS has no flock). Best-effort source: the
# lock is an optimization, and the create still runs unlocked if it is absent.
# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true

input="$(cat)"
# The harness sends the worktree name under `.name`; older/HTTP hook variants
# used `.worktree_name`. Read tolerantly so the hook survives payload drift.
worktree_name="$(printf '%s' "$input" | jq -r '.name // .worktree_name // ""')"

if [ -z "$worktree_name" ]; then
  printf 'create-worktree: missing worktree_name\n' >&2
  exit 1
fi

# Defense-in-depth: worktree_name lands in a filesystem path and a branch
# name. Reject `..` and absolute paths so the worktree can't escape the
# worktrees/ directory even if the stdin payload is influenced by untrusted
# content. Internal slashes (e.g. `fix/foo`) stay allowed.
if [[ "$worktree_name" == *..* || "$worktree_name" == /* ]]; then
  printf 'create-worktree: worktree_name must not contain ".." or start with "/"\n' >&2
  exit 1
fi

project_root="$(git rev-parse --show-toplevel)"

# No base ref is carried in the WorktreeCreate payload, so derive one: honor a
# ref if a future harness version supplies it, else branch fresh from the remote
# default branch (matching the harness default), else fall back to local HEAD.
base_ref="$(printf '%s' "$input" | jq -r '.base_ref // .source_ref // ""')"
if [ -z "$base_ref" ]; then
  base_ref="$(git -C "$project_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
fi

# Create under .claude/worktrees/ to match the harness default and gitignore.
worktree_path="$project_root/.claude/worktrees/$worktree_name"

mkdir -p "$(dirname "$worktree_path")"

# True (exit 0) iff `git worktree list --porcelain` shows $1 as a worktree left
# `locked` with git's own `initializing` reason, the fingerprint of a session
# killed mid-`worktree add`. Such an entry refuses a single `worktree remove
# --force` and wedges the name until a double --force clears it. Scoped to the
# target block (blocks are blank-line separated) so a sibling worktree's lock
# never matches, and matched on the exact `worktree <path>` line for the same
# whole-line reason the grep below uses.
wt_entry_is_locked_initializing() {
  local path="$1" list="$2"
  awk -v target="worktree $path" '
    $0 == "" { in_block = 0 }
    $0 == target { in_block = 1 }
    in_block && $0 ~ /^locked([[:space:]]|$)/ && $0 ~ /initializing/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' <<<"$list"
}

# The create-and-cleanup critical section. Runs under the per-name lock below,
# or unlocked as a fallback, and returns rather than exits so the lock helper can
# capture its status. $1 records which: `1` when we hold the lock, `0` when we do
# not. Holding the lock means no peer can be mid-`worktree add` here, so a leftover
# is settled and safe to reclaim; unlocked, a `locked initializing` entry may be a
# live peer still checking out, so the reclaim below stays gated on $1.
create_worktree_unit() {
  local locked="${1:-0}"

  # Sample whether the target path already exists before we touch it, now that
  # the lock makes the sample stable. The failure cleanup below force-removes
  # $worktree_path, and on a name collision (a peer session already holding a
  # worktree of this name) both `worktree add` attempts fail, so that cleanup
  # would delete someone else's worktree along with any uncommitted work in it.
  # Only clean up a path this run created.
  local path_pre_existed=0
  if [ -e "$worktree_path" ]; then
    path_pre_existed=1
  fi

  # Try new branch first; if name already exists, check out the existing one.
  # Silence git entirely (stdout too): "HEAD is now at ..." is written to stdout,
  # and the hook's stdout must carry only the worktree path for the harness.
  if ! git -C "$project_root" worktree add "$worktree_path" -b "$worktree_name" "$base_ref" >/dev/null 2>&1; then
    if ! git -C "$project_root" worktree add "$worktree_path" "$worktree_name" >/dev/null 2>&1; then
      printf 'create-worktree: git worktree add failed for %s\n' "$worktree_path" >&2
      # Both adds failed, so this run registered nothing: any worktree now at the
      # path is a settled peer's, not one racing us mid-add (the per-name lock
      # rules that out). Read the list to classify it. Fail closed on an
      # unreadable list: it cannot prove the path is ours, and not deleting other
      # people's work is this guard's entire purpose.
      local wt_list
      if ! wt_list="$(git -C "$project_root" worktree list --porcelain 2>/dev/null)"; then
        printf 'create-worktree: cannot read the worktree list; leaving %s alone\n' "$worktree_path" >&2
        return 1
      fi

      # A session killed mid-`worktree add` leaves a `locked initializing` entry
      # a single --force cannot remove, wedging the name for every later run.
      # Reclaim it with a double --force + prune so the next invocation can reuse
      # the name (the same self-heal the prunable-registration branch below
      # performs). Gated on holding the lock: only then is that entry provably
      # dead. Unlocked (a lock-timeout or no-lock fallback), the same entry might
      # be a live peer mid-add, so we skip the reclaim and fall through to the
      # conservative leave-intact branch, never force-removing a live checkout.
      if [ "$locked" = 1 ] && wt_entry_is_locked_initializing "$worktree_path" "$wt_list"; then
        printf 'create-worktree: reclaiming a crashed worktree registration at %s\n' "$worktree_path" >&2
        git -C "$project_root" worktree remove --force --force "$worktree_path" >/dev/null 2>&1 || true
        git -C "$project_root" worktree prune >/dev/null 2>&1 || true
        rm -rf "$worktree_path" 2>/dev/null || true
        return 1
      fi

      # `-e` is load-bearing, not redundant with the grep: git keeps listing a
      # worktree whose directory is gone (it is merely prunable), so the grep
      # alone would read a crashed run's stale registration as live and skip the
      # cleanup that prunes it, wedging this name for every later run.
      # Here-string, not a pipe: `git ... | grep -q` under pipefail lets grep's
      # early exit SIGPIPE the upstream write and flip a match into a false miss.
      # `-x` (whole-line) because `worktree /path/alpha` prefixes `.../alpha2`.
      if [ "$path_pre_existed" -eq 1 ] \
        || { [ -e "$worktree_path" ] && grep -qxF "worktree $worktree_path" <<<"$wt_list"; }; then
        # Not ours to delete. Say so: a name collision is the likeliest reason the
        # add failed at all, and the operator needs a way out.
        printf 'create-worktree: %s was not created by this run; leaving it intact (remove it yourself, or retry with a different worktree name)\n' "$worktree_path" >&2
      else
        # `git worktree remove --force` clears both the directory and the stale
        # .git/worktrees/ registration; rm -rf is the fallback if git itself
        # can't clean up. rmdir alone would leave a non-empty dir behind.
        git -C "$project_root" worktree remove --force "$worktree_path" 2>/dev/null \
          || rm -rf "$worktree_path" 2>/dev/null || true
      fi
      return 1
    fi
  fi

  # Set up shared-state symlinks inside the new worktree.
  (cd "$worktree_path" && bash ".gaia/scripts/link-worktree.sh") || true

  printf '%s\n' "$worktree_path"
  return 0
}

# Serialize create-and-cleanup per worktree name so two sessions racing on the
# SAME name can't interleave: the loser waits, then only ever inspects a settled
# peer worktree and leaves it alone (closing the create-time TOCTOU). Unrelated
# names still create in parallel. Each name gets its own lock directory; the
# shared helper drops its fixed `specs.lock` file inside it.
rc=0
lock_dir=""
if mkdir -p "$project_root/.gaia/local/worktree-locks/${worktree_name//\//__}" 2>/dev/null; then
  lock_dir="$project_root/.gaia/local/worktree-locks/${worktree_name//\//__}"
fi

if [ -n "$lock_dir" ] && declare -f with_ledger_lock >/dev/null 2>&1; then
  # Tuned for a checkout, not a ledger read-modify-write: wait longer for a
  # peer's create to finish, and treat only a lock older than 5 minutes as
  # abandoned so a slow-but-live checkout is never reclaimed mid-flight. On
  # acquisition timeout (rc 75) fall back to an unlocked attempt rather than fail
  # the hook outright, which is no worse than the pre-lock behavior.
  GAIA_LEDGER_LOCK_TIMEOUT_SECS="${GAIA_WORKTREE_LOCK_TIMEOUT_SECS:-30}" \
  GAIA_LEDGER_LOCK_STALE_SECS="${GAIA_WORKTREE_LOCK_STALE_SECS:-300}" \
    with_ledger_lock "$lock_dir" create_worktree_unit 1 || rc=$?
  if [ "$rc" -eq 75 ]; then
    printf 'create-worktree: worktree lock busy; proceeding without it\n' >&2
    rc=0
    create_worktree_unit 0 || rc=$?
  fi
else
  # No lock available (helper unsourceable or lock dir uncreatable): best-effort
  # unlocked create, preserving the pre-lock behavior.
  create_worktree_unit 0 || rc=$?
fi

exit "$rc"
