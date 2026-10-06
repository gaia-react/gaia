#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted jq filters where $s and friends
# are jq bindings, not shell variables.
# shellcheck disable=SC2016
# ledger-status-migrate.sh: one-time, idempotent, best-effort migration of
# .gaia/local/specs/ledger.json and .gaia/local/plans/ledger.json rows onto the
# unified status vocabulary (draft|ready|merged|abandoned).
#
# Usage: ledger-status-migrate.sh <repo_root>
#
# Status map (rewrites .status only): specified|in-progress|allocated -> ready;
# completed|archived -> merged; merged|draft|abandoned pass through unchanged.
# On the plans ledger only, a row carrying completed_at is additionally renamed
# to merged_at (completed_at deleted); source is never touched (it is not named
# anywhere in the jq, so it cannot be rewritten).
#
# Each ledger's read-modify-write runs inside the shared mutex
# (with-ledger-lock.sh) so it serializes against the per-row chokepoints
# (ledger-update.sh, plan-ledger-update.sh, spec-allocator.sh, plan-allocator.sh)
# writing the same file. Idempotent: a row already in the unified vocabulary
# with no completed_at maps to itself, so a second run leaves the ledger
# byte-identical.
#
# Best-effort / advisory: exits 0 always. A missing jq, missing lock helper, or
# missing ledger degrades to a silent no-op for that ledger; a jq failure leaves
# that ledger untouched. stdout carries one summary line per ledger, only when
# it changed something; all diagnostics go to stderr.
set -uo pipefail

log() {
  printf '%s\n' "$*" >&2
}

if [ "$#" -ne 1 ]; then
  log "usage: ledger-status-migrate.sh <repo_root>"
  exit 0
fi

repo_root="${1%/}"

if ! command -v jq >/dev/null 2>&1; then
  log "ledger-status-migrate: jq not found; skipping"
  exit 0
fi

# shellcheck source=.gaia/scripts/spec/with-ledger-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/spec/with-ledger-lock.sh" 2>/dev/null || true
if ! declare -f with_ledger_lock >/dev/null 2>&1; then
  log "ledger-status-migrate: with-ledger-lock.sh unavailable; skipping"
  exit 0
fi

specs_ledger="$repo_root/.gaia/local/specs/ledger.json"
plans_ledger="$repo_root/.gaia/local/plans/ledger.json"

# Rows whose .status is one of the retired values this run would remap. Used
# only to size the printed summary; the jq rewrite below is the source of
# truth for what actually changes.
retired_status_predicate='.status as $status | (["specified","in-progress","allocated","completed","archived"] | index($status)) != null'

# migrate_specs: jq-to-temporary-file-then-mv rewrite of specs_ledger's .status through the
# unified map. No field rename here (specs already key on merged_at).
# shellcheck disable=SC2329  # invoked indirectly via `with_ledger_lock ... migrate_specs`
migrate_specs() {
  local temporary_file
  temporary_file="$(mktemp)"
  if ! jq '
    def migrated_status: {"specified":"ready","in-progress":"ready","allocated":"ready",
            "completed":"merged","archived":"merged"};
    .specs |= map(.status = (migrated_status[.status] // .status))
  ' "$specs_ledger" > "$temporary_file" 2>/dev/null; then
    rm -f "$temporary_file"
    log "ledger-status-migrate: jq failed on $specs_ledger; skipping"
    return 1
  fi
  mv "$temporary_file" "$specs_ledger"
}

# migrate_plans: jq-to-temporary-file-then-mv rewrite of plans_ledger's .status through the
# same map, plus completed_at -> merged_at on any row that still carries it.
# source is never named in the jq, so it passes through byte-unchanged.
# shellcheck disable=SC2329  # invoked indirectly via `with_ledger_lock ... migrate_plans`
migrate_plans() {
  local temporary_file
  temporary_file="$(mktemp)"
  if ! jq '
    def migrated_status: {"specified":"ready","in-progress":"ready","allocated":"ready",
            "completed":"merged","archived":"merged"};
    .plans |= map(
      .status = (migrated_status[.status] // .status)
      | if has("completed_at")
        then .merged_at = (.merged_at // .completed_at) | del(.completed_at)
        else . end
    )
  ' "$plans_ledger" > "$temporary_file" 2>/dev/null; then
    rm -f "$temporary_file"
    log "ledger-status-migrate: jq failed on $plans_ledger; skipping"
    return 1
  fi
  mv "$temporary_file" "$plans_ledger"
}

if [ -f "$specs_ledger" ]; then
  specs_to_migrate_count="$(jq "[.specs[]? | select($retired_status_predicate)] | length" "$specs_ledger" 2>/dev/null)"
  specs_to_migrate_count="${specs_to_migrate_count:-0}"
  if with_ledger_lock "$repo_root/.gaia/local/specs" migrate_specs && [ "$specs_to_migrate_count" -gt 0 ]; then
    printf 'migrated %s specs row(s)\n' "$specs_to_migrate_count"
  fi
fi

if [ -f "$plans_ledger" ]; then
  plans_to_migrate_count="$(jq "[.plans[]? | select(($retired_status_predicate) or has(\"completed_at\"))] | length" "$plans_ledger" 2>/dev/null)"
  plans_to_migrate_count="${plans_to_migrate_count:-0}"
  if with_ledger_lock "$repo_root/.gaia/local/plans" migrate_plans && [ "$plans_to_migrate_count" -gt 0 ]; then
    printf 'migrated %s plans row(s)\n' "$plans_to_migrate_count"
  fi
fi

exit 0
