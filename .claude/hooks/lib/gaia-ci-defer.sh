#!/usr/bin/env bash
# GAIA CI deferral helper. Source this from any local automatic trigger that
# wants to honor the per-tool ci/local/off mode in .gaia/automation.json.
# When the matching config entry has mode == "ci", emit a one-line log and
# exit 0. Otherwise return without side effects so the caller continues.
#
# The argument is the snake_case CONFIG KEY from the automation schema —
# the same identifier used as the top-level field in .gaia/automation.json
# (e.g. `wiki`, `pnpm_audit`, `stale_branches`, `sharpen`, `update_gaia`).
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
  local config_path=".gaia/automation.json"

  [ -f "$config_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local mode
  mode=$(jq -r --arg k "$config_key" '(.[$k].mode) // "local"' "$config_path" 2>/dev/null) || return 0

  if [ "$mode" = "ci" ]; then
    echo "$config_key is CI-managed; deferring"
    exit 0
  fi
}
