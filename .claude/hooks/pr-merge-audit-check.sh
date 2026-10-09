#!/bin/bash
# PreToolUse Bash hook: BLOCK `gh pr merge` until every dispatched Code Audit
# Team member has cleared HEAD. AND-aggregator: resolves the diff's dispatched
# member set (.gaia/scripts/resolve-audit-members.sh) and requires each
# member's own clearance, one cleared member can no longer satisfy the gate
# while a co-dispatched member withholds.
#
# Zero-match (the whole diff is out of audit scope) or the resolver script
# being absent both fall through to the LEGACY single-signal gate: the marker/
# marker/status/bypass logic below, unchanged, evaluated for
# code-audit-frontend alone. A non-empty dispatched set instead runs the
# member-aware gate further down: code-audit-frontend by the same signals,
# each SPECIALIZED member <m> by its own marker
# .gaia/local/audit/<digest>.<m>.ok (the sole clearance signal for maintainer
# members, which are local-only with no commit-status equivalent).
#
# Markers are keyed to each member's own BRANCH-OWN DIGEST: a sha256 over the
# branch's own patch against the PR's base branch, restricted to the paths that
# member owns plus the shared gate machinery (folding in the in-scope-but-
# ownerless paths for the default member) and bound to the branch. The recipe
# lives in .claude/hooks/lib/audit-branch-patch.sh and audit-digest.sh. A marker
# attests that a member audited the branch's own change to the paths its digest
# covers: a path outside that set rotates no member's digest, so every existing
# marker keeps validating with zero re-dispatch; a change to the branch's own
# patch on a path a member owns rotates only that member's digest; one on a
# gate-machinery path rotates every member's digest. Content the base branch
# brought in through a clean catch-up merge is not part of the branch's patch
# and rotates nothing.
#
# The base is the one GitHub reports, never a local ref: the gate reads the PR's
# base branch name from the PR record and that branch's current tip through
# `gh`, requires the tip locally and a unique merge base, and denies naming the
# one next step otherwise. It is derived only once a signal needs a digest, so a
# bypass PR makes no base lookup.
#
# code-audit-frontend / legacy-gate signals:
#
#   1. Local marker file at .gaia/local/audit/<frontend-digest>.ok, written by
#      the audit agent at the end of a clean local review.
#
#   2. GAIA-Audit GitHub commit status on HEAD with state: success, description
#      "<version> <frontend-digest> <tree>", when both version and digest
#      match (the tree field is data only, never compared). post-audit-status.sh
#      posts it off a member marker, which is what lets a clearance earned on
#      one machine satisfy this gate on another. A non-success status on the
#      same context and SHA is not a cleared signal even when its description
#      matches. Queried via `gh api` using GH_TOKEN or the ambient gh auth
#      session.
#
#   3. chore(deps) PR bypass: PR title matches `^chore\(deps(-dev)?\):` and the
#      PR's recorded file list is confined to a dependency manifest. The
#      /update-deps wrapper runs the full quality gate locally before
#      pushing, so the audit signal is implicit for this PR class, but only
#      for the manifest bump itself; a dep-bump PR carrying a migration edit
#      or a rebuilt bundle runs the normal gate.
#
#   4. Out-of-scope bypass (legacy gate only, a non-empty dispatched set means
#      an in-scope file exists so this never applies there): every file the PR
#      changes lives on a surface outside audit scope, wiki, instruction files
#      (.claude), .gaia metadata, prose docs, and root-level
#      markdown. Evaluated fail-closed: any in-scope path (frontend/app/, frontend/test/,
#      configs, .github/workflows/) makes the marker mandatory again. An
#      in-scope-but-ownerless path (a root Makefile, public/**) is folded into
#      the frontend member's digest input set, so a stale marker computed for a
#      prior digest never matches such a change either; this bypass and that
#      digest fold close the same band from two directions.
#
# Signals 1-3 prove an audit ran against this content (or that none is
# needed); signal 4 proves there is nothing in audit scope to review at all. A
# refusal artifact (.gaia/local/audit/<digest>[.<member>].refused) for a
# member's current digest is checked BEFORE any earned signal and is
# absolute: it denies regardless of a same-digest earned marker, for both
# code-audit-frontend and every specialized member.
#
# BYPASS STAMP. A pull request allowed through signal 3 or 4 has no member
# marker, so nothing else posts the GAIA-Audit status that branch protection
# waits on. On those allows, and only those, this gate posts it itself
# (.claude/hooks/lib/audit-bypass-stamp.sh) with the description
# `skipped: out of scope` or `skipped: chore(deps) manifest-only`, immediately
# before the allow. Signal 4 is evaluated on every legacy-gate run, ahead of
# the other signals, so a wiki-only pull request a still-valid marker would
# clear first gets its stamp too; a head that already carries a cleared
# GAIA-Audit status (signal 2) is left alone. Never on a deny, never for a pull
# request this gate did not itself classify as a bypass, and never when local
# HEAD is not the pull request's recorded head, since the status would then
# attest content nobody classified.
#
# FORK REFUSAL. A cross-repository pull request is denied outright, before any
# marker, digest, scope, or base-provenance check, and before anything the
# acting tree carries (its roster, its member resolver, its dependency
# predicate) is read or run: once a fork head is checked out, that tree is the
# fork's. When gh cannot say whether the pull request is a fork, the gate
# denies as well. .claude/hooks/lib/cross-repo-refusal.sh holds the check and
# the message.
#
# Without every dispatched member's clearance, the hook denies the gh pr merge
# call. To unblock:
#   1. Dispatch the audit-loop-unit agent on the current branch; it runs the
#      pending members (code-audit-frontend for the default member; the
#      specialized member named in the deny reason otherwise).
#   2. The unit addresses the findings, commits and pushes, and re-runs the
#      members on the new HEAD until each writes its marker.
#   3. Retry gh pr merge.
#
# See wiki/concepts/PR Merge Workflow.md for the full contract.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literal below satisfies, live in .claude/hooks/lib/jq-availability.sh.
# No errexit bracket around the source, unlike the armed hooks that run under
# `set -e`: this one deliberately does not, per the header above.
#
# This gate is the sharpest instance of the class: it denies `gh pr merge` until
# every dispatched audit member has cleared, so standing down on a missing
# interpreter cleared the merge silently.
#
# The literal is `gh`, read off this gate's own arming predicate
# (`gate_verb_fragment` below, `gh[[:space:]]+pr[[:space:]]+merge`): every call this
# gate binds invokes `gh`, so the ABSENCE of `gh` from the command proves the
# call sits outside the remit and it is allowed, exactly as a parsed non-merge
# is. Presence is not proof of membership -- an ordinary command carrying `gh`
# inside a word satisfies it too -- and that over-deny is the safe direction.
# What it cannot reach is a spelling the shell assembles (`g\h pr merge`), which
# the arm's own header already names as the accepted residual.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: pr-merge-audit-check.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the PR merge audit gate' "$input" tool_input 'gh'

# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: pr-merge-audit-check.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_hook_payload_read "$input" || exit 0

tool_name=$GAIA_HOOK_TOOL_NAME
[ "$tool_name" = "Bash" ] || exit 0

# Note: avoid naming this `command`, it would shadow bash's `command` builtin
# and make any later `command -v ...` calls in this script silently misbehave.
command_line=$GAIA_HOOK_COMMAND

# Arm the gate when this tool call carries a `gh pr merge`, through the shared
# arming decision (.claude/hooks/lib/verb-arming.sh): the same raw start/sep
# match this gate always paid, re-tested against a same-length view that masks
# a heredoc body proven to be data, plus the first-command tokenizer arm. See
# that library's own header for the full three-pass contract and what it does
# not close; residual 1 still applies at this site: a quoted string carrying a
# separator before the verb still arms the gate, fail-closed, with no safe
# narrowing.
#
# Loaded from this hook's OWN on-disk location, never cwd: the bats suites run
# this hook by absolute path from a sandbox cwd with no .claude/, so a
# cwd-relative source would miss the lib and flip the arming answer.
#
# This runs BEFORE arming, ahead of even knowing whether the tool call is a
# merge, so an unloadable library denies every Bash tool call here, not merge
# attempts alone, unlike the five-lib deny further down which only ever denies
# a merge once armed.
_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
_verb_arming_ok=0
if [ -n "$_hook_library_directory" ] && [ -f "$_hook_library_directory/verb-arming.sh" ]; then
  # shellcheck source=/dev/null
  if . "$_hook_library_directory/verb-arming.sh" && type gaia_verb_armed >/dev/null 2>&1; then
    _verb_arming_ok=1
  fi
fi
if [ "$_verb_arming_ok" -ne 1 ]; then
  jq -n --arg reason "PR merge gate: cannot load the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh must exist, be readable, and define gaia_verb_armed). This check runs before the gate knows whether the tool call is a gh pr merge at all, so it denies every Bash tool call rather than merge attempts alone. Restore .claude/hooks/lib/verb-arming.sh (it ships with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

gate_verb_fragment='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$gate_verb_fragment" 'gh pr merge' "$command_line"; then
  : # armed
else
  exit 0
fi

# Appended to every deny below. Only a start or first-command arm is the call's
# own invocation; a separator or opener arm is also what a merge cited inside a
# body or a commit message produces, so the deny must not claim one was run.
gate_arm_note=""
if [ "$GAIA_VERB_ARM_KIND" = sep ]; then
  gate_arm_note="

This gate armed on a \`gh pr merge\` that follows a separator or a substitution opener inside the command, not on the command's own first word, and it cannot tell a merge the shell runs from one only cited in text the command carries (a pull-request or issue body, a commit message). If this call runs no merge, pass that text from a file instead (\`--body-file\`, \`git commit -F\`), which the gate does not read; if it does run one, the steps above apply."
fi

# Repo-scope: this gate enforces the home repo's audit contract only. A
# `gh pr merge` aimed at a different repo (e.g. a sibling project merged via
# `cd ../other && gh pr merge` or `gh pr merge -R owner/other`) has no bearing
# on this repo's audit markers, allow it. Rooted at this hook's own on-disk
# location, reusing the value resolved for the arming load above, for exactly
# the reason the clearance load below states: a cwd-relative source misses the
# lib from any directory that has no `.claude/`, and the `type` check that
# follows reads that as a library the checkout does not carry.
[ -n "$_hook_library_directory" ] && [ -f "$_hook_library_directory/repo-scope.sh" ] && . "$_hook_library_directory/repo-scope.sh"
if type command_targets_foreign_repo >/dev/null 2>&1 \
   && command_targets_foreign_repo "$command_line"; then
  exit 0
fi

# Load the shared clearance reader from this hook's OWN on-disk location
# (never cwd, never $repo_root). The bats suites run this hook by absolute
# path from a sandbox cwd that has no .claude/, so a cwd-relative source would
# miss the lib and flip every clearance check. Loaded lazily here, after the
# early exits above, because this hook fires on every Bash tool call.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
if [ -n "$_library_directory" ] && [ -f "$_library_directory/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_library_directory/audit-clearance.sh"
fi

# Load the shared main-root resolver the same guarded way, from this hook's
# own on-disk location. Backs the main-anchored `root` derivation below.
_repository_root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [ -n "$_repository_root_directory" ] && [ -f "$_repository_root_directory/.gaia/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_repository_root_directory/.gaia/scripts/main-root-lib.sh"
fi

# Load the shared ownership classifier + machinery list + branch-own patch
# library + digest engine + base provenance resolver from the same on-disk
# location, together with the fork check and the bypass stamp.
# check_out_of_scope_pr() below depends on the classifier to know what a changed
# path is and on the provenance resolver to know what base it is reading a
# change set against, and every marker check below is keyed to a member's
# branch-own digest computed by the digest engine over the patch library; an
# absent or unreadable module means this gate cannot know what it is gating, so
# it denies rather than fall through to a degraded, uninformed gate. This is a
# deliberate fail-closed path distinct from every other guard in this hook
# (which fail OPEN on an unusable lookup).
#
# repo-scope.sh joined this list when the command-binding predicate stopped
# being a bypass relaxation and became a conjunct on EVERY clearance permit.
# Its absence makes gate_command_names_the_record_pr return 1 above the scanner
# run, which used to mean only "this relaxation does not fire" and now means
# every permit denies. Left out of this guard the denial surfaces through the
# binding's own spelling arm, which blames the command's spelling and closes by
# recommending the exact bare merge that just denied: the real cause is never
# named and no respelling reaches it. Naming the file here is what turns that
# into the same one early, honest denial its siblings already give.
#
# The fork check is on this list because a missing one must not read as "not a
# fork", and the stamp because a bypass allow without it leaves the pull
# request waiting forever on a status nothing posts.
_repo_scope_library="$_library_directory/audit-scope.sh"
_machinery_library="$_library_directory/audit-machinery.sh"
_digest_library="$_library_directory/audit-digest.sh"
_branch_patch_library="$_library_directory/audit-branch-patch.sh"
_version_library="$_library_directory/gaia-version.sh"
_provenance_library="$_library_directory/audit-base-provenance.sh"
_repo_scope_library="$_library_directory/repo-scope.sh"
_cross_repo_library="$_library_directory/cross-repo-refusal.sh"
_bypass_stamp_library="$_library_directory/audit-bypass-stamp.sh"
if [ -z "$_library_directory" ] || [ ! -f "$_repo_scope_library" ] || [ ! -f "$_machinery_library" ] || [ ! -f "$_digest_library" ] || [ ! -f "$_branch_patch_library" ] || [ ! -f "$_version_library" ] || [ ! -f "$_provenance_library" ] || [ ! -f "$_repo_scope_library" ] || [ ! -f "$_cross_repo_library" ] || [ ! -f "$_bypass_stamp_library" ]; then
  jq -n --arg reason "PR merge gate: cannot load the ownership classifier, the digest engine, the branch-own patch library, the version normalizer, the base provenance resolver, the command scanner, the fork check, or the bypass stamp (.claude/hooks/lib/audit-scope.sh, .claude/hooks/lib/audit-machinery.sh, .claude/hooks/lib/audit-digest.sh, .claude/hooks/lib/audit-branch-patch.sh, .claude/hooks/lib/gaia-version.sh, .claude/hooks/lib/audit-base-provenance.sh, .claude/hooks/lib/repo-scope.sh, .claude/hooks/lib/cross-repo-refusal.sh, and .claude/hooks/lib/audit-bypass-stamp.sh must all exist and be readable). Every marker check below is keyed to a member's branch-own digest and to a version literal this gate compares for equality against the stamped one; this gate's out-of-scope bypass depends on the classifier to know what a changed path is, and on the provenance resolver to know what base its change set is read against; every permit this gate issues is bound to the pull request the merge names, which it reads through the command scanner; a fork pull request is refused through the fork check; and a bypass allow posts its GAIA-Audit status through the stamp. So it denies rather than guess. Restore every file named above (they ship with the framework; a missing or corrupted checkout is the usual cause) and retry.${gate_arm_note}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi
# shellcheck source=/dev/null
. "$_repo_scope_library"
# shellcheck source=/dev/null
. "$_machinery_library"
# shellcheck source=/dev/null
. "$_branch_patch_library"
# shellcheck source=/dev/null
. "$_digest_library"
# shellcheck source=/dev/null
. "$_version_library"
# shellcheck source=/dev/null
. "$_provenance_library"
# shellcheck source=/dev/null
. "$_cross_repo_library"
# shellcheck source=/dev/null
. "$_bypass_stamp_library"

# Fork refusal, ahead of every read of the acting tree below: audit_scope_init
# reads its roster, the member resolver and the chore(deps) predicate run from
# it, and on a fork head all three are the fork's. The pull request asked about
# is the one the merge names when it names a bare number, and otherwise the
# current branch's, which is the only other pull request any permit below can
# clear (every permit binds to the record of the current branch).
_fork_check_reference=''
if type gaia_scan_gh_merge >/dev/null 2>&1 && gaia_scan_gh_merge "$command_line"; then
  case "${GAIA_GH_MERGE_REFERENCE:-}" in
    '' | *[!0-9]*) ;;
    *) _fork_check_reference="$GAIA_GH_MERGE_REFERENCE" ;;
  esac
fi
if _fork_deny_reason=$(gaia_cross_repo_deny_reason "$_fork_check_reference" '' \
  'PR merge gate: ' \
  "PR merge gate: cannot tell whether pull request ${_fork_check_reference:-for the current branch}" \
  "so it denies rather than risk merging one. Check gh (\`gh auth status\`, the network) and retry." \
  "$gate_arm_note"); then
  jq -n --arg reason "$_fork_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

# Resolve HEAD's TREE. This is now a plain DATA field (surfaced in deny
# messages only), never a validity key: every marker check below is keyed to
# a member's branch-own digest, derived on first need.
tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)

# TWO roots, because this gate spans two different questions and one root
# cannot answer both.
#
#   root       WHERE a clearance lives. Resolved to the MAIN checkout: every
#              marker clearance_member_cleared builds a path for is
#              main-anchored shared state (.gaia/state-registry.json
#              scope=shared, the symlinked audit/ store), not a property of
#              whichever tree this hook happens to run in. Sourced from this
#              hook's own on-disk location, matching the sibling lib-loads
#              above.
#   tree_root  WHAT a clearance attests to. The ACTING tree: the content
#              being merged is this tree's HEAD, not main's. Every writer
#              agrees -- the agent definitions pass
#              `--root "$(git rev-parse --show-toplevel)"` to
#              audit-write-clearance.sh, and resolve-audit-members.sh derives the same
#              way -- so digesting main's HEAD here would compare a marker against content
#              nobody is merging. From a linked worktree the two trees
#              differ, no marker could ever match, and the gate's own remedy
#              text ("re-spawn the agents") would rewrite the same
#              non-matching marker forever.
#
# Both fall back to a bare toplevel query, then pwd, when the resolver is
# unavailable or fails -- the same fail-open direction the original
# CWD-anchored derivation had.
root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  root="$(gaia_resolve_main_root 2>/dev/null)" || root=""
fi
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Parse the roster ONCE per run (never once per path); the classifier module
# was sourced above. audit_branch_digests_all re-inits the same state
# internally, so this call is redundant with it in effect but kept explicit:
# check_out_of_scope_pr() run before any digest-dependent path in a future edit
# would still find the roster parsed. A config with no auditors: roster fails
# here with its own named remedy, ahead of the digest deny below, whose text
# would otherwise blame a missing sha256 tool.
if ! audit_scope_init "$tree_root" 2>/dev/null; then
  jq -n --arg reason "PR merge gate: ${tree_root}/.gaia/audit-ci.yml has no auditors: roster, so no Code Audit Team member can be resolved or cleared for HEAD ${sha:0:12}. There is no fallback roster. Restore the auditors: block from the GAIA template's .gaia/audit-ci.yml, commit it, and retry.${gate_arm_note}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# gate_emit_deny <reason>: print the deny decision for <reason> and exit.
gate_emit_deny() {
  jq -n --arg reason "$1$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# The per-member digests, the frontend marker path and the frontend refusal are
# derived together, on first need, by gate_require_digests below. Nothing above
# the first signal that reads a digest touches the network, which is what keeps a
# bypass pull request (out of scope, chore(deps) manifest-only) from ever
# looking up the base.
_DIGEST_MEMBER=()
_DIGEST_VALUE=()
frontend_digest=""
marker=""
frontend_refused=0
refusal_note=""
gate_digests_resolved=""

# member_digest <member> -> that member's branch-own digest on stdout, exit 0;
# exit 1 (empty stdout) when the member is absent from the batch.
member_digest() {
  local want="$1" i=0
  while [ "$i" -lt "${#_DIGEST_MEMBER[@]}" ]; do
    if [ "${_DIGEST_MEMBER[$i]}" = "$want" ]; then
      printf '%s\n' "${_DIGEST_VALUE[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# gate_require_digests: derive, once per run, every roster member's branch-own
# digest against the base GitHub reports, or print the deny decision naming the
# one next step and exit. Call it directly, never inside a `$( )`, so the memo
# and the exit both act on the parent shell.
#
# The trusted base is the PR record's base branch name plus that branch's tip
# from the GitHub branches endpoint. It is never read from a local ref: a stale
# or forged `refs/remotes/origin/*` would otherwise decide what counts as the
# branch's own change. The tip must be present locally and HEAD must have exactly
# one merge base with it; each failure has its own next step.
gate_require_digests() {
  [ -z "$gate_digests_resolved" ] || return 0
  gate_digests_resolved=yes

  resolve_pr_record

  local gh_remedy="Check gh (\`gh auth status\`, the network) and retry gh pr merge."
  local base_error_file base_detail repository tip merge_base lookup_status=0 digest_batch stale_cache_fix

  if [ -z "$pr_record_base" ]; then
    gate_emit_deny "PR merge gate: cannot verify the base branch for HEAD ${sha:0:12}: gh returned no pull request record naming a base branch for the current branch. Markers are keyed to the branch's own change against the base branch GitHub reports, and this gate never substitutes a local ref for it, so it denies. ${gh_remedy}"
  fi

  stale_cache_fix="$(audit_stale_cached_base "$tree_root" "$pr_record_base")" || stale_cache_fix=""
  if [ -n "$stale_cache_fix" ]; then
    gate_emit_deny "PR merge gate: this branch's cached audit base differs from base branch ${pr_record_base} that GitHub reports (the pull request was retargeted), so markers written locally are keyed to a different base than this gate measures for HEAD ${sha:0:12}. Run \`${stale_cache_fix}\`, re-run the audit writers, and retry gh pr merge."
  fi

  base_error_file="$(mktemp "${TMPDIR:-/tmp}/gate-base.XXXXXX" 2>/dev/null)" || base_error_file=/dev/null
  repository="$(audit_github_repository "$tree_root" 2>"$base_error_file")" || lookup_status=$?
  if [ "$lookup_status" -eq 0 ]; then
    tip="$(audit_github_base_tip "$tree_root" "$repository" "$pr_record_base" 2>"$base_error_file")" || lookup_status=$?
  fi
  if [ "$lookup_status" -ne 0 ]; then
    base_detail="$(head -n 1 "$base_error_file" 2>/dev/null || true)"
    [ "$base_error_file" = /dev/null ] || rm -f "$base_error_file"
    gate_emit_deny "PR merge gate: cannot read the tip of base branch ${pr_record_base} from GitHub for HEAD ${sha:0:12}: ${base_detail:-gh failed}. Markers are keyed to the branch's own change against the base GitHub reports, and this gate never substitutes a local ref for it, so it denies. ${gh_remedy}"
  fi
  [ "$base_error_file" = /dev/null ] || rm -f "$base_error_file"

  merge_base="$(audit_branch_patch_merge_base "$tree_root" "$tip" 2>/dev/null)" || lookup_status=$?
  case "$lookup_status" in
    0) ;;
    4)
      gate_emit_deny "PR merge gate: the tip of base branch ${pr_record_base} that GitHub reports (${tip:0:12}) is not a commit in this checkout, so the branch's own change cannot be measured against it for HEAD ${sha:0:12}. Run \`git fetch origin\` and retry gh pr merge."
      ;;
    3)
      gate_emit_deny "PR merge gate: HEAD ${sha:0:12} has more than one merge base with the tip of base branch ${pr_record_base} (${tip:0:12}), so the branch's own change is ambiguous. Run \`git merge --no-edit refs/remotes/origin/${pr_record_base}\` to make the merge base unique, then retry gh pr merge."
      ;;
    *)
      gate_emit_deny "PR merge gate: cannot derive the merge base of HEAD ${sha:0:12} and the tip of base branch ${pr_record_base} (${tip:0:12}). This usually means a shallow or damaged checkout. Run \`git fetch origin\` and retry gh pr merge."
      ;;
  esac

  digest_batch="$(audit_branch_digests_all "$tree_root" "$merge_base" 2>/dev/null)" || digest_batch=""
  if [ -z "$digest_batch" ]; then
    gate_emit_deny "PR merge gate: cannot derive per-member branch-own digests for HEAD ${sha:0:12} (audit_branch_digests_all failed or returned nothing). This usually means a missing sha256 tool (sha256sum / shasum -a 256), a git failure, a detached HEAD with no branch name to bind the digest to, or a corrupted checkout. Every Code Audit Team marker is keyed to a member's digest, so this gate denies rather than match against an empty or partial one. Restore the missing tool or checkout and retry."
  fi

  # Parse the batch into parallel arrays (bash 3.2 has no associative arrays,
  # mirroring the digest engine's own convention).
  local digest_line
  while IFS= read -r digest_line; do
    [ -n "$digest_line" ] || continue
    _DIGEST_MEMBER[${#_DIGEST_MEMBER[@]}]="${digest_line%%$'\t'*}"
    _DIGEST_VALUE[${#_DIGEST_VALUE[@]}]="${digest_line#*$'\t'}"
  done <<EOF
$digest_batch
EOF

  frontend_digest="$(member_digest code-audit-frontend)" || frontend_digest=""
  marker="$root/.gaia/local/audit/${frontend_digest}.ok"

  # A refusal for the frontend's CURRENT digest is checked before any earned
  # signal and is absolute: denies regardless of a same-digest earned marker.
  if [ -n "$frontend_digest" ] && clearance_member_refused "$root" "$frontend_digest" code-audit-frontend; then
    frontend_refused=1
    refusal_note="
A live refusal exists for this exact branch-own digest: $(clearance_refused_path "$root" "$frontend_digest" code-audit-frontend). A refusal always takes precedence over any earned marker for the same digest, and a bare re-spawn does NOT clear it: an ordinary earned write leaves the refusal in place, so re-running the agent against an unchanged, still-unaddressed patch refuses again. Clear it by resolving the finding with an edit to the branch's own patch on that member's paths (that rotates the digest, retiring this refusal); a fix that arrives only through a catch-up merge of the base branch does not rotate it. Or, when the operator acknowledges an Important with a stated reason and the digest does not move, re-spawn code-audit-frontend so it writes its earned marker with --supersede-refusal \"<reason>\", which removes its own refusal as an explicit, recorded act.
"
  fi
}

# Human-readable state of a local marker file for a deny message. The gate now
# accepts only a writer-produced clearance, so a file that exists but is not
# writer-shaped is neither "cleared" nor "missing": name that third state so an
# operator staring at a present marker while the gate says "missing" is not
# left guessing.
marker_state() {
  if [ -f "$1" ]; then
    printf '(present but not a valid clearance; re-run the member'\''s agent)'
  else
    printf '(missing)'
  fi
}

# --- code-audit-frontend clearance signals -----------------------------------
#
# Each check is a self-contained function so frontend_cleared() below can
# reuse it from both the legacy gate and the member-aware gate.

# _gate_current_version -> the trimmed .gaia/VERSION literal on stdout, or
# empty. Read by check_github_status to compare a stamped version field.
_gate_current_version() {
  # Rooted at the acting tree, the way every sibling caller of this reader
  # already passes it. A bare literal reads empty from any working directory
  # below the repository root, and the status check then reports a version
  # mismatch against a status that is correct, which sends the operator to
  # re-audit content nothing is wrong with.
  gaia_read_version "$tree_root/.gaia/VERSION"
}

# GitHub commit status fallback: post-audit-status.sh stamps a GAIA-Audit
# commit status off a member marker, which carries a clearance earned on one
# machine to a merge run on another. Query the API for a matching status on
# HEAD. The status must be state: success; its description shape is
# "<version> <frontend-digest> <tree>", and version + digest must both
# match (the tree field is data only, never compared), so a bypass stamp
# (`skipped: ...`) never reads as cleared here. A non-success status is
# filtered out at the source, so a pending status carrying HEAD's
# version+digest is not treated as cleared. Falls through silently on any
# error (no gh, no token, no GITHUB_REPOSITORY, API failure), the deny path
# below fires as normal.
#
# With "any-digest" the status's digest field is not compared, which needs no
# branch-own digest and so no base lookup. Only the bypass stamp decision uses
# it: it asks whether the head already carries a cleared status, not whether
# that status clears this gate. A status recorded under another digest recipe
# does not clear the gate (the default form compares the digest) but still
# satisfies the status check branch protection waits on.
check_github_status() {
  local digest_mode="${1:-}"
  command -v gh >/dev/null 2>&1 || return 1

  # Derive repo slug. GITHUB_REPOSITORY is set inside Actions; derive from
  # the current directory's git remote for local runs via `gh repo view`
  # (avoids BSD-vs-GNU sed portability issues with lazy quantifiers).
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$repo" ] || return 1
    case "$repo" in
      */*) ;;  # must contain exactly one slash (owner/name)
      *) return 1 ;;
    esac
  fi

  # Read .gaia/VERSION (same "no stamp without VERSION" invariant as CI).
  current_version="$(_gate_current_version)"
  [ -n "$current_version" ] || return 1

  [ "$digest_mode" = any-digest ] || [ -n "$frontend_digest" ] || return 1

  status_description=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | select(.state == "success") | .description' \
    2>/dev/null || true)

  [ -n "$status_description" ] && [ "$status_description" != "null" ] || return 1

  status_version=$(printf '%s' "$status_description" | awk '{print $1}')
  status_digest=$(printf '%s' "$status_description" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_digest" ] || return 1
  [ "$status_version" = "$current_version" ] || return 1
  [ "$digest_mode" = any-digest ] || [ "$status_digest" = "$frontend_digest" ] || return 1

  return 0
}

# resolve_pr_record: read this pull request's record once into
# $pr_record_title, $pr_record_base, $pr_record_head, $pr_record_number and
# $pr_record_files. Memoized on $pr_record_read, which is what distinguishes
# "not read yet" from "read, and the answer was nothing".
#
# One read rather than one per field. `gh` carries no request timeout of its
# own, so a second round-trip is a second OS-length stall on a blackholed
# network, and the memo is what keeps every consumer to the first one. Every
# failure (no gh, no auth, no PR for this branch, network error) leaves every
# field empty and each consumer takes its own no-answer path.
#
# The consumers are the two record-based bypasses, the legacy deny reason, and
# gate_command_names_the_record_pr, which every permit reaches through
# gate_permit_binds_to_named_pr. That last one is the reason this read is no
# longer confined to the uncleared path: a permit issued off a purely local
# clearance still has to establish which pull request it is a permit FOR. See
# gate_permit_binds_to_named_pr for why that is worth a network read.
#
# Every field is initialized HERE, at parent level, and that placement is
# load-bearing rather than cosmetic. This script runs under `set -uo
# pipefail`, and this function returns early before reaching any jq assignment
# on its two most common paths: no `gh` on PATH, and a `gh` that answers with
# nothing. A reader that dereferences $pr_record_head after either of those
# returns would trip `set -u` and kill the hook outright, so the gate would emit
# no JSON at all exactly where it owes a deny. Initializing inside the function
# body would not fix that; the early returns sit above it.
pr_record_read=""
pr_record_title=""
pr_record_base=""
pr_record_head=""
pr_record_number=""
pr_record_files=""
resolve_pr_record() {
  [ -z "$pr_record_read" ] || return 0
  pr_record_read=yes

  command -v gh >/dev/null 2>&1 || return 0
  pr_record=$(gh pr view --json title,baseRefName,headRefOid,number,files 2>/dev/null || true)
  [ -n "$pr_record" ] || return 0

  # `// ""` so a JSON null reaches the callers as the same empty string an
  # absent record does; both are "no answer" and neither is a branch name nor a
  # commit sha. A record carrying no head sha (an older stub, a trimmed
  # response) therefore reads as no answer, which FAILS the record-bound
  # conjunction below rather than passing it by default.
  pr_record_title=$(printf '%s' "$pr_record" | jq -r '.title // ""' 2>/dev/null || true)
  pr_record_base=$(printf '%s' "$pr_record" | jq -r '.baseRefName // ""' 2>/dev/null || true)
  pr_record_head=$(printf '%s' "$pr_record" | jq -r '.headRefOid // ""' 2>/dev/null || true)
  pr_record_number=$(printf '%s' "$pr_record" | jq -r '.number // ""' 2>/dev/null || true)
  pr_record_files=$(printf '%s' "$pr_record" | jq -r '(.files // [])[] | .path // empty' 2>/dev/null || true)
}

# chore(deps) bypass: PRs whose title matches `^chore\(deps(-dev)?\):` AND
# whose recorded file list is confined to a dependency manifest are
# pre-verified by the /update-deps wrapper's local quality gate (typecheck +
# lint + vitest + playwright + build), so the audit-marker requirement is
# waived for this PR class. The predicate itself lives in one place,
# .gaia/scripts/chore-deps-skip.sh, shared with the CI workflows that skip
# the same pull requests. A dep-bump PR that also
# carries a non-manifest path (a migration edit, a rebuilt bundle) does not
# waive; it runs the normal member-aware gate below.
#
# The title and file list come from the shared PR-record read above. On any
# failure (no gh, no auth, no PR for the current branch, network error, an
# empty file list, or an unresolved repo root) the bypass does not fire and the
# normal deny path runs, the bypass is opt-in proof, not a fallback.
check_chore_deps_pr() {
  resolve_pr_record
  [ -n "$pr_record_title" ] || return 1
  # Bind the bypass to the pull request the COMMAND names. The title above came
  # from `gh pr view` with no number, so on its own it proves a property of the
  # CURRENT BRANCH's pull request while the merge being gated names one this
  # function never parsed: from a checkout sitting on a dep-bump branch, a merge
  # naming an arbitrary unaudited number cleared with no marker at all.
  # A command carrying no positional still permits,
  # since that is gh's current-branch default and therefore the very pull
  # request the title was read for, which is what leaves the turnkey
  # `gh pr merge --squash` dep-bump path unaffected.
  gate_command_names_the_record_pr || return 1
  # tree_root, not root: the predicate is executable code, so it comes from the
  # ACTING tree that carries it. root is the main checkout, which from a linked
  # worktree is a different branch entirely and need not have the script at all.
  [ -n "$tree_root" ] || return 1
  [ "$(bash "$tree_root/.gaia/scripts/chore-deps-skip.sh" "$pr_record_title" <<<"$pr_record_files")" = "true" ]
}

# gate_resolve_base: resolve, ONCE per run, the diff base that scopes this pull
# request's own changes, together with the provenance that says how much that
# base deserves to be trusted. Both bypasses below read $gate_trust,
# $gate_anchor and $gate_base and nothing else, so the two cannot drift.
#
# The resolution itself lives in the shared library
# (.claude/hooks/lib/audit-base-provenance.sh), the one place tree-wide that
# walks the supplied/record/default-branch ladder and the one definition of
# whether an empty range at a given trust level is decisive. This gate owns no
# copy of either, which is what keeps it from reaching a verdict the audit spawn
# oracle would contradict about the same base.
#
# Every git call runs against $tree_root, the ACTING tree resolved from cwd
# above. The derivation this replaced used a bare cwd-relative `git`; anchoring
# it makes explicit what was implicit, and matches the anchoring the member
# dispatch block below already uses.
#
# The supplied-base argument is ALWAYS the empty string, deliberately. No
# gate-side consumer accepts a base override and none may gain one: a
# caller-chosen base is a caller-chosen diff, and a fail-closed check whose diff
# the caller picks is not fail-closed. Do not add one here for symmetry with the
# dispatch resolver, which is a dispatch-side consumer answering a different
# question.
#
# The answer comes from the pull request record, never from the environment. An
# exported base-ref variable would let a caller shrink a fail-closed check's
# diff until every remaining path looked out of scope; a PR's base ref is the
# branch it actually merges into, so scoping to it concedes nothing that merging
# the PR would not already concede. The shared resolver reads no environment
# variable naming a base branch on any path, so that refusal survives the move
# into it intact.
#
# Both checks below scope their diff to a merge base, and the branch that merge
# base is taken against decides what "this PR changes" means. The remote's
# advertised default is that branch only when the PR targets it: a PR stacked on
# another branch merges into THAT branch, and diffing against the default hands
# the check the base branch's own history instead, denying a bypass the PR had
# earned.
#
# When the record's remote-tracking ref does not verify (no gh, no auth, no PR
# for this branch, network error, a base branch this checkout has never
# fetched), the resolver falls through to the advertised default and reports
# anchor `default-branch`. That is usually the wider diff but not always: a
# backport forked from current main and targeting an older maintenance branch
# merge-bases NEARER to HEAD against main than against its own base. It is the
# safe direction regardless, for a reason that does not rest on the geometry.
# Whatever the narrower answer drops sits on commits already merged to the
# default branch, which is where they were already audited.
#
# That fall-through describes the ref-does-not-verify case ONLY. A record ref
# that verifies but whose merge-base fails (unrelated histories, a shallow HEAD)
# does not fall through at all: the resolver answers `unresolvable` with an
# empty base, the guards below fire, and the gate denies. That is exactly the
# answer the derivation this replaced gave, and falling through there would hand
# this gate a resolved, wider base on a path where it previously refused
# outright.
#
# The memo is parent-level, and calling this function DIRECTLY (never inside a
# `$( )`) is what keeps it that way. The per-subshell memo it replaced existed
# only because both bypasses reached the base through a command substitution,
# which also made its two variables a coupled pair whose half-set state was the
# one combination that derivation existed to forbid. Both bypasses are invoked
# from the parent shell, so a direct call retires that hazard.
#
# Resolution stays LAZY, and this is the more expensive read of the two: on top
# of resolve_pr_record it derives the base's provenance and, in its callers,
# diffs the whole base-to-HEAD range. A cleared run now pays the record read
# (see gate_permit_binds_to_named_pr) but must not pay this one. Call it only
# from inside the two bypasses and the legacy deny reason, never at the top
# level of this script.
gate_provenance_read=""
gate_trust=""
gate_anchor=""
gate_base=""
gate_resolve_base() {
  [ -z "$gate_provenance_read" ] || return 0
  gate_provenance_read=yes

  resolve_pr_record

  local base_provenance
  base_provenance="$(audit_resolve_base_provenance "$tree_root" pr-record "" "$pr_record_base")" || base_provenance=""
  # An empty $base_provenance leaves all three fields empty, which every guard below reads
  # as unresolvable and fails closed on.
  IFS=$'\t' read -r gate_trust gate_anchor gate_base <<< "$base_provenance" || true
}

# gate_command_names_the_record_pr: is the pull request the gated `gh pr merge`
# names the same one whose record the conjuncts around this were checked
# against? The record comes from `gh pr view` with no number, which describes
# the CURRENT BRANCH's pull request, so without this the record conjuncts prove
# only "this checkout is on a pull request", never "on the one being merged".
#
# Everything this reads about the command comes from the shared scanner in
# repo-scope.sh, never from a parser written here, and that is the whole design
# rather than a convenience. Two hand-rolled readings were tried and both were
# wrong in the permitting direction. Skipping options by their leading `-`
# alone reads a value-taking flag's SEPARATED value as the positional, so
# `gh pr merge --body <record-number> <other-number>` compared equal to the
# record and permitted a merge of <other-number>; `gh pr merge` has six such
# flags. Counting occurrences of the literal `gh pr merge` phrase to prove no
# second merge rides along missed every spelling that breaks the literal run of
# characters, `gh pr "merge" <n>` and a line continuation inside the verb among
# them. Both were demonstrated against this hook rather than argued.
#
# The scanner tokenizes the way the shell does, so it answers two of the three
# questions exactly: which reference the merge names, and whether a separator
# or a comment put another command beside it. The third, whether an EXPANSION
# smuggled one in, is not a question about words, so no word-level tokenizer
# answers it; this function rules it out lexically instead, by admitting only
# the characters a merge invocation needs and denying every other byte. Every
# abstention denies.
gate_command_names_the_record_pr() {
  # The scanner is normally already loaded, from the repo-scope source near the
  # top of this hook. That source is cwd-relative, so it can miss from a
  # non-root cwd; reload from this hook's OWN on-disk location and deny if the
  # scanner still cannot be had. A relaxation that cannot read the command it
  # is relaxing has nothing to relax on.
  if ! type gaia_scan_gh_merge >/dev/null 2>&1; then
    [ -n "$_library_directory" ] && [ -f "$_library_directory/repo-scope.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$_library_directory/repo-scope.sh" || return 1
    type gaia_scan_gh_merge >/dev/null 2>&1 || return 1
  fi

  # Abstains unless the tool call's FIRST command is the merge and every flag
  # on it is a shape the scanner models.
  gaia_scan_gh_merge "$command_line" || return 1

  # And no SEPARATOR puts a second command beside it. The scanner sets this
  # while reading the same command the call above just read, so it is that
  # read's own answer rather than a second pass: 0 means no separator and no
  # comment closed the merge.
  #
  # The allowlist above subsumes this today, since every separator character is
  # outside its set, which means no mutation of this line alone can red a test
  # while that arm stands. It is kept anyway, and the reason is stated rather
  # than left to be rediscovered: the two conjuncts answer different questions,
  # one lexical and one structural, and a future widening of the character set
  # (to admit a quoted subject, say) must not silently take the separator
  # guarantee with it.
  [ "$GAIA_FIRST_COMMAND_CLOSED" -eq 0 ] || return 1

  # And no EXPANSION runs one either. That question is not about words, so the
  # flag above does not answer it: a substitution is ordinary word text to a
  # tokenizer that models words, which reaches the end of the string having
  # found no separator while the shell runs the payload first, before the
  # permitted merge.
  #
  # This is an ALLOWLIST rather than a list of substitution spellings, and the
  # difference is the whole point. Two attempts to name the dangerous spellings
  # were both incomplete, and the second was incomplete in a way nobody could
  # have enumerated their way out of: which text makes a shell run a command is
  # a property of the shell running this tool call and of its version, not of
  # any fixed set of sequences. zsh, this platform's default, has `=(...)`;
  # bash gained `${ ...; }` in 5.3; the next release adds whatever it adds. So
  # the character set below is what a pull-request reference, a flag and a
  # branch or URL need, and every other byte denies, including `$`, a backtick,
  # every bracket, both quotes, and every separator. It cannot be outrun by a
  # spelling nobody has thought of, because it never asks what the spelling
  # means.
  #
  # Blunt in the deny direction only: a merge carrying a quoted subject denies
  # and costs a marker requirement, which is this arm's whole downside.
  case "$command_line" in
    *[!A-Za-z0-9_\ /.,:@=+-]*) return 1 ;;
  esac

  # No positional at all: the command targets the current branch, which is the
  # branch the record was read for, so the record conjuncts already bind it.
  [ -n "$GAIA_GH_MERGE_REFERENCE" ] || return 0
  # A bare number is the only spelling this gate can confirm without a second
  # network read. A branch name or a URL denies rather than resolve one: this
  # arm is a relaxation, so an unconfirmable target must not clear it.
  case "$GAIA_GH_MERGE_REFERENCE" in
    *[!0-9]*) return 1 ;;
  esac
  # The record is needed from HERE DOWN and nowhere above it, so resolve it at
  # the point of first need rather than leaning on a caller having done it.
  # Two things follow, and both are the point. The predicate is self-sufficient,
  # so a new call site cannot forget the read and get a permanent "no record"
  # answer that reads as a deny for a structural reason rather than a real one.
  # And the read stays LAZY where laziness is worth something: every return
  # above this line, a command naming no pull request and one naming a target
  # this gate cannot confirm among them, answers from the command's own bytes
  # and never reaches the network. The memo inside resolve_pr_record makes this
  # free for the callers that already made the read.
  resolve_pr_record
  [ -n "$pr_record_number" ] || return 1
  [ "$GAIA_GH_MERGE_REFERENCE" = "$pr_record_number" ]
}

# gate_permit_binds_to_named_pr: the last conjunct on every permit this gate
# issues off a CLEARANCE signal, as opposed to off the pull-request record.
#
# A clearance proves a property of THIS CHECKOUT's content: a member's own
# branch-own digest marker, a GAIA-Audit commit
# status on HEAD's sha. Not one of them reads the pull-request reference the
# gated command carries, so on a branch whose dispatched members have all
# cleared, `gh pr merge <other-number>` used to be permitted and merged a pull
# request nothing here audited.
#
# It sits at the two PERMIT SITES rather than inside the three signals, and
# that placement is what makes it complete rather than merely correct. A
# clearance becomes a merge at exactly two places, the legacy single-signal
# gate and the AND-aggregator, and every route through both, the frontend
# signals and each specialized member's own marker alike, passes through one of
# them. Binding the three signals individually would leave the specialized
# members' markers reachable and unbound, and closing that would take more code
# than this does, not less. The record-based bypasses each keep their own call:
# they need the answer to decide whether they fire at all, this needs it to
# decide whether a decision to permit may stand, and the memo makes the second
# ask free.
#
# WHAT IT COSTS, since the comment this replaces treated the cost as decisive.
# The predicate reaches the network through resolve_pr_record, which the
# clearance path otherwise never does. That read is now lazy to the point of
# first need, so a merge naming no pull request still decides entirely from
# local files; the prescribed `gh pr merge <N>` spelling does name one and pays
# one memoized `gh pr view`. The reason that is affordable is that the command
# being gated is itself an unbounded network round-trip: a permit issued
# network-free is a permit for an operation that immediately makes its own
# network calls, so keeping this path local moves a stall a few milliseconds
# later rather than avoiding one. The read is unbounded exactly as every other
# `gh` read in this hook is; bounding this one alone would buy nothing while
# the merge it clears stays unbounded.
#
# Prints the deny JSON and returns 1 when the binding does not hold; returns 0
# silently when it does.
gate_permit_binds_to_named_pr() {
  gate_command_names_the_record_pr && return 0

  local named record reason
  # Four of the predicate's five failure arms return ABOVE its own record read,
  # so reaching here says nothing about whether the record was ever queried.
  # Without this call the reason below would print an unread empty field as a
  # resolved negative, telling an operator whose pull request is perfectly
  # healthy that this checkout has no record: they go chase gh auth instead of
  # the command spelling that actually denied. resolve_pr_record memoizes, and
  # this is a deny path, so the read costs nothing the refused merge would not
  # have cost anyway, and it buys a reason that can name the real number.
  resolve_pr_record
  named="${GAIA_GH_MERGE_REFERENCE:-}"
  record="${pr_record_number:-}"

  local unreadable=0
  if [ -z "$named" ]; then
    # No positional means gh's current-branch default, which the conjunct above
    # permits outright, so reaching here without one means the command itself
    # was unreadable: not the first command in its tool call, carrying a flag
    # shape the scanner declines to model, a separator or comment putting a
    # second command beside it, or a byte outside the small set a merge needs.
    unreadable=1
    named="<unreadable>"
  fi

  # The predicate abstains for two materially different reasons and one message
  # cannot serve both. When the reference the command names IS the record's,
  # the target was never the problem: the gate could not read the command
  # exactly, so it abstained above the comparison. Telling that operator the
  # merge "does not name the pull request that clearance is for" is false, and
  # the repair that wording prescribes, name the record's number, is the exact
  # command that just denied. Split the headline and the remedy; the closing
  # paragraphs are true of both arms and stay shared.
  #
  # The spelling arm is the one reached in practice. A quoted `--subject` or
  # `--body` is an ordinary thing to type, while naming another pull request by
  # number is the rare case, so the message must not be written for the rare
  # one alone.
  local spelling_shared
  spelling_shared="The merge must be the first command in its tool call with nothing beside it,
and a separator, a comment, a flag shape the command scanner declines to model,
a branch name or URL in place of a number, or any byte outside the small set a
merge invocation needs each deny on their own. A quoted flag value is the common
case: drop it, or set it on the pull request before merging."

  # Which arm, and the sentinel belongs on the SPELLING side. An unreadable
  # command named no target the gate could read, so it never established a
  # wrong one; telling that operator the merge "does not name the pull request
  # that clearance is for" points at a target that was probably right, and the
  # mismatch remedy then offers them the no-number spelling they may have just
  # used. `<unreadable>` never equals a record, so keying on the comparison
  # alone would silently route it to the mismatch arm.
  local head_line names_line repair_lead
  if [ "$unreadable" -eq 1 ] || { [ -n "$record" ] && [ "$named" = "$record" ]; }; then
    if [ "$unreadable" -eq 1 ]; then
      head_line="PR merge gate: HEAD ${sha:0:12} is cleared, but this gate cannot read the merge command well enough to tell which pull request it targets."
      names_line="  Merge names:      no target this gate could read"
      repair_lead="To unblock, respell the merge. The target was never established, so this says
nothing about which pull request you meant."
    else
      head_line="PR merge gate: HEAD ${sha:0:12} is cleared and the merge names the right pull request (${record}), but the command is not one this gate can read exactly."
      names_line="  Merge names:      ${named}, which is this checkout's own pull request"
      repair_lead="To unblock, respell the merge; naming ${record} again is the one repair that
cannot work, because the number was never the problem."
    fi

    reason="${head_line}

  Clearance:        present for this checkout's content
${names_line}
  Blocked by:       how the command is spelled, not what it targets

This gate confirms a merge names the pull request its clearance is for by
reading the command itself, and it denies on every abstention rather than read
a command approximately. It abstained here, so it never reached the comparison
that would have passed.

${repair_lead} ${spelling_shared}
A bare \`gh pr merge --squash --delete-branch\`, with no number and no other
flag, is always readable and targets this checkout's own pull request."
  else
    reason="PR merge gate: HEAD ${sha:0:12} is cleared, but the merge does not name the pull request that clearance is for.

  Clearance:        present for this checkout's content
  Merge names:      ${named}
  This checkout is on: ${record:-<no pull-request record>}

Every clearance signal, a member's branch-own digest marker and the GAIA-Audit
commit status, proves that a member read THIS
CHECKOUT's content. None of them says anything about another pull request, so
merging one on their strength would merge a pull request nothing here audited.

To unblock:
  1. Merge the pull request this checkout is actually on: run
     \`gh pr merge --squash --delete-branch\` with no number, or name
     ${record:-the pull request for this branch} explicitly.
  2. To merge a different pull request, check that branch out and let its own
     Code Audit Team members clear it.

The spelling has to be one this gate can read exactly. ${spelling_shared}"
  fi

  reason="${reason}

This denial is UNCONDITIONAL and no clearance lifts it. Re-spawning the Code
Audit Team rewrites the same markers for the same unrotated digest and this
command denies identically; the repair is to respell the merge, never to obtain
another clearance.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  return 1
}

# gate_empty_is_decisive: may an EMPTY base-to-HEAD range clear this gate on its
# own? Five conjuncts, and the last four are why this is a named predicate
# rather than a bare call to the shared trust check.
#
# The trust conjunct is the shared library's, never a local copy: an empty range
# means "nothing left to audit" only when the base it was taken against is one
# this checkout could not have invented.
#
# The other four bind the relaxation to the pull-request record AND to the
# command being gated. This gate scopes its range to LOCAL HEAD, so without
# them a checkout sitting on a synced default branch, where `merge-base HEAD
# refs/remotes/origin/<default>` IS HEAD so the range holds zero files on remote
# provenance, would clear `gh pr merge <N>` for an arbitrary, entirely unaudited
# pull request. Requiring a `pr-record` anchor means the base was actually taken
# against the pull request's own recorded base branch; requiring HEAD to equal
# the record's head sha means this checkout is on the pull request the RECORD
# describes; and requiring the command's own reference to match the record's
# number means that pull request is the one being merged. On a synced default
# branch there is no pull request for the current branch, the record is empty,
# the anchor is `default-branch`, and this returns 1.
#
# The last conjunct reads the command through the shared scanner and denies on
# every abstention, so what it proves is bounded to the shapes that scanner
# reads exactly: the merge is the first command in the tool call, it carries no
# flag shape the scanner declines to model, no separator or comment puts a
# second command beside it, and every byte of it is in the small set a merge
# invocation needs, so no expansion of any spelling can run a second command.
# Anything else denies rather than being read approximately.
#
# The command-binding conjunct is NOT scoped to this arm, and it now IS a
# whole-gate invariant: no path through this gate clears a merge without
# establishing that the merge names the pull request the clearance is for. The
# arms that clear off the current-branch RECORD each ask at their own site, the
# chore(deps) bypass above and both arms of this function's own caller, because
# each needs the answer to decide whether it fires at all; keep it that way when
# adding a record-based arm, since they reach that record by different routes.
# The arms that clear off a
# CLEARANCE instead ask once, at the permit site, through
# gate_permit_binds_to_named_pr above; that function owns the reasoning for why
# the question sits there and what the network read costs.
gate_empty_is_decisive() {
  audit_provenance_empty_is_decisive "$gate_trust" || return 1
  [ "$gate_anchor" = "pr-record" ] || return 1
  [ -n "$pr_record_head" ] || return 1
  [ "$pr_record_head" = "$sha" ] || return 1
  gate_command_names_the_record_pr || return 1
  return 0
}

# Out-of-scope bypass: accept the merge when every file this PR changes lives
# on a surface outside audit scope. The agent has no rules that apply to wiki,
# instruction files, .gaia metadata, or prose, so there is nothing to audit and
# no marker is required. The allowlist itself lives in the
# shared classifier (audit_out_of_scope_allowlisted), the ONE place this
# literal set is defined.
# Legacy-gate only: the member roster's auditable-base set mirrors this check's complement, so
# any in-scope path here also dispatches a member, a non-empty dispatched set
# never reaches this function.
#
# Strict allowlist, evaluated fail-closed: the diff base must resolve, the diff
# must be non-empty OR its emptiness must be decisive under
# gate_empty_is_decisive above, and EVERY path must be out of scope. Any
# unresolved base, diff error, or in-scope path (frontend/app/, frontend/test/, configs,
# .github/workflows/) falls through to the normal deny. A PR that touches
# auditable source therefore can never reach this bypass, it cannot mask an
# audit that withheld its marker over unresolved findings, since that PR's diff
# carries in-scope paths by definition; and a decisive empty range says the
# merge introduces no content into its base at all, so there is nothing for a
# withheld marker to have been withheld over. No dependence on a CI stamp; the
# one network read is the base branch behind gate_resolve_base() above, whose
# failure widens the diff.
check_out_of_scope_pr() {
  # The merge base scopes the diff to THIS PR's changes, not unrelated drift
  # already on the base branch.
  gate_resolve_base
  [ -n "$gate_base" ] || return 1

  # Newline-delimited, derived NUL-delimited so git's default core.quotePath
  # cannot C-quote a non-ASCII path into a form the classifier below reads as an
  # unrecognized string. A non-zero return is a diff that never ran, which is
  # never an empty change set, so it denies here rather than reaching the
  # emptiness arm below.
  changed="$(audit_provenance_changed_files "$tree_root" "$gate_base")" || return 1

  if [ -z "$changed" ]; then
    # A REAL empty change set. Whether it clears this gate is the record-bound
    # question above, not this function's to answer: a locally-derived base, an
    # unresolvable one, or a checkout that is not on the pull request being
    # merged all deny here.
    gate_empty_is_decisive || return 1
    # The permit itself stays a silent zero exit with empty stdout, the shape
    # every other permit in this hook has. The reason is a diagnostic line on
    # stderr, not a permissionDecision emission: an explicit allow would
    # short-circuit the permission system for every `gh pr merge` this gate
    # sees, which is a far larger concession than the one being made here.
    echo "PR merge gate: no Code Audit Team marker required for HEAD ${sha:0:12}: the base-to-HEAD range is empty and the base carries ${gate_trust} provenance (anchor ${gate_anchor}, base ${gate_base:0:12})." >&2
    return 0
  fi

  # First path the shared classifier does not allowlist makes the marker
  # mandatory.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    audit_out_of_scope_allowlisted "$path" || return 1
  done <<< "$changed"

  # Bind to the pull request the COMMAND names, for the reason the chore(deps)
  # bypass above gives: every path checked so far belongs to the CURRENT
  # BRANCH's change set, which need not be the change set of the pull request
  # being merged. Placed here rather than at the top of this function on
  # purpose: the empty-change-set arm above routes through
  # gate_empty_is_decisive, which owns a strictly larger conjunct set including
  # this one, so hoisting would duplicate that call and blur which arm answers
  # for which conjuncts.
  gate_command_names_the_record_pr || return 1

  return 0
}

# code-audit-frontend clearance: the chore(deps) waiver first, since it needs no
# digest; then, with the digests derived, a live refusal for the current digest
# (absolute, ahead of every earned signal), then the marker, then the GitHub
# status. The waiver therefore outranks a refusal: honoring one needs the digest,
# hence the GitHub base lookup, which a manifest-only bump never makes. Reused by
# both the legacy gate and the member-aware gate below.
# Records which signal cleared in $frontend_cleared_by, because only the
# chore(deps) arm earns a bypass stamp.
frontend_cleared_by=""
frontend_cleared() {
  frontend_cleared_by=""
  # The chore(deps) waiver reads no digest, so it is asked first: a manifest-only
  # dependency bump never reaches the base lookup the digest signals below make.
  if check_chore_deps_pr; then
    frontend_cleared_by=chore-deps
    return 0
  fi
  gate_require_digests
  [ "$frontend_refused" -eq 1 ] && return 1
  if clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend; then
    frontend_cleared_by=marker
    return 0
  fi
  if github_status_cleared; then
    frontend_cleared_by=github-status
    return 0
  fi
  return 1
}

# github_status_cleared [any-digest]: check_github_status, asked at most once
# per run and form. The stamp decision asks the any-digest form, which needs no
# digest, so a bypass pull request never derives one.
github_status_answer=""
github_status_any_digest_answer=""
github_status_cleared() {
  if [ "${1:-}" = any-digest ]; then
    if [ -z "$github_status_any_digest_answer" ]; then
      github_status_any_digest_answer=no
      check_github_status any-digest && github_status_any_digest_answer=yes
    fi
    [ "$github_status_any_digest_answer" = yes ]
    return
  fi
  if [ -z "$github_status_answer" ]; then
    github_status_answer=no
    check_github_status && github_status_answer=yes
  fi
  [ "$github_status_answer" = yes ]
}

# gate_post_bypass_stamp <description>: post the GAIA-Audit bypass status for
# the pull request this run classified. Every caller has already established,
# through gate_command_names_the_record_pr, that the merge names the record's pull
# request, so the record's number is the one to stamp. The record's head must
# also be local HEAD, the content the classification read; otherwise the
# status would attest a head nobody classified, so it is skipped with the
# manual command instead. The POST goes to that verified sha ($sha), never to a
# second read of the pull request head, which a push could have moved.
gate_post_bypass_stamp() {
  local description="$1"
  resolve_pr_record
  if [ -z "$pr_record_number" ] || [ "$pr_record_head" != "$sha" ]; then
    printf 'GAIA-Audit bypass status not posted: pull request %s records head %s, not local HEAD %s, so this gate did not classify the head GitHub would mark. Push the branch and retry the merge, or post it by hand once the head is the classified one: gh api -X POST repos/{owner}/{repo}/statuses/<sha> -f state=success -f context=GAIA-Audit -f description='"'"'%s'"'"'\n' \
      "${pr_record_number:-<unknown>}" "${pr_record_head:-<unknown>}" "$sha" "$description" >&2
    return 0
  fi
  audit_post_bypass_status "$pr_record_number" "$sha" "$description"
}

# --- Dispatch: resolve the Code Audit Team member set for this diff ---------
#
# Anchored on $tree_root, the ACTING tree: who must clear is a property of the
# content being merged. $root stays main-anchored, via gaia_resolve_main_root,
# for WHERE a clearance lives; the two roots answer different questions and
# neither substitutes for the other. Anchoring here never collapses that split,
# because it only pins the acting-tree half harder. Both the existence test and
# the invocation are anchored, since a cwd-relative path reports the resolver
# absent from any directory that is not the checkout root. The `cd` lives
# inside a command substitution, so it never persists into the rest of the hook
# chain (.claude/rules/shell-cwd.md).
#
# The exit status is captured separately from the output. Non-zero means the
# resolver could not answer, which is never "nothing owed": folding it into the
# empty-set branch below hands the legacy single-signal gate a diff whose
# dispatched members are unknown.
members=""
resolver_exit_status=0
if [ -x "${tree_root}/.gaia/scripts/resolve-audit-members.sh" ]; then
  members="$( cd "$tree_root" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null )" \
    || resolver_exit_status=$?
fi

if [ "$resolver_exit_status" -ne 0 ]; then
  reason="PR merge gate: the Code Audit Team member resolver cannot answer for HEAD ${sha:0:12}.

.gaia/scripts/resolve-audit-members.sh exited ${resolver_exit_status} for the tree at
${tree_root}, so which members this diff dispatches is unknown. An unanswerable
member query is not an empty member set, and this gate denies rather than fall
back to the single-signal path and clear a diff a required auditor may never
have read.

To unblock:
  1. Run \`bash .gaia/scripts/resolve-audit-members.sh\` from the tree above and
     read its stderr; it names what it could not resolve.
  2. Fix what it names (an unreadable or non-checkout root, a broken git).
  3. Retry gh pr merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'

  exit 0
fi

if [ -z "$members" ]; then
  # Zero-match (entire diff out of scope) OR the resolver script is
  # absent/unusable: fall through to the legacy single-signal gate verbatim.
  # NOT an unconditional allow, the member roster's auditable-base set is strictly narrower
  # than check_out_of_scope_pr's denylist, so an ownerless-but-in-scope file
  # (root Makefile, public/**, ...) still denies here without a marker.
  #
  # The out-of-scope classification runs FIRST, ahead of every clearance
  # signal, because the bypass stamp depends on it whichever signal allows: a
  # wiki-only pull request cut from audited content still validates the old
  # marker (a path outside every member's set rotates no digest), so a gate that let the
  # marker answer first would allow it and never post the status branch
  # protection waits on. The price is the base resolution and diff on a run a
  # marker would have cleared without them.
  #
  # Neither bypass reads a branch-own digest, so both are decided before
  # gate_require_digests and its GitHub base lookup. Every path that sets
  # out_of_scope_pr has already bound the merge to the record's pull request
  # (check_out_of_scope_pr ends on that conjunct, and the empty-range arm routes
  # through gate_empty_is_decisive), so no permit-binding check follows here.
  out_of_scope_pr=0
  check_out_of_scope_pr && out_of_scope_pr=1

  if [ "$out_of_scope_pr" -eq 1 ]; then
    github_status_cleared any-digest || gate_post_bypass_stamp 'skipped: out of scope'
    exit 0
  fi

  if frontend_cleared; then
    gate_permit_binds_to_named_pr || exit 0
    if [ "$frontend_cleared_by" = chore-deps ]; then
      gate_post_bypass_stamp 'skipped: chore(deps) manifest-only'
    fi
    exit 0
  fi

  gate_require_digests

  # check_out_of_scope_pr above already populated the memo on every path that
  # reaches here; call it again anyway so the signal list below can never report
  # an empty provenance for a structural reason rather than a real one. The memo
  # makes the second call free.
  gate_resolve_base
  base_display="unresolved"
  [ -z "$gate_base" ] || base_display="${gate_base:0:12}"

  reason="PR merge gate: no code-audit-frontend signal for HEAD ${sha:0:12}.
${refusal_note}
None of the accepted signals is present:
  - Local marker:    ${marker} $(marker_state "$marker")
  - GitHub status:   absent or version/digest mismatch
  - chore(deps) PR:  PR title does not match \`chore(deps):\`/\`chore(deps-dev):\`, or the PR changes a path other than a dependency manifest
  - Out-of-scope:    PR changes at least one in-scope path (frontend/app/, frontend/test/, configs,
                     .github/workflows/), not a wiki/docs/.gaia-config-only diff
  - Diff base:       ${gate_trust:-unresolvable} provenance (anchor ${gate_anchor:-default-branch}, base ${base_display}); an empty
                     base-to-HEAD range clears this gate only on remote or supplied
                     provenance, with a pr-record anchor and HEAD at the pull
                     request's recorded head sha

To unblock:
  1. Dispatch the audit-loop-unit agent on HEAD
     (wiki/concepts/PR Merge Workflow.md, ## Dispatch the audit loop unit);
     it runs code-audit-frontend and fixes the findings.
  2. Let it push the fixes and write the marker on the new HEAD.
  3. Retry gh pr merge.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: bash .gaia/scripts/pr-wait-merge.sh --pr <N>
(it prints MERGED), do NOT retry the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  # --arg safely escapes $reason; never interpolate dynamic values directly into
  # the JSON template string.
  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'

  exit 0
fi

# --- AND-aggregator: require every dispatched member's clearance ------------
#
# A non-empty dispatched set means at least one changed file is owned by a
# Code Audit Team member. Every dispatched member must clear:
# code-audit-frontend via frontend_cleared() above, each specialized member
# <m> via its own marker .gaia/local/audit/<digest>.<m>.ok, keyed to that
# member's OWN branch-own digest. A live refusal for a member's current digest
# is checked before its earned marker and is absolute.

all_cleared=1
report=""
# Set when the chore(deps) waiver, not an earned signal, cleared
# code-audit-frontend: the one member-aware allow that earns a bypass stamp.
frontend_chore_deps_waived=0

while IFS= read -r roster_member; do
  [ -n "$roster_member" ] || continue

  member_cleared=0
  if [ "$roster_member" = "code-audit-frontend" ]; then
    if frontend_cleared; then
      member_cleared=1
      [ "$frontend_cleared_by" != chore-deps ] || frontend_chore_deps_waived=1
    fi
    member_content_digest="$frontend_digest"
    member_refused="$frontend_refused"
  else
    gate_require_digests
    member_content_digest="$(member_digest "$roster_member")" || member_content_digest=""
    member_refused=0
    if [ -n "$member_content_digest" ] && clearance_member_refused "$root" "$member_content_digest" "$roster_member"; then
      member_refused=1
    fi
    if [ "$member_refused" -eq 0 ] && [ -n "$member_content_digest" ]; then
      clearance_member_cleared "$root" "$member_content_digest" "$roster_member" && member_cleared=1
    fi
  fi

  if [ "$member_cleared" -eq 1 ]; then
    report="${report}  - ${roster_member}: CLEARED
"
  else
    all_cleared=0
    if [ "$member_refused" -eq 1 ]; then
      refused_path="$(clearance_refused_path "$root" "$member_content_digest" "$roster_member")"
      report="${report}  - ${roster_member}: REFUSED (a live refusal exists for this exact branch-own digest at ${refused_path}; a bare re-spawn does not clear it, the member must supersede it, see below)
"
    elif [ "$roster_member" = "code-audit-frontend" ]; then
      report="${report}  - code-audit-frontend: PENDING
      Local marker:    ${marker} $(marker_state "$marker")
      GitHub status:   absent or version/digest mismatch
      chore(deps) PR:  PR title does not match \`chore(deps):\`/\`chore(deps-dev):\`, or the PR changes a path other than a dependency manifest
"
    else
      member_marker="$root/.gaia/local/audit/${member_content_digest:-<unavailable>}.${roster_member}.ok"
      report="${report}  - ${roster_member}: PENDING (marker ${member_marker} $(marker_state "$member_marker"))
"
    fi
  fi
done <<< "$members"

if [ "$all_cleared" -eq 1 ]; then
  gate_permit_binds_to_named_pr || exit 0
  [ "$frontend_chore_deps_waived" -eq 0 ] || gate_post_bypass_stamp 'skipped: chore(deps) manifest-only'
  exit 0
fi

gate_require_digests

reason="PR merge gate: not every dispatched Code Audit Team member has cleared HEAD ${sha:0:12} (tree ${tree:0:12}).

${report}
To unblock: run the audit loop unit on HEAD (dispatch the audit-loop-unit agent per
wiki/concepts/PR Merge Workflow.md, ## Dispatch the audit loop unit) so each PENDING member
writes its marker (code-audit-frontend writes ${root}/.gaia/local/audit/${frontend_digest}.ok; each
specialized member writes ${root}/.gaia/local/audit/<its-own-digest>.<member>.ok, NOT
the frontend digest), then retry gh pr merge. Markers are keyed to each
member's own branch-own digest (the branch's own patch on the paths it owns plus
the shared gate machinery), so a path outside that set, or content the base
branch brought in through a catch-up merge, never invalidates one.

A REFUSED member is not a PENDING one: its refusal outranks any earned marker
for the same digest, and an ordinary re-spawn does not clear it (a plain
earned write leaves the refusal on disk). Resolve the finding with an edit to
the branch's own patch on that member's paths, which rotates its digest and
retires the refusal with it (a fix that arrives only through a catch-up merge of
the base branch does not rotate it); or, when the operator acknowledges an
Important with a stated reason and the digest does not move,
re-spawn the member so it writes its earned marker with
--supersede-refusal \"<reason>\", removing its own refusal as an explicit,
recorded act.

LOCAL-SYNC FAILURE NOTE: if a previous gh pr merge exited with
'fatal: main is already used by worktree at <path>', the GitHub-side merge
already succeeded. Verify with: bash .gaia/scripts/pr-wait-merge.sh --pr <N>
(it prints MERGED), do NOT retry the merge.

See wiki/concepts/PR Merge Workflow.md for the full contract."

jq -n --arg reason "$reason$gate_arm_note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'

exit 0
