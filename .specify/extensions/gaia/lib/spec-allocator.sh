#!/usr/bin/env bash
# spec-allocator.sh: Allocate SPEC-NNN ids using the .gaia/local/specs/ledger.json
# ledger, self-healed against deterministic markers in git (plan branches naming a SPEC) and
# the working-tree SPEC files. The repo must be a git working tree.
#
# Usage:
#   spec-allocator.sh next <repo_root> [<subject>]  # print next SPEC-NNN, reserve on remote, write ledger row
#   spec-allocator.sh highest <repo_root>           # print highest known SPEC-NNN, or "none"
#   spec-allocator.sh in_progress <repo_root>       # print first unfinalized (draft) SPEC id, or "none"
#   spec-allocator.sh reserve_pending <repo_root>   # push deferred provisional reservations; fail-open, exit 0
#
# Authority: the remote's spec/* tag namespace is the cross-team allocation
# authority; the local, gitignored .gaia/local/specs/ledger.json is a per-machine
# cache of draft status, intent, and timestamps, and one input to the union `next`
# reads. `next` performs a self-heal pass before allocating, any SPEC id found in a
# branch name (the deterministic marker that GAIA tooling creates) is treated as
# burned even if missing from the ledger. A skipped slot is strictly cheaper than a
# duplicate id. Commit messages are NOT scanned; they pick up free-text references
# (test fixtures, regression notes) that would inflate the highest id incorrectly.
#
# Reservation: `next` computes max+1 over the UNION of the remote spec/* tags (when
# reachable) and the local signals, then reserves the number by a non-force push of
# an immutable `spec/NNN` annotated tag pointed at git's empty-tree object
# (4b825dc642cb6eb9a060e54bf8d69288fbee4904). The push IS the cross-machine lock: a
# remote grants each ref once, so a rejected push whose ref now exists means another
# machine took the number → re-read the union and retry at the next number, bounded.
# The tag name is zero-padded to three digits (spec/021) so the namespace stays
# uniform; the union parser strips leading zeros so a legacy spec/22 still parses.
# Reservation tags are immutable: created once, never force-updated, never deleted
# on the remote (a failed LOCAL tag may be deleted before retrying at a free number).
# Each row records a `reservation` state:
#   reserved     — tag confirmed pushed to the remote.
#   provisional  — remote unreachable at allocation; deferred push pending (reserve_pending).
#   local        — no origin remote configured; local-only numbering, no push ever needed.
#   unavailable  — remote reachable but tag namespace not writable; degraded with a warning.
# and a `subject` (first line of the <subject> arg, trimmed, <=100 chars, non-empty;
# falls back to the SPEC id) used verbatim as the tag annotation, set once at
# reservation and never updated on a later push. Rows lacking reservation/subject are
# tolerated everywhere (a missing reservation is terminal, never auto-pushed).
#
# Never blocks or hangs: the remote read/push are bounded by a portable
# background-kill watchdog (the target machine has no timeout/gtimeout) plus
# GIT_TERMINAL_PROMPT=0 so a credential prompt cannot stall /gaia-spec. With no
# reachable remote allocation records a provisional local-union max+1 and reserves
# later; if that deferred push loses a race the in-flight spec is renumbered to the
# next free number via spec-renumber.sh rather than keeping the collided number.
#
# Concurrency: the `next` read-union-reserve-write critical section runs under the
# shared ledger mutex from with-ledger-lock.sh (flock when present, atomic-mkdir
# fallback on stock macOS). The remote read/push and ledger append happen inside the
# single held mutex so two same-machine `next` calls cannot interleave. A lock-
# acquisition timeout (helper exit 75) maps to exit 4; reservation-retry exhaustion
# also maps to exit 4; the caller (.claude/skills/gaia/references/spec.md step 3) handles exit
# 4, and every other non-zero exit, by surfacing the error and halting. Lock env knobs (GAIA_LEDGER_LOCK_TIMEOUT_SECONDS / _STALE_SECONDS / _POLL_SECONDS /
# _FORCE_FALLBACK): see with-ledger-lock.sh. Reservation env knobs:
#   GAIA_SPEC_REMOTE_TIMEOUT_SECONDS  per ls-remote / push bound (default 5)
#   GAIA_SPEC_ALLOCATION_MAXIMUM_RETRIES    reservation retry bound     (default 5)
#   GAIA_SPEC_FORCE_OFFLINE=1       force the unreachable path  (test knob)
# `highest` and `in_progress` are read-only, take NO lock, and never touch the network.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: spec-allocator.sh {next|highest|in_progress|reserve_pending} <repo_root> [<subject>]" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
subject_argument="${3:-}"

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
remote_timeout="${GAIA_SPEC_REMOTE_TIMEOUT_SECONDS:-5}"
maximum_retries="${GAIA_SPEC_ALLOCATION_MAXIMUM_RETRIES:-5}"

# A credential prompt on an HTTPS remote would hang /gaia-spec; disabling the
# terminal prompt makes every git remote op fail fast instead. Set for all git
# subprocesses this script spawns; it has no effect on the local-only ops.
export GIT_TERMINAL_PROMPT=0

# Set by classify_remote; read by union_maximum / the reservation paths.
_remote_state=""
_remote_tags_raw=""

# Source the shared libs from this script's own directory so they resolve
# identically from a caller in any checkout and from test copies of the lib dir (no
# hardcoded repo path, template-distributed, repo-relative). The ledger-path
# lib is reached by the same own-directory hop rather than through repo_root:
# repo_root is the value whose trustworthiness is in question here, so loading
# a library by it would decide correctness with the input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
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
  echo "spec-allocator: the shared ledger mutex is unusable; refuse to allocate (would risk duplicate SPEC ids)" >&2
  exit 4
}
# No probe of its own: the gaia_resolve_specs_directory call below already refuses
# when the function is absent, which is the degrade this load owes.
# shellcheck source=../../../../.gaia/scripts/ledger-path-lib.sh
set +e; [ -f "${_library_directory}/../../../../.gaia/scripts/ledger-path-lib.sh" ] && . "${_library_directory}/../../../../.gaia/scripts/ledger-path-lib.sh" 2>/dev/null; set -e
# The branch-naming library reads a SPEC number back out of a plan branch in
# every spelling GAIA mints, the worktree one included. Loaded the same
# bracketed way as the ledger-path lib above, for the same reason.
# shellcheck source=../../../../.gaia/scripts/branch-name-lib.sh
set +e; [ -f "${_library_directory}/../../../../.gaia/scripts/branch-name-lib.sh" ] && . "${_library_directory}/../../../../.gaia/scripts/branch-name-lib.sh" 2>/dev/null; set -e
if ! type gaia_branch_spec_number >/dev/null 2>&1; then
  echo "spec-allocator: the branch-naming library is unusable, so SPEC numbers held only on a branch cannot be read; refuse to allocate (would risk duplicate SPEC ids)" >&2
  exit 4
fi

require_git() {
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "spec-allocator: $repo_root is not a git repository; refuse to allocate (would risk duplicate SPEC ids)" >&2
    exit 3
  fi
}

# repo_root names the tree this allocation runs in; the ledger it feeds is
# main's, because the state registry declares specs/ main-only. Resolve rather
# than trust: from a linked worktree the operand is that worktree's own root,
# and using it forks the ledger and points the mutex at a directory no peer
# tree locks. A non-git operand is refused first with the existing "not a git
# repository" contract (exit 3); the resolver then anchors to main and refuses
# (exit 4) only when the operand is a repo whose main checkout is unresolvable
# -- the same stance this script already takes on a lock it cannot acquire.
require_git
if ! specs_directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || [ -z "$specs_directory" ]; then
  echo "spec-allocator: cannot resolve the main checkout for '$repo_root'; refuse to allocate (would risk duplicate SPEC ids across worktrees)" >&2
  exit 4
fi
ledger_path="${specs_directory}/ledger.json"

# Emit one bare integer per known SPEC number, one per line, unsorted.
# Sources (all deterministic LOCAL markers; no free-text scanning, no network):
#   1. .gaia/local/specs/ledger.json ledger
#   2. Local + remote-tracking plan branches naming a SPEC
#   3. Working-tree folders .gaia/local/specs/<spec_id>/SPEC.md
known_spec_numbers() {
  if [ -f "$ledger_path" ]; then
    jq -r '.specs[].id // empty' "$ledger_path" 2>/dev/null \
      | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
  fi

  # The test is a builtin prefilter so a branch that cannot name a
  # SPEC skips the subshells of the library; this scan runs under the ledger
  # lock, and a repository carries hundreds of refs.
  gaia_branch_list "$repo_root" | while IFS= read -r branch; do
    if [[ "$branch" == *spec-* ]]; then gaia_branch_spec_number "$branch"; fi
  done

  if [ -d "$specs_directory" ]; then
    find "$specs_directory" -mindepth 2 -maxdepth 2 -type f -name 'SPEC.md' -print 2>/dev/null \
      | sed -nE 's|.*/SPEC-0*([0-9]+)/SPEC\.md$|\1|p' || true
  fi
}

# Highest known LOCAL SPEC number, or 0 if none. No network: the `highest`
# subcommand and read-only callers depend on this never hitting the remote.
highest_number() {
  require_git
  local maximum_number=0 known_number
  while IFS= read -r known_number; do
    [ -z "$known_number" ] && continue
    known_number=$((10#$known_number))
    [ "$known_number" -gt "$maximum_number" ] && maximum_number="$known_number"
  done < <(known_spec_numbers | sort -un)
  echo "$maximum_number"
}

# Initialize the ledger file if missing. Empty ledger; entries are appended elsewhere.
ensure_ledger() {
  if [ ! -f "$ledger_path" ]; then
    mkdir -p "$(dirname "$ledger_path")"
    printf '{\n  "version": 1,\n  "specs": []\n}\n' > "$ledger_path"
  fi
}

# Append a new row to the ledger atomically, carrying the reservation state and
# tag-annotation subject. Keeps the `.specs += [...]` shape so a jq write failure
# is surfaced as return 4 (mapped to exit 4 by `next`).
append_ledger_row() {
  local id="$1" reservation="$2" subject="$3"
  local now temporary_file
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ensure_ledger
  temporary_file="$(mktemp)"
  if ! jq --arg id "$id" --arg now "$now" --arg reservation "$reservation" --arg subject "$subject" \
    '.specs += [{id: $id, allocated_at: $now, source: "allocated", status: "draft", reservation: $reservation, subject: $subject}]' \
    "$ledger_path" > "$temporary_file"; then
    rm -f "$temporary_file"
    echo "spec-allocator: failed to update ledger at $ledger_path" >&2
    # return (not exit) so the mkdir-lock trap still releases the lock dir;
    # allocate_next propagates this exit_status and `next)` re-maps it to exit 4.
    return 4
  fi
  mv "$temporary_file" "$ledger_path"
}

# Set an existing row's reservation state in place (mutex-protected pattern,
# NOT routed through ledger-update.sh's status guard which only vets `status`).
# Fail-open: a jq failure warns and returns 0 so a reconcile pass never crashes.
set_row_reservation() {
  local id="$1" state="$2" temporary_file
  [ -f "$ledger_path" ] || return 0
  temporary_file="$(mktemp)"
  if jq --arg id "$id" --arg reservation_state "$state" \
    '.specs |= map(if .id == $id then .reservation = $reservation_state else . end)' \
    "$ledger_path" > "$temporary_file"; then
    mv "$temporary_file" "$ledger_path"
  else
    rm -f "$temporary_file"
    echo "spec-allocator: failed to update reservation for $id" >&2
  fi
  return 0
}

# Print the first unfinalized (draft) SPEC id, or "none". Single-id,
# none-when-empty contract preserved.
#
# A SPEC is "in flight" for resume-vs-start-new purposes only while it is being
# authored. The ledger row is created at `next` (skill step 3) with status
# "draft" and flipped to "ready" when the SPEC artifact is finalized and
# frozen (skill step 8). Both transitions are owned by the same authoring
# session, so this signal cannot go stale on a fragile downstream chain.
#
# A finalized SPEC (ready / merged) is downstream feature work tracked by
# branches and PRs, NOT a draft a new /gaia-spec session would resume, so it
# is deliberately not reported here. The merged transition is reconciled from
# git ground truth by spec-reconcile.sh, out of this read path.
#
# Source: the .gaia/local/specs/ledger.json ledger only. The prior SPEC-file frontmatter
# fallback is intentionally gone: every SPEC gets a ledger row at allocation, so
# a draft always has one, and scanning frozen SPEC files re-flagged finalized
# work as in-flight forever (the staleness this design removes).
in_progress_spec() {
  if [ -f "$ledger_path" ]; then
    local id
    id="$(jq -r '
      [.specs[] | select(.status == "draft")][0].id // empty
    ' "$ledger_path" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      printf '%s\n' "$id"
      return
    fi
  fi
  echo "none"
}

# ---- Bounded network helpers ------------------------------------------------

# Run a command with a wall-clock bound, portably. The target machine has no
# timeout/gtimeout, so the load-bearing path is a background-kill watchdog: run
# the command in the background, kill it after N seconds. Returns the command's
# exit code (non-zero on kill/timeout). Falls through to timeout/gtimeout only
# when present.
_run_with_timeout() {
  local command_timeout_seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$command_timeout_seconds" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$command_timeout_seconds" "$@"
    return $?
  fi
  "$@" &
  local command_pid=$!
  # Watchdog: TERM then (after a grace) KILL. stdout redirected off the caller's
  # pipe so a command-substitution reader gets EOF as soon as the command exits.
  { sleep "$command_timeout_seconds"; kill -TERM "$command_pid" 2>/dev/null; sleep 1; kill -KILL "$command_pid" 2>/dev/null; } >/dev/null 2>&1 &
  local watch_pid=$!
  local exit_status=0
  wait "$command_pid" 2>/dev/null || exit_status=$?
  kill -TERM "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return "$exit_status"
}

# Classify the origin remote into none | reachable | unreachable and, when
# reachable, capture the spec/* ls-remote output for the union. Sets globals
# _remote_state and _remote_tags_raw. Order: no origin wins over FORCE_OFFLINE.
classify_remote() {
  _remote_tags_raw=""
  local url ls_remote_output exit_status=0
  url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    _remote_state="none"
    return
  fi
  if [ "${GAIA_SPEC_FORCE_OFFLINE:-}" = "1" ]; then
    _remote_state="unreachable"
    return
  fi
  ls_remote_output="$(_run_with_timeout "$remote_timeout" \
    git -C "$repo_root" ls-remote --tags origin 'refs/tags/spec/*' 2>/dev/null)" || exit_status=$?
  if [ "$exit_status" -ne 0 ]; then
    _remote_state="unreachable"
    return
  fi
  _remote_state="reachable"
  _remote_tags_raw="$ls_remote_output"
}

# Emit bare integers from the captured ls-remote output. Handles the annotated
# tag's peeled ^{} line and strips leading zeros in the regex; union_maximum coerces
# base-10 as a second guard.
remote_tag_numbers() {
  [ -z "$_remote_tags_raw" ] && return 0
  printf '%s\n' "$_remote_tags_raw" \
    | sed -nE 's|^[0-9a-f]+[[:space:]]+refs/tags/spec/0*([0-9]+)(\^\{\})?$|\1|p'
}

# Max over the union of local signals and (when reachable) the remote spec/*
# tags. The union can only rise, never fall.
union_maximum() {
  local maximum_number remote_number
  maximum_number="$(highest_number)"
  if [ "$_remote_state" = "reachable" ]; then
    while IFS= read -r remote_number; do
      [ -z "$remote_number" ] && continue
      remote_number=$((10#$remote_number))
      [ "$remote_number" -gt "$maximum_number" ] && maximum_number="$remote_number"
    done < <(remote_tag_numbers)
  fi
  echo "$maximum_number"
}

# First line of the subject arg, trimmed, truncated to <=100 chars. May be empty
# (callers fall back to the SPEC id).
normalize_subject() {
  local raw="$1" line
  line="$(printf '%s' "$raw" | sed -n '1p')"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  line="$(printf '%s' "$line" | cut -c1-100)"
  printf '%s' "$line"
}

# Create the local annotated empty-tree reservation tag, deleting any stale local
# tag of the same name from a prior failed attempt first (never touches the remote).
create_local_tag() {
  local tag="$1" subject="$2"
  git -C "$repo_root" tag -d "$tag" >/dev/null 2>&1 || true
  git -C "$repo_root" tag -a "$tag" "$EMPTY_TREE" -m "$subject" >/dev/null 2>&1
}

delete_local_tag() {
  git -C "$repo_root" tag -d "$1" >/dev/null 2>&1 || true
}

# Non-force push of the reservation ref, bounded.
push_tag() {
  local tag="$1" exit_status=0
  _run_with_timeout "$remote_timeout" \
    git -C "$repo_root" push origin "refs/tags/$tag" >/dev/null 2>&1 || exit_status=$?
  return "$exit_status"
}

# Re-check whether a specific reservation ref exists on the remote after a failed
# push. Echoes exists | absent | error (error = remote went unreachable mid-op).
remote_reference_state() {
  local tag="$1" ls_remote_output exit_status=0
  ls_remote_output="$(_run_with_timeout "$remote_timeout" \
    git -C "$repo_root" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" || exit_status=$?
  if [ "$exit_status" -ne 0 ]; then
    echo "error"
    return
  fi
  if [ -n "$ls_remote_output" ]; then
    echo "exists"
  else
    echo "absent"
  fi
}

# ---- Deferred-reservation reconcile (renumber-on-collision) -----------------

# Renumber an in-flight provisional spec whose number was taken on the remote
# while offline to the next free number and reserve that number instead. Never
# keeps the collided number. Bounded by maximum_retries; fail-open (returns 0,
# leaving the row provisional, on any snag so a later run retries).
_renumber_and_reserve() {
  local old_id="$1" subject="$2"
  local attempt=0 new_number new_id new_tag push_exit_status tag_existence
  while [ "$attempt" -lt "$maximum_retries" ]; do
    classify_remote
    if [ "$_remote_state" != "reachable" ]; then
      return 0
    fi
    new_number=$(( $(union_maximum) + 1 ))
    new_id="$(printf 'SPEC-%03d' "$new_number")"
    new_tag="$(printf 'spec/%03d' "$new_number")"
    if ! bash "${_library_directory}/spec-renumber.sh" "$repo_root" "$old_id" "$new_id" >/dev/null 2>&1; then
      echo "spec-allocator: could not renumber $old_id -> $new_id after offline collision; left provisional" >&2
      return 0
    fi
    if ! create_local_tag "$new_tag" "$subject"; then
      set_row_reservation "$new_id" "unavailable"
      echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $new_id" >&2
      return 0
    fi
    push_exit_status=0
    push_tag "$new_tag" || push_exit_status=$?
    if [ "$push_exit_status" -eq 0 ]; then
      set_row_reservation "$new_id" "reserved"
      return 0
    fi
    tag_existence="$(remote_reference_state "$new_tag")"
    delete_local_tag "$new_tag"
    case "$tag_existence" in
      exists)
        old_id="$new_id"
        attempt=$((attempt + 1))
        ;;
      absent)
        set_row_reservation "$new_id" "unavailable"
        echo "spec-allocator: cross-team collision-safety unavailable (tag namespace not writable): $new_id allocated from local numbering only" >&2
        return 0
        ;;
      error)
        return 0
        ;;
    esac
  done
  echo "spec-allocator: reservation retry exhausted reconciling $old_id; left provisional" >&2
  return 0
}

# Reconcile one provisional+draft row: push its deferred reservation, or renumber
# it if the number was taken on the remote while offline.
_reconcile_one_provisional() {
  local id="$1"
  local spec_number tag subject push_exit_status tag_existence
  spec_number=$((10#${id#SPEC-}))
  tag="$(printf 'spec/%03d' "$spec_number")"
  subject="$(jq -r --arg id "$id" '.specs[] | select(.id == $id) | .subject // empty' "$ledger_path" 2>/dev/null || true)"
  [ -z "$subject" ] && subject="$id"
  if ! create_local_tag "$tag" "$subject"; then
    set_row_reservation "$id" "unavailable"
    echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $id" >&2
    return 0
  fi
  push_exit_status=0
  push_tag "$tag" || push_exit_status=$?
  if [ "$push_exit_status" -eq 0 ]; then
    set_row_reservation "$id" "reserved"
    return 0
  fi
  tag_existence="$(remote_reference_state "$tag")"
  delete_local_tag "$tag"
  case "$tag_existence" in
    exists)
      _renumber_and_reserve "$id" "$subject"
      ;;
    absent)
      set_row_reservation "$id" "unavailable"
      echo "spec-allocator: cross-team collision-safety unavailable (tag namespace not writable): $id allocated from local numbering only" >&2
      ;;
    error)
      : # went unreachable mid-op; leave provisional for a future run
      ;;
  esac
  return 0
}

# Process every provisional+draft row (deferred push / renumber-on-collision).
# Only a still-provisional, not-yet-shared draft is renumber-eligible; a
# ready/merged row is left as accepted-stale. Runs with the ledger
# mutex ALREADY held (called from allocate_next and, wrapped, from the
# reserve_pending subcommand). Fail-open.
_reserve_pending_locked() {
  [ -f "$ledger_path" ] || return 0
  local ids id
  ids="$(jq -r '.specs[] | select(.reservation == "provisional" and .status == "draft") | .id' \
    "$ledger_path" 2>/dev/null || true)"
  [ -z "$ids" ] && return 0
  classify_remote
  if [ "$_remote_state" != "reachable" ]; then
    return 0 # offline: leave the rows; a future online run retries
  fi
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    _reconcile_one_provisional "$id"
  done <<EOF
$ids
EOF
  return 0
}

# ---- Allocation -------------------------------------------------------------

# Reservation loop for a reachable origin. Reserves union-max+1 with a non-force
# tag push; a rejected push whose ref now exists drives a bounded retry at the
# next number, exhaustion returns 4. A non-collision push failure degrades to
# local numbering (unavailable + warn); a mid-op unreachable falls to provisional.
reserve_reachable() {
  local requested_subject="$1"
  local attempt=0 candidate_number new_id tag subject push_exit_status tag_existence
  while [ "$attempt" -lt "$maximum_retries" ]; do
    candidate_number=$(( $(union_maximum) + 1 ))
    new_id="$(printf 'SPEC-%03d' "$candidate_number")"
    tag="$(printf 'spec/%03d' "$candidate_number")"
    subject="$(normalize_subject "$requested_subject")"
    [ -z "$subject" ] && subject="$new_id"
    if ! create_local_tag "$tag" "$subject"; then
      echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $new_id allocated from local numbering only" >&2
      append_ledger_row "$new_id" "unavailable" "$subject" || return $?
      printf '%s\n' "$new_id"
      return 0
    fi
    push_exit_status=0
    push_tag "$tag" || push_exit_status=$?
    if [ "$push_exit_status" -eq 0 ]; then
      append_ledger_row "$new_id" "reserved" "$subject" || return $?
      printf '%s\n' "$new_id"
      return 0
    fi
    tag_existence="$(remote_reference_state "$tag")"
    delete_local_tag "$tag"
    case "$tag_existence" in
      exists)
        # Another machine took the number; refresh the union and retry higher.
        attempt=$((attempt + 1))
        classify_remote
        if [ "$_remote_state" != "reachable" ]; then
          candidate_number=$(( $(union_maximum) + 1 ))
          new_id="$(printf 'SPEC-%03d' "$candidate_number")"
          subject="$(normalize_subject "$requested_subject")"
          [ -z "$subject" ] && subject="$new_id"
          append_ledger_row "$new_id" "provisional" "$subject" || return $?
          echo "spec-allocator: offline: $new_id reserved provisionally; the tag pushes on the next online allocation" >&2
          printf '%s\n' "$new_id"
          return 0
        fi
        ;;
      absent)
        echo "spec-allocator: cross-team collision-safety unavailable (tag namespace not writable): $new_id allocated from local numbering only" >&2
        append_ledger_row "$new_id" "unavailable" "$subject" || return $?
        printf '%s\n' "$new_id"
        return 0
        ;;
      error)
        append_ledger_row "$new_id" "provisional" "$subject" || return $?
        echo "spec-allocator: offline: $new_id reserved provisionally; the tag pushes on the next online allocation" >&2
        printf '%s\n' "$new_id"
        return 0
        ;;
    esac
  done
  echo "spec-allocator: reservation retry exhausted after $maximum_retries attempts; refuse to allocate (would risk duplicate SPEC ids)" >&2
  return 4
}

# The read-union-reserve-write critical section, run inside the ledger mutex so
# two parallel `next` calls cannot read the same union and allocate a duplicate
# id. Reconciles any prior provisional rows first, then classifies the remote
# once and reserves by state. append_ledger_row returns (not exits) 4 on jq
# failure; reserve_reachable returns 4 on retry exhaustion; both propagate so the
# helper passes them through and the trap still runs.
allocate_next() {
  local requested_subject="${1:-}"
  local next_number new_id subject
  _reserve_pending_locked
  classify_remote
  case "$_remote_state" in
    none)
      next_number=$(( $(union_maximum) + 1 ))
      new_id="$(printf 'SPEC-%03d' "$next_number")"
      subject="$(normalize_subject "$requested_subject")"
      [ -z "$subject" ] && subject="$new_id"
      append_ledger_row "$new_id" "local" "$subject" || return $?
      printf '%s\n' "$new_id"
      ;;
    unreachable)
      next_number=$(( $(union_maximum) + 1 ))
      new_id="$(printf 'SPEC-%03d' "$next_number")"
      subject="$(normalize_subject "$requested_subject")"
      [ -z "$subject" ] && subject="$new_id"
      append_ledger_row "$new_id" "provisional" "$subject" || return $?
      echo "spec-allocator: offline: $new_id reserved provisionally; the tag pushes on the next online allocation" >&2
      printf '%s\n' "$new_id"
      ;;
    reachable)
      reserve_reachable "$requested_subject" || return $?
      ;;
  esac
}

case "$mode" in
  next)
    require_git
    ensure_ledger
    # Lock-dir precondition: the dir must exist before with_ledger_lock.
    # ensure_ledger already mkdir -p's it via the ledger parent, but make the
    # precondition explicit and independent of ledger-init ordering.
    mkdir -p "$specs_directory"
    # Capture rc directly, NOT `if ! with_ledger_lock …; then rc=$?`: after a
    # `!`-negated command, $? is the negation's status (0), masking the real
    # rc. `|| rc=$?` preserves the helper's actual exit code under set -e.
    exit_status=0
    with_ledger_lock "$specs_directory" allocate_next "$subject_argument" || exit_status=$?
    if [ "$exit_status" -ne 0 ]; then
      if [ "$exit_status" -eq 75 ]; then
        echo "spec-allocator: could not acquire ledger lock; refuse to allocate (would risk duplicate SPEC ids)" >&2
        exit 4
      fi
      exit "$exit_status"   # propagate append_ledger_row's rc 4 / retry-exhaustion 4, etc.
    fi
    ;;
  reserve_pending)
    require_git
    ensure_ledger
    mkdir -p "$specs_directory"
    # Fail-open: process deferred reservations under the mutex, but always exit 0
    # (a lock timeout or reconcile snag must never fail a caller's /gaia-spec).
    with_ledger_lock "$specs_directory" _reserve_pending_locked || true
    exit 0
    ;;
  highest)
    highest_spec_number="$(highest_number)"
    if [ "$highest_spec_number" -eq 0 ]; then
      echo "none"
    else
      printf 'SPEC-%03d\n' "$highest_spec_number"
    fi
    ;;
  in_progress)
    in_progress_spec
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
