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
# This load runs before the arming gate, on every Bash tool call, so it takes
# the free half rather than a parse check: `bash -n` on the real
# verb-arming.sh measures ~13ms on bash 3.2.57 and ~16ms on 5.3.15, against the
# ~16-21ms per hook process .gaia/tests/hooks/verb-arming-cost.bats records, so
# a fork here roughly doubles what every Bash tool call pays. `|| true` costs
# nothing and closes the bash 5 half. The honest limit, stated rather than
# implied: under `set -e` an UNPARSEABLE verb-arming.sh still abandons the
# shell ahead of the arm on a stock 3.2, exiting 2. Same decision, same reason,
# as token-tally-git-op.sh's own pre-gate load. Closing that residual needs
# something other than a per-call fork and is tracked on
# gaia-react/gaia#1556, along with verb-arming.sh's own lazy load of
# verb-arming-walk.sh, which no consumer hook can guard from out here.
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && [ -f "$_va_lib/verb-arming.sh" ] && { . "$_va_lib/verb-arming.sh" 2>/dev/null || true; }
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
# abandons the shell ahead of that arm; a file bash cannot open exits 1, an
# advisory that loses the breadcrumb, and one it cannot parse exits 2 on every
# platform. This is PostToolUse, so neither refuses the `gh pr create` that
# already ran; both contradict the "degrade silently, always exit 0" contract
# in this file's header. What degrades in the arm's place is the `type` check.
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
