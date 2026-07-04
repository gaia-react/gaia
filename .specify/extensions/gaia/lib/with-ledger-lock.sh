#!/usr/bin/env bash
# with-ledger-lock.sh: Single shared mutex helper for .gaia/local/specs/ledger.json
# read-modify-write critical sections. Sourced (not executed) by sibling lib
# scripts (spec-allocator.sh, ledger-update.sh) so the locking logic is defined
# exactly once and cannot drift between two copies.
#
# Public function:
#   with_ledger_lock <lock_dir> <command> [args...]
#
# <lock_dir> is an already-existing directory (callers mkdir -p the ledger
# parent before calling, typically "${repo_root%/}/.gaia/local/specs"). <command> [args...]
# runs inside the held mutex; its exit code passes through unchanged.
#
# Lock primitive selection, in order:
#   1. GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 → atomic-mkdir lock (test knob).
#   2. flock present → flock on <lock_dir>/specs.lock (kernel releases the fd
#      on process death; no stale handling needed).
#   3. else → atomic-mkdir lock on <lock_dir>/specs.lock.d. mkdir is atomic on
#      POSIX/HFS+/APFS: the process that creates the dir owns the lock. macOS
#      has no util-linux flock, so this is the load-bearing path here.
#
# Deadlock prevention (mkdir path): a trap on EXIT INT TERM rmdirs the lock dir
# iff this process created it; a stale lock dir older than
# GAIA_LEDGER_LOCK_STALE_SECS is reclaimed and the mkdir retried once.
#
# Env knobs (all optional, read at call time):
#   GAIA_LEDGER_LOCK_TIMEOUT_SECS    acquisition timeout       (default 10)
#   GAIA_LEDGER_LOCK_STALE_SECS      stale-lock age threshold  (default 30)
#   GAIA_LEDGER_LOCK_POLL_SECS       inter-attempt sleep       (default 0.2)
#   GAIA_LEDGER_LOCK_FORCE_FALLBACK  =1 forces the mkdir path  (unset)
#
# Diagnostics go to stderr only; the helper writes nothing to stdout itself.
# On acquisition timeout it returns 75 (EX_TEMPFAIL); callers map this onto
# their own ledger-write-failure exit code (see spec-allocator.sh /
# ledger-update.sh headers).
#
# This file is sourced, not run: it only defines the function and reads no env
# until the function is called.

if ! declare -f with_ledger_lock >/dev/null 2>&1; then

with_ledger_lock() {
  local lock_dir="$1"
  shift

  local timeout_secs="${GAIA_LEDGER_LOCK_TIMEOUT_SECS:-10}"
  local stale_secs="${GAIA_LEDGER_LOCK_STALE_SECS:-30}"
  local poll_secs="${GAIA_LEDGER_LOCK_POLL_SECS:-0.2}"
  local force_fallback="${GAIA_LEDGER_LOCK_FORCE_FALLBACK:-}"

  # ---- flock path: kernel-backed, releases the fd on subshell exit ----------
  if [ "$force_fallback" != "1" ] && command -v flock >/dev/null 2>&1; then
    local lock_file="${lock_dir%/}/specs.lock"
    local rc=0
    # The subshell holds fd 9 on the lock file; flock blocks (with a timeout)
    # until it owns the lock, then runs the command. The fd, and therefore the
    # lock, releases when the subshell exits, even if the command fails or the
    # process is killed.
    (
      if ! flock -w "$timeout_secs" 9; then
        echo "with-ledger-lock: timed out acquiring $lock_dir lock" >&2
        exit 75
      fi
      "$@"
    ) 9>"$lock_file"
    rc=$?
    return "$rc"
  fi

  # ---- portable atomic-mkdir fallback --------------------------------------
  local lock_d="${lock_dir%/}/specs.lock.d"
  local owned=0
  local saved_exit saved_int saved_term

  # Snapshot any pre-existing traps so we can restore them on return and not
  # clobber a caller's handlers beyond the critical section.
  saved_exit="$(trap -p EXIT)"
  saved_int="$(trap -p INT)"
  saved_term="$(trap -p TERM)"

  _with_ledger_lock_release() {
    if [ "$owned" -eq 1 ]; then
      rmdir "$lock_d" 2>/dev/null || true
      owned=0
    fi
  }

  _with_ledger_lock_restore_traps() {
    if [ -n "$saved_exit" ]; then eval "$saved_exit"; else trap - EXIT; fi
    if [ -n "$saved_int" ]; then eval "$saved_int"; else trap - INT; fi
    if [ -n "$saved_term" ]; then eval "$saved_term"; else trap - TERM; fi
  }

  # Portable lock-dir age in seconds, or empty if it cannot be determined.
  _with_ledger_lock_age_secs() {
    local now mtime
    now="$(date +%s)"
    if mtime="$(stat -f %m "$lock_d" 2>/dev/null)"; then
      :
    elif mtime="$(stat -c %Y "$lock_d" 2>/dev/null)"; then
      :
    else
      return 1
    fi
    echo "$((now - mtime))"
  }

  trap '_with_ledger_lock_release' EXIT INT TERM

  local start_ts now_ts elapsed age
  start_ts="$(date +%s)"

  while true; do
    if mkdir "$lock_d" 2>/dev/null; then
      owned=1
      local rc=0
      "$@" || rc=$?
      _with_ledger_lock_release
      _with_ledger_lock_restore_traps
      return "$rc"
    fi

    # Lock held by someone else; reclaim if stale, then retry once.
    if age="$(_with_ledger_lock_age_secs)" && [ -n "$age" ] \
      && [ "$age" -gt "$stale_secs" ]; then
      rm -rf "$lock_d" 2>/dev/null || true
      if mkdir "$lock_d" 2>/dev/null; then
        owned=1
        local rc=0
        "$@" || rc=$?
        _with_ledger_lock_release
        _with_ledger_lock_restore_traps
        return "$rc"
      fi
    fi

    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))
    if [ "$elapsed" -ge "$timeout_secs" ]; then
      _with_ledger_lock_restore_traps
      echo "with-ledger-lock: timed out acquiring $lock_dir lock" >&2
      return 75
    fi

    sleep "$poll_secs"
  done
}

fi
