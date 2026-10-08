#!/usr/bin/env bash
# whole-tree-mark-guard.sh: flag a bats suite that enumerates the tracked tree
# without carrying the whole-tree mark.
#
# A suite is whole-tree when its outcome depends on tracked files it does not
# name. The change selector (.gaia/scripts/bats-suites-for-change.sh) picks a
# suite only when the suite names a changed file, so a whole-tree suite is
# never picked by it. The mark, the bats-native file tag line
#   # bats file_tags=whole-tree
# placed before the first test, makes the verification runner always run it.
#
# Recognized idioms (the ONLY ones this guard recognizes). First the suite's
# real-root variables are collected: a variable assigned from an expression
# containing $BATS_TEST_DIRNAME or $BATS_TEST_FILENAME, plus any variable whose
# assignment expression contains one already collected, repeated until no new
# variable joins. Then a line, outside comments, is flagged when a real-root
# variable is the operand of:
#   1. git -C <root> ... ls-files   or   git -C <root> ... grep
#   2. find <root>   or   find <root>/<dir>
#   3. a glob loop: for <name> in <root>/<path>*...
# A root that is a $BATS_TEST_TMPDIR-based or other fixture path is never a
# real root, so a fixture repository is never flagged. Neither is a root
# assigned from a path with a `fixtures` segment, nor a find or glob-loop
# operand under one: committed fixtures are the suite's own inputs, edited
# beside it, not the tracked tree it checks.
# An ls-files call is not enumeration when it uses --error-unmatch (a
# membership test) or when every operand is a literal path that is not a
# tracked directory: it names those paths. A glob, a magic pathspec, a variable
# or a tracked directory operand is enumeration.
#
# NOT claimed: enumeration delegated to a script the suite calls (a lint
# script, a roster check) is outside this guard. Such a suite is marked by
# hand. The guard never widens its parser to chase more shapes.
#
# Maintainer-only: .gaia/tests is release-excluded wholesale.
#
# Usage:
#   bash .gaia/tests/whole-tree-mark-guard.sh [--root <repo>] [<suite>...]
# With no suite operands every tracked *.bats under the root is scanned.
# Exit: 0 no unmarked enumerating suite; 1 one or more found; 2 usage error or
# an empty discovery set (a guard over nothing is not clean).

set -u

usage() {
  echo "usage: whole-tree-mark-guard.sh [--root <repo>] [<suite>...]" >&2
}

root=""
suites=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      root="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      suites+=("$1")
      shift
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "whole-tree-mark-guard: not inside a git repository; pass --root <repo>" >&2
    exit 2
  }
fi

scan_paths=()
if [ "${#suites[@]}" -gt 0 ]; then
  scan_paths=(${suites[@]+"${suites[@]}"})
else
  while IFS= read -r -d '' tracked_suite; do
    scan_paths+=("$root/$tracked_suite")
  done < <(git -C "$root" ls-files -z '*.bats' 2>/dev/null)
fi

if [ "${#scan_paths[@]}" -eq 0 ]; then
  echo "whole-tree-mark-guard: no tracked *.bats suite found under $root; a guard over nothing is not clean" >&2
  exit 2
fi

# Prints "<idiom>\t<line>" for the first flagged line of the suite, nothing
# when the suite names no recognized idiom.
find_enumeration() {
  awk -v directory_list="$directory_list" '
    function is_comment(text) { return text ~ /^[ \t]*#/ }
    function refers(text, name) {
      return text ~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")
    }
    function names_only(rest,   tail, token_count, tokens, t, token, operand_count) {
      if (rest ~ /(^|[ \t])--error-unmatch([ \t]|$)/) { return 1 }
      tail = rest
      sub(/^.*(^|[ \t])ls-files([ \t]|$)/, "", tail)
      if (match(tail, /[|)<>;&]/)) { tail = substr(tail, 1, RSTART - 1) }
      operand_count = 0
      token_count = split(tail, tokens, /[ \t]+/)
      for (t = 1; t <= token_count; t++) {
        token = tokens[t]
        gsub(/["\047]/, "", token)
        if (token == "" || token ~ /^-/) { continue }
        if (token ~ /[$*?[]/ || token ~ /^:/ || token ~ /\/$/ || (token in is_directory)) { return 0 }
        operand_count++
      }
      return operand_count > 0
    }
    BEGIN {
      count = 0; pending = ""; pending_line = 0
      while ((getline directory < directory_list) > 0) { is_directory[directory] = 1 }
    }
    {
      raw = $0
      if (pending == "") {
        pending_line = NR
      }
      if (raw ~ /\\[ \t]*$/ && !is_comment(raw)) {
        sub(/\\[ \t]*$/, " ", raw)
        pending = pending raw
        next
      }
      logical = pending raw
      pending = ""
      count++
      text[count] = logical
      line[count] = pending_line
    }
    END {
      if (pending != "") {
        count++
        text[count] = pending
        line[count] = pending_line
      }
      roots = 0
      for (i = 1; i <= count; i++) {
        if (is_comment(text[i])) { continue }
        stmt = text[i]
        sub(/^[ \t]*/, "", stmt)
        sub(/^(local|export|readonly|declare)[ \t]+(-[A-Za-z]+[ \t]+)?/, "", stmt)
        if (stmt !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { continue }
        eq = index(stmt, "=")
        assigned_count++
        assigned_name[assigned_count] = substr(stmt, 1, eq - 1)
        assigned_value[assigned_count] = substr(stmt, eq + 1)
      }
      changed = 1
      while (changed) {
        changed = 0
        for (a = 1; a <= assigned_count; a++) {
          name = assigned_name[a]
          if (name in is_root) { continue }
          value = assigned_value[a]
          if (value ~ /\/fixtures([\/" \t]|$)/) { continue }
          join = 0
          if (index(value, "$BATS_TEST_DIRNAME") || index(value, "${BATS_TEST_DIRNAME") \
              || index(value, "$BATS_TEST_FILENAME") || index(value, "${BATS_TEST_FILENAME")) {
            join = 1
          } else {
            for (known in is_root) {
              if (refers(value, known)) { join = 1; break }
            }
          }
          if (join) { is_root[name] = 1; changed = 1 }
        }
      }
      for (i = 1; i <= count; i++) {
        if (is_comment(text[i])) { continue }
        for (name in is_root) {
          ref = "\\$\\{?" name "([^A-Za-z0-9_]|$)"
          if (text[i] !~ ref) { continue }
          gitc = "git[ \t]+(.*[ \t])?-C[ \t]+\"?" "\\$\\{?" name "([^A-Za-z0-9_]|$)"
          if (match(text[i], gitc)) {
            rest = substr(text[i], RSTART + RLENGTH)
            if (rest ~ /(^|[ \t])ls-files([ \t]|$)/ && names_only(rest)) { continue }
            if (rest ~ /(^|[ \t])(ls-files|grep)([ \t]|$)/) {
              printf "git -C <root> %s\t%d\n", (rest ~ /(^|[ \t])ls-files([ \t]|$)/ ? "ls-files" : "grep"), line[i]
              exit
            }
          }
          findpat = "(^|[^A-Za-z0-9_-])find[ \t]+\"?\\$\\{?" name "([^A-Za-z0-9_]|$)"
          fixture_find = "find[ \t]+\"?\\$\\{?" name "\\}?/([^ \t\"]*/)?fixtures([/\" \t]|$)"
          if (text[i] ~ findpat && text[i] !~ fixture_find) {
            printf "find <root>\t%d\n", line[i]
            exit
          }
          forpat = "(^|[^A-Za-z0-9_])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+[^;]*\"?\\$\\{?" name "\\}?\"?[^ \t;]*\\*"
          fixture_loop = "in[ \t]+\"?\\$\\{?" name "\\}?\"?/([^ \t;\"]*/)?fixtures/"
          if (text[i] ~ forpat && text[i] !~ fixture_loop) {
            printf "glob loop over <root>\t%d\n", line[i]
            exit
          }
        }
      }
    }
  ' "$1"
}

marked() {
  grep -qE '^# bats file_tags=([^,]*,)*whole-tree(,|$)' "$1"
}

# Every directory holding a tracked file, so a literal ls-files operand naming
# one still counts as enumeration. Empty when the root is not a repository.
directory_list="$(mktemp)" || { echo "whole-tree-mark-guard: cannot create a temporary file" >&2; exit 2; }
trap 'rm -f "$directory_list"' EXIT
git -C "$root" ls-files 2>/dev/null \
  | awk -F/ '{ path = $1; for (i = 2; i <= NF; i++) { print path; path = path "/" $i } }' \
  | sort -u >"$directory_list"

flagged=0
for suite_path in ${scan_paths[@]+"${scan_paths[@]}"}; do
  if [ ! -f "$suite_path" ]; then
    echo "whole-tree-mark-guard: not a file: $suite_path" >&2
    exit 2
  fi
  if marked "$suite_path"; then
    continue
  fi
  hit="$(find_enumeration "$suite_path")"
  [ -n "$hit" ] || continue
  idiom="${hit%%$'\t'*}"
  line_number="${hit##*$'\t'}"
  display="$suite_path"
  case "$suite_path" in
    "$root"/*) display="${suite_path#"$root"/}" ;;
  esac
  printf "%s: enumerates the tracked tree (%s, line %s) without the whole-tree mark; add the line '# bats file_tags=whole-tree' before its first test\n" \
    "$display" "$idiom" "$line_number"
  flagged=$((flagged + 1))
done

if [ "$flagged" -gt 0 ]; then
  echo "whole-tree-mark-guard: $flagged suite(s) flagged. Only the idioms in this script's header are recognized (git -C <root> listing tracked files or grep, find <root>, a glob loop over <root>); enumeration delegated to a script the suite calls is outside this guard's claim and needs the mark by hand."
  exit 1
fi

echo "whole-tree-mark-guard: no unmarked suite uses a recognized enumeration idiom (enumeration delegated to a called script is outside this guard's claim)"
exit 0
