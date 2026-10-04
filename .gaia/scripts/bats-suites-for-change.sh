#!/usr/bin/env bash
#
# Prints every bats suite that references a file the change edits or deletes,
# one repo-relative path per line, sorted and de-duplicated: the suite set the
# pre-merge "verify your own work" step (no argument, the whole branch) and
# each audit round's verification (`HEAD`, that round's staged delta) run
# through bats5.sh.
#
# A suite is selected when it contains a changed file's match text as a fixed
# string, or when it is itself a changed suite that still exists. The match
# text is the basename, because a suite names the file it tests through a
# directory variable and the bare name (`"$SCRIPTS/usage-lib.sh"`), with two
# exceptions where the bare name is mostly fixture data (a staged path, a hook
# command) and selecting on it runs suites the change cannot affect:
#
#   - A root-level file matches as `/<name>`. A suite that reads one reads it
#     through a root (`"$REPO_ROOT/CHANGELOG.md"`).
#   - A JS/TS source whose basename another tracked file shares (`index.tsx`,
#     `common.ts`), under a top-level directory holding no bats suite, matches
#     on its shortest trailing path no other tracked file ends with
#     (`form-error/tests/index.test.tsx`). No suite sits beside it to name it
#     through a directory variable. A source under a tree holding suites keeps
#     the basename: a suite there imports it as `"$storage_directory/index.ts"`.
#
# The exceptions drop a suite that reaches such a file only by an unqualified
# spelling (`cd "$REPO_ROOT" && cat package.json`). No tracked suite does
# today; one that starts to is missed here and still runs in CI.
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
      awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'
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
tracked_list="$(mktemp)" || { rm -f "$changed_list" "$suite_list"; die_input "cannot create a temporary file"; }
suite_tree_list="$(mktemp)" || { rm -f "$changed_list" "$suite_list" "$tracked_list"; die_input "cannot create a temporary file"; }
trap 'rm -f "$changed_list" "$suite_list" "$tracked_list" "$suite_tree_list"' EXIT

# -z keeps a non-ASCII path unquoted, so it compares equal to the diff's path.
git -C "$repository_root" ls-files -z | tr '\0' '\n' > "$tracked_list" \
  || die_input "listing tracked files failed"
awk -F/ 'NF > 1 && /\.bats$/ { print $1 }' "$tracked_list" | sort -u > "$suite_tree_list"

count_other_paths_ending_with() {
  awk -v changed="$1" -v suffix="/$2" '
    $0 != changed && substr("/" $0, length($0) + 2 - length(suffix)) == suffix { count++ }
    END { print count + 0 }
  ' "$tracked_list"
}

match_text_for() {
  local changed_path="$1" base_name="${1##*/}" match_text parent_path
  if [ "$changed_path" = "$base_name" ]; then
    printf '/%s' "$base_name"
    return
  fi
  case "$base_name" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) ;;
    *) printf '%s' "$base_name"; return ;;
  esac
  if grep -qxF -e "${changed_path%%/*}" "$suite_tree_list" \
    || [ "$(count_other_paths_ending_with "$changed_path" "$base_name")" -eq 0 ]; then
    printf '%s' "$base_name"
    return
  fi
  match_text="$base_name"
  parent_path="${changed_path%/*}"
  while :; do
    match_text="${parent_path##*/}/$match_text"
    [ "$parent_path" != "${parent_path%/*}" ] || break
    parent_path="${parent_path%/*}"
    [ "$(count_other_paths_ending_with "$changed_path" "$match_text")" -gt 0 ] || break
  done
  printf '%s' "$match_text"
}

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
  git -C "$repository_root" grep -l -F -e "$(match_text_for "$changed_path")" -- '*.bats' >> "$suite_list" || {
    grep_status=$?
    [ "$grep_status" -eq 1 ] || die_input "git grep for $changed_path failed"
  }
done < "$changed_list"

sort -u "$suite_list"
