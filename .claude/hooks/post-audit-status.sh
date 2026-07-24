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
#   .claude/hooks/post-audit-status.sh [--root <path>] <marker-path>
#
#   --root <path>  The audited working root. Every git call, derived path, and
#                  gh invocation is scoped to it. Defaults to the ambient
#                  checkout, which is correct only when the caller reviewed
#                  that tree; a worktree dispatch must name the tree it read.
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
#          root not a directory
#          audited tree not on pushed head
#          members pending <list>
#          post failed
#   2 , Usage error (no marker path argument, an unknown option, or --root
#       with no value). Stderr.
#
# References
#   Audit-marker handshake: .claude/agents/code-audit-frontend.md "Audit marker (gate handshake)"
#   Dispatch resolver:      .gaia/scripts/resolve-audit-members.sh
#   Per-author resolver:    .gaia/scripts/read-audit-ci-config.sh
#   State-aware readers:    .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash).
#   - Resolves the repo root via git rev-parse and scopes every git call to it
#     with -C. The two gh calls are the exception: gh takes no root argument
#     and reads the repo and PR from its working directory, so they run inside
#     a subshell `cd "$repo_root"` whose effect cannot outlive the command
#     (per .claude/rules/shell-cwd.md, which bans a cd that leaks into the
#     caller's environment, not a contained one).
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

emit_posted() {
  printf 'status: posted GAIA-Audit success %s\n' "$1"
}

emit_decline() {
  printf 'status: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-audit-status: %s\n' "$1" >&2
}

# The audited working root. `--root` names it explicitly; every git call and
# derived path below is scoped to it. A dispatch against a linked worktree must
# pass it, because there the ambient cwd is the MAIN checkout, so a cwd-derived
# root resolves the wrong head, digest, and member set. Absent the flag the
# ambient checkout is the root, the ordinary single-checkout case.
root_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      # An EMPTY value errors rather than falling back to the cwd: a caller that
      # asked for an explicit root and silently got the ambient checkout is the
      # exact failure this flag exists to prevent.
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        emit_error "--root requires a path"
        exit 2
      fi
      root_arg="$2"
      shift 2
      ;;
    --root=*)
      root_arg="${1#--root=}"
      if [ -z "$root_arg" ]; then
        emit_error "--root requires a path"
        exit 2
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      emit_error "unknown option: $1"
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

marker="${1:-}"
if [ -z "$marker" ]; then
  emit_error "usage: post-audit-status.sh [--root <path>] <marker-path>"
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

if [ -n "$root_arg" ]; then
  if [ ! -d "$root_arg" ]; then
    emit_decline "root not a directory"
    exit 0
  fi
  repo_root=$(git -C "$root_arg" rev-parse --show-toplevel 2>/dev/null || true)
else
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
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
# never seen, so a status posted there 422s and never lands (#726). Target the
# pushed PR head instead (mirrors CI, which posts on pull_request.head.sha).
# Run gh from the audited root, not the ambient cwd: gh resolves both the repo
# and the PR from the working directory's remotes and current branch, so under
# worktree dispatch a cwd-run call reads whatever branch the main checkout
# happens to hold. The subshell keeps the directory change from leaking.
head_sha="$( (cd "$repo_root" && gh pr view --json headRefOid --jq .headRefOid) 2>/dev/null || true)"
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
# partial/early-resume tree is never bricked. Each member is keyed to its OWN
# digest (owned files + machinery), not the frontend digest or the tree; there
# is no carried provenance, so every dispatched member's clearance is earned.
resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
if [ -x "$resolver" ]; then
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

# Description (C3): three positional fields "<version> <frontend-digest>
# <tree>". Every dispatched member's clearance is earned (there is no
# carried provenance), so the shape is fixed: no branch, no CLI flag.
desc="${version} ${frontend_digest} ${tree_sha}"

repo=$( (cd "$repo_root" && gh repo view --json nameWithOwner --jq .nameWithOwner) 2>/dev/null || true)
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
