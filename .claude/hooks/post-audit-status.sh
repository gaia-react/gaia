#!/usr/bin/env bash
# post-audit-status.sh, post the GAIA-Audit success commit status on HEAD.
#
# Purpose
#   Called by a Code Audit Team member's agent (code-audit-frontend at
#   .claude/agents/code-audit-frontend.md, or a specialized member) on the
#   local (Claude-driven merge) path, AFTER that member's marker has been
#   written. Posts a GAIA-Audit commit status of state=success on HEAD, but
#   only once EVERY member dispatched against HEAD's diff has cleared, so the
#   same server-side gate the CI path satisfies is satisfied here too, letting
#   the github.com button and the per-author resolver's required-check
#   verification clear. The caller's own marker file is a literal precondition
#   for its own call; the member-aware gate below is the precondition for the
#   POST itself.
#
# Invocation
#   .claude/hooks/post-audit-status.sh <marker-path>
#
#   <marker-path>  The marker file the calling member's agent just wrote
#                  (.gaia/local/audit/<tree-sha>.ok for code-audit-frontend,
#                  .gaia/local/audit/<tree-sha>.<member>.ok for a specialized
#                  member). Its existence gates this call; the agent passes
#                  the path it wrote in the marker step.
#
# Behavior
#   Best-effort and fail-safe-asymmetric: when gh is absent or unauthenticated,
#   or when a dispatched member other than the caller hasn't cleared yet, the
#   POST is skipped (the button stays blocked) but the marker the caller
#   already wrote is untouched. The status is never posted without every
#   dispatched member's marker present, and an absent status never inverts
#   into a cleared gate. Order-independent: each member calls this script
#   after writing its own marker, so whichever member finishes last is the one
#   whose call actually posts.
#
#   Order-independence rests on the TREE key. Markers are named for HEAD's tree,
#   not its commit sha, so code-audit-frontend's GAIA-Audit trailer stamp -- an
#   empty commit, which advances HEAD while leaving the tree byte-identical --
#   does not orphan a sibling member's marker. Keyed to the commit, the stamp
#   would invalidate every marker written before it, and the member that
#   finished last would find the others' markers gone and decline forever. The
#   POST itself still targets the commit sha: a GitHub commit status has nowhere
#   else to land.
#
# Exit codes
#   0 , Posted successfully OR declined (precondition failed). One stdout
#        marker line is always emitted; the audit caller surfaces it. Lines:
#          status: posted GAIA-Audit success <short-sha>
#        Decline lines (prefix "status: declined: "):
#          marker absent
#          marker not a valid clearance
#          gh absent
#          gh unauthenticated
#          version file missing
#          version file empty
#          repo slug unresolved
#          audited tree not on pushed head
#          members pending <list>
#          post failed
#   2 , Usage error (no marker path argument). Stderr.
#
# References
#   Audit-marker handshake: .claude/agents/code-audit-frontend.md "Audit marker (gate handshake)"
#   Dispatch resolver:      .gaia/scripts/resolve-audit-members.sh
#   Per-author resolver:    .gaia/scripts/read-audit-ci-config.sh
#   State-aware readers:    .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash).
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves the repo root via
#     git rev-parse and uses repo-relative paths from there.
#   - The success description "<version> <tree-sha>" matches what every
#     state-aware GAIA-Audit reader accepts as cleared, and state=success
#     distinguishes it from the CI local-mode stand-down's pending sentinel.

set -euo pipefail

# Load the shared clearance reader from this hook's OWN on-disk location
# (never cwd, never $repo_root), per the frozen library resolution basis.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi

emit_posted() {
  printf 'status: posted GAIA-Audit success %s\n' "$1"
}

emit_decline() {
  printf 'status: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-audit-status: %s\n' "$1" >&2
}

marker="${1:-}"
if [ -z "$marker" ]; then
  emit_error "usage: post-audit-status.sh <marker-path>"
  exit 2
fi

# Marker-first: the marker the caller wrote is the literal precondition.
if [ ! -f "$marker" ]; then
  emit_decline "marker absent"
  exit 0
fi

# The gate accepts only a writer-produced clearance. Derive the member and tree
# from the marker filename and require a writer-shaped body: a present but
# legacy or hand-written marker is not a clearance and must not clear the POST.
# The authority POSTs the path of a CARRIED clearance, so strip any of the three
# provenance extensions (only one ever matches a given filename).
marker_base="$(basename "$marker")"
marker_stem="$marker_base"
marker_stem="${marker_stem%.ok}"
marker_stem="${marker_stem%.carried}"
marker_stem="${marker_stem%.refused}"
marker_tree="${marker_stem%%.*}"
marker_member_part="${marker_stem#"$marker_tree"}"
if [ -z "$marker_member_part" ]; then
  marker_member="code-audit-frontend"
else
  marker_member="${marker_member_part#.}"
fi
if ! clearance_acceptable "$marker" "$marker_member" "$marker_tree"; then
  emit_decline "marker not a valid clearance"
  exit 0
fi

# gh must be present and authenticated; otherwise skip the POST (fail-safe
# asymmetry: the marker stays, the button stays blocked, never inverts).
if ! command -v gh >/dev/null 2>&1; then
  emit_decline "gh absent"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  emit_decline "gh unauthenticated"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

version_file="${repo_root}/.gaia/VERSION"
if [ ! -f "$version_file" ]; then
  emit_decline "version file missing"
  exit 0
fi

version=$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')
version="${version#"${version%%[![:space:]]*}"}"
version="${version%"${version##*[![:space:]]}"}"
if [ -z "$version" ]; then
  emit_decline "version file empty"
  exit 0
fi

# The sha branch protection checks is the PR head on the REMOTE, not local HEAD.
# On the empty-commit stamp path local HEAD is an un-pushed commit origin has
# never seen, so a status posted there 422s and never lands (#726). Target the
# pushed PR head instead (mirrors CI, which posts on pull_request.head.sha).
head_sha="$(gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || true)"
if [ -z "$head_sha" ]; then
  # No PR resolvable: fall back to the upstream tracking tip, then local HEAD.
  head_sha="$(git -C "$repo_root" rev-parse '@{u}' 2>/dev/null || true)"
fi
if [ -z "$head_sha" ]; then
  head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
fi

tree_sha=$(git -C "$repo_root" rev-parse "HEAD^{tree}" 2>/dev/null || true)
if [ -z "$head_sha" ] || [ -z "$tree_sha" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

# Never green a tree the target sha does not carry. The audited tree (local
# HEAD's tree) must equal the target sha's tree; otherwise the audited content
# is not on the remote head yet (un-pushed tree-changing work, e.g. an unpushed
# self-heal) and posting would falsely clear a stale head. Decline instead.
target_tree="$(git -C "$repo_root" rev-parse "${head_sha}^{tree}" 2>/dev/null || true)"
if [ -z "$target_tree" ] || [ "$target_tree" != "$tree_sha" ]; then
  emit_decline "audited tree not on pushed head"
  exit 0
fi

# Member-aware gate (blocker COV-001): require EVERY dispatched Code Audit
# Team member's marker, not just the caller's own, before posting success.
# Otherwise a frontend-only POST on a mixed diff would flip the GAIA-Audit
# status green (and unlock the github.com merge button) while a co-dispatched
# maintainer member still withholds over an unresolved finding. Resolver
# absent/unusable falls back to today's single-marker POST unchanged, a
# partial/early-resume tree is never bricked.
# carried is set when ANY dispatched member's clearance is carried (not earned).
# The producer decides the description shape from the state on disk; there is no
# CLI flag, which is what makes it deterministic.
carried=0
resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
if [ -x "$resolver" ]; then
  members="$(bash "$resolver" 2>/dev/null || true)"
  pending=""
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if clearance_member_cleared "$repo_root" "$tree_sha" "$m"; then
      # Prefer the earned marker; a member cleared only by its carried marker
      # makes the whole status carried.
      ep="$(clearance_earned_path "$repo_root" "$tree_sha" "$m")"
      if ! clearance_acceptable "$ep" "$m" "$tree_sha"; then
        cp="$(clearance_carried_path "$repo_root" "$tree_sha" "$m")"
        clearance_acceptable "$cp" "$m" "$tree_sha" && carried=1
      fi
    else
      pending="${pending}${pending:+ }${m}"
    fi
  done <<< "$members"

  if [ -n "$pending" ]; then
    emit_decline "members pending ${pending}"
    exit 0
  fi
fi

# Description: today's two-field "<version> <tree>" when every dispatched
# member's clearance is earned; "<version> <tree> carried" when any is carried.
# The third field is invisible to CI's base resolver's field-1-only parse (so a
# carried clearance can never anchor the incremental review base) while a
# substring reader still accepts it, and the merge gate tolerates it.
desc="${version} ${tree_sha}"
[ "$carried" -eq 1 ] && desc="${desc} carried"

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$repo" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

if gh api "repos/${repo}/statuses/${head_sha}" \
  --method POST \
  --field state=success \
  --field context=GAIA-Audit \
  --field description="${desc}" >/dev/null 2>&1; then
  # Surface the sha we POSTed to (the remote PR head), never local HEAD: on the
  # empty-commit stamp path local HEAD is an un-pushed commit while head_sha is
  # the pushed PR head, so the two differ. Assert the surfaced short sha
  # re-resolves to head_sha; on a mismatch surface the full head_sha and warn.
  posted_short="$(git -C "$repo_root" rev-parse --short "$head_sha" 2>/dev/null || echo "$head_sha")"
  if [ "$(git -C "$repo_root" rev-parse "$posted_short" 2>/dev/null || true)" != "$(git -C "$repo_root" rev-parse "$head_sha" 2>/dev/null || true)" ]; then
    emit_error "posted-sha mismatch: surfaced ${posted_short} does not resolve to POSTed ${head_sha}"
    posted_short="$head_sha"
  fi
  emit_posted "$posted_short"
  exit 0
fi

emit_decline "post failed"
exit 0
