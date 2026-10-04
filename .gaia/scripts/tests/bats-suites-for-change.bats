#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/bats-suites-for-change.sh, the one owner
# of "every bats suite that references a file the change edits or deletes".
#
# The pin that matters most is the first test: a changed path holding a space
# selects only the suites naming its whole basename. A hand-rolled
# `for f in $(git diff --name-only ...)` word-splits that path into fragments
# (`PR`, `Merge`, `Workflow.md`) that match nearly every suite, so the fixture
# carries one suite per fragment and asserts none of them is selected.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/bats-suites-for-change.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/bats-suites-for-change.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE/wiki" "$FIXTURE/tests"
  git -C "$FIXTURE" init -q -b main
  git -C "$FIXTURE" config user.email t@example.com
  git -C "$FIXTURE" config user.name t
  git -C "$FIXTURE" config commit.gpgsign false

  printf 'one\n' > "$FIXTURE/wiki/PR Merge Workflow.md"
  printf 'two\n' > "$FIXTURE/wiki/other.md"
  printf 'three\n' > "$FIXTURE/gone.sh"
  printf '# reads PR Merge Workflow.md\n' > "$FIXTURE/tests/names-it.bats"
  printf '# PR\n' > "$FIXTURE/tests/fragment-pr.bats"
  printf '# Merge\n' > "$FIXTURE/tests/fragment-merge.bats"
  printf '# Workflow.md\n' > "$FIXTURE/tests/fragment-workflow.bats"
  printf '# sources gone.sh\n' > "$FIXTURE/tests/names-gone.bats"
  printf '# unrelated\n' > "$FIXTURE/tests/unrelated.bats"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m base
  BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
  # The default mode diffs against the merge base with the remote default
  # branch; a remote-tracking ref is all it reads, so no real remote is needed.
  git -C "$FIXTURE" update-ref refs/remotes/origin/main "$BASE"
}

@test "a changed path holding a space selects only suites naming its whole basename" {
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am edit

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/names-it.bats" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a deleted file still selects the suites referencing it" {
  git -C "$FIXTURE" rm -q gone.sh
  git -C "$FIXTURE" commit -q -m delete

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/names-gone.bats" ]
}

@test "a renamed file still selects the suites naming its old basename" {
  git -C "$FIXTURE" mv gone.sh renamed.sh
  git -C "$FIXTURE" commit -q -m rename

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/names-gone.bats" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a renamed file selects the suites naming its old basename in the default mode" {
  git -C "$FIXTURE" mv gone.sh renamed.sh

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "tests/names-gone.bats" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "a changed suite selects itself even when nothing names it" {
  printf '# edited\n' >> "$FIXTURE/tests/unrelated.bats"
  git -C "$FIXTURE" commit -q -am edit-suite

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "tests/unrelated.bats" ]
}

@test "a deleted suite is not printed, since there is nothing left to run" {
  git -C "$FIXTURE" rm -q tests/unrelated.bats
  git -C "$FIXTURE" commit -q -m drop-suite

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no argument covers committed, uncommitted, and untracked changes since the merge base" {
  printf 'committed\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am committed
  printf 'uncommitted\n' >> "$FIXTURE/gone.sh"
  printf 'new\n' > "$FIXTURE/wiki/fresh.md"
  printf '# reads fresh.md\n' > "$FIXTURE/tests/names-fresh.bats"

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ]
  expected="$(printf 'tests/names-fresh.bats\ntests/names-gone.bats\ntests/names-it.bats')"
  [ "$output" = "$expected" ] || {
    printf 'got:\n%s\n' "$output" >&2
    return 1
  }
}

@test "no change prints nothing and exits 0" {
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unreadable diff fails loudly instead of reporting no suites" {
  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" no-such-revision HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"bats-suites-for-change"* ]]
}

@test "a failing suite search fails loudly instead of dropping that path's suites" {
  printf 'edited\n' >> "$FIXTURE/wiki/PR Merge Workflow.md"
  git -C "$FIXTURE" commit -q -am edit
  # A git that answers every subcommand but grep, which it fails the way an
  # unreadable object store does (status 128, not grep's no-match 1).
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nfor argument in "$@"; do [ "$argument" = grep ] && exit 128; done\nexec "%s" "$@"\n' \
    "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE" "$BASE" HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "no remote default branch in the default mode names the fix" {
  git -C "$FIXTURE" update-ref -d refs/remotes/origin/main

  run --separate-stderr bash "$SCRIPT" --dir "$FIXTURE"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"pass a range"* ]]
}

@test "an unknown option is a usage error" {
  run --separate-stderr bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
