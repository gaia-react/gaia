#!/usr/bin/env bash
# PostToolUse Bash hook on `gh pr create`. Drops a breadcrumb (the PR number,
# repo, branch, and session) that only `token-tally.sh --action execute` ever
# reads, so plan execution can carry the pull request its own commit-triggered
# rows have no agent in the loop to report. Every other cost-recording surface
# (the five prose maintenance commands and the /gaia-wiki chain) binds its
# artifact by direct pass-through instead and reads no breadcrumb; see
# .gaia/scripts/gh-artifact-lib.sh for the full rationale.
#
# Fires on every Bash tool call in every session: stay cheap, degrade
# silently, never emit a permission decision, never write to stdout, always
# exit 0.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Uses the shared arming decision, the same one token-rollup-merge.sh uses
# (.claude/hooks/lib/verb-arming.sh). Deliberately does NOT match `gh issue
# create`: see gh-artifact-lib.sh for why. A quoted verb inside prose still
# arms here, fail-closed, with no safe narrowing.
#
# This load runs before the arming gate, on every Bash tool call, so whatever
# guards it is paid on every call. Measured on this machine rather than assumed:
# `bash -n` on the real verb-arming.sh costs ~3.1ms on bash 3.2.57 and ~5.7ms
# on 5.3.15, and as a whole extra hook process that is +2.5ms and +5.7ms
# against a ~16-21ms hook. A surcharge, not a doubling, and worth paying.
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
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && "${BASH:-bash}" -n "$_va_lib/verb-arming.sh" 2>/dev/null && . "$_va_lib/verb-arming.sh" 2>/dev/null || true
type gaia_verb_armed >/dev/null 2>&1 || exit 0

frag='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if gaia_verb_armed "$frag" 'gh pr create' "$cmd"; then
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
"${BASH:-bash}" -n .gaia/scripts/gh-artifact-lib.sh 2>/dev/null && . .gaia/scripts/gh-artifact-lib.sh 2>/dev/null || true
type gaia_gh_artifact_parse_url >/dev/null 2>&1 || exit 0

stdout_text=$(jq -r '.tool_response.stdout // ""' <<<"$payload")
parsed="$(gaia_gh_artifact_parse_url "$stdout_text")"
[ -n "$parsed" ] || exit 0

number="$(jq -r '.number' <<<"$parsed" 2>/dev/null)"
repo="$(jq -r '.repo' <<<"$parsed" 2>/dev/null)"
sid="$(jq -r '.session_id // ""' <<<"$payload")"
branch="$(git branch --show-current 2>/dev/null || true)"

cache_dir="$(gaia_gh_artifact_cache_dir)"
[ -n "$cache_dir" ] || exit 0
bc_path="$(gaia_gh_artifact_path "$cache_dir" "$branch")"
[ -n "$bc_path" ] || exit 0

gaia_gh_artifact_write "$bc_path" "$number" "$repo" "$branch" "$sid" >/dev/null 2>&1 || true

exit 0
