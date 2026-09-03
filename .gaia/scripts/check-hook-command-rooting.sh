#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hook-command rooting check for .claude/settings.json (#1740).
#
# Every hook is registered as a command string, and /bin/sh runs that
# string against the Bash tool's current working directory, which persists
# for the whole session. A command naming its script by a repo-relative
# path therefore resolves against wherever the session last stood, so one
# `cd` unregisters the entire layer: the script is not found, /bin/sh exits
# 127, and per wiki/concepts/Claude Hooks.md only exit 2 (or a structured
# deny) blocks. 127 is neither, so the tool call proceeds and the guard
# layer fails OPEN. Under bypassPermissions those guards are the only layer
# there is.
#
# WHY THIS CHECK IS LOAD-BEARING RATHER THAN GARNISH. Nothing at the
# registration site can fail closed, because the failure mode IS a missing
# script and a missing script exits 127. No prefix, fallback or wrapper
# changes that, and a wrapper is registered by the same mechanism it would
# be protecting. So a static read of the file is the only instrument that
# can hold this class down, and this is it. What it holds down is the half
# of the class that lives in the file; a root that fails to resolve at
# RUNTIME is a residual this check cannot reach and does not claim to.
#
# WHAT COUNTS AS ROOTED. Two shapes, and the test is a property rather than
# a spelling, so a future registration that reaches its root another way is
# not forced to match a literal:
#
#   1. every `.claude/` and `.gaia/` occurrence is preceded by `/`, which is
#      what makes it a suffix of some root rather than a path in its own
#      right, and
#   2. the command contains no `../` traversal, since `x/../.claude/...`
#      satisfies rule 1 while still resolving against the current directory.
#
# The sanctioned prefix in this repo is
#   "$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/"
# which resolves to the CURRENT tree at any depth inside the repository.
# `$CLAUDE_PROJECT_DIR` alone is deliberately NOT the root: measured
# 2026-09-03, it holds the session's original project directory and does not
# follow entry into a linked worktree, so prefixing with it would make a
# worktree session execute the main checkout's hooks instead of its own
# tree's. See wiki/concepts/Claude Hooks.md.
#
# Dual-mode: source it for the functions below, or run it directly.
#
# gaia_hook_command_rooting_commands <settings-json-path>
#   Prints every registered command string, one per line: every
#   hooks.<event>[].hooks[].command plus statusLine.command when present.
#   This is the derivation the suite counts against the file itself, so a
#   short read fails loudly instead of silently checking a subset.
#
# gaia_check_hook_command_rooting <repo_root>
#   Prints one `UNROOTED: <command>` line per violation. Returns 0 only when
#   at least one command was found and every one of them is rooted; 1 on any
#   violation or on an empty command set (a per-element claim over an empty
#   set is true without meaning anything); 2 when the file is missing or
#   unreadable. Requires jq.

gaia_hook_command_rooting_commands() {
  local settings="$1"
  jq -r '[(.hooks // {} | .[][].hooks[].command), (.statusLine.command // empty)] | .[]' "$settings"
}

gaia_check_hook_command_rooting() {
  local repo_root="$1"
  local settings="$repo_root/.claude/settings.json"
  local rc=0 count=0 cmd

  if [ ! -f "$settings" ]; then
    printf 'check-hook-command-rooting: no such file: %s\n' "$settings" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'check-hook-command-rooting: jq is required\n' >&2
    return 2
  fi

  local commands
  if ! commands="$(gaia_hook_command_rooting_commands "$settings" 2>/dev/null)"; then
    printf 'check-hook-command-rooting: could not parse %s\n' "$settings" >&2
    return 2
  fi

  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    count=$((count + 1))
    # Rule 1: a `.claude/` or `.gaia/` occurrence not preceded by `/` is a
    # path in its own right, so it resolves against the current directory.
    if printf '%s' "$cmd" | grep -qE '(^|[^/])\.(claude|gaia)/'; then
      printf 'UNROOTED: %s\n' "$cmd"
      rc=1
      continue
    fi
    # Rule 2: a traversal satisfies rule 1 and still resolves relatively.
    if printf '%s' "$cmd" | grep -qF -- '../'; then
      printf 'UNROOTED: %s\n' "$cmd"
      rc=1
    fi
  done <<EOF
$commands
EOF

  if [ "$count" -eq 0 ]; then
    printf 'check-hook-command-rooting: no hook commands found in %s\n' "$settings" >&2
    return 1
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'settings.json hook commands: every registered command resolves independently of cwd (%s checked)\n' "$count"
  fi
  return $rc
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-hook-command-rooting: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_hook_command_rooting "$repo_root"
  exit $?
fi
