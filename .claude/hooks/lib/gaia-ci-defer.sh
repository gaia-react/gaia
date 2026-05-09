#!/usr/bin/env bash
# GAIA CI deferral helper. Source this from any local automatic wiki trigger.
# When .gaia/automation.json says wiki.mode == "ci", emit a one-line log and
# exit 0. Otherwise return without side effects so the caller continues.
#
# Usage (from a hook script):
#   . .claude/hooks/lib/gaia-ci-defer.sh
#   gaia_ci_defer_if_managed wiki   # exits 0 if managed; returns if not.
#
# Sourcing a function (rather than a top-level guard) lets the caller run its
# own pre-flight (jq presence, .git presence, payload reads) before deciding
# when to check deferral.

gaia_ci_defer_if_managed() {
  local tool="$1"
  local config_path=".gaia/automation.json"

  [ -f "$config_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local mode
  mode=$(jq -r --arg t "$tool" '(.[$t].mode) // "local"' "$config_path" 2>/dev/null) || return 0

  if [ "$mode" = "ci" ]; then
    echo 'wiki is CI-managed; deferring'
    exit 0
  fi
}
