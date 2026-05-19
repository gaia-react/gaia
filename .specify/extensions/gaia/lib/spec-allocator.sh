#!/usr/bin/env bash
# spec-allocator.sh — Allocate SPEC-NNN ids using the .gaia/specs.json ledger,
# self-healed against deterministic markers in git (spec-NNN-* branches) and the
# working-tree SPEC files. The repo must be a git working tree.
#
# Usage:
#   spec-allocator.sh next <repo_root>      # prints next SPEC-NNN id, writes ledger row
#   spec-allocator.sh highest <repo_root>   # prints highest known SPEC-NNN, or "none"
#   spec-allocator.sh in_progress <repo_root>  # prints first in-progress SPEC id, or "none"
#
# Authority: git is the truth, .gaia/specs.json is a fast index. `next` performs a
# self-heal pass before allocating — any SPEC id found in a branch name (the
# deterministic marker that GAIA tooling creates) is treated as burned even if
# missing from the ledger. A skipped slot is strictly cheaper than a duplicate id.
# Commit messages are NOT scanned; they pick up free-text references (test
# fixtures, regression notes) that would inflate the highest id incorrectly.
#
# Concurrency: the `next` read-modify-write critical section runs under the
# shared ledger mutex from with-ledger-lock.sh (flock when present, atomic-mkdir
# fallback on stock macOS). Two parallel `/gaia spec` sessions cannot allocate a
# duplicate SPEC id. A lock-acquisition timeout (helper exit 75) maps to exit 4
# — callers (the speckit preset) already handle 4 as "allocation failed", so a
# new exit code would break their error handling. Lock env knobs
# (GAIA_LEDGER_LOCK_TIMEOUT_SECS / _STALE_SECS / _POLL_SECS /
# _FORCE_FALLBACK): see with-ledger-lock.sh. `highest` and `in_progress` are
# read-only and take NO lock.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: spec-allocator.sh {next|highest|in_progress} <repo_root>" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
specs_dir="${repo_root%/}/.gaia/local/specs"
ledger_path="${repo_root%/}/.gaia/specs.json"

# Source the shared ledger mutex from this script's own directory so it
# resolves identically from the speckit preset and from test copies of the
# lib dir (no hardcoded repo path — template-distributed, repo-relative).
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
# Sources (all deterministic markers — no free-text scanning):
#   1. .gaia/specs.json ledger
#   2. Local + remote branches matching ^spec-NNN-
#   3. Working-tree files .gaia/local/specs/SPEC-NNN.md
known_spec_numbers() {
  if [ -f "$ledger_path" ]; then
    jq -r '.specs[].id // empty' "$ledger_path" 2>/dev/null \
      | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
  fi

  git -C "$repo_root" for-each-ref --format='%(refname:short)' \
    'refs/heads/spec-*' 'refs/remotes/*/spec-*' 2>/dev/null \
    | sed -nE 's|^.*/?spec-0*([0-9]+)(-.*)?$|\1|p' || true

  if [ -d "$specs_dir" ]; then
    find "$specs_dir" -maxdepth 1 -type f -name 'SPEC-*.md' -print 2>/dev/null \
      | sed -nE 's|.*/SPEC-0*([0-9]+)\.md$|\1|p' || true
  fi
}

# Highest known SPEC number, or 0 if none.
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

# Append a new row to the ledger atomically.
append_ledger_row() {
  local id="$1"
  local now
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  ensure_ledger
  local tmp
  tmp="$(mktemp)"
  if ! jq --arg id "$id" --arg now "$now" \
    '.specs += [{id: $id, allocated_at: $now, source: "allocated", status: "draft"}]' \
    "$ledger_path" > "$tmp"; then
    rm -f "$tmp"
    echo "spec-allocator: failed to update ledger at $ledger_path" >&2
    # return (not exit) so the mkdir-lock trap still releases the lock dir;
    # allocate_next propagates this rc and `next)` re-maps it to exit 4.
    return 4
  fi
  mv "$tmp" "$ledger_path"
}

# Print the first in-flight SPEC id, or "none". Single-id, none-when-empty
# contract preserved. Source order:
#   1. Ledger rows with status draft OR in-progress (ledger array order). The
#      row is created at `next` (skill step 3), strictly before the first
#      draft-<spec_id>.md cache write, so this covers the widest in-flight
#      window — including the draft phase a parallel session would otherwise
#      miss.
#   2. Fallback: canonical .gaia/local/specs/SPEC-*.md frontmatter scan for
#      status: in-progress (legacy case — SPEC file in-progress but no ledger
#      row, e.g. a backfilled / hand-edited ledger).
in_progress_spec() {
  if [ -f "$ledger_path" ]; then
    local id
    id="$(jq -r '
      [.specs[] | select(.status == "draft" or .status == "in-progress")][0].id // empty
    ' "$ledger_path" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      printf '%s\n' "$id"
      return
    fi
  fi

  if [ ! -d "$specs_dir" ]; then
    echo "none"
    return
  fi
  local f
  while IFS= read -r -d '' f; do
    local in_fm=0 status="" id=""
    local line
    while IFS= read -r line; do
      if [ "$in_fm" -eq 0 ] && [ "$line" = "---" ]; then
        in_fm=1
        continue
      fi
      if [ "$in_fm" -eq 1 ] && [ "$line" = "---" ]; then
        break
      fi
      if [ "$in_fm" -eq 1 ]; then
        case "$line" in
          status:*)
            status="${line#status:}"
            status="${status## }"
            status="${status%% *}"
            ;;
          spec_id:*)
            id="${line#spec_id:}"
            id="${id## }"
            id="${id%% *}"
            ;;
        esac
      fi
    done < "$f"
    if [ "$status" = "in-progress" ] && [ -n "$id" ]; then
      echo "$id"
      return
    fi
  done < <(find "$specs_dir" -maxdepth 1 -type f -name 'SPEC-*.md' -print0 2>/dev/null | sort -z)
  echo "none"
}

# The read-modify-write critical section, run inside the ledger mutex so two
# parallel `next` calls cannot read the same highest_num and allocate a
# duplicate id. append_ledger_row returns (not exits) 4 on jq failure; we
# propagate that rc so the helper passes it through and the trap still runs.
allocate_next() {
  local h next new_id
  h="$(highest_num)"
  next=$((h + 1))
  new_id="$(printf 'SPEC-%03d' "$next")"
  append_ledger_row "$new_id" || return $?
  printf '%s\n' "$new_id"
}

case "$mode" in
  next)
    require_git
    ensure_ledger
    # C1 lock-dir precondition: the dir must exist before with_ledger_lock.
    # ensure_ledger already mkdir -p's it via the ledger parent, but make the
    # precondition explicit and independent of ledger-init ordering.
    mkdir -p "${repo_root%/}/.gaia"
    # Capture rc directly — NOT `if ! with_ledger_lock …; then rc=$?`: after a
    # `!`-negated command, $? is the negation's status (0), masking the real
    # rc. `|| rc=$?` preserves the helper's actual exit code under set -e.
    rc=0
    with_ledger_lock "${repo_root%/}/.gaia" allocate_next || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 75 ]; then
        echo "spec-allocator: could not acquire ledger lock; refuse to allocate (would risk duplicate SPEC ids)" >&2
        exit 4
      fi
      exit "$rc"   # propagate append_ledger_row's own rc 4, etc.
    fi
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
