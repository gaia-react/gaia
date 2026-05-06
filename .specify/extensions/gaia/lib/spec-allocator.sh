#!/usr/bin/env bash
# spec-allocator.sh - Allocate the next SPEC-NNN id by scanning .gaia/local/specs/
#
# Usage:
#   spec-allocator.sh next <repo_root>      # prints next SPEC-NNN id (e.g. SPEC-002)
#   spec-allocator.sh highest <repo_root>   # prints highest existing SPEC-NNN, or "none"
#   spec-allocator.sh in_progress <repo_root>  # prints first in-progress SPEC id, or "none"
#
# Used by the wrapper to allocate ids and by before_specify.sh to detect resume candidates.
# Pure stdout; no side effects beyond reading the specs directory.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: spec-allocator.sh {next|highest|in_progress} <repo_root>" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
specs_dir="${repo_root%/}/.gaia/local/specs"

# Highest existing numeric suffix; 0 if directory missing or empty.
highest_num() {
  if [ ! -d "$specs_dir" ]; then
    echo 0
    return
  fi
  local max=0
  local f
  while IFS= read -r -d '' f; do
    local base
    base="$(basename "$f")"
    # Match SPEC-<digits>.md
    if [[ "$base" =~ ^SPEC-([0-9]+)\.md$ ]]; then
      local n="${BASH_REMATCH[1]}"
      # Strip leading zeros for numeric comparison.
      n=$((10#$n))
      if [ "$n" -gt "$max" ]; then
        max="$n"
      fi
    fi
  done < <(find "$specs_dir" -maxdepth 1 -type f -name 'SPEC-*.md' -print0 2>/dev/null)
  echo "$max"
}

# Print first SPEC-NNN whose frontmatter has status: in-progress; "none" if none.
in_progress_spec() {
  if [ ! -d "$specs_dir" ]; then
    echo "none"
    return
  fi
  local f
  while IFS= read -r -d '' f; do
    # Read frontmatter (between first two --- lines) and look for status: in-progress.
    local in_fm=0
    local status=""
    local id=""
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

case "$mode" in
  next)
    h="$(highest_num)"
    next=$((h + 1))
    printf 'SPEC-%03d\n' "$next"
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
