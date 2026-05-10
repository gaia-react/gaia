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
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: spec-allocator.sh {next|highest|in_progress} <repo_root>" >&2
  exit 2
fi

mode="$1"
repo_root="$2"
specs_dir="${repo_root%/}/.gaia/local/specs"
ledger_path="${repo_root%/}/.gaia/specs.json"

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
    exit 4
  fi
  mv "$tmp" "$ledger_path"
}

# Print the first SPEC whose frontmatter has status: in-progress; "none" if none.
in_progress_spec() {
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

case "$mode" in
  next)
    h="$(highest_num)"
    next=$((h + 1))
    new_id="$(printf 'SPEC-%03d' "$next")"
    append_ledger_row "$new_id"
    echo "$new_id"
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
