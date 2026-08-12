#!/usr/bin/env bash
# bats-shards.sh: deterministic, discovery-based file-level sharder for this
# repo's bats suites, one matrix leg per shard.
#
# .github/workflows/audit-ci-tests.yml's `shards` job matrix calls `run
# <shard-id>` once per bats leg. `.gaia/tests/lib/bats-shards.bats` (this
# script's own guard suite) and `.gaia/tests/lib/audit-ci-shards.bats` (the
# workflow's guard suite) call `shards` and `files <id>` to prove the
# partition and the directory seam.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
#
# Usage:
#   bash .gaia/tests/bats-shards.sh shards              # shard ids, in order
#   bash .gaia/tests/bats-shards.sh files <shard-id>     # that shard's .bats paths
#   bash .gaia/tests/bats-shards.sh run <shard-id>       # bats those paths, one invocation
#   bash .gaia/tests/bats-shards.sh -h | --help
#
# Exit codes:
#   0  success (shards/files listed, or run's bats invocation passed)
#   1  run's bats invocation failed
#   2  usage error, unknown shard id, a shard resolving zero files, or a
#      pinned hook not found in HOOKS_DIR
#
# Why discovery over a checked-in file manifest: a manifest goes stale the
# moment a .bats file is added, and it fails SILENTLY -- the new file runs in
# no shard, the check greens, the pass count quietly drops. Round-robin over
# a fresh directory listing puts every new file in a shard automatically. The
# zero-files rule below is what keeps an empty directory from lying the same
# way in the other direction: a green "all passed" over zero work.
#
# Assignment rules: hooks-1 is the pinned list below; hooks-2/3/4 round-robin
# the rest of HOOKS_DIR (0-based index i -> hooks-$(( i % 3 + 2 )));
# scripts-1/2 round-robin SCRIPTS_TESTS_DIR (i -> scripts-$(( i % 2 + 1 )));
# audit and lib are their whole directories; misc is FORENSICS_DIR plus
# STATUSLINE_DIR combined.
#
# Directory seam: six variables below, each independently overridable from
# the environment. A value beginning with `/` is used AS-IS; any other value
# resolves against the repo root this script derives for itself, never
# against $PWD. This lets the guard suite drive every shard with an absolute
# mktemp -d tree without a $PWD-relative default silently prefixing it under
# the real repo root.
#
# Portability: runs on CI bash 5 and macOS /bin/bash 3.2.57. No mapfile, no
# declare -A, no ${var^^}, no wait -n, no eval. Every list is LC_ALL=C sorted
# so ordering never depends on the invoking locale.
set -euo pipefail

HOOKS_DIR="${HOOKS_DIR:-.gaia/tests/hooks}"
SCRIPTS_TESTS_DIR="${SCRIPTS_TESTS_DIR:-.gaia/scripts/tests}"
AUDIT_TESTS_DIR="${AUDIT_TESTS_DIR:-.github/audit/tests}"
LIB_DIR="${LIB_DIR:-.gaia/tests/lib}"
FORENSICS_DIR="${FORENSICS_DIR:-.gaia/tests/forensics}"
STATUSLINE_DIR="${STATUSLINE_DIR:-.gaia/tests/statusline}"

# Cost floor, not correctness: a file-level sharder cannot split one file, and
# local-janitor.bats is the heaviest file in the hooks suite (83 @test, each
# doing a full git init plus a bare origin plus a push), so it anchors hooks-1
# alone rather than folding into the round-robin split with the rest of
# HOOKS_DIR. An array so a future maintainer can pin a second file and add a
# fourth hooks shard without archaeology.
PINNED_HOOKS=(local-janitor.bats)

SHARD_IDS=(hooks-1 hooks-2 hooks-3 hooks-4 scripts-1 scripts-2 audit lib misc)

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"

usage() {
  printf 'Usage: bash .gaia/tests/bats-shards.sh shards\n'
  printf '       bash .gaia/tests/bats-shards.sh files <shard-id>\n'
  printf '       bash .gaia/tests/bats-shards.sh run <shard-id>\n'
  printf '       bash .gaia/tests/bats-shards.sh -h | --help\n'
}

die_usage() {
  printf 'bats-shards: %s\n' "$1" >&2
  usage >&2
  exit 2
}

is_known_shard() {
  local id="$1" s
  for s in "${SHARD_IDS[@]}"; do
    if [ "$s" = "$id" ]; then
      return 0
    fi
  done
  return 1
}

# A seam value beginning with `/` is absolute and used as-is; anything else
# resolves against REPO_ROOT, never against $PWD.
resolve_dir() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
  esac
}

# Inverse of resolve_dir for display: a path under REPO_ROOT prints
# repo-relative (".gaia/tests/hooks/x.bats"); a path outside it (an absolute
# seam override) prints as-is.
relativize() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Every *.bats directly inside the resolved $1, LC_ALL=C sorted. A bash 3.2
# glob over an empty or missing directory leaves the pattern literal, so
# [ -e ] filters that out rather than nullglob, which is bash 4+.
discover_bats() {
  local dir f
  dir="$(resolve_dir "$1")"
  for f in "$dir"/*.bats; do
    if [ -e "$f" ]; then
      relativize "$f"
    fi
  done | LC_ALL=C sort
}

# Reads newline-separated stdin into the global array `lines`. No mapfile
# (bash 4+); the `|| [ -n "$line" ]` clause keeps a final unterminated line,
# matching parse_table()'s idiom in run-bats-parallel.sh.
read_lines() {
  lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done
}

is_pinned_hook() {
  local base="$1" pinned
  for pinned in "${PINNED_HOOKS[@]}"; do
    if [ "$base" = "$pinned" ]; then
      return 0
    fi
  done
  return 1
}

files_hooks1() {
  local p base found pinned
  read_lines < <(discover_bats "$HOOKS_DIR")
  for pinned in "${PINNED_HOOKS[@]}"; do
    found=0
    for p in "${lines[@]}"; do
      base="${p##*/}"
      if [ "$base" = "$pinned" ]; then
        printf '%s\n' "$p"
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      printf 'bats-shards: pinned hook not found: %s (in %s)\n' "$pinned" "$HOOKS_DIR" >&2
      exit 2
    fi
  done
}

# 0-based index i over the sorted, pinned-subtracted HOOKS_DIR list goes to
# hooks-$(( i % 3 + 2 )).
hooks_round_robin() {
  local target="$1" p base i mod rest
  read_lines < <(discover_bats "$HOOKS_DIR")
  rest=()
  for p in "${lines[@]}"; do
    base="${p##*/}"
    if ! is_pinned_hook "$base"; then
      rest+=("$p")
    fi
  done
  i=0
  for p in "${rest[@]}"; do
    mod=$((i % 3 + 2))
    if [ "$mod" -eq "$target" ]; then
      printf '%s\n' "$p"
    fi
    i=$((i + 1))
  done
}

# 0-based index i over the sorted SCRIPTS_TESTS_DIR list goes to
# scripts-$(( i % 2 + 1 )).
scripts_round_robin() {
  local target="$1" p i mod
  read_lines < <(discover_bats "$SCRIPTS_TESTS_DIR")
  i=0
  for p in "${lines[@]}"; do
    mod=$((i % 2 + 1))
    if [ "$mod" -eq "$target" ]; then
      printf '%s\n' "$p"
    fi
    i=$((i + 1))
  done
}

files_for_shard() {
  case "$1" in
    hooks-1) files_hooks1 ;;
    hooks-2) hooks_round_robin 2 ;;
    hooks-3) hooks_round_robin 3 ;;
    hooks-4) hooks_round_robin 4 ;;
    scripts-1) scripts_round_robin 1 ;;
    scripts-2) scripts_round_robin 2 ;;
    audit) discover_bats "$AUDIT_TESTS_DIR" ;;
    lib) discover_bats "$LIB_DIR" ;;
    misc)
      discover_bats "$FORENSICS_DIR"
      discover_bats "$STATUSLINE_DIR"
      ;;
  esac
}

cmd_shards() {
  local s
  for s in "${SHARD_IDS[@]}"; do
    printf '%s\n' "$s"
  done
}

cmd_files() {
  local id="$1" out rc
  if ! is_known_shard "$id"; then
    printf 'bats-shards: unknown shard id: %s\n' "$id" >&2
    printf 'bats-shards: known ids: %s\n' "${SHARD_IDS[*]}" >&2
    exit 2
  fi
  rc=0
  out="$(files_for_shard "$id" | LC_ALL=C sort)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  if [ -z "$out" ]; then
    printf 'bats-shards: shard %s resolved zero files\n' "$id" >&2
    exit 2
  fi
  printf '%s\n' "$out"
}

cmd_run() {
  local id="$1" out rc line argv
  rc=0
  out="$(cmd_files "$id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  argv=()
  while IFS= read -r line || [ -n "$line" ]; do
    argv+=("$line")
  done <<EOF
$out
EOF
  bats "${argv[@]}"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h | --help)
      usage
      exit 0
      ;;
    shards)
      cmd_shards
      ;;
    files)
      [ $# -ge 2 ] || die_usage 'files needs a shard id'
      cmd_files "$2"
      ;;
    run)
      [ $# -ge 2 ] || die_usage 'run needs a shard id'
      cmd_run "$2"
      ;;
    '')
      die_usage 'missing command'
      ;;
    *)
      die_usage "unknown command: $cmd"
      ;;
  esac
}

main "$@"
