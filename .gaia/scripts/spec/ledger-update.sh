#!/usr/bin/env bash
# ledger-update.sh: Merge a JSON object into the ledger row matching an id.
# Existing fields are overwritten; absent fields are preserved. The one
# chokepoint for both ledgers: a SPEC-NNN id patches
# .gaia/local/specs/ledger.json, a PLAN-NNN id patches
# .gaia/local/plans/ledger.json.
#
# Usage:
#   ledger-update.sh <repo_root> <SPEC-NNN|PLAN-NNN> '<json-object>'
#
# Refuses if the row is missing, callers must allocate via spec-allocator.sh or
# plan-allocator.sh first. A plan's initial status:"ready" is written inline by
# plan-allocator.sh at row creation (NOT via this chokepoint); every later
# transition goes through here.
#
# The jq…>tmp; mv critical section runs inside the shared ledger mutex
# (with-ledger-lock.sh), rooted at the kind's own directory, so it serializes
# against that allocator's row append on the same ledger.json. A plan update
# never queues behind the specs lock a spec allocation can hold across network
# ops. See with-ledger-lock.sh for the lock env knobs (GAIA_LEDGER_LOCK_*).
#
# Canonical status vocabulary (ledger-lib.sh): spec draft|ready|merged|abandoned,
# plan ready|merged|abandoned. A plan's `abandoned` is accepted but no shipped
# code path stamps it. The plans `status` field is distinct in meaning from the
# `source` field (provenance, not lifecycle); this chokepoint never touches
# `source`.
#
# Exit codes: 0 ok, 2 usage (including an id matching neither prefix, once
# ledger-lib.sh has loaded), 4 ledger or row missing OR main checkout
# unresolvable OR lock-acquisition timeout OR the shared mutex library or
# ledger-lib.sh unusable (could not safely apply the ledger write; fails closed
# for both kinds), 5 invalid patch JSON, 6 status not canonical for that kind.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: ledger-update.sh <repo_root> <SPEC-NNN|PLAN-NNN> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
ledger_id="$2"
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
# shellcheck source=/dev/null
set +e; [ -f "${_library_directory}/ledger-lib.sh" ] && . "${_library_directory}/ledger-lib.sh" 2>/dev/null; set -e
type gaia_ledger_kind_for_id >/dev/null 2>&1 || {
  echo "ledger-update: the shared ledger library is unusable; refuse to write (cannot tell which ledger the id belongs to)" >&2
  exit 4
}
# No probe of its own: gaia_ledger_directory below already refuses when the
# resolver functions are absent, which is the degrade this load owes.
# shellcheck source=../ledger-path-lib.sh
set +e; [ -f "${_library_directory}/../ledger-path-lib.sh" ] && . "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null; set -e

if ! ledger_kind="$(gaia_ledger_kind_for_id "$ledger_id")"; then
  echo "ledger-update: '$ledger_id' is neither a SPEC-NNN nor a PLAN-NNN id" >&2
  exit 2
fi
array_key="$(gaia_ledger_array_key "$ledger_kind")"

# repo_root names the tree this write runs in; the ledger it writes is
# main's, because the state registry declares specs/ and plans/ main-only.
# Resolve rather than trust: from a linked worktree the operand is that
# worktree's own root, and using it would fork the ledger. Refuse when main is
# unresolvable, mapped to this file's own ledger-missing code: a ledger this
# script cannot locate is indistinguishable from one that is missing.
if ! ledger_directory="$(gaia_ledger_directory "$ledger_kind" "$repo_root")"; then
  echo "ledger-update: cannot resolve the main checkout for '$repo_root'; refuse to write (would fork the ledger across worktrees)" >&2
  exit 4
fi
ledger_path="${ledger_directory}/ledger.json"

if [ ! -f "$ledger_path" ]; then
  echo "ledger-update: ledger not found at $ledger_path" >&2
  exit 4
fi

if ! jq -e --arg key "$array_key" --arg id "$ledger_id" '.[$key][] | select(.id == $id)' "$ledger_path" >/dev/null 2>&1; then
  echo "ledger-update: $ledger_kind $ledger_id not in ledger" >&2
  exit 4
fi

# Canonical status vocabulary guard (wiki/concepts/GAIA Spec.md, "Ledger status
# vocabulary"). This is the single chokepoint for ledger writes, so rejecting
# an off-vocabulary status here keeps every tool path (allocator finalize,
# spec-reconcile, plan-reconcile) from persisting a stray label. A patch that
# does not set status (e.g. a merged_at-only stamp) passes untouched. An
# unparseable patch falls through to apply_patch, which reports it as exit 5.
# Existing off-vocabulary spec rows are repaired by spec-reconcile.sh, which
# renames the alias it knows (`shipped`) through this same chokepoint.
patch_status="$(jq -r 'if type == "object" and has("status") then (.status | tostring) else empty end' <<<"$patch" 2>/dev/null || true)"
if [ -n "$patch_status" ] && ! gaia_ledger_status_allowed "$ledger_kind" "$patch_status"; then
  case "$ledger_kind" in
    spec) allowed_statuses="draft, ready, merged, abandoned" ;;
    *) allowed_statuses="ready, merged, abandoned" ;;
  esac
  echo "ledger-update: non-canonical status '$patch_status' (allowed: $allowed_statuses)" >&2
  exit 6
fi

apply_patch() {
  local temporary_file
  temporary_file="$(mktemp)"
  if ! jq --arg key "$array_key" --arg id "$ledger_id" --argjson patch "$patch" \
    '.[$key] |= map(if .id == $id then . + $patch else . end)' \
    "$ledger_path" > "$temporary_file" 2>/dev/null; then
    rm -f "$temporary_file"
    echo "ledger-update: jq failed (invalid patch JSON?)" >&2
    return 5
  fi
  mv "$temporary_file" "$ledger_path"
}

exit_status=0
with_ledger_lock "$ledger_directory" apply_patch || exit_status=$?
if [ "$exit_status" -ne 0 ]; then
  if [ "$exit_status" -eq 75 ]; then
    echo "ledger-update: could not acquire ledger lock; patch not applied" >&2
    exit 4
  fi
  exit "$exit_status"
fi
