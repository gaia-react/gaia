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
subject_argument="${3:-}"

# Source the shared libs from this script's own directory so they resolve
# identically from the real repo and from test copies of the lib dir (no
# hardcoded repo path, template-distributed, repo-relative). The ledger-path
# lib is reached by the same own-directory hop rather than through repo_root:
# repo_root is the value whose trustworthiness is in question here, so loading
# a library by it would decide correctness with the input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_library_directory}/with-ledger-lock.sh"
# shellcheck source=/dev/null
. "${_library_directory}/title-normalize.sh"
# shellcheck source=../ledger-path-lib.sh
. "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || true

# repo_root names the tree this allocation runs in; the ledger it feeds is
# main's, because the state registry declares plans/ main-only. Resolve rather
# than trust: from a linked worktree the operand is that worktree's own root,
# and using it forks the ledger and points the mutex at a directory no peer
# tree locks. Refuse when main is unresolvable -- the same stance this script
# already takes on a lock it cannot acquire, and for the same reason.
if ! plans_directory="$(gaia_resolve_plans_directory "$repo_root" 2>/dev/null)" || [ -z "$plans_directory" ]; then
  echo "plan-allocator: cannot resolve the main checkout for '$repo_root'; refuse to allocate (would risk duplicate PLAN ids across worktrees)" >&2
  exit 4
fi
ledger_path="${plans_directory}/ledger.json"

# Emit one bare integer per known PLAN number, one per line, unsorted.
# Sources: the ledger's plan ids, and on-disk PLAN-* basenames under
# plans_directory and plans_directory/archived (live + archived).
known_plan_numbers() {
  if [ -f "$ledger_path" ]; then
    jq -r '.plans[].id // empty' "$ledger_path" 2>/dev/null \
      | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p' || true
  fi

  local plan_path
  for plan_path in "$plans_directory"/PLAN-* "$plans_directory"/archived/PLAN-*; do
    [ -e "$plan_path" ] || continue
    printf '%s\n' "${plan_path##*/}" | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p'
  done
}

# Highest known PLAN number, or 0 if none.
highest_number() {
  local maximum_number=0 known_number
  while IFS= read -r known_number; do
    [ -z "$known_number" ] && continue
    known_number=$((10#$known_number))
    [ "$known_number" -gt "$maximum_number" ] && maximum_number="$known_number"
  done < <(known_plan_numbers | sort -un)
  echo "$maximum_number"
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
  local now temporary_file
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ensure_ledger
  temporary_file="$(mktemp)"
  if ! jq --arg id "$id" --arg now "$now" --arg subject "$subject" \
    '.plans += [{id: $id, allocated_at: $now, source: "allocated", subject: $subject, status: "ready"}]' \
    "$ledger_path" > "$temporary_file"; then
    rm -f "$temporary_file"
    echo "plan-allocator: failed to update ledger at $ledger_path" >&2
    return 4   # return (not exit) so the mutex trap releases the lock dir
  fi
  mv "$temporary_file" "$ledger_path"
}

# The critical section run under the mutex: compute the next id, normalize
# the subject, append the row, print the id.
allocate_next() {
  local requested_subject="${1:-}"
  local next_number new_id subject
  next_number=$(( $(highest_number) + 1 ))
  new_id="$(printf 'PLAN-%03d' "$next_number")"
  subject="$(normalize_subject "$requested_subject")"
  [ -z "$subject" ] && subject="$new_id"
  append_ledger_row "$new_id" "$subject" || return $?
  printf '%s\n' "$new_id"
}

case "$mode" in
  next)
    ensure_ledger
    mkdir -p "$plans_directory"
    # PLAN-scoped lock. with-ledger-lock.sh hard-names its lock specs.lock[.d]
    # regardless of dir, so it lands at .gaia/local/plans/specs.lock[.d]:
    # cosmetic only, gitignored, and does not match PLAN-*/*/RUNNING/the archiver.
    # A plan allocation is local-only, so it must NOT queue behind the shared
    # .gaia lock a spec allocation can hold ~25s across network ops.
    exit_status=0
    with_ledger_lock "$plans_directory" allocate_next "$subject_argument" || exit_status=$?
    if [ "$exit_status" -ne 0 ]; then
      if [ "$exit_status" -eq 75 ]; then
        echo "plan-allocator: could not acquire ledger lock; refuse to allocate (would risk duplicate PLAN ids)" >&2
        exit 4
      fi
      exit "$exit_status"
    fi
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
