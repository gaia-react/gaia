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
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Shared arming decision; see .claude/hooks/lib/verb-arming.sh. A quoted verb
# inside prose still arms here, fail-closed, with no safe narrowing.
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

_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_lib:-}" ] && "${BASH:-bash}" -n "$_lib/repo-scope.sh" 2>/dev/null && . "$_lib/repo-scope.sh" 2>/dev/null || true
type cmd_targets_foreign_repo_slug >/dev/null 2>&1 || exit 0
type gaia_gh_merge_ref_to_home_pr >/dev/null 2>&1 || exit 0
if cmd_targets_foreign_repo_slug "$cmd"; then
  exit 0
fi

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

# Rooted through the location resolved for the arming load above, never named cwd-relatively, so a failure here degrades to the same silent `exit 0` the arms above take rather than a name resolved against the wrong directory.
_gaia_scripts="${_va_lib:+$_va_lib/../../../.gaia/scripts}"
[ -n "$_gaia_scripts" ] || exit 0

# Best-effort: post-findings-block.sh always exits 0 and declines cleanly
# when no sidecars exist, so an early merge attempt before the audit ran
# posts nothing rather than an empty block.
bash "$_gaia_scripts/post-findings-block.sh" --pr "$PR" >/dev/null 2>&1 || true

exit 0
