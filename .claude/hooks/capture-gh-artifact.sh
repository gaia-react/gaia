#!/usr/bin/env bash
# PostToolUse Bash hook on `gh pr create`. Records the PR-to-branch edge in the
# usage ledger (`usage.sh link --pr`), and drops a breadcrumb (the PR number,
# repo, branch, and session) that only `token-tally.sh --action execute` ever
# reads, so plan execution can carry the pull request its own commit-triggered
# rows have no agent in the loop to report. GAIA_USAGE_HOOKS_DISABLE=1 skips
# the edge; it is a test seam for suites that run this real hook. Every other
# cost-recording surface (the five prose maintenance commands and the
# /gaia-wiki chain) binds its artifact by direct pass-through instead and reads
# no breadcrumb; see .gaia/scripts/gh-artifact-lib.sh for the full rationale.
#
# Fires on every Bash tool call in every session: stay cheap, degrade
# silently, never emit a permission decision, never write to stdout, always
# exit 0.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)

_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_hook_library_directory:-}" ] && . "$_hook_library_directory/hook-payload.sh" 2>/dev/null || true
type gaia_hook_payload_read >/dev/null 2>&1 || exit 0
gaia_hook_payload_read "$payload" || exit 0
[ "$GAIA_HOOK_TOOL_NAME" = "Bash" ] || exit 0

command=$GAIA_HOOK_COMMAND

# Uses the shared arming decision, the same one token-rollup-merge.sh uses
# (.claude/hooks/lib/verb-arming.sh). Deliberately does NOT match `gh issue
# create`: see gh-artifact-lib.sh for why. A quoted verb inside prose still
# arms here, fail-closed, with no safe narrowing.
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
# shellcheck source=/dev/null
[ -n "${_hook_library_directory:-}" ] && "${BASH:-bash}" -n "$_hook_library_directory/verb-arming.sh" 2>/dev/null && . "$_hook_library_directory/verb-arming.sh" 2>/dev/null || true
type gaia_verb_armed >/dev/null 2>&1 || exit 0

verb_pattern='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if gaia_verb_armed "$verb_pattern" 'gh pr create' "$command"; then
  :
else
  exit 0
fi

# Past the arming gate, so this load parse-checks: `bash -n` answers both
# "does it open" and "does it parse" in one call and subsumes the existence
# test the trailing `|| exit 0` could not deliver. Under `set -e` a failed `.`
# abandons the shell ahead of that arm: a file bash cannot open exits 1, losing
# the breadcrumb, and one it cannot parse exits 2. Both halves are 3.2-only
# here, because the arm this replaced was `|| exit 0` and bash 5 reaches it for
# an unparseable lib exactly as for a missing one; measured 2 and 0 on 3.2.57
# and 5.3.15. Only a bare `.` with no arm dies on both shells, which is the
# shape the verb-arming load above carried and this one did not. That is why
# the conflict-marker case for this load is pinned to /bin/bash and ships no
# unpinned counterpart. This is PostToolUse, so neither exit refuses the
# `gh pr create` that already ran; both contradict the "degrade silently,
# always exit 0" contract in this file's header. What degrades in the arm's
# place is the `type` check.
#
# Rooted through the location resolved for the arming load above rather than
# the process working directory: the parse check answers false for a library it
# cannot see, and the `type` degrade below reads that as an unusable lib.
# Three levels up, not two: $_hook_library_directory is the `lib` DIRECTORY
# (<root>/.claude/hooks/lib), so the repository root is ../../.. from it.
# Empty when the rooting above failed, and guarded rather than defaulted to a
# bare `.claude/hooks/lib`: that default resolves against the process working
# directory, so the one branch where the rooting fails would revert to exactly
# the resolution this rooting exists to remove, indistinguishably from an
# absent library. Same shape as the arming load above.
_gh_artifact_library="${_hook_library_directory:+$_hook_library_directory/../../../.gaia/scripts/gh-artifact-lib.sh}"
# shellcheck source=/dev/null
[ -n "$_gh_artifact_library" ] && "${BASH:-bash}" -n "$_gh_artifact_library" 2>/dev/null && . "$_gh_artifact_library" 2>/dev/null || true
type gaia_gh_artifact_parse_url >/dev/null 2>&1 || exit 0

stdout_text=$(jq -r '.tool_response.stdout // ""' <<<"$payload")
parsed="$(gaia_gh_artifact_parse_url "$stdout_text")"
[ -n "$parsed" ] || exit 0

number="$(jq -r '.number' <<<"$parsed" 2>/dev/null)"
repo="$(jq -r '.repo' <<<"$parsed" 2>/dev/null)"
session_id=$GAIA_HOOK_SESSION_ID
branch="$(git branch --show-current 2>/dev/null || true)"

# The PR-to-branch edge is written before the cache and breadcrumb exits below,
# so a cache that cannot be written never costs the merge hook its way back to
# the branch. No network call.
# A repo flag (`-R`, `-Rvalue`, `--repo`, `--repo=`) anywhere in the text after
# the create verb, later lines included, means the PR lives in another
# repository, so its number names nothing on the local branch and no edge is
# written. The scan reads the whole remaining text, so a multi-line `--body`
# ahead of the flag cannot hide it; a flag inside quoted prose, or in a later
# command, also skips the edge, which fails toward no edge. The created URL is
# not compared with origin, because a fork workflow creates a PR in the
# upstream repository from the local branch.
_gh_fragment='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
_gh_foreign=0
if [[ $command =~ $_gh_fragment ]]; then
  _gh_rest="${command#*"${BASH_REMATCH[0]}"}"
  _gh_repo_flag_pattern='(^|[[:space:]])(-R|--repo)'
  if [[ $_gh_rest =~ $_gh_repo_flag_pattern ]]; then _gh_foreign=1; fi
fi
if [ "${GAIA_USAGE_HOOKS_DISABLE:-}" != 1 ] && [ -n "$branch" ] && [ "$_gh_foreign" = 0 ]; then
  _usage_sh="${_hook_library_directory:+$_hook_library_directory/../../../.gaia/scripts/usage.sh}"
  if [ -n "$_usage_sh" ] && [ -f "$_usage_sh" ]; then
    bash "$_usage_sh" link --pr "$number" --branch "$branch" --source gh-pr-create --session "$session_id" >/dev/null 2>&1 || true
  fi
fi

cache_directory="$(gaia_gh_artifact_cache_directory)"
[ -n "$cache_directory" ] || exit 0
breadcrumb_path="$(gaia_gh_artifact_path "$cache_directory" "$branch")"
[ -n "$breadcrumb_path" ] || exit 0

gaia_gh_artifact_write "$breadcrumb_path" "$number" "$repo" "$branch" "$session_id" >/dev/null 2>&1 || true

exit 0
