#!/usr/bin/env bash
# spec-archive-abandoned.sh: delete an abandoned SPEC folder once its
# abandoned_at has aged past the retention window and its cost is fully
# represented in cost.jsonl. The abandoned-status counterpart to
# spec-archive-merged.sh.
#
# Why this exists: an abandoned SPEC has no implementing PR, so unlike a
# merged SPEC its folder is the only record of whatever audit findings or
# reasoning killed it. That is real but time-boxed value, not a reason to
# keep the folder forever: a SPEC is abandoned for a definitive reason (a
# falsified premise, a change that shipped the same intent elsewhere) and
# revisiting one past the retention window is vanishingly unlikely. The same
# GAIA_SPEC_RETENTION_DAYS clock that reaps merged folders applies here too.
#
# Unlike the merged path, there is no consolidation gate and no --close
# early-reap: nothing ever promotes an abandoned SPEC's content into the
# wiki, so the whole folder reaps as one unit once it clears the age and
# cost gates. A dangling wiki-promote defer flag (implement ran before the
# row was abandoned, so a PR-merge drain was left pending) is purged rather
# than guarded on, since there is no close flow left to drain it and no
# merge left to wait for; see the cache-purge step below. The cost gate
# stays, unchanged, because an abandoned draft can still have burned real
# tokens (e.g. an adversarial audit that ran before the premise was falsified)
# and that accounting must not be lost silently.
#
# Sweep criteria, per row: a .gaia/local/specs/ledger.json row is a delete
# candidate when ALL hold:
#   - row status == "abandoned"
#   - an active artifact folder exists at .gaia/local/specs/<id>/
#   - the row's abandoned_at is parseable AND has aged past the retention
#     window (GAIA_SPEC_RETENTION_DAYS, default 30; the same knob and default
#     as spec-archive-merged.sh); a missing or unparseable abandoned_at never
#     reads as infinitely old, so it keeps the folder rather than authorizing
#     a delete
#   - the folder's cost is fully represented in cost.jsonl
#     (cost_folder_represented, the same fail-closed gate
#     spec-archive-merged.sh uses; a folder with no cost.md/cost.json at all
#     is automatically represented, nothing to lose)
# An abandoned row with no active folder is skipped.
#
# Best-effort and fail-open, exactly like spec-archive-merged.sh: a missing
# jq / ledger, an unrepresented cost, or a telemetry-append failure never
# blocks a caller. One stdout line summarizes what was deleted; diagnostics
# go to stderr.
#
# Usage:
#   spec-archive-abandoned.sh <repo_root> [<spec_id>]
# With <spec_id>, only that id is considered. With no id, every abandoned row
# is swept.
#
# Exit: always 0 (advisory).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-archive-abandoned.sh <repo_root> [<spec_id>]" >&2
  exit 0
fi

repo_root="${1%/}"
filter_id="${2:-}"
ledger_path="${repo_root}/.gaia/local/specs/ledger.json"
specs_dir="${repo_root}/.gaia/local/specs"

# Retention knob, shared with spec-archive-merged.sh: a non-numeric override
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

# Candidate rows (local, cheap): abandoned but possibly still in the active
# dir. An optional single-id filter narrows the sweep to one row.
if [ -n "$filter_id" ]; then
  abandoned_ids="$(jq -r --arg id "$filter_id" \
    '.specs[] | select(.status == "abandoned" and .id == $id) | .id' \
    "$ledger_path" 2>/dev/null || true)"
else
  abandoned_ids="$(jq -r '.specs[] | select(.status == "abandoned") | .id' "$ledger_path" 2>/dev/null || true)"
fi
[ -n "$abandoned_ids" ] || exit 0

deleted_list=""

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue

  folder="${specs_dir}/${spec_id}"
  # Skip abandoned rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Age gate: cheaper than the representation gate below, and avoids computing
  # representation for a folder that is kept regardless. A missing/unparseable
  # abandoned_at keeps the folder (fail-closed).
  abandoned_at="$(jq -r --arg id "$spec_id" '.specs[] | select(.id==$id) | .abandoned_at // ""' "$ledger_path" 2>/dev/null || true)"
  if ! _age_past_window "$abandoned_at"; then
    echo "spec-archive-abandoned: $spec_id within retention window (or abandoned_at missing/unparseable); kept" >&2
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
    echo "spec-archive-abandoned: cost not fully represented in cost.jsonl; left $spec_id folder for review" >&2
    continue
  fi

  # Reap the abandoned SPEC's cache keyset (gate1/draft/session/lock/audit),
  # plus any wiki-promote defer flag. An abandoned SPEC's authoring session
  # is over, so its lock is stale by definition, same as the merged path. A
  # defer flag means /speckit-implement ran before the row was abandoned (a
  # finalized SPEC's PR was open, then dropped for cause) and left
  # .gaia/local/cache/wiki-promote/<id>.json awaiting a merge that will now
  # never happen: unlike the merged path, which GUARDS on this flag
  # (skip-and-let-close-drain), there is no close to drain it here, so it is
  # purged rather than left to orphan (nothing else ever reaps
  # wiki-promote/, see local-janitor.sh sweep #9's allowlist). Best-effort
  # and fail-open, matching the rest of this script's contract.
  local_cache="${repo_root}/.gaia/local/cache"
  rm -f "${local_cache}/gate1-${spec_id}.json" \
        "${local_cache}/draft-${spec_id}.md" \
        "${local_cache}/spec-session-${spec_id}.json" \
        "${local_cache}/spec-session-${spec_id}.lock" \
        "${local_cache}/wiki-promote/${spec_id}.json" 2>/dev/null
  rm -rf "${local_cache}/audit-${spec_id}" 2>/dev/null

  if ! rm -rf "$folder" 2>/dev/null; then
    echo "spec-archive-abandoned: $spec_id folder delete failed; left active folder in place" >&2
    continue
  fi

  deleted_list="${deleted_list:+$deleted_list, }${spec_id}"
done <<EOF
$abandoned_ids
EOF

[ -n "$deleted_list" ] || exit 0

count="$(printf '%s' "$deleted_list" | awk -F', ' '{print NF}')"
printf 'Deleted %s abandoned SPEC folder(s): %s\n' "$count" "$deleted_list"

exit 0
