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
#
#     A long option belongs here only when its argument is REQUIRED, and that
#     condition carries the whole safety of the row. GNU spells an optional
#     argument `--eof[=EOF]`, and an optional argument can only ever be
#     `=`-joined: `xargs --eof git commit` passes no value at all. Listing such
#     an option makes this parser consume `git` as its value, which hides the
#     invocation that was standing in plain sight, so a wrong entry here fails
#     OPEN where the rest of this file's errors fail closed. `xargs`'s
#     `--eof`, `--replace` and `--max-lines` are the live examples, all three
#     deliberately absent while their required-argument short forms `-E`, `-I`
#     and `-L` are present. Read the wrapper's own manual for the brackets
#     before adding a long option.
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
# HONEST LIMITS. Every one below but the last is the under-strip direction,
# which leaves the gap exactly where it is today rather than opening a new one;
# the last alters the text that survives a strip, so it is called out as its own
# kind:
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
#   - a wrapper outside the table below, which is the authority on the set.
#     Adding a row is how it grows, and a guard's own comment naming a few
#     wrappers is illustrating the class rather than enumerating it.
#   - a path-qualified spelling of a wrapper that IS in the table
#     (`/usr/bin/env git commit`). The match keys on the bare word, so the
#     strip does not fire and the segment is skipped. This is the same
#     boundary the `^git` test the callers apply already has, which leaves
#     `/usr/bin/git commit` equally unread, so it is an accepted tree-wide
#     contract rather than something this table narrowed.
#   - the one limit that is NOT under-strip: the surviving words are rejoined
#     on a single space, so a run of internal whitespace inside a quoted
#     operand collapses whenever a strip actually fires. A wrapped
#     `git -C "<path carrying two spaces>"` reaches the callers' own global
#     parse with a value naming a directory the command never did. The callers
#     that read an unresolvable `-C` fail closed on it; the one that reads it
#     as a checkout to look a ledger up in reads the wrong checkout. Keeping
#     the spacing would mean carrying byte offsets through a scan that works in
#     words, which is a larger change than this residual justifies.
#
# ADDING A ROW: state all three properties. An option that takes a separated
# value and is left out of the row hands its own value to the command-word
# slot, which is a silent skip rather than a visible misread, so check the
# wrapper's own manual rather than copying a neighbouring row.
#
# `sudo` and `doas` are deliberately absent rather than overlooked. Each takes
# options this table cannot model safely (`sudo -u <user> -g <group>` alongside
# bare flags that a wrong row would misread in either direction), and a wrong
# row for a privilege wrapper is the one place the over-read this file otherwise
# welcomes stops being cheap. Adding them is a separate decision, not a row.

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
    env) _w_valued=' -u -C -S --unset --chdir --split-string '; _w_operands=0; _w_assign=1 ;;
    command) _w_valued=' '; _w_operands=0; _w_assign=0 ;;
    exec) _w_valued=' -a '; _w_operands=0; _w_assign=0 ;;
    nice) _w_valued=' -n --adjustment '; _w_operands=0; _w_assign=0 ;;
    nohup) _w_valued=' '; _w_operands=0; _w_assign=0 ;;
    setsid) _w_valued=' '; _w_operands=0; _w_assign=0 ;;
    stdbuf) _w_valued=' -i -o -e --input --output --error '; _w_operands=0; _w_assign=0 ;;
    timeout) _w_valued=' -k -s --kill-after --signal '; _w_operands=1; _w_assign=0 ;;
    xargs) _w_valued=' -a -E -I -L -P -d -n -s --arg-file --delimiter --max-args --max-procs --max-chars '; _w_operands=0; _w_assign=0 ;;
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
        # The appending spelling `NAME+=value` needs no alternative of its own:
        # the middle `*` absorbs the `+`, and a second pattern naming it
        # explicitly would be unreachable text a later reader would preserve as
        # load-bearing.
        [A-Za-z_]*=*) _i=$((_i + 1)) ;;
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
# so this loops. The segment's own word count bounds it: a pass succeeds only
# when it drops at least one word and leaves one behind, so the text is
# strictly shorter each time and the loop cannot run longer than the words it
# was handed.
#
# Deliberately NOT the substitution collapse's fixed pass bound, whose parity
# this once claimed. The two differ on exhaustion. A collapse that gives up
# loses only the rejoined outer line, and the walk still cuts at every paren,
# so the inner command reaches it as its own segment. A wrapper strip that
# gives up hands back a word that is still a wrapper: the `^git` test fails,
# the segment never arms, and the whole-command safety net is itself gated on a
# segment having armed, so nothing behind it catches the invocation. A ceiling
# here is a bypass at one wrapper past it, in the one direction this table must
# never fail in.
gaia_strip_command_wrappers() {
  local _text="${1:-}" _next
  while :; do
    _next=$(_gaia_strip_one_wrapper "$_text") || break
    [ -n "$_next" ] || break
    _text="$_next"
  done
  printf '%s' "$_text"
}
