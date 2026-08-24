#!/usr/bin/env bash
# The data-proof walker behind the shared verb-arming decision. Sourced by
# lib/verb-arming.sh, lazily, only once a raw arming match has already hit;
# sourced by nothing else. Does no work at source time.
#
#   gaia_verb_arm_view <text>
#
# ASSIGNS GAIA_VERB_ARM_VIEW. It does not print the view, and no caller may
# read it through `$( )`: command substitution strips every trailing newline,
# and a tool call ending in one is the common heredoc shape, so a stdout return
# channel would break the same-length property below for exactly the inputs
# that need it most.
#
# SAME LENGTH, ALWAYS. The view is the same CHARACTER length as <text>, because
# the mask is an overwrite rather than a deletion. The pull-request-creation
# consumer recovers the real bytes of its captured flag tail by suffix length
# against the view, so any length drift there silently hands that consumer a
# tail cut in the wrong place. Character length is the dimension that matters,
# which is why the mask run is sized outside the byte-locale the scan runs in.
#
# WHAT COUNTS AS DATA. Exactly one shape, and deliberately small. A heredoc
# body is data when all of the following hold on its opener line:
#
#   1. the command word is the literal `cat` or `tee`, written out, never
#      reached through an expansion;
#   2. the output goes to a file: a `>` or `>>` redirect to a word, or a `tee`
#      file operand. Never into a pipe, another command, or a file descriptor;
#   3. the line carries no command substitution, parameter expansion, or
#      backtick anywhere;
#   4. the delimiter is a single unambiguous word, `<<` or `<<-`, quoted or
#      unquoted;
#   5. the delimiter line actually appears later in the text;
#   6. the heredoc belongs to that first command: no `&`, `;` or `(` stands
#      between the command word and the heredoc operator. Conditions 1 and 2
#      each read the line as a whole, so without this one a line whose first
#      command is `cat > f` lends its proof to a second command's heredoc after
#      a separator, and the shell runs what that second command is handed.
#
# The body runs from the newline ENDING the opener line, not from the heredoc
# operator, so anything still on the opener line after the operator is ordinary
# command text and keeps its arming power. That newline is masked with the body
# it introduces, because it is the separator a body's first line would arm on.
# The newline that ends the last body line is left alone: nothing after it is
# body, and leaving it is the direction that suppresses less.
#
# NOTHING ELSE IS PROOF. Quoted spans are never suppressed: a `bash -c` runs
# what it is handed from inside one, and a runner reached through a variable
# defeats any list of interpreter names, so there is no safe narrowing.
# Comments are never suppressed: a `#` that is not word-initial opens no
# comment, and the arming patterns already decline a word-initial one because
# they require whitespace before the verb. The walk still RECOGNIZES quoted
# spans and comments, for one purpose: knowing that a `<<` inside one opens no
# heredoc. Recognizing is not suppressing.
#
# ABSTENTION IS WHOLE-INPUT. On any of a text longer than the character bound,
# a text dense enough to exhaust the re-reading budget, an unterminated quoted
# span, a `$'…'` word, a heredoc whose delimiter never appears, or any
# construct not modelled here, the view is the identity and nothing anywhere is
# suppressed. The burden of proof rests on suppression: an
# over-armed hook costs an unrelated tool call a decision nobody asked for,
# while an under-armed one lets a real merge past a gate.
#
# THE BOUND. 16,384 characters, owned by lib/verb-arming.sh and defaulted here
# so this file is sourceable on its own under `set -u`. It covers the observed
# population: in a corpus of 33,498 real Bash tool calls no call that armed ran
# longer, and two ran past 8,192. Past the bound the view is the identity and
# the raw match stands, because a hook that misses its deadline is cancelled
# and the tool call then proceeds uninspected, which is the fail-open direction.
#
# COST. The walk jumps span to span with parameter-expansion prefix strips
# rather than reading a character at a time: `${s:$i:1}` costs O(i), so a
# per-character index is quadratic, which at this bound is the difference
# between roughly a hundredth of a second and roughly a second per hook on
# stock bash 3.2. It has to be affordable on ordinary traffic rather than on
# merges, because commits and pushes are most of what raw-matches at all. Size
# alone does not bound the walk, so a second bound does; see the re-reading
# budget below.
#
# WHAT THIS DOES NOT CLOSE, stated so no reader takes the arming contract for
# whole:
#
#   - Quoted prose still over-arms. A quoted string carrying a separator before
#     the verb arms every consumer. Fail-closed, and there is no safe
#     narrowing.
#   - A verb whose characters are quoted still under-arms outside the first
#     command, because the tokenizer arm reads the first command only.
#   - Dollar-quoted words are unmodelled. The walk abandons suppression on one
#     rather than approximating it.
#   - The tokenizer arm's bounded prefix can create an arm no data proof
#     removes, because truncation at that bound can leave a word reading as the
#     verb. That arm is not subject to this walk at all.

_GAIA_VA_TAB=$'\t'
# A lone backslash is unwritable as a `case` pattern without either escaping it
# into something else or drawing a false "did you mean to escape a quote"
# reading; held in a variable it is unambiguous in both places it is compared.
_GAIA_VA_BS=$'\\'

# Character sets the walk jumps to, as glob bracket expressions held in
# variables: a bracket carrying a newline, a backslash and both quote
# characters is unreadable written inline, and a literal `$'\n'` cannot appear
# in a `case` pattern at all.
#
# Top level: both quote characters, a backslash (escapes the next character), a
# backtick (opens a substitution span), a `#` (may open a comment), a `<` (may
# open a heredoc), a `$` (may open a dollar-quoted word), and a newline (ends a
# line, which is where heredoc bodies begin). The apostrophe and the backtick
# are spelled as octal escapes rather than written out: a literal backtick in a
# `$'…'` word reads as an unclosed substitution to a tokenizer that does not
# model this quoting form, and a `\'` reads as the word's own terminator, which
# desyncs the tree's shell linters over the whole rest of the file.
_GAIA_VA_TOP_SET=$'["\047\\\\\140#<$\n]'
# Inside a double-quoted span: the closing quote, and a backslash, which
# escapes the character after it there.
_GAIA_VA_DQ_SET=$'["\\\\]'
# A run ending in one of these leaves the next character word-initial, which is
# what decides whether a `#` opens a comment.
_GAIA_VA_WORD_SET=$'[ \t;&|(\n]'
# The blanks that may sit between a heredoc operator and its delimiter, and
# their complement, so the run is skipped in one strip rather than one per
# character.
_GAIA_VA_BLANK_SET=$'[ \t]'
_GAIA_VA_NONBLANK_SET=$'[! \t]'

# How much re-reading the walk pays for before it gives up, counted in
# characters.
#
# The character bound bounds SIZE, and size is not what the walk costs. Every
# parameter expansion of the remaining text costs a pass over the whole of it,
# so the price is the number of steps times what is still to come, and two
# texts of the same size differ by two orders of magnitude depending on how
# densely they carry the characters a step lands on. The dense end is where a
# hook misses its deadline, gets cancelled, and lets the tool call through
# uninspected, so it needs a bound in the dimension the cost is actually in
# rather than a step count, which would be far too tight on a short dense text
# and far too loose on a long one.
#
# 2,000,000 puts the worst case a text at the character bound can reach in the
# same range as an ordinary one, and leaves real traffic untouched by a wide
# margin. A heredoc's body is skipped whole rather than stepped through, so a
# report written to a file spends two steps whatever its body costs, and even
# a two-hundred-line script that goes on to write one stays inside.
_GAIA_VA_MAX_WORK=2000000

# A `>` or `>>` redirect to a word. The leading exclusion is what keeps a file
# descriptor out: `2>err` redirects stderr and leaves the body on stdout, and
# `>&2` is a descriptor duplication with no file anywhere.
_GAIA_VA_REDIR_RE='(^|[^0-9&>])>>?[[:space:]]*[^[:space:]&<>|;]'
# A `tee` file operand: flags, then a word that is neither a flag nor a
# redirection. `tee <<EOF` and `tee -a <<EOF` name no file and fail it.
_GAIA_VA_TEE_RE='^[[:space:]]*tee([[:space:]]+-[^[:space:]]*)*[[:space:]]+[^-<>[:space:]]'

# The run of `x` every mask is filled from, grown on demand and reused for the
# life of the process. Taken from a doubling cache rather than from
# `${body//?/x}`, whose pattern substitution rescans the whole body per
# replacement and is quadratic in body length. ASCII, so its length is the same
# character count in every locale.
_gaia_va_xrun=x
_gaia_va_run=""
_gaia_va_p=-1
_gaia_va_lc_prev=""
_gaia_va_lc_had=""

_gaia_va_make_run() {
  local n="$1"
  [ "$n" -gt 0 ] || { _gaia_va_run=""; return 0; }
  while [ "${#_gaia_va_xrun}" -lt "$n" ]; do
    _gaia_va_xrun="$_gaia_va_xrun$_gaia_va_xrun"
  done
  _gaia_va_run="${_gaia_va_xrun:0:$n}"
}

# The scan runs under LC_ALL=C, where every offset and length is a byte. Every
# character it looks for is ASCII and a multibyte character's bytes are all
# non-ASCII, so byte offsets cut in the same places character offsets would.
# The mask run is the one quantity that cannot be sized that way, since the
# view's length contract is in characters, so the walk steps back into the
# caller's locale to measure each body and returns.
_gaia_va_lc_bytes() {
  _gaia_va_lc_had="${LC_ALL+set}"
  _gaia_va_lc_prev="${LC_ALL-}"
  LC_ALL=C
}

_gaia_va_lc_chars() {
  if [ "$_gaia_va_lc_had" = set ]; then LC_ALL="$_gaia_va_lc_prev"; else unset LC_ALL; fi
}

# _gaia_va_find_delim <text> <delim> <strip>: set _gaia_va_p to the offset in
# <text> at which the delimiter LINE begins, or return 1 when no such line
# exists. <strip> is 1 for the `<<-` form, whose delimiter line may carry
# leading tabs the shell removes.
_gaia_va_find_delim() {
  local s="$1" d="$2" strip="$3"
  local nl=$'\n' pre probe consumed line t
  _gaia_va_p=-1
  if [ "$strip" = 0 ]; then
    case "$s" in
      "$d"|"$d$nl"*) _gaia_va_p=0; return 0 ;;
    esac
    # One prefix strip locates the first delimiter line: `%%` removes the
    # longest suffix that matches, which is the one starting at the earliest
    # occurrence. Quoting the delimiter inside the pattern keeps a glob
    # character in it literal.
    pre="${s%%"$nl$d$nl"*}"
    if [ "${#pre}" -ne "${#s}" ]; then _gaia_va_p=$(( ${#pre} + 1 )); return 0; fi
    case "$s" in
      *"$nl$d") _gaia_va_p=$(( ${#s} - ${#d} )); return 0 ;;
    esac
    return 1
  fi
  # The `<<-` form needs the tabs stripped before the comparison, which no
  # single pattern expresses, so walk the lines.
  probe="$s"
  consumed=0
  while :; do
    case "$probe" in
      *"$nl"*) line="${probe%%"$nl"*}" ;;
      *) line="$probe" ;;
    esac
    t="$line"
    while :; do
      case "$t" in
        "$_GAIA_VA_TAB"*) t="${t#?}" ;;
        *) break ;;
      esac
    done
    if [ "$t" = "$d" ]; then _gaia_va_p="$consumed"; return 0; fi
    case "$probe" in
      *"$nl"*) ;;
      *) return 1 ;;
    esac
    probe="${probe#*"$nl"}"
    consumed=$(( consumed + ${#line} + 1 ))
  done
}

# _gaia_va_opener_is_data <opener-line> <pre-operator-text>: 0 when the line
# meets every condition in the whitelist this file's header states, 1
# otherwise. Conditions 4 and 5 are decided where the delimiter is parsed and
# where its line is located; this decides 1, 2, 3 and 6.
_gaia_va_opener_is_data() {
  local line="$1" pre="$2"
  # Condition 6. Conditions 1 and 2 each read the line as a whole, the command
  # word at its start and a redirect anywhere on it, so a line whose FIRST
  # command is `cat > f` and whose heredoc belongs to a SECOND command after a
  # separator satisfies both while the shell hands that body to the second
  # command and runs it. `cat > f.txt && bash <<EOF` with a merge in the body
  # is the shape that costs: masking it there disarms every gate on a merge the
  # shell executes, which is the one direction this walk may never fail in.
  # Only the text ahead of the operator separates the two readings, and a
  # separator after the operator is not the same question: the heredoc there
  # already belongs to the first command. `|` needs no arm of its own, since
  # condition 3 rejects it anywhere on the line.
  case "$pre" in
    *'&'*|*';'*|*'('*) return 1 ;;
  esac
  # Condition 3, read as "no `$` at all" rather than as a list of expansion
  # openers. Narrower than the whitelist's letter, and narrower is the safe
  # direction: `$@`, `$?` and `$$` expand too, and enumerating them invites the
  # next one to be missed. A pipe anywhere fails condition 2 for the same
  # reason, without needing to know whether it is quoted.
  case "$line" in
    *'$'*|*'`'*|*'|'*) return 1 ;;
  esac
  # Condition 1. The command word has to BE `cat` or `tee`: a quoted spelling,
  # a path, or any prefix ahead of it means the walk cannot say what runs.
  case "$line" in
    'cat '*|"cat$_GAIA_VA_TAB"*|'tee '*|"tee$_GAIA_VA_TAB"*) ;;
    *) return 1 ;;
  esac
  # Condition 2.
  [[ "$line" =~ $_GAIA_VA_REDIR_RE ]] && return 0
  case "$line" in
    'tee'*) [[ "$line" =~ $_GAIA_VA_TEE_RE ]] && return 0 ;;
  esac
  return 1
}

gaia_verb_arm_view() {
  local text="$1"
  GAIA_VERB_ARM_VIEW="$text"
  [ "${#text}" -le "${GAIA_VERB_ARM_MAX_CHARS:-16384}" ] || return 0
  # No heredoc operator anywhere means no body can be proven data, and this is
  # the shape most raw-matching traffic takes, so it never pays for the walk.
  case "$text" in
    *'<<'*) ;;
    *) return 0 ;;
  esac

  local nl=$'\n'
  local s out cur q ch pre np chunk blanks ok wstart work line_start
  local hd_n strip dl dbad data first p body dline bi hd_pre
  local hd_delim hd_strip
  hd_delim=()
  hd_strip=()

  _gaia_va_lc_bytes
  s="$text"
  out=""
  q=""
  ok=1
  wstart=1
  work=0
  line_start=0
  hd_n=0
  hd_pre=""

  while [ -n "$s" ]; do
    # Charge this step what it is about to cost, and abandon suppression on
    # running out, exactly as the walk does on anything else it cannot decide
    # cheaply.
    work=$(( work + ${#s} ))
    if [ "$work" -gt "$_GAIA_VA_MAX_WORK" ]; then ok=0; break; fi

    if [ -n "$q" ]; then
      # Inside a quoted span, jump to what can end it. A single-quoted span and
      # a backtick span end only at their own delimiter; a double-quoted span
      # also has to honour the backslash, which escapes the character after it
      # there.
      if [ "$q" = '"' ]; then
        # The set is a bracket expression, so it has to reach the matcher
        # UNQUOTED; quoting it would compare the brackets themselves.
        # shellcheck disable=SC2295
        pre="${s%%$_GAIA_VA_DQ_SET*}"
      else
        pre="${s%%"$q"*}"
      fi
      np=${#pre}
      ch="${s:$np:1}"
      # An empty character here means the strip found nothing, so the span runs
      # to the end of the text without closing.
      if [ -z "$ch" ]; then ok=0; break; fi
      out+="$pre$ch"
      s="${s:$(( np + 1 ))}"
      if [ "$ch" = "$_GAIA_VA_BS" ]; then
        [ -n "$s" ] || { ok=0; break; }
        out+="${s:0:1}"
        s="${s:1}"
      else
        q=""
      fi
      continue
    fi

    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    pre="${s%%$_GAIA_VA_TOP_SET*}"
    # Every expansion of the remaining text costs a pass over the whole of it,
    # so the strip's length is taken once and reused. Reading the character at
    # that offset also answers whether the strip found anything: past the end
    # of the text the slice is empty, which no real match can be.
    np=${#pre}
    ch="${s:$np:1}"
    if [ -z "$ch" ]; then
      out+="$pre"
      s=""
      break
    fi
    out+="$pre"
    s="${s:$np}"
    case "$pre" in
      '') ;;
      *$_GAIA_VA_WORD_SET) wstart=1 ;;
      *) wstart=0 ;;
    esac

    case "$ch" in
      "'"|'"'|'`')
        q="$ch"
        out+="$ch"
        s="${s:1}"
        wstart=0
        ;;
      "$_GAIA_VA_BS")
        out+="$ch"
        s="${s:1}"
        if [ -z "$s" ]; then ok=0; break; fi
        ch="${s:0:1}"
        out+="$ch"
        s="${s:1}"
        # A backslash-newline is a line CONTINUATION: the shell removes both
        # and the logical line runs on, so the newline that ends an opener line
        # is somewhere further down. Locating a body under that would mask
        # command text, so give up on the whole input instead.
        if [ "$ch" = "$nl" ] && [ "$hd_n" -gt 0 ]; then ok=0; break; fi
        wstart=0
        ;;
      '$')
        out+="$ch"
        s="${s:1}"
        case "$s" in "'"*) ok=0; break ;; esac
        wstart=0
        ;;
      '#')
        if [ "$wstart" = 1 ]; then
          case "$s" in
            *"$nl"*) pre="${s%%"$nl"*}" ;;
            *) pre="$s" ;;
          esac
          out+="$pre"
          s="${s:${#pre}}"
        else
          out+="$ch"
          s="${s:1}"
          wstart=0
        fi
        ;;
      '<')
        case "$s" in
          '<<<'*)
            # A herestring, not a heredoc: its word is on this line and no
            # following line is a body.
            out+='<<<'
            s="${s:3}"
            wstart=0
            ;;
          '<<'*)
            chunk='<<'
            s="${s:2}"
            strip=0
            case "$s" in '-'*) chunk="$chunk-"; s="${s:1}"; strip=1 ;; esac
            blanks=""
            # shellcheck disable=SC2295 # bracket expressions, matched as patterns
            case "$s" in
              $_GAIA_VA_BLANK_SET*) blanks="${s%%$_GAIA_VA_NONBLANK_SET*}" ;;
            esac
            if [ -n "$blanks" ]; then chunk="$chunk$blanks"; s="${s:${#blanks}}"; fi
            dl=""
            dbad=0
            case "$s" in
              "'"*)
                s="${s:1}"
                case "$s" in
                  *"'"*) dl="${s%%\'*}"; s="${s:$(( ${#dl} + 1 ))}"; chunk="$chunk'$dl'" ;;
                  *) dbad=1 ;;
                esac
                ;;
              '"'*)
                s="${s:1}"
                case "$s" in
                  *'"'*) dl="${s%%\"*}"; s="${s:$(( ${#dl} + 1 ))}"; chunk="$chunk\"$dl\"" ;;
                  *) dbad=1 ;;
                esac
                ;;
              "$_GAIA_VA_BS"*)
                s="${s:1}"
                dl="${s%%[!A-Za-z0-9_.-]*}"
                if [ -n "$dl" ]; then s="${s:${#dl}}"; chunk="$chunk$_GAIA_VA_BS$dl"; else dbad=1; fi
                ;;
              *)
                dl="${s%%[!A-Za-z0-9_.-]*}"
                if [ -n "$dl" ]; then s="${s:${#dl}}"; chunk="$chunk$dl"; else dbad=1; fi
                ;;
            esac
            if [ "$dbad" = 1 ]; then ok=0; break; fi
            # Condition 4: the delimiter has to be the whole word. Anything
            # abutting it is a spelling this walk cannot read exactly, and
            # reading it wrong puts the body's end in the wrong place.
            case "$s" in
              ''|' '*|"$_GAIA_VA_TAB"*|"$nl"*|';'*|'&'*|'|'*|'<'*|'>'*|')'*) ;;
              *) ok=0; break ;;
            esac
            # Condition 6's evidence, captured here because this is the only
            # point that knows where the operator sits: `out` still holds the
            # line up to it and nothing of it is masked yet. Only the first
            # operator on a line is recorded, which is the only one condition 6
            # is ever asked about.
            if [ "$hd_n" -eq 0 ]; then hd_pre="${out:$line_start}"; fi
            out+="$chunk"
            hd_delim[hd_n]="$dl"
            hd_strip[hd_n]="$strip"
            hd_n=$(( hd_n + 1 ))
            wstart=0
            ;;
          *)
            out+='<'
            s="${s:1}"
            wstart=0
            ;;
        esac
        ;;
      "$nl")
        if [ "$hd_n" -eq 0 ]; then
          out+="$nl"
          s="${s:1}"
          line_start=${#out}
          wstart=1
          continue
        fi
        # The opener line is read back out of the view rather than accumulated
        # alongside it: the accumulation costs an append per jump on every line
        # in the text, and only a line that turns out to carry an opener is ever
        # read. Nothing ahead of this point in the line is masked, so the slice
        # is the line's own bytes.
        cur="${out:$line_start}"
        # More than one heredoc on a line and the redirection that decides
        # where each body goes stops being readable from one opener, so none of
        # them is proven; their bodies are still skipped, just not masked.
        data=0
        if [ "$hd_n" -eq 1 ] && _gaia_va_opener_is_data "$cur" "$hd_pre"; then data=1; fi
        s="${s:1}"
        first=1
        bi=0
        while [ "$bi" -lt "$hd_n" ]; do
          _gaia_va_find_delim "$s" "${hd_delim[$bi]}" "${hd_strip[$bi]}" || { ok=0; break; }
          p="$_gaia_va_p"
          if [ "$first" = 1 ] && [ "$data" = 1 ] && [ "$p" -gt 0 ]; then
            out+=x
          else
            out+="$nl"
          fi
          first=0
          if [ "$p" -gt 0 ]; then
            body="${s:0:$p}"
            s="${s:$p}"
            if [ "$data" = 1 ]; then
              _gaia_va_lc_chars
              _gaia_va_make_run "$(( ${#body} - 1 ))"
              _gaia_va_lc_bytes
              out+="$_gaia_va_run$nl"
            else
              out+="$body"
            fi
          fi
          case "$s" in
            *"$nl"*) dline="${s%%"$nl"*}" ;;
            *) dline="$s" ;;
          esac
          out+="$dline"
          s="${s:${#dline}}"
          bi=$(( bi + 1 ))
          if [ "$bi" -lt "$hd_n" ]; then
            case "$s" in
              "$nl"*) s="${s:1}" ;;
              *) ok=0; break ;;
            esac
          fi
        done
        [ "$ok" = 1 ] || break
        hd_n=0
        hd_delim=()
        hd_strip=()
        line_start=${#out}
        wstart=1
        ;;
    esac
  done

  # A heredoc still pending at the end of the text has no body and no
  # delimiter line; an open span has no end. Both are the walk failing to
  # decide, which suppresses nothing.
  if [ "$ok" = 1 ] && [ -z "$q" ] && [ "$hd_n" -eq 0 ]; then
    # shellcheck disable=SC2034 # the view is this function's whole product; every reader is a consumer hook
    GAIA_VERB_ARM_VIEW="$out"
  fi
  _gaia_va_lc_chars
  return 0
}
