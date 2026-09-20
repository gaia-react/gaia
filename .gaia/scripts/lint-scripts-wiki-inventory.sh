#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-scripts-wiki-inventory.sh: flag every file at the root of
# .gaia/scripts/ that wiki/concepts/GAIA Scripts.md does not mention. Exit 0
# when every root file appears on the page, 1 with a per-file report on any
# gap, 2 on the check's own failure, and 130 or 143 when a SIGINT or SIGTERM
# interrupts it (see the trap arms in main). Run it from anywhere:
# `bash .gaia/scripts/lint-scripts-wiki-inventory.sh [<repo_root>]`.
#
# TWO SOURCES, UNIONED. A root file is a subject when git tracks it, or when
# it is an `.sh` sitting at the root of the directory. Neither source is
# complete alone. The tracked listing is the authoritative set and the only
# one that reaches a root file which is not shell -- the rate card the cost
# ledger prices against is tracked, is a subject, and no `*.sh` glob sees it.
# The on-disk glob reaches a script that is not tracked yet, which the index
# read cannot see at all, and that is the discovery-stage fail-open
# `.claude/rules/guards-must-fail.md` names FIRST: a new guard and its sibling
# suite are both untracked at the moment their author runs the guard to see
# whether the tree is clean, so a tracked-only subject set reports clean over
# exactly the files most likely to red, and that output is indistinguishable
# from a real clean pass.
#
# The union's cost, stated rather than left to be discovered: an untracked
# `.sh` dropped into this directory as scratch reds until it is either
# indexed on the page or moved out. That is the fail-closed direction and it
# is the intended one -- a script living here is a script the index owes a
# row -- but it is a real cost on a dirty working tree and it is not a bug.
#
# THE ROOT ONLY, and the non-descending sources are the point rather than an
# oversight. The subdirectories hold Node helpers, one sourced shell library,
# and the bats suites; the page describes them as directories and does not
# index their contents, so a descending walk would demand a row for each of
# them and red on a tree that is correct.
#
# The page's `## The index` section presents itself as the inventory of what
# lives in this directory, and every reader treats it as complete: the
# directory itself says nothing about what any file is, so the page is the
# only answer there is. It is hand-kept, and a hand-kept list is itself the
# arming stage `.claude/rules/guards-must-fail.md` warns about. It goes stale
# the moment a script lands without a matching row, silently, and the
# staleness surfaces only when someone audits the page against the directory
# by hand. This check is what makes the next omission red on the pull request
# that adds the script instead of on an audit round some months later.
#
# ONE DIRECTION, deliberately. This asks only whether every root file in the
# subject set is mentioned; it does not ask whether every file the page names
# still exists. The reverse question needs a parse of the page rather than a
# membership test against it, because the page legitimately names files that
# are not subjects -- the Node helpers under the subdirectories, the hooks and
# CI jobs in its Invoker column, and the sibling pages it points at -- so a
# naive reverse sweep would report each of those as a stale row. A deleted
# script left on the page is real drift and is not covered here; it is worth
# its own check when it happens, written against a parse that can tell an
# inventory row from a mention.
#
# MENTION, not row shape. A file counts as inventoried when its basename
# appears anywhere in the page, which is weaker than "has a row in the shape
# the other rows use" and is chosen for having no false-positive class at all:
# a script named in the section prose, or under a path prefix, is genuinely
# reachable by a reader searching the page. The omission this exists to catch
# is total absence, which is what a whole-page search is exactly the right
# instrument for. A check that also judged row shape would red on prose it has
# no business grading.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- git absent, the index read failing, the scripts directory
#                missing, or the two sources together yielding no file at all,
#                each exits 2, never 0
#   arming    -- a missing or empty inventory page exits 2
#   match     -- the membership test is a fixed-string search for the
#                basename, so it neither depends on the row's surrounding
#                markup nor admits a regex metacharacter in a filename
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

readonly PROG="lint-scripts-wiki-inventory"

# The subject listing is staged through this file (see the discovery block in
# main). It is script-scoped rather than a local in main because the EXIT arm
# that unlinks it runs after main has returned on the ordinary path, with the
# frame already popped and a local out of reach by then, so a local would
# leave the file behind on every clean run.
LIST_FILE=''

# The subjects, each named once: the directory the subject set is read from,
# and the page it is compared against.
readonly SCRIPTS_DIR=".gaia/scripts"
readonly INVENTORY="wiki/concepts/GAIA Scripts.md"

# tracked_root_files <repo_root>
#
# Print every git-tracked file at the root of .gaia/scripts/ as its basename,
# one per line. Prints nothing, and fails, when the index cannot be read.
#
# `-z` is not optional here and is not decoration: a listing without it hands
# back a C-quoted path for any name carrying a byte git considers unusual, and
# the basename recovered from that quoted form is not the name on disk. The
# NUL-delimited read below is the other half of the same decision.
#
# The depth filter is what keeps this the ROOT set. The pathspec reaches every
# tracked file below the directory, subdirectories included, so the subjects
# are selected by counting separators rather than by trusting the pathspec to
# stop at one level.
tracked_root_files() {
  local root="$1" path rest
  git -C "$root" -c core.quotepath=false ls-files -z -- "$SCRIPTS_DIR" |
    while IFS= read -r -d '' path; do
      rest="${path#"$SCRIPTS_DIR"/}"
      case "$rest" in
        */*) continue ;;
      esac
      printf '%s\n' "$rest"
    done
}

# disk_root_scripts <repo_root>
#
# Print every `.sh` at the root of .gaia/scripts/ as its basename, one per
# line. Prints nothing when the directory holds no `.sh`.
#
# This is the second of the two sources the subject set unions, and the one
# that closes the untracked gap the header describes. It is scoped to `.sh`
# rather than to every directory entry so an editor swap file, a downloaded
# artifact, or a platform's own metadata file does not become a subject the
# page owes a row: those are not scripts and nobody would index them, whereas
# an untracked `.sh` here is a script somebody is in the middle of adding.
disk_root_scripts() {
  local root="$1" f
  # Through SCRIPTS_DIR, not a second literal spelling of the same path. The
  # arming arm in main tests that directory and this enumerates it, so a
  # literal here would let the two name different directories: the check would
  # arm on one and read the other, and report clean over a tree it never
  # listed.
  for f in "$root/$SCRIPTS_DIR/"*.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}

main() {
  local root
  if [ "$#" -gt 1 ]; then
    printf '%s: too many arguments\n' "$PROG" >&2
    printf 'usage: bash .gaia/scripts/%s.sh [<repo_root>]\n' "$PROG" >&2
    return 2
  fi
  if [ "$#" -eq 1 ]; then
    root="$1"
    if [ ! -d "$root" ]; then
      printf '%s: not a directory: %s\n' "$PROG" "$root" >&2
      return 2
    fi
  else
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=''
    if [ -z "$root" ]; then
      printf '%s: not inside a git repository and no <repo_root> given\n' "$PROG" >&2
      return 2
    fi
  fi

  if ! command -v git >/dev/null 2>&1; then
    printf '%s: git is required to read the tracked set and is not on PATH\n' "$PROG" >&2
    return 2
  fi

  # Arming. Both page conditions exit 2 rather than 1, and they are separated
  # because the repairs differ: an absent page is a moved or deleted file, an
  # empty one is a truncated write. Either would otherwise report every root
  # file as uninventoried, which reads as a directory's worth of findings and
  # is really one broken subject.
  if [ ! -f "$root/$INVENTORY" ]; then
    printf '%s: inventory page not found: %s\n' "$PROG" "$INVENTORY" >&2
    return 2
  fi
  if [ ! -s "$root/$INVENTORY" ]; then
    printf '%s: inventory page is empty: %s\n' "$PROG" "$INVENTORY" >&2
    return 2
  fi
  # The directory both sources read has to be armed too. An absent one yields
  # no name from either, which is silently the same as a tree whose scripts are
  # all indexed, so without this arm the check would quietly report the page
  # complete having compared nothing.
  if [ ! -d "$root/$SCRIPTS_DIR" ]; then
    printf '%s: scripts directory not found: %s\n' "$PROG" "$SCRIPTS_DIR" >&2
    return 2
  fi

  # Discovery, staged through a file rather than a variable so a failing index
  # read stays distinguishable from a directory that tracks nothing: a git
  # failure and an empty tree are different conditions owed different
  # messages, and a pipeline or a process substitution would merge them into
  # one unreadable answer.
  LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX")" || {
    printf '%s: could not create a temporary file for the subject listing\n' "$PROG" >&2
    return 2
  }
  # Three arms, not one shared arm. Bash resumes at the point of interruption
  # once a trapped signal handler returns, so a single `EXIT INT TERM` arm that
  # only unlinks the file leaves Ctrl-C removing the temp file and the check
  # running on to print its verdict as if uninterrupted. The signal arms exit,
  # and the EXIT arm they fall into owns the removal.
  trap 'rm -f "$LIST_FILE"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # The index read is asked its own question first, and asked where its status
  # is still readable. Folded into the union below it would sit upstream of a
  # `sort` under `pipefail`, where a repository this check cannot read at all
  # yields an empty set that the arm below would describe as a directory with
  # nothing in it -- a false statement about a tree whose index simply never
  # opened.
  local tracked
  if ! tracked="$(tracked_root_files "$root")"; then
    printf '%s: could not read the git index for %s under %s\n' "$PROG" "$SCRIPTS_DIR" "$root" >&2
    printf 'The tracked listing is one of the two sources the subject set unions, so a\n' >&2
    printf 'failure here would leave the comparison running against the on-disk half\n' >&2
    printf 'alone. It refuses rather than compare a short set against the page.\n' >&2
    return 2
  fi

  { printf '%s' "$tracked"; printf '\n'; disk_root_scripts "$root"; } |
    grep -v '^$' | LC_ALL=C sort -u >"$LIST_FILE"

  # An empty set is never a clean tree here: this repository both tracks files
  # in that directory and carries scripts there on disk, and a discovery that
  # finds neither would report the inventory complete having compared nothing.
  #
  # TWO conditions reach this branch, and the message names both rather than
  # the one that prompted it, per .claude/rules/partial-cause-reporting.md: a
  # directory with no tracked file at its root, and one holding no `.sh`
  # there. They are not distinguished because the set is a union, so an empty
  # union means BOTH sources came back empty and the operator's next step is
  # the same either way: find out why the directory has nothing in it. The
  # arms above have already ruled out the causes whose repairs do differ -- an
  # unreadable index, a missing git, an absent directory -- so none of them can
  # be what the operator is reading this message about.
  if [ ! -s "$LIST_FILE" ]; then
    printf '%s: discovery found no root file, from either source.\n' "$PROG" >&2
    printf 'git tracks nothing at the root of %s, AND that directory holds no .sh\n' "$SCRIPTS_DIR" >&2
    printf 'there. git is on PATH, the index read succeeded, and the directory exists,\n' >&2
    printf 'so this is an empty directory rather than a path or a listing this check\n' >&2
    printf 'failed to read.\n' >&2
    return 2
  fi

  local name findings=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qF -- "$name" "$root/$INVENTORY" && continue
    if [ "$findings" -eq 0 ]; then
      printf '%s: root files of %s that %s never mentions:\n' "$PROG" "$SCRIPTS_DIR" "$INVENTORY" >&2
    fi
    printf '  %s\n' "$name" >&2
    findings=$((findings + 1))
  done <"$LIST_FILE"

  if [ "$findings" -gt 0 ]; then
    printf '\n%s: %d root file(s) above are absent from the index.\n' \
      "$PROG" "$findings" >&2
    printf 'Add one row per file to the family table in %s, in the shape the\n' "$INVENTORY" >&2
    printf 'existing rows use, naming what runs it and what it is. A row for a file\n' >&2
    printf 'that does not ship ends in a single-line gaia:maintainer-only marker pair,\n' >&2
    printf 'so the scrub drops it from the adopter copy of the page.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
