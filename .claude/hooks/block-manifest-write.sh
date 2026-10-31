#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash hook: deny writes to .gaia/manifest.json.
#
# .gaia/manifest.json is release-generated and lists only the files GAIA
# ships; adopter feature work never adds to it.
# This is a best-effort, defense-in-depth guard, not an airtight one: Bash
# vectors are unbounded, so it covers the well-known write shapes and stays
# biased toward allowing on ambiguity.
#
# Edit / Write / MultiEdit: inspect .tool_input.file_path. No exemption; no
# legitimate writer uses an edit tool on the manifest.
#
# Bash: inspect .tool_input.command.
#   - Exemption: a command containing the substring GAIA_MANIFEST_WRITE=
#     (any value) is allowed unconditionally. The legitimate Bash writers
#     prepend it: the /update-gaia skill (.claude/skills/update-gaia/SKILL.md),
#     the remove-i18n instructions and the 2.0.0 migration prompt.
#   - Otherwise denied when the command writes the guarded path via an output
#     redirect (>, >>), tee, sed -i (with or without a macOS '' backup
#     suffix), sponge, or cp/mv with the guarded path as destination. Reading
#     the manifest as a cp/mv source, or any other command, is allowed. The
#     detection lives in the shared lib/bash-write-target.sh; this hook keeps
#     the path rule and the exemption.
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-manifest-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the manifest write guard' "$payload" tool_input 'manifest.json'
# The GAIA_MANIFEST_WRITE= exemption is not read here: with no jq the command
# that would carry it cannot be read, so a legitimate writer refuses too.

set +e
# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
set -e
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-manifest-write.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
set +e
# shellcheck source=lib/bash-write-target.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/bash-write-target.sh" ] && . "$_jq_library_directory/bash-write-target.sh" 2>/dev/null
set -e
if ! type gaia_bash_command_writes_target >/dev/null 2>&1; then
  printf 'BLOCKED: block-manifest-write.sh cannot load lib/bash-write-target.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
# An empty or unreadable payload names nothing to guard, and the hook stands
# down with status 0, as the per-field reads did for an empty payload.
gaia_hook_payload_read "$payload" || exit 0
tool_name="$GAIA_HOOK_TOOL_NAME"

DENY_MESSAGE="BLOCKED: .gaia/manifest.json is release-generated and lists only files GAIA ships; feature work never adds to it. /gaia-fitness reads it to tell GAIA's files from yours, so an added entry can mark your own file GAIA-shipped and put it beyond the heal, and /update-gaia replaces the file wholesale from the release, discarding the edit."

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Guarded path: after stripping surrounding quotes and a leading ./, the
# path equals .gaia/manifest.json or ends with /.gaia/manifest.json (absolute
# paths). Not guarded if any other character follows .json.
is_guarded_path() {
  local candidate_path
  candidate_path=$(gaia_write_target_strip_quotes "$1")
  candidate_path=${candidate_path#./}
  [[ "$candidate_path" == ".gaia/manifest.json" || "$candidate_path" == */.gaia/manifest.json ]]
}

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path="$GAIA_HOOK_FILE_PATH"
    [[ -n "$file_path" ]] || exit 0
    is_guarded_path "$file_path" && deny "$DENY_MESSAGE"
    exit 0
    ;;

  Bash)
    command_line="$GAIA_HOOK_COMMAND"
    [[ -n "$command_line" ]] || exit 0

    # Exemption marker: allow unconditionally, before any vector inspection.
    [[ "$command_line" == *"GAIA_MANIFEST_WRITE="* ]] && exit 0

    gaia_bash_command_writes_target "$command_line" is_guarded_path && deny "$DENY_MESSAGE"

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
