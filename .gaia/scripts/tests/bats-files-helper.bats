#!/usr/bin/env bats
# The shared byte-identity primitives in .gaia/tests/helpers/files.sh.
#
# Every byte-identity claim across the bats suites that consume it now rests
# on `assert_files_identical`, and a primitive that many assertions depend on is
# the worst place for an unproven one: an edit hollowing it back toward the
# `$(cat …)` comparison it replaced would green every consuming suite with nothing
# reddening anywhere. The suites it serves prove their own pins by mutation;
# this file holds the primitive to the same standard.
#
# The trailing-newline pair is the specific case that matters, because it is the
# whole reason the helper exists: command substitution strips trailing newlines
# from both sides, so `a\n` and `a\n\n\n` compare EQUAL through `$(cat …)` and
# differ under `cmp`. Test 2 pins that difference directly.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"

  FIRST_FILE="$BATS_TEST_TMPDIR/a"
  SECOND_FILE="$BATS_TEST_TMPDIR/b"
}

@test "assert_files_identical accepts two files with identical bytes" {
  printf 'one\ntwo\n' > "$FIRST_FILE"
  printf 'one\ntwo\n' > "$SECOND_FILE"
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE"
}

@test "assert_files_identical rejects a pair differing only in a trailing newline" {
  printf 'one\ntwo\n' > "$FIRST_FILE"
  printf 'one\ntwo\n\n\n' > "$SECOND_FILE"

  # Written as a positive match on the bad case per the bats-assertions rule.
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE" && {
    echo "the helper accepts a trailing-newline difference; it has decayed into the \$(cat …) comparison it replaced" >&2
    return 1
  }

  # And the control: that same pair IS equal through command substitution, which
  # is the defect this primitive exists to remove rather than a hypothetical.
  [ "$(cat "$FIRST_FILE")" = "$(cat "$SECOND_FILE")" ] || {
    echo "control broken: the fixture pair no longer demonstrates the \$(cat …) strip" >&2
    return 1
  }
}

@test "assert_files_identical rejects a pair differing in the middle" {
  printf 'one\ntwo\n' > "$FIRST_FILE"
  printf 'one\nTWO\n' > "$SECOND_FILE"
  assert_files_identical "$FIRST_FILE" "$SECOND_FILE" && return 1
  true
}

@test "assert_files_identical fails rather than passes when a file is missing" {
  printf 'one\n' > "$FIRST_FILE"
  # An absent path must never read as "identical". `cmp` exits non-zero and says
  # which path it could not open.
  assert_files_identical "$FIRST_FILE" "$BATS_TEST_TMPDIR/does-not-exist" && return 1
  true
}

@test "snapshot_file captures bytes that later writes to the source cannot change" {
  printf 'before\n' > "$FIRST_FILE"
  local snapshot_path
  snapshot_path="$(snapshot_file "$FIRST_FILE")"

  [ -n "$snapshot_path" ] || { echo "snapshot_file printed no path" >&2; return 1; }
  [ "$snapshot_path" != "$FIRST_FILE" ] || { echo "snapshot_file returned the source path itself" >&2; return 1; }

  printf 'after\n' > "$FIRST_FILE"
  assert_files_identical "$snapshot_path" "$FIRST_FILE" && {
    echo "the snapshot tracked a later write; it is an alias, not a copy" >&2
    return 1
  }

  printf 'before\n' > "$SECOND_FILE"
  assert_files_identical "$snapshot_path" "$SECOND_FILE"
}

@test "snapshot_file preserves a trailing newline exactly" {
  # The capture half of the same defect: a snapshot taken through command
  # substitution would drop these, and the comparison could never see them again.
  printf 'row\n\n\n' > "$FIRST_FILE"
  local snapshot_path
  snapshot_path="$(snapshot_file "$FIRST_FILE")"
  assert_files_identical "$snapshot_path" "$FIRST_FILE"
}

@test "two snapshots in one test do not collide" {
  printf 'first\n' > "$FIRST_FILE"
  printf 'second\n' > "$SECOND_FILE"
  local first_snapshot second_snapshot
  first_snapshot="$(snapshot_file "$FIRST_FILE")"
  second_snapshot="$(snapshot_file "$SECOND_FILE")"

  [ "$first_snapshot" != "$second_snapshot" ] || { echo "both snapshots landed on one path" >&2; return 1; }
  assert_files_identical "$first_snapshot" "$FIRST_FILE"
  assert_files_identical "$second_snapshot" "$SECOND_FILE"
}
