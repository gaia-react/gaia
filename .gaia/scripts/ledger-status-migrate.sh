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

# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true
if ! declare -f with_ledger_lock >/dev/null 2>&1; then
  log "ledger-status-migrate: with-ledger-lock.sh unavailable; skipping"
  exit 0
fi

specs_ledger="$repo_root/.gaia/local/specs/ledger.json"
plans_ledger="$repo_root/.gaia/local/plans/ledger.json"

# Rows whose .status is one of the retired values this run would remap. Used
# only to size the printed summary; the jq rewrite below is the source of
# truth for what actually changes.
retired_status_pred='.status as $s | (["specified","in-progress","allocated","completed","archived"] | index($s)) != null'

# migrate_specs: jq-to-tmp-then-mv rewrite of specs_ledger's .status through the
# unified map. No field rename here (specs already key on merged_at).
# shellcheck disable=SC2329  # invoked indirectly via `with_ledger_lock ... migrate_specs`
migrate_specs() {
  local tmp
  tmp="$(mktemp)"
  if ! jq '
    def m: {"specified":"ready","in-progress":"ready","allocated":"ready",
            "completed":"merged","archived":"merged"};
    .specs |= map(.status = (m[.status] // .status))
  ' "$specs_ledger" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log "ledger-status-migrate: jq failed on $specs_ledger; skipping"
    return 1
  fi
  mv "$tmp" "$specs_ledger"
}

# migrate_plans: jq-to-tmp-then-mv rewrite of plans_ledger's .status through the
# same map, plus completed_at -> merged_at on any row that still carries it.
# source is never named in the jq, so it passes through byte-unchanged.
# shellcheck disable=SC2329  # invoked indirectly via `with_ledger_lock ... migrate_plans`
migrate_plans() {
  local tmp
  tmp="$(mktemp)"
  if ! jq '
    def m: {"specified":"ready","in-progress":"ready","allocated":"ready",
            "completed":"merged","archived":"merged"};
    .plans |= map(
      .status = (m[.status] // .status)
      | if has("completed_at")
        then .merged_at = (.merged_at // .completed_at) | del(.completed_at)
        else . end
    )
  ' "$plans_ledger" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log "ledger-status-migrate: jq failed on $plans_ledger; skipping"
    return 1
  fi
  mv "$tmp" "$plans_ledger"
}

if [ -f "$specs_ledger" ]; then
  n_specs="$(jq "[.specs[]? | select($retired_status_pred)] | length" "$specs_ledger" 2>/dev/null)"
  n_specs="${n_specs:-0}"
  if with_ledger_lock "$repo_root/.gaia/local/specs" migrate_specs && [ "$n_specs" -gt 0 ]; then
    printf 'migrated %s specs row(s)\n' "$n_specs"
  fi
fi

if [ -f "$plans_ledger" ]; then
  n_plans="$(jq "[.plans[]? | select(($retired_status_pred) or has(\"completed_at\"))] | length" "$plans_ledger" 2>/dev/null)"
  n_plans="${n_plans:-0}"
  if with_ledger_lock "$repo_root/.gaia/local/plans" migrate_plans && [ "$n_plans" -gt 0 ]; then
    printf 'migrated %s plans row(s)\n' "$n_plans"
  fi
fi

exit 0
