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
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"

  A="$BATS_TEST_TMPDIR/a"
  B="$BATS_TEST_TMPDIR/b"
}

@test "assert_files_identical accepts two files with identical bytes" {
  printf 'one\ntwo\n' > "$A"
  printf 'one\ntwo\n' > "$B"
  assert_files_identical "$A" "$B"
}

@test "assert_files_identical rejects a pair differing only in a trailing newline" {
  printf 'one\ntwo\n' > "$A"
  printf 'one\ntwo\n\n\n' > "$B"

  # Written as a positive match on the bad case per the bats-assertions rule.
  assert_files_identical "$A" "$B" && {
    echo "the helper accepts a trailing-newline difference; it has decayed into the \$(cat …) comparison it replaced" >&2
    return 1
  }

  # And the control: that same pair IS equal through command substitution, which
  # is the defect this primitive exists to remove rather than a hypothetical.
  [ "$(cat "$A")" = "$(cat "$B")" ] || {
    echo "control broken: the fixture pair no longer demonstrates the \$(cat …) strip" >&2
    return 1
  }
}

@test "assert_files_identical rejects a pair differing in the middle" {
  printf 'one\ntwo\n' > "$A"
  printf 'one\nTWO\n' > "$B"
  assert_files_identical "$A" "$B" && return 1
  true
}

@test "assert_files_identical fails rather than passes when a file is missing" {
  printf 'one\n' > "$A"
  # An absent path must never read as "identical". `cmp` exits non-zero and says
  # which path it could not open.
  assert_files_identical "$A" "$BATS_TEST_TMPDIR/does-not-exist" && return 1
  true
}

@test "snapshot_file captures bytes that later writes to the source cannot change" {
  printf 'before\n' > "$A"
  local snap
  snap="$(snapshot_file "$A")"

  [ -n "$snap" ] || { echo "snapshot_file printed no path" >&2; return 1; }
  [ "$snap" != "$A" ] || { echo "snapshot_file returned the source path itself" >&2; return 1; }

  printf 'after\n' > "$A"
  assert_files_identical "$snap" "$A" && {
    echo "the snapshot tracked a later write; it is an alias, not a copy" >&2
    return 1
  }

  printf 'before\n' > "$B"
  assert_files_identical "$snap" "$B"
}

@test "snapshot_file preserves a trailing newline exactly" {
  # The capture half of the same defect: a snapshot taken through command
  # substitution would drop these, and the comparison could never see them again.
  printf 'row\n\n\n' > "$A"
  local snap
  snap="$(snapshot_file "$A")"
  assert_files_identical "$snap" "$A"
}

@test "two snapshots in one test do not collide" {
  printf 'first\n' > "$A"
  printf 'second\n' > "$B"
  local s1 s2
  s1="$(snapshot_file "$A")"
  s2="$(snapshot_file "$B")"

  [ "$s1" != "$s2" ] || { echo "both snapshots landed on one path" >&2; return 1; }
  assert_files_identical "$s1" "$A"
  assert_files_identical "$s2" "$B"
}
