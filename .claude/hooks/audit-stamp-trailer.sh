#!/usr/bin/env bash
# audit-stamp-trailer.sh, write the GAIA-Audit commit trailer on HEAD.
#
# Purpose
#   Implements the stamp invariant + stamp placement rule described in
#   .gaia/local/plans/code-review-audit-ci/trailer-format.md. Called by the
#   code-audit-frontend agent (.claude/agents/code-audit-frontend.md) after the
#   audit has decided that an "Audit marker" is warranted. The trailer travels
#   with the commit through the network so CI can skip its own audit run when
#   the trailer's <agent-version> + <frontend-digest> match a CI-recomputed
#   digest of the PR head.
#
# Invocation
#   .claude/hooks/audit-stamp-trailer.sh [--root <path>]
#
#   --root <path>  The audited working root. Defaults to the ambient checkout,
#                  which is correct only when the caller reviewed that tree;
#                  a worktree dispatch must name the tree it read. Every other
#                  input still comes from the environment + git state.
#
# Required env input
#   AUDIT_TREE_SHA      The tree-sha the audit reviewed (captured at audit
#                       start). When unset/empty the script assumes the
#                       current tree IS the audited tree.
#   AUDIT_SELF_HEALED   "true" iff the audit made fix-commits during this run.
#                       Anything else (incl. unset) means the audit was clean.
#
# Exit codes
#   0 , Stamped successfully OR declined (precondition failed). One stdout
#        marker line is always emitted; the audit caller pipes it into its
#        final surface line. Stamp lines:
#          stamp: amended onto HEAD (un-pushed)
#          stamp: amended onto audit-self-heal HEAD
#          stamp: empty commit (created locally)
#        Decline lines (prefix "stamp: declined: "):
#          tree dirty
#          version file missing
#          version file empty
#          tree changed since audit started
#          not in a git repo
#          root not a directory
#          --root requires a path
#          unknown argument: <arg>
#          already stamped
#          frontend digest unavailable
#          members pending <list>
#          stamp lock contended
#   2 , Usage / unexpected error. Stderr.
#
# References
#   Frozen contract:        .gaia/local/plans/code-review-audit-ci/trailer-format.md
#   Audit-marker handshake: .claude/agents/code-audit-frontend.md "Audit marker (gate handshake)"
#   PR-merge gate hook:     .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash). Avoids associative arrays,
#     `${var^^}`, and other 4.x-only features.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves the repo root via
#     git rev-parse and uses repo-relative paths from there.
#   - Uses `git interpret-trailers --trailer` (git 2.13+) to round-trip the
#     trailer through git's RFC 822 folder.

set -euo pipefail

# Load the shared clearance reader + digest engine from this hook's OWN
# on-disk location (never cwd, never $repo_root), per the frozen
# library-resolution basis.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-digest.sh"
fi

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

emit_stamp() {
  printf 'stamp: %s\n' "$1"
}

emit_decline() {
  printf 'stamp: declined: %s\n' "$1"
}

emit_error() {
  printf 'audit-stamp-trailer: %s\n' "$1" >&2
}

# -----------------------------------------------------------------------------
# Stamp lock
# -----------------------------------------------------------------------------

# Portable mutex for the already-stamped-guard-through-commit critical
# section. flock is absent on macOS, so this uses mkdir's atomicity instead.
# Recovers a lock left behind by a crashed holder (stale past $stale seconds)
# so the gate can never wedge shut.
_stamp_lock_dir=""
acquire_stamp_lock() {
  local lock="$1" timeout=45 stale=15 waited=0 now mtime age
  while ! mkdir "$lock" 2>/dev/null; do
    # Held. Recover a stale lock left by a crashed holder.
    now="$(date +%s 2>/dev/null || echo 0)"
    # GNU stat first (-c %Y), then BSD/macOS stat (-f %m).
    mtime="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)"
    if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ]; then
      age=$(( now - mtime ))
      if [ "$age" -ge "$stale" ]; then
        rm -rf "$lock" 2>/dev/null || true
        continue
      fi
    fi
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  _stamp_lock_dir="$lock"
  trap 'if [ -n "$_stamp_lock_dir" ]; then rm -rf "$_stamp_lock_dir" 2>/dev/null || true; fi' EXIT
  return 0
}

# -----------------------------------------------------------------------------
# Repo + version preconditions
# -----------------------------------------------------------------------------

# The audited working root. `--root` names it explicitly; every other path and
# git call below derives from it. A dispatch against a linked worktree must
# pass it, because there the ambient cwd is the MAIN checkout: a cwd-derived
# root digests, gates, and stamps a tree the caller never reviewed. Absent the
# flag the ambient checkout is the root, which is the ordinary single-checkout
# case and the long-standing behavior.
root_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      # An EMPTY value declines rather than falling back to the cwd: a caller
      # that asked for an explicit root and silently got the ambient checkout
      # is the exact failure this flag exists to prevent, and the binding is
      # model-authored prose, so an empty one is a live case, not a hypothetical.
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        emit_decline "--root requires a path"
        exit 0
      fi
      root_arg="$2"
      shift 2
      ;;
    --root=*)
      root_arg="${1#--root=}"
      if [ -z "$root_arg" ]; then
        emit_decline "--root requires a path"
        exit 0
      fi
      shift
      ;;
    *)
      emit_decline "unknown argument: $1"
      exit 0
      ;;
  esac
done

# Verify the root is inside a git work tree.
if [ -n "$root_arg" ]; then
  if [ ! -d "$root_arg" ]; then
    emit_decline "root not a directory"
    exit 0
  fi
  repo_root=$(git -C "$root_arg" rev-parse --show-toplevel 2>/dev/null || true)
else
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    emit_decline "not in a git repo"
    exit 0
  fi
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$repo_root" ]; then
  emit_decline "not in a git repo"
  exit 0
fi

version_file="${repo_root}/.gaia/VERSION"

if [ ! -f "$version_file" ]; then
  emit_decline "version file missing"
  exit 0
fi

# trim leading + trailing whitespace (incl. trailing newline)
agent_version=$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')
agent_version="${agent_version#"${agent_version%%[![:space:]]*}"}"
agent_version="${agent_version%"${agent_version##*[![:space:]]}"}"

if [ -z "$agent_version" ]; then
  emit_decline "version file empty"
  exit 0
fi

# -----------------------------------------------------------------------------
# Tree state preconditions
# -----------------------------------------------------------------------------

# Working tree must be clean, except for claude-code-action's runtime
# working area `.claude-pr/`, a verbatim mirror of the repo the action
# creates for sandboxed execution. It is never audit output and is always
# untracked, so it must not count as a dirty tree. Relying on the adopter's
# `.gitignore` to hide it is fragile: that file is manifest-class `owned` and
# drifts, so an adopter copy can lack the entry and then decline the trailer
# on every otherwise-clean audit. Exclude it at the check instead. A real
# tracked modification (staged or unstaged) outside `.claude-pr/` still
# registers as dirty and declines.
if [ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude).claude-pr' 2>/dev/null)" ]; then
  emit_decline "tree dirty"
  exit 0
fi

current_tree=$(git -C "$repo_root" rev-parse "HEAD^{tree}" 2>/dev/null || true)
if [ -z "$current_tree" ]; then
  emit_error "could not resolve HEAD tree-sha"
  exit 2
fi

# If the caller told us which tree it audited, the current tree must match it.
audit_tree="${AUDIT_TREE_SHA:-}"
if [ -n "$audit_tree" ] && [ "$audit_tree" != "$current_tree" ]; then
  emit_decline "tree changed since audit started"
  exit 0
fi

# -----------------------------------------------------------------------------
# Frontend digest (C3 field 2). Fail closed: never stamp a trailer without a
# real digest. Reused below by the member-aware gate for the frontend member's
# own digest, avoiding a second tree walk.
# -----------------------------------------------------------------------------
frontend_digest="$(audit_member_digest "$repo_root" code-audit-frontend 2>/dev/null || true)"
if [ -z "$frontend_digest" ]; then
  emit_decline "frontend digest unavailable"
  exit 0
fi

# A multi-member diff has all three Code Audit Team members invoke this hook
# after writing their markers, and the member-aware gate below only passes
# once the last member clears. Two members can pass the already-stamped
# guard near-simultaneously (neither sees a trailer yet) and both reach the
# commit. The mutex below serializes the whole already-stamped-guard through
# final-commit region so only one racer stamps; the loser sees the winner's
# trailer and declines "already stamped". The lock lives under the
# per-worktree git dir so its granularity matches git's own index.lock:
# it never falsely contends across separate worktrees of the same repo.
lock_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || echo "${repo_root}/.git")/gaia-audit-stamp.lock"
if ! acquire_stamp_lock "$lock_dir"; then
  emit_decline "stamp lock contended"
  exit 0
fi

# -----------------------------------------------------------------------------
# Already-stamped guard
# -----------------------------------------------------------------------------

# If HEAD already carries a GAIA-Audit trailer, do not re-stamp. Re-stamping
# an un-pushed HEAD would amend again and orphan the existing marker file
# (the marker is keyed to the pre-amend SHA). Re-stamping a pushed HEAD
# creates a spurious empty commit on every audit re-run. Both produce the
# same bad outcome: the PR accrues unnecessary commits.
if git -C "$repo_root" log -1 --format='%B' | grep -q "^GAIA-Audit:"; then
  emit_decline "already stamped"
  exit 0
fi

# -----------------------------------------------------------------------------
# Member-aware gate: the trailer certifies that EVERY dispatched Code Audit Team
# member cleared this CONTENT, not just the caller. Mirrors the member-aware
# gate in .claude/hooks/post-audit-status.sh. Each member is keyed to its OWN
# digest (owned files + machinery), not the frontend digest or the tree.
# Resolver absent/non-executable, or the clearance lib unavailable, falls back
# to the caller's own clean judgment (today's behavior) so a partial or
# early-resume tree is never bricked (never a fail-closed deadlock).
# -----------------------------------------------------------------------------
resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
if [ -x "$resolver" ] && command -v clearance_member_cleared >/dev/null 2>&1; then
  # Run the resolver FROM the audited root, not merely by a path under it:
  # it derives its own repo root from its working directory, so an ambient-cwd
  # run resolves the main checkout's member set. Under worktree dispatch that
  # set is usually empty, which would make this member-aware gate pass
  # vacuously and let the first member through before any sibling cleared.
  members="$( (cd "$repo_root" && bash "$resolver") 2>/dev/null || true)"
  pending=""
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ "$m" = "code-audit-frontend" ]; then
      member_digest="$frontend_digest"
    else
      member_digest="$(audit_member_digest "$repo_root" "$m" 2>/dev/null || true)"
    fi
    if [ -z "$member_digest" ] || ! clearance_member_cleared "$repo_root" "$member_digest" "$m"; then
      pending="${pending}${pending:+ }${m}"
    fi
  done <<< "$members"
  if [ -n "$pending" ]; then
    emit_decline "members pending ${pending}"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Placement decision (amend vs empty commit)
# -----------------------------------------------------------------------------

self_healed="${AUDIT_SELF_HEALED:-false}"

# Pushed-vs-un-pushed detection.
#   Detached HEAD (CI checkout of pull_request.head.sha; rebase/cherry-pick
#   in flight; explicit `git checkout <sha>`), treat as pushed. The
#   stamp must never amend a commit the runner cannot guarantee is local.
#   The empty-commit path is the safe choice for any "HEAD is published"
#   semantics, which a detached HEAD always carries (CI), or for which
#   amending is meaningless (a transient checkout the user is not on).
#   Attached HEAD with an upstream + empty `@{u}..HEAD`, pushed.
#   Anything else (no upstream; ahead of upstream), un-pushed.
push_status="un-pushed"
head_branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD 2>/dev/null || true)
if [ -z "$head_branch" ]; then
  push_status="pushed"
elif upstream=$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
  if [ -n "$upstream" ]; then
    if [ -z "$(git -C "$repo_root" rev-list '@{u}..HEAD' 2>/dev/null)" ]; then
      push_status="pushed"
    fi
  fi
fi

trailer="GAIA-Audit: ${agent_version} ${frontend_digest} ${current_tree}"

# -----------------------------------------------------------------------------
# Stamp
# -----------------------------------------------------------------------------

if [ "$self_healed" = "true" ]; then
  # Audit owns the final commit, amend it regardless of push status.
  git -C "$repo_root" commit --amend --no-edit --no-verify \
    --trailer "$trailer" >/dev/null
  emit_stamp "amended onto audit-self-heal HEAD"
  exit 0
fi

if [ "$push_status" = "un-pushed" ]; then
  git -C "$repo_root" commit --amend --no-edit --no-verify \
    --trailer "$trailer" >/dev/null
  emit_stamp "amended onto HEAD (un-pushed)"
  exit 0
fi

# Pushed: never amend a published commit. Carry the trailer on an empty
# commit created locally only, the caller pushes after writing the audit
# marker (see .claude/agents/code-audit-frontend.md "Audit marker (gate
# handshake)"). Marker-before-push ensures a "chore: code review audit
# passed" commit never reaches remote history without a corresponding
# marker: if the marker write is interrupted, the un-pushed commit is
# recoverable via `git reset --hard HEAD~1`.
git -C "$repo_root" commit --allow-empty --no-verify \
  -m "chore: code review audit passed" \
  --trailer "$trailer" >/dev/null
emit_stamp "empty commit (created locally)"
exit 0
