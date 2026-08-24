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
_va_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_va_lib:-}" ] && [ -f "$_va_lib/verb-arming.sh" ] && . "$_va_lib/verb-arming.sh"
type gaia_verb_armed >/dev/null 2>&1 || exit 0

frag='gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if gaia_verb_armed "$frag" 'gh pr create' "$cmd"; then
  :
else
  exit 0
fi

[ -f .gaia/scripts/gh-artifact-lib.sh ] || exit 0
. .gaia/scripts/gh-artifact-lib.sh 2>/dev/null || exit 0

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
