#!/usr/bin/env bash
# PreToolUse Bash hook on `gh pr merge`: the deterministic caller for
# post-findings-block.sh. Under local audit mode no code path posted the
# machine-readable findings block, only a hand-run snippet did, so a local
# merge contributed nothing to the finding-recurrence tally. This hook closes
# that gap: on a real `gh pr merge` invocation whose resolved audit mode is
# `local`, it resolves the incremental audit base and calls the existing
# producer. Pure side effect: it never blocks the merge and never emits a
# permission decision.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Shared arming decision; see .claude/hooks/lib/verb-arming.sh. A quoted verb
# inside prose still arms here, fail-closed, with no safe narrowing.
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && [ -f "$_va_lib/verb-arming.sh" ] && . "$_va_lib/verb-arming.sh"
type gaia_verb_armed >/dev/null 2>&1 || exit 0

frag='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$frag" 'gh pr merge' "$cmd"; then
  :
else
  exit 0
fi

# `gh pr merge` aimed at a different repo has no bearing on this repo's audit
# posting; allow it.
#
# This hook ACTS on the home repository, it posts a findings block onto a pull
# request, so it takes repo-scope's act-on-home entry point rather than the
# blocking one. The blocking guard compares only the repo-NAME half of a
# `--repo` value against the checkout's directory basename, which reads a
# same-named fork (`--repo other-org/gaia` run from a checkout named `gaia`,
# the ordinary fork topology) as home; this hook would then resolve THIS
# repository's pull request of that number and post onto a pull request the
# command never touched. The act-on-home entry point compares the whole
# HOST/OWNER/REPO, and it reads the merge with the lib's first-command scan, so
# every ambiguity resolves to "foreign" and declines rather than acts. The cost
# is that a merge run behind any earlier command in the same tool call posts
# nothing; the merge workflow runs the merge as its own step, and the
# alternative is a prefix nobody can read exactly, whose misreads all land on a
# post onto a pull request in a repository the merge never named.
#
# Sourced from this hook's own on-disk location, never cwd. A cwd-relative
# source misses from any non-root cwd, and a `type f >/dev/null 2>&1 && f`
# guard then falls THROUGH to posting rather than bailing: the two compose
# into no boundary check at all. Undefined after the source exits instead.
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_lib:-}" ] && [ -f "$_lib/repo-scope.sh" ] && . "$_lib/repo-scope.sh"
type cmd_targets_foreign_repo_slug >/dev/null 2>&1 || exit 0
type gaia_gh_merge_ref_to_home_pr >/dev/null 2>&1 || exit 0
if cmd_targets_foreign_repo_slug "$cmd"; then
  exit 0
fi

# Resolve the pull request the merge names, from the scan the boundary check
# above already ran rather than from a pattern over the raw command text. A
# regex takes its FIRST match anywhere in the string, and it only matches a
# number sitting immediately after the verb, so a merge spelling its flags
# first (`gh pr merge --squash 1515`) does not match at the merge and a later
# mention of another one (`&& echo "see gh pr merge 1520"`) supplies the number
# instead. Posting this merge's findings block onto that other pull request is
# the same "a pattern cannot tell which command a token belongs to" failure the
# boundary check three lines above exists to close, and the scan already holds
# the answer.
#
# gh accepts a number, a URL, or a branch name as the selector, and the three
# carry different boundaries, so each gets its own arm rather than one lookup
# standing in for all of them. The post always lands HERE, on the repository
# resolved from this hook's own cwd, while gh resolves a URL against the
# repository the URL names and a branch name against whatever pull request that
# branch has, so a value gh resolves is not by itself a value this hook may act
# on.
#
# The URL arm is the one the boundary check above cannot cover: a URL carries
# no `-R`/`--repo`, so the scanned repository is empty, which reads as home.
# The lib compares it instead, host half included, and declines on any shape it
# does not recognize. `issue-claim-release.sh` reaches the same function for the
# identical scanned value, so the two hooks cannot answer it differently.
#
# An empty selector is gh's own current-branch default, and it is the ONLY arm
# that reaches it. A named reference gh cannot resolve is not the same case: the
# merge named something, so falling back would act on a different pull request
# than the one it named, and PATCH over whatever block already sits there. That
# declines, which is the act-on-home fail direction this whole path takes.
PR=""
case "${GAIA_GH_MERGE_REF:-}" in
  '')
    PR="$(gh pr view --json number --jq .number 2>/dev/null || true)"
    ;;
  *://*)
    gaia_gh_merge_ref_to_home_pr "$GAIA_GH_MERGE_REF" || exit 0
    PR="$GAIA_HOME_PR_NUMBER"
    ;;
  *[!0-9]*)
    PR="$(gh pr view "$GAIA_GH_MERGE_REF" --json number --jq .number 2>/dev/null || true)"
    ;;
  *)
    PR="$GAIA_GH_MERGE_REF"
    ;;
esac
[ -n "$PR" ] || exit 0

# Resolve the audit mode via the shared resolver: the SAME resolved_mode CI
# reads for this author, so the two producers can never disagree about who
# posts. Proceed ONLY when resolved_mode is exactly `local`; any other value,
# or any resolution failure/ambiguity, means posting here could clobber CI's
# own findings block, so this exits without posting.
is_fork="$(gh pr view "$PR" --json isCrossRepository --jq .isCrossRepository 2>/dev/null || true)"
author="$(gh pr view "$PR" --json author --jq .author.login 2>/dev/null || true)"
[ -n "$author" ] || exit 0

resolved_mode=""
eval "$(PR_IS_FORK="$is_fork" bash .gaia/scripts/read-audit-ci-config.sh --resolve-author "$author" 2>/dev/null)" || true
[ "$resolved_mode" = "local" ] || exit 0

# Resolve the incremental audit base the same way the audited member(s) do.
BASE_REF="$(.github/audit/resolve-audit-base.sh 2>/dev/null || true)"
[ -n "$BASE_REF" ] || exit 0
BASE_SHA="$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
[ -n "$BASE_SHA" ] || exit 0

# Best-effort: post-findings-block.sh always exits 0 and declines cleanly
# when no sidecars exist, so an early merge attempt before the audit ran
# posts nothing rather than an empty block.
bash .gaia/scripts/post-findings-block.sh --base "$BASE_SHA" --pr "$PR" >/dev/null 2>&1 || true

exit 0
