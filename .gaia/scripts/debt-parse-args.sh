#!/usr/bin/env bash
#
# The /gaia-debt argument parser: turns the raw argument string into exactly one
# stdout line naming what to run, so the grammar is executable instead of prose
# the model interprets (.claude/skills/gaia/references/debt.md, "Argument
# parsing"). A first word the grammar does not know stops the run; it never
# falls through to draining the top of the backlog.
#
# The argument string arrives on STDIN, never argv, so the caller can hand it
# over through a quoted heredoc and nothing in it is expanded by a shell. The
# text is never evaluated: no eval, no command substitution over it, and every
# expansion of it is quoted, so `$(id)` and backticks are ordinary characters.
# The tokens this accepts flow on into `gh` and branch-name arguments, which is
# why the number grammar is pinned here, before anything reaches them.
#
# Grammar. Split on whitespace and commas, drop empty fields, then:
#   (nothing, or only whitespace)  ->  top
#   fix                            ->  top
#   list                           ->  list        (any further token is refused)
#   why <number>                   ->  why <N>     (exactly one number)
#   [fix] <number> [<number> ...]  ->  numbers <N1> [<N2> ...]
# A number token is an optional single `#` then a positive integer with no
# leading zero. Duplicates collapse, first occurrence wins. Numbers are compared
# as strings and never put through shell arithmetic, which overflows on a long
# digit run. Subcommand words are exact lowercase. The offending token of a
# refusal is the first one, left to right, that the grammar cannot place.
# Non-whitespace input that yields no token (only commas) is refused as `,`.
#
# Isolation keyword. An operator may name the isolation mode in the same
# argument string ("12 34 worktree", "do it on a branch"). When any token
# contains `worktree` or `branch`, in any case, the string is read as phrasing:
# every token holding a keyword, and every word token with no digit that is not
# a subcommand word, is skipped as filler, and the grammar above runs on what is
# left. A token with a digit is never filler, so a mistyped number (`12x`) is
# still refused rather than dropped. When exactly one of the two keywords
# appears, a `top` or `numbers` result gains a second stdout line,
# `isolation worktree` or `isolation branch`; when both appear the mode is
# ambiguous and no second line is printed. `list` and `why` never isolate, so
# they never print it. With no keyword in the string, nothing above changes.
#
# Usage:
#   bash .gaia/scripts/debt-parse-args.sh <<'GAIA_DEBT_ARGUMENTS'
#   /gaia-debt arguments, verbatim
#   GAIA_DEBT_ARGUMENTS
#
# Stdout is one line: top | list | why <N> | numbers <N1> [<N2> ...] (numbers
# without the `#`), or `unrecognized <token>` on a refusal, plus the optional
# `isolation worktree|branch` second line described above.
#
# Exit: 0 parsed, 2 refused (stderr carries the token and the accepted forms),
# 3 misused (an argv argument was given, or stdin could not be read; stdout is
# empty and stderr is one `debt-parse-args:` line).
#
# Pure bash, parses and runs under bash 3.2: case patterns and one array filled
# by `read -a`, no associative arrays, no `mapfile`, no case-folding expansions.

set -o pipefail

if [ "$#" -gt 0 ]; then
  echo "debt-parse-args: takes no arguments; pass the argument string on stdin" >&2
  exit 3
fi

if ! input=$(cat 2>/dev/null); then
  echo "debt-parse-args: could not read stdin" >&2
  exit 3
fi

refuse() {
  printf 'unrecognized %s\n' "$1"
  {
    printf 'unrecognized argument: %s\n' "$1"
    echo "accepted forms: /gaia-debt | /gaia-debt fix | /gaia-debt list | /gaia-debt why <issue-number> | /gaia-debt [fix] <issue-number> [<issue-number> ...] (numbers may carry a leading # and be separated by spaces or commas)"
  } >&2
  exit 2
}

# is_number_token <token>: sets number_value (the token without its `#`) and
# returns 0 only for `#?[1-9][0-9]*`.
is_number_token() {
  case "$1" in
    \#*) number_value="${1#\#}" ;;
    *) number_value="$1" ;;
  esac
  case "$number_value" in
    "" | 0* | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# The isolation keyword pre-pass runs over the whole string, so filler that
# comes before the keyword ("please use a worktree") is skipped too. Bracket
# patterns match case-insensitively without a bash 4 case-folding expansion.
worktree_pattern='*[wW][oO][rR][kK][tT][rR][eE][eE]*'
branch_pattern='*[bB][rR][aA][nN][cC][hH]*'
saw_worktree=0
saw_branch=0
# shellcheck disable=SC2254
case "$input" in $worktree_pattern) saw_worktree=1 ;; esac
# shellcheck disable=SC2254
case "$input" in $branch_pattern) saw_branch=1 ;; esac
phrasing=$((saw_worktree + saw_branch))
isolation_mode=""
if [ "$saw_worktree" -eq 1 ] && [ "$saw_branch" -eq 0 ]; then
  isolation_mode="worktree"
elif [ "$saw_branch" -eq 1 ] && [ "$saw_worktree" -eq 0 ]; then
  isolation_mode="branch"
fi

# is_filler <token>: under phrasing, true for a keyword token and for a word
# with no digit that is not a subcommand word.
is_filler() {
  [ "$phrasing" -gt 0 ] || return 1
  # shellcheck disable=SC2254
  case "$1" in
    $worktree_pattern | $branch_pattern) return 0 ;;
    fix | list | why | *[0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# State machine over the token stream, so the tokens never need a second pass:
#   start     nothing seen yet
#   fixed     a leading `fix`; a number must follow
#   listed    `list`; nothing may follow
#   why_bare  `why`; one number must follow
#   why_done  `why <N>`; nothing may follow
#   numbers   one or more numbers so far
state="start"
token_count=0
numbers_seen=" "
numbers_out=""
why_number=""

consume_token() {
  local token="$1"
  token_count=$((token_count + 1))
  case "$state" in
    start)
      case "$token" in
        fix) state="fixed" ;;
        list) state="listed" ;;
        why) state="why_bare" ;;
        *)
          is_number_token "$token" || refuse "$token"
          state="numbers"
          add_number "$number_value"
          ;;
      esac
      ;;
    fixed | numbers)
      is_number_token "$token" || refuse "$token"
      state="numbers"
      add_number "$number_value"
      ;;
    why_bare)
      is_number_token "$token" || refuse "$token"
      state="why_done"
      why_number="$number_value"
      ;;
    *) refuse "$token" ;;
  esac
}

add_number() {
  case "$numbers_seen" in
    *" $1 "*) ;;
    *)
      numbers_seen="$numbers_seen$1 "
      numbers_out="$numbers_out $1"
      ;;
  esac
}

while IFS= read -r line || [ -n "$line" ]; do
  fields=()
  IFS=$' \t\r,' read -r -a fields <<<"$line"
  field_index=0
  while [ "$field_index" -lt "${#fields[@]}" ]; do
    if [ -n "${fields[$field_index]}" ] && ! is_filler "${fields[$field_index]}"; then
      consume_token "${fields[$field_index]}"
    fi
    field_index=$((field_index + 1))
  done
done <<<"$input"

# print_isolation: the optional second line, for the two results that isolate.
print_isolation() {
  if [ -n "$isolation_mode" ]; then
    echo "isolation $isolation_mode"
  fi
}

if [ "$token_count" -eq 0 ]; then
  case "$input" in
    *[![:space:]]*)
      [ "$phrasing" -gt 0 ] || refuse ","
      ;;
  esac
  echo "top"
  print_isolation
  exit 0
fi

case "$state" in
  fixed)
    echo "top"
    print_isolation
    ;;
  listed) echo "list" ;;
  why_bare) refuse "why" ;;
  why_done) echo "why $why_number" ;;
  numbers)
    echo "numbers$numbers_out"
    print_isolation
    ;;
esac
