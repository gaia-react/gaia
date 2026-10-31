#!/usr/bin/env bash
# PreToolUse Bash + Monitor hook: ask before a command writes .claude/settings.json.
#
# .claude/settings.json registers every GAIA hook and permission rule, so
# whoever edits it decides which guards run. Under bypassPermissions Claude
# Code's own protected-path check does not fire, and a session can rewrite the
# file with no prompt at all. The Edit, Write and MultiEdit tools are covered by
# a permissions.ask rule in .claude/settings.json rather than by this hook; this
# hook covers the shell.
#
# Why ask rather than deny: the guard matches on the target alone and cannot
# read intent. A legitimate change (registering a new hook) and a guard being
# switched off are the same shape, and the party that holds the separating fact
# is the operator, so the call goes to them. The reason string admits the prompt
# is on the target alone.
#
# Path rule: the path equals .claude/settings.json or ends with
# /.claude/settings.json after surrounding quotes and one leading ./ are
# removed. Nested package copies (frontend/.claude/settings.json), worktree
# copies under .claude/worktrees/<name>/ and ~/.claude/settings.json all ask.
# settings.local.json and any other name do not.
#
# There is no exemption marker: a command carrying GAIA_MANIFEST_WRITE= still
# asks, because that marker is the manifest guard's and means nothing here.
#
# Detection is the shared lib/bash-write-target.sh, which the manifest guard
# also sources: redirects, tee, sponge, sed -i and a cp/mv destination. It is
# best-effort and biased toward allowing on ambiguity. Shapes it does not
# recognise pass, for example perl -i, python -c writing the file, and
# git-mediated restores. The hook inspects Monitor commands as well as Bash.
#
# The decision is JSON on stdout and the hook exits 0 with it.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. The contract the literals below
# satisfy lives in .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-settings-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the settings write guard' "$payload" tool_input 'settings.json'

set +e
# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
set -e
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-settings-write.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

set +e
# shellcheck source=lib/bash-write-target.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/bash-write-target.sh" ] && . "$_jq_library_directory/bash-write-target.sh" 2>/dev/null
set -e
if ! type gaia_bash_command_writes_target >/dev/null 2>&1; then
  printf 'BLOCKED: block-settings-write.sh cannot load lib/bash-write-target.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

# An empty or unreadable payload names nothing to guard.
gaia_hook_payload_read "$payload" || exit 0

ASK_REASON='CONFIRM: this command writes .claude/settings.json, the file that registers every GAIA hook and permission rule. This guard asks on the target alone, whatever the change does, because no automatic test tells an intended settings change apart from a guard being switched off. Approve only a change you meant; otherwise deny it. Claude: do not retry this write by another route (another tool, shell shape or path spelling) to get past this prompt.'

ask() {
  jq -n --arg reason "$ASK_REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Called by name from gaia_bash_command_writes_target.
# shellcheck disable=SC2329
is_settings_path() {
  local candidate_path
  candidate_path=$(gaia_write_target_strip_quotes "$1")
  candidate_path=${candidate_path#./}
  [[ "$candidate_path" == ".claude/settings.json" || "$candidate_path" == */.claude/settings.json ]]
}

case "$GAIA_HOOK_TOOL_NAME" in
  Bash | Monitor)
    command_line="$GAIA_HOOK_COMMAND"
    [[ -n "$command_line" ]] || exit 0
    gaia_bash_command_writes_target "$command_line" is_settings_path && ask
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
