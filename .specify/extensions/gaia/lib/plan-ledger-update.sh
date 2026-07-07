#!/usr/bin/env bash
# plan-ledger-update.sh: Merge a JSON object into the .gaia/local/plans/ledger.json
# row matching plan_id. Existing fields are overwritten; absent fields are
# preserved. The plans-side mirror of ledger-update.sh (specs ledger).
#
# Usage:
#   plan-ledger-update.sh <repo_root> <plan_id> '<json-object>'
#
# Refuses if the row is missing, callers must allocate via plan-allocator.sh
# first. Initial status:"ready" is written inline by plan-allocator.sh at
# row creation (NOT via this chokepoint); every later transition goes through
# here.
#
# The jq…>tmp; mv critical section runs inside the PLAN-only ledger mutex
# (with-ledger-lock.sh, scoped to .gaia/local/plans) so it serializes against
# plan-allocator.sh's row append on the same ledger.json, without queuing
# behind the shared .gaia/local/specs lock a spec allocation can hold across
# network ops. See with-ledger-lock.sh for the lock env knobs
# (GAIA_LEDGER_LOCK_*).
#
# Canonical status vocabulary: ready | merged | abandoned. `abandoned` is
# reserved: the guard accepts it, but no shipped code path stamps it, there is
# no auto-abandon sweep, because a gitignored local-only ledger has no
# reliable stale-plan signal. The plans `status` field is distinct in meaning
# from the pre-existing `source` field (which reads "allocated" but records
# provenance, not lifecycle); this chokepoint never touches `source`.
#
# Exit codes: 0 ok, 2 usage, 4 ledger or row missing OR lock-acquisition
# timeout (could not safely apply the ledger write), 5 invalid patch JSON,
# 6 non-canonical status value in the patch.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: plan-ledger-update.sh <repo_root> <plan_id> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
plan_id="$2"
patch="$3"
ledger_path="${repo_root%/}/.gaia/local/plans/ledger.json"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_lib_dir}/with-ledger-lock.sh"

if [ ! -f "$ledger_path" ]; then
  echo "plan-ledger-update: ledger not found at $ledger_path" >&2
  exit 4
fi

if ! jq -e --arg id "$plan_id" '.plans[] | select(.id == $id)' "$ledger_path" >/dev/null 2>&1; then
  echo "plan-ledger-update: plan $plan_id not in ledger" >&2
  exit 4
fi

# Canonical status vocabulary guard, mirrors ledger-update.sh. A patch that
# does not set status (e.g. a subject-only repair patch) passes untouched. An
# unparseable patch falls through to apply_patch, which reports it as exit 5.
patch_status="$(jq -r 'if type == "object" and has("status") then (.status | tostring) else empty end' <<<"$patch" 2>/dev/null || true)"
if [ -n "$patch_status" ]; then
  case "$patch_status" in
    ready | merged | abandoned) ;;
    *)
      echo "plan-ledger-update: non-canonical status '$patch_status' (allowed: ready, merged, abandoned)" >&2
      exit 6
      ;;
  esac
fi

apply_patch() {
  local tmp
  tmp="$(mktemp)"
  if ! jq --arg id "$plan_id" --argjson patch "$patch" \
    '.plans |= map(if .id == $id then . + $patch else . end)' \
    "$ledger_path" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "plan-ledger-update: jq failed (invalid patch JSON?)" >&2
    return 5
  fi
  mv "$tmp" "$ledger_path"
}

rc=0
with_ledger_lock "${repo_root%/}/.gaia/local/plans" apply_patch || rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 75 ]; then
    echo "plan-ledger-update: could not acquire ledger lock; patch not applied" >&2
    exit 4
  fi
  exit "$rc"
fi
