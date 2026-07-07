#!/usr/bin/env bash
# spec-archive-merged.sh: delete a merged SPEC folder once its cost is fully
# represented in cost.jsonl. Safety net for the SPEC close flow.
#
# Why this exists: deletion normally happens through the SPEC close command,
# which drains any deferred wiki-promote, flips the ledger row to merged, then
# delegates the actual delete to this script for one id. But a PR can merge
# out-of-band (the github.com button, another session), so the SPEC folder
# lingers in the active specs dir with nothing to sweep it. This pass is that
# sweep, and the close command's own single-id delete reuses it too, so the
# gate, cache purge, telemetry, and compute-profile chain live in one place.
#
# Sweep criteria, per row: a .gaia/local/specs/ledger.json row is a delete
# candidate when ALL hold:
#   - row status == "merged"
#   - an active artifact folder exists at .gaia/local/specs/<id>/ (the folder
#     is the deletion unit; siblings go with it)
#   - NO pending wiki-promote drain cache at
#     .gaia/local/cache/wiki-promote/<id>.json (those have not promoted their
#     wiki content yet; the close flow drains them, so leave them be)
#   - the row's merged_at is parseable AND has aged past the retention window
#     (the age gate below); a missing or unparseable merged_at keeps the
#     folder rather than reading as infinitely old
# A merged row with no active folder (e.g. a pre-folder SPEC) is skipped.
#
# Age gate: a merged folder is kept until GAIA_SPEC_RETENTION_DAYS (default
# 30; a non-numeric override falls back to 30) days have passed since the
# row's merged_at, so a just-merged SPEC survives for review instead of
# vanishing at merge. The gate lives here so every caller inherits it: the
# /gaia-spec pre-flight sweep, the spec-close single-id delegate, and the
# janitor's SessionStart sweep.
#
# Representation gate: once a candidate clears the age gate, this sources
# .gaia/scripts/cost-represented.sh and asks whether every cost.md phase
# section under the folder is already captured, value for value, in the
# main-checkout cost.jsonl (resolved via .gaia/scripts/ledger-path-lib.sh). Any
# non-zero verdict blocks that one id: the folder is left in place for review,
# and the sweep moves on to the next candidate.
#
# The ledger row's merged/merged_at stamp is a precondition set upstream (git
# reconcile / the close command), not by this sweep, and stays untouched; it
# is the identity record that survives once the folder is gone.
#
# On a successful delete this reaps the SPEC's cache keyset (gate1/draft/
# session/audit), appends a spec_closed telemetry event (disposition: delete),
# and runs the mentorship compute-profile chain, best-effort.
#
# Best-effort and fail-open by contract, exactly like spec-reconcile.sh: a
# missing jq / ledger, an unrepresented cost, or a telemetry-append failure
# never blocks a caller. One stdout line summarizes what was deleted;
# diagnostics go to stderr.
#
# Usage:
#   spec-archive-merged.sh <repo_root> [<spec_id>]
# With <spec_id>, only that id is considered (the close command's single-id
# delegate). With no id, every merged row is swept.
#
# Exit: always 0 (advisory).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-archive-merged.sh <repo_root> [<spec_id>]" >&2
  exit 0
fi

repo_root="${1%/}"
filter_id="${2:-}"
ledger_path="${repo_root}/.gaia/local/specs/ledger.json"
specs_dir="${repo_root}/.gaia/local/specs"
cache_dir="${repo_root}/.gaia/local/cache/wiki-promote"
telemetry_path="${repo_root}/.gaia/local/telemetry/spec-pacing.jsonl"

# Retention knob, read once: a non-numeric override falls back to the default.
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

# No ledger or no jq → nothing to do. (No git needed for the delete itself:
# specs are local/gitignored, so it is a plain filesystem rm, never a git op.)
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
    '.specs[] | select(.status == "merged" and .id == $id) | .id' \
    "$ledger_path" 2>/dev/null || true)"
else
  merged_ids="$(jq -r '.specs[] | select(.status == "merged") | .id' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$merged_ids" ] || exit 0

now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
deleted_list=""

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue

  folder="${specs_dir}/${spec_id}"
  # Skip merged rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Leave specs whose wiki content has not been promoted yet; the close flow
  # owns their drain + disposition.
  [ -f "${cache_dir}/${spec_id}.json" ] && continue

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # merged_at keeps the folder (fail-closed).
  merged_at="$(jq -r --arg id "$spec_id" '.specs[] | select(.id==$id) | .merged_at // ""' "$ledger_path" 2>/dev/null || true)"
  if ! _age_past_window "$merged_at"; then
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

  # Reap the merged SPEC's cache keyset (gate1/draft/session/audit). Best-effort
  # and fail-open, matching the rest of this script's contract; never purges
  # wiki-promote/<id>.json (guarded above).
  local_cache="${repo_root}/.gaia/local/cache"
  rm -f "${local_cache}/gate1-${spec_id}.json" \
        "${local_cache}/draft-${spec_id}.md" \
        "${local_cache}/spec-session-${spec_id}.json" 2>/dev/null
  rm -rf "${local_cache}/audit-${spec_id}" 2>/dev/null

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "spec-archive-merged: $spec_id folder delete failed; left active folder in place" >&2
    continue
  fi

  # Telemetry: a spec_closed event, mirroring the close command's own. drained
  # is always false here (specs with a pending drain cache are skipped above).
  # Failure to append never blocks the sweep.
  if ev="$(jq -nc --arg id "$spec_id" --arg ts "$now" \
      '{event: "spec_closed", spec_id: $id, disposition: "delete", drained: false, ts: $ts}' 2>/dev/null)"; then
    mkdir -p "$(dirname "$telemetry_path")" 2>/dev/null || true
    printf '%s\n' "$ev" >> "$telemetry_path" 2>/dev/null || true
  fi

  deleted_list="${deleted_list:+$deleted_list, }${spec_id}"
done <<EOF
$merged_ids
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s merged SPEC folder(s): %s\n' "$count" "$deleted_list"

# Best-effort profile recompute, mirroring the close command's own chain.
# Guarded on the CLI existing (absent in hermetic tests and on minimal
# clones); it self-short-circuits when mentorship is disabled. Never blocks
# the sweep.
gaia_cli="${repo_root}/.gaia/cli/gaia"
if [ -x "$gaia_cli" ]; then
  "$gaia_cli" telemetry compute-profile >/dev/null 2>&1 || true
fi

exit 0
