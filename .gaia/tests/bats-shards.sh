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
#   2  a usage error, or any refusal to answer: every one prints a
#      `bats-shards:` line to stderr naming its own cause. Stated as a pointer
#      rather than a list because the list is what went wrong twice: it was
#      written as exhaustive, fell behind the code as arms were added, and
#      completing it only restarts the same decay from a fresher number.
#
# Why discovery over a checked-in file manifest: a manifest goes stale the
# moment a .bats file is added, and it fails SILENTLY -- the new file runs in
# no shard, the check greens, the pass count quietly drops. Assigning over a
# fresh directory listing puts every new file in a shard automatically. The
# zero-files rule below is what keeps an empty directory from lying the same
# way in the other direction: a green "all passed" over zero work.
#
# Assignment rules: hooks-1 is the pinned list below; HOOKS_GREEDY_IDS split
# the rest of HOOKS_DIRECTORY by weight, SCRIPTS_IDS split SCRIPTS_TESTS_DIRECTORY the same
# way; audit and lib are their whole directories; misc is FORENSICS_DIRECTORY plus
# STATUSLINE_DIRECTORY combined.
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
# 1. Counting files therefore leaves shards that are even in files and lopsided
# in minutes, and the local wall clock is the slowest shard.
#
# SIZE IN BYTES is the better proxy a pure discovery pass can compute, and it
# is a proxy rather than an identity. Timed one file at a time across
# SCRIPTS_TESTS_DIRECTORY it predicts runtime at r=0.43 over that group as it stands
# and at r=0.73 with SCRIPTS_COST_OUTLIERS set aside, so it is sound for the
# ordinary members and blind to exactly the files that list names. Anchoring
# those is what covers the gap; the weight itself stays bytes for every file.
#
# Size is read from the tree at discovery time, which is what keeps this pure
# discovery. A checked-in table of per-file runtimes would be a better proxy
# still, and it would reintroduce exactly the stale-manifest hazard this
# script's whole design rejects: a new file would weigh nothing, and nothing
# would say so. SCRIPTS_COST_OUTLIERS is not that table and does not reopen the
# hazard: it carries no runtimes and changes no file's weight, it decides which
# BUCKET a named file takes, and a file it does not name weighs its bytes as
# before rather than weighing nothing. A name it carries that discovery does
# not return is an error rather than a silent no-op, which is the half the
# rejected table could not offer.
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

HOOKS_DIRECTORY="${HOOKS_DIRECTORY:-.gaia/tests/hooks}"
# Named as a constant as well as a default because SCRIPTS_COST_OUTLIERS below
# describes THIS directory's contents: comparing the resolved seam against it
# is what tells a stale entry apart from a seam a caller has pointed elsewhere.
SCRIPTS_TESTS_DIRECTORY_DEFAULT='.gaia/scripts/tests'
SCRIPTS_TESTS_DIRECTORY="${SCRIPTS_TESTS_DIRECTORY:-$SCRIPTS_TESTS_DIRECTORY_DEFAULT}"
AUDIT_TESTS_DIRECTORY="${AUDIT_TESTS_DIRECTORY:-.github/audit/tests}"
LIBRARY_DIRECTORY="${LIBRARY_DIRECTORY:-.gaia/tests/lib}"
FORENSICS_DIRECTORY="${FORENSICS_DIRECTORY:-.gaia/tests/forensics}"
STATUSLINE_DIRECTORY="${STATUSLINE_DIRECTORY:-.gaia/tests/statusline}"

# Cost floor, not correctness: a file-level sharder cannot split one file, and
# local-janitor.bats is the heaviest file in the hooks suite (38 @test, each
# doing a full git init plus a bare origin plus a push), so it anchors hooks-1
# alone rather than folding into the weighted split with the rest of
# HOOKS_DIRECTORY. An array so a future maintainer can pin a second file and add a
# fifth hooks shard without archaeology.
#
# It is also half of the partition's floor. This one file runs about 150
# seconds and the whole AUDIT_TESTS_DIRECTORY shard runs about the same, and neither
# splits further, so no arrangement of the weighted groups takes the slowest
# shard below that. Group sizes are chosen against that floor rather than
# against each other; `wiki/decisions/Sharded CI Test Matrix.md` carries the
# measurements and why the groups stop where they do.
PINNED_HOOKS=(local-janitor.bats)

# The scripts group's cost outliers: suites whose runtime lives in what they
# INVOKE rather than in what they contain, which is the one thing a byte weight
# cannot see. Each of these drives a whole-tree gate per assertion, so its cost
# tracks the size of the tree it sweeps and not the size of its own text, and
# the weight below reads it as an ordinary file of that many bytes.
#
# The drift is measured, not asserted. Timed one file at a time across the
# whole group, a file's size predicts its runtime at r=0.43 with these two in
# and at r=0.73 with them out, so the proxy is sound for the group's other
# members and wrong for exactly these. They also dominate: between them they
# carry better than a third of the group's wall clock, and the next suite
# behind them costs under a quarter of either. Those are shares rather than
# counts on purpose, since the group gains suites and a count taken once goes
# quietly wrong; `wiki/decisions/Sharded CI Test Matrix.md` carries the run.
#
# What that combination breaks is the partition, not the estimate. Weighed by
# bytes these two are unremarkable, so which bucket each lands in is decided by
# the packing of everything around them, and a tree change anywhere in the
# group can move them together. That draw is what reds the leg: co-located they
# exceed .github/workflows/audit-ci-tests.yml's per-shard cap and the job is
# cancelled with no failing assertion. Naming them here holds them in distinct
# buckets so no draw can produce it, which is what splitting one of them into
# halves could not do on its own -- a split divides the text, and the cost
# stayed with the half that kept the whole-tree runs.
#
# Membership rule for a future maintainer: a suite belongs here when its cost
# is dominated by an external command it runs per test, and it does NOT belong
# here merely for being slow or large. A suite left out weighs its bytes, which
# is today's behaviour and degrades no further; the ordering below decides
# which bucket each named suite anchors, so keep the list shorter than
# SCRIPTS_IDS. `wiki/decisions/Sharded CI Test Matrix.md` carries the
# measurements.
SCRIPTS_COST_OUTLIERS=(shell-lint.bats)

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
  local id="$1" known_shard_id
  for known_shard_id in ${SHARD_IDS[@]+"${SHARD_IDS[@]}"}; do
    if [ "$known_shard_id" = "$id" ]; then
      return 0
    fi
  done
  return 1
}

# A seam value beginning with `/` is absolute and used as-is; anything else
# resolves against REPO_ROOT, never against $PWD.
resolve_directory() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
  esac
}

# Inverse of resolve_directory for display: a path under REPO_ROOT prints
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
  local directory bats_file
  directory="$(resolve_directory "$1")"
  for bats_file in "$directory"/*.bats; do
    if [ -e "$bats_file" ]; then
      relativize "$bats_file"
    fi
  done | LC_ALL=C sort
}

# Reads newline-separated stdin into the global array `lines`. No mapfile
# (bash 4+); the `|| [ -n "$line" ]` clause keeps a final unterminated line.
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
  local bats_path base found pinned
  read_lines < <(discover_bats "$HOOKS_DIRECTORY")
  for pinned in ${PINNED_HOOKS[@]+"${PINNED_HOOKS[@]}"}; do
    found=0
    for bats_path in ${lines[@]+"${lines[@]}"}; do
      base="${bats_path##*/}"
      if [ "$base" = "$pinned" ]; then
        printf '%s\n' "$bats_path"
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      printf 'bats-shards: pinned hook not found: %s (in %s)\n' "$pinned" "$HOOKS_DIRECTORY" >&2
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
  local directory="$1" mode="$2" bats_path base absolute_path size
  while IFS= read -r bats_path || [ -n "$bats_path" ]; do
    [ -n "$bats_path" ] || continue
    base="${bats_path##*/}"
    if [ "$mode" = pinned ] && is_pinned_hook "$base"; then
      continue
    fi
    case "$bats_path" in
      /*) absolute_path="$bats_path" ;;
      *) absolute_path="$REPO_ROOT/$bats_path" ;;
    esac
    size=0
    if [ -r "$absolute_path" ]; then
      size="$(wc -c <"$absolute_path" | tr -d ' ')"
    fi
    printf '%s%s%s\n' "$size" "$TAB" "$bats_path"
  done < <(discover_bats "$directory") | LC_ALL=C sort -t"$TAB" -k1,1nr -k2,2
}

# Greedy longest-processing-time assignment of directory $1's discovered files
# across the shard ids from $5 on, printing the ones that land on target id $2.
# $3 is `pinned` or `all`, forwarded to weighted_list. $4 is a space-separated
# list of anchored basenames, empty for a group that names none.
#
# Walk the files heaviest first and give each to the lightest bucket so far,
# ties to the lowest-numbered shard. LPT is not optimal, but the arrangement it
# misses by is far inside the run-to-run noise of the runtimes it approximates,
# and it needs no search, so the assignment stays a single pass a reader can
# follow.
#
# An ANCHORED file skips that choice and takes the bucket its position in $4
# names, the first to the first shard, the second to the second, so two of them
# can never share a leg however the rest of the group packs. Its own weight
# still joins that bucket's load, so every later choice is made against what
# the bucket really holds. Anchoring decides a file's bucket, never whether it
# is assigned at all: an anchored file is walked, printed and counted exactly
# like any other, so the partition stays whole by construction rather than by
# the caller remembering to hold the set out and put it back.
greedy_bucket() {
  local directory="$1" target="$2" mode="$3" anchors="$4"
  shift 4
  local ids bucket_count i best target_index id size bats_path loads base
  local anchor_names anchor_indexes anchor_count
  ids=("$@")
  bucket_count=$#

  # Anchors, in listed order, one per shard from the first. Read into parallel
  # indexed arrays rather than one associative array, which bash 3.2 lacks.
  anchor_names=()
  anchor_indexes=()
  anchor_count=0
  for base in ${anchors}; do
    anchor_names+=("$base")
    anchor_indexes+=("$anchor_count")
    anchor_count=$((anchor_count + 1))
  done
  if [ "$anchor_count" -gt "$bucket_count" ]; then
    printf 'bats-shards: %s anchored files over %s shards in %s\n' \
      "$anchor_count" "$bucket_count" "$directory" >&2
    exit 2
  fi

  target_index=-1
  i=0
  for id in ${ids[@]+"${ids[@]}"}; do
    if [ "$id" = "$target" ]; then
      target_index=$i
    fi
    i=$((i + 1))
  done
  if [ "$target_index" -lt 0 ]; then
    printf 'bats-shards: %s is not one of this group'"'"'s shards\n' "$target" >&2
    exit 2
  fi

  loads=()
  i=0
  while [ "$i" -lt "$bucket_count" ]; do
    loads+=(0)
    i=$((i + 1))
  done

  while IFS="$TAB" read -r size bats_path || [ -n "$bats_path" ]; do
    [ -n "$bats_path" ] || continue
    base="${bats_path##*/}"
    best=-1
    i=0
    while [ "$i" -lt "$anchor_count" ]; do
      if [ "$base" = "${anchor_names[$i]}" ]; then
        best="${anchor_indexes[$i]}"
        break
      fi
      i=$((i + 1))
    done
    if [ "$best" -lt 0 ]; then
      best=0
      i=1
      while [ "$i" -lt "$bucket_count" ]; do
        if [ "${loads[$i]}" -lt "${loads[$best]}" ]; then
          best=$i
        fi
        i=$((i + 1))
      done
    fi
    if [ "$best" -eq "$target_index" ]; then
      printf '%s\n' "$bats_path"
    fi
    loads[best]=$((loads[best] + size))
  done < <(weighted_list "$directory" "$mode")
}

# Fail closed when SCRIPTS_COST_OUTLIERS names a file $1's discovery does not
# return. A stale entry is silent everywhere else: the suite it meant to hold
# apart is renamed or gone, anchoring quietly stops applying to it, every shard
# still exits 0 with a whole partition, and the co-location it exists to
# prevent is back with nothing saying so. That is the same silent-manifest
# failure this script's discovery design rejects, so it is an error here rather
# than a degraded arrangement.
#
# Checked at the configuration boundary rather than inside the assignment walk,
# and only against the default seam. The list describes one real directory; a
# caller that points SCRIPTS_TESTS_DIRECTORY at a fixture tree is not carrying a
# stale list, it is asking about a directory the list was never about, and the
# anchors are simply vacuous there. Reading a seam override as a stale list
# would fail every seam-based test in this script's own guard suite.
require_anchors_present() {
  local directory="$1" base found bats_path
  for base in ${SCRIPTS_COST_OUTLIERS[@]+"${SCRIPTS_COST_OUTLIERS[@]}"}; do
    found=0
    while IFS= read -r bats_path || [ -n "$bats_path" ]; do
      if [ "${bats_path##*/}" = "$base" ]; then
        found=1
        break
      fi
    done < <(discover_bats "$directory")
    if [ "$found" -eq 0 ]; then
      printf 'bats-shards: cost-outlier file not found: %s (in %s)\n' \
        "$base" "$directory" >&2
      exit 2
    fi
  done
}

files_for_shard() {
  case "$1" in
    hooks-1) files_hooks1 ;;
    hooks-*)
      greedy_bucket "$HOOKS_DIRECTORY" "$1" pinned "" \
        ${HOOKS_GREEDY_IDS[@]+"${HOOKS_GREEDY_IDS[@]}"}
      ;;
    scripts-*)
      if [ "$SCRIPTS_TESTS_DIRECTORY" = "$SCRIPTS_TESTS_DIRECTORY_DEFAULT" ]; then
        require_anchors_present "$SCRIPTS_TESTS_DIRECTORY"
      fi
      greedy_bucket "$SCRIPTS_TESTS_DIRECTORY" "$1" all \
        "${SCRIPTS_COST_OUTLIERS[*]+${SCRIPTS_COST_OUTLIERS[*]}}" \
        ${SCRIPTS_IDS[@]+"${SCRIPTS_IDS[@]}"}
      ;;
    audit) discover_bats "$AUDIT_TESTS_DIRECTORY" ;;
    lib) discover_bats "$LIBRARY_DIRECTORY" ;;
    misc)
      discover_bats "$FORENSICS_DIRECTORY"
      discover_bats "$STATUSLINE_DIRECTORY"
      ;;
  esac
}

# The ids sharing $1's exchange group, in matrix order, $1 included. Mirrors
# files_for_shard's case structure deliberately: the two answer the same
# question about the same boundaries, so a group added there without a case
# here is a discrepancy subcommand_group's empty-output guard fails on rather than
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

subcommand_shards() {
  local shard_id
  for shard_id in ${SHARD_IDS[@]+"${SHARD_IDS[@]}"}; do
    printf '%s\n' "$shard_id"
  done
}

subcommand_files() {
  local id="$1" shard_files exit_status
  if ! is_known_shard "$id"; then
    printf 'bats-shards: unknown shard id: %s\n' "$id" >&2
    printf 'bats-shards: known ids: %s\n' "${SHARD_IDS[*]+"${SHARD_IDS[*]}"}" >&2
    exit 2
  fi
  exit_status=0
  shard_files="$(files_for_shard "$id" | LC_ALL=C sort)" || exit_status=$?
  if [ "$exit_status" -ne 0 ]; then
    exit "$exit_status"
  fi
  if [ -z "$shard_files" ]; then
    printf 'bats-shards: shard %s resolved zero files\n' "$id" >&2
    exit 2
  fi
  printf '%s\n' "$shard_files"
}

subcommand_group() {
  local id="$1" group_ids
  if ! is_known_shard "$id"; then
    printf 'bats-shards: unknown shard id: %s\n' "$id" >&2
    printf 'bats-shards: known ids: %s\n' "${SHARD_IDS[*]+"${SHARD_IDS[*]}"}" >&2
    exit 2
  fi
  group_ids="$(group_for_shard "$id")"
  # Fail closed rather than print nothing. A known id reaching this empty means
  # group_for_shard has no case for it, and a caller rounding a set up to whole
  # groups would silently drop that shard instead of widening to it.
  if [ -z "$group_ids" ]; then
    printf 'bats-shards: shard %s belongs to no declared exchange group\n' "$id" >&2
    exit 2
  fi
  printf '%s\n' "$group_ids"
}

subcommand_run() {
  local id="$1" shard_files exit_status line argv
  exit_status=0
  shard_files="$(subcommand_files "$id")" || exit_status=$?
  if [ "$exit_status" -ne 0 ]; then
    exit "$exit_status"
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
$shard_files
EOF
  # Gate git's background auto-maintenance for every git process the suites
  # spawn. Left ungated, every `git commit` into a fixture repository spawns a
  # detached `git maintenance run --auto` that can outlive its test and race the
  # teardown deleting that repository, a false red on a clean tree. An
  # environment entry reaches every git subprocess regardless of cwd and
  # outranks repo-local config, so a suite added later is covered without
  # opting in. Why each key is in the list is the vitest side's:
  # .gaia/cli/src/util/git-maintenance-env.ts. The list itself, and the
  # append-after-ambient shape, are .gaia/scripts/bats5.sh's; bats-shards.bats
  # holds this block equal to that one, and that list equal to the vitest
  # side's. CI's shard legs reach bats only through this block, so this one
  # site covers them. A test that
  # needs git's own resolution sets GIT_CONFIG_COUNT=0 for that one call.
  (
    config_entry_count="${GIT_CONFIG_COUNT:-0}"
    for key_value_pair in gc.auto=0 maintenance.auto=false gc.autoDetach=false maintenance.autoDetach=false; do
      export "GIT_CONFIG_KEY_$config_entry_count=${key_value_pair%%=*}" "GIT_CONFIG_VALUE_$config_entry_count=${key_value_pair#*=}"
      config_entry_count=$((config_entry_count + 1))
    done
    export GIT_CONFIG_COUNT="$config_entry_count"
    bats ${argv[@]+"${argv[@]}"}
  )
}

main() {
  local subcommand="${1:-}"
  case "$subcommand" in
    -h | --help)
      usage
      exit 0
      ;;
    shards)
      subcommand_shards
      ;;
    files)
      [ $# -ge 2 ] || die_usage 'files needs a shard id'
      subcommand_files "$2"
      ;;
    group)
      [ $# -ge 2 ] || die_usage 'group needs a shard id'
      subcommand_group "$2"
      ;;
    run)
      [ $# -ge 2 ] || die_usage 'run needs a shard id'
      subcommand_run "$2"
      ;;
    '')
      die_usage 'missing command'
      ;;
    *)
      die_usage "unknown command: $subcommand"
      ;;
  esac
}

main "$@"
