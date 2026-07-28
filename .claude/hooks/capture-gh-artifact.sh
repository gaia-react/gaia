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

# Match `gh pr create` as a real shell invocation, at command start or right
# after a shell separator (&&, ;, ||, |, newline), never mid-line in prose or
# a quoted string. Mirrors token-rollup-merge.sh's command match. Deliberately
# does NOT match `gh issue create`: see gh-artifact-lib.sh for why.
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  :
elif [[ "$cmd" =~ $sep_re ]]; then
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
