#!/usr/bin/env bash
# spec-archive-merged.sh: delete a merged SPEC folder once its cost is fully
# represented in cost.jsonl. Run by the pre-flight sweep of /gaia-spec and
# /gaia-plan (.claude/skills/gaia/references/spec/lifecycle.md).
#
# Why this exists: a PR can merge out-of-band (the github.com button, another
# session), or the orchestrator can end before its post-merge close, so the
# SPEC folder lingers in the active specs dir with nothing to sweep it. This
# pass is that sweep, after the ledger row has been reconciled to merged.
#
# Sweep criteria, per row: a .gaia/local/specs/ledger.json row is a delete
# candidate when ALL hold:
#   - row status == "merged"
#   - an active artifact folder exists at .gaia/local/specs/<id>/ (the folder
#     is the deletion unit; siblings go with it)
#   - the folder holds no SPEC.md/AUDIT.md with an absent-or-empty
#     SUMMARY.md (the consolidation gate below); consolidation never ran, so
#     those layers are the sole record and are never destroyed
#   - the row's merged_at is parseable AND has aged past the retention window
#     (the age gate below); a missing or unparseable merged_at keeps the
#     folder rather than reading as infinitely old
# A merged row with no active folder (e.g. a pre-folder SPEC) is skipped.
#
# Age gate: a merged folder is kept until GAIA_SPEC_RETENTION_DAYS (default
# 30; a non-numeric override falls back to 30) days have passed since the
# row's merged_at, so a just-merged SPEC survives for review instead of
# vanishing at merge. There is no early reap: --close is accepted and ignored.
#
# Consolidation gate: a folder that still holds SPEC.md or AUDIT.md with no
# non-empty SUMMARY.md has never been through consolidation, so those layers
# are its sole record and reaping them would be destructive. This delegates
# to .gaia/scripts/summary-verify.sh when present (exit 0 = well-formed);
# absent that script, a plain non-empty SUMMARY.md is the floor.
#
# Representation gate: once a candidate clears the age gate, this sources
# .gaia/scripts/cost-represented.sh and asks whether every cost.md phase
# section under the folder is already captured, value for value, in the
# main-checkout cost.jsonl (resolved via .gaia/scripts/ledger-path-lib.sh). Any
# non-zero verdict blocks that one id: the folder is left in place for review,
# and the sweep moves on to the next candidate.
#
# The ledger row's merged/merged_at stamp is a precondition set upstream (git
# reconcile), not by this sweep, and stays untouched; it
# is the identity record that survives once the folder is gone.
#
# On a successful delete this reaps the SPEC's cache keyset (gate1/draft/
# session/lock/audit), best-effort.
#
# Best-effort and fail-open by contract, exactly like spec-reconcile.sh: a
# missing jq / ledger or an unrepresented cost never blocks a caller. One
# stdout line summarizes what was deleted; diagnostics go to stderr.
#
# Usage:
#   spec-archive-merged.sh <repo_root> [<spec_id>] [--close]
# With <spec_id>, only that id is considered. With no id, every merged row is
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
  echo "usage: spec-archive-merged.sh <repo_root> [<spec_id>] [--close]" >&2
  exit 0
fi

repo_root="${args[0]%/}"
filter_id="${args[1]:-}"

# Retention knob, read once: a non-numeric override falls back to the default.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

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

# Source the shared ledger-path lib from this script's own directory, never
# through repo_root: repo_root is the value whose trustworthiness is in
# question here, so loading a library by it would decide correctness with the
# input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ledger-path-lib.sh
. "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || true
# The age test lives in ledger-lib.sh. Loaded bracketed against an unparseable
# copy; without it no age can be judged, and an unknown age must never read as
# past the window, so the sweep reaps nothing.
# shellcheck source=ledger-lib.sh
set +e; [ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null; set -e
if ! type gaia_ledger_age_past_window >/dev/null 2>&1; then
  echo "spec-archive-merged: ledger-lib.sh is unusable; nothing swept" >&2
  exit 0
fi

# repo_root names the tree this sweep runs in; the ledger and folders it
# sweeps are main's, because the state registry declares specs/ main-only.
# Best-effort by contract: an unresolvable main is one diagnostic and exit 0,
# nothing touched.
if ! specs_directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || [ -z "$specs_directory" ]; then
  echo "spec-archive-merged: cannot resolve the main checkout for '$repo_root'; nothing swept" >&2
  exit 0
fi
ledger_path="${specs_directory}/ledger.json"

# No ledger or no jq → nothing to do. (No git needed for the delete itself:
# specs are local/gitignored, so it is a plain filesystem rm, never a git op.)
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=../cost-represented.sh
. "${repo_root}/.gaia/scripts/cost-represented.sh" 2>/dev/null || true

# Resolve the main-checkout cost ledger from repo_root's own git identity,
# never the caller's cwd (a subshell cd keeps this script's cwd unchanged).
cost_ledger="$(cd "$repo_root" 2>/dev/null && gaia_resolve_ledger_path 2>/dev/null || true)"

# Candidate rows (local, cheap): merged but possibly still in the active dir.
# An optional single-id filter narrows the sweep to one row.
if [ -n "$filter_id" ]; then
  merged_ids="$(jq -r --arg id "$filter_id" \
    '.specs[] | select(.status == "merged" and .id == $id) | .id' \
    "$ledger_path" 2>/dev/null || true)"
else
  merged_ids="$(jq -r '.specs[] | select(.status == "merged") | .id' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$merged_ids" ] || exit 0

deleted_list=""

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue

  folder="${specs_directory}/${spec_id}"
  # Skip merged rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Consolidation gate: a folder still holding SPEC.md/AUDIT.md with no
  # consolidated SUMMARY.md is never reaped; those layers are its sole record.
  if ! _consolidation_gate_pass "$folder"; then
    echo "spec-archive-merged: consolidation never ran; kept $spec_id" >&2
    continue
  fi

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # merged_at keeps the folder (fail-closed). No caller bypasses it.
  merged_at="$(jq -r --arg id "$spec_id" '.specs[] | select(.id==$id) | .merged_at // ""' "$ledger_path" 2>/dev/null || true)"
  if ! gaia_ledger_age_past_window "$merged_at" "$now_epoch" "$retention_days"; then
    echo "spec-archive-merged: $spec_id within retention window (or merged_at missing/unparseable); kept" >&2
    continue
  fi

  # Representation gate: refuse to delete a folder whose cost.md sections are
  # not fully accounted for in cost.jsonl. Any non-zero verdict, including an
  # unresolved cost ledger, blocks this id and leaves the folder untouched.
  gate_status=2
  if [ -n "$cost_ledger" ] && declare -f cost_folder_represented >/dev/null 2>&1; then
    cost_folder_represented "$folder" spec_id "$spec_id" "$cost_ledger" >/dev/null 2>&1
    gate_status=$?
  fi
  if [ "$gate_status" -ne 0 ]; then
    echo "spec-archive-merged: cost not fully represented in cost.jsonl; left $spec_id folder for review" >&2
    continue
  fi

  # Reap the merged SPEC's cache keyset (gate1/draft/session/lock/audit).
  # Best-effort and fail-open, matching the rest of this script's contract. A merged SPEC's
  # authoring session is long over, so its lock is stale by definition.
  local_cache="${repo_root}/.gaia/local/cache"
  rm -f "${local_cache}/gate1-${spec_id}.json" \
        "${local_cache}/draft-${spec_id}.md" \
        "${local_cache}/spec-session-${spec_id}.json" \
        "${local_cache}/spec-session-${spec_id}.lock" 2>/dev/null
  rm -rf "${local_cache}/audit-${spec_id}" 2>/dev/null

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "spec-archive-merged: $spec_id folder delete failed; left active folder in place" >&2
    continue
  fi

  deleted_list="${deleted_list:+$deleted_list, }${spec_id}"
done <<EOF
$merged_ids
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s merged SPEC folder(s): %s\n' "$count" "$deleted_list"

exit 0
