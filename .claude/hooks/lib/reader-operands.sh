#!/usr/bin/env bash
# Shared reader-operand extraction for the two read-side secret guards.
#
# Sourced by .claude/hooks/block-env-read.sh and
# .claude/hooks/block-secrets-read.sh. Does no work at source time.
#
# Both guards ask one question of a Bash command segment, "which tokens in it
# name a file that a reader will open?", and differ only in the predicate they
# then apply to the answer. This library owns the question; each hook owns its
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
# Three flags are the exception that proves the rule: -f / --file name a file of
# patterns, and --exclude-from / --ignore-file name a file of globs. Those
# values ARE opened by grep itself, so they are emitted as operands rather than
# discarded. `grep -f <secret> .` reads the secret exactly as `grep x <secret>`
# does, and only this arm can tell the difference.
#
# The flag tables are the UNION of GNU grep's and ripgrep's, deliberately. A
# union misreads a flag only in the direction of consuming one extra token, and
# the two tools' letters do not collide on any flag where that matters. Keeping
# one table beats keeping two that must be diffed against each other by hand.

# Readers whose every argument is a candidate path. This is the historical set
# from block-env-read.sh, unchanged: `awk` and `perl` take a PROGRAM as their
# first operand much as grep takes a pattern, but they have always been scanned
# whole, and narrowing them here would loosen a guard while claiming to refactor
# it. The grep family is handled separately below.
_GAIA_RO_PLAIN_READERS='cat head tail sed xxd od hexdump strings nl less more diff cut tac paste awk perl source .'

# The grep family: pattern-first grammar, handled by _gaia_ro_grep_operands.
_GAIA_RO_GREP_READERS='grep egrep fgrep rgrep rg'

# Short flags that take a value which is NOT a file to open (a pattern, a count,
# a type name, a replacement). The value is discarded.
_GAIA_RO_SHORT_DISCARD='emABCDdtTrg'

# Short flags whose value IS a file grep opens. Emitted as an operand.
_GAIA_RO_SHORT_FILE='f'

# Long flags that take a value which is not a file. Matched with or without `=`.
_GAIA_RO_LONG_DISCARD='--regexp --max-count --after-context --before-context --context --binary-files --devices --directories --label --include --exclude --exclude-dir --group-separator --colors --color --colour --type --type-not --type-add --glob --iglob --replace --pre --sort --sortr --context-separator --path-separator --field-match-separator --encoding --engine --dfa-size-limit --regex-size-limit --max-columns --max-depth --max-filesize --threads'

# Long flags whose value IS a file grep opens. Split by whether the flag also
# SUPPLIES THE PATTERN, because that is what decides whether the next positional
# operand is a file or the pattern. --file does supply it; --exclude-from and
# --ignore-file name a file of globs and supply nothing, so a positional after
# either is still the pattern.
_GAIA_RO_LONG_FILE_PATTERN='--file'
_GAIA_RO_LONG_FILE_PLAIN='--exclude-from --ignore-file'

# Strip one matching pair of surrounding quotes from a token. Mirrors the
# helper the hooks already carry, so a token reaches the predicate in the same
# shape whichever arm produced it.
_gaia_ro_strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
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
  local v
  v=$(_gaia_ro_strip_quotes "$1")
  if [ -n "$v" ]; then printf '%s\n' "$v"; fi
}

# Emit the file operands of a grep-family invocation. Arguments are the tokens
# AFTER the command word.
_gaia_ro_grep_operands() {
  local toks=("$@")
  local n=${#toks[@]}
  local i=0
  # pending is the disposition of a value the previous flag expects in the NEXT
  # token: "file" to emit it, "discard" to drop it, empty for neither.
  local pending=''
  # Set once -e/-f/--regexp/--file has supplied the pattern, which is what makes
  # the first positional operand a FILE rather than the pattern.
  local pattern_flagged=1
  local pattern_taken=1
  local end_of_flags=1
  local t name val rest c j

  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    i=$((i + 1))

    if [ -n "$pending" ]; then
      if [ "$pending" = 'file' ]; then _gaia_ro_emit "$t"; fi
      pending=''
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "$t" = '--' ]; then
      end_of_flags=0
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "${t#--}" != "$t" ]; then
      name="${t%%=*}"
      val=''
      if [ "$name" != "$t" ]; then val="${t#*=}"; fi
      if _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_FILE_PATTERN" \
        || _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_FILE_PLAIN"; then
        if _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_FILE_PATTERN"; then
          pattern_flagged=0
        fi
        if [ -n "$val" ]; then
          _gaia_ro_emit "$val"
        else
          pending='file'
        fi
      elif _gaia_ro_in_list "$name" "$_GAIA_RO_LONG_DISCARD"; then
        if [ "$name" = '--regexp' ]; then pattern_flagged=0; fi
        if [ -z "$val" ]; then pending='discard'; fi
      fi
      continue
    fi

    if [ "$end_of_flags" -ne 0 ] && [ "${t#-}" != "$t" ] && [ "$t" != '-' ]; then
      j=1
      while [ "$j" -lt "${#t}" ]; do
        c="${t:$j:1}"
        rest="${t:$((j + 1))}"
        if [ "$_GAIA_RO_SHORT_FILE" != "${_GAIA_RO_SHORT_FILE/$c/}" ]; then
          pattern_flagged=0
          if [ -n "$rest" ]; then
            _gaia_ro_emit "$rest"
          else
            pending='file'
          fi
          break
        fi
        if [ "$_GAIA_RO_SHORT_DISCARD" != "${_GAIA_RO_SHORT_DISCARD/$c/}" ]; then
          if [ "$c" = 'e' ]; then pattern_flagged=0; fi
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
    _gaia_ro_emit "$t"
  done
}

# Redirection FROM a path: `< <path>` or `$(< <path>)`. Applies regardless of
# command word, since the target may be a bare assignment (`x=$(<f)`) with no
# recognizable command word at all.
_gaia_ro_redirect_operand() {
  local seg="$1" rest cand
  case "$seg" in
    *'<'*) : ;;
    *) return 0 ;;
  esac
  rest=$(printf '%s' "$seg" | sed -E 's/^.*<[[:space:]]*//')
  cand=$(printf '%s' "$rest" | sed -E 's/[[:space:])].*$//')
  if [ -n "$cand" ]; then _gaia_ro_emit "$cand"; fi
  return 0
}

# Strip leading NAME=value assignments so the real command word is exposed.
gaia_reader_strip_env_prefix() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//'
}

# Dispatch on a token list whose first element is the command word. Split out
# so the `env` runner arm can re-enter it on the command env wraps.
_gaia_ro_dispatch() {
  local toks=("$@")
  local cmdword t i n

  [ "${#toks[@]}" -gt 0 ] || return 0
  cmdword=$(_gaia_ro_strip_quotes "${toks[0]}")
  # Reach the real reader through a leading path (`/usr/bin/grep`), the way the
  # permission analyzer this guard backstops does.
  cmdword="${cmdword##*/}"

  # `env` is a runner as well as a dump: `env FOO=1 cat <path>` opens <path> as
  # surely as a bare `cat` would. Strip env's own flags and the NAME=value
  # assignments it sets, then judge whatever it wraps. Whether a bare `env` with
  # nothing left to wrap is a process-environment DUMP is a separate question,
  # and not this library's: the caller that cares owns it.
  if [ "$cmdword" = 'env' ]; then
    n=${#toks[@]}
    i=1
    while [ "$i" -lt "$n" ]; do
      case "${toks[$i]}" in
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    while [ "$i" -lt "$n" ]; do
      case "${toks[$i]}" in
        [A-Za-z_]*=*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    if [ "$i" -lt "$n" ]; then
      _gaia_ro_dispatch "${toks[@]:$i}"
    fi
    return 0
  fi

  if _gaia_ro_in_list "$cmdword" "$_GAIA_RO_GREP_READERS"; then
    _gaia_ro_grep_operands "${toks[@]:1}"
  elif _gaia_ro_in_list "$cmdword" "$_GAIA_RO_PLAIN_READERS"; then
    for t in "${toks[@]:1}"; do
      _gaia_ro_emit "$t"
    done
  fi
  return 0
}

gaia_reader_operands() {
  local seg="$1"
  local seg_cmd
  local toks

  seg_cmd=$(gaia_reader_strip_env_prefix "$seg")
  read -r -a toks <<<"$seg_cmd"

  if [ "${#toks[@]}" -gt 0 ]; then
    _gaia_ro_dispatch "${toks[@]}"
  fi

  _gaia_ro_redirect_operand "$seg"
}
