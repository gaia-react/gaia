#!/usr/bin/env bash
# plan-archive-abandoned.sh: delete an abandoned spec-less PLAN-NNN folder
# once its abandoned_at has aged past the retention window and its cost is
# fully represented in cost.jsonl. The abandoned-status counterpart to
# plan-archive-merged.sh, the plans-side mirror of spec-archive-abandoned.sh.
#
# Why this exists: `abandoned` is a canonical plan-ledger status
# (plan-ledger-update.sh), but no shipped code path stamps it today, so a
# .gaia/local/plans/PLAN-NNN/ row can sit at `abandoned` with no reap path at
# all, unlike a merged row, which sweep 3's plan-archive.sh delegation reduces
# and this sweep's merged sibling eventually deletes. This script closes that
# gap so the first write path that adopts the status inherits a working reap.
#
# Sweep criteria, per row: a .gaia/local/plans/ledger.json row is a delete
# candidate when ALL hold:
#   - row status == "abandoned"
#   - an active artifact folder exists at .gaia/local/plans/<id>/
#   - the row's abandoned_at is parseable AND has aged past the retention
#     window (GAIA_SPEC_RETENTION_DAYS, default 30; the same knob and default
#     as plan-archive-merged.sh); a missing or unparseable abandoned_at never
#     reads as infinitely old, so it keeps the folder rather than authorizing
#     a delete
#   - the folder's cost is fully represented in cost.jsonl
#     (cost_folder_represented, the same fail-closed gate plan-archive-merged.sh
#     uses; a folder with no cost.md/cost.json at all is automatically
#     represented, nothing to lose)
# An abandoned row with no active folder is skipped.
#
# Unlike the merged path, there is no consolidation gate: nothing ever
# promotes an abandoned plan's content into the wiki, so the whole folder
# reaps as one unit once it clears the age and cost gates. A dangling
# wiki-promote drain cache (.gaia/local/cache/wiki-promote/<id>.json) is
# purged rather than guarded on, since there is no close flow left to drain
# it and no merge left to wait for. There is no plan-scoped gate1-/draft-/
# session-lock cache namespace to purge, mirroring plan-archive-merged.sh's
# own note.
#
# Best-effort and fail-open, exactly like plan-archive-merged.sh: a missing
# jq / ledger or an unrepresented cost never blocks a caller. One stdout line
# summarizes what was deleted; diagnostics go to stderr.
#
# Usage:
#   plan-archive-abandoned.sh <repo_root> [<plan_id>]
# With <plan_id>, only that id is considered. With no id, every abandoned row
# is swept.
#
# Exit: always 0 (advisory).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: plan-archive-abandoned.sh <repo_root> [<plan_id>]" >&2
  exit 0
fi

repo_root="${1%/}"
filter_id="${2:-}"
ledger_path="${repo_root}/.gaia/local/plans/ledger.json"
plans_dir="${repo_root}/.gaia/local/plans"
cache_dir="${repo_root}/.gaia/local/cache/wiki-promote"

# Retention knob, shared with plan-archive-merged.sh: a non-numeric override
# falls back to the default.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

# _age_past_window <abandoned_at_iso>: 0 iff abandoned_at is parseable AND
# older than the retention window (reap-eligible). 1 iff missing /
# unparseable / within window (keep).
_age_past_window() {
  local iso="$1" abandoned_epoch age_days
  [ -n "$iso" ] || return 1
  abandoned_epoch="$(jq -rn --arg t "$iso" '($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)' 2>/dev/null || true)"
  case "$abandoned_epoch" in '' | *[!0-9]*) return 1 ;; esac
  [ "$now_epoch" -gt 0 ] || return 1
  age_days=$(( (now_epoch - abandoned_epoch) / 86400 ))
  [ "$age_days" -ge "$retention_days" ] && return 0 || return 1
}

# No ledger or no jq → nothing to do. (No git needed for the delete itself:
# plans are local/gitignored, so it is a plain filesystem rm, never a git op.)
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=../../../../.gaia/scripts/cost-represented.sh
. "${repo_root}/.gaia/scripts/cost-represented.sh" 2>/dev/null || true
# shellcheck source=../../../../.gaia/scripts/ledger-path-lib.sh
. "${repo_root}/.gaia/scripts/ledger-path-lib.sh" 2>/dev/null || true

# Resolve the main-checkout cost ledger from repo_root's own git identity,
# never the caller's cwd (a subshell cd keeps this script's cwd unchanged).
cost_ledger="$(cd "$repo_root" 2>/dev/null && gaia_resolve_ledger_path 2>/dev/null || true)"

# Candidate rows (local, cheap): abandoned but possibly still in the active
# dir. An optional single-id filter narrows the sweep to one row.
if [ -n "$filter_id" ]; then
  abandoned_ids="$(jq -r --arg id "$filter_id" \
    '.plans[] | select(.status == "abandoned" and .id == $id) | .id' \
    "$ledger_path" 2>/dev/null || true)"
else
  abandoned_ids="$(jq -r '.plans[] | select(.status == "abandoned") | .id' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$abandoned_ids" ] || exit 0

deleted_list=""

while IFS= read -r plan_id; do
  [ -n "$plan_id" ] || continue

  folder="${plans_dir}/${plan_id}"
  # Skip abandoned rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # abandoned_at keeps the folder (fail-closed).
  abandoned_at="$(jq -r --arg id "$plan_id" '.plans[] | select(.id==$id) | .abandoned_at // ""' "$ledger_path" 2>/dev/null || true)"
  if ! _age_past_window "$abandoned_at"; then
    echo "plan-archive-abandoned: $plan_id within retention window (or abandoned_at missing/unparseable); kept" >&2
    continue
  fi

  # Representation gate: refuse to delete a folder whose cost is not fully
  # accounted for in cost.jsonl. Any non-zero verdict, including an unresolved
  # cost ledger, blocks this id and leaves the folder untouched.
  gate_status=2
  if [ -n "$cost_ledger" ] && declare -f cost_folder_represented >/dev/null 2>&1; then
    cost_folder_represented "$folder" plan_id "$plan_id" "$cost_ledger" >/dev/null 2>&1
    gate_status=$?
  fi
  if [ "$gate_status" -ne 0 ]; then
    echo "plan-archive-abandoned: cost not fully represented in cost.jsonl; left $plan_id folder for review" >&2
    continue
  fi

  # Reap the dangling wiki-promote drain cache too: an abandoned plan is never
  # promoted anywhere, so there is no close flow left to drain it. Best-effort
  # and fail-open, matching the rest of this script's contract.
  rm -f "${cache_dir}/${plan_id}.json" 2>/dev/null

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "plan-archive-abandoned: $plan_id folder delete failed; left active folder in place" >&2
    continue
  fi

  deleted_list="${deleted_list:+$deleted_list, }${plan_id}"
done <<EOF
$abandoned_ids
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s abandoned plan folder(s): %s\n' "$count" "$deleted_list"

exit 0
