#!/usr/bin/env bash
# Shared bats primitives for asserting that a file did not change.
#
# Sourced from a suite's `setup()`, from any bats directory:
#   . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
#
# This is a CROSS-DIRECTORY helper, alongside `path.sh` and
# `hook-registration.sh` and distinct from the per-suite-directory
# `.gaia/tests/lib/helpers/` and `.gaia/tests/hooks/helpers/` by REACH rather
# than by how a file there is invoked: a suite in any bats directory may source
# what lives here, while those two serve their own directory's suites, whatever
# invocation style a file in them happens to use. Suites under
# `.gaia/scripts/tests/`, `.gaia/tests/lib/` and `.gaia/tests/hooks/` all use
# this one.
#
# API:
#   snapshot_file FILE           - copy FILE's bytes aside; print the copy's path
#   assert_files_identical A B   - `cmp` A against B; return 1 when they differ
#
# WHY THIS EXISTS, and why the obvious idiom is the bug it replaces.
#
# The convention these suites reached for was command substitution:
#
#   before="$(cat "$LEDGER")"
#   ...
#   [ "$(cat "$LEDGER")" = "$before" ]
#
# `$(…)` strips ALL trailing newlines from its output, on both sides. So a
# regression that only appends or drops a trailing newline compares equal, and
# it does so in the tests whose names promise byte identity (#1201, and #1047
# before it). The comparison is not weaker at the margin; it is blind to exactly
# the class of change a writer regression produces.
#
# Comparing FILES sidesteps the strip, because no file's bytes ever pass through
# a command substitution. That is the fix the sites #1047 repaired already
# use by hand; this file is the reusable form of it, so the next byte-identity
# test written reaches for a primitive rather than for `$(cat …)` out of habit.
#
# Sourced, so it enables no shell options of its own: bats runs each `@test`
# body under `set -e` already, and a suite that wants more sets it itself.

# snapshot_file FILE -> prints the path of a byte-exact copy of FILE.
#
# The copy lives under `$BATS_TEST_TMPDIR`, which bats removes after each test,
# so a snapshot never outlives the test that took it and no suite has to clean
# one up. `mktemp` names it, so two snapshots in one test cannot collide.
#
# `${BATS_TEST_TMPDIR:?}` rather than a fallback to `$TMPDIR`: outside a bats
# test there is no correct place for these, and failing loudly beats scattering
# copies somewhere nothing will collect them.
snapshot_file() {
  local source_file="$1" snapshot_directory destination_file
  snapshot_directory="${BATS_TEST_TMPDIR:?snapshot_file must be called from inside a bats test}/.snapshots"

  mkdir -p "$snapshot_directory" || return 1
  destination_file="$(mktemp "$snapshot_directory/snapshot.XXXXXX")" || return 1
  # `cp` rather than `cat >`: it is the byte-for-byte copy, and a read failure
  # (an unreadable or absent source) fails here rather than producing an empty
  # snapshot that would later compare equal to an emptied file.
  cp "$source_file" "$destination_file" || return 1

  printf '%s' "$destination_file"
}

# assert_files_identical A B: the two files hold identical bytes.
#
# `cmp` unsuppressed, so a failure names the differing byte offset instead of
# only reporting that the two disagreed, and it also fails loudly when either
# path is missing. The explicit `return 1` is what makes this safe anywhere in a
# test body: per `.claude/rules/bats-assertions.md`, a bare non-final assertion
# must fail through a real exit code rather than rely on `set -e`.
assert_files_identical() {
  cmp "$1" "$2" || return 1
}
