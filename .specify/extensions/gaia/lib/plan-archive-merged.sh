#!/usr/bin/env bash
# plan-archive-merged.sh: delete a merged spec-less PLAN-NNN folder once its
# cost is fully represented in cost.jsonl. Safety net for the plan close flow,
# the plans-side mirror of spec-archive-merged.sh.
#
# Why this exists: deletion normally happens through the plan close command,
# which drains any deferred wiki-promote, flips the plans-ledger row to
# merged, then delegates the actual delete to this script for one id. But a
# PR can merge out-of-band (the github.com button, another session), so the
# PLAN-NNN folder lingers in the active plans dir with nothing to sweep it.
# This pass is that sweep, and the close command's own single-id delete
# reuses it too, so the gate and pacing append live in one place.
#
# Sweep criteria, per row: a .gaia/local/plans/ledger.json row is a delete
# candidate when ALL hold:
#   - row status == "merged"
#   - an active artifact folder exists at .gaia/local/plans/<id>/ (the folder
#     is the deletion unit; siblings go with it). By the time a plan reaches
#     this sweep it has already been reduced to SUMMARY.md + cost.json by
#     plan-archive.sh, so the reap removes the whole PLAN-NNN folder.
#   - NO pending wiki-promote drain cache at
#     .gaia/local/cache/wiki-promote/<id>.json (those have not promoted their
#     wiki content yet; the close flow drains them, so leave them be)
#   - the folder holds no SPEC.md/AUDIT.md with an absent-or-empty
#     SUMMARY.md (the consolidation gate below); consolidation never ran, so
#     those layers are the sole record and are never destroyed
#   - the row's merged_at is parseable AND has aged past the retention window
#     (the age gate below), UNLESS the caller passes --close; a missing or
#     unparseable merged_at keeps the folder rather than reading as
#     infinitely old
# A merged row with no active folder (already gone, or never had one) is
# skipped.
#
# Age gate: a merged folder is kept until GAIA_SPEC_RETENTION_DAYS (default
# 30; a non-numeric override falls back to 30) days have passed since the
# row's merged_at, the SAME single knob spec-archive-merged.sh reads, so a
# just-merged plan survives for review instead of vanishing at merge. The
# gate lives here so every caller inherits it: the janitor's SessionStart
# sweep and the plan-close single-id delegate. --close bypasses ONLY this
# gate (early-reap at close, once the caller has already confirmed the
# merge); every other gate still applies.
#
# Consolidation gate: a folder that still holds SPEC.md or AUDIT.md with no
# non-empty SUMMARY.md has never been through consolidation, so those layers
# are its sole record and reaping them would be destructive (defensive here;
# a spec-less plan folder does not normally carry SPEC.md/AUDIT.md). This
# delegates to .gaia/scripts/summary-verify.sh when present (exit 0 =
# well-formed); absent that script, a plain non-empty SUMMARY.md is the
# floor.
#
# Representation gate: once a candidate clears the age gate, this sources
# .gaia/scripts/cost-represented.sh and asks whether every cost record under
# the folder is already captured, value for value, in the main-checkout
# cost.jsonl (resolved via .gaia/scripts/ledger-path-lib.sh), keyed on
# plan_id. Any non-zero verdict blocks that one id: the folder is left in
# place for review, and the sweep moves on to the next candidate.
#
# The ledger row's merged/merged_at stamp is a precondition set upstream
# (plan-archive.sh / the close command), not by this sweep, and stays
# untouched; it is the identity record that survives once the folder is
# gone.
#
# On a successful delete this appends a plan_closed telemetry event
# (disposition: delete), best-effort. There is no plan-scoped gate1-/draft-
# cache namespace to purge today; only the wiki-promote drain cache exists,
# and it is never purged here (guarded above).
#
# Best-effort and fail-open by contract, exactly like spec-archive-merged.sh:
# a missing jq / ledger, an unrepresented cost, or a telemetry-append failure
# never blocks a caller. One stdout line summarizes what was deleted;
# diagnostics go to stderr.
#
# Usage:
#   plan-archive-merged.sh <repo_root> [<plan_id>] [--close]
# With <plan_id>, only that id is considered (the close command's single-id
# delegate). With no id, every merged row is swept. --close bypasses the age
# gate for early-reap-at-close (plan-close.md's single-id delegate).
#
# Exit: always 0 (advisory).
set -uo pipefail

close_flag=0
args=()
for a in "$@"; do
  case "$a" in
    --close) close_flag=1 ;;
    --*) ;; # unknown flags tolerated
    *) args+=("$a") ;;
  esac
done

if [ "${#args[@]}" -lt 1 ]; then
  echo "usage: plan-archive-merged.sh <repo_root> [<plan_id>] [--close]" >&2
  exit 0
fi

repo_root="${args[0]%/}"
filter_id="${args[1]:-}"
ledger_path="${repo_root}/.gaia/local/plans/ledger.json"
plans_dir="${repo_root}/.gaia/local/plans"
cache_dir="${repo_root}/.gaia/local/cache/wiki-promote"
telemetry_path="${repo_root}/.gaia/local/telemetry/spec-pacing.jsonl"

# Retention knob, read once: a non-numeric override falls back to the default.
# The same GAIA_SPEC_RETENTION_DAYS knob spec-archive-merged.sh reads.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

# _age_past_window <merged_at_iso>: 0 iff merged_at is parseable AND older
# than the retention window (reap-eligible). 1 iff missing/unparseable/within
# window (keep). A missing or unparseable merged_at never reads as infinitely
# old, so it keeps the folder rather than authorizing a delete.
_age_past_window() {
  local iso="$1" merged_epoch age_days
  [ -n "$iso" ] || return 1
  merged_epoch="$(jq -rn --arg t "$iso" '($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)' 2>/dev/null || true)"
  case "$merged_epoch" in '' | *[!0-9]*) return 1 ;; esac
  [ "$now_epoch" -gt 0 ] || return 1
  age_days=$(( (now_epoch - merged_epoch) / 86400 ))
  [ "$age_days" -ge "$retention_days" ] && return 0 || return 1
}

# _consolidation_gate_pass <folder>: 0 iff the folder holds neither SPEC.md
# nor AUDIT.md, or its SUMMARY.md is present and well-formed (consolidation
# ran). 1 keeps the folder: those layers are its sole record and consolidation
# never produced a SUMMARY.md to replace them. Prefers summary-verify.sh when
# present; falls back to a plain non-empty-file check.
_consolidation_gate_pass() {
  local folder="$1"
  [ -f "${folder}/SPEC.md" ] || [ -f "${folder}/AUDIT.md" ] || return 0
  local summary="${folder}/SUMMARY.md" verify="${repo_root}/.gaia/scripts/summary-verify.sh"
  if [ -f "$verify" ]; then
    bash "$verify" "$summary" >/dev/null 2>&1
    return $?
  fi
  [ -s "$summary" ]
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

# Candidate rows (local, cheap): merged but possibly still in the active dir.
# An optional single-id filter narrows the sweep to one row.
if [ -n "$filter_id" ]; then
  merged_ids="$(jq -r --arg id "$filter_id" \
    '.plans[] | select(.status == "merged" and .id == $id) | .id' \
    "$ledger_path" 2>/dev/null || true)"
else
  merged_ids="$(jq -r '.plans[] | select(.status == "merged") | .id' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$merged_ids" ] || exit 0

now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
deleted_list=""

while IFS= read -r plan_id; do
  [ -n "$plan_id" ] || continue

  folder="${plans_dir}/${plan_id}"
  # Skip merged rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Leave plans whose wiki content has not been promoted yet; the close flow
  # owns their drain + disposition.
  [ -f "${cache_dir}/${plan_id}.json" ] && continue

  # Consolidation gate: a folder still holding SPEC.md/AUDIT.md with no
  # consolidated SUMMARY.md is never reaped; those layers are its sole record.
  if ! _consolidation_gate_pass "$folder"; then
    echo "plan-archive-merged: consolidation never ran; kept $plan_id" >&2
    continue
  fi

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # merged_at keeps the folder (fail-closed). --close bypasses this gate only.
  if [ "$close_flag" -ne 1 ]; then
    merged_at="$(jq -r --arg id "$plan_id" '.plans[] | select(.id==$id) | .merged_at // ""' "$ledger_path" 2>/dev/null || true)"
    if ! _age_past_window "$merged_at"; then
      echo "plan-archive-merged: $plan_id within retention window (or merged_at missing/unparseable); kept" >&2
      continue
    fi
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
    echo "plan-archive-merged: cost not fully represented in cost.jsonl; left $plan_id folder for review" >&2
    continue
  fi

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "plan-archive-merged: $plan_id folder delete failed; left active folder in place" >&2
    continue
  fi

  # Telemetry: a plan_closed event, mirroring spec-archive-merged.sh's own.
  # drained is always false here (plans with a pending drain cache are
  # skipped above). Failure to append never blocks the sweep.
  if ev="$(jq -nc --arg id "$plan_id" --arg ts "$now" \
      '{event: "plan_closed", plan_id: $id, disposition: "delete", drained: false, ts: $ts}' 2>/dev/null)"; then
    mkdir -p "$(dirname "$telemetry_path")" 2>/dev/null || true
    printf '%s\n' "$ev" >> "$telemetry_path" 2>/dev/null || true
  fi

  deleted_list="${deleted_list:+$deleted_list, }${plan_id}"
done <<EOF
$merged_ids
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s merged plan folder(s): %s\n' "$count" "$deleted_list"

exit 0
