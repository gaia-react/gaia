#!/usr/bin/env bash
# ledger-update.sh: Merge a JSON object into the .gaia/local/specs/ledger.json row
# matching spec_id. Existing fields are overwritten; absent fields are preserved.
#
# Usage:
#   ledger-update.sh <repo_root> <spec_id> '<json-object>'
#
# Refuses if the row is missing, callers must allocate via spec-allocator.sh first.
#
# The jq…>tmp; mv critical section runs inside the shared ledger mutex
# (with-ledger-lock.sh) so it serializes against spec-allocator.sh's row
# append on the same .gaia/local/specs/ledger.json. See with-ledger-lock.sh for
# the lock env knobs (GAIA_LEDGER_LOCK_*).
#
# Exit codes: 0 ok, 2 usage, 4 ledger or row missing OR lock-acquisition
# timeout (could not safely apply the ledger write), 5 invalid patch JSON,
# 6 non-canonical status value in the patch.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: ledger-update.sh <repo_root> <spec_id> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
spec_id="$2"
patch="$3"
ledger_path="${repo_root%/}/.gaia/local/specs/ledger.json"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_lib_dir}/with-ledger-lock.sh"

if [ ! -f "$ledger_path" ]; then
  echo "ledger-update: ledger not found at $ledger_path" >&2
  exit 4
fi

if ! jq -e --arg id "$spec_id" '.specs[] | select(.id == $id)' "$ledger_path" >/dev/null 2>&1; then
  echo "ledger-update: spec $spec_id not in ledger" >&2
  exit 4
fi

# Canonical status vocabulary guard. The ledger's status is one of the four
# canonical values draft|specified|merged|archived, plus the tolerated legacy
# value in-progress (wiki/concepts/GAIA Spec.md, "Ledger status vocabulary").
# This is the single chokepoint for ledger writes, so rejecting an
# off-vocabulary status here keeps every tool path (allocator finalize,
# spec-reconcile, spec-close) from persisting a stray label. A patch that does
# not set status (e.g. a merged_at-only stamp) passes untouched. An unparseable
# patch falls through to apply_patch, which reports it as exit 5. Existing
# off-vocabulary rows (e.g. a hand-edited "shipped") are repaired by
# spec-reconcile.sh, which renames known aliases through this same chokepoint.
patch_status="$(jq -r 'if type == "object" and has("status") then (.status | tostring) else empty end' <<<"$patch" 2>/dev/null || true)"
if [ -n "$patch_status" ]; then
  case "$patch_status" in
    draft | specified | merged | archived | in-progress) ;;
    *)
      echo "ledger-update: non-canonical status '$patch_status' (allowed: draft, specified, merged, archived)" >&2
      exit 6
      ;;
  esac
fi

apply_patch() {
  local tmp
  tmp="$(mktemp)"
  if ! jq --arg id "$spec_id" --argjson patch "$patch" \
    '.specs |= map(if .id == $id then . + $patch else . end)' \
    "$ledger_path" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ledger-update: jq failed (invalid patch JSON?)" >&2
    return 5
  fi
  mv "$tmp" "$ledger_path"
}

rc=0
with_ledger_lock "${repo_root%/}/.gaia/local/specs" apply_patch || rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 75 ]; then
    echo "ledger-update: could not acquire ledger lock; patch not applied" >&2
    exit 4
  fi
  exit "$rc"
fi
