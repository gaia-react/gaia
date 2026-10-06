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
# timeout OR the shared mutex library unusable (could not safely apply the
# ledger write), 5 invalid patch JSON, 6 non-canonical status value in the
# patch.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: ledger-update.sh <repo_root> <spec_id> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
spec_id="$2"
patch="$3"

_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each load is bracketed against a target that is present but UNPARSEABLE, and
# the probe under it decides the degrade. A bare `.` under errexit abandons the
# shell AT the load, exit 2 with no diagnostic, so none of the refusals written
# below would run; and a trailing `|| true` does not save it on stock macOS
# /bin/bash 3.2.57, which aborts before the arm is ever evaluated. An
# interrupted update, an unresolved merge conflict, and a truncated write all
# leave exactly that state on disk.
# shellcheck source=/dev/null
set +e; [ -f "${_library_directory}/with-ledger-lock.sh" ] && . "${_library_directory}/with-ledger-lock.sh" 2>/dev/null; set -e
type with_ledger_lock >/dev/null 2>&1 || {
  echo "ledger-update: the shared ledger mutex is unusable; refuse to write (an unserialized write can tear the ledger)" >&2
  exit 4
}
# No probe of its own: the gaia_resolve_specs_directory call below already refuses
# when the function is absent, which is the degrade this load owes.
# shellcheck source=../ledger-path-lib.sh
set +e; [ -f "${_library_directory}/../ledger-path-lib.sh" ] && . "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null; set -e

# repo_root names the tree this write runs in; the ledger it writes is
# main's, because the state registry declares specs/ main-only. Resolve
# rather than trust: from a linked worktree the operand is that worktree's
# own root, and using it would fork the ledger. Refuse when main is
# unresolvable, mapped to this file's own ledger-missing code: a ledger this
# script cannot locate is indistinguishable from one that is missing.
if ! specs_directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || [ -z "$specs_directory" ]; then
  echo "ledger-update: cannot resolve the main checkout for '$repo_root'; refuse to write (would fork the ledger across worktrees)" >&2
  exit 4
fi
ledger_path="${specs_directory}/ledger.json"

if [ ! -f "$ledger_path" ]; then
  echo "ledger-update: ledger not found at $ledger_path" >&2
  exit 4
fi

if ! jq -e --arg id "$spec_id" '.specs[] | select(.id == $id)' "$ledger_path" >/dev/null 2>&1; then
  echo "ledger-update: spec $spec_id not in ledger" >&2
  exit 4
fi

# Canonical status vocabulary guard. The ledger's status is one of the four
# canonical values draft|ready|merged|abandoned (wiki/concepts/GAIA Spec.md,
# "Ledger status vocabulary").
# This is the single chokepoint for ledger writes, so rejecting an
# off-vocabulary status here keeps every tool path (allocator finalize,
# spec-reconcile) from persisting a stray label. A patch that does
# not set status (e.g. a merged_at-only stamp) passes untouched. An unparseable
# patch falls through to apply_patch, which reports it as exit 5. Existing
# off-vocabulary rows (e.g. a hand-edited "shipped") are repaired by
# spec-reconcile.sh, which renames known aliases through this same chokepoint.
patch_status="$(jq -r 'if type == "object" and has("status") then (.status | tostring) else empty end' <<<"$patch" 2>/dev/null || true)"
if [ -n "$patch_status" ]; then
  case "$patch_status" in
    draft | ready | merged | abandoned) ;;
    *)
      echo "ledger-update: non-canonical status '$patch_status' (allowed: draft, ready, merged, abandoned)" >&2
      exit 6
      ;;
  esac
fi

apply_patch() {
  local temporary_file
  temporary_file="$(mktemp)"
  if ! jq --arg id "$spec_id" --argjson patch "$patch" \
    '.specs |= map(if .id == $id then . + $patch else . end)' \
    "$ledger_path" > "$temporary_file" 2>/dev/null; then
    rm -f "$temporary_file"
    echo "ledger-update: jq failed (invalid patch JSON?)" >&2
    return 5
  fi
  mv "$temporary_file" "$ledger_path"
}

exit_status=0
with_ledger_lock "$specs_directory" apply_patch || exit_status=$?
if [ "$exit_status" -ne 0 ]; then
  if [ "$exit_status" -eq 75 ]; then
    echo "ledger-update: could not acquire ledger lock; patch not applied" >&2
    exit 4
  fi
  exit "$exit_status"
fi
