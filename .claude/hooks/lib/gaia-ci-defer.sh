#!/usr/bin/env bash
# GAIA CI deferral helper. Source this from any local automatic trigger that
# wants to honor the per-tool ci/local/off mode in .gaia/automation.json.
# When the matching config entry has mode == "ci", emit a one-line log and
# exit 0. Otherwise return without side effects so the caller continues.
#
# The argument is the snake_case CONFIG KEY from the automation schema,
# the same identifier used as the top-level field in .gaia/automation.json
# (e.g. `wiki`, `pnpm_audit`, `stale_branches`, `update_deps`, `update_gaia`).
# It is NOT necessarily the CLI tool id (kebab-case `pnpm-audit` vs
# snake_case `pnpm_audit`). Callers must pass the config-key form.
#
# Usage (from a hook script):
#   . .claude/hooks/lib/gaia-ci-defer.sh
#   gaia_ci_defer_if_managed wiki   # exits 0 if managed; returns if not.
#
# Sourcing a function (rather than a top-level guard) lets the caller run its
# own pre-flight (jq presence, .git presence, payload reads) before deciding
# when to check deferral.

gaia_ci_defer_if_managed() {
  local config_key="$1"

  # The config is a tracked file belonging to the ACTING TREE, so it is
  # resolved rather than named relative to the process working directory. A
  # caller reached from a subdirectory -- wiki-commit-nudge.sh is one, gated
  # only by `git rev-parse --is-inside-work-tree`, true at any depth -- would
  # otherwise miss the file and take the absent-config default. That default
  # fails toward RUNNING, so a tool the operator put in `ci` mode fires its
  # local trigger anyway, with output byte-identical to having no config at
  # all: there is nothing in the result to read the miss off.
  #
  # Resolved inside the function body, never at source time, so this lib keeps
  # its no-side-effects-on-source contract; lib/red-ledger.sh's
  # red_ledger_path resolves on the same terms. Every failure along the chain
  # returns the caller to "not managed", which is this function's existing
  # posture for an unreadable config, and the chain's last step is `pwd`, what
  # the bare literal named before.
  local self_dir tree_root
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
  # shellcheck source=/dev/null
  . "$self_dir/../../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || true
  tree_root=''
  if type gaia_resolve_tree_root >/dev/null 2>&1; then
    tree_root="$(gaia_resolve_tree_root 2>/dev/null)" || tree_root=''
  fi
  [ -n "$tree_root" ] || tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  local config_path="$tree_root/.gaia/automation.json"

  [ -f "$config_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local mode
  mode=$(jq -r --arg k "$config_key" '(.[$k].mode) // "local"' "$config_path" 2>/dev/null) || return 0

  if [ "$mode" = "ci" ]; then
    echo "$config_key is CI-managed; deferring"
    exit 0
  fi
}
