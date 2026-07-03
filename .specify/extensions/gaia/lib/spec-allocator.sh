#!/usr/bin/env bash
# spec-allocator.sh: Allocate SPEC-NNN ids using the .gaia/local/specs/ledger.json
# ledger, self-healed against deterministic markers in git (spec-NNN-* branches) and
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
# also maps to exit 4; callers (the speckit preset) already handle 4 as "allocation
# failed". Lock env knobs (GAIA_LEDGER_LOCK_TIMEOUT_SECS / _STALE_SECS / _POLL_SECS /
# _FORCE_FALLBACK): see with-ledger-lock.sh. Reservation env knobs:
#   GAIA_SPEC_REMOTE_TIMEOUT_SECS  per ls-remote / push bound (default 5)
#   GAIA_SPEC_ALLOC_MAX_RETRIES    reservation retry bound     (default 5)
#   GAIA_SPEC_FORCE_OFFLINE=1       force the unreachable path  (test knob)
# `highest` and `in_progress` are read-only, take NO lock, and never touch the network.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: spec-allocator.sh {next|highest|in_progress|reserve_pending} <repo_root> [<subject>]" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
subject_arg="${3:-}"
specs_dir="${repo_root%/}/.gaia/local/specs"
ledger_path="${repo_root%/}/.gaia/local/specs/ledger.json"

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
remote_timeout="${GAIA_SPEC_REMOTE_TIMEOUT_SECS:-5}"
max_retries="${GAIA_SPEC_ALLOC_MAX_RETRIES:-5}"

# A credential prompt on an HTTPS remote would hang /gaia-spec; disabling the
# terminal prompt makes every git remote op fail fast instead. Set for all git
# subprocesses this script spawns; it has no effect on the local-only ops.
export GIT_TERMINAL_PROMPT=0

# Set by classify_remote; read by union_max / the reservation paths.
_remote_state=""
_remote_tags_raw=""

# Source the shared ledger mutex from this script's own directory so it
# resolves identically from the speckit preset and from test copies of the
# lib dir (no hardcoded repo path, template-distributed, repo-relative).
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${_lib_dir}/with-ledger-lock.sh"

require_git() {
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "spec-allocator: $repo_root is not a git repository; refuse to allocate (would risk duplicate SPEC ids)" >&2
    exit 3
  fi
}

# Emit one bare integer per known SPEC number, one per line, unsorted.
# Sources (all deterministic LOCAL markers; no free-text scanning, no network):
#   1. .gaia/local/specs/ledger.json ledger
#   2. Local + remote branches matching ^spec-NNN-
#   3. Working-tree folders .gaia/local/specs/<spec_id>/SPEC.md
known_spec_numbers() {
  if [ -f "$ledger_path" ]; then
    jq -r '.specs[].id // empty' "$ledger_path" 2>/dev/null \
      | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
  fi

  git -C "$repo_root" for-each-ref --format='%(refname:short)' \
    'refs/heads/spec-*' 'refs/remotes/*/spec-*' 2>/dev/null \
    | sed -nE 's|^.*/?spec-0*([0-9]+)(-.*)?$|\1|p' || true

  if [ -d "$specs_dir" ]; then
    find "$specs_dir" -mindepth 2 -maxdepth 2 -type f -name 'SPEC.md' -print 2>/dev/null \
      | sed -nE 's|.*/SPEC-0*([0-9]+)/SPEC\.md$|\1|p' || true
  fi
}

# Highest known LOCAL SPEC number, or 0 if none. No network: the `highest`
# subcommand and read-only callers depend on this never hitting the remote.
highest_num() {
  require_git
  local max=0 n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done < <(known_spec_numbers | sort -un)
  echo "$max"
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
  local now tmp
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ensure_ledger
  tmp="$(mktemp)"
  if ! jq --arg id "$id" --arg now "$now" --arg reservation "$reservation" --arg subject "$subject" \
    '.specs += [{id: $id, allocated_at: $now, source: "allocated", status: "draft", reservation: $reservation, subject: $subject}]' \
    "$ledger_path" > "$tmp"; then
    rm -f "$tmp"
    echo "spec-allocator: failed to update ledger at $ledger_path" >&2
    # return (not exit) so the mkdir-lock trap still releases the lock dir;
    # allocate_next propagates this rc and `next)` re-maps it to exit 4.
    return 4
  fi
  mv "$tmp" "$ledger_path"
}

# Set an existing row's reservation state in place (mutex-protected pattern,
# NOT routed through ledger-update.sh's status guard which only vets `status`).
# Fail-open: a jq failure warns and returns 0 so a reconcile pass never crashes.
set_row_reservation() {
  local id="$1" state="$2" tmp
  [ -f "$ledger_path" ] || return 0
  tmp="$(mktemp)"
  if jq --arg id "$id" --arg st "$state" \
    '.specs |= map(if .id == $id then .reservation = $st else . end)' \
    "$ledger_path" > "$tmp"; then
    mv "$tmp" "$ledger_path"
  else
    rm -f "$tmp"
    echo "spec-allocator: failed to update reservation for $id" >&2
  fi
  return 0
}

# Print the first unfinalized (draft) SPEC id, or "none". Single-id,
# none-when-empty contract preserved.
#
# A SPEC is "in flight" for resume-vs-start-new purposes only while it is being
# authored. The ledger row is created at `next` (skill step 3) with status
# "draft" and flipped to "specified" when the SPEC artifact is finalized and
# frozen (skill step 8). Both transitions are owned by the same authoring
# session, so this signal cannot go stale on a fragile downstream chain.
#
# A finalized SPEC (specified / merged / archived) is downstream feature work
# tracked by branches and PRs, NOT a draft a new /gaia-spec session would
# resume, so it is deliberately not reported here. The merged transition is
# reconciled from git ground truth by spec-reconcile.sh, out of this read path.
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
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  "$@" &
  local cmd_pid=$!
  # Watchdog: TERM then (after a grace) KILL. stdout redirected off the caller's
  # pipe so a command-substitution reader gets EOF as soon as the command exits.
  { sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "$cmd_pid" 2>/dev/null; } >/dev/null 2>&1 &
  local watch_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return "$rc"
}

# Classify the origin remote into none | reachable | unreachable and, when
# reachable, capture the spec/* ls-remote output for the union. Sets globals
# _remote_state and _remote_tags_raw. Order: no origin wins over FORCE_OFFLINE.
classify_remote() {
  _remote_tags_raw=""
  local url out rc=0
  url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    _remote_state="none"
    return
  fi
  if [ "${GAIA_SPEC_FORCE_OFFLINE:-}" = "1" ]; then
    _remote_state="unreachable"
    return
  fi
  out="$(_run_with_timeout "$remote_timeout" \
    git -C "$repo_root" ls-remote --tags origin 'refs/tags/spec/*' 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _remote_state="unreachable"
    return
  fi
  _remote_state="reachable"
  _remote_tags_raw="$out"
}

# Emit bare integers from the captured ls-remote output. Handles the annotated
# tag's peeled ^{} line and strips leading zeros in the regex; union_max coerces
# base-10 as a second guard.
remote_tag_numbers() {
  [ -z "$_remote_tags_raw" ] && return 0
  printf '%s\n' "$_remote_tags_raw" \
    | sed -nE 's|^[0-9a-f]+[[:space:]]+refs/tags/spec/0*([0-9]+)(\^\{\})?$|\1|p'
}

# Max over the union of local signals and (when reachable) the remote spec/*
# tags. The union can only rise, never fall.
union_max() {
  local max n
  max="$(highest_num)"
  if [ "$_remote_state" = "reachable" ]; then
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      n=$((10#$n))
      [ "$n" -gt "$max" ] && max="$n"
    done < <(remote_tag_numbers)
  fi
  echo "$max"
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
  local tag="$1" rc=0
  _run_with_timeout "$remote_timeout" \
    git -C "$repo_root" push origin "refs/tags/$tag" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# Re-check whether a specific reservation ref exists on the remote after a failed
# push. Echoes exists | absent | error (error = remote went unreachable mid-op).
remote_ref_state() {
  local tag="$1" out rc=0
  out="$(_run_with_timeout "$remote_timeout" \
    git -C "$repo_root" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error"
    return
  fi
  if [ -n "$out" ]; then
    echo "exists"
  else
    echo "absent"
  fi
}

# ---- Deferred-reservation reconcile (renumber-on-collision) -----------------

# Renumber an in-flight provisional spec whose number was taken on the remote
# while offline to the next free number and reserve that number instead. Never
# keeps the collided number. Bounded by max_retries; fail-open (returns 0,
# leaving the row provisional, on any snag so a later run retries).
_renumber_and_reserve() {
  local old_id="$1" subject="$2"
  local attempt=0 newn new_id newtag prc rstate
  while [ "$attempt" -lt "$max_retries" ]; do
    classify_remote
    if [ "$_remote_state" != "reachable" ]; then
      return 0
    fi
    newn=$(( $(union_max) + 1 ))
    new_id="$(printf 'SPEC-%03d' "$newn")"
    newtag="$(printf 'spec/%03d' "$newn")"
    if ! bash "${_lib_dir}/spec-renumber.sh" "$repo_root" "$old_id" "$new_id" >/dev/null 2>&1; then
      echo "spec-allocator: could not renumber $old_id -> $new_id after offline collision; left provisional" >&2
      return 0
    fi
    if ! create_local_tag "$newtag" "$subject"; then
      set_row_reservation "$new_id" "unavailable"
      echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $new_id" >&2
      return 0
    fi
    prc=0
    push_tag "$newtag" || prc=$?
    if [ "$prc" -eq 0 ]; then
      set_row_reservation "$new_id" "reserved"
      return 0
    fi
    rstate="$(remote_ref_state "$newtag")"
    delete_local_tag "$newtag"
    case "$rstate" in
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
  local num tag subject prc rstate
  num=$((10#${id#SPEC-}))
  tag="$(printf 'spec/%03d' "$num")"
  subject="$(jq -r --arg id "$id" '.specs[] | select(.id == $id) | .subject // empty' "$ledger_path" 2>/dev/null || true)"
  [ -z "$subject" ] && subject="$id"
  if ! create_local_tag "$tag" "$subject"; then
    set_row_reservation "$id" "unavailable"
    echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $id" >&2
    return 0
  fi
  prc=0
  push_tag "$tag" || prc=$?
  if [ "$prc" -eq 0 ]; then
    set_row_reservation "$id" "reserved"
    return 0
  fi
  rstate="$(remote_ref_state "$tag")"
  delete_local_tag "$tag"
  case "$rstate" in
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
# specified/merged/archived row is left as accepted-stale. Runs with the ledger
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
  local subj_arg="$1"
  local attempt=0 n new_id tag subject prc rstate
  while [ "$attempt" -lt "$max_retries" ]; do
    n=$(( $(union_max) + 1 ))
    new_id="$(printf 'SPEC-%03d' "$n")"
    tag="$(printf 'spec/%03d' "$n")"
    subject="$(normalize_subject "$subj_arg")"
    [ -z "$subject" ] && subject="$new_id"
    if ! create_local_tag "$tag" "$subject"; then
      echo "spec-allocator: cross-team collision-safety unavailable (could not create reservation tag): $new_id allocated from local numbering only" >&2
      append_ledger_row "$new_id" "unavailable" "$subject" || return $?
      printf '%s\n' "$new_id"
      return 0
    fi
    prc=0
    push_tag "$tag" || prc=$?
    if [ "$prc" -eq 0 ]; then
      append_ledger_row "$new_id" "reserved" "$subject" || return $?
      printf '%s\n' "$new_id"
      return 0
    fi
    rstate="$(remote_ref_state "$tag")"
    delete_local_tag "$tag"
    case "$rstate" in
      exists)
        # Another machine took the number; refresh the union and retry higher.
        attempt=$((attempt + 1))
        classify_remote
        if [ "$_remote_state" != "reachable" ]; then
          n=$(( $(union_max) + 1 ))
          new_id="$(printf 'SPEC-%03d' "$n")"
          subject="$(normalize_subject "$subj_arg")"
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
  echo "spec-allocator: reservation retry exhausted after $max_retries attempts; refuse to allocate (would risk duplicate SPEC ids)" >&2
  return 4
}

# The read-union-reserve-write critical section, run inside the ledger mutex so
# two parallel `next` calls cannot read the same union and allocate a duplicate
# id. Reconciles any prior provisional rows first, then classifies the remote
# once and reserves by state. append_ledger_row returns (not exits) 4 on jq
# failure; reserve_reachable returns 4 on retry exhaustion; both propagate so the
# helper passes them through and the trap still runs.
allocate_next() {
  local subj_arg="${1:-}"
  local n new_id subject
  _reserve_pending_locked
  classify_remote
  case "$_remote_state" in
    none)
      n=$(( $(union_max) + 1 ))
      new_id="$(printf 'SPEC-%03d' "$n")"
      subject="$(normalize_subject "$subj_arg")"
      [ -z "$subject" ] && subject="$new_id"
      append_ledger_row "$new_id" "local" "$subject" || return $?
      printf '%s\n' "$new_id"
      ;;
    unreachable)
      n=$(( $(union_max) + 1 ))
      new_id="$(printf 'SPEC-%03d' "$n")"
      subject="$(normalize_subject "$subj_arg")"
      [ -z "$subject" ] && subject="$new_id"
      append_ledger_row "$new_id" "provisional" "$subject" || return $?
      echo "spec-allocator: offline: $new_id reserved provisionally; the tag pushes on the next online allocation" >&2
      printf '%s\n' "$new_id"
      ;;
    reachable)
      reserve_reachable "$subj_arg" || return $?
      ;;
  esac
}

case "$mode" in
  next)
    require_git
    ensure_ledger
    # C1 lock-dir precondition: the dir must exist before with_ledger_lock.
    # ensure_ledger already mkdir -p's it via the ledger parent, but make the
    # precondition explicit and independent of ledger-init ordering.
    mkdir -p "${repo_root%/}/.gaia"
    # Capture rc directly, NOT `if ! with_ledger_lock …; then rc=$?`: after a
    # `!`-negated command, $? is the negation's status (0), masking the real
    # rc. `|| rc=$?` preserves the helper's actual exit code under set -e.
    rc=0
    with_ledger_lock "${repo_root%/}/.gaia" allocate_next "$subject_arg" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 75 ]; then
        echo "spec-allocator: could not acquire ledger lock; refuse to allocate (would risk duplicate SPEC ids)" >&2
        exit 4
      fi
      exit "$rc"   # propagate append_ledger_row's rc 4 / retry-exhaustion 4, etc.
    fi
    ;;
  reserve_pending)
    require_git
    ensure_ledger
    mkdir -p "${repo_root%/}/.gaia"
    # Fail-open: process deferred reservations under the mutex, but always exit 0
    # (a lock timeout or reconcile snag must never fail a caller's /gaia-spec).
    with_ledger_lock "${repo_root%/}/.gaia" _reserve_pending_locked || true
    exit 0
    ;;
  highest)
    h="$(highest_num)"
    if [ "$h" -eq 0 ]; then
      echo "none"
    else
      printf 'SPEC-%03d\n' "$h"
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
