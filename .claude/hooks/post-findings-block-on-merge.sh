#!/usr/bin/env bash
# PreToolUse Bash hook on `gh pr merge`: the deterministic caller for
# post-findings-block.sh. Under local audit mode no code path posted the
# machine-readable findings block, only a hand-run snippet did, so a local
# merge contributed nothing to the finding-recurrence tally. This hook closes
# that gap: on a real `gh pr merge` invocation it resolves the pull request
# and calls the existing producer. Every audit is local, so no audit mode is
# resolved first. Pure side effect: it never blocks the merge and never emits
# a permission decision.

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

command_line=$GAIA_HOOK_COMMAND

# Shared arming decision; see .claude/hooks/lib/verb-arming.sh. A quoted verb
# inside prose still arms here, fail-closed, with no safe narrowing.
# shellcheck source=/dev/null
[ -n "${_hook_library_directory:-}" ] && "${BASH:-bash}" -n "$_hook_library_directory/verb-arming.sh" 2>/dev/null && . "$_hook_library_directory/verb-arming.sh" 2>/dev/null || true
type gaia_verb_armed >/dev/null 2>&1 || exit 0

verb_pattern='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$verb_pattern" 'gh pr merge' "$command_line"; then
  :
else
  exit 0
fi

_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_library_directory:-}" ] && "${BASH:-bash}" -n "$_library_directory/repo-scope.sh" 2>/dev/null && . "$_library_directory/repo-scope.sh" 2>/dev/null || true
type command_targets_foreign_repo_slug >/dev/null 2>&1 || exit 0
type gaia_gh_merge_reference_to_home_pr >/dev/null 2>&1 || exit 0
if command_targets_foreign_repo_slug "$command_line"; then
  exit 0
fi

PR=""
case "${GAIA_GH_MERGE_REFERENCE:-}" in
  '')
    PR="$(gh pr view --json number --jq .number 2>/dev/null || true)"
    ;;
  *://*)
    gaia_gh_merge_reference_to_home_pr "$GAIA_GH_MERGE_REFERENCE" || exit 0
    PR="$GAIA_HOME_PR_NUMBER"
    ;;
  *[!0-9]*)
    PR="$(gh pr view "$GAIA_GH_MERGE_REFERENCE" --json number --jq .number 2>/dev/null || true)"
    ;;
  *)
    PR="$GAIA_GH_MERGE_REFERENCE"
    ;;
esac
[ -n "$PR" ] || exit 0

# Rooted through the location resolved for the arming load above, never named cwd-relatively, so a failure here degrades to the same silent `exit 0` the arms above take rather than a name resolved against the wrong directory.
_gaia_scripts="${_hook_library_directory:+$_hook_library_directory/../../../.gaia/scripts}"
[ -n "$_gaia_scripts" ] || exit 0

# Best-effort: post-findings-block.sh always exits 0 and declines cleanly
# when no sidecars exist, so an early merge attempt before the audit ran
# posts nothing rather than an empty block.
bash "$_gaia_scripts/post-findings-block.sh" --pr "$PR" >/dev/null 2>&1 || true

exit 0
