#!/usr/bin/env bash
# Shared reader-operand extraction for the two read-side secret guards.
#
# Sourced by .claude/hooks/block-env-read.sh and
# .claude/hooks/block-secrets-read.sh. Does no work at source time.
#
# Both guards ask one question of a Bash command segment, "which tokens in it
# name or select a file that a reader will open?", and differ only in the
# predicate they then apply to the answer. This library owns the question; each hook owns its
# own answer. Splitting it this way is what keeps the grep arm below written
# once: it is the only part of either guard that needs real argument grammar,
# and a second hand-rolled copy of it would drift.
#
#   gaia_reader_operands <segment-text>
#
# Prints, one per line, every token in one already-split command segment that a
# recognized reader would open. Prints nothing when the segment's command word
# is not a reader and the segment carries no read redirect. Callers split the
# full command into segments themselves, because the two hooks disagree about
# what else a segment means: only the dotenv guard treats a bare `env` as a
# process-environment dump, and that judgement is not this library's.
#
# WHY grep NEEDS ITS OWN ARM. In `grep PATTERN FILE` the first operand is a
# pattern, not a path. The blanket "every token is a candidate" treatment the
# other readers get would therefore deny `grep '.env' .gitignore`: a search of a
# committed file for a string that merely LOOKS like a dotenv name. That command
# is the reason grep sat outside the recognized-reader set until now, and the
# arm below is what lets it come in. It skips the pattern operand, and skips the
# values of the flags that carry one.
#
# The filter flags that SELECT which files a recursive search reads (--include,
# and ripgrep's --glob, --iglob and -g) are emitted too, because
# `rg -g '*.key' TOKEN` reads every key file as surely as naming one would, and
# the Grep tool arm already denies the same filter given as its `glob`. Their
# value is a glob rather than a path, so the predicate catches the literal
# shapes (`*.key`, `.env*`) and not every glob that could expand onto one; each
# hook's HONEST LIMITS names what gets through. The value is split on commas and
# each element judged alone, because the ugrep that Claude Code's own shell runs
# as `grep` reads it as a list (`-g '!*.md,*.key'` still searches key files). A
# comma inside a ripgrep brace glob splits into fragments that match nothing,
# the brace-glob pass the limits already name. An element with a leading `!` is
# dropped, and so is one with a leading `^`: ripgrep reads `!` as an EXCLUSION
# and ugrep reads both that way, so judging them would deny a search for
# steering clear of the class. GNU and BSD grep take both characters literally,
# which leaves a file whose name really begins with one unjudged on those two.
# The flags that only ever exclude (--exclude, --exclude-dir) stay discarded.
#
# The flag tables are the UNION of GNU grep's and ripgrep's, deliberately, and
# the union is safe ONLY because no discard-listed flag is value-less for either
# tool. That condition is the whole of it, so state what breaks without it: a
# discard-listed flag that takes no value for the tool actually invoked consumes
# the PATTERN as its value. The next token then becomes the first positional and
# is consumed as the pattern in turn, so the real file operand is never reached
# and the walk emits NOTHING. That is a silent allow, not the extra-operand
# over-deny a union is often assumed to degrade into, so a value-less collision
# fails the guard open in exactly the case it exists to catch.
#
# Three collisions were found that way and are deliberately NOT discard-listed:
# -r (GNU --recursive, value-less; ripgrep --replace, value-taking), -T (GNU
# --initial-tab, value-less; ripgrep --type-not, value-taking), and the bare
# --color / --colour spelling (optional-value for GNU, value-taking for
# ripgrep). Leaving them out costs an over-read on ripgrep's spelling, where the
# replacement text is taken as the pattern and the real pattern is emitted as an
# operand. That is the fail-CLOSED direction: an extra candidate can only ever
# add a deny, and it denies only if the pattern text itself looks like a secret
# path. --colors (plural, ripgrep-only) keeps its entry because no GNU spelling
# collides with it, and the --color=auto form is unaffected either way because
# the `=` split supplies its own value and never reaches for the next token.
#
# ADDING A FLAG: check it against BOTH tools first. Value-taking in both, or
# absent from one, is safe to discard-list. Value-less or optional-value in
# either is not, and belongs in the exception list above instead.

# Readers whose every argument is a candidate path. This is the historical set
# from block-env-read.sh, unchanged: `awk` and `perl` take a PROGRAM as their
# first operand much as grep takes a pattern, but they have always been scanned
# whole, and narrowing them here would loosen a guard while claiming to refactor
# it. The grep family is handled separately below.
_GAIA_RO_PLAIN_READERS='cat head tail sed xxd od hexdump strings nl less more diff cut tac paste awk perl source .'

# The grep family: pattern-first grammar, handled by _gaia_ro_grep_operands.
_GAIA_RO_GREP_READERS='grep egrep fgrep rgrep rg'

# Short flags that take a value which is NOT a file to open (a pattern, a count,
# a type name, a replacement, or a file of patterns/globs grep reads itself but
# whose own content this walk does not treat as a candidate). The value is
# discarded.
_GAIA_RO_SHORT_DISCARD='emABCDdtf'

# Short and long flags whose value is a glob selecting the files a search reads.
# Each non-negated element of the value is emitted. Not a closed set of every
# way to select files: ripgrep's --type-add definitions and ugrep's extension
# filters select too, and each hook's HONEST LIMITS names them as open.
_GAIA_RO_SHORT_SELECT='g'
_GAIA_RO_LONG_SELECT='--include --glob --iglob'

# Long flags that take a value which is not a file to open (a pattern, a count,
# a type name, a replacement, or a file of patterns/globs grep reads itself but
# whose own content this walk does not treat as a candidate). Matched with or
# without `=`. --file supplies the pattern the same way -e/--regexp does, so a
# positional after it is still a file operand; --exclude-from and
# --ignore-file supply nothing, so a positional after either is still the
# pattern.
_GAIA_RO_LONG_DISCARD='--regexp --file --exclude-from --ignore-file --max-count --after-context --before-context --context --binary-files --devices --directories --label --exclude --exclude-dir --group-separator --colors --type --type-not --type-add --replace --pre --sort --sortr --context-separator --path-separator --field-match-separator --encoding --engine --dfa-size-limit --regex-size-limit --max-columns --max-depth --max-filesize --threads'

# Strip one matching pair of surrounding quotes from a token. PUBLIC, under the
# gaia_reader_ prefix: both hooks call it for the tokens they read straight off
# the payload, so a token reaches the predicate in the same shape whichever arm
# produced it. It is one definition rather than three because a correction here
# (escaped quotes, a backtick pair, nesting) has to reach every caller, and a
# copy nobody remembers to edit diverges with no test going red.
gaia_reader_strip_quotes() {
  local token="$1"
  case "$token" in
    \"*\") token=${token#\"}; token=${token%\"} ;;
    \'*\') token=${token#\'}; token=${token%\'} ;;
  esac
  printf '%s' "$token"
}

_gaia_ro_in_list() {
  local needle="$1" list="$2" item
  for item in $list; do
    if [ "$item" = "$needle" ]; then return 0; fi
  done
  return 1
}

# Emit one operand. An empty token is dropped rather than printed as a blank
# line, so a caller can read the output with a plain line loop and never have to
# re-check for emptiness that this function already ruled out.
_gaia_ro_emit() {
  local operand
  operand=$(gaia_reader_strip_quotes "$1")
  if [ -n "$operand" ]; then printf '%s\n' "$operand"; fi
}

# Emit each element of a select flag's comma-separated glob list, skipping the
# negated ones.
_gaia_ro_emit_select() {
  local glob_list glob_element
  local parts=()
  glob_list=$(gaia_reader_strip_quotes "$1")
  # An empty array expands as unbound under bash 3.2 with set -u.
  [ -n "$glob_list" ] || return 0
  # read -a rather than an unquoted IFS split, which would also pathname-expand
  # a glob element against the working directory.
  IFS=',' read -r -a parts <<<"$glob_list"
  for glob_element in ${parts[@]+"${parts[@]}"}; do
    case "$glob_element" in
      '!'* | '^'*) ;;
      *) _gaia_ro_emit "$glob_element" ;;
    esac
  done
}

# Emit the file operands of a grep-family invocation. Arguments are the tokens
# AFTER the command word.
_gaia_ro_grep_operands() {
  local tokens=("$@")
  local token_count=${#tokens[@]}
  local i=0
  # pending is the disposition of a value the previous flag expects in the NEXT
  # token: "select" to emit it unless negated, "discard" to drop it, empty for
  # neither.
  local pending=''
  # Set once -e/-f/--regexp/--file has supplied the pattern, which is what makes
  # the first positional operand a FILE rather than the pattern.
  local pattern_flagged=1
  local pattern_taken=1
  local end_of_flags=1
  local token name flag_value rest flag_character j

  while [ "$i" -lt "$token_count" ]; do
    token="${tokens[$i]}"
    i=$((i + 1))

    if [ -n "$pending" ]; then
      if [ "$pending" = 'select' ]; then _gaia_ro_emit_select "$token"; fi
      pending=''
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "$token" = '--' ]; then
      end_of_flags=0
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "${token#--}" != "$token" ]; then
      name="${token%%=*}"
      flag_value=''
      if [ "$name" != "$token" ]; then flag_value="${token#*=}"; fi
      if _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_SELECT"; then
        if [ -n "$flag_value" ]; then
          _gaia_ro_emit_select "$flag_value"
        else
          pending='select'
        fi
      elif _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_DISCARD"; then
        if [ "$name" = '--regexp' ] || [ "$name" = '--file' ]; then pattern_flagged=0; fi
        if [ -z "$flag_value" ]; then pending='discard'; fi
      fi
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "${token#-}" != "$token" ] && [ "$token" != '-' ]; then
      j=1
      while [ "$j" -lt "${#token}" ]; do
        flag_character="${token:$j:1}"
        rest="${token:$((j + 1))}"
        if [ "$_GAIA_RO_SHORT_SELECT" != "${_GAIA_RO_SHORT_SELECT/$flag_character/}" ]; then
          if [ -n "$rest" ]; then
            _gaia_ro_emit_select "$rest"
          else
            pending='select'
          fi
          break
        fi
        if [ "$_GAIA_RO_SHORT_DISCARD" != "${_GAIA_RO_SHORT_DISCARD/$flag_character/}" ]; then
          if [ "$flag_character" = 'e' ] || [ "$flag_character" = 'f' ]; then pattern_flagged=0; fi
          if [ -z "$rest" ]; then pending='discard'; fi
          break
        fi
        j=$((j + 1))
      done
      continue
    fi

    # A positional operand. The first one is the pattern unless a flag already
    # supplied it.
    if [ "$pattern_flagged" -ne 0 ] && [ "$pattern_taken" -ne 0 ]; then
      pattern_taken=0
      continue
    fi
    _gaia_ro_emit "$token"
  done
}

# Redirection FROM a path: `< <path>` or `$(< <path>)`. Applies regardless of
# command word, since the target may be a bare assignment (`x=$(<f)`) with no
# recognizable command word at all.
_gaia_ro_redirect_operand() {
  local segment="$1" rest candidate
  case "$segment" in
    *'<'*) : ;;
    *) return 0 ;;
  esac
  rest=$(printf '%s' "$segment" | sed -E 's/^.*<[[:space:]]*//')
  candidate=$(printf '%s' "$rest" | sed -E 's/[[:space:])].*$//')
  if [ -n "$candidate" ]; then _gaia_ro_emit "$candidate"; fi
  return 0
}

# Strip leading NAME=value assignments so the real command word is exposed.
gaia_reader_strip_env_prefix() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//'
}

# Dispatch on a token list whose first element is the command word.
_gaia_ro_dispatch() {
  local tokens=("$@")
  local command_word token

  [ "${#tokens[@]}" -gt 0 ] || return 0
  command_word=$(gaia_reader_strip_quotes "${tokens[0]}")

  if _gaia_ro_in_list "$command_word" "$_GAIA_RO_GREP_READERS"; then
    _gaia_ro_grep_operands "${tokens[@]:1}"
  elif _gaia_ro_in_list "$command_word" "$_GAIA_RO_PLAIN_READERS"; then
    for token in "${tokens[@]:1}"; do
      _gaia_ro_emit "$token"
    done
  fi
  return 0
}

gaia_reader_operands() {
  local segment="$1"
  local segment_command
  local tokens

  segment_command=$(gaia_reader_strip_env_prefix "$segment")
  read -r -a tokens <<<"$segment_command"

  if [ "${#tokens[@]}" -gt 0 ]; then
    _gaia_ro_dispatch ${tokens[@]+"${tokens[@]}"}
  fi

  _gaia_ro_redirect_operand "$segment"
}
