#!/usr/bin/env bash
# audit-stamp-trailer.sh — write the GAIA-Audit commit trailer on HEAD.
#
# Purpose
#   Implements the stamp invariant + stamp placement rule described in
#   .gaia/local/plans/code-review-audit-ci/trailer-format.md. Called by the
#   code-review-audit agent (.claude/agents/code-review-audit.md) after the
#   audit has decided that an "Audit marker" is warranted. The trailer travels
#   with the commit through the network so CI can skip its own audit run when
#   the trailer's <agent-version> + <tree-sha> match the PR head.
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
#   AUDIT_SELF_HEALED   "true" iff the audit made fix-commits during this run.
#                       Anything else (incl. unset) means the audit was clean.
#
# Exit codes
#   0  — Stamped successfully OR declined (precondition failed). One stdout
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
#   2  — Usage / unexpected error. Stderr.
#
# References
#   Frozen contract:        .gaia/local/plans/code-review-audit-ci/trailer-format.md
#   Audit-marker handshake: .claude/agents/code-review-audit.md "Audit marker (gate handshake)"
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

# Working tree must be clean.
if [ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]; then
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
# Placement decision (amend vs empty commit)
# -----------------------------------------------------------------------------

self_healed="${AUDIT_SELF_HEALED:-false}"

# Pushed-vs-un-pushed detection.
#   Detached HEAD (CI checkout of pull_request.head.sha; rebase/cherry-pick
#   in flight; explicit `git checkout <sha>`) — treat as pushed. The
#   stamp must never amend a commit the runner cannot guarantee is local.
#   The empty-commit path is the safe choice for any "HEAD is published"
#   semantics, which a detached HEAD always carries (CI), or for which
#   amending is meaningless (a transient checkout the user is not on).
#   Attached HEAD with an upstream + empty `@{u}..HEAD` — pushed.
#   Anything else (no upstream; ahead of upstream) — un-pushed.
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

trailer="GAIA-Audit: ${agent_version} ${current_tree}"

# -----------------------------------------------------------------------------
# Stamp
# -----------------------------------------------------------------------------

if [ "$self_healed" = "true" ]; then
  # Audit owns the final commit — amend it regardless of push status.
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
# commit created locally only — the caller pushes after writing the audit
# marker (see .claude/agents/code-review-audit.md "Audit marker (gate
# handshake)"). Marker-before-push ensures a "chore: code review audit
# passed" commit never reaches remote history without a corresponding
# marker: if the marker write is interrupted, the un-pushed commit is
# recoverable via `git reset --hard HEAD~1`.
git -C "$repo_root" commit --allow-empty --no-verify \
  -m "chore: code review audit passed" \
  --trailer "$trailer" >/dev/null
emit_stamp "empty commit (created locally)"
exit 0
