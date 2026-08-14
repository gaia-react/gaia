#!/usr/bin/env bats
# Tests for .claude/hooks/lib/gaia-version.sh, the one .gaia/VERSION
# read-and-normalize point.
#
# Two things are under test, and the second is the point of the file. The
# first is the normalization itself: CR stripping, first-non-blank-line
# selection, surrounding-whitespace trim, and the caller-owned absent-file
# policy the header states.
#
# The second is that the idiom exists exactly once. The literal this produces
# is the first field of the GAIA-Audit trailer and of the GAIA-Audit commit
# status, and readers compare it for equality to decide whether a clearance
# still applies, so a second copy is not redundancy but a second answer to one
# equality: repair one copy and its producer stamps a literal an unrepaired
# reader can never match, with every component behaving exactly as written and
# no error anywhere (#1297). The structural test below is the
# only thing that can catch a copy coming back, because a reintroduced copy
# agrees with the helper on the day it lands and diverges silently later.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  VERSION_LIB="$REPO_ROOT/.claude/hooks/lib/gaia-version.sh"
  [ -f "$VERSION_LIB" ] || skip "gaia-version.sh not present"
  # shellcheck source=/dev/null
  . "$VERSION_LIB"

  TMP="$BATS_TEST_TMPDIR/version"
  mkdir -p "$TMP"
}

@test "a plain version file normalizes to the bare literal" {
  printf '1.6.1\n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "1.6.1" ]
}

@test "CRLF line endings are stripped" {
  printf '1.6.1\r\n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$output" = "1.6.1" ]
}

@test "leading blank lines are skipped and the first non-blank line wins" {
  printf '\n\n1.6.1\n2.0.0\n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$output" = "1.6.1" ]
}

# A line holding only a CR is blank once the CR is stripped, so it is skipped
# like any other blank line. This pins the ordering inside the reader rather
# than a caller-visible nicety: CR is not awk's default field separator, so a
# reader that tested for a non-blank line BEFORE stripping would select this
# line, print nothing, and report a readable version file as missing.
@test "a CR-only line is blank and is skipped, not selected" {
  printf '\r\n1.6.1\n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$output" = "1.6.1" ]
}

@test "surrounding whitespace is trimmed" {
  printf '   1.6.1\t \n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$output" = "1.6.1" ]
}

# The absent-file and empty-file cases are one contract, not two: both yield
# the empty string and exit 0, because the five call sites disagree on what a
# missing file means and the helper must not flatten those policies.

@test "an absent file yields the empty string and exits 0" {
  run gaia_read_version "$TMP/nope"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a whitespace-only file yields the empty string and exits 0" {
  printf '\n  \n\t\n' > "$TMP/VERSION"
  run gaia_read_version "$TMP/VERSION"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty argument yields the empty string and exits 0" {
  run gaia_read_version ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The structural pin. A CR strip paired with a first-non-blank-line awk select
# is the read half of the idiom; the helper is the only file allowed to hold
# it. A site that grows its own copy again reds here rather than at the point,
# some releases later, where the two literals stop matching.
#
# Both halves match on a regex rather than a fixed string, so a copy that
# merely reshuffles quoting or spacing (`tr -d "\r"`, `NF {print; exit}`) is
# still caught.
#
# The accepted miss is the `*.sh` pathspec: a workflow `run:` block holds shell
# without being a `.sh` file, so an eighth copy inlined into one reds nowhere.
# Widening the pathspec alone catches nothing, though. Both regexes are written
# against this idiom, and the one `.yml` that reads the same file spells it
# `cat .gaia/VERSION | tr -d '[:space:]'`, which matches neither half. Catching
# an inlined copy would mean loosening the regexes as well, and that is the step
# to be careful with: `release.yml` normalizes this file deliberately and
# differently, for tag equality rather than for the audit equality pinned here.

@test "the read-and-normalize idiom lives in exactly one tracked file" {
  cr_strip='(tr -d .\\r.|gsub\(/\\r/)'
  first_line='NF[[:space:]]*\{[[:space:]]*print;[[:space:]]*exit'

  # The candidate walk uses `if`, not `grep && printf`: an `if` whose condition
  # is false still exits 0, so a final candidate that does not match cannot
  # leave the loop non-zero and abort the test under bats' `set -e` before its
  # own assertion runs.
  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qE -- "$first_line" "$REPO_ROOT/$f"; then
      hits="${hits}${f}
"
    fi
  done <<<"$(cd "$REPO_ROOT" && git grep -lE -- "$cr_strip" -- '*.sh')"

  [ "$hits" = ".claude/hooks/lib/gaia-version.sh
" ]
}
