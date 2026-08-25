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
#
# This load runs before the arming gate, on every Bash tool call, so whatever
# guards it is paid on every call. Measured on this machine rather than assumed:
# `bash -n` on the real verb-arming.sh costs ~3.1ms on bash 3.2.57 and ~5.7ms
# on 5.3.15, over 200 forks, against a ~16-21ms hook process. A surcharge, not
# a doubling, and worth paying. That per-fork figure is the one to size a fifth
# parse-checked hook off: no end-to-end per-hook delta is quoted here because
# it could not be measured on this machine, and the header of
# verb-arming-cost.bats records why.
#
# The cheaper `{ . lib || true; }` arm was the first spelling here and is not
# enough. It closes the bash 5 half only: under `set -e` an unparseable
# verb-arming.sh still abandons the shell ahead of the arm on a stock 3.2 at
# exit 2, and it suppresses the syntax error that would name the broken file,
# so what survives is a denial with no stated reason. The parse check removes
# both, which is why the cost above is spent here.
#
# What the check does not reach, because `bash -n` does not recurse into a
# sourced file: verb-arming.sh lazily sources TWO libs of its own, each behind
# an `-f` test with no parse check, and an unparseable copy of either still
# abandons a stock 3.2 shell at exit 2.
#
#   verb-arming-walk.sh, inside _gaia_va_view, needs a raw verb match.
#   repo-scope.sh, inside _gaia_va_first_command, needs only the lead-word
#   pre-filter, so it fires on any command sharing the verb's FIRST WORD.
#
# The second is much the wider of the two and the one to close first: measured
# on staged copies with repo-scope.sh holding conflict markers, a plain
# `git status` exits 2 on /bin/bash 3.2.57 and 0 on 5.3.15. Both loads live
# inside verb-arming.sh, so no consumer hook can guard either from out here.
# Tracked as its own issue rather than this one, because gaia-react/gaia#1556
# closes when this change merges and a pointer needs a live destination:
# gaia-react/gaia#1564.
#
# This hook is PreToolUse, so the residual above is the widest of the three
# that share this load: an unparseable verb-arming.sh on a stock 3.2 exits 2
# here, the deny code, and it does so before the gate knows the call is a
# `gh pr merge` at all, refusing every Bash tool call rather than merges alone.
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && "${BASH:-bash}" -n "$_va_lib/verb-arming.sh" 2>/dev/null && . "$_va_lib/verb-arming.sh" 2>/dev/null || true
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
#
# Past the arming gate, so this load parse-checks rather than resting on the
# `-f` test: an existence test proves the file opens, not that it parses, and
# under `set -e` an unparseable repo-scope.sh abandons the shell at exit 2, the
# deny code, refusing the merge this hook's contract says it never blocks.
# `bash -n` subsumes the existence test, and the undefined-after-the-source
# contract below is what still degrades.
#
# What that closes is bounded, and the bound is this hook's alone among the
# four: verb-arming.sh's pass-3 tokenizer sources the SAME repo-scope.sh
# unguarded, inside the gaia_verb_armed call above. On bash 5 that load reaches
# its arm and this one still decides. On a stock 3.2 the shell is already gone
# before the check below runs, so the check covers a repo-scope.sh reached only
# by this load and not one pass 3 reaches first. The residual paragraph above
# names that site; it is the same gaia-react/gaia#1564 entry.
#
# The pass-3 path needs a payload that MISSES the raw match to reach it, so a
# merge payload cannot exercise it: the conflict-marker case below returns on
# the raw match before pass 3 fires, which is why it is honest unpinned.
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_lib:-}" ] && "${BASH:-bash}" -n "$_lib/repo-scope.sh" 2>/dev/null && . "$_lib/repo-scope.sh" 2>/dev/null || true
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
