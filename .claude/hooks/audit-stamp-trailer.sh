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
#   .claude/hooks/audit-stamp-trailer.sh
#
#   Argument-less. Reads its inputs from the environment + git state.
#
# Required env input
#   AUDIT_TREE_SHA      The tree-sha the audit reviewed (captured at audit
#                       start). When unset/empty the script assumes the
#                       current tree IS the audited tree.
#   AUDIT_SELF_HEALED   "true" iff the audit repaired anything during this run,
#                       working tree or commit. Local passes repair the working
#                       tree and make no commit; CI commits its own self-heal.
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
#          already stamped
#          frontend digest unavailable
#          clearance reader unavailable
#          frontend holds a live refusal
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
# Bracketed in `set +e` because errexit is armed above: a module that is present
# but unparseable abandons the shell AT the load, so an `-f` test ahead of it
# proves nothing and no caller can guard it from outside -- `bash -n` does not
# recurse into what a file sources. Every consumer below already gates on
# `type` / `command -v`, which is what degrades once the shell survives.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || true
set +e
if [ -n "$_lib_dir" ]; then
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-clearance.sh" ] && . "$_lib_dir/audit-clearance.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-digest.sh" ] && . "$_lib_dir/audit-digest.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/gaia-version.sh" ] && . "$_lib_dir/gaia-version.sh" 2>/dev/null
fi
set -e

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

# Verify we are inside a git work tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_decline "not in a git repo"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  emit_decline "not in a git repo"
  exit 0
fi

version_file="${repo_root}/.gaia/VERSION"

if [ ! -f "$version_file" ]; then
  emit_decline "version file missing"
  exit 0
fi

if ! command -v gaia_read_version >/dev/null 2>&1; then
  emit_decline "version normalizer unavailable (lib/gaia-version.sh)"
  exit 0
fi

agent_version="$(gaia_read_version "$version_file")"

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

# A multi-member diff has every dispatched Code Audit Team member invoke this
# hook after writing their markers, and the member-aware gate below only passes
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
# An ABSENT or non-executable resolver falls back to the caller's own clean
# judgment so a partial or early-resume tree is never bricked (never a
# fail-closed deadlock). ABSENT and FAILED are two different
# states and only the first gets that fallback: a resolver that runs and exits
# non-zero could not resolve the audited root, so the member set is unknown,
# and stamping a trailer that certifies an unknown set is the vacuous pass this
# gate exists to prevent. That arm declines.
#
# The invocation is anchored on $repo_root, the acting tree this hook measures,
# because the resolver derives its own root from cwd. $repo_root is itself a
# toplevel query against the ambient cwd, so the anchor normalizes a run from a
# SUBDIRECTORY up to the checkout root; it cannot repoint the hook at another
# tree. Selecting the tree is the caller's job, done by invoking the hook from
# it.
#
# Two checks sit AHEAD of that branch and hold whether or not a roster resolves,
# so the never-brick fallback can no longer stamp over a refusal it never read.
# -----------------------------------------------------------------------------

# The refusal reader is required by both of them, probed once here rather than
# per member. A clearance lib carrying clearance_member_cleared without
# clearance_member_refused makes a refusal call exit 127, and the surrounding
# `||` chain consumes that as "not refused", reverting the gate to cleared-only
# and stamping on content where a member holds a live refusal. That is the one
# degradation direction this gate must never take, so an unavailable reader
# declines rather than falling open, matching post-audit-status.sh.
#
# The posture that decides this arm, stated once for both hooks: the trailer is
# an attestation, and an attestation nobody can verify is worse than none. Fail
# closed costs nothing a merge needs, because the trailer is one of several
# independent signals the merge gate reads (pr-merge-audit-check.sh's
# frontend_cleared tries the member's own marker first and the GitHub status
# after), so withholding it leaves those standing rather than bricking anything.
if ! command -v clearance_member_refused >/dev/null 2>&1 \
   || ! command -v clearance_member_cleared >/dev/null 2>&1; then
  emit_decline "clearance reader unavailable"
  exit 0
fi

# The refusal that contradicts THIS trailer, read without the roster. Field 2
# certifies code-audit-frontend at $frontend_digest, and that member is exactly
# what the merge gate's trailer fallback stands in for, so a live refusal for
# that member and digest contradicts the trailer on its own terms. An earned
# write never clears a same-digest refusal (only --supersede-refusal does, as an
# explicit recorded act), so a member that refused this digest and was then
# re-run with a plain earned write holds BOTH artifacts. The member loop below
# catches that for every dispatched member, but it is armed only when the
# resolver is executable, and the no-resolver fallback stamps on the caller's own
# judgment alone. Left to that fallback the trailer asserts a clean pass over a
# live refusal, and CI's whole-team floor anchors a later round past it.
if clearance_member_refused "$repo_root" "$frontend_digest" code-audit-frontend; then
  emit_decline "frontend holds a live refusal"
  exit 0
fi

resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
if [ -x "$resolver" ]; then
  resolver_rc=0
  members="$( cd "$repo_root" && bash "$resolver" 2>/dev/null )" || resolver_rc=$?
  if [ "$resolver_rc" -ne 0 ]; then
    emit_decline "member resolver could not answer"
    exit 0
  fi
  pending=""
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ "$m" = "code-audit-frontend" ]; then
      member_digest="$frontend_digest"
    else
      member_digest="$(audit_member_digest "$repo_root" "$m" 2>/dev/null || true)"
    fi
    # Refusal-first, mirroring the member loop in post-audit-status.sh and the
    # merge hook's own precedence. A member that cleared a digest in one wave and
    # refused the SAME digest in a later one holds both artifacts, because the
    # writer publishes a refusal beside an earned marker rather than replacing
    # it. Read cleared alone and that member counts as cleared, nothing lands in
    # $pending, and the trailer stamps a clean pass over a live refusal.
    if [ -z "$member_digest" ] \
       || clearance_member_refused "$repo_root" "$member_digest" "$m" \
       || ! clearance_member_cleared "$repo_root" "$member_digest" "$m"; then
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
