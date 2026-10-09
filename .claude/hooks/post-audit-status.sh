#!/usr/bin/env bash
# post-audit-status.sh, post the GAIA-Audit commit status on HEAD.
#
# Purpose
#   Two callers, on the local (Claude-driven merge) path, neither of them a
#   Code Audit Team member's own agent: a clean pass no longer posts its own
#   success here (see wiki/concepts/PR Merge Workflow.md, "Posting the status
#   last"). The orchestrating session calls this, once, after every dispatched
#   member holds an earned marker for the current tree and every finding from
#   every round is fixed or recorded, passing any one current member's own
#   marker path. Posts a GAIA-Audit commit status of state=success on HEAD, but
#   only once EVERY member dispatched against HEAD's diff has cleared, so the
#   server-side required-check gate is satisfied, letting the github.com
#   button and the required-check verification clear. The passed marker file is a literal precondition
#   for the call; the member-aware gate below is the precondition for the
#   POST itself.
#
#   The second caller is the shared clearance writer itself
#   (.gaia/scripts/audit-write-clearance.sh), which makes this call the moment
#   it records a REFUSAL, on the local path, with no orchestrator step needed.
#   Handed a REFUSAL it posts state=failure and skips the member-aware gate.
#   That arm is what gives refusal precedence a server-side signal: the local
#   merge hook honors a refusal over any same-digest earned marker, but
#   GitHub's auto-merge merges on the required status alone and never runs that
#   hook, so without a compensating post a refusal written after a success
#   status already landed for this head (the orchestrator's own earlier post)
#   leaves that success standing. The writer making this call itself
#   is what makes the signal a mechanism rather than a step anyone has to
#   remember.
#
#   Honest limit: the pushed-head guards below apply to both states, so a
#   refusal written against work that is not what the pull request head carries
#   declines rather than posting. That is the fail-safe direction (the local
#   gate still denies the merge, and an un-audited pushed head carries no
#   success to retract), and it keeps this hook from ever posting about content
#   the caller did not audit.
#
# Invocation
#   .claude/hooks/post-audit-status.sh <marker-path>
#
#   <marker-path>  A clearance artifact on disk for the current tree
#                  (.gaia/local/audit/<digest>.ok for code-audit-frontend,
#                  .gaia/local/audit/<digest>.<member>.ok for a specialized
#                  member, <digest> the member's own 64-hex branch-own digest;
#                  the same two names with a .refused extension for a refusal).
#                  Its existence gates this call. On the success path the
#                  orchestrator passes any one current member's own marker
#                  path, since the member-aware gate below resolves the rest
#                  of the roster itself; on the refusal path the clearance
#                  writer passes the refusal it just wrote.
#
# Behavior
#   Best-effort and fail-safe-asymmetric: when gh is absent or unauthenticated,
#   or, on the SUCCESS arm, when a dispatched member other than the caller
#   hasn't cleared yet, the POST is skipped (the button stays blocked) but the
#   clearance the caller already wrote is untouched. A SUCCESS status is never
#   posted without every dispatched member's marker present and none of them
#   holding a live refusal, save a code-audit-frontend marker the chore(deps)
#   manifest-only waiver excuses (a frontend refusal is never excused), and an
#   absent status never inverts into a cleared gate. The caller may hand in
#   any one current member's own marker path;
#   the member-aware gate below evaluates the whole roster regardless of
#   which member's marker was passed, so the call is order-independent with
#   respect to the roster even though there is now exactly one caller (the
#   orchestrator) rather than one call per member.
#
#   The REFUSAL arm skips the member-aware gate by design (see Purpose above),
#   so none of the roster conditions above bound it. Re-arming that gate here
#   would be a regression rather than a tightening: it would withhold the
#   retraction on exactly the state the retraction exists for, since a refusal
#   is itself the reason the roster is not clear.
#
#   Order-independence rests on the DIGEST key. Markers are named for the
#   member's own branch-own digest, not its commit sha, so a commit that leaves
#   the branch's own patch unchanged (an empty commit, or a clean catch-up
#   merge of the base) rotates no member's digest and does not orphan a
#   sibling member's marker. Keyed to the commit, such a commit would
#   invalidate every marker written before it, and the member that finished
#   last would find the others' markers gone and decline forever. The POST
#   itself still targets the commit sha: a GitHub commit status has nowhere
#   else to land.
#
#   The SUCCESS arm measures that digest against a trusted base: the PR's base
#   branch name and its current tip come from GitHub through gh, the tip must
#   exist locally, and the branch must have a unique merge base with it. A base
#   that cannot be verified declines, naming the one next step, rather than
#   falling back to a local ref the branch could have forged. The REFUSAL arm
#   never verifies the base: a refusal must always be able to retract an
#   earlier success, and it names the digest its caller already holds.
#
# Exit codes
#   0 , Posted successfully OR declined (precondition failed). One stdout
#        marker line is always emitted; the audit caller surfaces it. Lines:
#          status: posted GAIA-Audit success <short-sha>
#          status: posted GAIA-Audit failure <short-sha>
#        Decline lines (prefix "status: declined: "):
#          marker absent
#          marker not a valid clearance
#          gh absent
#          gh unauthenticated
#          version file missing
#          version normalizer unavailable (lib/gaia-version.sh)
#          version file empty
#          frontend digest unavailable
#          branch patch library unavailable (lib/audit-branch-patch.sh)
#          trusted base unverified, <gh failure line>; next step: gh auth status
#          trusted base unverified, the base tip is not present locally; next
#            step: git fetch origin
#          trusted base unverified, more than one merge base with the base
#            branch; next step: git merge --no-edit refs/remotes/origin/<base>
#          trusted base unverified, no unique merge base could be derived
#          clearance reader unavailable
#          caller holds a live refusal
#          repo slug unresolved
#          audited tree not on pushed head
#          stamp not pushed
#          member resolver could not answer
#          members pending <list>
#          post failed
#   1 , The status posted but the draft flip did not (see Draft flip). One
#        stderr line names the manual `gh pr ready` command; the status is
#        never rolled back.
#   2 , Usage error (no marker path argument). Stderr.
#
# Draft flip
#   Pull requests open as drafts. Once a status has posted, this hook flips the
#   draft: `gh pr ready` after a success, `gh pr ready --undo` after a failure
#   (a refusal converts the pull request back to draft). The flip always comes
#   second, so a reviewer is notified only after the status that justifies it
#   exists. A success flips only a pull request that is a draft, and an undo
#   GitHub refuses because the repository does not support drafts is not a
#   failure: the refusal status already landed. It targets the pull request of the current branch, the same one the
#   `gh pr view` below resolves the head sha from, and is skipped when that read
#   found no pull request.
#
# References
#   Audit-marker handshake: .claude/agents/code-audit-*.md members via .claude/hooks/lib/audit-member-protocol.md "Gate handshake (per-member marker)"
#   Dispatch resolver:      .gaia/scripts/resolve-audit-members.sh
#   State-aware readers:    .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash).
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves the repo root via
#     git rev-parse and uses repo-relative paths from there.
#   - The success description "<version> <frontend-digest> <tree-sha>" (three
#     positional fields; field 2 is the digest) matches what every
#     state-aware GAIA-Audit reader accepts as cleared, and state=success
#     distinguishes it from a pending status.
#     The refusal description carries neither shape, for the same reason.

set -euo pipefail

# Load the shared clearance reader + digest engine from this hook's OWN
# on-disk location (never cwd, never $repo_root), per the frozen library
# resolution basis.
# Bracketed in `set +e` because errexit is armed above: a module that is present
# but unparseable abandons the shell AT the load, so an `-f` test ahead of it
# proves nothing and no caller can guard it from outside -- `bash -n` does not
# recurse into what a file sources. What degrades once the shell survives is
# each consumer below on its own terms: the digest and version readers gate on
# `type` / `command -v`, while `clearance_acceptable` is called bare inside an
# `if` condition, where a 127 is errexit-exempt and falls through to the same
# decline an unreadable marker takes -- correct, but noisier, since it prints a
# `command not found` beside a decline whose message blames the marker.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || true
set +e
if [ -n "$_library_directory" ]; then
  # shellcheck source=/dev/null
  [ -f "$_library_directory/audit-clearance.sh" ] && . "$_library_directory/audit-clearance.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_library_directory/audit-branch-patch.sh" ] && . "$_library_directory/audit-branch-patch.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_library_directory/audit-base-provenance.sh" ] && . "$_library_directory/audit-base-provenance.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_library_directory/audit-digest.sh" ] && . "$_library_directory/audit-digest.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_library_directory/gaia-version.sh" ] && . "$_library_directory/gaia-version.sh" 2>/dev/null
fi
set -e

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `repo_root` derivation below.
_repository_root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || true
set +e
# shellcheck source=/dev/null
[ -n "$_repository_root_directory" ] && [ -f "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" ] \
  && . "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" 2>/dev/null
set -e

emit_posted() {
  printf 'status: posted GAIA-Audit success %s\n' "$1"
}

emit_posted_failure() {
  printf 'status: posted GAIA-Audit failure %s\n' "$1"
}

emit_decline() {
  printf 'status: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-audit-status: %s\n' "$1" >&2
}

# digest_for_member <member>: the member's digest out of branch_digest_lines
# (`<member>\t<digest>` per line), or nothing when the member is not listed.
digest_for_member() {
  local line
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$1" ]; then
      printf '%s' "${line#*$'\t'}"
      return 0
    fi
  done <<<"$branch_digest_lines"
  return 0
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
# Two modes, decided by the artifact named at the marker path, and nothing
# else is a clearance. An EARNED marker posts success, gated below on every
# dispatched member having cleared. A REFUSAL posts failure, and skips that
# gate: the refusal IS the member's answer, so waiting for a roster to clear
# before reporting it would be waiting for the condition it contradicts.
#
# The failure post exists because the local merge hook is not the only merge
# path. GitHub's auto-merge consults the required GAIA-Audit status alone and
# never reaches the hook that honors refusal precedence, so a refusal written
# after a success status already landed for this head (the orchestrator's own
# earlier post) would leave that success standing and the pull
# request merging over a live refusal. Posting failure for the same head
# retracts it; the latest status for a context wins, and a later success post
# once the orchestrator's own preconditions are met again overwrites this in
# turn, so a refusal can never strand a pull request it no longer applies to.
post_state=""
if clearance_acceptable "$marker" "$marker_member" "$marker_digest"; then
  post_state="success"
elif command -v clearance_refusal_acceptable >/dev/null 2>&1 \
     && clearance_refusal_acceptable "$marker" "$marker_member" "$marker_digest"; then
  post_state="failure"
else
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
#               stamps into the status description, the branch-own digests it
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

# The version, the trusted base and the digests are inputs to the SUCCESS
# description and to the member-aware gate, and the refusal arm reads none of
# them: its description is built from the caller's own member and digest, and it
# skips the gate. So these preconditions are scoped to the success arm rather
# than applied to both. Declining a refusal over a field it never reads, or over
# a base it never measures against, would be the wrong direction: it withholds a
# retraction while the stale success it exists to retract stands.
version=""
frontend_digest=""
branch_digest_lines=""
if [ "$post_state" = "success" ]; then
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

  # Fail closed when any function the trusted-base derivation needs is missing:
  # a partial library set must decline, never fall through to a weaker base.
  if ! command -v audit_branch_patch_merge_base >/dev/null 2>&1 \
     || ! command -v audit_github_repository >/dev/null 2>&1 \
     || ! command -v audit_github_pr_base_branch >/dev/null 2>&1 \
     || ! command -v audit_github_base_tip >/dev/null 2>&1 \
     || ! command -v audit_branch_digests_all >/dev/null 2>&1; then
    emit_decline "branch patch library unavailable (lib/audit-branch-patch.sh)"
    exit 0
  fi

  # The trusted base comes from GitHub, never from a local ref. On a failure a
  # library call prints nothing on stdout and one line on stderr, so the
  # captured text is a message only when the call failed.
  base_failure=""
  base_repository=""
  base_tip=""
  base_branch="$(audit_github_pr_base_branch "$repo_root" 2>&1)" || base_failure="$base_branch"
  if [ -z "$base_failure" ]; then
    base_repository="$(audit_github_repository "$repo_root" 2>&1)" || base_failure="$base_repository"
  fi
  if [ -z "$base_failure" ]; then
    base_tip="$(audit_github_base_tip "$repo_root" "$base_repository" "$base_branch" 2>&1)" || base_failure="$base_tip"
  fi
  if [ -n "$base_failure" ]; then
    emit_decline "trusted base unverified, ${base_failure}; next step: gh auth status"
    exit 0
  fi

  merge_base_status=0
  merge_base="$(audit_branch_patch_merge_base "$repo_root" "$base_tip" HEAD 2>/dev/null)" || merge_base_status=$?
  case "$merge_base_status" in
    0) ;;
    4)
      emit_decline "trusted base unverified, the base tip is not present locally; next step: git fetch origin"
      exit 0
      ;;
    3)
      emit_decline "trusted base unverified, more than one merge base with the base branch; next step: git merge --no-edit refs/remotes/origin/${base_branch}"
      exit 0
      ;;
    *)
      emit_decline "trusted base unverified, no unique merge base could be derived"
      exit 0
      ;;
  esac

  # Every member's digest in one pass, so one identities listing serves the
  # frontend digest below and the member-aware gate. Fail closed: never post a
  # status without a real digest.
  branch_digest_lines="$(audit_branch_digests_all "$repo_root" "$merge_base" 2>/dev/null || true)"
  frontend_digest="$(digest_for_member code-audit-frontend)"
  if [ -z "$frontend_digest" ]; then
    emit_decline "frontend digest unavailable"
    exit 0
  fi
fi

# The sha branch protection checks is the PR head on the REMOTE, not local HEAD.
# When local HEAD is an un-pushed commit origin has never seen, a status posted
# there 422s and never lands. Target the pushed PR head instead (the same sha a pull_request event reports as head.sha).
#
# `gh` resolves BOTH the repository and the current branch from its working
# directory, so it runs anchored on $repo_root. Be precise about what that
# buys: $repo_root is itself a toplevel query against the ambient cwd, so this
# normalizes a run from a SUBDIRECTORY up to the checkout root. It cannot
# repoint the hook at a different tree, because the root it anchors on is
# derived from the cwd it already had. Choosing which tree this hook answers
# for is the caller's job, done by invoking the hook from that tree.
#
# The same read carries the pull request's title, on a second line, and its
# file list on the lines after that, for the chore(deps) waiver in the
# member-aware gate below. GitHub titles are single line, so the first two
# newlines are an unambiguous split.
pr_view="$( cd "$repo_root" && gh pr view --json headRefOid,title,files --jq '.headRefOid, .title, (.files[]?.path)' 2>/dev/null || true )"
head_sha="${pr_view%%$'\n'*}"
pr_title=""
pr_files=""
case "$pr_view" in
  *$'\n'*)
    pr_view_rest="${pr_view#*$'\n'}"
    pr_title="${pr_view_rest%%$'\n'*}"
    case "$pr_view_rest" in
      *$'\n'*) pr_files="${pr_view_rest#*$'\n'}" ;;
    esac
    ;;
esac
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
# is not on the remote head yet (un-pushed tree-changing work)
# and posting would falsely clear a stale head. Decline instead.
target_tree="$(git -C "$repo_root" rev-parse "${head_sha}^{tree}" 2>/dev/null || true)"
if [ -z "$target_tree" ] || [ "$target_tree" != "$tree_sha" ]; then
  emit_decline "audited tree not on pushed head"
  exit 0
fi

# The tree guard above cannot see an un-pushed content-preserving commit
# (an empty commit): every blob stays byte-identical and local HEAD's tree
# equals the target sha's tree even while that commit exists only locally.
# Require the COMMIT sha to match too. Without this the status posts on the
# older head, the commit is pushed afterwards, the PR head advances, and the
# success status is stranded on a sha no reader checks, so a required
# GAIA-Audit check waits forever. head_sha here is the live PR head read
# fresh from `gh`. When no PR and no upstream resolve, head_sha IS local
# HEAD, so this guard does not fire on that path.
head_local="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
if [ "$head_local" != "$head_sha" ]; then
  emit_decline "stamp not pushed"
  exit 0
fi

# Member-aware gate: require EVERY dispatched Code Audit
# Team member's marker, not just the caller's own, before posting success.
# Otherwise a frontend-only POST on a mixed diff would flip the GAIA-Audit
# status green (and unlock the github.com merge button) while a co-dispatched
# maintainer member still withholds over an unresolved finding. An ABSENT or
# non-executable resolver falls back to the single-marker POST below, so a
# partial/early-resume tree is never bricked. Each member is keyed to its OWN
# branch-own digest, not the frontend digest or the tree; there
# is no carried provenance, so every dispatched member's clearance is earned.
#
# The resolver derives its own root from cwd, so it runs anchored on
# $repo_root, the acting tree it measures. A NON-ZERO exit is the third state
# and it takes neither of the other two paths: the resolver ran and could not
# answer, so the member set is unknown, and posting success on an unknown
# member set is the vacuous pass this gate exists to prevent. That arm
# declines.
# The refusal reader is required for BOTH checks below, probed once here rather
# than per member and OUTSIDE the resolver branch. A clearance lib carrying
# clearance_member_cleared without clearance_member_refused makes a refusal call
# exit 127, and the surrounding `||` chain consumes that as "not refused",
# reverting the gate to cleared-only and posting success on a head where a
# member holds a live refusal. That is the one degradation direction this gate
# must never take, so an unavailable reader declines instead of falling open.
# The earned reader's own probe sits at the marker-mode branch above, where
# absence degrades to a decline on its own.
if [ "$post_state" = "success" ] && ! command -v clearance_member_refused >/dev/null 2>&1; then
  emit_decline "clearance reader unavailable"
  exit 0
fi

# The CALLER'S OWN refusal, checked without the roster. An earned write never
# clears a same-digest refusal (only --supersede-refusal does, as an explicit
# recorded act), so a member that refused this digest and was then re-run with a
# plain earned write holds BOTH artifacts. The member-aware gate below catches
# that for every dispatched member, but it is armed only when the resolver is
# executable, and the no-resolver fallback posts on the caller's marker alone.
# Left to that fallback this hook retracts the failure the refusal writer
# posted, and auto-merge completes over a live refusal, which is the whole
# incident the refusal arm exists to prevent. The caller's own member and digest
# are already in hand, so this needs nothing the roster provides.
if [ "$post_state" = "success" ] \
   && clearance_member_refused "$store_root" "$marker_digest" "$marker_member"; then
  emit_decline "caller holds a live refusal"
  exit 0
fi

# The chore(deps) waiver: a dep-bump pull
# request whose recorded file list is confined to a dependency manifest waives
# code-audit-frontend, through the same predicate the merge hook
# already reads, so a co-dispatched member's earned marker completes the
# handshake. It waives the missing frontend marker only and sits after the
# loop's refusal read, so a frontend refusal stays pending under a dep-bump
# title. Fail-closed: no pull request, an unreadable title, an empty or
# non-manifest file list, or an absent predicate leave frontend pending. No
# extra tree binding is needed here: the pushed-head guards above (target_tree
# == tree_sha, head_local == head_sha) already proved local HEAD equals this
# same read's headRefOid before this point, so the file list already describes
# exactly the tree being posted about.
frontend_waived="false"
chore_deps_predicate="${repo_root}/.gaia/scripts/chore-deps-skip.sh"
if [ -n "$pr_title" ] && [ -f "$chore_deps_predicate" ] \
   && [ "$(bash "$chore_deps_predicate" "$pr_title" <<<"$pr_files" 2>/dev/null || true)" = "true" ]; then
  frontend_waived="true"
fi

resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
if [ "$post_state" = "success" ] && [ -x "$resolver" ]; then
  resolver_exit_status=0
  members="$( cd "$repo_root" && bash "$resolver" 2>/dev/null )" || resolver_exit_status=$?
  if [ "$resolver_exit_status" -ne 0 ]; then
    emit_decline "member resolver could not answer"
    exit 0
  fi

  pending=""
  while IFS= read -r roster_member; do
    [ -n "$roster_member" ] || continue
    member_digest="$(digest_for_member "$roster_member")"
    # Refusal-first, mirroring the merge hook's own precedence
    # (pr-merge-audit-check.sh's member loop). A member that cleared a digest in
    # one wave and refused the SAME digest in a later one holds both artifacts,
    # because the writer publishes a refusal beside an earned marker rather than
    # replacing it. Read cleared alone and that member counts as cleared, so the
    # next member's earned handshake posts success on the same head and
    # latest-status-wins retracts the failure the refusal just posted. The local
    # gate would still deny, which is the divergence: the two readers must agree
    # about one state, and the gate's answer is the one that governs.
    if [ -z "$member_digest" ] \
       || clearance_member_refused "$store_root" "$member_digest" "$roster_member"; then
      pending="${pending}${pending:+ }${roster_member}"
    elif ! clearance_member_cleared "$store_root" "$member_digest" "$roster_member" \
         && { [ "$roster_member" != "code-audit-frontend" ] || [ "$frontend_waived" != "true" ]; }; then
      pending="${pending}${pending:+ }${roster_member}"
    fi
  done <<< "$members"

  if [ -n "$pending" ]; then
    emit_decline "members pending ${pending}"
    exit 0
  fi
fi

# Description: three positional fields "<version> <frontend-digest>
# <tree>". Every dispatched member's clearance is earned (there is no
# carried provenance), so the shape is fixed: no branch, no CLI flag.
#
# The refusal description deliberately does NOT carry that cleared shape (its
# field 1 is a fixed word that can never be a version, field 2 a member name
# that can never be a 64-hex digest), so it cannot pass for a cleared status:
# defense in depth behind the state-aware readers, which already reject any
# non-success state. It names the refusing member and the exact branch-own
# digest, which is what an operator needs to find the artifact on disk.
if [ "$post_state" = "failure" ]; then
  status_description="refused by ${marker_member} ${marker_digest}"
else
  status_description="${version} ${frontend_digest} ${tree_sha}"
fi

# Anchored for the same reason as the `gh pr view` above, and with the same
# limits: a subdirectory normalization, not a cross-tree guarantee.
repo=$( cd "$repo_root" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true )
if [ -z "$repo" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

if gh api "repos/${repo}/statuses/${head_sha}" \
  --method POST \
  --field state="${post_state}" \
  --field context=GAIA-Audit \
  --field description="${status_description}" >/dev/null 2>&1; then
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
  if [ "$post_state" = "failure" ]; then
    emit_posted_failure "$posted_short"
  else
    emit_posted "$posted_short"
  fi
  # Draft flip, strictly after the status (see the header). `gh pr ready`
  # resolves the pull request from the current branch exactly as the head read
  # above did, so it needs no number; with no pull request resolved there is
  # nothing to flip.
  if [ -n "$pr_view" ]; then
    flip_undo=""
    flip_manual="gh pr ready"
    if [ "$post_state" = "failure" ]; then
      flip_undo="--undo"
      flip_manual="gh pr ready --undo"
    fi
    # A success flips only a draft: a pull request opened ready (a private
    # repository where GitHub refuses drafts) has nothing to flip, and an
    # unreadable draft state falls through to the flip so a failure is reported.
    flip_needed=1
    if [ "$post_state" != "failure" ]; then
      pr_is_draft="$( cd "$repo_root" && gh pr view --json isDraft --jq .isDraft 2>/dev/null </dev/null || true )"
      [ "$pr_is_draft" != "false" ] || flip_needed=0
    fi
    if [ "$flip_needed" = 1 ]; then
      flip_output=""
      if ! flip_output="$( cd "$repo_root" && gh pr ready ${flip_undo:+"$flip_undo"} 2>&1 </dev/null )"; then
        # A refusal on a repository that does not support drafts has no draft
        # to restore; its failure status already landed, so that is not a
        # failed flip.
        if [ "$post_state" = "failure" ] && grep -qiE 'draft.*(not supported|unsupported)|(not supported|unsupported).*draft' <<<"$flip_output"; then
          exit 0
        fi
        emit_error "the GAIA-Audit ${post_state} status posted but the draft flip failed; run it by hand: ${flip_manual}"
        exit 1
      fi
    fi
  fi
  exit 0
fi

emit_decline "post failed"
exit 0
