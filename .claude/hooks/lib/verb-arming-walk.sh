#!/usr/bin/env bash
# The data-proof walker behind the shared verb-arming decision, and the
# liveness scan after it (its own section below). Sourced by lib/verb-arming.sh,
# lazily, only once a raw arming match has already hit; sourced by nothing
# else. Does no work at source time.
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
# body is data when all of the following hold, the first six on its opener
# line and the seventh on the body itself:
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
#      a separator, and the shell runs what that second command is handed;
#   7. the body runs nothing: either the delimiter is quoted or escaped, which
#      turns substitution off, or the body carries no command-substitution
#      opener: no `$(` and no backtick.
#      With an unquoted delimiter the shell runs a command substitution inside
#      the body before `cat` ever sees it, so that body is not data.
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
#   - Quoted prose still over-arms. A quoted string carrying a list operator
#     or a newline before the verb arms every consumer. Fail-closed, and there
#     is no safe narrowing. A substitution opener there is the liveness scan's
#     question, not this walk's.
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
_GAIA_VA_BACKSLASH=$'\\'

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
_GAIA_VA_DOUBLE_QUOTE_SET=$'["\\\\]'
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
_GAIA_VA_MAXIMUM_WORK=2000000

# A `>` or `>>` redirect to a word. The leading exclusion is what keeps a file
# descriptor out: `2>err` redirects stderr and leaves the body on stdout, and
# `>&2` is a descriptor duplication with no file anywhere.
_GAIA_VA_REDIRECT_REGEX='(^|[^0-9&>])>>?[[:space:]]*[^[:space:]&<>|;]'
# A `tee` file operand: flags, then a word that is neither a flag nor a
# redirection. `tee <<EOF` and `tee -a <<EOF` name no file and fail it.
_GAIA_VA_TEE_REGEX='^[[:space:]]*tee([[:space:]]+-[^[:space:]]*)*[[:space:]]+[^-<>[:space:]]'

# The run of `x` every mask is filled from, grown on demand and reused for the
# life of the process. Taken from a doubling cache rather than from
# `${body//?/x}`, whose pattern substitution rescans the whole body per
# replacement and is quadratic in body length. ASCII, so its length is the same
# character count in every locale.
_gaia_va_xrun=x
_gaia_va_run=""
_gaia_va_delimiter_offset=-1
_gaia_va_locale_previous=""
_gaia_va_locale_was_set=""

_gaia_va_make_run() {
  local run_length="$1"
  [ "$run_length" -gt 0 ] || { _gaia_va_run=""; return 0; }
  while [ "${#_gaia_va_xrun}" -lt "$run_length" ]; do
    _gaia_va_xrun="$_gaia_va_xrun$_gaia_va_xrun"
  done
  _gaia_va_run="${_gaia_va_xrun:0:$run_length}"
}

# The scan runs under LC_ALL=C, where every offset and length is a byte. Every
# character it looks for is ASCII and a multibyte character's bytes are all
# non-ASCII, so byte offsets cut in the same places character offsets would.
# The mask run is the one quantity that cannot be sized that way, since the
# view's length contract is in characters, so the walk steps back into the
# caller's locale to measure each body and returns.
_gaia_va_locale_bytes() {
  _gaia_va_locale_was_set="${LC_ALL+set}"
  _gaia_va_locale_previous="${LC_ALL-}"
  LC_ALL=C
}

_gaia_va_locale_characters() {
  if [ "$_gaia_va_locale_was_set" = set ]; then LC_ALL="$_gaia_va_locale_previous"; else unset LC_ALL; fi
}

# _gaia_va_find_delimiter <text> <delimiter> <strip_tabs>: set _gaia_va_delimiter_offset to the offset in
# <text> at which the delimiter LINE begins, or return 1 when no such line
# exists. <strip_tabs> is 1 for the `<<-` form, whose delimiter line may carry
# leading tabs the shell removes.
_gaia_va_find_delimiter() {
  local search_text="$1" delimiter="$2" strip_tabs="$3"
  local newline=$'\n' prefix probe consumed line stripped_line
  _gaia_va_delimiter_offset=-1
  if [ "$strip_tabs" = 0 ]; then
    case "$search_text" in
      "$delimiter"|"$delimiter$newline"*) _gaia_va_delimiter_offset=0; return 0 ;;
    esac
    # One prefix strip locates the first delimiter line: `%%` removes the
    # longest suffix that matches, which is the one starting at the earliest
    # occurrence. Quoting the delimiter inside the pattern keeps a glob
    # character in it literal.
    prefix="${search_text%%"$newline$delimiter$newline"*}"
    if [ "${#prefix}" -ne "${#search_text}" ]; then _gaia_va_delimiter_offset=$(( ${#prefix} + 1 )); return 0; fi
    case "$search_text" in
      *"$newline$delimiter") _gaia_va_delimiter_offset=$(( ${#search_text} - ${#delimiter} )); return 0 ;;
    esac
    return 1
  fi
  # The `<<-` form needs the tabs stripped before the comparison, which no
  # single pattern expresses, so walk the lines.
  probe="$search_text"
  consumed=0
  while :; do
    case "$probe" in
      *"$newline"*) line="${probe%%"$newline"*}" ;;
      *) line="$probe" ;;
    esac
    stripped_line="$line"
    while :; do
      case "$stripped_line" in
        "$_GAIA_VA_TAB"*) stripped_line="${stripped_line#?}" ;;
        *) break ;;
      esac
    done
    if [ "$stripped_line" = "$delimiter" ]; then _gaia_va_delimiter_offset="$consumed"; return 0; fi
    case "$probe" in
      *"$newline"*) ;;
      *) return 1 ;;
    esac
    probe="${probe#*"$newline"}"
    consumed=$(( consumed + ${#line} + 1 ))
  done
}

# _gaia_va_opener_is_data <opener-line> <pre-operator-text>: 0 when the line
# meets every condition in the whitelist this file's header states, 1
# otherwise. Conditions 4 and 5 are decided where the delimiter is parsed and
# where its line is located; this decides 1, 2, 3 and 6.
_gaia_va_opener_is_data() {
  local line="$1" text_before_operator="$2"
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
  case "$text_before_operator" in
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
  [[ "$line" =~ $_GAIA_VA_REDIRECT_REGEX ]] && return 0
  case "$line" in
    'tee'*) [[ "$line" =~ $_GAIA_VA_TEE_REGEX ]] && return 0 ;;
  esac
  return 1
}

gaia_verb_arm_view() {
  local text="$1"
  GAIA_VERB_ARM_VIEW="$text"
  [ "${#text}" -le "${GAIA_VERB_ARM_MAXIMUM_CHARACTERS:-16384}" ] || return 0
  # No heredoc operator anywhere means no body can be proven data, and this is
  # the shape most raw-matching traffic takes, so it never pays for the walk.
  case "$text" in
    *'<<'*) ;;
    *) return 0 ;;
  esac

  local newline=$'\n'
  local remaining_text view_text opener_line quote_character character prefix prefix_length chunk blanks ok word_start work line_start
  local heredoc_count strip_tabs delimiter delimiter_unreadable delimiter_quoted data first delimiter_offset body delimiter_line body_index heredoc_prefix
  local heredoc_delimiters heredoc_strip_tabs heredoc_quoted
  heredoc_delimiters=()
  heredoc_strip_tabs=()
  heredoc_quoted=()

  _gaia_va_locale_bytes
  remaining_text="$text"
  view_text=""
  quote_character=""
  ok=1
  word_start=1
  work=0
  line_start=0
  heredoc_count=0
  heredoc_prefix=""

  while [ -n "$remaining_text" ]; do
    # Charge this step what it is about to cost, and abandon suppression on
    # running out, exactly as the walk does on anything else it cannot decide
    # cheaply.
    work=$(( work + ${#remaining_text} ))
    if [ "$work" -gt "$_GAIA_VA_MAXIMUM_WORK" ]; then ok=0; break; fi

    if [ -n "$quote_character" ]; then
      # Inside a quoted span, jump to what can end it. A single-quoted span and
      # a backtick span end only at their own delimiter; a double-quoted span
      # also has to honour the backslash, which escapes the character after it
      # there.
      if [ "$quote_character" = '"' ]; then
        # The set is a bracket expression, so it has to reach the matcher
        # UNQUOTED; quoting it would compare the brackets themselves.
        # shellcheck disable=SC2295
        prefix="${remaining_text%%$_GAIA_VA_DOUBLE_QUOTE_SET*}"
      else
        prefix="${remaining_text%%"$quote_character"*}"
      fi
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      # An empty character here means the strip found nothing, so the span runs
      # to the end of the text without closing.
      if [ -z "$character" ]; then ok=0; break; fi
      view_text+="$prefix$character"
      remaining_text="${remaining_text:$(( prefix_length + 1 ))}"
      if [ "$character" = "$_GAIA_VA_BACKSLASH" ]; then
        [ -n "$remaining_text" ] || { ok=0; break; }
        view_text+="${remaining_text:0:1}"
        remaining_text="${remaining_text:1}"
      else
        quote_character=""
      fi
      continue
    fi

    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${remaining_text%%$_GAIA_VA_TOP_SET*}"
    # Every expansion of the remaining text costs a pass over the whole of it,
    # so the strip's length is taken once and reused. Reading the character at
    # that offset also answers whether the strip found anything: past the end
    # of the text the slice is empty, which no real match can be.
    prefix_length=${#prefix}
    character="${remaining_text:$prefix_length:1}"
    if [ -z "$character" ]; then
      view_text+="$prefix"
      remaining_text=""
      break
    fi
    view_text+="$prefix"
    remaining_text="${remaining_text:$prefix_length}"
    case "$prefix" in
      '') ;;
      *$_GAIA_VA_WORD_SET) word_start=1 ;;
      *) word_start=0 ;;
    esac

    case "$character" in
      "'"|'"'|'`')
        quote_character="$character"
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        word_start=0
        ;;
      "$_GAIA_VA_BACKSLASH")
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ -z "$remaining_text" ]; then ok=0; break; fi
        character="${remaining_text:0:1}"
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        # A backslash-newline is a line CONTINUATION: the shell removes both
        # and the logical line runs on, so the newline that ends an opener line
        # is somewhere further down. Locating a body under that would mask
        # command text, so give up on the whole input instead.
        if [ "$character" = "$newline" ] && [ "$heredoc_count" -gt 0 ]; then ok=0; break; fi
        word_start=0
        ;;
      '$')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        case "$remaining_text" in "'"*) ok=0; break ;; esac
        word_start=0
        ;;
      '#')
        if [ "$word_start" = 1 ]; then
          case "$remaining_text" in
            *"$newline"*) prefix="${remaining_text%%"$newline"*}" ;;
            *) prefix="$remaining_text" ;;
          esac
          view_text+="$prefix"
          remaining_text="${remaining_text:${#prefix}}"
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
          word_start=0
        fi
        ;;
      '<')
        case "$remaining_text" in
          '<<<'*)
            # A herestring, not a heredoc: its word is on this line and no
            # following line is a body.
            view_text+='<<<'
            remaining_text="${remaining_text:3}"
            word_start=0
            ;;
          '<<'*)
            chunk='<<'
            remaining_text="${remaining_text:2}"
            strip_tabs=0
            case "$remaining_text" in '-'*) chunk="$chunk-"; remaining_text="${remaining_text:1}"; strip_tabs=1 ;; esac
            blanks=""
            # shellcheck disable=SC2295 # bracket expressions, matched as patterns
            case "$remaining_text" in
              $_GAIA_VA_BLANK_SET*) blanks="${remaining_text%%$_GAIA_VA_NONBLANK_SET*}" ;;
            esac
            if [ -n "$blanks" ]; then chunk="$chunk$blanks"; remaining_text="${remaining_text:${#blanks}}"; fi
            delimiter=""
            delimiter_unreadable=0
            delimiter_quoted=1
            case "$remaining_text" in
              "'"*)
                remaining_text="${remaining_text:1}"
                case "$remaining_text" in
                  *"'"*) delimiter="${remaining_text%%\'*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk'$delimiter'" ;;
                  *) delimiter_unreadable=1 ;;
                esac
                ;;
              '"'*)
                remaining_text="${remaining_text:1}"
                case "$remaining_text" in
                  *'"'*) delimiter="${remaining_text%%\"*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk\"$delimiter\"" ;;
                  *) delimiter_unreadable=1 ;;
                esac
                ;;
              "$_GAIA_VA_BACKSLASH"*)
                remaining_text="${remaining_text:1}"
                delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
                if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$_GAIA_VA_BACKSLASH$delimiter"; else delimiter_unreadable=1; fi
                ;;
              *)
                delimiter_quoted=0
                delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
                if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$delimiter"; else delimiter_unreadable=1; fi
                ;;
            esac
            if [ "$delimiter_unreadable" = 1 ]; then ok=0; break; fi
            # Condition 4: the delimiter has to be the whole word. Anything
            # abutting it is a spelling this walk cannot read exactly, and
            # reading it wrong puts the body's end in the wrong place.
            case "$remaining_text" in
              ''|' '*|"$_GAIA_VA_TAB"*|"$newline"*|';'*|'&'*|'|'*|'<'*|'>'*|')'*) ;;
              *) ok=0; break ;;
            esac
            # Condition 6's evidence, captured here because this is the only
            # point that knows where the operator sits: `view_text` still holds the
            # line up to it and nothing of it is masked yet. Only the first
            # operator on a line is recorded, which is the only one condition 6
            # is ever asked about.
            if [ "$heredoc_count" -eq 0 ]; then heredoc_prefix="${view_text:$line_start}"; fi
            view_text+="$chunk"
            heredoc_delimiters[heredoc_count]="$delimiter"
            heredoc_strip_tabs[heredoc_count]="$strip_tabs"
            heredoc_quoted[heredoc_count]="$delimiter_quoted"
            heredoc_count=$(( heredoc_count + 1 ))
            word_start=0
            ;;
          *)
            view_text+='<'
            remaining_text="${remaining_text:1}"
            word_start=0
            ;;
        esac
        ;;
      "$newline")
        if [ "$heredoc_count" -eq 0 ]; then
          view_text+="$newline"
          remaining_text="${remaining_text:1}"
          line_start=${#view_text}
          word_start=1
          continue
        fi
        # The opener line is read back out of the view rather than accumulated
        # alongside it: the accumulation costs an append per jump on every line
        # in the text, and only a line that turns out to carry an opener is ever
        # read. Nothing ahead of this point in the line is masked, so the slice
        # is the line's own bytes.
        opener_line="${view_text:$line_start}"
        # More than one heredoc on a line and the redirection that decides
        # where each body goes stops being readable from one opener, so none of
        # them is proven; their bodies are still skipped, just not masked.
        data=0
        if [ "$heredoc_count" -eq 1 ] && _gaia_va_opener_is_data "$opener_line" "$heredoc_prefix"; then data=1; fi
        remaining_text="${remaining_text:1}"
        first=1
        body_index=0
        while [ "$body_index" -lt "$heredoc_count" ]; do
          _gaia_va_find_delimiter "$remaining_text" "${heredoc_delimiters[$body_index]}" "${heredoc_strip_tabs[$body_index]}" || { ok=0; break; }
          delimiter_offset="$_gaia_va_delimiter_offset"
          # Condition 7, decided here because only now is the body's extent
          # known. Only the first heredoc can carry the proof, so only it is
          # asked. The needles are the command-substitution openers of
          # `separator_regex` in verb-arming.sh; an opener added there and missed here
          # is masked as data, which fails open.
          if [ "$first" = 1 ] && [ "$data" = 1 ] && [ "${heredoc_quoted[$body_index]}" = 0 ]; then
            # shellcheck disable=SC2016 # the literal opener is the needle
            case "${remaining_text:0:$delimiter_offset}" in
              *'$('*|*'`'*) data=0 ;;
            esac
          fi
          if [ "$first" = 1 ] && [ "$data" = 1 ] && [ "$delimiter_offset" -gt 0 ]; then
            view_text+=x
          else
            view_text+="$newline"
          fi
          first=0
          if [ "$delimiter_offset" -gt 0 ]; then
            body="${remaining_text:0:$delimiter_offset}"
            remaining_text="${remaining_text:$delimiter_offset}"
            if [ "$data" = 1 ]; then
              _gaia_va_locale_characters
              _gaia_va_make_run "$(( ${#body} - 1 ))"
              _gaia_va_locale_bytes
              view_text+="$_gaia_va_run$newline"
            else
              view_text+="$body"
            fi
          fi
          case "$remaining_text" in
            *"$newline"*) delimiter_line="${remaining_text%%"$newline"*}" ;;
            *) delimiter_line="$remaining_text" ;;
          esac
          view_text+="$delimiter_line"
          remaining_text="${remaining_text:${#delimiter_line}}"
          body_index=$(( body_index + 1 ))
          if [ "$body_index" -lt "$heredoc_count" ]; then
            case "$remaining_text" in
              "$newline"*) remaining_text="${remaining_text:1}" ;;
              *) ok=0; break ;;
            esac
          fi
        done
        [ "$ok" = 1 ] || break
        heredoc_count=0
        heredoc_delimiters=()
        heredoc_strip_tabs=()
        heredoc_quoted=()
        line_start=${#view_text}
        word_start=1
        ;;
    esac
  done

  # A heredoc still pending at the end of the text has no body and no
  # delimiter line; an open span has no end. Both are the walk failing to
  # decide, which suppresses nothing.
  if [ "$ok" = 1 ] && [ -z "$quote_character" ] && [ "$heredoc_count" -eq 0 ]; then
    # shellcheck disable=SC2034 # the view is this function's whole product; every reader is a consumer hook
    GAIA_VERB_ARM_VIEW="$view_text"
  fi
  _gaia_va_locale_characters
  return 0
}

# ---------------------------------------------------------------------------
# The liveness scan
# ---------------------------------------------------------------------------
#
#   gaia_verb_arm_live_view <text>
#
# ASSIGNS GAIA_VERB_ARM_LIVE: <text> with the first character of every
# substitution opener the parsing shell never runs overwritten by `x`. An
# opener that arms is one the shell runs, and textually `separator_regex` in
# lib/verb-arming.sh cannot tell those apart from one cited in prose, so the
# arming decision asks this view whether its opener survived. Same length, in
# bytes and so in characters, because every overwrite is one ASCII byte for
# another.
#
# DEAD, and nothing else:
#
#   - inside a single-quoted span, wherever single quotes quote: at top level
#     and inside a substitution, never inside double quotes, where an
#     apostrophe is an ordinary character;
#   - escaped by a backslash;
#   - inside the body of a heredoc whose delimiter is quoted or escaped, read
#     by a bare `cat` or `tee` (flags allowed, nothing else) at top level or
#     directly inside `$( )`, with nothing after the delimiter on the opener
#     line and no second heredoc on it. That is the shape a pull-request,
#     issue, or commit body takes when it is passed as
#     `--body "$(cat <<'EOF' ... EOF)"`. Inside `<( )` the body is handed to
#     whatever reads the file, often an interpreter, so it stays live.
#
# The openers are the ones `separator_regex` carries; one added there needs its first
# character in _GAIA_VA_LIVE_OPENER_SET, or it is never masked, which only
# over-arms.
#
# ABSTENTION IS WHOLE-INPUT, as in the walk above: an unterminated span, a
# dollar-quoted word, a `${` carrying anything but a plain name, a `)` in a
# context that holds the word `case` (a case arm's bare `)` would close the
# substitution early and desync every quote after it), a backslash before `$`,
# a backtick, or a backslash anywhere under backticks (the shell strips it
# before parsing the inner command, so the escape is gone), a backtick under
# backticks inside quotes, a comment, a heredoc body, or a nested substitution
# (bash closes the outer backquote there, zsh does not), a `#` straight after
# a subshell's `)` (a comment there, where after a substitution's `)` it
# continues the word), a `<<` inside parentheses (an arithmetic shift, or a
# heredoc feeding a subshell's output), a body inside `$( )` whose
# substitution bash 3.2's heredoc-blind paren matcher could close before the
# body ends (_gaia_va_b32_body_safe, read from each enclosing `$(`), a heredoc
# the text never closes, and running out of the re-reading budget all leave
# every opener live. Abstaining over-arms, which is today's answer; a wrong
# mask under-arms, which lets a merge past a gate.
#
# WHAT THIS DOES NOT CLOSE. The body of a quoted-delimiter heredoc read by
# `cat` is data to `cat`, not to whatever later executes the text cat
# produced: `eval`, `bash -c`, a pipe or here-string into an interpreter, or
# a file later sourced all run an opener in the body that this scan masks,
# the same nested-interpreter under-arm a quoted verb already has, and so
# does a `cat` or `tee` redefined earlier in the call (a function, an alias,
# a PATH entry), since the scan reads the name, not what it resolves to. Openers the shell never runs inside
# double quotes (`<(`, `>(`) stay live, as do openers in comments.

# Top level and inside a substitution: both quotes, a backslash, a backtick, a
# `$`, both parentheses, the first characters of the process-substitution
# openers, a `#`, the list operators, and a newline.
_GAIA_VA_LIVE_TOP_SET=$'["\047\\\\\140$()<>=#;&|\n]'
# Inside double quotes: the closing quote, a backslash, a backtick and a `$`.
_GAIA_VA_LIVE_DOUBLE_QUOTE_SET=$'["\\\\\140$]'
# The first characters an opener can begin with.
_GAIA_VA_LIVE_OPENER_SET=$'[\140$<>=]'
_GAIA_VA_LIVE_CASE_REGEX='(^|[^A-Za-z0-9_])case([^A-Za-z0-9_]|$)'
_GAIA_VA_LIVE_OWNER_REGEX='^[[:space:]]*(cat|tee)([[:space:]]+-[A-Za-z]+)*[[:space:]]*$'
_GAIA_VA_BLANK_LINE_REGEX='^[[:space:]]*$'

_gaia_va_live_work=0
_gaia_va_masked=""

# _gaia_va_mask_openers <span>: set _gaia_va_masked to <span> with every
# opener's first character overwritten. Charges the shared budget and returns
# 1 when it runs out.
_gaia_va_mask_openers() {
  local rest="$1" prefix prefix_length character next_character
  _gaia_va_masked=""
  while [ -n "$rest" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#rest} ))
    [ "$_gaia_va_live_work" -le "$_GAIA_VA_MAXIMUM_WORK" ] || return 1
    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${rest%%$_GAIA_VA_LIVE_OPENER_SET*}"
    prefix_length=${#prefix}
    character="${rest:$prefix_length:1}"
    if [ -z "$character" ]; then _gaia_va_masked+="$rest"; return 0; fi
    next_character="${rest:$(( prefix_length + 1 )):1}"
    _gaia_va_masked+="$prefix"
    # shellcheck disable=SC2016 # the literal openers are the patterns
    case "$character$next_character" in
      '`'*|'$('|'<('|'>(') _gaia_va_masked+=x ;;
      *) _gaia_va_masked+="$character" ;;
    esac
    rest="${rest:$(( prefix_length + 1 ))}"
  done
  return 0
}

# What bash 3.2's matcher stops on inside `$( )`: both quotes, a backtick, a
# backslash and both parentheses.
_GAIA_VA_B32_SET=$'["\047\140\\\\()]'

# _gaia_va_b32_body_safe <region> <after>: <region> runs from just past a
# `$(` through the end of a heredoc body inside it. 0 when bash 3.2 would
# read all of it as part of that substitution, 1 when it may close the
# substitution first. bash 3.2 finds that `)` with a paren-and-quote matcher
# that knows nothing of heredocs or comments, so an unmatched `)` anywhere in
# the region, counted outside quotes, ends the substitution there and
# everything after it runs as live text. A quote the region leaves open is safe only when
# nothing in <after> can close it: the matcher then reaches the end of the
# text, which is a syntax error, so nothing runs. A double-quoted or
# backticked span that nests anything, and a dollar-quoted span, are not
# modelled. Charges the shared
# budget.
_gaia_va_b32_body_safe() {
  local rest="$1" after="$2" prefix prefix_length character span depth=0
  while [ -n "$rest" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#rest} ))
    [ "$_gaia_va_live_work" -le "$_GAIA_VA_MAXIMUM_WORK" ] || return 1
    # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
    prefix="${rest%%$_GAIA_VA_B32_SET*}"
    prefix_length=${#prefix}
    character="${rest:$prefix_length:1}"
    [ -n "$character" ] || break
    rest="${rest:$(( prefix_length + 1 ))}"
    case "$character" in
      '(') depth=$(( depth + 1 )) ;;
      ')')
        depth=$(( depth - 1 ))
        [ "$depth" -ge 0 ] || return 1
        ;;
      "$_GAIA_VA_BACKSLASH") rest="${rest:1}" ;;
      *)
        case "$rest" in
          *"$character"*) ;;
          *)
            case "$after" in *"$character"*) return 1 ;; esac
            return 0
            ;;
        esac
        # A `$'` span honours backslash escapes, so its end is not the next
        # apostrophe. An escaped `$` was consumed above and never reaches
        # here.
        case "$character$prefix" in "'"*'$') return 1 ;; esac
        span="${rest%%"$character"*}"
        if [ "$character" != "'" ]; then
          case "$span" in *'$'*|*'`'*|*"$_GAIA_VA_BACKSLASH"*) return 1 ;; esac
        fi
        rest="${rest:$(( ${#span} + 1 ))}"
        ;;
    esac
  done
  [ "$depth" -eq 0 ]
}

gaia_verb_arm_live_view() {
  local text="$1"
  GAIA_VERB_ARM_LIVE="$text"
  [ "${#text}" -le "${GAIA_VERB_ARM_MAXIMUM_CHARACTERS:-16384}" ] || return 0

  local newline=$'\n'
  local remaining_text view_text ok word_start stack_top backtick_depth kind prefix prefix_length character next_character inner command_so_far rest dead
  local chunk strip_tabs blanks delimiter delimiter_unreadable delimiter_quoted heredoc_count heredoc_stack_top heredoc_owned heredoc_end body_index delimiter_offset body delimiter_line
  # The context stack. kind: T top level, S `$( )`, P `<( )` `>( )` `=( )`,
  # B backticks, D double quotes. parenthesis_depths counts bare parentheses, case_seen records the
  # word `case`, command_starts is the offset in `view_text` where the current command began,
  # and substitution_open_offsets, for an S frame, the offset just past its `$(`. Offsets in `view_text`
  # are offsets in <text>: the scan runs on bytes and masks one for one.
  local frame_kinds parenthesis_depths case_seen command_starts substitution_open_offsets heredoc_delimiters heredoc_strip_tabs heredoc_quoted frame_index
  frame_kinds=(T); parenthesis_depths=(0); case_seen=(0); command_starts=(0); substitution_open_offsets=(0)
  heredoc_delimiters=(); heredoc_strip_tabs=(); heredoc_quoted=()

  _gaia_va_locale_bytes
  remaining_text="$text"
  view_text=""
  ok=1
  word_start=1
  stack_top=0
  backtick_depth=0
  heredoc_count=0
  heredoc_stack_top=0
  heredoc_owned=0
  heredoc_end=0
  _gaia_va_live_work=0

  while [ -n "$remaining_text" ]; do
    _gaia_va_live_work=$(( _gaia_va_live_work + ${#remaining_text} ))
    if [ "$_gaia_va_live_work" -gt "$_GAIA_VA_MAXIMUM_WORK" ]; then ok=0; break; fi
    kind="${frame_kinds[$stack_top]}"

    if [ "$kind" = D ]; then
      # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
      prefix="${remaining_text%%$_GAIA_VA_LIVE_DOUBLE_QUOTE_SET*}"
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      if [ -z "$character" ]; then ok=0; break; fi
      view_text+="$prefix"
      remaining_text="${remaining_text:$prefix_length}"
    else
      # shellcheck disable=SC2295 # a bracket expression, matched as a pattern
      prefix="${remaining_text%%$_GAIA_VA_LIVE_TOP_SET*}"
      prefix_length=${#prefix}
      character="${remaining_text:$prefix_length:1}"
      if [ -z "$character" ]; then view_text+="$remaining_text"; remaining_text=""; break; fi
      view_text+="$prefix"
      remaining_text="${remaining_text:$prefix_length}"
      if [ -n "$prefix" ]; then
        [[ "$prefix" =~ $_GAIA_VA_LIVE_CASE_REGEX ]] && case_seen[stack_top]=1
        case "$prefix" in
          *$_GAIA_VA_WORD_SET) word_start=1 ;;
          *) word_start=0 ;;
        esac
      fi
    fi
    next_character="${remaining_text:1:1}"

    case "$character" in
      '"')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "$kind" = D ]; then
          stack_top=$(( stack_top - 1 ))
        else
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=D; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
        fi
        word_start=0
        ;;
      "'")
        # Only reachable outside double quotes: the double-quote set holds no
        # apostrophe.
        remaining_text="${remaining_text:1}"
        case "$remaining_text" in
          *"'"*) ;;
          *) ok=0; break ;;
        esac
        inner="${remaining_text%%\'*}"
        # bash ends a backquote at its first unescaped backtick, quoted or not.
        if [ "$backtick_depth" -gt 0 ]; then
          case "$inner" in *'`'*) ok=0; break ;; esac
        fi
        _gaia_va_mask_openers "$inner" || { ok=0; break; }
        view_text+="'$_gaia_va_masked'"
        remaining_text="${remaining_text:$(( ${#inner} + 1 ))}"
        word_start=0
        ;;
      "$_GAIA_VA_BACKSLASH")
        view_text+="$character"
        if [ -z "$next_character" ]; then ok=0; break; fi
        # Under backticks, in any context down to the innermost, the shell
        # strips the backslash from `\$`, `` \` `` and `\\` before parsing the
        # inner command, so the escape it seems to make is gone by then.
        if [ "$backtick_depth" -gt 0 ]; then
          case "$next_character" in
            '$'|'`'|"$_GAIA_VA_BACKSLASH") ok=0; break ;;
          esac
        fi
        # A line continuation moves the newline that ends a heredoc opener.
        if [ "$next_character" = "$newline" ] && [ "$heredoc_count" -gt 0 ]; then ok=0; break; fi
        case "$next_character" in
          '$'|'`'|'<'|'>'|'=') view_text+=x ;;
          *) view_text+="$next_character" ;;
        esac
        remaining_text="${remaining_text:2}"
        word_start=0
        ;;
      '`')
        # Under backticks, bash closes the outer backquote here even from
        # inside double quotes or a nested `$( )`, where zsh opens a new one.
        if [ "$backtick_depth" -gt 0 ] && [ "$kind" != B ]; then ok=0; break; fi
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "$kind" = B ]; then
          stack_top=$(( stack_top - 1 ))
          backtick_depth=$(( backtick_depth - 1 ))
          word_start=0
        else
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=B; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
          backtick_depth=$(( backtick_depth + 1 ))
          word_start=1
        fi
        ;;
      '$')
        case "$next_character" in
          '(')
            # shellcheck disable=SC2016 # the literal opener, copied through
            view_text+='$('
            remaining_text="${remaining_text:2}"
            stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=S; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
            substitution_open_offsets[stack_top]=${#view_text}
            word_start=1
            ;;
          "'")
            # A dollar-quoted word, except inside double quotes, where the
            # apostrophe is ordinary.
            if [ "$kind" != D ]; then ok=0; break; fi
            view_text+='$'
            remaining_text="${remaining_text:1}"
            ;;
          '{')
            rest="${remaining_text:2}"
            case "$rest" in
              *'}'*) ;;
              *) ok=0; break ;;
            esac
            inner="${rest%%\}*}"
            # A plain parameter expansion is skipped whole. Anything that can
            # nest, quote, or run a command inside the braces is not modelled,
            # and that includes bash 5.3's `${ ` and `${|`.
            case "$inner" in
              ''|[[:space:]]*|'|'*|*[\"\'\`\$\(\{\\]*|*"$newline"*) ok=0; break ;;
            esac
            view_text+="\${$inner}"
            remaining_text="${remaining_text:$(( ${#inner} + 3 ))}"
            word_start=0
            ;;
          *)
            view_text+='$'
            remaining_text="${remaining_text:1}"
            word_start=0
            ;;
        esac
        ;;
      '(')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        parenthesis_depths[stack_top]=$(( ${parenthesis_depths[$stack_top]} + 1 ))
        command_starts[stack_top]=${#view_text}
        word_start=1
        ;;
      ')')
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        if [ "${case_seen[$stack_top]}" = 1 ]; then ok=0; break; fi
        if [ "${parenthesis_depths[$stack_top]}" -gt 0 ]; then
          parenthesis_depths[stack_top]=$(( ${parenthesis_depths[$stack_top]} - 1 ))
          # A subshell's `)` is an operator, so a `#` right after it opens a
          # comment, where after a substitution's `)` it continues the word.
          # Rather than model which `(` this closes, stop.
          case "$remaining_text" in '#'*) ok=0; break ;; esac
        elif [ "$kind" = S ] || [ "$kind" = P ]; then
          stack_top=$(( stack_top - 1 ))
        else
          ok=0; break
        fi
        word_start=0
        ;;
      '<'|'>'|'=')
        if [ "$next_character" = '(' ]; then
          view_text+="$character("
          remaining_text="${remaining_text:2}"
          stack_top=$(( stack_top + 1 )); frame_kinds[stack_top]=P; parenthesis_depths[stack_top]=0; case_seen[stack_top]=0; command_starts[stack_top]=${#view_text}
          word_start=1
        elif [ "$character" = '<' ] && [ "${remaining_text:0:3}" = '<<<' ]; then
          view_text+='<<<'
          remaining_text="${remaining_text:3}"
          word_start=0
        elif [ "$character" = '<' ] && [ "$next_character" = '<' ]; then
          # Inside parentheses `<<` may be an arithmetic shift, and a heredoc
          # in a subshell can feed whatever reads the subshell's output.
          if [ "${parenthesis_depths[$stack_top]}" -gt 0 ]; then ok=0; break; fi
          # The delimiter is read exactly as the walk above reads it.
          command_so_far="${view_text:${command_starts[$stack_top]}}"
          chunk='<<'
          remaining_text="${remaining_text:2}"
          strip_tabs=0
          case "$remaining_text" in '-'*) chunk="$chunk-"; remaining_text="${remaining_text:1}"; strip_tabs=1 ;; esac
          blanks=""
          # shellcheck disable=SC2295 # bracket expressions, matched as patterns
          case "$remaining_text" in
            $_GAIA_VA_BLANK_SET*) blanks="${remaining_text%%$_GAIA_VA_NONBLANK_SET*}" ;;
          esac
          if [ -n "$blanks" ]; then chunk="$chunk$blanks"; remaining_text="${remaining_text:${#blanks}}"; fi
          delimiter=""
          delimiter_unreadable=0
          delimiter_quoted=1
          case "$remaining_text" in
            "'"*)
              remaining_text="${remaining_text:1}"
              case "$remaining_text" in
                *"'"*) delimiter="${remaining_text%%\'*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk'$delimiter'" ;;
                *) delimiter_unreadable=1 ;;
              esac
              ;;
            '"'*)
              remaining_text="${remaining_text:1}"
              case "$remaining_text" in
                *'"'*) delimiter="${remaining_text%%\"*}"; remaining_text="${remaining_text:$(( ${#delimiter} + 1 ))}"; chunk="$chunk\"$delimiter\"" ;;
                *) delimiter_unreadable=1 ;;
              esac
              ;;
            "$_GAIA_VA_BACKSLASH"*)
              remaining_text="${remaining_text:1}"
              delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
              if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$_GAIA_VA_BACKSLASH$delimiter"; else delimiter_unreadable=1; fi
              ;;
            *)
              delimiter_quoted=0
              delimiter="${remaining_text%%[!A-Za-z0-9_.-]*}"
              if [ -n "$delimiter" ]; then remaining_text="${remaining_text:${#delimiter}}"; chunk="$chunk$delimiter"; else delimiter_unreadable=1; fi
              ;;
          esac
          if [ "$delimiter_unreadable" = 1 ]; then ok=0; break; fi
          case "$remaining_text" in
            ''|' '*|"$_GAIA_VA_TAB"*|"$newline"*|';'*|'&'*|'|'*|'<'*|'>'*|')'*) ;;
            *) ok=0; break ;;
          esac
          if [ "$heredoc_count" -eq 0 ]; then
            heredoc_stack_top=$stack_top
            heredoc_owned=0
            if [ "$kind" = T ] || [ "$kind" = S ]; then
              [[ "$command_so_far" =~ $_GAIA_VA_LIVE_OWNER_REGEX ]] && heredoc_owned=1
            fi
          elif [ "$stack_top" -ne "$heredoc_stack_top" ]; then
            ok=0; break
          fi
          view_text+="$chunk"
          heredoc_delimiters[heredoc_count]="$delimiter"
          heredoc_strip_tabs[heredoc_count]="$strip_tabs"
          heredoc_quoted[heredoc_count]="$delimiter_quoted"
          heredoc_count=$(( heredoc_count + 1 ))
          [ "$heredoc_count" -eq 1 ] && heredoc_end=${#view_text}
          word_start=0
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
          word_start=0
        fi
        ;;
      '#')
        if [ "$word_start" = 1 ]; then
          case "$remaining_text" in
            *"$newline"*) prefix="${remaining_text%%"$newline"*}" ;;
            *) prefix="$remaining_text" ;;
          esac
          if [ "$backtick_depth" -gt 0 ]; then
            case "$prefix" in *'`'*) ok=0; break ;; esac
          fi
          view_text+="$prefix"
          remaining_text="${remaining_text:${#prefix}}"
        else
          view_text+="$character"
          remaining_text="${remaining_text:1}"
        fi
        ;;
      ';'|'&'|'|')
        # After `>` or `<` this completes a redirection operator (`>&`, `<&`,
        # `>|`) rather than ending the command, and the word after it is a
        # file, never the command a heredoc belongs to.
        case "$view_text" in
          *'>'|*'<') ;;
          *) command_starts[stack_top]=$(( ${#view_text} + 1 )) ;;
        esac
        view_text+="$character"
        remaining_text="${remaining_text:1}"
        word_start=1
        ;;
      "$newline")
        if [ "$heredoc_count" -eq 0 ]; then
          view_text+="$newline"
          remaining_text="${remaining_text:1}"
          command_starts[stack_top]=${#view_text}
          word_start=1
          continue
        fi
        # The bodies begin here, in the context their operators stood in.
        if [ "$stack_top" -ne "$heredoc_stack_top" ]; then ok=0; break; fi
        dead=0
        if [ "$heredoc_count" -eq 1 ] && [ "$heredoc_owned" = 1 ] && [ "${heredoc_quoted[0]}" = 1 ] \
           && [[ "${view_text:$heredoc_end}" =~ $_GAIA_VA_BLANK_LINE_REGEX ]]; then
          dead=1
        fi
        view_text+="$newline"
        remaining_text="${remaining_text:1}"
        body_index=0
        while [ "$body_index" -lt "$heredoc_count" ]; do
          _gaia_va_find_delimiter "$remaining_text" "${heredoc_delimiters[$body_index]}" "${heredoc_strip_tabs[$body_index]}" || { ok=0; break; }
          delimiter_offset="$_gaia_va_delimiter_offset"
          body="${remaining_text:0:$delimiter_offset}"
          remaining_text="${remaining_text:$delimiter_offset}"
          if [ "$backtick_depth" -gt 0 ]; then
            case "$body" in *'`'*) ok=0; break ;; esac
          fi
          # bash 3.2's matcher starts at each enclosing `$(`, not at the body,
          # so it reads everything from there on: earlier bodies, comments and
          # delimiter lines included.
          if [ "$dead" = 1 ]; then
            frame_index=0
            while [ "$frame_index" -le "$heredoc_stack_top" ]; do
              if [ "${frame_kinds[$frame_index]}" = S ]; then
                _gaia_va_b32_body_safe "${text:${substitution_open_offsets[$frame_index]}:$(( ${#view_text} - ${substitution_open_offsets[$frame_index]} ))}$body" "$remaining_text" || { ok=0; break; }
              fi
              frame_index=$(( frame_index + 1 ))
            done
            [ "$ok" = 1 ] || break
          fi
          if [ "$dead" = 1 ]; then
            _gaia_va_mask_openers "$body" || { ok=0; break; }
            view_text+="$_gaia_va_masked"
          else
            view_text+="$body"
          fi
          case "$remaining_text" in
            *"$newline"*) delimiter_line="${remaining_text%%"$newline"*}" ;;
            *) delimiter_line="$remaining_text" ;;
          esac
          view_text+="$delimiter_line"
          remaining_text="${remaining_text:${#delimiter_line}}"
          body_index=$(( body_index + 1 ))
          if [ "$body_index" -lt "$heredoc_count" ]; then
            case "$remaining_text" in
              "$newline"*) view_text+="$newline"; remaining_text="${remaining_text:1}" ;;
              *) ok=0; break ;;
            esac
          fi
        done
        [ "$ok" = 1 ] || break
        heredoc_count=0
        heredoc_delimiters=(); heredoc_strip_tabs=(); heredoc_quoted=()
        command_starts[stack_top]=${#view_text}
        word_start=1
        ;;
    esac
  done

  # Anything still open at the end is the scan failing to decide, which masks
  # nothing.
  if [ "$ok" = 1 ] && [ "$stack_top" -eq 0 ] && [ "$heredoc_count" -eq 0 ]; then
    # shellcheck disable=SC2034 # read by lib/verb-arming.sh
    GAIA_VERB_ARM_LIVE="$view_text"
  fi
  _gaia_va_locale_characters
  return 0
}
