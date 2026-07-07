#!/usr/bin/env bash
# plan-allocator.sh: Allocate PLAN-NNN ids for spec-less one-off plans using
# the .gaia/local/plans/ledger.json ledger. Local-only: no git requirement, no
# remote tag reservation, no network. Plans are gitignored and ephemeral, so
# the ledger alone (plus on-disk folders) is the collision authority. Next id
# is max+1 over the union of ledger ids and on-disk PLAN-NNN folders (both
# live and archived/).
#
# Usage:
#   plan-allocator.sh next <repo_root> [<subject>]  # print next PLAN-NNN, append ledger row
#
# Ledger rows are {id, allocated_at, source, subject, status}. status is
# written "ready" inline here at row creation; every later transition
# goes through the guarded plan-ledger-update.sh chokepoint. Numbers are
# never reused.
#
# Concurrency: the read-union-allocate-write critical section runs under the
# shared ledger mutex from with-ledger-lock.sh (flock when present, atomic-
# mkdir fallback on stock macOS), scoped to the PLAN-only lock dir
# (.gaia/local/plans), NOT the shared .gaia/local/specs lock a spec allocation
# can hold across network ops. A lock-acquisition timeout (helper exit 75)
# maps to exit 4.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: plan-allocator.sh next <repo_root> [<subject>]" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
subject_arg="${3:-}"
plans_dir="${repo_root%/}/.gaia/local/plans"
ledger_path="${plans_dir}/ledger.json"

# Source the shared ledger mutex from this script's own directory so it
# resolves identically from the real repo and from test copies of the lib
# dir (no hardcoded repo path, template-distributed, repo-relative).
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_lib_dir}/with-ledger-lock.sh"
# shellcheck source=/dev/null
. "${_lib_dir}/title-normalize.sh"

# Emit one bare integer per known PLAN number, one per line, unsorted.
# Sources: the ledger's plan ids, and on-disk PLAN-* basenames under
# plans_dir and plans_dir/archived (live + archived).
known_plan_numbers() {
  if [ -f "$ledger_path" ]; then
    jq -r '.plans[].id // empty' "$ledger_path" 2>/dev/null \
      | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p' || true
  fi

  local d
  for d in "$plans_dir"/PLAN-* "$plans_dir"/archived/PLAN-*; do
    [ -e "$d" ] || continue
    printf '%s\n' "${d##*/}" | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p'
  done
}

# Highest known PLAN number, or 0 if none.
highest_num() {
  local max=0 n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done < <(known_plan_numbers | sort -un)
  echo "$max"
}

# Initialize the ledger file if missing. Empty ledger; rows appended elsewhere.
ensure_ledger() {
  if [ ! -f "$ledger_path" ]; then
    mkdir -p "$(dirname "$ledger_path")"
    printf '{\n  "version": 1,\n  "plans": []\n}\n' > "$ledger_path"
  fi
}

normalize_subject() {
  gaia_normalize_title "$1"
}

# Append a new row to the ledger atomically. A jq write failure returns
# (not exits) 4 so the mutex trap still releases the lock dir; `next` maps
# it to exit 4.
append_ledger_row() {
  local id="$1" subject="$2"
  local now tmp
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ensure_ledger
  tmp="$(mktemp)"
  if ! jq --arg id "$id" --arg now "$now" --arg subject "$subject" \
    '.plans += [{id: $id, allocated_at: $now, source: "allocated", subject: $subject, status: "ready"}]' \
    "$ledger_path" > "$tmp"; then
    rm -f "$tmp"
    echo "plan-allocator: failed to update ledger at $ledger_path" >&2
    return 4   # return (not exit) so the mutex trap releases the lock dir
  fi
  mv "$tmp" "$ledger_path"
}

# The critical section run under the mutex: compute the next id, normalize
# the subject, append the row, print the id.
allocate_next() {
  local subj_arg="${1:-}"
  local n new_id subject
  n=$(( $(highest_num) + 1 ))
  new_id="$(printf 'PLAN-%03d' "$n")"
  subject="$(normalize_subject "$subj_arg")"
  [ -z "$subject" ] && subject="$new_id"
  append_ledger_row "$new_id" "$subject" || return $?
  printf '%s\n' "$new_id"
}

case "$mode" in
  next)
    ensure_ledger
    mkdir -p "$plans_dir"
    # PLAN-scoped lock. with-ledger-lock.sh hard-names its lock specs.lock[.d]
    # regardless of dir, so it lands at .gaia/local/plans/specs.lock[.d]:
    # cosmetic only, gitignored, and does not match PLAN-*/*/RUNNING/the archiver.
    # A plan allocation is local-only, so it must NOT queue behind the shared
    # .gaia lock a spec allocation can hold ~25s across network ops.
    rc=0
    with_ledger_lock "$plans_dir" allocate_next "$subject_arg" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 75 ]; then
        echo "plan-allocator: could not acquire ledger lock; refuse to allocate (would risk duplicate PLAN ids)" >&2
        exit 4
      fi
      exit "$rc"
    fi
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
