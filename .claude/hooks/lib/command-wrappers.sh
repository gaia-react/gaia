#!/usr/bin/env bash
# Shared command-WRAPPER stripping for the commit guards.
#
# Sourced by .claude/hooks/block-no-verify.sh,
# .claude/hooks/block-main-destructive-git.sh and
# .claude/hooks/red-verify-commit-check.sh. Does no work at source time.
#
#   gaia_strip_command_wrappers <command-word-text>
#
# Prints the text with any leading command WRAPPERS removed, so the word each
# guard tests against `^git` is the program actually being run rather than a
# wrapper standing in front of it.
#
# WHY THIS IS NOT ANOTHER ALTERNATION IN THE PREFIX STRIP. Each guard already
# strips env-var assignment prefixes, shell reserved words and leading
# redirections with one sed, and a wrapper looks like one more word to add to
# that list. It is not: a prefix carries no arguments of its own, and every
# wrapper here does. A blind strip of the word alone reads `env -i git commit`
# as an option-carrying git invocation and `timeout 5 git commit` as none at
# all, because in the first the next word is the wrapper's flag and in the
# second it is the wrapper's operand. Reading past a wrapper needs that
# wrapper's own grammar, which is what the table below states.
#
# WHAT THE TABLE STATES, PER WRAPPER. Three properties, and they are the three
# a reader needs to find the word after the wrapper:
#
#   - which of its options take a SEPARATED value, so the value is consumed
#     with its option instead of being read as the command word. The
#     `=`-joined and attached spellings (`--unset=FOO`, `-I{}`, `-k5`) need no
#     entry: they are one word, so the command word still lands next.
#   - how many OPERANDS of its own it consumes before the command word.
#     `timeout` is the only one here that takes any, its DURATION.
#   - whether it accepts `NAME=value` ASSIGNMENTS between its options and the
#     command word. `env` is the only one that does, and that is its whole
#     purpose; the others would run an assignment as a program.
#
# DIRECTION OF ERROR. Stripping a word that is not really a wrapper makes a
# guard read a command word it would otherwise have skipped, so the guard arms
# on MORE commands, never fewer. That is the direction these guards must fail
# in, and it is why `command -v git` is stripped like any other `command`
# invocation even though it only prints a path: the over-read costs a deny on
# `command -v git commit`, a command nobody runs, and closing it would need the
# shell's own evaluation.
#
# HONEST LIMITS, all of them the under-strip direction, which leaves the gap
# exactly where it is today rather than opening a new one:
#
#   - a wrapper option whose separated value carries whitespace inside quotes
#     (`env -S "a b" git commit`). The scan splits on whitespace, so it
#     consumes `"a` and reads `b"` as the command word, finds no `git`, and
#     skips the segment.
#   - a value-taking wrapper option absent from its row, whose value is a bare
#     word. The value reaches the command-word slot, exactly as it does in
#     `parse_git_globals` for git's own globals.
#   - a wrapper, an option or an operand produced by an expansion (`$VAR`,
#     `$(...)`, a backtick, `~`), which is ordinary word text to a scan that
#     does not expand.
#   - a wrapper outside the table. The set below is the one the sourcing
#     guards' honest-limit comments have always named. Adding a row is how it
#     grows.
#
# ADDING A ROW: state all three properties. An option that takes a separated
# value and is left out of the row hands its own value to the command-word
# slot, which is a silent skip rather than a visible misread, so check the
# wrapper's own manual rather than copying a neighbouring row.

# Strip one leading wrapper from <text>. Prints the remainder and returns 0
# when the first word is a wrapper and a word survives it; returns 1
# otherwise, which is what ends the caller's loop.
_gaia_strip_one_wrapper() {
  local _w_valued _w_operands _w_assign _t _i _n
  local _w_first _rest
  local -a _w=()
  # `read -r -a` and not an unquoted array assignment: the latter would run
  # pathname expansion over the segment, so a `*` or `?` anywhere in it would
  # glob against the hook's working directory and change the word count this
  # parser counts on. A segment carries no newline (the walk cut them), so one
  # read takes all of it.
  read -r -a _w <<<"${1:-}" || true
  _n=${#_w[@]}
  [ "$_n" -gt 1 ] || return 1
  _w_first="${_w[0]}"
  case "$_w_first" in
    # GAIA_WRAPPER_TABLE_BEGIN
    env) _w_valued=' -u -C -S '; _w_operands=0; _w_assign=1 ;;
    command) _w_valued=' '; _w_operands=0; _w_assign=0 ;;
    exec) _w_valued=' -a '; _w_operands=0; _w_assign=0 ;;
    nohup) _w_valued=' '; _w_operands=0; _w_assign=0 ;;
    timeout) _w_valued=' -k -s '; _w_operands=1; _w_assign=0 ;;
    xargs) _w_valued=' -a -E -I -L -P -d -n -s '; _w_operands=0; _w_assign=0 ;;
    # GAIA_WRAPPER_TABLE_END
    *) return 1 ;;
  esac
  _i=1
  while [ "$_i" -lt "$_n" ]; do
    _t="${_w[$_i]}"
    case "$_t" in
      --) _i=$((_i + 1)); break ;;
      -?*)
        case "$_w_valued" in
          *" $_t "*) _i=$((_i + 2)); continue ;;
        esac
        _i=$((_i + 1)); continue ;;
      *) break ;;
    esac
  done
  while [ "$_w_operands" -gt 0 ] && [ "$_i" -lt "$_n" ]; do
    _i=$((_i + 1))
    _w_operands=$((_w_operands - 1))
  done
  if [ "$_w_assign" -eq 1 ]; then
    while [ "$_i" -lt "$_n" ]; do
      case "${_w[$_i]}" in
        [A-Za-z_]*=* | [A-Za-z_]*+=*) _i=$((_i + 1)) ;;
        *) break ;;
      esac
    done
  fi
  [ "$_i" -lt "$_n" ] || return 1
  _rest="${_w[*]:$_i}"
  printf '%s' "$_rest"
}

# gaia_strip_command_wrappers <command-word-text>: print the text with every
# leading wrapper removed. Nesting is real (`nohup timeout 5 env git commit`),
# so this loops; the bound is a backstop, not a grammar, exactly as the
# substitution collapse's pass bound is.
gaia_strip_command_wrappers() {
  local _text="${1:-}" _next _pass=0
  while [ "$_pass" -lt 8 ]; do
    _next=$(_gaia_strip_one_wrapper "$_text") || break
    [ -n "$_next" ] || break
    _text="$_next"
    _pass=$((_pass + 1))
  done
  printf '%s' "$_text"
}
