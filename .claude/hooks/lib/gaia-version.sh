#!/usr/bin/env bash
# gaia-version.sh: the one .gaia/VERSION read-and-normalize point for the
# GAIA-Audit version equality. Sourced, never executed; does no work at source
# time. The scope is that equality rather than every read of the file anywhere:
# the release workflow normalizes the same file differently and on purpose, to
# gate a release against a git tag, and nothing here is meant to reach it.
#
# The literal this produces is the first field of the GAIA-Audit trailer and of
# the GAIA-Audit commit-status description, and every reader compares it for
# EQUALITY to decide whether a standing clearance still applies. Producers and
# readers live in three trees (.github/audit, .gaia/scripts, .claude/hooks), so
# the normalization has to be one function rather than one idiom: correct a
# producer without correcting a reader and the two disagree forever, the audit
# re-runs on every push, and no component reports an error because each is
# behaving exactly as written (gaia-react/gaia#1297).
#
# The absent-file policy belongs to the CALLER, deliberately. The call sites
# disagree on what a missing file means -- some treat it as empty and let a
# later guard decide, one declines outright, one falls back to a ref -- and
# answering for them here would flatten three live policies into one. So a
# missing, unreadable, or blank file all yield the empty string and exit 0.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

# gaia_read_version <version-file> -> the normalized version literal on stdout,
# with no trailing newline, or the empty string when the file is absent,
# unreadable, or holds no non-blank line. Always exits 0.
gaia_read_version() {
  local file="${1:-}"
  local v=""

  if [ -n "$file" ] && [ -f "$file" ]; then
    # Strip CR, take the first non-blank line, trim surrounding whitespace.
    #
    # The gsub runs in its own pattern-less block so it fires BEFORE the NF
    # test, which is what makes this one process equivalent to piping `tr -d
    # '\r'` into `awk 'NF{print; exit}'`. Testing NF first instead would change
    # the answer on a line holding only a CR: awk's default field separator is
    # blank and newline, and CR is neither, so such a line has NF of 1, gets
    # selected, and prints empty, turning a readable version file into a
    # missing one. Doing it in one process rather than a pipe also keeps the
    # result independent of the caller's `pipefail`, which five of the seven
    # call sites set.
    v=$(awk '{ gsub(/\r/, "") } NF { print; exit }' "$file" 2>/dev/null) || v=""
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
  fi

  printf '%s' "$v"
}
