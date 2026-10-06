#!/usr/bin/env bash
#
# The /gaia-debt argument parser: turns the raw argument string into exactly one
# stdout line naming what to run, so the grammar is executable instead of prose
# the model interprets (.claude/skills/gaia/references/debt.md, "Argument
# parsing"). A word the grammar does not know stops the run; it never falls
# through to draining the top of the backlog.
#
# The argument string arrives on STDIN, never argv, so the caller can hand it
# over through a quoted heredoc and nothing in it is expanded by a shell. The
# text is never evaluated: no eval, no command substitution over it, and every
# expansion of it is quoted, so `$(id)` and backticks are ordinary characters.
# The tokens this accepts flow on into `gh` and branch-name arguments, which is
# why the number grammar is pinned here, before anything reaches them.
#
# Grammar. Split on whitespace and commas, drop empty fields, then:
#   [<number> ...] [[use] worktree|branch]
# No numbers prints `top`; one or more prints `numbers <N1> [<N2> ...]`. The
# isolation suffix, when present, is the last token and adds a second line,
# `isolation <mode>`. A number token is an optional single `#` then a positive
# integer with no leading zero. Duplicates collapse, first occurrence wins.
# Numbers are compared as strings and never put through shell arithmetic, which
# overflows on a long digit run. The words are exact lowercase. The offending
# token of a refusal is the first one, left to right, that the grammar cannot
# place. Non-whitespace input that yields no token (only commas) is refused
# as `,`.
#
# Usage:
#   bash .gaia/scripts/debt-parse-args.sh <<'GAIA_DEBT_ARGUMENTS'
#   /gaia-debt arguments, verbatim
#   GAIA_DEBT_ARGUMENTS
#
# Stdout is one line, top | numbers <N1> [<N2> ...] (numbers without the `#`),
# plus the optional `isolation worktree|branch` line, or `unrecognized <token>`
# on a refusal.
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
    echo "accepted form: /gaia-debt [<issue-number> ...] [[use] worktree|branch] (numbers may carry a leading # and be separated by spaces or commas)"
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

# State machine over the token stream, so the tokens never need a second pass:
#   numbers   zero or more numbers so far
#   use_bare  `use`; `worktree` or `branch` must follow
#   isolated  the isolation suffix; nothing may follow
state="numbers"
token_count=0
numbers_seen=" "
numbers_out=""
isolation_mode=""

consume_token() {
  local token="$1"
  token_count=$((token_count + 1))
  case "$state" in
    numbers)
      case "$token" in
        use) state="use_bare" ;;
        worktree | branch)
          state="isolated"
          isolation_mode="$token"
          ;;
        *)
          is_number_token "$token" || refuse "$token"
          add_number "$number_value"
          ;;
      esac
      ;;
    use_bare)
      case "$token" in
        worktree | branch)
          state="isolated"
          isolation_mode="$token"
          ;;
        *) refuse "$token" ;;
      esac
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
    if [ -n "${fields[$field_index]}" ]; then
      consume_token "${fields[$field_index]}"
    fi
    field_index=$((field_index + 1))
  done
done <<<"$input"

if [ "$token_count" -eq 0 ]; then
  case "$input" in
    *[![:space:]]*) refuse "," ;;
    *)
      echo "top"
      exit 0
      ;;
  esac
fi

[ "$state" = "use_bare" ] && refuse "use"

if [ -n "$numbers_out" ]; then
  echo "numbers$numbers_out"
else
  echo "top"
fi
if [ -n "$isolation_mode" ]; then
  echo "isolation $isolation_mode"
fi
