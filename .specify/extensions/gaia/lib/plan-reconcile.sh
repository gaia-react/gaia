#!/usr/bin/env bash
# plan-reconcile.sh: flip a PLAN-NNN plans-ledger row to "merged" at
# orchestrator-confirmed merge. The plan-side counterpart to spec-reconcile.sh,
# but orchestrator-driven: the merge is already confirmed and the plan_id is
# known, so there is NO gh/PR scan. It decouples the status advance from the
# folder delete, so a PLAN-NNN row reaches "merged" even when plan-archive.sh
# gates the delete off. Best-effort, fail-open, ALWAYS exit 0. Idempotent.
#
# Usage: plan-reconcile.sh <repo_root> <plan_id>
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: plan-reconcile.sh <repo_root> <plan_id>" >&2
  exit 0
fi
repo_root="${1%/}"
plan_id="$2"
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only reconcile a real PLAN-NNN id (a free-form slug has no plans-ledger row).
case "$plan_id" in
  PLAN-*)
    plan_number="${plan_id#PLAN-}"
    case "$plan_number" in ''|*[!0-9]*) echo "plan-reconcile: $plan_id not PLAN-NNN; nothing to do" >&2; exit 0 ;; esac
    ;;
  *) echo "plan-reconcile: $plan_id not PLAN-NNN; nothing to do" >&2; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
patch="$(jq -nc --arg timestamp "$now" '{status: "merged", merged_at: $timestamp}')"
if bash "${_library_directory}/plan-ledger-update.sh" "$repo_root" "$plan_id" "$patch" >/dev/null 2>&1; then
  printf 'reconciled %s -> merged\n' "$plan_id"
else
  echo "plan-reconcile: could not advance $plan_id (missing ledger/row or lock timeout); left as-is" >&2
fi
exit 0
