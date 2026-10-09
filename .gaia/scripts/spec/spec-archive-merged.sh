#!/usr/bin/env bash
# spec-archive-merged.sh: delete a merged SPEC folder once the usage ledger
# records the runs the folder needs. Run by the pre-flight sweep of /gaia-spec and
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
# Usage-ledger gate: once a candidate clears the age gate, this asks
# `usage.sh represented` (against the main checkout's usage ledger) whether a
# close is recorded for spec:<id> under gaia-spec, and also under gaia-plan
# when the folder holds a plan or plan-<N> subfolder. Any non-zero verdict
# blocks that one id: the folder is left in place, one stdout keep line names
# the missing run and the `usage.sh record` recovery command, and the sweep
# moves on to the next candidate.
#
# The ledger row's merged/merged_at stamp is a precondition set upstream (git
# reconcile), not by this sweep, and stays untouched; it
# is the identity record that survives once the folder is gone.
#
# On a successful delete this reaps the SPEC's cache keyset (gate1/draft/
# session/lock/audit), best-effort.
#
# Best-effort and fail-open by contract, exactly like spec-reconcile.sh: a
# missing jq / ledger or an unrecorded run never blocks a caller. One stdout
# line summarizes what was deleted, and one names each kept folder;
# diagnostics go to stderr.
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

# Source the shared ledger-path and main-root libs from this script's own
# directory, never through repo_root: repo_root is the value whose
# trustworthiness is in question here, so loading a library by it would decide
# correctness with the input under test. A library that cannot load sweeps
# nothing.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ledger-path-lib.sh
. "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || {
  echo "spec-archive-merged: cannot load ${_library_directory}/../ledger-path-lib.sh; nothing swept" >&2
  exit 0
}
# shellcheck source=../main-root-lib.sh
. "${_library_directory}/../main-root-lib.sh" 2>/dev/null || {
  echo "spec-archive-merged: cannot load ${_library_directory}/../main-root-lib.sh; nothing swept" >&2
  exit 0
}
# The age test lives in ledger-lib.sh. Loaded bracketed against an unparseable
# copy; without it no age can be judged, and an unknown age must never read as
# past the window, so the sweep reaps nothing.
# shellcheck source=ledger-lib.sh
[ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null || true
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

# The usage ledger lives under the main checkout, resolved from repo_root's own
# git identity and never the caller's cwd. An unresolved root fails the gate
# closed: every candidate is kept.
main_root="$(gaia_resolve_main_root "$repo_root" 2>/dev/null || true)"

# _usage_gate <relative_folder> <ref> <workflow>: 0 when the usage ledger
# records a <workflow> close for <ref>. Otherwise prints the keep line for the
# folder on stdout and returns 1: the unreadable-ledger form when
# `usage.sh represented` exits 2 or the main checkout is unresolved, the
# no-run-recorded form for any other failure.
_usage_gate() {
  local relative_folder="$1" ref="$2" workflow="$3" gate_status=2 recovery_command
  recovery_command="outside a live ${workflow} run, record it: bash .gaia/scripts/usage.sh record ${ref} --workflow ${workflow} --start <iso>"
  if [ -n "$main_root" ]; then
    gate_status=0
    bash "${repo_root}/.gaia/scripts/usage.sh" represented "$ref" --workflow "$workflow" \
      --main-root "$main_root" </dev/null >/dev/null 2>&1 || gate_status=$?
  fi
  [ "$gate_status" -ne 0 ] || return 0
  if [ "$gate_status" -eq 2 ]; then
    printf 'Kept %s: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for %s; once it reads, %s\n' \
      "$relative_folder" "$ref" "$recovery_command"
  else
    printf 'Kept %s: no %s run recorded for %s; %s\n' \
      "$relative_folder" "$workflow" "$ref" "$recovery_command"
  fi
  return 1
}

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

  # Usage-ledger gate: refuse to delete a folder whose runs the usage ledger
  # does not record. Any non-zero verdict, including an unresolved main
  # checkout, blocks this id and leaves the folder untouched. A folder that
  # holds a plan or plan-<N> subfolder also needs its gaia-plan run recorded.
  if ! _usage_gate ".gaia/local/specs/${spec_id}" "spec:${spec_id}" gaia-spec; then
    continue
  fi
  holds_plan=0
  for plan_subfolder in "$folder"/plan "$folder"/plan-[0-9]*; do
    [ -d "$plan_subfolder" ] && holds_plan=1
  done
  if [ "$holds_plan" -eq 1 ] && ! _usage_gate ".gaia/local/specs/${spec_id}" "spec:${spec_id}" gaia-plan; then
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
