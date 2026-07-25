#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helper for the worthiness ledger, the ONE definition of where a
# tree's worthiness verdicts live. Both the ledger writer
# (.gaia/scripts/audit-ledger/append-worthiness.mjs) and its reader
# (.claude/hooks/worthiness-presence-check.sh) call this instead of hand-
# building the path literal independently, matching the problem
# .claude/hooks/lib/red-ledger.sh already solves for the RED ledger. Dual-
# mode: source it for the function below, or run it directly as a script so
# the Node writer can shell out to it (see "Usage (executable)" below).
#
# Usage (sourced, from a hook script, pwd = repo root):
#   [ -f .claude/hooks/lib/worthiness-ledger.sh ] && . .claude/hooks/lib/worthiness-ledger.sh
#   ledger=$(worthiness_ledger_path "$tree_root")
#
# Usage (executable):
#   bash .claude/hooks/lib/worthiness-ledger.sh [dir]
#
# No persistent `cd`; all paths are repo-relative or resolved via
# main-root-lib.sh's own resolvers. Guarded so double-sourcing is a no-op.

[ -n "${WORTHINESS_LEDGER_LIB_SOURCED:-}" ] && return 0
WORTHINESS_LEDGER_LIB_SOURCED=1

# Absolute path to the append-only JSON Lines ledger, rooted at ROOT (the
# per-tree root a caller has already resolved, typically via Pattern T's
# payload-anchored gaia_resolve_tree_root) and keyed to that same ROOT's own
# gaia_tree_key, so the ledger lands under a tree-keyed subpath even once a
# worktree's whole .gaia/local becomes one symlink to main's. Defaults to
# gaia_resolve_tree_root of the process cwd when no ROOT is supplied. The key
# is always derived from ROOT itself, never from the process cwd, so a
# caller's own root resolution and this function's key agree. The resolver
# is sourced here, deferred into this function's own body (never at source
# time), matching red_ledger_path's own "no side effects at source time"
# contract.
worthiness_ledger_path() {
  local root="${1:-}"
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  # shellcheck disable=SC1091
  source "$self_dir/../../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || return 1
  if [ -z "$root" ]; then
    root="$(gaia_resolve_tree_root 2>/dev/null)" || return 1
  fi
  [ -n "$root" ] || return 1
  local key
  key="$(gaia_tree_key "$root" 2>/dev/null)" || return 1
  printf '%s\n' "$root/.gaia/local/worthiness-ledger/$key/worthiness.jsonl"
}

# Executable entry: prints the ledger path for an optional dir operand
# (default: process cwd's own tree). Lets append-worthiness.mjs shell out to
# this one definition instead of reimplementing the path in JS.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  worthiness_ledger_path "${1:-}"
  exit $?
fi
