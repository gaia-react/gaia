#!/usr/bin/env bash
# Shared helpers for the RED-observation ledger, sourced by both the capture
# hook (.claude/hooks/capture-red-observations.sh) and the commit check
# (.claude/hooks/red-verify-commit-check.sh). Keeping the path, the
# repo-relative normalization, and the signal invocation in one place keeps
# the two hooks in sync by construction.
#
# Usage (from a hook script, pwd = repo root):
#   [ -f .claude/hooks/lib/red-ledger.sh ] && . .claude/hooks/lib/red-ledger.sh
#   ledger=$(red_ledger_path "$tree_root")
#   rel=$(red_ledger_repo_rel "$some_path")
#   red_ledger_signals "$rel"          # NDJSON on stdout; helper's exit code
#
# No persistent `cd`; all paths are repo-relative or resolved via `git -C`.
# Guarded so double-sourcing is a no-op.

[ -n "${RED_LEDGER_LIB_SOURCED:-}" ] && return 0
RED_LEDGER_LIB_SOURCED=1

# Absolute path to the append-only JSON Lines ledger, rooted at ROOT (the
# per-tree root a caller has already resolved, typically via Pattern T's
# payload-anchored gaia_resolve_tree_root). Defaults to gaia_resolve_tree_root
# of the process cwd when no ROOT is supplied; the resolver is sourced here,
# deferred into this function's own body (never at source time), so this
# lib's "no side effects at source time" contract holds -- matching
# state-registry-lib.sh's own gaia_registry_path.
red_ledger_path() {
  local root="${1:-}"
  if [ -z "$root" ]; then
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
    # shellcheck disable=SC1091
    source "$self_dir/../../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || return 1
    root="$(gaia_resolve_tree_root 2>/dev/null)" || return 1
  fi
  [ -n "$root" ] || return 1
  printf '%s\n' "$root/.gaia/local/red-ledger/observations.jsonl"
}

# Repo-relative path to the Node signal helper.
red_ledger_signal_script() {
  printf '%s\n' '.gaia/scripts/red-ledger/extract-test-signals.mjs'
}

# Normalize an absolute-or-relative path to a repo-relative POSIX path.
# Strips a leading repo-root prefix and any leading `./`. Idempotent: an
# already-repo-relative path returns unchanged. pwd is the repo root, so a
# bare relative path is already repo-relative.
red_ledger_repo_rel() {
  local path="$1"
  local root

  # Resolve the repo root; fall back to pwd when not inside a work tree.
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  [ -n "$root" ] || root="$PWD"

  # Strip a leading repo-root prefix (with or without trailing slash).
  case "$path" in
    "$root"/*) path="${path#"$root"/}" ;;
    "$root") path="" ;;
  esac

  # Strip any leading `./` segments.
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done

  printf '%s\n' "$path"
}

# Run the Node signal helper for a repo-relative test path and echo its NDJSON
# output. Propagates the helper's exit code so the caller can apply its own
# fail-open / fail-closed policy. Exits 0 with no output (and a stderr note) if
# Node is unavailable, treating that as "cannot recompute signal".
red_ledger_signals() {
  local rel="$1"
  local script
  script=$(red_ledger_signal_script)

  if ! command -v node >/dev/null 2>&1; then
    echo "red-ledger: node not found; cannot compute signals" >&2
    return 0
  fi
  [ -f "$script" ] || {
    echo "red-ledger: signal helper missing at $script" >&2
    return 0
  }

  node "$script" "$rel"
}
