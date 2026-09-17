#!/usr/bin/env bats

# Parity between the two walks that read a git segment's global `-C`:
# `git_segment_c` in .claude/hooks/red-verify-commit-check.sh and
# `parse_git_globals` in .claude/hooks/block-main-destructive-git.sh.
#
# The two are kept as separate copies on purpose (gaia-react/gaia#2028), so
# nothing structural stops a repair to one from leaving the other behind. That
# already happened once: a widened value-taking option table landed in the
# destructive gate alone, and the commit gate went on reading the payload cwd
# for spellings the other gate resolved. The divergence is silent in both hooks,
# because each falls back to a tree it would have read anyway, so this suite is
# the only place it goes red.
#
# Each walk is driven as its hook defines it: every top-level function in the
# hook file is loaded into its own bash process, so the two copies of any shared
# helper cannot shadow each other, and the walk is called on one input per line.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  COMMIT_HOOK="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
  DESTRUCTIVE_HOOK="$HOME_ROOT/.claude/hooks/block-main-destructive-git.sh"
}

# walk_dirs <hook> <walk>: read segments from stdin, print the directory the
# named walk resolves for each, one per line. Exits 3 when the walk is not
# defined after loading, so a renamed function reads as a failure rather than
# as a column of empty directories.
walk_dirs() {
  local hook="$1" walk="$2" defs
  defs=$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { p = 1 } p { print } p && /^}$/ { p = 0 }' "$hook")
  DEFS="$defs" WALK="$walk" "$BASH" -c '
    eval "$DEFS"
    declare -F "$WALK" >/dev/null || exit 3
    while IFS= read -r seg; do
      if [ "$WALK" = parse_git_globals ]; then
        parse_git_globals "$seg"
        d="$git_cwd"
      else
        d=$("$WALK" "$seg")
      fi
      printf "%s\n" "$d"
    done
  '
}

# check_rows: read `<segment>|<expected directory>` rows from stdin and fail,
# naming every mismatch, unless both walks resolve each segment to its expected
# directory.
check_rows() {
  local rows segs expected commit destructive n US=$'\x1f' seg exp cg dg bad=0
  rows=$(cat)
  [ -n "$rows" ] || { echo "no rows to check"; return 1; }
  segs=$(printf '%s\n' "$rows" | cut -d'|' -f1)
  expected=$(printf '%s\n' "$rows" | cut -d'|' -f2-)
  commit=$(printf '%s\n' "$segs" | walk_dirs "$COMMIT_HOOK" git_segment_c) || { echo "git_segment_c not loadable"; return 1; }
  destructive=$(printf '%s\n' "$segs" | walk_dirs "$DESTRUCTIVE_HOOK" parse_git_globals) || { echo "parse_git_globals not loadable"; return 1; }

  # A walk yielding fewer lines than it was fed would pair every later row with
  # the wrong answer, so the line counts have to match before any row is read.
  n=$(printf '%s\n' "$segs" | wc -l)
  [ "$(printf '%s\n' "$commit" | wc -l)" -eq "$n" ] || { echo "commit walk dropped rows"; return 1; }
  [ "$(printf '%s\n' "$destructive" | wc -l)" -eq "$n" ] || { echo "destructive walk dropped rows"; return 1; }

  # A non-whitespace delimiter, so an empty directory stays its own field.
  while IFS="$US" read -r seg exp cg dg; do
    if [ "$cg" != "$exp" ] || [ "$dg" != "$exp" ]; then
      printf 'segment=[%s] expected=[%s] commit-gate=[%s] destructive-gate=[%s]\n' "$seg" "$exp" "$cg" "$dg"
      bad=1
    fi
  done < <(paste -d "$US" <(printf '%s\n' "$segs") <(printf '%s\n' "$expected") \
    <(printf '%s\n' "$commit") <(printf '%s\n' "$destructive"))
  [ "$bad" -eq 0 ]
}

# option_table <hook> <walk>: the value-taking global options the walk skips,
# read from the `-c | ...` case arm inside its own function body, since a hook
# can carry an arm of the same shape for a subcommand's options. Fails unless
# the body holds exactly one such arm.
option_table() {
  local arms
  arms=$(awk -v f="$2" '$0 == f "() {" { p = 1 } p { print } p && /^}$/ { exit }' "$1" \
    | grep -E '^[[:space:]]*-c \|.*\)')
  [ "$(printf '%s\n' "$arms" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$arms" | sed -E 's/\).*//' | tr '|' '\n' | tr -d ' ' | grep .
}

@test "both walks resolve the same global -C directory on the shared corpus" {
  run check_rows <<'EOF'
git -C /d commit -m x|/d
git -C /a -C /b commit|/b
git commit -C HEAD|
git commit -m x|
git --no-pager -C /d commit|/d
git -C "/a b" commit|/a b
git -C '/a b' commit|/a b
git -c "user.name=a b" -C /d commit|/d
git --config-env foo=BAR -C /d commit|/d
git --attr-source HEAD -C /d commit|/d
git --config-env=foo=BAR -C /d commit|/d
git --exec-path=/x -C /d commit|/d
EOF
  echo "$output"
  [ "$status" -eq 0 ]
}

# `--exec-path` has no separated-value form. Given no `=`, git prints its exec
# path and exits, so a word after it is never a value and nothing after it runs:
# it lands in the subcommand slot and no global -C beyond it is read.
@test "a bare --exec-path takes no separated value in either walk" {
  run check_rows <<'EOF'
git --exec-path /x -C /d commit|
EOF
  echo "$output"
  [ "$status" -eq 0 ]
}

# The corpus above samples the quoting grammar; the splitter has more of it
# (backslash escapes, a backslash inside single quotes, tabs and newlines) than
# a corpus row per case would be worth, so its two copies are held identical.
@test "both hooks carry the same split_git_words" {
  local a b
  a=$(awk '/^split_git_words\(\) \{$/ { p = 1 } p { print } p && /^}$/ { exit }' "$COMMIT_HOOK")
  b=$(awk '/^split_git_words\(\) \{$/ { p = 1 } p { print } p && /^}$/ { exit }' "$DESTRUCTIVE_HOOK")
  [ -n "$a" ] || { echo "commit gate defines no split_git_words"; return 1; }
  [ -n "$b" ] || { echo "destructive gate defines no split_git_words"; return 1; }
  [ "$a" = "$b" ] || { diff <(printf '%s\n' "$b") <(printf '%s\n' "$a"); return 1; }
}

@test "every value-taking global either walk skips is skipped by both" {
  local commit_opts destructive_opts opts rows opt
  commit_opts=$(option_table "$COMMIT_HOOK" git_segment_c) || { echo "commit gate option arm not found exactly once"; return 1; }
  destructive_opts=$(option_table "$DESTRUCTIVE_HOOK" parse_git_globals) || { echo "destructive gate option arm not found exactly once"; return 1; }
  opts=$(printf '%s\n%s\n' "$commit_opts" "$destructive_opts" | sort -u)
  [ -n "$opts" ] || { echo "no options derived"; return 1; }
  rows=""
  while IFS= read -r opt; do
    rows="${rows}git $opt VALUE -C /d commit|/d"$'\n'
  done <<<"$opts"
  run check_rows <<<"${rows%$'\n'}"
  echo "$output"
  [ "$status" -eq 0 ]
}
