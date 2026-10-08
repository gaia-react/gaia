#!/usr/bin/env bash
# plan-archive-merged.sh: delete a merged spec-less PLAN-NNN folder once its
# cost is fully represented in cost.jsonl. The plans-side mirror of
# spec-archive-merged.sh, run by the pre-flight sweep of /gaia-spec and
# /gaia-plan (.claude/skills/gaia/references/spec/lifecycle.md).
#
# Why this exists: the orchestrator's post-merge close reduces a plan folder to
# SUMMARY.md + cost.json, but a PR can merge out-of-band (the github.com
# button, another session), or the orchestrator can end before its close, so
# the PLAN-NNN folder lingers in the active plans dir with nothing to sweep
# it. This pass is that sweep.
#
# Sweep criteria, per row: a .gaia/local/plans/ledger.json row is a delete
# candidate when ALL hold:
#   - the row is a merged row on one of two arms:
#       confirmed arm: a non-empty pr_number (stamped by the orchestrator's
#         post-merge close, or by plan-reconcile.sh's scan, which matches a
#         merged PR by plan number and creation time, not by confirmed
#         identity) and a parseable merged_at that has aged past the
#         retention window
#       legacy arm: no pr_number, status == "merged", and a parseable
#         merged_at that has aged past the same window; rows written before
#         pr_number existed age out here
#     A row whose status is not "merged", or whose merged_at is missing or
#     unparseable, is never a candidate on either arm.
#   - an active artifact folder exists at .gaia/local/plans/<id>/ (the folder
#     is the deletion unit; siblings go with it)
#   - the folder holds a well-formed SUMMARY.md (the consolidation gate
#     below); a folder with an absent, empty or malformed SUMMARY.md never
#     went through consolidation, so whatever it holds is the sole record and
#     is never destroyed
# A merged row with no active folder (already gone, or never had one) is
# skipped.
#
# Age gate: a merged folder is kept until GAIA_SPEC_RETENTION_DAYS (default
# 30; a non-numeric override falls back to 30) days have passed since the
# row's merged_at, the SAME single knob spec-archive-merged.sh reads, so a
# just-merged plan survives for review instead of vanishing at merge. There
# is no early reap: --close is accepted and ignored. A missing or unparseable
# merged_at keeps the folder rather than reading as infinitely old.
#
# Consolidation gate: a folder with no verified SUMMARY.md has never been
# through consolidation (a plan that was never executed holds only its plan
# files), so its contents are the sole record and reaping them would be
# destructive.
# This delegates to .gaia/scripts/summary-verify.sh when present (exit 0 =
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
# The ledger row's merged/merged_at/pr_number stamp is a precondition set
# upstream (the orchestrator's post-merge close, or plan-reconcile.sh's scan),
# not by this sweep, and stays untouched; it is the identity record that
# survives once the folder is gone.
#
# Best-effort and fail-open by contract, exactly like spec-archive-merged.sh:
# a missing jq / ledger or an unrepresented cost never blocks a caller. One
# stdout line summarizes what was deleted; diagnostics go to stderr.
#
# Usage:
#   plan-archive-merged.sh <repo_root> [<plan_id>] [--close]
# With <plan_id>, only that id is considered. With no id, every merged row is
# swept. --close is accepted and ignored.
#
# Exit: always 0 (advisory).
set -uo pipefail

args=()
for argument in "$@"; do
  case "$argument" in
    --*) ;; # --close and unknown flags tolerated, ignored
    *) args+=("$argument") ;;
  esac
done

if [ "${#args[@]}" -lt 1 ]; then
  echo "usage: plan-archive-merged.sh <repo_root> [<plan_id>] [--close]" >&2
  exit 0
fi

repo_root="${args[0]%/}"
filter_id="${args[1]:-}"

# Retention knob, read once: a non-numeric override falls back to the default.
# The same GAIA_SPEC_RETENTION_DAYS knob spec-archive-merged.sh reads.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

# _consolidation_gate_pass <folder>: 0 iff the folder's SUMMARY.md is present
# and well-formed (consolidation ran). 1 keeps the folder: consolidation never
# produced a SUMMARY.md to replace its contents. Prefers summary-verify.sh when
# present; falls back to a plain non-empty-file check.
_consolidation_gate_pass() {
  local folder="$1"
  local summary="${folder}/SUMMARY.md" verify="${repo_root}/.gaia/scripts/summary-verify.sh"
  if [ -f "$verify" ]; then
    bash "$verify" "$summary" >/dev/null 2>&1
    return $?
  fi
  [ -s "$summary" ]
}

# No jq -> nothing to do (checked first: cheap, and every other gate needs it).
command -v jq >/dev/null 2>&1 || exit 0

_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cost-represented.sh
. "${repo_root}/.gaia/scripts/cost-represented.sh" 2>/dev/null || true
# shellcheck source=../ledger-path-lib.sh
. "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || true
# The age test lives in ledger-lib.sh. Loaded bracketed against an unparseable
# copy; without it no age can be judged, and an unknown age must never read as
# past the window, so the sweep reaps nothing.
# shellcheck source=ledger-lib.sh
[ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null || true
if ! type gaia_ledger_age_past_window >/dev/null 2>&1; then
  echo "plan-archive-merged: ledger-lib.sh is unusable; nothing swept" >&2
  exit 0
fi

# repo_root names the tree this sweep runs in; the ledger and plan folders it
# reads are main's, because the state registry declares plans/ main-only.
# Resolve rather than trust a per-tree fallback: best-effort sweep, so an
# unresolvable main root is one stderr diagnostic and exit 0 (this script's
# own fail-open contract), never a silent fallback to the unresolved operand
# -- that fallback is the forked-ledger defect this task removes. Resolving
# still needs git; the delete itself remains a plain filesystem rm, never a
# git op (plans are local/gitignored).
if ! plans_directory="$(gaia_resolve_plans_directory "$repo_root" 2>/dev/null)" || [ -z "$plans_directory" ]; then
  echo "plan-archive-merged: cannot resolve the main checkout for '$repo_root'; skipping sweep" >&2
  exit 0
fi
ledger_path="${plans_directory}/ledger.json"

# No ledger -> nothing to do.
[ -f "$ledger_path" ] || exit 0

# Resolve the main-checkout cost ledger from repo_root's own git identity,
# never the caller's cwd (a subshell cd keeps this script's cwd unchanged).
cost_ledger="$(cd "$repo_root" 2>/dev/null && gaia_resolve_ledger_path 2>/dev/null || true)"

# Candidate rows (local, cheap): merged rows. The confirmed arm (a pr_number)
# and the legacy arm (none) share every gate and differ only in provenance, so
# one select covers both; the age gate below requires a parseable, aged
# merged_at of each. An optional
# single-id filter narrows the sweep to one row. Each candidate prints as
# "<id><TAB><merged_at>".
if [ -n "$filter_id" ]; then
  merged_rows="$(jq -r --arg id "$filter_id" \
    '.plans[] | select(.status == "merged" and .id == $id) | "\(.id)\t\(.merged_at // "")"' \
    "$ledger_path" 2>/dev/null || true)"
else
  merged_rows="$(jq -r '.plans[] | select(.status == "merged") | "\(.id)\t\(.merged_at // "")"' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$merged_rows" ] || exit 0

deleted_list=""

while IFS='	' read -r plan_id merged_at; do
  [ -n "$plan_id" ] || continue

  folder="${plans_directory}/${plan_id}"
  # Skip merged rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Consolidation gate: a folder with no consolidated SUMMARY.md is never
  # reaped; its contents are the sole record.
  if ! _consolidation_gate_pass "$folder"; then
    echo "plan-archive-merged: consolidation never ran; kept $plan_id" >&2
    continue
  fi

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # merged_at keeps the folder (fail-closed). No caller bypasses it.
  if ! gaia_ledger_age_past_window "$merged_at" "$now_epoch" "$retention_days"; then
    echo "plan-archive-merged: $plan_id within retention window (or merged_at missing/unparseable); kept" >&2
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
    echo "plan-archive-merged: cost not fully represented in cost.jsonl; left $plan_id folder for review" >&2
    continue
  fi

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "plan-archive-merged: $plan_id folder delete failed; left active folder in place" >&2
    continue
  fi

  deleted_list="${deleted_list:+$deleted_list, }${plan_id}"
done <<EOF
$merged_rows
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s merged plan folder(s): %s\n' "$count" "$deleted_list"

exit 0
