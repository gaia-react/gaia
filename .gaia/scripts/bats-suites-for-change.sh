#!/usr/bin/env bash
#
# Prints every bats suite that references a file the change edits or deletes,
# one repo-relative path per line, sorted and de-duplicated: the change-selected
# part of the suite set the verification runner (.gaia/tests/verify-harness.sh)
# runs through bats5.sh, in the pre-merge "verify your own work" step and in each
# audit round. In branch mode the runner subtracts this output from the
# whole-tree-marked suites and runs it in full; round mode runs it alone.
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
#     (`error-stack/tests/index.stories.tsx`). No suite sits beside it to name it
#     through a directory variable. A source under a tree holding suites keeps
#     the basename: a suite there imports it as `"$storage_directory/index.ts"`.
#   - Any other file whose basename occurs inside a tracked directory path
#     matches on its shortest trailing path no tracked directory path contains
#     (`.gaia/cli/gaia` as `cli/gaia`). The bare name is in every suite that
#     names a path through that directory (`.gaia/`), so it selects nearly all.
#
# The exceptions drop a suite that reaches such a file only by a spelling the
# match text is not part of (`cd "$REPO_ROOT" && cat package.json`,
# `"$(cd "$SCRIPTS/../cli" && pwd)/gaia"`). A suite reaching a file by a
# spelling the match text is not part of is missed here; the push-to-main full
# run backstops it.
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
directory_list="$(mktemp)" || { rm -f "$changed_list" "$suite_list" "$tracked_list" "$suite_tree_list"; die_input "cannot create a temporary file"; }
pattern_list="$(mktemp)" || { rm -f "$changed_list" "$suite_list" "$tracked_list" "$suite_tree_list" "$directory_list"; die_input "cannot create a temporary file"; }
trap 'rm -f "$changed_list" "$suite_list" "$tracked_list" "$suite_tree_list" "$directory_list" "$pattern_list"' EXIT

# -z keeps a non-ASCII path unquoted, so it compares equal to the diff's path.
git -C "$repository_root" ls-files -z | tr '\0' '\n' > "$tracked_list" \
  || die_input "listing tracked files failed"
awk -F/ 'NF > 1 && /\.bats$/ { print $1 }' "$tracked_list" | sort -u > "$suite_tree_list"
awk -F/ 'NF > 1 { sub(/\/[^\/]*$/, ""); print }' "$tracked_list" | sort -u > "$directory_list"

# Reads changed paths, one per line on stdin, and prints each one's match text
# on its own line in the same order: one awk process for the whole change,
# where calling awk per path and per lengthening step cost seconds on a long
# branch.
match_texts_for() {
  awk -v tracked_file="$tracked_list" -v directory_file="$directory_list" -v suite_tree_file="$suite_tree_list" '
    function last_segment(path,   segments, segment_count) {
      segment_count = split(path, segments, "/")
      return segments[segment_count]
    }
    function parent_of(path) {
      if (match(path, /\/[^\/]*$/)) return substr(path, 1, RSTART - 1)
      return path
    }
    function first_segment(path,   slash) {
      slash = index(path, "/")
      return slash ? substr(path, 1, slash - 1) : path
    }
    function count_other_paths_ending_with(changed, suffix,   position, count, tracked_path) {
      suffix = "/" suffix
      count = 0
      for (position = 1; position <= tracked_count; position++) {
        tracked_path = tracked[position]
        if (tracked_path != changed && substr("/" tracked_path, length(tracked_path) + 2 - length(suffix)) == suffix) count++
      }
      return count
    }
    function directory_path_contains(text,   position) {
      for (position = 1; position <= directory_count; position++) {
        if (index(directories[position], text)) return 1
      }
      return 0
    }
    function match_text_for(changed,   base_name, match_text, parent_path) {
      base_name = last_segment(changed)
      if (changed == base_name) return "/" base_name
      match_text = base_name
      parent_path = parent_of(changed)
      if (base_name !~ /\.(ts|tsx|js|jsx|mjs|cjs)$/) {
        while (directory_path_contains(match_text)) {
          match_text = last_segment(parent_path) "/" match_text
          if (index(parent_path, "/") == 0) break
          parent_path = parent_of(parent_path)
        }
        return match_text
      }
      if ((first_segment(changed) in suite_trees) || count_other_paths_ending_with(changed, base_name) == 0) return base_name
      while (1) {
        match_text = last_segment(parent_path) "/" match_text
        if (index(parent_path, "/") == 0) break
        parent_path = parent_of(parent_path)
        if (count_other_paths_ending_with(changed, match_text) == 0) break
      }
      return match_text
    }
    FILENAME == tracked_file { tracked[++tracked_count] = $0; next }
    FILENAME == directory_file { directories[++directory_count] = $0; next }
    FILENAME == suite_tree_file { suite_trees[$0] = 1; next }
    { print match_text_for($0) }
  ' "$tracked_list" "$directory_list" "$suite_tree_list" -
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
done < "$changed_list"

tr '\0' '\n' < "$changed_list" | match_texts_for > "$pattern_list" \
  || die_input "computing the match texts failed"
# One git grep for every match text at once. An empty change never reaches
# it: handed an empty pattern file, git grep reads the `*.bats` pathspec as its
# pattern instead and lists every tracked file of any kind holding that text.
if [ -s "$pattern_list" ]; then
  # git grep exits 1 on no match; only a status above 1 is a failure.
  git -C "$repository_root" grep -l -F -f "$pattern_list" -- '*.bats' >> "$suite_list" || {
    grep_status=$?
    [ "$grep_status" -eq 1 ] || die_input "git grep over the changed paths failed"
  }
fi

sort -u "$suite_list"
