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
#                  (.gaia/local/audit/<digest>.ok for code-audit-frontend,
#                  .gaia/local/audit/<digest>.<member>.ok for a specialized
#                  member, <digest> the member's own 64-hex content digest).
#                  Its existence gates this call; the agent passes the path
#                  it wrote in the marker step.
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
#   Order-independence rests on the DIGEST key. Markers are named for the
#   member's own content digest, not its commit sha, so code-audit-frontend's
#   GAIA-Audit trailer stamp -- an empty commit, which advances HEAD while
#   leaving every blob byte-identical -- rotates no member's digest and does
#   not orphan a sibling member's marker. Keyed to the commit, the stamp would
#   invalidate every marker written before it, and the member that finished
#   last would find the others' markers gone and decline forever. The POST
#   itself still targets the commit sha: a GitHub commit status has nowhere
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
#          frontend digest unavailable
#          repo slug unresolved
#          audited tree not on pushed head
#          stamp not pushed
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
#   - The success description "<version> <frontend-digest> <tree-sha>" (three
#     positional fields; field 2 is the digest) matches what every
#     state-aware GAIA-Audit reader accepts as cleared, and state=success
#     distinguishes it from the CI local-mode stand-down's pending sentinel.

set -euo pipefail

# Load the shared clearance reader + digest engine from this hook's OWN
# on-disk location (never cwd, never $repo_root), per the frozen library
# resolution basis.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-digest.sh"
fi
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/gaia-version.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/gaia-version.sh"
fi

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `repo_root` derivation below.
_root_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [ -n "$_root_lib_dir" ] && [ -f "$_root_lib_dir/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_root_lib_dir/.gaia/scripts/main-root-lib.sh"
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

# The gate accepts only a writer-produced clearance. Derive the member and
# digest from the marker filename and require a writer-shaped body: a present
# but legacy or hand-written marker is not a clearance and must not clear the
# POST. Only two provenance extensions exist (there is no carried family), so
# strip either (only one ever matches a given filename); the stem before the
# first remaining dot is the 64-hex digest, the remainder is the member infix.
marker_base="$(basename "$marker")"
marker_stem="$marker_base"
marker_stem="${marker_stem%.ok}"
marker_stem="${marker_stem%.refused}"
marker_digest="${marker_stem%%.*}"
marker_member_part="${marker_stem#"$marker_digest"}"
if [ -z "$marker_member_part" ]; then
  marker_member="code-audit-frontend"
else
  marker_member="${marker_member_part#.}"
fi
if ! clearance_acceptable "$marker" "$marker_member" "$marker_digest"; then
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

# TWO roots, mirroring pr-merge-audit-check.sh, because this script spans two
# different questions and one root cannot answer both.
#
#   repo_root   The ACTING tree. Everything this script measures is a property
#               of the tree being audited and pushed: the .gaia/VERSION it
#               stamps into the status description, the content digests it
#               derives, the HEAD/upstream/tree shas it compares against the
#               PR head, and the roster resolver it runs. Main-anchoring these
#               reads main's HEAD tree while head_sha comes from the acting
#               tree's PR, so from a linked worktree the "audited tree not on
#               pushed head" guard below declines on every run and the
#               GAIA-Audit status can never post -- leaving branch protection
#               blocked with no way to clear it.
#   store_root  WHERE a clearance lives. Resolved to the MAIN checkout: marker
#               state is main-anchored shared state (.gaia/state-registry.json
#               scope=shared, the symlinked audit/ store), not a property of
#               whichever tree this script happens to run in. Falls back to
#               repo_root when the resolver is unavailable or fails -- the same
#               fail-open direction the original CWD-anchored derivation had.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

store_root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  store_root="$(gaia_resolve_main_root 2>/dev/null)" || store_root=""
fi
[ -n "$store_root" ] || store_root="$repo_root"

version_file="${repo_root}/.gaia/VERSION"
if [ ! -f "$version_file" ]; then
  emit_decline "version file missing"
  exit 0
fi

if ! command -v gaia_read_version >/dev/null 2>&1; then
  emit_decline "version normalizer unavailable (lib/gaia-version.sh)"
  exit 0
fi

version="$(gaia_read_version "$version_file")"
if [ -z "$version" ]; then
  emit_decline "version file empty"
  exit 0
fi

# Frontend digest (C3 field 2). Fail closed: never post a status without a
# real digest. Reused below by the member-aware gate for the frontend
# member's own digest, avoiding a second tree walk.
frontend_digest="$(audit_member_digest "$repo_root" code-audit-frontend 2>/dev/null || true)"
if [ -z "$frontend_digest" ]; then
  emit_decline "frontend digest unavailable"
  exit 0
fi

# The sha branch protection checks is the PR head on the REMOTE, not local HEAD.
# On the empty-commit stamp path local HEAD is an un-pushed commit origin has
# never seen, so a status posted there 422s and never lands (gaia-react/gaia#726). Target the
# pushed PR head instead (mirrors CI, which posts on pull_request.head.sha).
#
# `gh` resolves BOTH the repository and the current branch from its working
# directory, so it runs anchored on $repo_root. Be precise about what that
# buys: $repo_root is itself a toplevel query against the ambient cwd, so this
# normalizes a run from a SUBDIRECTORY up to the checkout root. It cannot
# repoint the hook at a different tree, because the root it anchors on is
# derived from the cwd it already had. Choosing which tree this hook answers
# for is the caller's job, done by invoking the hook from that tree.
head_sha="$( cd "$repo_root" && gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || true )"
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

# The tree guard above cannot see an un-pushed GAIA-Audit trailer stamp, by
# construction: the stamp is content-preserving (an empty commit on the pushed
# path, an amend on the un-pushed one), so every blob stays byte-identical and
# local HEAD's tree equals the target sha's tree even while the stamp commit
# exists only locally. Require the COMMIT sha to match too. Without this the
# status posts on the PRE-STAMP head, the stamp is pushed afterwards, the PR
# head advances, and the success status is stranded on a sha no reader checks,
# so a required GAIA-Audit check waits forever. Push the stamp, then post.
# When no PR and no upstream resolve, head_sha IS local HEAD, so this guard
# does not fire on that path.
head_local="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
if [ "$head_local" != "$head_sha" ]; then
  emit_decline "stamp not pushed"
  exit 0
fi

# Member-aware gate (blocker COV-001): require EVERY dispatched Code Audit
# Team member's marker, not just the caller's own, before posting success.
# Otherwise a frontend-only POST on a mixed diff would flip the GAIA-Audit
# status green (and unlock the github.com merge button) while a co-dispatched
# maintainer member still withholds over an unresolved finding. An ABSENT or
# non-executable resolver falls back to the single-marker POST below, so a
# partial/early-resume tree is never bricked. Each member is keyed to its OWN
# digest (owned files + machinery), not the frontend digest or the tree; there
# is no carried provenance, so every dispatched member's clearance is earned.
#
# The resolver derives its own root from cwd, so it runs anchored on
# $repo_root, the acting tree it measures. A NON-ZERO exit is the third state
# and it takes neither of the other two paths: the resolver ran and could not
# answer, so the member set is unknown, and posting success on an unknown
# member set is the vacuous pass this gate exists to prevent. That arm
# declines.
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
    if [ -z "$member_digest" ] || ! clearance_member_cleared "$store_root" "$member_digest" "$m"; then
      pending="${pending}${pending:+ }${m}"
    fi
  done <<< "$members"

  if [ -n "$pending" ]; then
    emit_decline "members pending ${pending}"
    exit 0
  fi
fi

# Description (C3): three positional fields "<version> <frontend-digest>
# <tree>". Every dispatched member's clearance is earned (there is no
# carried provenance), so the shape is fixed: no branch, no CLI flag.
desc="${version} ${frontend_digest} ${tree_sha}"

# Anchored for the same reason as the `gh pr view` above, and with the same
# limits: a subdirectory normalization, not a cross-tree guarantee.
repo=$( cd "$repo_root" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true )
if [ -z "$repo" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

if gh api "repos/${repo}/statuses/${head_sha}" \
  --method POST \
  --field state=success \
  --field context=GAIA-Audit \
  --field description="${desc}" >/dev/null 2>&1; then
  # Surface the sha we POSTed to, head_sha, which the sha guard above has already
  # established IS local HEAD: nothing reaches this POST while the two name
  # different commits, so the surfaced sha and the POSTed sha are one commit.
  # Assert the surfaced short sha re-resolves to head_sha; on a mismatch surface
  # the full head_sha and warn.
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
