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
# What the check does not reach: verb-arming.sh lazily sources
# verb-arming-walk.sh on a raw match, and `bash -n` does not recurse into a
# sourced file, so an unparseable walk lib still denies on 3.2. That load lives
# inside verb-arming.sh, so no consumer hook can guard it from out here; it is
# gaia-react/gaia#1556.
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
