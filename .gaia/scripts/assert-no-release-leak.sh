#!/usr/bin/env bash
# shellcheck shell=bash
#
# assert-no-release-leak.sh -- the shipped-tree leak assertion: prove that no
# release-excluded path survived into the tree that becomes the tarball.
#
# The assertion this replaces derived its verdict from a command substitution
# whose producer failure was unobservable (#2061):
#
#   leaked="$( (cd "$STAGING" && find . -type f | sed 's|^\./||') \
#     | grep -E -f /tmp/exclude-regex.txt || true )"
#   if [ -n "$leaked" ]; then ... exit 1; fi
#
# An empty `leaked` was read as "nothing leaked". But empty is also what the
# pipeline produces when the PRODUCER fails: the `cd` does not land, `find`
# aborts part way through an unreadable directory, or `sed` dies. The
# substitution's status is `grep`'s alone, `grep` exits 1 on no-match, and
# `|| true` swallowed that, so nothing distinguished "the scan found nothing"
# from "the scan did not happen". Worse, `shopt inherit_errexit` is off in a
# GitHub step body (`bash -e {0}`), so a failure inside the substitution
# neither aborted the group nor propagated: a PARTIAL enumeration was accepted
# silently, and the assertion ran over whatever subset `find` reached before it
# stopped. The failure direction was fail-open on the gate that decides whether
# a maintainer-only path ships to every adopter.
#
# Three things make the scan's own failure observable here. The enumeration runs
# under `pipefail` with its status read directly, so a failing `cd`, `find`, or
# `sed` is a hard failure rather than an empty result. The match reads `grep`'s
# status as a three-way answer -- matched, did not match, could not run --
# rather than collapsing the last two into "clean". And an empty staged tree is
# refused rather than passed, because a staging step that produced no files at
# all is the same fail-open shape one layer up: nothing to scan reads exactly
# like nothing to find.
#
#   bash .gaia/scripts/assert-no-release-leak.sh <staging-dir> <exclude-regex-file>
#
# <exclude-regex-file> holds the anchored ERE patterns `gaia-maintainer release
# exclude-regex` compiles from .gaia/release-exclude, one per line, matched
# against staging-relative paths with no leading `./`.
#
# Exit 0 when the tree was scanned and holds no release-excluded path, which
# includes the legitimately empty exclude list (nothing is withheld, so nothing
# can leak).
#
# Exit 1 on the refusal, and only on the refusal: at least one release-excluded
# path is present in the staged tree. Every offending path is named on stderr,
# beside the diagnostic naming the tree; nothing is written to stdout on any
# path out of this script. So a caller that wants the list captures stderr, and
# one that captures stdout alone is handed the empty string on a real leak,
# which is the same empty-means-clean shape this script exists to close.
#
# Exit 2 on every condition that leaves the question UNANSWERED, which is the
# whole point of the split: a usage error, a staging directory that is missing
# or is not a directory, an exclude-regex file that is missing or unreadable, a
# scratch file that cannot be created or written, an enumeration that failed or
# stopped short, an empty staged tree, and a `grep` that could not run its
# patterns. A caller must treat 2 as fatal exactly as it treats 1; the two are
# separated so the diagnostic can say which happened, never so that 2 can be
# waved through.

set -u

usage() {
  printf 'usage: assert-no-release-leak.sh <staging-dir> <exclude-regex-file>\n' >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

staging_dir="$1"
exclude_regex="$2"

if [ ! -d "$staging_dir" ]; then
  printf 'assert-no-release-leak: staging tree is missing or is not a directory: %s\n' \
    "$staging_dir" >&2
  exit 2
fi

if [ ! -r "$exclude_regex" ]; then
  printf 'assert-no-release-leak: exclude-regex file is missing or unreadable: %s\n' \
    "$exclude_regex" >&2
  exit 2
fi

# A compiled exclude list with no patterns means nothing is withheld from the
# distribution, so no path in the staged tree can be a leak. This is the one
# empty input that is an answer rather than an absent one, and it is separated
# from the empty-tree refusal below for that reason.
if [ ! -s "$exclude_regex" ]; then
  exit 0
fi

staged_list="$(mktemp)" || {
  printf 'assert-no-release-leak: could not create a scratch file for the staged-path list\n' >&2
  exit 2
}
trap 'rm -f "$staged_list"' EXIT

# The producer runs in its own subshell with `pipefail` armed and its status
# read directly, which is the whole repair. Every way this enumeration can come
# up short -- `cd` not landing, `find` aborting on a directory it cannot read,
# `sed` dying mid-stream, the redirect failing on a full or unwritable scratch
# location -- now reaches the caller as a non-zero status instead of as an empty
# result indistinguishable from a clean tree. The statuses are not separated
# further because the operator's next step is the same for all of them: the scan
# did not complete, so re-run the staging step and read the stderr `find`, `sed`,
# or the shell already printed immediately above this diagnostic.
if ! ( set -o pipefail; cd "$staging_dir" && find . -type f | sed 's|^\./||' ) \
    > "$staged_list"; then
  printf 'assert-no-release-leak: could not enumerate the staged tree at %s;\n' \
    "$staging_dir" >&2
  printf '  the scan did not complete, so leak-freedom is UNPROVEN. See the diagnostic above.\n' >&2
  exit 2
fi

# A staging step that copied nothing satisfies any leak scan trivially. Refusing
# here is the same class of repair as the status capture above: an input set
# that is empty for a reason nobody checked reads exactly like a clean pass.
if [ ! -s "$staged_list" ]; then
  printf 'assert-no-release-leak: the staged tree at %s holds no files;\n' "$staging_dir" >&2
  printf '  an empty tree passes any leak scan without proving anything. Staging failed upstream.\n' >&2
  exit 2
fi

# `grep`'s status is a three-way answer and is read as one: 0 matched, 1 did not
# match, anything else could not run the patterns (an unreadable pattern file, a
# pattern the ERE engine rejects, a resource limit). Collapsing the last two into
# "clean" is the second half of the defect this script exists to close.
leaked="$(grep -E -f "$exclude_regex" "$staged_list")"
grep_status=$?

case "$grep_status" in
  0)
    printf 'assert-no-release-leak: release-excluded path(s) leaked into %s:\n' "$staging_dir" >&2
    printf '%s\n' "$leaked" >&2
    exit 1
    ;;
  1)
    exit 0
    ;;
  *)
    printf 'assert-no-release-leak: the leak scan of %s could not run (grep exit %s);\n' \
      "$staging_dir" "$grep_status" >&2
    printf '  leak-freedom is UNPROVEN. Check the pattern file %s.\n' "$exclude_regex" >&2
    exit 2
    ;;
esac
