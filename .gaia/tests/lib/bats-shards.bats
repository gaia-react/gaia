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
# mutate a scratch copy of the script to prove those three checks can
# actually fail, following the discipline .gaia/tests/lib/run-bats-parallel.bats
# sets for its own F1/F2 fixtures.
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
  SCRIPTS_TESTS_DIR_DEFAULT='.gaia/scripts/tests'
  AUDIT_TESTS_DIR_DEFAULT='.github/audit/tests'
  LIB_DIR_DEFAULT='.gaia/tests/lib'
  FORENSICS_DIR_DEFAULT='.gaia/tests/forensics'
  STATUSLINE_DIR_DEFAULT='.gaia/tests/statusline'
}

teardown() {
  local p
  if [ -f "$BATS_TEST_TMPDIR/scratch-copies" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
      if [ -n "$p" ]; then
        rm -f "$p"
      fi
    done <"$BATS_TEST_TMPDIR/scratch-copies"
  fi
}

# Every *.bats directly inside repo-relative dir $1, LC_ALL=C sorted. A
# second, independent implementation of the script's own discover_bats: this
# must never call the script, or S1 would only prove the script agrees with
# itself.
discover_independent() {
  local dir="$1" f
  for f in "$REPO_ROOT/$dir"/*.bats; do
    if [ -e "$f" ]; then
      printf '%s\n' "${f#"$REPO_ROOT"/}"
    fi
  done | LC_ALL=C sort
}

# The independently discovered union of all six default directories.
all_discovered() {
  {
    discover_independent "$HOOKS_DIR_DEFAULT"
    discover_independent "$SCRIPTS_TESTS_DIR_DEFAULT"
    discover_independent "$AUDIT_TESTS_DIR_DEFAULT"
    discover_independent "$LIB_DIR_DEFAULT"
    discover_independent "$FORENSICS_DIR_DEFAULT"
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
  local script="$1" dupes
  dupes="$(union_of_shard_files "$script" | LC_ALL=C sort | uniq -d)"
  [ -z "$dupes" ]
}

# S3: every shard id resolves at least one file.
check_no_empty_shard() {
  local script="$1" id n
  while IFS= read -r id; do
    n="$(bash "$script" files "$id" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
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
  local dest
  dest="$(mktemp "$BATS_TEST_DIRNAME/.bats-shards-scratch.XXXXXX")"
  cp "$SCRIPT" "$dest"
  chmod +x "$dest"
  printf '%s\n' "$dest" >>"$BATS_TEST_TMPDIR/scratch-copies"
  printf '%s\n' "$dest"
}

# A1 fixture: makes the first (0-based) unpinned hooks file match no
# round-robin target on the copy, so it is assigned to no shard while every
# shard the copy reports still exits 0 and stays non-empty. Proves
# check_partition can fail.
doctor_dropped_file() {
  local dest anchor
  dest="$(copy_sharder a1-dropped.sh)"
  # Matched by shape, not by one exact spelling: the loop it anchors on is
  # written with bash 3.2's empty-array offset guard, and a -F anchor pinned to
  # the bare "${rest[@]}" form silently stops matching the moment that guard is
  # added or removed. A no-match would splice nothing, leaving an undoctored
  # copy that proves nothing.
  anchor="$(grep -nE 'for p in .*\$\{rest\[@\]' "$dest" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || return 1
  awk -v a="$anchor" '
    { print }
    NR == a { print "    if [ \"$i\" -eq 0 ]; then i=$((i + 1)); continue; fi" }
  ' "$dest" >"$dest.new"
  mv "$dest.new" "$dest"
  printf '%s\n' "$dest"
}

# A2 fixture: forces the first (0-based) scripts-tests file to also print
# under scripts-2 on the copy, so it lands in both scripts-1 and scripts-2.
# Proves check_no_duplicates can fail.
doctor_duplicated_file() {
  local dest anchor
  dest="$(copy_sharder a2-duplicated.sh)"
  anchor="$(grep -nF 'mod=$((i % 2 + 1))' "$dest" | head -1 | cut -d: -f1)"
  [ -n "$anchor" ] || return 1
  awk -v a="$anchor" '
    { print }
    NR == a { print "    if [ \"$target\" -eq 2 ] && [ \"$i\" -eq 0 ]; then printf \"%s\\n\" \"$p\"; fi" }
  ' "$dest" >"$dest.new"
  mv "$dest.new" "$dest"
  printf '%s\n' "$dest"
}

# A3 fixture: removes cmd_files' own fail-closed zero-files guard on the copy,
# so a shard resolving to nothing still exits 0 with empty output instead of
# exit 2. What this proves is that check_no_empty_shard itself would catch a
# regression in that guard, not merely that the guard exists.
doctor_bypassed_zero_guard() {
  local dest start end
  dest="$(copy_sharder a3-bypassed-guard.sh)"
  start="$(grep -nF 'if [ -z "$out" ]; then' "$dest" | head -1 | cut -d: -f1)"
  [ -n "$start" ] || return 1
  end=$((start + 4))
  awk -v s="$start" -v e="$end" '
    NR == s { print "  [ -z \"$out\" ] || printf \"%s\\n\" \"$out\""; next }
    NR > s && NR <= e { next }
    { print }
  ' "$dest" >"$dest.new"
  mv "$dest.new" "$dest"
  printf '%s\n' "$dest"
}

# Directory of a builtin_table() row's command field: `bats X/` yields `X`;
# `bash X/run-all.sh` yields `X` (its dirname). Used by S10 to derive the
# pre-sharding six-directory surface without restating it by hand.
extract_dir_from_cmd() {
  local cmd="$1" path
  path="${cmd#* }"
  case "$path" in
    *.sh) path="${path%/*}" ;;
    */) path="${path%/}" ;;
  esac
  printf '%s\n' "$path"
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

@test "S1: shards partition equals the independently discovered file set" {
  run check_partition "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "S2: no duplicate path across the shard partition" {
  run check_no_duplicates "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "S3: no shard resolves to zero files" {
  run check_no_empty_shard "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "S4: shards prints exactly nine ids in the documented order" {
  run bash "$SCRIPT" shards
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  expected="hooks-1
hooks-2
hooks-3
hooks-4
scripts-1
scripts-2
audit
lib
misc"
  [ "$output" = "$expected" ]
  grep -qF -- 'sandbox' <<<"$output" && return 1
  grep -qF -- 'concurrency' <<<"$output" && return 1
  return 0
}

@test "S5: hooks-1 is exactly the pinned singleton" {
  run bash "$SCRIPT" files hooks-1
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/hooks/local-janitor.bats" ]
}

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
  HOOKS_DIR="$empty_hooks" run bash "$SCRIPT" files hooks-2
  [ "$status" -eq 2 ]
  grep -qF -- 'hooks-2' <<<"$output"

  empty_forensics="$BATS_TEST_TMPDIR/s7-empty-forensics"
  empty_statusline="$BATS_TEST_TMPDIR/s7-empty-statusline"
  mkdir -p "$empty_forensics" "$empty_statusline"
  FORENSICS_DIR="$empty_forensics" STATUSLINE_DIR="$empty_statusline" run bash "$SCRIPT" files misc
  [ "$status" -eq 2 ]
  grep -qF -- 'misc' <<<"$output"
}

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

@test "S9: no shard is unbalanced against a broken modulo" {
  local n_hooks n_unpinned n_scripts hooks_cap scripts_cap id count
  n_hooks=$(discover_independent "$HOOKS_DIR_DEFAULT" | wc -l | tr -d ' ')
  n_unpinned=$((n_hooks - 1))
  n_scripts=$(discover_independent "$SCRIPTS_TESTS_DIR_DEFAULT" | wc -l | tr -d ' ')
  hooks_cap=$(((n_unpinned + 3 - 1) / 3 + 1))
  scripts_cap=$(((n_scripts + 2 - 1) / 2 + 1))
  for id in hooks-2 hooks-3 hooks-4; do
    count=$(bash "$SCRIPT" files "$id" | wc -l | tr -d ' ')
    if [ "$count" -gt "$hooks_cap" ]; then
      return 1
    fi
  done
  for id in scripts-1 scripts-2; do
    count=$(bash "$SCRIPT" files "$id" | wc -l | tr -d ' ')
    if [ "$count" -gt "$scripts_cap" ]; then
      return 1
    fi
  done
  return 0
}

@test "S10: the sharder's six roots equal run-bats-parallel.sh's builtin_table() surface" {
  local runner row cmd dir dirs expected
  runner="$BATS_TEST_DIRNAME/../run-bats-parallel.sh"
  run bash -c "source '$runner'; builtin_table"
  [ "$status" -eq 0 ]
  dirs=""
  for row in "${lines[@]}"; do
    cmd="${row##*$'\t'}"
    dir="$(extract_dir_from_cmd "$cmd")"
    dirs="$dirs$dir"$'\n'
  done
  dirs="$(printf '%s' "$dirs" | LC_ALL=C sort -u)"
  expected="$(printf '%s\n' \
    "$HOOKS_DIR_DEFAULT" "$SCRIPTS_TESTS_DIR_DEFAULT" "$AUDIT_TESTS_DIR_DEFAULT" \
    "$LIB_DIR_DEFAULT" "$FORENSICS_DIR_DEFAULT" "$STATUSLINE_DIR_DEFAULT" | LC_ALL=C sort -u)"
  [ "$dirs" = "$expected" ]
}

@test "S11: a pinned hook missing from discovery is a fail-closed error" {
  local dir
  dir="$BATS_TEST_TMPDIR/s11-hooks"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' >"$dir/not-the-pinned-file.bats"
  HOOKS_DIR="$dir" run bash "$SCRIPT" files hooks-1
  [ "$status" -eq 2 ]
  grep -qF -- 'local-janitor.bats' <<<"$output"
}

@test "S12: run honors the seam and executes exactly what files lists" {
  local d1 d2 files_output
  d1="$BATS_TEST_TMPDIR/s12-forensics"
  d2="$BATS_TEST_TMPDIR/s12-statusline"
  mkdir -p "$d1" "$d2"
  write_trivial_bats "$d1/marker-a.bats" "MARK-A"
  write_trivial_bats "$d2/marker-b.bats" "MARK-B"

  FORENSICS_DIR="$d1" STATUSLINE_DIR="$d2" run bash "$SCRIPT" files misc
  [ "$status" -eq 0 ]
  files_output="$output"

  FORENSICS_DIR="$d1" STATUSLINE_DIR="$d2" run bash "$SCRIPT" run misc
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

@test "A1: dropped file reds the partition check" {
  local copy
  copy="$(doctor_dropped_file)"
  run check_partition "$copy"
  [ "$status" -eq 1 ]
}

@test "A2: duplicated file reds the no-duplicates check" {
  local copy
  copy="$(doctor_duplicated_file)"
  run check_no_duplicates "$copy"
  [ "$status" -eq 1 ]
}

@test "A3: an empty shard behind a bypassed guard reds the no-empty-shard check" {
  local copy dir
  copy="$(doctor_bypassed_zero_guard)"
  dir="$BATS_TEST_TMPDIR/a3-empty-scripts"
  mkdir -p "$dir"

  # First, prove the guard itself is actually bypassed on the copy: exit 0
  # with empty output, where the real script would exit 2.
  SCRIPTS_TESTS_DIR="$dir" run bash "$copy" files scripts-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  SCRIPTS_TESTS_DIR="$dir" run check_no_empty_shard "$copy"
  [ "$status" -eq 1 ]
}
