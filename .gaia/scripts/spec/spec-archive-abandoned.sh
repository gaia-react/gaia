#!/usr/bin/env bash
# spec-archive-abandoned.sh: delete an abandoned SPEC folder once its
# abandoned_at has aged past the retention window. The abandoned-status
# counterpart to spec-archive-merged.sh.
#
# Why this exists: an abandoned SPEC has no implementing PR, so unlike a
# merged SPEC its folder is the only record of whatever audit findings or
# reasoning killed it. That is real but time-boxed value, not a reason to
# keep the folder forever: a SPEC is abandoned for a definitive reason (a
# falsified premise, a change that shipped the same intent elsewhere) and
# revisiting one past the retention window is vanishingly unlikely. The same
# GAIA_SPEC_RETENTION_DAYS clock that reaps merged folders applies here too.
#
# Unlike the merged path, there is no consolidation gate: nothing ever
# promotes an abandoned SPEC's content into the wiki, so the whole folder
# reaps as one unit once it clears the age gate. There is no usage-ledger gate
# either: an abandoned draft never closes a run on the ledger, so the age rule
# alone decides and this script never calls `usage.sh represented`.
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
# An abandoned row with no active folder is skipped.
#
# Best-effort and fail-open, exactly like spec-archive-merged.sh: a missing
# jq or ledger never blocks a caller. One stdout line summarizes what was
# deleted; diagnostics go to stderr.
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

# Retention knob, shared with spec-archive-merged.sh: a non-numeric override
# falls back to the default.
retention_days="${GAIA_SPEC_RETENTION_DAYS:-30}"
case "$retention_days" in '' | *[!0-9]*) retention_days=30 ;; esac
now_epoch="$(date -u +%s 2>/dev/null || echo 0)"

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
[ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null || true
if ! type gaia_ledger_age_past_window >/dev/null 2>&1; then
  echo "spec-archive-abandoned: ledger-lib.sh is unusable; nothing swept" >&2
  exit 0
fi

# repo_root names the tree this sweep runs in; the ledger and folders it
# sweeps are main's, because the state registry declares specs/ main-only.
# Best-effort by contract: an unresolvable main is one diagnostic and exit 0,
# nothing touched.
if ! specs_directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || [ -z "$specs_directory" ]; then
  echo "spec-archive-abandoned: cannot resolve the main checkout for '$repo_root'; nothing swept" >&2
  exit 0
fi
ledger_path="${specs_directory}/ledger.json"

# No ledger or no jq → nothing to do. (No git needed for the delete itself:
# specs are local/gitignored, so it is a plain filesystem rm, never a git op.)
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

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

  folder="${specs_directory}/${spec_id}"
  # Skip abandoned rows with no active folder (already gone, or never had one).
  [ -d "$folder" ] || continue

  # Age gate: the only gate. A missing/unparseable abandoned_at keeps the
  # folder (fail-closed).
  abandoned_at="$(jq -r --arg id "$spec_id" '.specs[] | select(.id==$id) | .abandoned_at // ""' "$ledger_path" 2>/dev/null || true)"
  if ! gaia_ledger_age_past_window "$abandoned_at" "$now_epoch" "$retention_days"; then
    echo "spec-archive-abandoned: $spec_id within retention window (or abandoned_at missing/unparseable); kept" >&2
    continue
  fi

  # Reap the abandoned SPEC's cache keyset (gate1/draft/session/lock/audit).
  # An abandoned SPEC's authoring session is over, so its lock is stale by
  # definition, same as the merged path. Best-effort and fail-open, matching
  # the rest of this script's contract.
  local_cache="${repo_root}/.gaia/local/cache"
  rm -f "${local_cache}/gate1-${spec_id}.json" \
        "${local_cache}/draft-${spec_id}.md" \
        "${local_cache}/spec-session-${spec_id}.json" \
        "${local_cache}/spec-session-${spec_id}.lock" 2>/dev/null
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
