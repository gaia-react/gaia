#!/usr/bin/env bats

# Adversarial suite for .gaia/tests/bats-shards.sh, the discovery-based file
# sharder .github/workflows/audit-ci-tests.yml's matrix legs call to decide
# which .bats files each shard runs. The invariant that matters is that
# `shards` + `files <id>` together form a partition of the discovered file
# set: every file in exactly one shard, no shard empty, no file lost. A
# regression here is silent everywhere else -- a dropped file simply never
# runs again, every shard still greens, and the declared-required check still
# reports success having covered less than it used to.
#
# S1/S2/S3 independently re-discover the six directories rather than asking
# the script to grade its own homework, and the adversarial fixtures (A1-A3)
# mutate a scratch copy of the script to prove those checks can actually fail.
# S9 and A4 cover the second invariant the partition has to
# hold: the weighted groups are split by weight, not by file count, and the
# partition checks are blind to that on their own. S16, with A6, A7 and A8,
# covers the third: no two suites the sharder declares cost outliers share a
# scripts shard, which the weight checks are equally blind to, since those
# suites are unremarkable by the weight being balanced.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], POSIX [ ] and grep only, so a broken assertion still fails on
# macOS bash 3.2.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bats-shards.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOKS_DIR_DEFAULT='.gaia/tests/hooks'
  SCRIPTS_TESTS_DIRECTORY_DEFAULT='.gaia/scripts/tests'
  AUDIT_TESTS_DIR_DEFAULT='.github/audit/tests'
  LIB_DIR_DEFAULT='.gaia/tests/lib'
  FORENSICS_DIRECTORY_DEFAULT='.gaia/tests/forensics'
  STATUSLINE_DIR_DEFAULT='.gaia/tests/statusline'
  # The change-scoped commands run the classifier against the diff arguments
  # first. A fixture diff names nothing the real classifier could read, so every
  # case gets a stub that prints $STUB_CLASSIFIER_OUTPUT and exits
  # $STUB_CLASSIFIER_STATUS, and says nothing by default.
  cat >"$BATS_TEST_TMPDIR/classifier.sh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_CLASSIFIER_OUTPUT:-}" ]; then
  printf '%s\n' "$STUB_CLASSIFIER_OUTPUT"
fi
exit "${STUB_CLASSIFIER_STATUS:-0}"
STUB
  export CHANGE_SCOPE_SCRIPT="$BATS_TEST_TMPDIR/classifier.sh"
}

teardown() {
  local scratch_copy_path
  if [ -f "$BATS_TEST_TMPDIR/scratch-copies" ]; then
    while IFS= read -r scratch_copy_path || [ -n "$scratch_copy_path" ]; do
      if [ -n "$scratch_copy_path" ]; then
        rm -f "$scratch_copy_path"
      fi
    done <"$BATS_TEST_TMPDIR/scratch-copies"
  fi
}

# Every *.bats directly inside repo-relative directory $1, LC_ALL=C sorted. A
# second, independent implementation of the script's own discover_bats: this
# must never call the script, or S1 would only prove the script agrees with
# itself.
discover_independent() {
  local directory="$1" suite_file
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this discovery carries the per-test mark
  for suite_file in "$REPO_ROOT/$directory"/*.bats; do
    if [ -e "$suite_file" ]; then
      printf '%s\n' "${suite_file#"$REPO_ROOT"/}"
    fi
  done | LC_ALL=C sort
}

# The independently discovered union of all six default directories.
all_discovered() {
  {
    discover_independent "$HOOKS_DIR_DEFAULT"
    discover_independent "$SCRIPTS_TESTS_DIRECTORY_DEFAULT"
    discover_independent "$AUDIT_TESTS_DIR_DEFAULT"
    discover_independent "$LIB_DIR_DEFAULT"
    discover_independent "$FORENSICS_DIRECTORY_DEFAULT"
    discover_independent "$STATUSLINE_DIR_DEFAULT"
  } | LC_ALL=C sort
}

# The union of `files <id>` over every id `shards` prints, for the script at
# $1. Takes the script path as an argument so the healthy run and a doctored
# copy exercise the same code, per the adversarial-fixture requirement below.
union_of_shard_files() {
  local script="$1" id
  while IFS= read -r id; do
    bash "$script" files "$id"
  done < <(bash "$script" shards)
}

# S1: the shard partition equals the independently discovered file set.
check_partition() {
  local script="$1"
  [ "$(all_discovered)" = "$(union_of_shard_files "$script" | LC_ALL=C sort)" ]
}

# S2: no path repeats across the shard partition.
check_no_duplicates() {
  local script="$1" duplicates
  duplicates="$(union_of_shard_files "$script" | LC_ALL=C sort | uniq -d)"
  [ -z "$duplicates" ]
}

# S3: every shard id resolves at least one file.
check_no_empty_shard() {
  local script="$1" id file_count
  while IFS= read -r id; do
    file_count="$(bash "$script" files "$id" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$file_count" -eq 0 ]; then
      return 1
    fi
  done < <(bash "$script" shards)
  return 0
}

# Copies the sharder into a fresh scratch path, so a mutation for one
# adversarial fixture never touches the real script other tests in this suite
# depend on. The copy is written beside this suite (inside the repo tree)
# rather than under $BATS_TEST_TMPDIR: the script derives its own REPO_ROOT
# from `git -C "$(dirname BASH_SOURCE)" rev-parse --show-toplevel`, which
# fails outright from a copy living under the OS temp directory, outside any
# git working tree.
#
# The path is recorded here, in a FILE, and that spelling is load-bearing:
# this function runs inside a command substitution, where an array append
# would be made in the subshell and lost on exit, while a filesystem write
# survives. Recording it here rather than at the call site is what lets
# teardown() clean up after a doctor_* that returns early on an unmatched
# anchor, which never reaches its caller at all. The file is per-test, so this
# stays correct if the suite is ever run under `bats --jobs`.
copy_sharder() {
  local destination
  destination="$(mktemp "$BATS_TEST_DIRNAME/.bats-shards-scratch.XXXXXX")"
  cp "$SCRIPT" "$destination"
  chmod +x "$destination"
  printf '%s\n' "$destination" >>"$BATS_TEST_TMPDIR/scratch-copies"
  printf '%s\n' "$destination"
}

# The line number of greedy_bucket's assignment walk in copy $1. Matched by
# shape, not by one exact spelling: a -F anchor pinned to today's variable
# names silently stops matching the moment one is renamed, and a no-match
# would splice nothing, leaving an undoctored copy that proves nothing. Every
# fixture below splices into the top of this loop body, so each one skews the
# assignment the same way for every shard the copy is asked about, which is
# what keeps the doctored partition self-consistent rather than merely broken.
greedy_walk_line() {
  local anchor
  anchor="$(grep -nE 'while IFS=.*read -r size bats_path' "$1" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || return 1
  printf '%s\n' "$anchor"
}

# A1 fixture: drops the heaviest file of each weighted group on the copy, so it
# is assigned to no shard while every shard the copy reports still exits 0 and
# stays non-empty. Proves check_partition can fail.
doctor_dropped_file() {
  local destination anchor
  destination="$(copy_sharder a1-dropped.sh)"
  anchor="$(greedy_walk_line "$destination")" || return 1
  awk -v anchor_line="$anchor" '
    { print }
    NR == anchor_line { print "    if [ -z \"${a1_seen:-}\" ]; then a1_seen=1; continue; fi" }
  ' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# A2 fixture: forces each group's heaviest file to also print under the group's
# SECOND shard on the copy. The unweighted walk already puts the first file it
# sees on the first shard, so the file lands in both. Proves
# check_no_duplicates can fail.
doctor_duplicated_file() {
  local destination anchor
  destination="$(copy_sharder a2-duplicated.sh)"
  anchor="$(greedy_walk_line "$destination")" || return 1
  awk -v anchor_line="$anchor" '
    { print }
    NR == anchor_line { print "    if [ \"$target_index\" -eq 1 ] && [ -z \"${a2_seen:-}\" ]; then a2_seen=1; printf \"%s\\n\" \"$bats_path\"; fi" }
  ' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# A3 fixture: removes subcommand_files' own fail-closed zero-files guard on the copy,
# so a shard resolving to nothing still exits 0 with empty output instead of
# exit 2. What this proves is that check_no_empty_shard itself would catch a
# regression in that guard, not merely that the guard exists.
doctor_bypassed_zero_guard() {
  local destination start end
  destination="$(copy_sharder a3-bypassed-guard.sh)"
  start="$(grep -nF 'if [ -z "$shard_files" ]; then' "$destination" | head -1 | cut -d: -f1)"
  [ -n "$start" ] || return 1
  end=$((start + 4))
  awk -v start_line="$start" -v end_line="$end" '
    NR == start_line { print "  [ -z \"$shard_files\" ] || printf \"%s\\n\" \"$shard_files\""; next }
    NR > start_line && NR <= end_line { next }
    { print }
  ' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# Writes a trivial single-@test .bats fixture whose test name and stdout are
# both the given marker, so S12 can identify exactly which fixture ran. Built
# from a variable rather than a literal `@test "..." {` line in this file's
# own source: bats' own preprocessor line-matches `@test` at column zero with
# no awareness of heredocs or quoting, so a literal line here would be
# rewritten by the OUTER bats run before this function ever executes,
# corrupting every fixture this suite writes.
write_trivial_bats() {
  local path="$1" marker="$2" at_test='@test'
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "%s" {\n' "$at_test" "$marker"
    printf "  printf '%s\\\\n'\n" "$marker"
    printf '}\n'
  } >"$path"
}

# bats test_tags=whole-tree
@test "S1: shards partition equals the independently discovered file set" {
  run check_partition "$SCRIPT"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "S2: no duplicate path across the shard partition" {
  run check_no_duplicates "$SCRIPT"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "S3: no shard resolves to zero files" {
  run check_no_empty_shard "$SCRIPT"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "S5: hooks-1 is exactly the pinned singleton" {
  run bash "$SCRIPT" files hooks-1
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/hooks/local-janitor.bats" ]
}

# bats test_tags=whole-tree
@test "S6: files output is deterministic across repeated calls" {
  local first second
  first="$(bash "$SCRIPT" files hooks-2)"
  second="$(bash "$SCRIPT" files hooks-2)"
  [ "$first" = "$second" ]
  first="$(bash "$SCRIPT" files scripts-1)"
  second="$(bash "$SCRIPT" files scripts-1)"
  [ "$first" = "$second" ]
}

@test "S7: fail-closed on zero files, exit 2 naming the shard" {
  local empty_hooks empty_forensics empty_statusline
  empty_hooks="$BATS_TEST_TMPDIR/s7-empty-hooks"
  mkdir -p "$empty_hooks"
  HOOKS_DIRECTORY="$empty_hooks" run bash "$SCRIPT" files hooks-2
  [ "$status" -eq 2 ]
  grep -qF -- 'hooks-2' <<<"$output"

  empty_forensics="$BATS_TEST_TMPDIR/s7-empty-forensics"
  empty_statusline="$BATS_TEST_TMPDIR/s7-empty-statusline"
  mkdir -p "$empty_forensics" "$empty_statusline"
  FORENSICS_DIRECTORY="$empty_forensics" STATUSLINE_DIRECTORY="$empty_statusline" run bash "$SCRIPT" files misc
  [ "$status" -eq 2 ]
  grep -qF -- 'misc' <<<"$output"
}

# bats test_tags=whole-tree
@test "S8: usage errors" {
  run bash "$SCRIPT" files nope
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" run nope
  [ "$status" -eq 2 ]

  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -qiF -- 'usage' <<<"$output"

  run bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
}

# Size of one path as `files` prints it: repo-relative for a path under the
# sharder's own root, absolute for one reached through a seam override.
bytes_of() {
  case "$1" in
    /*) wc -c <"$1" | tr -d ' ' ;;
    *) wc -c <"$REPO_ROOT/$1" | tr -d ' ' ;;
  esac
}

# The byte load of shard $2, under script $1.
shard_bytes() {
  local script="$1" id="$2" suite_path total=0
  while IFS= read -r suite_path || [ -n "$suite_path" ]; do
    [ -n "$suite_path" ] || continue
    total=$((total + $(bytes_of "$suite_path")))
  done < <(bash "$script" files "$id")
  printf '%s\n' "$total"
}

# `<total-bytes> <largest-file-bytes>` over the paths on stdin.
weight_profile() {
  local suite_path size total=0 largest=0
  while IFS= read -r suite_path || [ -n "$suite_path" ]; do
    [ -n "$suite_path" ] || continue
    size=$(bytes_of "$suite_path")
    total=$((total + size))
    if [ "$size" -gt "$largest" ]; then
      largest=$size
    fi
  done
  printf '%s %s\n' "$total" "$largest"
}

# 0 when every shard id from $4 on is within the greedy load bound implied by
# the profile `<total> <largest>` in $2/$3 over $n buckets, 1 when one is over.
within_load_bound() {
  local script="$1" total="$2" largest="$3"
  shift 3
  local ids id cap load
  ids=("$@")
  cap=$((total / $# + largest))
  for id in ${ids[@]+"${ids[@]}"}; do
    load="$(shard_bytes "$script" "$id")"
    if [ "$load" -gt "$cap" ]; then
      echo "$id carries $load bytes, over the greedy bound of $cap" >&2
      return 1
    fi
  done
  return 0
}

# S9. Each weighted group's shards are actually balanced by weight.
#
# The bound is the one greedy list scheduling always satisfies, not a tuned
# threshold: whichever file pushed a shard to its final load was placed while
# that shard was the LIGHTEST, so the load before it was at most the mean, and
# the load after it is at most the mean plus that one file. A shard exceeding
# `total/n + largest` therefore did not come out of a lightest-bucket walk at
# all. That is what fails if the assignment reverts to counting files, or
# collapses a group onto one shard, while every partition check above (which
# only cares WHICH shard a file lands in, never how heavy it is) stays green.
#
# Stated as a bound rather than a spread so it never flakes: it holds for every
# input, including one file heavier than the whole rest of its group.
# S14. `group <id>` answers a question `files <id>` cannot: which shard ids a
# file can move BETWEEN without anyone editing the sharder. A caller that must
# stay correct across reshuffles rounds its shard set up to whole groups, which
# is what .github/workflows/audit-ci-tests.yml's apt step does with the legs
# W10 derives; rounding up is only sound while the groups really do partition
# the shard set. Checked as a partition rather than against a transcript of
# today's groups, so a fifth hooks bucket or a second pinned file is covered by
# construction rather than by a fixture that would have to be re-typed.
# bats test_tags=whole-tree
@test "S14: group reports an exchange group, and the groups partition the shard set" {
  local ids id member group_ids member_group_ids union sorted_ids
  ids="$(bash "$SCRIPT" shards)"
  [ -n "$ids" ]

  union=''
  for id in $ids; do
    run bash "$SCRIPT" group "$id"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # A shard is always in its own group. Without this, a group that named
    # only a shard's siblings would satisfy every other assertion here.
    grep -qx -- "$id" <<<"$output" || {
      echo "group $id does not name $id itself:" >&2
      printf '%s\n' "$output" >&2
      return 1
    }
    union="$union$output
"
  done

  # The union over every shard's group is exactly the shard set: no group names
  # an id `shards` never prints, and no shard is left out of every group.
  sorted_ids="$(printf '%s\n' "$ids" | LC_ALL=C sort -u)"
  [ "$(printf '%s' "$union" | LC_ALL=C sort -u)" = "$sorted_ids" ] || {
    echo "the groups' union is not the shard set:" >&2
    printf '%s' "$union" | LC_ALL=C sort -u >&2
    return 1
  }

  # Groups are equal or disjoint, checked as "every member of a group reports
  # that same group". A partial overlap would make a rounded-up set correct for
  # one member of it and wrong for its neighbour, which is the one way rounding
  # up could still churn.
  for id in $ids; do
    group_ids="$(bash "$SCRIPT" group "$id")"
    for member in $group_ids; do
      member_group_ids="$(bash "$SCRIPT" group "$member")"
      [ "$member_group_ids" = "$group_ids" ] || {
        echo "$member is in $id's group but reports a different group of its own" >&2
        return 1
      }
    done
  done
}

@test "S15: group's usage and unknown-id errors match files'" {
  run bash "$SCRIPT" group nope
  [ "$status" -eq 2 ]
  grep -qF -- 'nope' <<<"$output"

  run bash "$SCRIPT" group
  [ "$status" -eq 2 ]
  grep -qiF -- 'usage' <<<"$output"
}

# A5 fixture: deletes group_for_shard's whole-directory arm on the copy, so a
# known shard resolves to an empty group. Proves subcommand_group's fail-closed guard
# is the thing standing between that and a caller silently narrowing its set,
# rather than the guard merely existing in the source.
doctor_groupless_shard() {
  local destination line
  destination="$(copy_sharder a5-groupless.sh)"
  line="$(grep -nF 'audit | lib | misc) printf' "$destination" | head -1 | cut -d: -f1)"
  [ -n "$line" ] || return 1
  awk -v removed_line="$line" 'NR != removed_line { print }' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# bats test_tags=whole-tree
@test "A5: a known shard with no group case fails closed rather than reporting an empty group" {
  local copy
  copy="$(doctor_groupless_shard)"

  # The healthy arm first, on the same doctored copy: a shard whose arm was
  # left alone still answers, so this cannot pass on a copy that simply broke.
  run bash "$copy" group hooks-2
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run bash "$copy" group lib
  [ "$status" -eq 2 ]
  [ -n "$output" ]
  grep -qF -- 'lib' <<<"$output"
}

# bats test_tags=whole-tree
@test "S9: each weighted group's shards respect the greedy load bound" {
  local total largest pinned
  # The held-out set is asked for rather than spelled out. Written as a literal
  # it would name today's single pinned file, and the sharder invites pinning a
  # second: that file would then stay in the profile while leaving the shards
  # under test, inflating `total` and `largest` and loosening the bound instead
  # of failing.
  pinned="$(bash "$SCRIPT" files hooks-1)"
  read -r total largest < <(discover_independent "$HOOKS_DIR_DEFAULT" | grep -vxF "$pinned" | weight_profile)
  run within_load_bound "$SCRIPT" "$total" "$largest" hooks-2 hooks-3 hooks-4
  [ "$status" -eq 0 ]

  read -r total largest < <(discover_independent "$SCRIPTS_TESTS_DIRECTORY_DEFAULT" | weight_profile)
  run within_load_bound "$SCRIPT" "$total" "$largest" scripts-1 scripts-2 scripts-3 scripts-4
  [ "$status" -eq 0 ]
}

# A4 fixture: makes every file weigh the same on the copy, which is the exact
# regression S9 exists to catch -- greedy over equal weights degenerates to
# round-robin over the sorted listing, i.e. back to counting files. The
# lightest-bucket walk is untouched, so every shard stays non-empty and the
# partition stays whole; only the balance goes.
doctor_unweighted() {
  local destination anchor
  destination="$(copy_sharder)"
  anchor="$(grep -nF 'size="${readable_sizes[$readable_position]:-0}"' "$destination" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || return 1
  awk -v anchor_line="$anchor" '
    NR == anchor_line { print "      size=1"; next }
    { print }
  ' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# A seam directory whose round-robin split across four shards is lopsided and
# whose weighted split is not: two heavy files four positions apart in the
# sorted listing land on the same shard when position decides, and on different
# shards when weight does. Six files, so no shard is empty under round-robin
# either way.
seed_lopsided_tree() {
  local directory="$1" name
  mkdir -p "$directory"
  for name in s-a s-e; do
    write_trivial_bats "$directory/$name.bats" "HEAVY-$name"
    # Padded to a size the light files cannot approach, as one trailing comment
    # line, so which shard holds the two heavy files is what decides the
    # comparison.
    head -c 1000 /dev/zero | tr '\0' '#' >>"$directory/$name.bats"
  done
  for name in s-b s-c s-d s-f; do
    write_trivial_bats "$directory/$name.bats" "LIGHT-$name"
  done
}

@test "A4: a group split by file count rather than weight reds the load bound" {
  local directory copy total largest
  directory="$BATS_TEST_TMPDIR/a4-scripts"
  seed_lopsided_tree "$directory"
  read -r total largest < <(printf '%s\n' "$directory"/*.bats | weight_profile)

  # The healthy arm first, so a bound loose enough to pass anything could not
  # pass this test.
  SCRIPTS_TESTS_DIRECTORY="$directory" run within_load_bound "$SCRIPT" "$total" "$largest" scripts-1 scripts-2 scripts-3 scripts-4
  [ "$status" -eq 0 ]

  copy="$(doctor_unweighted)"
  # The doctored copy still partitions the tree cleanly...
  SCRIPTS_TESTS_DIRECTORY="$directory" run check_no_duplicates "$copy"
  [ "$status" -eq 0 ]
  # ...and is still caught, because the two heavy files landed together.
  SCRIPTS_TESTS_DIRECTORY="$directory" run within_load_bound "$copy" "$total" "$largest" scripts-1 scripts-2 scripts-3 scripts-4
  [ "$status" -eq 1 ]
}

# The sizes come from one wc over the whole group, paired to the files by
# position. A directory named like a suite gets no wc line, so letting it into
# that wc would hand each later file its neighbour's size. Two heavy files, one
# named with a space, must each hold a shard alone, with the light files and
# the directory together on the third.
@test "A10: a directory among the suites does not shift the weights onto the wrong files" {
  local directory shard heavy_shard_count=0 listing
  directory="$BATS_TEST_TMPDIR/a10-scripts"
  mkdir -p "$directory/a-directory.bats"
  for name in "b heavy" "c heavy"; do
    write_trivial_bats "$directory/$name.bats" "HEAVY-$name"
    head -c 1000 /dev/zero | tr '\0' '#' >>"$directory/$name.bats"
  done
  for name in d-light e-light f-light g-light; do
    write_trivial_bats "$directory/$name.bats" "LIGHT-$name"
  done

  for shard in scripts-1 scripts-2 scripts-3 scripts-4; do
    # stdout alone: a wc complaint about the directory is not a listed file.
    listing="$(SCRIPTS_TESTS_DIRECTORY="$directory" bash "$SCRIPT" files "$shard" 2>/dev/null)" || return 1
    if grep -qF 'heavy.bats' <<<"$listing"; then
      heavy_shard_count=$((heavy_shard_count + 1))
      [ "$(grep -c . <<<"$listing")" -eq 1 ] || {
        printf '%s holds a heavy file and more:\n%s\n' "$shard" "$listing" >&2
        return 1
      }
    fi
  done
  [ "$heavy_shard_count" -eq 2 ]
}

# The anchored basenames the script declares, asked for rather than spelled
# out, on the same reasoning S9 gives for the pinned set: a literal here would
# name today's two files and would keep passing once a third is added, which is
# exactly the case S16 exists to cover.
#
# $2 names the list, SCRIPTS_COST_OUTLIERS when omitted; each weighted group
# declares its own.
cost_outliers() {
  local list_name="${2:-SCRIPTS_COST_OUTLIERS}"
  sed -n "s/^${list_name}=(\\(.*\\))\$/\\1/p" "$1" | tr ' ' '\n' | grep -v '^$'
}

# A copy of the script whose anchor list $3 (SCRIPTS_COST_OUTLIERS when
# omitted) is replaced by $2 (space-separated, possibly empty). Empty is the
# "anchoring disabled" arm every fixture below compares against: it is the one
# mutation that turns the mechanism off without touching the assignment walk
# the A1/A2 fixtures splice into.
doctor_outliers() {
  local name="$1" list="$2" list_name="${3:-SCRIPTS_COST_OUTLIERS}" destination anchor
  destination="$(copy_sharder "$name")"
  # Resolved and checked before splicing, for the reason greedy_walk_line
  # gives: an awk program that matches nothing rewrites nothing and hands back
  # an undoctored copy, which proves whatever the caller assumed rather than
  # what it meant to test.
  anchor="$(grep -nE "^${list_name}=\\(" "$destination" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || return 1
  awk -v anchor_line="$anchor" -v list="$list" -v list_name="$list_name" '
    NR == anchor_line { print list_name "=(" list ")"; next }
    { print }
  ' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  printf '%s\n' "$destination"
}

# Which scripts shard of script $1, under seam $3, holds basename $2. An empty
# $3 leaves the seam at its default, since the script resolves an empty
# SCRIPTS_TESTS_DIRECTORY through the same `:-` as an unset one.
#
# The group's ids are asked for, not spelled out, on the same reasoning S9
# gives for the pinned set and cost_outliers gives for the anchor list. The
# script builds SCRIPTS_IDS as the one place a scripts shard is added, so a
# literal list here would stop covering the group the moment a fourth is added:
# a caller looking for an outlier that landed on the new shard would be told
# there is none and abort on an empty variable, which reads as a confusing red
# rather than as a statement about the anchoring property. That reaches S16 and
# A6's anchoring-off arm, which ask which shard holds a file; A6's anchoring-on
# arm names its two expected ids outright and is unaffected.
#
# Read line by line rather than walked as an unquoted expansion, matching
# union_of_shard_files and check_no_empty_shard above: those enumerate the same
# kind of id list, and one idiom for one job is worth more than the token set
# happening to carry no glob metacharacter today.
scripts_shard_of() {
  local script="$1" base="$2" directory="$3" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if SCRIPTS_TESTS_DIRECTORY="$directory" bash "$script" files "$id" 2>/dev/null \
      | grep -qF -- "/$base"; then
      printf '%s\n' "$id"
      return 0
    fi
  done < <(bash "$script" group scripts-1)
  return 1
}

# A seam whose pure lightest-bucket walk provably co-locates two files, so the
# anchoring arm has something to separate. Three fillers take one bucket each
# (1000, 1000, 300), which leaves the third bucket light enough to win the next
# TWO picks: both trailing files land on it. The gap is what does the work, not
# the file count, so this stays a fixture about the walk rather than about how
# many files happen to be here.
seed_anchor_tree() {
  local directory="$1"
  mkdir -p "$directory"
  write_trivial_bats "$directory/fill-a.bats" "FILL-A"
  head -c 1000 /dev/zero | tr '\0' '#' >>"$directory/fill-a.bats"
  write_trivial_bats "$directory/fill-b.bats" "FILL-B"
  head -c 1000 /dev/zero | tr '\0' '#' >>"$directory/fill-b.bats"
  write_trivial_bats "$directory/fill-c.bats" "FILL-C"
  head -c 300 /dev/zero | tr '\0' '#' >>"$directory/fill-c.bats"
  write_trivial_bats "$directory/heavy-x.bats" "HEAVY-X"
  write_trivial_bats "$directory/heavy-y.bats" "HEAVY-Y"
}

# S16. The property the anchor list exists to deliver, asserted over the real
# tree rather than over a fixture: no two declared cost outliers share a leg.
# Byte weight cannot see what these suites cost, so which bucket each lands in
# is otherwise decided by the packing of every other file in the group, and a
# tree change anywhere in it can put two together and red the leg on the cap.
# bats test_tags=whole-tree
@test "S16: no two declared cost outliers share a scripts shard" {
  local base shard seen declaration declared_words
  seen=""
  while IFS= read -r base || [ -n "$base" ]; do
    [ -n "$base" ] || continue
    shard="$(scripts_shard_of "$SCRIPT" "$base" "")"
    [ -n "$shard" ]
    # Not already claimed by an earlier outlier.
    printf '%s\n' "$seen" | grep -qxF -- "$shard" && return 1
    seen="$(printf '%s\n%s' "$seen" "$shard")"
  done < <(cost_outliers "$SCRIPT")
  # The scripts list may legitimately be empty, so non-vacuity is asserted on
  # the parse rather than on the members: the declaration must exist, and the
  # parse must return exactly the words it holds. A renamed or reshaped
  # declaration would otherwise read as an empty list and pass the loop above
  # without asserting anything; the hooks twin below carries the non-empty arm.
  declaration="$(grep -E '^SCRIPTS_COST_OUTLIERS=\(.*\)$' "$SCRIPT")"
  [ "$(printf '%s\n' "$declaration" | grep -c .)" -eq 1 ]
  declared_words="$(printf '%s' "$declaration" | sed 's/^[^(]*(\(.*\))$/\1/' | wc -w | tr -d ' ')"
  [ "$(cost_outliers "$SCRIPT" | grep -c .)" -eq "$declared_words" ]
}

# A6. Proves S16's property comes from the anchoring and not from the byte
# packing happening to separate the two files anyway. Both arms run over the
# same seam, so the only difference between them is the list.
@test "A6: anchoring separates two files the unweighted walk co-locates" {
  local directory off on x_off y_off x_on y_on
  directory="$BATS_TEST_TMPDIR/a6-scripts"
  seed_anchor_tree "$directory"

  # Anchoring off: the walk puts both trailing files on the same shard.
  off="$(doctor_outliers a6-off.sh '')"
  x_off="$(scripts_shard_of "$off" heavy-x.bats "$directory")"
  y_off="$(scripts_shard_of "$off" heavy-y.bats "$directory")"
  [ -n "$x_off" ]
  [ "$x_off" = "$y_off" ]

  # Anchoring on: the same two files take the first two shards instead.
  on="$(doctor_outliers a6-on.sh 'heavy-x.bats heavy-y.bats')"
  x_on="$(scripts_shard_of "$on" heavy-x.bats "$directory")"
  y_on="$(scripts_shard_of "$on" heavy-y.bats "$directory")"
  [ "$x_on" = "scripts-1" ]
  [ "$y_on" = "scripts-2" ]

  # And the partition is still whole, so the separation is a reassignment
  # rather than a file quietly running twice or not at all.
  SCRIPTS_TESTS_DIRECTORY="$directory" run check_no_duplicates "$on"
  [ "$status" -eq 0 ]
}

# A7. The stale-list arm. An anchor naming a file discovery does not return is
# the silent failure the whole check exists for: anchoring stops applying, every
# shard still exits 0 with a whole partition, and nothing says the guarantee is
# gone.
# bats test_tags=whole-tree
@test "A7: an anchor naming a missing file is a fail-closed error" {
  local copy
  copy="$(doctor_outliers a7-stale.sh 'no-such-suite.bats')"
  run bash "$copy" files scripts-1
  [ "$status" -eq 2 ]
  grep -qF -- 'no-such-suite.bats' <<<"$output"

  # The healthy arm, so a check that passed everything could not pass this
  # test: the real list against the real seam still resolves.
  run bash "$SCRIPT" files scripts-1
  [ "$status" -eq 0 ]
}

# A7 second arm: the check is scoped to the default seam deliberately, so a
# caller pointing SCRIPTS_TESTS_DIRECTORY at a fixture tree is not read as carrying a
# stale list. Without this scoping every seam-based test in this file reds.
@test "A7: a seam override is not read as a stale anchor list" {
  local directory
  directory="$BATS_TEST_TMPDIR/a7-seam"
  seed_anchor_tree "$directory"
  SCRIPTS_TESTS_DIRECTORY="$directory" run bash "$SCRIPT" files scripts-1
  [ "$status" -eq 0 ]
}

# A8. More anchors than buckets cannot be honoured, and honouring it partly
# would silently put two of them together, which is the state the list exists
# to forbid.
@test "A8: more anchored files than shards is a fail-closed error" {
  local directory copy
  directory="$BATS_TEST_TMPDIR/a8-scripts"
  seed_anchor_tree "$directory"
  copy="$(doctor_outliers a8-over.sh \
    'fill-a.bats fill-b.bats fill-c.bats heavy-x.bats heavy-y.bats')"
  SCRIPTS_TESTS_DIRECTORY="$directory" run bash "$copy" files scripts-1
  [ "$status" -eq 2 ]
  # The phrase, not a word inside it: this script prints several exit-2
  # diagnostics, and pinning a substring short enough to appear in another one
  # would let a differently-caused exit 2 satisfy the test.
  grep -qF -- 'anchored files over' <<<"$output"
}

# Which weighted hooks shard of script $1 holds basename $2, the group's ids
# asked for on scripts_shard_of's reasoning.
hooks_shard_of() {
  local script="$1" base="$2" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if bash "$script" files "$id" 2>/dev/null | grep -qF -- "/$base"; then
      printf '%s\n' "$id"
      return 0
    fi
  done < <(bash "$script" group hooks-2)
  return 1
}

# S16 for the hooks group: its cost outliers are the suites whose runtime lives
# in what they run, so their byte weight says nothing about which leg can hold
# two of them.
# bats test_tags=whole-tree
@test "S16: no two declared cost outliers share a hooks shard" {
  local base shard seen
  seen=""
  while IFS= read -r base || [ -n "$base" ]; do
    [ -n "$base" ] || continue
    shard="$(hooks_shard_of "$SCRIPT" "$base")"
    [ -n "$shard" ]
    printf '%s\n' "$seen" | grep -qxF -- "$shard" && return 1
    seen="$(printf '%s\n%s' "$seen" "$shard")"
  done < <(cost_outliers "$SCRIPT" HOOKS_COST_OUTLIERS)
  [ -n "$(cost_outliers "$SCRIPT" HOOKS_COST_OUTLIERS)" ]
}

# A7 for the hooks group: a stale name fails closed on the default seam, and a
# seam override is not read as a stale list.
# bats test_tags=whole-tree
@test "A7: a hooks anchor naming a missing file is a fail-closed error" {
  local copy directory
  copy="$(doctor_outliers a7-hooks-stale.sh 'no-such-hook-suite.bats' HOOKS_COST_OUTLIERS)"
  run bash "$copy" files hooks-2
  [ "$status" -eq 2 ]
  grep -qF -- 'no-such-hook-suite.bats' <<<"$output"

  directory="$BATS_TEST_TMPDIR/a7-hooks-seam"
  seed_anchor_tree "$directory"
  write_trivial_bats "$directory/local-janitor.bats" "PINNED"
  HOOKS_DIRECTORY="$directory" run bash "$copy" files hooks-2
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" files hooks-2
  [ "$status" -eq 0 ]
}

@test "S11: a pinned hook missing from discovery is a fail-closed error" {
  local directory
  directory="$BATS_TEST_TMPDIR/s11-hooks"
  mkdir -p "$directory"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' >"$directory/not-the-pinned-file.bats"
  HOOKS_DIRECTORY="$directory" run bash "$SCRIPT" files hooks-1
  [ "$status" -eq 2 ]
  grep -qF -- 'local-janitor.bats' <<<"$output"
}

@test "S12: run honors the seam and executes exactly what files lists" {
  local forensics_directory statusline_directory files_output
  forensics_directory="$BATS_TEST_TMPDIR/s12-forensics"
  statusline_directory="$BATS_TEST_TMPDIR/s12-statusline"
  mkdir -p "$forensics_directory" "$statusline_directory"
  write_trivial_bats "$forensics_directory/marker-a.bats" "MARK-A"
  write_trivial_bats "$statusline_directory/marker-b.bats" "MARK-B"

  FORENSICS_DIRECTORY="$forensics_directory" STATUSLINE_DIRECTORY="$statusline_directory" run bash "$SCRIPT" files misc
  [ "$status" -eq 0 ]
  files_output="$output"

  FORENSICS_DIRECTORY="$forensics_directory" STATUSLINE_DIRECTORY="$statusline_directory" run bash "$SCRIPT" run misc
  [ "$status" -eq 0 ]
  grep -qF -- 'MARK-A' <<<"$output"
  grep -qF -- 'MARK-B' <<<"$output"

  # Exactly two `ok` results proves nothing beyond the two fixtures ran --
  # in particular that run-all.sh's own BASH_SOURCE-relative glob never fired.
  local ok_count files_count
  ok_count=$(grep -c '^ok ' <<<"$output")
  [ "$ok_count" -eq 2 ]
  files_count=$(printf '%s\n' "$files_output" | wc -l | tr -d ' ')
  [ "$files_count" -eq 2 ]
}

# Writes a fixture suite proving, from inside a bats run, whether that run
# gates git's background maintenance. GIT_TRACE2_EVENT records a child's argv as
# a `child_start` event in the spawning process's trace, so a --detach run is
# visible without waiting on it; both argv spellings count, since pre-2.29 git
# spawns `gc` where modern git spawns `maintenance`. The subject arm needs 2.29
# or later: earlier git spawns `gc --auto` on every commit and gc.auto=0 only
# empties its work, so a correctly gated run would still count one there.
#
# Each repository writes git's own defaults for the gates, so a personal
# ~/.gitconfig carrying gc.auto=0 cannot gate it and the environment is the only
# thing that can. A bare "no spawn" also holds when the trace saw nothing, so
# the control arm clears the environment's gates for its one commit and must
# see a spawn. The autoDetach pair is not a gate: it keeps any spawned run in
# the foreground, so it cannot outlive the commit into bats' removal of
# $BATS_TEST_TMPDIR. Limit: measured on git 2.55, against a repository carrying
# an explicit maintenance.auto=true only the environment's maintenance.auto
# entry suppresses the spawn, so the subject arm reds when that key leaves run's
# gates and stays green when gc.auto does; gc.auto matters only on git predating
# the maintenance task set, which CI does not run. So S17 pins maintenance.auto
# alone, and S18 holds the rest: it keeps run's gating block equal to
# bats5.sh's, whose own suite pins every pair.
#
# AT_TEST stands in for bats' test keyword and is swapped in on the way out,
# for the reason write_trivial_bats gives.
write_maintenance_fixture() {
  sed 's/^AT_TEST /@test /' >"$1" <<'FIXTURE'
#!/usr/bin/env bats

_spawns() {
  grep -F '"child_start"' "$1" 2>/dev/null | grep -cE '"(maintenance|gc)"' || true
}

_repo_at_git_defaults() {
  mkdir "$1"
  git -C "$1" init --quiet --initial-branch=main
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
  git -C "$1" config commit.gpgsign false
  git -C "$1" config gc.auto 6700
  git -C "$1" config maintenance.auto true
  git -C "$1" config gc.autoDetach false
  git -C "$1" config maintenance.autoDetach false
}

AT_TEST "control" {
  _repo_at_git_defaults "$BATS_TEST_TMPDIR/repo"
  GIT_CONFIG_COUNT=0 GIT_TRACE2_EVENT="$BATS_TEST_TMPDIR/trace" \
    git -C "$BATS_TEST_TMPDIR/repo" commit --quiet --allow-empty -m control
  [ "$(_spawns "$BATS_TEST_TMPDIR/trace")" -gt 0 ]
}

AT_TEST "subject" {
  _repo_at_git_defaults "$BATS_TEST_TMPDIR/repo"
  GIT_TRACE2_EVENT="$BATS_TEST_TMPDIR/trace" \
    git -C "$BATS_TEST_TMPDIR/repo" commit --quiet --allow-empty -m subject
  [ "$(_spawns "$BATS_TEST_TMPDIR/trace")" -eq 0 ]
}
FIXTURE
}

# The gating block in file $1, indentation stripped: every line from the
# ambient-count read through the count export, so the key list and the
# append-after-ambient shape are compared together. Prints nothing unless the
# block opens exactly once, so a second copy, or a block rewritten to overwrite
# the ambient entries, reads as no block rather than as whichever matched.
gate_block() {
  [ "$(grep -c '^ *config_entry_count="${GIT_CONFIG_COUNT:-0}"$' "$1")" -eq 1 ] || return 0
  sed -n '/^ *config_entry_count="${GIT_CONFIG_COUNT:-0}"$/,/^ *export GIT_CONFIG_COUNT="$config_entry_count"$/p' "$1" |
    sed 's/^ *//'
}

# A9 fixture: empties run's gate list on the copy, so the count it exports is
# the ambient one and the suites it runs get git's own maintenance resolution.
# What this proves is that S17's subject arm can red, not merely that the gates
# are spelled out in the script.
doctor_ungated_run() {
  local destination
  destination="$(copy_sharder a9-ungated-run.sh)"
  [ -n "$(gate_block "$destination")" ] || return 1
  sed 's/^\( *for key_value_pair in\) .*\(; do\)$/\1\2/' "$destination" >"$destination.new"
  mv "$destination.new" "$destination"
  grep -qxF '    for key_value_pair in; do' "$destination" || return 1
  printf '%s\n' "$destination"
}

# The outer GIT_CONFIG_COUNT=0 is what makes a pass mean anything: this suite
# normally runs under bats-shards.sh itself, and an inherited gate would green
# the subject arm with run's own export deleted.
@test "S17: run gates git's background maintenance for every suite it runs" {
  local fixture_directory ok_count
  fixture_directory="$BATS_TEST_TMPDIR/s17-lib"
  mkdir -p "$fixture_directory"
  write_maintenance_fixture "$fixture_directory/maintenance.bats"

  GIT_CONFIG_COUNT=0 LIBRARY_DIRECTORY="$fixture_directory" run bash "$SCRIPT" run lib
  [ "$status" -eq 0 ]
  grep -qE '^ok [0-9]+ control$' <<<"$output"
  grep -qE '^ok [0-9]+ subject$' <<<"$output"
  ok_count=$(grep -c '^ok ' <<<"$output")
  [ "$ok_count" -eq 2 ]
}

@test "A9: a run that leaves maintenance ungated reds S17's subject arm" {
  local copy fixture_directory
  copy="$(doctor_ungated_run)"
  fixture_directory="$BATS_TEST_TMPDIR/a9-lib"
  mkdir -p "$fixture_directory"
  write_maintenance_fixture "$fixture_directory/maintenance.bats"

  GIT_CONFIG_COUNT=0 LIBRARY_DIRECTORY="$fixture_directory" run bash "$copy" run lib
  [ "$status" -eq 1 ]
  grep -qE '^ok [0-9]+ control$' <<<"$output"
  grep -qE '^not ok [0-9]+ subject$' <<<"$output"
}

# S13's allowlist: a tracked .bats file that no shard resolves, paired with
# the runner that does execute it. Four tab-separated fields per row: the path
# prefix, the file to look in, the LITERAL text that invokes the runner, and a
# human label for the failure message.
#
# A row's prefix must not reach further than its runner does, and the trailing
# slash is what says how far: allowlist_row_covers below matches a row ending
# in `/` by prefix and every other row by exact path. Two rows name a directory
# because their runner takes the whole of one: sandbox/run-all.sh globs
# `"$HERE"/*.bats`, and the forensics delegation runs a directory. The
# concurrency row names a full file path instead, because meter-gate.sh pins
# `SUITE="$HERE/concurrency.bats"` rather than globbing; matched as a prefix
# it would excuse a second suite added beside that one while nothing ran it,
# reproducing the silent green this test exists to catch, inside the waiver.
#
# The needle is carried per row rather than derived from the prefix, and that
# is the difference between a check and a decoration. A derived needle is
# whatever the prefix happens to spell -- `sandbox`, `concurrency` -- and those
# words appear throughout the workflow's prose, `concurrency:` being a
# top-level GitHub Actions key that is present no matter what. Such a grep
# cannot fail: delete both matrix legs AND their run: steps and it still
# matches, so the row would go on excusing every suite behind that prefix,
# which is the exact regression this test exists to catch. The invocation
# line is the thing that disappears when the runner does, so it is what gets
# matched.
non_shard_runners() {
  printf '%s\t%s\t%s\t%s\n' \
    '.gaia/tests/sandbox/' '.github/workflows/audit-ci-tests.yml' \
    'bash .gaia/tests/sandbox/run-all.sh' 'the sandbox leg of the audit-ci-tests.yml matrix' \
    '.gaia/tests/concurrency/concurrency.bats' '.github/workflows/audit-ci-tests.yml' \
    'bash .gaia/tests/concurrency/meter-gate.sh' 'the concurrency leg of the audit-ci-tests.yml matrix' \
    '.gaia/tests/commitlint/' '.github/workflows/audit-ci-tests.yml' \
    'bash .gaia/scripts/bats5.sh .gaia/tests/commitlint/' 'the commitlint leg of the audit-ci-tests.yml matrix' \
    '.github/forensics/tests/' '.gaia/tests/forensics/unit.bats' \
    'run bats "$FORENSICS_DIR/tests/"' 'the delegation @test in .gaia/tests/forensics/unit.bats, which the misc shard runs'
}

# Whether allowlist prefix $2 covers orphan $1. A prefix ending in `/` names a
# directory its runner takes whole, so it covers every suite beneath it; any
# other prefix names one file and covers that path alone. Matching a file row
# by prefix would also excuse a tracked `<that path>.disabled.bats` sitting
# beside it, which nothing runs.
allowlist_row_covers() {
  local orphan="$1" prefix="$2"
  case "$prefix" in
    */)
      case "$orphan" in
        "$prefix"*) return 0 ;;
      esac
      ;;
    *)
      if [ "$orphan" = "$prefix" ]; then
        return 0
      fi
      ;;
  esac
  return 1
}

# The allowlist row covering orphan $1 on stdout; non-zero when no row does.
covering_row() {
  local orphan="$1" row prefix rest
  while IFS= read -r row || [ -n "$row" ]; do
    IFS=$'\t' read -r prefix rest <<<"$row"
    if allowlist_row_covers "$orphan" "$prefix"; then
      printf '%s\n' "$row"
      return 0
    fi
  done < <(non_shard_runners)
  return 1
}

# S13. Every tracked .bats file is executed by something.
#
# The sharder's own partition checks (S1-S3) prove the shards agree with a
# re-discovery of the SIX SEAM DIRECTORIES. That is a closed loop: a .bats
# file in a seventh directory is outside both sides of the comparison, so
# every one of those assertions passes while nothing runs the file. The check
# greens, the suite never executes, and a regression in it merges.
#
# The blind spot is every directory outside the seam. Most of `.gaia/tests/`
# is outside it, and so is anywhere else in the repo a suite might land, so a
# suite dropped into one of them is unreached while every assertion above
# stays green.
#
# So this compares the shard union against `git ls-files`, the repo's own
# answer to "what .bats files exist", rather than against a re-listing of the
# same six directories. Anything in the first set and not the second is an
# orphan unless the allowlist above names its runner.
#
# Scope, honestly: this proves a file is REACHED, not that its assertions are
# armed on the right pull requests. A suite in a shard whose guarded source is
# missing from the workflow's `code:` filter still skips on the change that
# breaks it; workflow-filter-coverage.bats (.gaia/scripts/tests/) is the guard
# for that half.
# bats test_tags=whole-tree
@test "S13: every tracked .bats file is run by a shard or a named non-shard runner" {
  local tracked covered orphans orphan prefix file needle label row exit_status
  tracked="$(cd "$REPO_ROOT" && git -c core.quotepath=false ls-files -z '*.bats' | tr '\0' '\n' | LC_ALL=C sort)"
  [ -n "$tracked" ] || {
    # gaia-lint-ignore lint-git-path-quoting: incidental command text in a
    # diagnostic message string, not an invocation; there is no call here to
    # give -z to
    echo "git ls-files found no .bats files at all; the comparison would be vacuous" >&2
    return 1
  }
  covered="$(union_of_shard_files "$SCRIPT" | LC_ALL=C sort -u)"

  # Capture rather than iterate a process substitution, so comm's own status
  # is checked instead of discarded: it exits non-zero on input its collation
  # rejects, and a fail-open there would report zero orphans for the wrong
  # reason. LC_ALL=C matches the sort the two operands were built with; under
  # a differing ambient locale GNU comm reports disorder on inputs that are
  # correctly sorted for C.
  orphans="$(LC_ALL=C comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$covered"))" || {
    echo "comm failed comparing the tracked suites against the shard union" >&2
    return 1
  }

  exit_status=0
  while IFS= read -r orphan || [ -n "$orphan" ]; do
    [ -n "$orphan" ] || continue
    if row="$(covering_row "$orphan")"; then
      IFS=$'\t' read -r prefix file needle label <<<"$row"
      # Prove the named runner still exists rather than trusting the row:
      # a stale entry would keep excusing a file whose runner was deleted,
      # which is the same silent green one level up.
      grep -qF -- "$needle" "$REPO_ROOT/$file" || {
        echo "allowlist excuses $orphan via $label, but $file no longer contains: $needle" >&2
        exit_status=1
      }
    else
      echo "orphan bats suite, no shard resolves it and no allowlist row names a runner: $orphan" >&2
      exit_status=1
    fi
  done <<EOF
$orphans
EOF

  [ "$exit_status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "S13 adversarial: an orphan suite outside the seam is caught" {
  # The real failure shape: a .bats file tracked by git, in no seam directory
  # and on no allowlist prefix. Written into a directory the seam does not
  # reach, then staged so `git ls-files` reports it.
  #
  # Staged into a COPY of the index, never the repository's own. Writing the
  # real index would make this the one test here that mutates shared repo
  # state, and a documented invariant forbids it: a sibling suite derives its
  # whole input population from `git ls-files`. It would also
  # need an undo, whose own failure path (a contended index.lock) strands a
  # staged-deleted path in the real index, which is exactly the dirty-tree
  # state that makes every audit member withhold its marker. GIT_INDEX_FILE
  # removes the hazard rather than reporting it: nothing to undo, so nothing
  # that can fail to undo.
  local directory relative_path git_directory index
  directory="$REPO_ROOT/.gaia/tests/lib/fixtures"
  relative_path=".gaia/tests/lib/fixtures/s13-orphan-probe.bats"
  index="$BATS_TEST_TMPDIR/probe-index"
  git_directory="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
  cp "$git_directory/index" "$index"
  mkdir -p "$directory"
  printf '%s\n' "$REPO_ROOT/$relative_path" >>"$BATS_TEST_TMPDIR/scratch-copies"
  write_trivial_bats "$REPO_ROOT/$relative_path" "S13-ORPHAN"
  GIT_INDEX_FILE="$index" git -C "$REPO_ROOT" add -N -- "$relative_path"

  local tracked covered orphans
  tracked="$(cd "$REPO_ROOT" && GIT_INDEX_FILE="$index" git -c core.quotepath=false ls-files -z '*.bats' | tr '\0' '\n' | LC_ALL=C sort)"
  covered="$(union_of_shard_files "$SCRIPT" | LC_ALL=C sort -u)"
  orphans="$(LC_ALL=C comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$covered"))"

  # `fixtures/` is a subdirectory of a seam root, and the seam globs *.bats
  # DIRECTLY inside its roots only, so this probe is genuinely unreached --
  # which is exactly the blind spot S13 exists to name.
  grep -qF -- "$relative_path" <<<"$orphans" || {
    echo "an orphan .bats outside every seam root did not surface as uncovered" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "S13 adversarial: a file-path allowlist row does not excuse a suite beside it" {
  # The waiver's own blind spot. `.gaia/tests/concurrency/concurrency.bats` is
  # allowlisted because meter-gate.sh pins that one file; matched as a prefix,
  # the row also excuses a tracked sibling whose name merely extends it, and
  # nothing runs the sibling.
  #
  # Staged into a COPY of the index for the reason the probe above gives: a
  # staged entry stranded in the real index is the dirty-tree state that makes
  # every Code Audit Team member withhold its marker.
  local directory relative_path git_directory index
  directory="$REPO_ROOT/.gaia/tests/concurrency"
  relative_path=".gaia/tests/concurrency/concurrency.bats.disabled.bats"
  index="$BATS_TEST_TMPDIR/beside-index"
  git_directory="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
  cp "$git_directory/index" "$index"
  mkdir -p "$directory"
  printf '%s\n' "$REPO_ROOT/$relative_path" >>"$BATS_TEST_TMPDIR/scratch-copies"
  write_trivial_bats "$REPO_ROOT/$relative_path" "S13-BESIDE"
  GIT_INDEX_FILE="$index" git -C "$REPO_ROOT" add -N -- "$relative_path"

  local tracked covered orphans
  tracked="$(cd "$REPO_ROOT" && GIT_INDEX_FILE="$index" git -c core.quotepath=false ls-files -z '*.bats' | tr '\0' '\n' | LC_ALL=C sort)"
  covered="$(union_of_shard_files "$SCRIPT" | LC_ALL=C sort -u)"
  orphans="$(LC_ALL=C comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$covered"))"

  # No shard resolves it, so it reaches the allowlist as an orphan...
  grep -qF -- "$relative_path" <<<"$orphans" || {
    echo "the sibling suite did not reach the allowlist as an orphan" >&2
    return 1
  }
  # ...and no row covers it, so S13 names it.
  covering_row "$relative_path" && return 1

  # The green half: the pinned file is still excused by its own row, and each
  # directory row still covers an arbitrary suite beneath it.
  covering_row '.gaia/tests/concurrency/concurrency.bats' >/dev/null || return 1
  covering_row '.gaia/tests/sandbox/any-suite.bats' >/dev/null || return 1
  covering_row '.github/forensics/tests/any-suite.bats' >/dev/null || return 1
}

# bats test_tags=whole-tree
@test "A1: dropped file reds the partition check" {
  local copy
  copy="$(doctor_dropped_file)"
  run check_partition "$copy"
  [ "$status" -eq 1 ]
}

# bats test_tags=whole-tree
@test "A2: duplicated file reds the no-duplicates check" {
  local copy
  copy="$(doctor_duplicated_file)"
  run check_no_duplicates "$copy"
  [ "$status" -eq 1 ]
}

@test "A3: an empty shard behind a bypassed guard reds the no-empty-shard check" {
  local copy directory
  copy="$(doctor_bypassed_zero_guard)"
  directory="$BATS_TEST_TMPDIR/a3-empty-scripts"
  mkdir -p "$directory"

  # First, prove the guard itself is actually bypassed on the copy: exit 0
  # with empty output, where the real script would exit 2.
  SCRIPTS_TESTS_DIRECTORY="$directory" run bash "$copy" files scripts-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  SCRIPTS_TESTS_DIRECTORY="$directory" run check_no_empty_shard "$copy"
  [ "$status" -eq 1 ]
}

# The change-scoped subcommands. A leg running for a narrow change hands bats
# the shard's suites the change selector picks, in full, and the shard's other
# whole-tree-marked suites under the whole-tree tag. The fixture shard holds
# one suite of each kind plus one the change owes nothing, and a stub stands in
# for the selector so the selection is the fixture's, not the live diff's. The
# tag line is assembled at run time, for the reason the authoring rule gives:
# a column-0 tag line in this file would mark this suite's own next test.
write_change_fixture() {
  local directory="$1" at_test='@test'
  mkdir -p "$directory/lib"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "picked one" {\n  true\n}\n' "$at_test"
    printf '%s "picked two" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/picked.bats"
  {
    printf '#!/usr/bin/env bats\n'
    printf '# bats %s\n' 'test_tags=whole-tree'
    printf '%s "marked whole-tree" {\n  true\n}\n' "$at_test"
    printf '%s "marked plain" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/marked.bats"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "unrelated" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/unrelated.bats"
  # The stub records its argv one per line and picks one suite, or exits 3,
  # the selector's "the change could not be read", when told to.
  cat >"$directory/selector.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_DIRECTORY/selector-argv"
[ -n "${STUB_SELECTOR_FAILS:-}" ] && exit 3
printf '%s\n' "$STUB_DIRECTORY/lib/picked.bats"
STUB
}

# run_for_change_fixture <sharder> <fixture-directory> <subcommand>: the
# change-scoped subcommand against the fixture shard and its stub selector.
run_for_change_fixture() {
  STUB_DIRECTORY="$2" LIBRARY_DIRECTORY="$2/lib" SUITES_FOR_CHANGE_SCRIPT="$2/selector.sh" \
    bash "$1" "$3" lib base-ref head-ref
}

@test "S19: files-for-change lists the picked and the whole-tree-marked suites of the shard, and no other" {
  local directory="$BATS_TEST_TMPDIR/s19"
  write_change_fixture "$directory"

  run run_for_change_fixture "$SCRIPT" "$directory" files-for-change
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$(printf '%s\n%s' "$directory/lib/marked.bats" "$directory/lib/picked.bats")" ]
  # The diff arguments reach the selector verbatim, after the repository root.
  [ "$(sed -n '1p' "$directory/selector-argv")" = "--dir" ]
  [ "$(sed -n '3,4p' "$directory/selector-argv" | tr '\n' ' ')" = "base-ref head-ref " ]
}

@test "S20: run-for-change runs a picked suite in full and only the whole-tree tests of a marked one" {
  local directory="$BATS_TEST_TMPDIR/s20"
  write_change_fixture "$directory"

  run run_for_change_fixture "$SCRIPT" "$directory" run-for-change
  [ "$status" -eq 0 ]
  grep -qE '^ok [0-9]+ picked one$' <<<"$output"
  grep -qE '^ok [0-9]+ picked two$' <<<"$output"
  grep -qE '^ok [0-9]+ marked whole-tree$' <<<"$output"
  grep -qE 'marked plain$' <<<"$output" && return 1
  grep -qE 'unrelated$' <<<"$output" && return 1
  true
}

@test "S21: a selector that cannot read the change runs the whole shard, never nothing" {
  local directory="$BATS_TEST_TMPDIR/s21"
  write_change_fixture "$directory"

  STUB_SELECTOR_FAILS=1 run run_for_change_fixture "$SCRIPT" "$directory" run-for-change
  [ "$status" -eq 0 ]
  grep -qE '^ok [0-9]+ unrelated$' <<<"$output"
  grep -qE '^ok [0-9]+ marked plain$' <<<"$output"
  grep -qE '^ok [0-9]+ picked one$' <<<"$output"

  STUB_SELECTOR_FAILS=1 run run_for_change_fixture "$SCRIPT" "$directory" files-for-change
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '\.bats$')" -eq 3 ]
}

@test "S22: the change-scoped subcommands refuse a call that names no change or no known shard" {
  run bash "$SCRIPT" run-for-change lib
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" files-for-change lib
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" run-for-change no-such-shard base-ref head-ref
  [ "$status" -eq 2 ]
}

@test "A11: a plan blind to the whole-tree mark reds S20's marked arm" {
  local copy directory="$BATS_TEST_TMPDIR/a11"
  copy="$(copy_sharder)"
  grep -qF '"$verify_whole_tree_mark_pattern"' "$copy" || return 1
  sed 's/"\$verify_whole_tree_mark_pattern"/"^never-matches$"/' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  write_change_fixture "$directory"

  run run_for_change_fixture "$copy" "$directory" run-for-change
  grep -qE '^ok [0-9]+ marked whole-tree$' <<<"$output" && return 1
  true
}

@test "A12: a fallback that runs nothing reds S21" {
  local copy directory="$BATS_TEST_TMPDIR/a12"
  copy="$(copy_sharder)"
  grep -qF 'subcommand_run "$id"' "$copy" || return 1
  sed 's/^\( *\)subcommand_run "\$id" # whole-shard fallback$/\1exit 0/' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  grep -qF '# whole-shard fallback' "$copy" && return 1
  write_change_fixture "$directory"

  STUB_SELECTOR_FAILS=1 run run_for_change_fixture "$copy" "$directory" run-for-change
  grep -qE '^ok [0-9]+ unrelated$' <<<"$output" && return 1
  true
}

# The shard plan. The fixture shard holds a suite carrying the
# installed-dependencies mark, one carrying the whole-tree mark, a plain one,
# and a Chromium suite by name; a stub selector picks only what
# $STUB_SELECTOR_PICKS names. Tag lines are assembled at run time, as above.
write_plan_fixture() {
  local directory="$1" at_test='@test'
  mkdir -p "$directory/lib"
  {
    printf '#!/usr/bin/env bats\n'
    printf '# bats %s\n' 'file_tags=installed-dependencies'
    printf '%s "dependency one" {\n  true\n}\n' "$at_test"
    printf '%s "dependency two" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/dependent.bats"
  {
    printf '#!/usr/bin/env bats\n'
    printf '# bats %s\n' 'test_tags=whole-tree'
    printf '%s "marked whole-tree" {\n  true\n}\n' "$at_test"
    printf '%s "marked plain" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/marked.bats"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "unrelated" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/unrelated.bats"
  {
    printf '#!/usr/bin/env bats\n'
    printf '%s "lifecycle" {\n  true\n}\n' "$at_test"
  } >"$directory/lib/uat-lifecycle-e2e.bats"
  cat >"$directory/selector.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SELECTOR_FAILS:-}" ] || exit 3
if [ -n "${STUB_SELECTOR_PICKS:-}" ]; then
  printf '%s\n' "$STUB_SELECTOR_PICKS"
fi
exit 0
STUB
}

# plan_fixture <sharder> <fixture-directory> <subcommand> <args>...: the
# subcommand over the fixture shard, stderr left in $BATS_TEST_TMPDIR/stderr.
plan_fixture() {
  local sharder="$1" directory="$2"
  shift 2
  LIBRARY_DIRECTORY="$directory/lib" SUITES_FOR_CHANGE_SCRIPT="$directory/selector.sh" \
    bash "$sharder" "$@" 2>"$BATS_TEST_TMPDIR/stderr"
}

@test "P1: a harness change runs the whole shard and says why on one stderr line" {
  local directory="$BATS_TEST_TMPDIR/p1"
  write_plan_fixture "$directory"
  STUB_CLASSIFIER_OUTPUT=$(printf 'harness\t.claude/hooks/lib/x.sh')
  export STUB_CLASSIFIER_OUTPUT

  run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '\.bats$')" -eq 4 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stderr")" = "bats-shards: harness-change; running all of lib" ]

  run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$(sed -n '1,2p' <<<"$output" | tr '\n' ' ')" = "mode=full reason=harness-change " ]
}

@test "P2: an unreadable change runs the whole shard even when a dependency path was printed" {
  local directory="$BATS_TEST_TMPDIR/p2"
  write_plan_fixture "$directory"

  STUB_CLASSIFIER_STATUS=3 run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '\.bats$')" -eq 4 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stderr")" = "bats-shards: change-unreadable; running all of lib" ]
  STUB_CLASSIFIER_STATUS=3 run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  grep -qx 'reason=change-unreadable' <<<"$output"

  STUB_CLASSIFIER_OUTPUT=$(printf 'dependency\tpnpm-lock.yaml')
  export STUB_CLASSIFIER_OUTPUT
  STUB_SELECTOR_FAILS=1 run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '\.bats$')" -eq 4 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stderr")" = "bats-shards: change-unreadable; running all of lib" ]
  STUB_SELECTOR_FAILS=1 run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  grep -qx 'mode=full' <<<"$output"
  grep -qx 'reason=change-unreadable' <<<"$output"
}

@test "P3: a dependency change runs the installed-dependencies suites in full beside the whole-tree ones" {
  local directory="$BATS_TEST_TMPDIR/p3"
  write_plan_fixture "$directory"
  STUB_CLASSIFIER_OUTPUT=$(printf 'dependency\tpnpm-lock.yaml')
  export STUB_CLASSIFIER_OUTPUT

  run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$(printf '%s\n%s' "$directory/lib/dependent.bats" "$directory/lib/marked.bats")" ]

  run plan_fixture "$SCRIPT" "$directory" run-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  grep -qE '^ok [0-9]+ dependency one$' <<<"$output"
  grep -qE '^ok [0-9]+ dependency two$' <<<"$output"
  grep -qE '^ok [0-9]+ marked whole-tree$' <<<"$output"
  grep -qE 'marked plain$' <<<"$output" && return 1
  grep -qE 'unrelated$' <<<"$output" && return 1

  run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  [ "$status" -eq 0 ]
  grep -qx 'mode=scoped' <<<"$output"
  grep -qx 'reason=selected' <<<"$output"
  grep -qx 'needs_node=1' <<<"$output"
  grep -qx 'needs_chromium=0' <<<"$output"
}

@test "P4: without a dependency line the installed-dependencies suite is not listed" {
  local directory="$BATS_TEST_TMPDIR/p4"
  write_plan_fixture "$directory"

  run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$output" = "$directory/lib/marked.bats" ]
  run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  grep -qx 'needs_node=0' <<<"$output"
}

@test "P5: a change that owes nothing selects nothing and installs nothing" {
  local directory="$BATS_TEST_TMPDIR/p5"
  write_plan_fixture "$directory"
  rm "$directory/lib/dependent.bats" "$directory/lib/marked.bats" "$directory/lib/uat-lifecycle-e2e.bats"

  run plan_fixture "$SCRIPT" "$directory" files-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run plan_fixture "$SCRIPT" "$directory" run-for-change lib base-ref head-ref
  [ "$status" -eq 0 ]
  grep -qF 'lib holds no suite this change owes' <<<"$output"
  run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mode=none\nreason=nothing-selected\nneeds_node=0\nneeds_chromium=0')" ]
}

@test "P6: the Chromium need follows the set the leg will run" {
  local directory="$BATS_TEST_TMPDIR/p6"
  write_plan_fixture "$directory"

  STUB_SELECTOR_PICKS="$directory/lib/uat-lifecycle-e2e.bats" run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  grep -qx 'needs_chromium=1' <<<"$output"
  run plan_fixture "$SCRIPT" "$directory" plan lib base-ref head-ref
  grep -qx 'needs_chromium=0' <<<"$output"
  run plan_fixture "$SCRIPT" "$directory" plan lib --full
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'mode=full\nreason=requested\nneeds_node=1\nneeds_chromium=1')" ]
}

@test "P7: plan prints exactly four key=value lines in order, on every arm" {
  local directory="$BATS_TEST_TMPDIR/p7" arm
  write_plan_fixture "$directory"

  for arm in full harness unreadable selected none; do
    unset STUB_CLASSIFIER_OUTPUT STUB_CLASSIFIER_STATUS STUB_SELECTOR_PICKS
    case "$arm" in
      full) set -- --full ;;
      harness)
        STUB_CLASSIFIER_OUTPUT="$(printf 'harness\tx.sh')"
        set -- base-ref head-ref
        ;;
      unreadable)
        STUB_CLASSIFIER_STATUS=3
        set -- base-ref head-ref
        ;;
      selected)
        STUB_SELECTOR_PICKS="$directory/lib/unrelated.bats"
        set -- base-ref head-ref
        ;;
      none)
        rm -f "$directory/lib/marked.bats" "$directory/lib/dependent.bats"
        set -- base-ref head-ref
        ;;
    esac
    export STUB_CLASSIFIER_OUTPUT STUB_CLASSIFIER_STATUS STUB_SELECTOR_PICKS
    run plan_fixture "$SCRIPT" "$directory" plan lib "$@"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
    [ "$(sed -n '1p' <<<"$output" | cut -d= -f1)" = mode ]
    [ "$(sed -n '2p' <<<"$output" | cut -d= -f1)" = reason ]
    [ "$(sed -n '3p' <<<"$output" | cut -d= -f1)" = needs_node ]
    [ "$(sed -n '4p' <<<"$output" | cut -d= -f1)" = needs_chromium ]
    [ "$(grep -cE '^[a-z_]+=[a-z0-9-]+$' <<<"$output")" -eq 4 ]
  done
}

@test "P8: plan refuses a call with no shard, an unknown shard, or no change" {
  run bash "$SCRIPT" plan
  [ "$status" -eq 2 ]
  grep -q '^bats-shards:' <<<"$output"
  run bash "$SCRIPT" plan no-such-shard --full
  [ "$status" -eq 2 ]
  grep -q '^bats-shards:' <<<"$output"
  run bash "$SCRIPT" plan lib
  [ "$status" -eq 2 ]
  grep -q '^bats-shards:' <<<"$output"
}

# bats test_tags=whole-tree
@test "P9: a lockfile-only change owes every real shard its installed-dependencies and whole-tree suites" {
  local derived shard_id shard_file expected actual union=''
  derived="$(bash "$REPO_ROOT/.gaia/tests/installed-dependencies-mark-guard.sh" --list-derived)"
  [ -n "$derived" ]
  STUB_CLASSIFIER_OUTPUT=$(printf 'dependency\tpnpm-lock.yaml')
  export STUB_CLASSIFIER_OUTPUT
  export SUITES_FOR_CHANGE_SCRIPT="$BATS_TEST_TMPDIR/silent-selector.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SUITES_FOR_CHANGE_SCRIPT"

  for shard_id in $(bash "$SCRIPT" shards); do
    expected=''
    for shard_file in $(bash "$SCRIPT" files "$shard_id"); do
      if grep -qxF -- "$shard_file" <<<"$derived" ||
        grep -qE '^# bats (file|test)_tags=([^,]*,)*whole-tree(,|$)' "$REPO_ROOT/$shard_file"; then
        expected="$expected$shard_file"$'\n'
      fi
    done
    actual="$(bash "$SCRIPT" files-for-change "$shard_id" base-ref head-ref | sed "s|^$REPO_ROOT/||")"
    [ "$(printf '%s' "$actual" | LC_ALL=C sort)" = "$(printf '%s' "$expected" | sed '/^$/d' | LC_ALL=C sort)" ]
    union="$union$actual"$'\n'
    run bash "$SCRIPT" plan "$shard_id" base-ref head-ref
    [ "$status" -eq 0 ]
    grep -qx 'mode=full' <<<"$output" && return 1
  done
  for shard_file in capture-red-observations red-ledger-lib red-verify-commit-check red-verify-e2e worthiness-presence-check extract-test-signals-stories-reporter uat-lifecycle-e2e; do
    grep -q "/$shard_file\.bats\$" <<<"$union"
  done
}

# bats test_tags=whole-tree
@test "P10: the default classifier and selector seams resolve over the real tree" {
  run env -u CHANGE_SCOPE_SCRIPT -u SUITES_FOR_CHANGE_SCRIPT bash "$SCRIPT" files-for-change lib HEAD HEAD
  [ "$status" -eq 0 ]
}
