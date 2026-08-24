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
#   bash .gaia/tests/bats-shards.sh group <shard-id>     # its exchange group's ids
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
# no shard, the check greens, the pass count quietly drops. Assigning over a
# fresh directory listing puts every new file in a shard automatically. The
# zero-files rule below is what keeps an empty directory from lying the same
# way in the other direction: a green "all passed" over zero work.
#
# Assignment rules: hooks-1 is the pinned list below; HOOKS_GREEDY_IDS split
# the rest of HOOKS_DIR by weight, SCRIPTS_IDS split SCRIPTS_TESTS_DIR the same
# way; audit and lib are their whole directories; misc is FORENSICS_DIR plus
# STATUSLINE_DIR combined.
#
# Exchange groups, which `group <shard-id>` reports. A shard's group is the set
# of ids a file can move BETWEEN without anyone editing this script: the two
# weighted groups exchange files among their own buckets on every size change,
# and every other shard is a group of one, because its files are selected by
# name (hooks-1) or by whole directory (audit, lib, misc) and no reshuffle can
# move one across that boundary. A caller that must stay correct across
# reshuffles asks about the group rather than the shard; the apt step in
# .github/workflows/audit-ci-tests.yml is the one that does.
#
# Why weight rather than count. A shard's cost is the sum of its files'
# runtimes, and file COUNT is a poor proxy for that: per-file setup dominates
# per-test work here, so one 22-second file holds 185 @test and another holds
# 1. Against a per-file timing of the whole suite, a file's SIZE IN BYTES
# correlates with its runtime at r=0.80 where its @test count manages r=0.42.
# Counting files therefore leaves shards that are even in files and lopsided in
# minutes, and the local wall clock is the slowest shard.
#
# Size is read from the tree at discovery time, which is what keeps this pure
# discovery. A checked-in table of per-file runtimes would be a better proxy
# still, and it would reintroduce exactly the stale-manifest hazard this
# script's whole design rejects: a new file would weigh nothing, and nothing
# would say so.
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
#
# Every array expansion below is written ${arr[@]+"${arr[@]}"} rather than
# "${arr[@]}", which is not style: on bash 3.2 an EMPTY array expanded bare
# under `set -u` aborts with `arr[@]: unbound variable`. A seam directory that
# resolves zero .bats files hits exactly that, and the script would exit 1 on
# an unbound variable instead of taking the documented fail-closed exit 2 path
# below, defeating the zero-files guard. bash 5 does not reproduce it, so the
# guard suite is blind to the class; .gaia/scripts/lint-hook-array-guard.sh is
# the repo's detector for it.
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
# alone rather than folding into the weighted split with the rest of
# HOOKS_DIR. An array so a future maintainer can pin a second file and add a
# fifth hooks shard without archaeology.
#
# It is also half of the partition's floor. This one file runs about 150
# seconds and the whole AUDIT_TESTS_DIR shard runs about the same, and neither
# splits further, so no arrangement of the weighted groups takes the slowest
# shard below that. Group sizes are chosen against that floor rather than
# against each other; `wiki/decisions/Sharded CI Test Matrix.md` carries the
# measurements and why the groups stop where they do.
PINNED_HOOKS=(local-janitor.bats)

# The two weighted groups, each listed once and in matrix order. Adding a shard
# to a group is a one-word edit here: SHARD_IDS is built from these rather than
# restated, so the id list and the assignment cannot disagree about how many
# buckets a group has.
HOOKS_GREEDY_IDS=(hooks-2 hooks-3 hooks-4)
SCRIPTS_IDS=(scripts-1 scripts-2 scripts-3)

SHARD_IDS=(
  hooks-1
  ${HOOKS_GREEDY_IDS[@]+"${HOOKS_GREEDY_IDS[@]}"}
  ${SCRIPTS_IDS[@]+"${SCRIPTS_IDS[@]}"}
  audit lib misc
)

TAB="$(printf '\t')"

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"

usage() {
  printf 'Usage: bash .gaia/tests/bats-shards.sh shards\n'
  printf '       bash .gaia/tests/bats-shards.sh files <shard-id>\n'
  printf '       bash .gaia/tests/bats-shards.sh group <shard-id>\n'
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
  for s in ${SHARD_IDS[@]+"${SHARD_IDS[@]}"}; do
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
  for pinned in ${PINNED_HOOKS[@]+"${PINNED_HOOKS[@]}"}; do
    if [ "$base" = "$pinned" ]; then
      return 0
    fi
  done
  return 1
}

files_hooks1() {
  local p base found pinned
  read_lines < <(discover_bats "$HOOKS_DIR")
  for pinned in ${PINNED_HOOKS[@]+"${PINNED_HOOKS[@]}"}; do
    found=0
    for p in ${lines[@]+"${lines[@]}"}; do
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

# `<bytes><TAB><path>` for every discovered .bats file in the resolved $1,
# heaviest first, path ascending within an equal size, so the walk order below
# is total and depends on neither the directory order nor the locale. Pass
# `pinned` as $2 to hold out PINNED_HOOKS, which files_hooks1 assigns instead.
#
# An unreadable file weighs 0 rather than aborting: it still lands in exactly
# one shard, so the partition stays whole and only the balance degrades. The
# alternative fails the whole listing over a file the sharder does not read.
weighted_list() {
  local dir="$1" mode="$2" p base abs size
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    base="${p##*/}"
    if [ "$mode" = pinned ] && is_pinned_hook "$base"; then
      continue
    fi
    case "$p" in
      /*) abs="$p" ;;
      *) abs="$REPO_ROOT/$p" ;;
    esac
    size=0
    if [ -r "$abs" ]; then
      size="$(wc -c <"$abs" | tr -d ' ')"
    fi
    printf '%s%s%s\n' "$size" "$TAB" "$p"
  done < <(discover_bats "$dir") | LC_ALL=C sort -t"$TAB" -k1,1nr -k2,2
}

# Greedy longest-processing-time assignment of directory $1's discovered files
# across the shard ids from $4 on, printing the ones that land on target id $2.
# $3 is `pinned` or `all`, forwarded to weighted_list.
#
# Walk the files heaviest first and give each to the lightest bucket so far,
# ties to the lowest-numbered shard. LPT is not optimal, but the arrangement it
# misses by is far inside the run-to-run noise of the runtimes it approximates,
# and it needs no search, so the assignment stays a single pass a reader can
# follow.
greedy_bucket() {
  local dir="$1" target="$2" mode="$3"
  shift 3
  local ids n i best target_idx id size p loads
  ids=("$@")
  n=$#

  target_idx=-1
  i=0
  for id in ${ids[@]+"${ids[@]}"}; do
    if [ "$id" = "$target" ]; then
      target_idx=$i
    fi
    i=$((i + 1))
  done
  if [ "$target_idx" -lt 0 ]; then
    printf 'bats-shards: %s is not one of this group'"'"'s shards\n' "$target" >&2
    exit 2
  fi

  loads=()
  i=0
  while [ "$i" -lt "$n" ]; do
    loads+=(0)
    i=$((i + 1))
  done

  while IFS="$TAB" read -r size p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    best=0
    i=1
    while [ "$i" -lt "$n" ]; do
      if [ "${loads[$i]}" -lt "${loads[$best]}" ]; then
        best=$i
      fi
      i=$((i + 1))
    done
    if [ "$best" -eq "$target_idx" ]; then
      printf '%s\n' "$p"
    fi
    loads[best]=$((loads[best] + size))
  done < <(weighted_list "$dir" "$mode")
}

files_for_shard() {
  case "$1" in
    hooks-1) files_hooks1 ;;
    hooks-*)
      greedy_bucket "$HOOKS_DIR" "$1" pinned \
        ${HOOKS_GREEDY_IDS[@]+"${HOOKS_GREEDY_IDS[@]}"}
      ;;
    scripts-*)
      greedy_bucket "$SCRIPTS_TESTS_DIR" "$1" all \
        ${SCRIPTS_IDS[@]+"${SCRIPTS_IDS[@]}"}
      ;;
    audit) discover_bats "$AUDIT_TESTS_DIR" ;;
    lib) discover_bats "$LIB_DIR" ;;
    misc)
      discover_bats "$FORENSICS_DIR"
      discover_bats "$STATUSLINE_DIR"
      ;;
  esac
}

# The ids sharing $1's exchange group, in matrix order, $1 included. Mirrors
# files_for_shard's case structure deliberately: the two answer the same
# question about the same boundaries, so a group added there without a case
# here is a discrepancy cmd_group's empty-output guard fails on rather than
# papering over with a default arm.
group_for_shard() {
  local id
  case "$1" in
    hooks-1) printf '%s\n' hooks-1 ;;
    hooks-*)
      for id in ${HOOKS_GREEDY_IDS[@]+"${HOOKS_GREEDY_IDS[@]}"}; do
        printf '%s\n' "$id"
      done
      ;;
    scripts-*)
      for id in ${SCRIPTS_IDS[@]+"${SCRIPTS_IDS[@]}"}; do
        printf '%s\n' "$id"
      done
      ;;
    audit | lib | misc) printf '%s\n' "$1" ;;
  esac
}

cmd_shards() {
  local s
  for s in ${SHARD_IDS[@]+"${SHARD_IDS[@]}"}; do
    printf '%s\n' "$s"
  done
}

cmd_files() {
  local id="$1" out rc
  if ! is_known_shard "$id"; then
    printf 'bats-shards: unknown shard id: %s\n' "$id" >&2
    printf 'bats-shards: known ids: %s\n' "${SHARD_IDS[*]+"${SHARD_IDS[*]}"}" >&2
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

cmd_group() {
  local id="$1" out
  if ! is_known_shard "$id"; then
    printf 'bats-shards: unknown shard id: %s\n' "$id" >&2
    printf 'bats-shards: known ids: %s\n' "${SHARD_IDS[*]+"${SHARD_IDS[*]}"}" >&2
    exit 2
  fi
  out="$(group_for_shard "$id")"
  # Fail closed rather than print nothing. A known id reaching this empty means
  # group_for_shard has no case for it, and a caller rounding a set up to whole
  # groups would silently drop that shard instead of widening to it.
  if [ -z "$out" ]; then
    printf 'bats-shards: shard %s belongs to no declared exchange group\n' "$id" >&2
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
  # `files` prints repo-relative paths for display, but bats resolves its
  # arguments against $PWD, so handing those through unchanged would make `run`
  # work only from the repo root while discovery itself is $PWD-independent.
  # Re-absolutize here, so both halves of the script agree. An absolute seam
  # override already prints absolute and is passed through untouched.
  argv=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      /*) argv+=("$line") ;;
      *) argv+=("$REPO_ROOT/$line") ;;
    esac
  done <<EOF
$out
EOF
  bats ${argv[@]+"${argv[@]}"}
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
    group)
      [ $# -ge 2 ] || die_usage 'group needs a shard id'
      cmd_group "$2"
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
