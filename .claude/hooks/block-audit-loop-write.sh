#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash/Monitor hook: deny Claude any write,
# edit, move or delete of the audit loop gate inputs, and any execution of the
# two audit loop recorders. The gate inputs are
#   <main>/.gaia/local/protected/                       hook-only and human-only state
#     protected/audit-loop/                             state: history + allowance
#     protected/checkpoint-override.json                the per-machine override
#   <main>/.gaia/local/cache/shared/context/            per-session context readings
# The protected folder is guarded as a whole, so a file added to it later is
# protected by its placement, with no edit to this guard.
#
# WHY. The state directory holds each branch's audit history and its
# human-granted allowance. Only audit-loop-bound.sh may write history, and only
# audit-loop-grant.sh and audit-loop-ask-grant.sh may write allowance; if Claude
# could write the files through its own tools it could forge an allowance or
# reset the history. The bound hook also trusts the context readings (the
# statusline writes one per render) and the override (written only by a
# human), so Claude writing either would move the checkpoint line. A
# checkpoint is answered by the pinned AskUserQuestion or by a human typing
# `audit-grant <n>` or `audit-accept`; both reach the state through a hook,
# never a tool call.
# The recorders read a hook payload on stdin, so a forged payload piped to one
# from Bash would mint an answer: this guard denies executing them. The writer
# hooks and the statusline run as their own processes, so they are not subject
# to this guard.
#
# WHAT IS COVERED.
#   Edit / Write / MultiEdit: .tool_input.file_path is resolved physically (the
#     deepest existing ancestor through `pwd -P`, `..` collapsed, the rest
#     re-appended), so a linked worktree's `.gaia/local` symlink to the main
#     checkout resolves to the real directory. Denied when the result is
#     <main>/.gaia/local/protected or lies inside it, or lies inside
#     <main>/.gaia/local/cache/shared/context/ (<main> from
#     gaia_resolve_main_root of the payload cwd), or when the literal path
#     contains or ends in one of those spellings (catches a worktree spelling
#     whose symlink target cannot be resolved). A sibling inside the folder
#     such as `protected/checkpoint-override.json.bak` is guarded; a sibling
#     beside the folder such as `.gaia/local/protected-notes.md` is not.
#     `.claude/settings.json`, `.claude/settings.local.json` and GAIA's
#     writable opt-ins file `.gaia/local/settings.json` are not this guard's
#     remit.
#   Bash / Monitor: .tool_input.command. Cheap pre-filter first: allowed unless
#     the payload contains `audit-loop`, `local/protected` or
#     `cache/shared/context`. For the protected folder the command must name
#     `.gaia/local/protected` followed by a slash, a delimiter or the end of
#     the command: a path segment that merely starts with `protected` (a
#     sibling such as `.gaia/local/protected-notes.md`) does not arm it. The
#     command is read with its quotes grouped (single and double quotes, a
#     backslash escape), and a command that names a guarded path is
#     denied when a `>`, `>>`, `>|` or `>&` redirect TARGETS that path, or
#     when a write, move or delete verb stands outside quotes: rm, mv, cp, tee,
#     ln, install, dd, touch, truncate, chmod, rsync, unlink, shred, `sed -i`,
#     `perl -i`, or python/node/perl/ruby given -c or -e. So a printf of a
#     quoted note that names a path, redirected elsewhere, is allowed, and so
#     are read-only commands naming a path (cat, jq, ls). A `cp` or `mv` that
#     only READS a path is denied too: the verb is armed, the direction is not
#     parsed, and the over-deny is the safe side. A comment is skipped. A
#     command holding a heredoc, an unclosed quote, a command substitution or
#     backtick inside double quotes, or a redirect target built from a
#     variable, a substitution or a glob is not read that way, since its
#     quoting or its target means something else there: it is denied on any
#     redirect (a redirect to /dev/null or a descriptor duplication such as
#     2>&1 is not one) or verb anywhere. The deny message follows what the
#     command writes: the audit loop state, the override, or the folder.
#   Recorder execution: a command that EXECUTES audit-loop-grant.sh or
#     audit-loop-ask-grant.sh is denied. The command is split on `;`, `&&`,
#     `||`, `|`, `&`, `(`, `)`, backticks, `$(` and newlines; each simple
#     command is read with its quotes grouped (so a quoted recorder path under
#     a checkout path with a space stays one word) and again as blank-separated
#     words with quotes stripped, and executes a recorder when, in either
#     reading, the recorder path is its command word (leading NAME=value words
#     skipped), or the script argument of bash, sh, zsh, dash, ksh, `source`,
#     `.` or `exec` (flags skipped, `-o <option>` skipped, a lone `-n` syntax
#     check excepted). A command that merely NAMES a recorder
#     (`git add`, `git diff`, `git grep -l`, `git log`, `shellcheck`, `cat`,
#     `grep`, `bash -n`) is allowed, because staging, gate discovery and commits
#     name these paths.
#
# WHAT IS NOT COVERED (exotic spellings, outside the guarantee): a `cd` into a
# guarded directory followed by relative names; `eval`, `bash -c`, `env`,
# `timeout` and `xargs` wrappers, and a path held in a variable or built from a
# command substitution, for any guarded path and for the recorders; glob
# spellings such as `.gaia/local/prot*`; a verb joined to the path by quoting
# tricks, or itself quoted (`'rm'`); `bash < <recorder>` and
# `cat <recorder> | bash`; a recorder name inside a quoted string that the
# split above cuts at a `;`, `|` or `&`; case variants of a guarded path on a
# case-insensitive filesystem (`.gaia/local/Protected`); an Edit/Write path or
# a Bash command that reaches `protected/` without naming `local/protected` or
# `audit-loop` anywhere in its spelling (a `..` hop such as
# `.gaia/local/runs/../protected/x`, or a symlink alias whose own path names
# neither): the raw pre-filter allows it before any resolution; a symlink alias
# to `protected/` or into it whose own path never names it, and the two-hop
# parent alias (an allowed `ln -s <main>/.gaia/local <elsewhere>`, which names
# neither `.gaia/local/protected` nor `local/protected`, followed by a write
# through `<elsewhere>/protected/...`, or a `mv` or `ln` through the alias),
# since the `ln -s` that names the folder is denied but the parent alias is not;
# `mkdir`, which is not a write verb, so creating the folder or a directory
# inside it stays allowed; a context reading minted by a command that never
# names the context directory, by running .gaia/statusline/gaia-statusline.sh
# with a crafted stdin payload or by sourcing
# .gaia/scripts/context-checkpoint-lib.sh and calling gaia_context_write, directly or
# through a wrapper such as .gaia/statusline/context-reading.sh's
# gaia_statusline_write_context (such a reading stands until the next real
# statusline render overwrites it).
#
# THE PARENT. Deleting the parent `.gaia/local` (which would take the state with
# it) is block-rm-rf.sh's remit, not this guard's, and is not widened here.
#
# Fail mode: a missing jq refuses only a call whose tool_input mentions one of
# the guarded spellings (exit 2, via lib/jq-availability.sh), so installing jq
# stays allowed. A deny is JSON on stdout with exit 0.
#
# Bash 3.2 compatible.
set -euo pipefail

payload=$(cat)

# A missing jq-availability library refuses before the pre-filter below: the
# pre-filter's silent allow is only sound while the arm it skips is loadable,
# and a guard that exits 0 with its library gone fails open. A plain file test
# keeps this free of a fork on the common path.
_self_directory="${BASH_SOURCE[0]%/*}"
[ "$_self_directory" != "${BASH_SOURCE[0]}" ] || _self_directory=.
if [ ! -f "$_self_directory/lib/jq-availability.sh" ]; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

# Raw pre-filter. Every call this guard can bind carries one of these literals
# in its payload (JSON never escapes those characters; both recorder names
# contain `audit-loop`), so a payload without any is outside the remit with no
# jq read at all. This is the path every ordinary Bash call takes.
case "$payload" in
  *audit-loop* | *local/protected* | *cache/shared/context*) ;;
  *) exit 0 ;;
esac

_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the audit loop state guard' "$payload" tool_input 'audit-loop' 'local/protected' 'cache/shared/context'

set +e
# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
set -e
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
# An empty or unreadable payload names nothing to guard, and the hook stands
# down with status 0, as the per-field reads did for an empty payload.
gaia_hook_payload_read "$payload" || exit 0
tool_name="$GAIA_HOOK_TOOL_NAME"

DENY_STATE_MESSAGE="BLOCKED: block-audit-loop-write.sh: the audit loop state (<main>/.gaia/local/protected/audit-loop/) is written only by the audit loop hooks. Claude never writes, edits, moves or deletes it. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). A corrupt state file is repaired by a human from a terminal outside Claude Code."
DENY_CONTEXT_MESSAGE="BLOCKED: block-audit-loop-write.sh: the context readings (<main>/.gaia/local/cache/shared/context/) are written by the statusline on each render, and the audit checkpoint trusts them. Claude never writes, edits, moves or deletes them. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."
DENY_OVERRIDE_MESSAGE="BLOCKED: block-audit-loop-write.sh: <main>/.gaia/local/protected/checkpoint-override.json is the per-machine audit checkpoint override, and only a human edits the override, by hand from outside Claude Code. Claude never creates, writes, edits, moves or deletes it. GAIA's writable per-machine opt-ins live in <main>/.gaia/local/settings.json, which this guard does not cover. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."
DENY_FOLDER_MESSAGE="BLOCKED: block-audit-loop-write.sh: <main>/.gaia/local/protected/ holds state the audit checkpoint trusts, and only hooks or a human write <main>/.gaia/local/protected/, by hand from a terminal outside Claude Code. Claude never creates, writes, edits, moves or deletes anything in it. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint)."
DENY_RECORDER_MESSAGE="BLOCKED: block-audit-loop-write.sh: audit-loop-grant.sh and audit-loop-ask-grant.sh run only as hooks. Claude never executes them from Bash or Monitor, because a piped payload would forge a checkpoint answer. A human answers a checkpoint through the pinned AskUserQuestion, or by typing a whole prompt that is exactly the audit-grant <n> or audit-accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). Naming the files (git add, git diff, git grep -l, shellcheck, cat, bash -n) is allowed."
DENY_BASH_TRIGGER="Trigger: the command names that path and either redirects into it or carries a write, move or delete verb (rm, mv, cp, tee, ln, touch, sed -i, an interpreter given -c or -e, and the like) outside quotes; in a command holding a heredoc, an unclosed quote, a command substitution inside double quotes, or a redirect target built from a variable or a glob, any redirect or such verb anywhere counts. A command that names the path only as quoted text and redirects elsewhere is allowed, so stage a note that mentions it with printf and a quoted string, no heredoc, or leave the literal path out of the command."

# deny <state|override|folder|context|recorder> [bash]
deny() {
  local message
  case "$1" in
    context) message="$DENY_CONTEXT_MESSAGE" ;;
    override) message="$DENY_OVERRIDE_MESSAGE" ;;
    folder) message="$DENY_FOLDER_MESSAGE" ;;
    recorder) message="$DENY_RECORDER_MESSAGE" ;;
    *) message="$DENY_STATE_MESSAGE" ;;
  esac
  [ "${2-}" != bash ] || message="$message $DENY_BASH_TRIGGER"
  jq -n --arg reason "$message" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# protected_class <path> <folder>: print the class a path inside, or equal to,
# the protected folder names. The audit loop state directory and the exact
# override file name get their own message; every other occupant, a sibling
# such as `protected/checkpoint-override.json.bak` included, is the folder.
protected_class() {
  case "$1" in
    "$2/audit-loop" | "$2/audit-loop"/*) printf state ;;
    "$2/checkpoint-override.json") printf override ;;
    *) printf folder ;;
  esac
}

# guarded_class <path>: print the guarded class a path spelling names, or
# nothing. The protected arm pairs the folder itself with its children, so a
# sibling beside it such as `.gaia/local/protected-notes.md` and the writable
# opt-ins file `.gaia/local/settings.json` do not match.
guarded_class() {
  case "$1" in
    */.gaia/local/protected/* | */.gaia/local/protected) protected_class "$1" "${1%%/.gaia/local/protected*}/.gaia/local/protected" ;;
    */.gaia/local/cache/shared/context/* | */.gaia/local/cache/shared/context) printf context ;;
  esac
}

# physical_path <path> <base-dir>: print the physically resolved absolute path.
# Walks the segments; while each prefix exists as a directory it is entered with
# `pwd -P` (symlinks and `..` resolved by the filesystem), and once a segment is
# missing the rest is joined lexically with `..` collapsed.
physical_path() {
  local input_path="$1" base="$2" current_path path_component lexical=0 rest hops=0 target
  case "$input_path" in
    /*) ;;
    *) input_path="$base/$input_path" ;;
  esac
  current_path=/
  rest="${input_path#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        path_component="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        path_component="$rest"
        rest=''
        ;;
    esac
    case "$path_component" in
      '' | .) continue ;;
      ..)
        if [ "$lexical" -eq 1 ]; then
          current_path="${current_path%/*}"
          [ -n "$current_path" ] || current_path=/
        else
          current_path=$( (cd "${current_path%/}/.." 2>/dev/null && pwd -P) ) || current_path=/
        fi
        continue
        ;;
    esac
    if [ "$lexical" -eq 0 ] && [ -d "${current_path%/}/$path_component" ]; then
      current_path=$( (cd "${current_path%/}/$path_component" 2>/dev/null && pwd -P) ) || { lexical=1; current_path="${current_path%/}/$path_component"; }
    else
      # A final component that is itself a symlink (a file link into the
      # directory): follow it, a bounded number of hops.
      if [ "$lexical" -eq 0 ] && [ -z "$rest" ] && [ -L "${current_path%/}/$path_component" ] && [ "$hops" -lt 8 ]; then
        hops=$((hops + 1))
        target=$(readlink "${current_path%/}/$path_component" 2>/dev/null) || target=''
        if [ -n "$target" ]; then
          physical_path "$target" "$current_path"
          return 0
        fi
      fi
      lexical=1
      current_path="${current_path%/}/$path_component"
    fi
  done
  printf '%s' "$current_path"
}

# has_write_verb <text>: rc 0 when the text carries a write, move or delete
# verb.
has_write_verb() {
  local verbs_re sedi_re interpreter_re
  verbs_re='(^|[[:space:];&|(`/])(rm|mv|cp|tee|ln|install|dd|touch|truncate|chmod|rsync|unlink|shred)([[:space:]]|$)'
  sedi_re='(^|[[:space:];&|(`/])(sed|perl)[[:space:]]+(-[a-zA-Z]*i|--in-place)'
  interpreter_re='(^|[[:space:];&|(`/])(python[0-9.]*|node|perl|ruby)[[:space:]]+-[a-zA-Z]*[ce]'
  [[ "$1" =~ $verbs_re ]] && return 0
  [[ "$1" =~ $sedi_re ]] && return 0
  [[ "$1" =~ $interpreter_re ]] && return 0
  return 1
}

# has_write_spelling <command>: rc 0 when the command carries a write, move or
# delete spelling anywhere, quoted text included. The fallback reading.
has_write_spelling() {
  local scrub

  # Drop redirects that cannot write a guarded path: descriptor duplication
  # (2>&1, >&2) and a redirect to /dev/null.
  scrub=$(sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9&]*>>?[[:space:]]*\/dev\/null//g' <<<"$1")

  # A redirect to anything else.
  case "$scrub" in
    *'>'*) return 0 ;;
  esac
  has_write_verb "$scrub"
}

# shell_scan <text>: read the text the way the shell groups it, as far as this
# guard needs. Sets
#   SCAN_WORDS    the words, quotes removed: single and double quotes group, a
#                 backslash outside single quotes escapes the next character,
#                 unquoted blanks, newlines and ; & | ( ) ` end a word, and a
#                 redirect target is not a word
#   SCAN_TARGETS  each `>`, `>>`, `>|` or `>&` redirect target, one per line;
#                 a descriptor duplication (2>&1, >&-) and a process
#                 substitution `>(` have none
#   SCAN_BARE     the text outside quotes and comments, each quoted span as
#                 one Q
#   SCAN_SOUND    0 when the text ends inside a quote, holds a heredoc, has a
#                 command substitution or backtick inside double quotes, or
#                 has a redirect target holding `$`, a backtick or a glob
# An unquoted `#` that starts a word opens a comment to the end of the line.
# A heredoc body is unquoted prose whose apostrophes this reading would take
# for quotes, and a quoted substitution runs commands this reading takes for
# text, so on SCAN_SOUND=0 the caller falls back to the whole-text reading.
shell_scan() {
  local scanned_text="$1" text_length=${#1} i=0 character open_quote='' word='' inword=0 want=0
  SCAN_WORDS=()
  SCAN_TARGETS=''
  SCAN_BARE=''
  SCAN_SOUND=1
  while [ "$i" -le "$text_length" ]; do
    character="${scanned_text:i:1}"
    if [ -n "$open_quote" ] && [ "$i" -lt "$text_length" ]; then
      if [ "$character" = "$open_quote" ]; then
        open_quote=''
      elif [ "$open_quote" = '"' ] && [ "$character" = "\\" ]; then
        i=$((i + 1))
        word="$word${scanned_text:i:1}"
      else
        if [ "$open_quote" = '"' ]; then
          case "$character" in
            '`') SCAN_SOUND=0 ;;
            '$') [ "${scanned_text:i+1:1}" != '(' ] || SCAN_SOUND=0 ;;
          esac
        fi
        word="$word$character"
      fi
      i=$((i + 1))
      continue
    fi
    case "$character" in
      "'" | '"')
        open_quote="$character"
        inword=1
        SCAN_BARE="${SCAN_BARE}Q"
        ;;
      "\\")
        i=$((i + 1))
        word="$word${scanned_text:i:1}"
        inword=1
        SCAN_BARE="$SCAN_BARE$character${scanned_text:i:1}"
        ;;
      '' | ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '`' | '>')
        # The end of the text, or a character that ends the word in hand.
        if [ "$inword" -eq 1 ]; then
          if [ "$want" -eq 1 ]; then
            SCAN_TARGETS="$SCAN_TARGETS$word"$'\n'
            want=0
            # A target built from a variable, a substitution or a glob can
            # land on a path the command names elsewhere.
            case "$word" in
              *'$'* | *'*'* | *'?'* | *'['* | *'`'*) SCAN_SOUND=0 ;;
            esac
          elif [ "$character" = '>' ] && [[ "$word" =~ ^[0-9]+$ ]]; then
            : # the descriptor number of a redirect such as 2>, not a word
          else
            SCAN_WORDS[${#SCAN_WORDS[@]}]="$word"
          fi
        fi
        word=''
        inword=0
        SCAN_BARE="$SCAN_BARE$character"
        if [ "$character" = '>' ]; then
          case "${scanned_text:i+1:1}" in
            '>' | '|')
              i=$((i + 1))
              SCAN_BARE="$SCAN_BARE${scanned_text:i:1}"
              ;;
          esac
          if [ "${scanned_text:i+1:1}" = '&' ]; then
            i=$((i + 1))
            SCAN_BARE="$SCAN_BARE&"
            case "${scanned_text:i+1:1}" in
              [0-9-]) ;;
              *) want=1 ;;
            esac
          elif [ "${scanned_text:i+1:1}" != '(' ]; then
            want=1
          fi
        fi
        ;;
      '#')
        if [ "$inword" -eq 1 ]; then
          word="$word$character"
          SCAN_BARE="$SCAN_BARE$character"
        else
          # A comment runs to the end of the line; its apostrophes are not
          # quotes. The newline itself is read next, as a separator.
          while [ "$((i + 1))" -lt "$text_length" ] && [ "${scanned_text:i+1:1}" != $'\n' ]; do
            i=$((i + 1))
          done
        fi
        ;;
      '<')
        # `<<<` is a here-string; a bare `<<` opens a heredoc.
        if [ "${scanned_text:i+1:2}" = '<<' ]; then
          i=$((i + 2))
          word="$word<<"
          SCAN_BARE="$SCAN_BARE<<"
        elif [ "${scanned_text:i+1:1}" = '<' ]; then
          SCAN_SOUND=0
        fi
        word="$word$character"
        inword=1
        SCAN_BARE="$SCAN_BARE$character"
        ;;
      *)
        word="$word$character"
        inword=1
        SCAN_BARE="$SCAN_BARE$character"
        ;;
    esac
    i=$((i + 1))
  done
  [ -z "$open_quote" ] || SCAN_SOUND=0
  return 0
}

# writes_named <command> <names-regex>: rc 0 when the command writes, moves or
# deletes what the regex names: a redirect whose target names it, or a write
# verb outside quotes in a command that names it anywhere. On an unsound
# reading (see shell_scan), any redirect or verb anywhere counts.
writes_named() {
  local target
  [ "$SCAN_SOUND" -eq 1 ] || {
    has_write_spelling "$1"
    return
  }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [[ "$target" =~ $2 ]] && return 0
  done <<<"$SCAN_TARGETS"
  has_write_verb "$SCAN_BARE"
}

# is_recorder_word <word>: rc 0 when the word's file name is one of the two
# recorders.
is_recorder_word() {
  case "$1" in
    audit-loop-grant.sh | */audit-loop-grant.sh | audit-loop-ask-grant.sh | */audit-loop-ask-grant.sh) return 0 ;;
  esac
  return 1
}

# words_run_recorder: rc 0 when the simple command held in the `words` array
# executes a recorder (command word, or script argument of a shell or
# `source`/`.`/`exec`).
words_run_recorder() {
  local count=${#words[@]} word_index=0 word base syntax_check

  # Skip leading NAME=value words, `!`, and `exec`.
  while [ "$word_index" -lt "$count" ]; do
    case "${words[$word_index]}" in
      [A-Za-z_]*=* | '!' | exec) word_index=$((word_index + 1)) ;;
      *) break ;;
    esac
  done
  [ "$word_index" -lt "$count" ] || return 1

  word="${words[$word_index]}"
  is_recorder_word "$word" && return 0
  base="${word##*/}"
  case "$base" in
    bash | sh | zsh | dash | ksh | source | .)
      syntax_check=0
      word_index=$((word_index + 1))
      while [ "$word_index" -lt "$count" ]; do
        word="${words[$word_index]}"
        case "$word" in
          -n) syntax_check=1 ;;
          -o | +o) word_index=$((word_index + 1)) ;;
          -* | +*) ;;
          *)
            if is_recorder_word "$word" && [ "$syntax_check" -eq 0 ]; then
              return 0
            fi
            break
            ;;
        esac
        word_index=$((word_index + 1))
      done
      ;;
  esac
  return 1
}

# runs_recorder <command>: rc 0 when a simple command in the line executes a
# recorder. Each segment is read twice, as the shell groups its quotes (a
# quoted path with a space stays one word) and as blank-separated words with
# their quotes stripped (a quote the segment split cut in half), and either
# reading executing a recorder counts.
runs_recorder() {
  local command_line="$1" segments segment words word_index count word
  case "$command_line" in
    *audit-loop-grant.sh* | *audit-loop-ask-grant.sh*) ;;
    *) return 1 ;;
  esac
  segments="${command_line//\$\(/$'\n'}"
  segments=$(printf '%s' "$segments" | tr ';&|`()' '\n')
  while IFS= read -r segment; do
    words=()
    read -r -a words <<<"$segment" || true
    count=${#words[@]}
    [ "$count" -gt 0 ] || continue
    word_index=0
    while [ "$word_index" -lt "$count" ]; do
      word="${words[$word_index]//\"/}"
      word="${word//\'/}"
      words[word_index]="$word"
      word_index=$((word_index + 1))
    done
    words_run_recorder && return 0

    shell_scan "$segment"
    words=()
    count=${#SCAN_WORDS[@]}
    word_index=0
    while [ "$word_index" -lt "$count" ]; do
      words[word_index]="${SCAN_WORDS[$word_index]}"
      word_index=$((word_index + 1))
    done
    [ "$count" -gt 0 ] || continue
    words_run_recorder && return 0
  done <<<"$segments"
  return 1
}

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path="$GAIA_HOOK_FILE_PATH"
    [[ -n "$file_path" ]] || exit 0

    # Literal spelling first: it needs no resolution and survives a symlink
    # target that cannot be resolved.
    class=$(guarded_class "$file_path")
    [ -z "$class" ] || deny "$class"

    cwd="$GAIA_HOOK_CWD"
    [[ -n "$cwd" ]] || cwd=$(pwd -P)
    resolved=$(physical_path "$file_path" "$cwd")

    main_root=''
    _main_root_library="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
    if [ -f "$_main_root_library" ]; then
      set +e
      # shellcheck source=../../.gaia/scripts/main-root-lib.sh
      . "$_main_root_library" 2>/dev/null
      main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null)
      set -e
    fi
    if [ -n "$main_root" ]; then
      case "$resolved" in
        "$main_root/.gaia/local/protected" | "$main_root/.gaia/local/protected"/*) deny "$(protected_class "$resolved" "$main_root/.gaia/local/protected")" ;;
        "$main_root/.gaia/local/cache/shared/context" | "$main_root/.gaia/local/cache/shared/context"/*) deny context ;;
      esac
    fi
    # Resolved spelling that still names a guarded path (a symlinked checkout
    # whose main root could not be resolved).
    class=$(guarded_class "$resolved")
    [ -z "$class" ] || deny "$class"
    exit 0
    ;;

  Bash | Monitor)
    command_line="$GAIA_HOOK_COMMAND"
    [[ -n "$command_line" ]] || exit 0

    runs_recorder "$command_line" && deny recorder

    # Pre-filter per class: does the command name the path at all?
    protected_names_re='\.gaia/local/protected(/|[[:space:]"'\'';|&)<>]|$)'
    state_subpath_re='\.gaia/local/protected/audit-loop(/|[[:space:]"'\'';|&)<>]|$)'
    override_subpath_re='\.gaia/local/protected/checkpoint-override\.json([[:space:]"'\'';|&)<>]|$)'
    context_names_re='\.gaia/local/cache/shared/context(/|[[:space:]"'\'';|&)<>]|$)'
    shell_scan "$command_line"
    if [[ "$command_line" =~ $protected_names_re ]] && writes_named "$command_line" "$protected_names_re"; then
      # The class follows what is written, not what is merely named.
      if [[ "$command_line" =~ $state_subpath_re ]] && writes_named "$command_line" "$state_subpath_re"; then
        deny state bash
      fi
      if [[ "$command_line" =~ $override_subpath_re ]] && writes_named "$command_line" "$override_subpath_re"; then
        deny override bash
      fi
      deny folder bash
    fi
    if [[ "$command_line" =~ $context_names_re ]] && writes_named "$command_line" "$context_names_re"; then
      deny context bash
    fi
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
