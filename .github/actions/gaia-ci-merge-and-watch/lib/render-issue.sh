#!/usr/bin/env bash
# Renders an issue body template by passing it through envsubst.
# Required env vars (caller sets via composite-action `env:`):
#   ORIGINAL_PR, ORIGINAL_TITLE, REVERT_PR, MERGE_SHA, FAILED_RUN_URL,
#   WORKFLOW_NAME, REVERT_FAILED_RUN_URL (latter empty for priority:high).
#
# Args:
#   $1 — path to the template (.md file using ${VAR} placeholders).
#
# stdout: rendered body. The composite action pipes it to
#   `gh issue create --body-file -`.

set -euo pipefail

TEMPLATE="${1:?template path required}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "render-issue: template not found: $TEMPLATE" >&2
  exit 1
fi

# Expand only the known set of variables to prevent accidental token injection
# from variables in user-controlled fields (PR title, workflow name, etc).
envsubst '${ORIGINAL_PR},${ORIGINAL_TITLE},${REVERT_PR},${MERGE_SHA},${FAILED_RUN_URL},${WORKFLOW_NAME},${REVERT_FAILED_RUN_URL}' < "$TEMPLATE"
