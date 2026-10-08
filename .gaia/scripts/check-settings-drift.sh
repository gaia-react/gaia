#!/usr/bin/env bash
# Drift check for the generated per-package Claude settings. A session launched in `frontend/`
# reads `frontend/.claude/settings.json` and never the root file, so a hook or deny the root gains and the generated
# file lacks is a guard that silently does not run there.
#
# Usage: check-settings-drift.sh [repo_root]
#
# Two checks per registered package whose path is not `.`:
#   1. `gaia packages sync-settings --check`: the generated file equals what the
#      generator would write now (catches an overlay or root edit not synced).
#   2. A presence assertion with jq, independent of the generator: every root
#      PreToolUse handler appears as the same (command, if) pair, every root permissions.deny and
#      sandbox.filesystem.denyRead entry appears in its re-anchored form, and
#      additionalDirectories reaches the repo root. This is what catches a
#      generator that drops an entry while still agreeing with itself. The
#      handler comparison covers PreToolUse only, where every guard lives.
#
# Exit 0 clean, 1 drift or a missing entry (the file and entry are named),
# 2 when the check cannot run (no jq, no CLI bundle, unreadable registry).
#
# Bash 3.2 compatible; BSD and GNU tools.
set -u

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$script_directory/../.." && pwd)}"

fail_unrunnable() {
  printf 'check-settings-drift: %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail_unrunnable 'jq is not on PATH. Next step: install jq.'
cli="$root/.gaia/cli/gaia"
[ -x "$cli" ] || fail_unrunnable "$cli is missing or not executable. Next step: restore it from git or run /update-gaia."
packages_lib="$root/.claude/hooks/lib/gaia-packages.sh"
[ -f "$packages_lib" ] || fail_unrunnable "$packages_lib is missing. Next step: restore it from git or run /update-gaia."
root_settings="$root/.claude/settings.json"
[ -f "$root_settings" ] || fail_unrunnable "$root_settings is missing. Next step: restore it from git."

# shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
. "$packages_lib"
load_status=0
gaia_packages_load "$root" || load_status=$?
if [ "$load_status" -ne 0 ]; then
  fail_unrunnable "$GAIA_PACKAGES_ERROR"
fi

status=0

generator_status=0
generator_output="$("$cli" packages sync-settings --check --repo-root "$root" 2>&1 >/dev/null)" || generator_status=$?
if [ "$generator_status" -eq 2 ]; then
  printf '%s\n' "$generator_output" >&2
  fail_unrunnable 'settings generation failed. Next step: fix the error above, then run ./.gaia/cli/gaia packages sync-settings.'
elif [ "$generator_status" -ne 0 ]; then
  printf '%s\n' "$generator_output" >&2
  printf 'check-settings-drift: generated settings are out of date. Next step: run ./.gaia/cli/gaia packages sync-settings and stage the result.\n' >&2
  status=1
fi

# The re-anchor rule, restated in jq on purpose: it is the independent oracle
# for the generator's TypeScript copy of it.
# shellcheck disable=SC2016 # a jq program, not shell
reanchor_program='
def spec_anchor($p):
  if test("^(\\*\\*/|//|~/)") then . else $p + sub("^(\\./|/)"; "") end;
def rule_anchor($p):
  if test("^(Edit|MultiEdit|NotebookEdit|Read|Write)\\(.*\\)$")
  then capture("^(?<tool>[A-Za-z]+)\\((?<spec>.*)\\)$")
       | "\(.tool)(\(.spec | spec_anchor($p)))"
  else . end;
'

report_missing() {
  printf 'check-settings-drift: %s is missing %s\n' "$1" "$2" >&2
  status=1
}

# Each query below reads a JSON-lines stream through a here-document, so the
# loop body runs in this shell and can set `status`.
while IFS="$(printf '\t')" read -r package_name package_path; do
  [ -n "$package_name" ] || continue
  [ "$package_path" = . ] && continue
  generated_relative="$package_path/.claude/settings.json"
  generated="$root/$generated_relative"
  if [ ! -f "$generated" ]; then
    report_missing "$generated_relative" 'the file itself'
    continue
  fi
  if ! jq -e . "$generated" >/dev/null 2>&1; then
    report_missing "$generated_relative" 'valid JSON'
    continue
  fi

  prefix=''
  parent=''
  remaining="$package_path"
  while [ -n "$remaining" ]; do
    prefix="${prefix}../"
    if [ -z "$parent" ]; then parent='..'; else parent="../$parent"; fi
    case "$remaining" in
      */*) remaining="${remaining#*/}" ;;
      *) remaining='' ;;
    esac
  done

  # Every root PreToolUse handler as a (command, if) pair, verbatim; an absent
  # `if` is its own value (null), so a generated handler that gained or lost a
  # gate is a miss. Pairs travel as JSON so a command carrying a quote or a
  # newline compares exactly. `.["if"]` because bare `.if` is a syntax error in
  # older jq.
  while IFS= read -r handler_json; do
    [ -n "$handler_json" ] || continue
    if ! jq -e --argjson h "$handler_json" \
      '[.hooks.PreToolUse[]?.hooks[]? | [.command, .["if"]]] | any(.[]; . == $h)' \
      "$generated" >/dev/null; then
      command_json="$(printf '%s' "$handler_json" | jq -c '.[0]')"
      if_json="$(printf '%s' "$handler_json" | jq -c '.[1]')"
      report_missing "$generated_relative" "the PreToolUse hook command $command_json with if $if_json"
    fi
  done <<HOOK_HANDLERS
$(jq -c '.hooks.PreToolUse[]?.hooks[]? | [.command, .["if"]]' "$root_settings")
HOOK_HANDLERS

  # Every root deny rule and denyRead entry, in its re-anchored form.
  while IFS= read -r rule_json; do
    [ -n "$rule_json" ] || continue
    if ! jq -e --argjson r "$rule_json" '(.permissions.deny // []) | index($r) != null' \
      "$generated" >/dev/null; then
      report_missing "$generated_relative" "the permissions.deny rule $rule_json"
    fi
  done <<DENY_RULES
$(jq -c --arg p "$prefix" "$reanchor_program"'(.permissions.deny // [])[] | rule_anchor($p)' "$root_settings")
DENY_RULES

  while IFS= read -r entry_json; do
    [ -n "$entry_json" ] || continue
    if ! jq -e --argjson r "$entry_json" '(.sandbox.filesystem.denyRead // []) | index($r) != null' \
      "$generated" >/dev/null; then
      report_missing "$generated_relative" "the sandbox.filesystem.denyRead entry $entry_json"
    fi
  done <<DENY_READ_ENTRIES
$(jq -c --arg p "$prefix" "$reanchor_program"'(.sandbox.filesystem.denyRead // [])[] | spec_anchor($p)' "$root_settings")
DENY_READ_ENTRIES

  if ! jq -e --arg d "$parent" '(.permissions.additionalDirectories // []) | index($d) != null' \
    "$generated" >/dev/null; then
    report_missing "$generated_relative" "permissions.additionalDirectories entry \"$parent\""
  fi
done <<PACKAGE_LIST
$(gaia_packages_list)
PACKAGE_LIST

if [ "$status" -eq 0 ]; then
  printf 'check-settings-drift: clean\n' >&2
fi
exit "$status"
