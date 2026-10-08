#!/usr/bin/env bash
# PostToolUse Bash hook on `gh pr merge`. Runs .gaia/scripts/usage-merge.sh with
# the payload on stdin, so the session's context gets the per-PR usage-ledger
# block, the Code Audit Team line included, and nothing else.
#
# Exit contract: 0 on every path except a missing library, which exits non-zero
# with stderr naming the file. That is the one documented exception to
# hook-payload.sh's advisory-hook caller contract (an advisory hook exits 0 on a
# load failure): a cost hook that cannot load its readers must say so rather
# than go quiet. When usage-merge.sh itself exits non-zero this hook still
# exits 0 and prints one `[PR cost] unavailable` line on stdout that carries the
# rerun command.
#
# jq absent: the one arming decision made without jq is a raw grep of the
# payload for the merge verb, which prints a single marker line so usage
# tracking does not go quiet without saying so. It can over-arm on a payload
# that merely mentions the phrase; that prints one line and changes nothing.
#
# GAIA_USAGE_HOOKS_DISABLE=1 is a test seam: usage-merge.sh then prints
# nothing, so a suite that runs this real hook drives no ledger writes.

set -euo pipefail

payload=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  if grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' <<<"$payload"; then
    printf 'usage tracking inactive: jq not found\n'
  fi
  exit 0
fi

# Rooted at this file's own directory, never the process working directory.
hook_script_path="${BASH_SOURCE[0]:-$0}"
case "$hook_script_path" in */*) hook_directory="${hook_script_path%/*}" ;; *) hook_directory=. ;; esac

# shellcheck source=/dev/null
. "$hook_directory/lib/hook-payload.sh"
# shellcheck source=/dev/null
. "$hook_directory/lib/verb-arming.sh"

gaia_hook_payload_read "$payload" || exit 0
[ "$GAIA_HOOK_TOOL_NAME" = "Bash" ] || exit 0

# A quoted verb inside prose still arms here, fail-closed, with no safe narrowing.
merge_verb_pattern='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$merge_verb_pattern" 'gh pr merge' "$GAIA_HOOK_COMMAND"; then
  :
else
  exit 0
fi

usage_merge_exit_code=0
bash "$hook_directory/../../.gaia/scripts/usage-merge.sh" <<<"$payload" || usage_merge_exit_code=$?

if [ "$usage_merge_exit_code" -ne 0 ]; then
  # The rerun line is a runnable command: a PR number straight from the merge
  # command, else the current branch only when its name is shell-inert.
  merge_number_pattern='gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([1-9][0-9]{0,9})([[:space:]]|$)'
  if [[ $GAIA_HOOK_COMMAND =~ $merge_number_pattern ]]; then
    rerun_target="${BASH_REMATCH[1]}"
  else
    current_branch="$(git -C "${GAIA_HOOK_CWD:-.}" branch --show-current 2>/dev/null)" || current_branch=""
    if [[ $current_branch =~ ^[A-Za-z0-9._/+-]+$ && $current_branch != -* ]]; then
      rerun_target="--branch $current_branch"
    else
      rerun_target="--branch <branch>"
    fi
  fi
  # The script path is a printed argument, not a path this hook runs, so it
  # is passed as data rather than spelled after `bash` in the format.
  printf '[PR cost] unavailable: usage-merge.sh exited %s; rerun: bash %s pr %s\n' "$usage_merge_exit_code" '.gaia/scripts/usage.sh' "$rerun_target"
fi

exit 0
