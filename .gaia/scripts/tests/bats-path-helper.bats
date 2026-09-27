#!/usr/bin/env bats
# The shared PATH primitives in .gaia/tests/helpers/path.sh.
#
# A bats suite that drives a "tool is not installed" arm on a developer machine
# where the tool really is installed needs a PATH with that tool guaranteed
# absent. The need arrived independently in suites across the tree, each with
# its own hand-rolled rebuild loop; a tree-wide grep for `helpers/path.sh`
# answers which suites are clients today. Separately, and not at every one of
# those loops, the membership test was written as `[ -x "$dir/$name" ]`.
#
# That predicate is wrong in one direction. `-x` is true for a searchable
# DIRECTORY named for the tool, not only for an executable file, so a PATH
# entry that merely holds such a directory was dropped along with every real
# tool it provides. bash's own PATH lookup accepts a regular file that is
# executable, which is `-f` and `-x` together.
#
# The direction is safe -- an over-strip removes a needed tool and fails the
# command under test rather than greening it -- so what makes this worth a
# primitive is the DUPLICATION rather than the defect. A rule with two homes
# gets repaired in one of them, and the copy nobody edited has nothing red to
# catch the drift. The client suites exercise the primitives through their own
# "not installed" arms; this file pins only that the two builders refuse to
# write outside a bats per-test temp dir.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
}

@test "path_shim_without refuses rather than writing outside a bats per-test temp dir" {
  # Sourced outside a test there is nowhere sanctioned to build the shim, and
  # picking one anyway would write where no caller asked. Asserted on the
  # diagnostic rather than on the status alone: a non-zero status is also what a
  # failed mkdir at an unwritable guessed path returns, so the status cannot
  # tell the refusal apart from the accident it exists to replace.
  local out rc=0
  out="$(BATS_TEST_TMPDIR="" path_shim_without uvx 2>&1)" || rc=$?
  [ "$rc" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$out"
}

@test "path_allowlist refuses rather than writing outside a bats per-test temp dir" {
  # Same refusal, and the same reason, as path_shim_without's: the directory is
  # torn down with the test that built it, so outside a test there is nowhere
  # sanctioned to build one. Asserted on the diagnostic rather than the status
  # alone, because a failed mkdir at a guessed path returns non-zero too.
  local out rc=0
  out="$(BATS_TEST_TMPDIR="" path_allowlist gaia-fixture-wanted 2>&1)" || rc=$?
  [ "$rc" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$out"
}
