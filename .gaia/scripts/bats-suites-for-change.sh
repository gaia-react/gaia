#!/usr/bin/env bash
#
# Prints every bats suite that references a file the change edits or deletes,
# one repo-relative path per line, sorted and de-duplicated: the suite set the
# pre-merge "verify your own work" step (no argument, the whole branch) and
# each audit round's verification (`HEAD`, that round's staged delta) run
# through bats5.sh.
#
# A suite is selected when it names a changed file's basename as a fixed
# string, or when it is itself a changed suite that still exists. Selection by
# basename over-selects on a common name (`index.ts`) and never drops a suite,
# which is the safe direction for a verification set.
#
# Changed paths are read NUL-delimited. The hand-rolled spelling,
# `for f in $(git diff --name-only ...)`, word-splits a path holding a space
# (`PR Merge Workflow.md` becomes `PR`, `Merge`, `Workflow.md`), and those
# fragments match nearly every suite.
#
# Rename detection is off, so a renamed file lists both its old and new path.
# With it on, only the new path prints and a suite still naming the old
# basename, the one most likely to break, would go unselected.
#
# Usage:
#   bash .gaia/scripts/bats-suites-for-change.sh [--dir <repo>] [<git-diff-arg>...]
#
# With no diff argument the change is everything since the merge base with the
# remote default branch: committed, uncommitted, and untracked. Any arguments
# given are passed to `git diff --name-only` verbatim (`<base> HEAD`,
# `<base>...HEAD`), and untracked files are then not added.
#
# Exit: 0 suites printed (possibly none), 2 usage error, 3 the change could not
# be read. On exit 3 nothing is printed, so an empty stdout on exit 0 always
# means "no suite references the change", never "the diff failed".

set -uo pipefail

directory="."
diff_arguments=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || { printf 'bats-suites-for-change: --dir needs a value\n' >&2; exit 2; }
      directory="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --)
      shift
      diff_arguments+=("$@")
      break
      ;;
    --*)
      printf 'bats-suites-for-change: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      diff_arguments+=("$1")
      shift
      ;;
  esac
done

die_input() {
  printf 'bats-suites-for-change: %s\n' "$1" >&2
  exit 3
}

repository_root="$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null)" \
  || die_input "not a git checkout: $directory"

changed_list="$(mktemp)" || die_input "cannot create a temporary file"
suite_list="$(mktemp)" || { rm -f "$changed_list"; die_input "cannot create a temporary file"; }
trap 'rm -f "$changed_list" "$suite_list"' EXIT

if [ "${#diff_arguments[@]}" -gt 0 ]; then
  git -C "$repository_root" diff --name-only --no-renames -z ${diff_arguments[@]+"${diff_arguments[@]}"} -- > "$changed_list" \
    || die_input "git diff ${diff_arguments[*]} failed"
else
  default_branch="$(git -C "$repository_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  default_branch="${default_branch#refs/remotes/origin/}"
  [ -n "$default_branch" ] || default_branch="main"
  merge_base="$(git -C "$repository_root" merge-base "refs/remotes/origin/$default_branch" HEAD 2>/dev/null)" \
    || die_input "no merge base with refs/remotes/origin/$default_branch; pass a range, e.g. <base> HEAD"
  git -C "$repository_root" diff --name-only --no-renames -z "$merge_base" -- > "$changed_list" \
    || die_input "git diff $merge_base failed"
  git -C "$repository_root" ls-files --others --exclude-standard -z >> "$changed_list" \
    || die_input "listing untracked files failed"
fi

while IFS= read -r -d '' changed_path; do
  case "$changed_path" in
    *.bats)
      [ -f "$repository_root/$changed_path" ] && printf '%s\n' "$changed_path" >> "$suite_list"
      ;;
  esac
  # git grep exits 1 on no match; only a status above 1 is a failure.
  git -C "$repository_root" grep -l -F -e "${changed_path##*/}" -- '*.bats' >> "$suite_list" || {
    grep_status=$?
    [ "$grep_status" -eq 1 ] || die_input "git grep for $changed_path failed"
  }
done < "$changed_list"

sort -u "$suite_list"
