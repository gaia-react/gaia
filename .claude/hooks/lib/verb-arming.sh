#!/usr/bin/env bash
# The one arming decision every verb-armed hook asks: does this Bash tool call
# carry an invocation of the verb the caller cares about? Sourced
# unconditionally by each consumer, off the consumer's own on-disk location.
# Does no work at source time.
#
#   gaia_verb_armed <verb_fragment> <words_spec> <text>   # 0 armed, 1 not
#
# <verb_fragment> is an ERE fragment matching the verb AND its trailing
# boundary group, plus any further capture groups the caller wants. It is
# composed, byte for byte, into the pattern pair the consumers used to spell
# out one at a time:
#
#   start_re = '^[[:space:]]*'                       + <verb_fragment>
#   sep_re   = $'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*' + <verb_fragment>
#
# Composition is literal concatenation in that order, which is what preserves
# capture-group numbering: under `start` the fragment's own groups begin at 1,
# under `sep` group 1 is the separator and the fragment's begin at 2. The one
# consumer that reads a captured flag tail back out of the match depends on
# that numbering, so nothing here may introduce a group of its own.
#
# <words_spec> is the tokenizer arm's word-tuple set, `;`-separated. Each tuple
# is space-separated words compared as a PREFIX against the first command's
# words; the single-character token `*` matches exactly one word at that
# position. An empty spec turns the tokenizer arm off.
#
# <text> is what the caller matches against, which for one consumer is not the
# raw command: it joins backslash-newline pairs first, and the view has to be
# derived from the text actually matched.
#
# THREE PASSES, in this order, because the order is what makes the cost
# affordable:
#
#   1. The raw match, which is what every consumer paid before there was a
#      shared decision. Most tool calls miss it and go straight to pass 3, so
#      they never pay for the walk.
#   2. The data proof, only on a raw hit. The walker builds a same-length view
#      with every heredoc body it can prove is data masked out, and the same
#      two patterns run again against that. A hit there arms; a miss falls
#      through.
#   3. The first-command tokenizer, behind a cheap leading-character
#      pre-filter. Never subject to the data proof: it reads the invocation
#      itself, so there is no data span for it to be confused by.
#
# WHAT EVERY CALL SETS, armed or not:
#
#   GAIA_VERB_ARM_KIND         start | sep | first-command | ""
#   GAIA_VERB_ARM_MATCH        array copy of BASH_REMATCH from the deciding
#                              match; empty for first-command and for not armed
#   GAIA_VERB_ARM_VIEW         the text the deciding match ran against; the
#                              identity whenever nothing was suppressed
#   GAIA_VERB_ARM_SUPPRESSED   1 when the view differs from <text>, else 0
#
# CALL IT IN A CONDITION CONTEXT, always:
#
#   if gaia_verb_armed "$frag" "$words" "$cmd"; then … fi
#
# never as a bare statement and never inside `$( )`. Consumers run under three
# different option sets, and five of them trap ERR; some of those also set
# errexit and one does not. In a condition context bash suppresses both errexit
# and the ERR trap for the whole function body, which is what stops a routine
# `return 1` from silently exiting a hook that traps ERR to `exit 0`. This
# library never mutates the caller's options and never installs a trap.
#
# FAIL DIRECTIONS. If the walker cannot be sourced, the raw match stands and
# the view is the identity, which is precisely the answer every consumer gave
# before this decision was shared: a missing walker degrades to the old
# behaviour rather than to silence. If THIS file cannot be sourced, the answer
# is the consumer's to give, and it differs by consumer: a deny-capable
# consumer denies, naming the missing file, unless its own published contract
# is fail-open, in which case it exits 0.
#
# WHAT THIS DOES NOT CLOSE. Quoted prose still over-arms, fail-closed, and
# there is no safe narrowing. A verb whose characters are quoted still
# under-arms outside the first command, because pass 3 reads the first command
# only. Dollar-quoted words are unmodelled and the walk abstains on one rather
# than approximating it. Pass 3's bounded prefix can create an arm no data
# proof removes, because truncation at the bound can leave a word reading as
# the verb; that direction costs a decision nobody asked for rather than a
# merge nobody audited.

# Inputs longer than this get the identity view and the raw match stands. It
# covers the observed population: in a corpus of 33,498 real Bash tool calls no
# call that armed ran longer, and two ran past 8,192. The walker defaults the
# same value so it stays sourceable on its own under `set -u`.
# shellcheck disable=SC2034 # read by the walker, which defaults it when sourced alone
GAIA_VERB_ARM_MAX_CHARS=16384
# How much of the text pass 3 reads. CHARACTERS, not bytes. The scanner it
# calls walks a character at a time, so its cost grows faster than the input,
# and this bound sits far past the twenty-odd characters a real invocation
# needs for its first three words.
GAIA_VERB_ARM_SCAN_PREFIX=2048

# The four result variables. Every reader is a consumer hook or its suite, so
# no use of them is visible from inside this file.
# shellcheck disable=SC2034
GAIA_VERB_ARM_KIND=""
# shellcheck disable=SC2034
GAIA_VERB_ARM_MATCH=()
GAIA_VERB_ARM_VIEW=""
# shellcheck disable=SC2034
GAIA_VERB_ARM_SUPPRESSED=0

# 0 not tried, 1 loaded, 2 unavailable.
_gaia_va_walk=0
# Pre-filter cache, keyed on the words spec it was derived from.
_gaia_va_lead_key=""
_gaia_va_lead_re=""

# Derive pass 3's pre-filter from the distinct first words of <words_spec>.
#
# The filter reads the LEADING CHARACTERS rather than searching for the verb,
# and soundness is why: a word the shell assembles need not appear in the text
# as a run of bytes at all, so a search for one drops exactly the spellings
# this pass exists to catch. Two characters, not one, because the second is
# what tells `gh` from `git`; a first word that can reach `gh` begins with
# `gh`, or with `g` followed by a quote or backslash spelling the `h`, or with
# a quote or backslash outright.
#
# Be exact about what it does not buy. It reads the first word, never the
# subcommand, so every invocation of that command pays the source and the scan
# whatever it goes on to do, and so does any text opening with a quote or a
# backslash. What it removes is every text whose first word cannot reach the
# verb's command at all, which is most Bash tool calls.
#
# A leading character that is not alphanumeric is left to the scan: a filter
# built around one would have to know how the character behaves inside a
# bracket expression, and getting that wrong drops an arm silently.
_gaia_va_build_lead_re() {
  local spec="$1"
  local rest tuple w c0 c1 alts seen
  [ "$_gaia_va_lead_key" = "$spec" ] && return 0
  _gaia_va_lead_key="$spec"
  _gaia_va_lead_re=""
  alts=""
  seen=" "
  rest="$spec"
  while [ -n "$rest" ]; do
    case "$rest" in
      *';'*) tuple="${rest%%;*}"; rest="${rest#*;}" ;;
      *) tuple="$rest"; rest="" ;;
    esac
    case "$tuple" in
      *' '*) w="${tuple%% *}" ;;
      *) w="$tuple" ;;
    esac
    [ -n "$w" ] || continue
    case "$seen" in *" $w "*) continue ;; esac
    seen="$seen$w "
    c0="${w:0:1}"
    c1="${w:1:1}"
    case "$c0" in [A-Za-z0-9]) ;; *) return 0 ;; esac
    if [ -n "$c1" ]; then
      case "$c1" in [A-Za-z0-9]) ;; *) return 0 ;; esac
      alts="${alts}[$c0][\"'\\$c1]|"
    else
      alts="${alts}[$c0]|"
    fi
  done
  [ -n "$alts" ] || return 0
  _gaia_va_lead_re="^[[:space:]]*(${alts}[\"'\\])"
  return 0
}

# Compare the first command's words against <words_spec>. A tuple longer than
# the scanned word list never matches.
_gaia_va_words_match() {
  local spec="$1"
  local rest tuple wrest w i n ok
  n="${#GAIA_FIRST_COMMAND_WORDS[@]}"
  rest="$spec"
  while [ -n "$rest" ]; do
    case "$rest" in
      *';'*) tuple="${rest%%;*}"; rest="${rest#*;}" ;;
      *) tuple="$rest"; rest="" ;;
    esac
    [ -n "$tuple" ] || continue
    wrest="$tuple"
    i=0
    ok=1
    while [ -n "$wrest" ]; do
      case "$wrest" in
        *' '*) w="${wrest%% *}"; wrest="${wrest#* }" ;;
        *) w="$wrest"; wrest="" ;;
      esac
      [ -n "$w" ] || continue
      if [ "$i" -ge "$n" ]; then ok=0; break; fi
      if [ "$w" != '*' ] && [ "$w" != "${GAIA_FIRST_COMMAND_WORDS[$i]}" ]; then ok=0; break; fi
      i=$(( i + 1 ))
    done
    if [ "$ok" = 1 ] && [ "$i" -gt 0 ]; then return 0; fi
  done
  return 1
}

# Pass 3. It asks the shared scanner for WORDS rather than for a modelled
# invocation, and the difference is load-bearing: a function that abstains on
# an unmodelled flag shape is right for a relaxation deciding whether to permit
# and wrong here, because arming must be strictly broader than clearing.
_gaia_va_first_command() {
  local words_spec="$1" text="$2" dir errexit_was
  [ -n "$words_spec" ] || return 1
  _gaia_va_build_lead_re "$words_spec"
  if [ -n "$_gaia_va_lead_re" ]; then
    [[ "$text" =~ $_gaia_va_lead_re ]] || return 1
  fi
  # From this library's OWN on-disk location, never cwd: the suites run the
  # hooks by absolute path from a sandbox cwd that has no .claude/, so a
  # cwd-relative source would leave this pass silently dead exactly where the
  # tests believe they are exercising it.
  if ! type gaia_scan_first_command >/dev/null 2>&1; then
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    [ -n "$dir" ] && [ -f "$dir/repo-scope.sh" ] || return 1
    # Suspend errexit across the load, then RESTORE WHAT WAS THERE. Under errexit
    # an unparseable copy abandons the shell here before the type check below can
    # degrade, and in the errexit consumers that exit is 2, the deny code; no
    # consumer can guard it from outside, because `bash -n` does not recurse into
    # what a file sources. The restore is conditional rather than a bare `set -e`
    # because several consumers deliberately run WITHOUT errexit, and
    # several are PreToolUse deny gates where a stray non-zero exit is a verdict.
    # Nothing returns between the suspend and the restore, so no path leaks it.
    errexit_was=0
    case $- in *e*) errexit_was=1 ;; esac
    set +e
    # shellcheck source=/dev/null
    . "$dir/repo-scope.sh" 2>/dev/null
    if [ "$errexit_was" = 1 ]; then set -e; fi
    type gaia_scan_first_command >/dev/null 2>&1 || return 1
  fi
  gaia_scan_first_command "${text:0:$GAIA_VERB_ARM_SCAN_PREFIX}" || return 1
  _gaia_va_words_match "$words_spec"
}

# Pass 2's front door. Loads the walker at most once per process, from this
# library's own directory, and falls back to the identity when it cannot.
_gaia_va_view() {
  local dir errexit_was
  if [ "$_gaia_va_walk" = 0 ]; then
    _gaia_va_walk=2
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -n "$dir" ] && [ -f "$dir/verb-arming-walk.sh" ]; then
      # Same state-preserving bracket as the repo-scope load above, and for the
      # same reason. The `if . X; then` this replaced did NOT cover it: a parse
      # error abandons the shell from a condition context too, measured on
      # 3.2.57. The type check below is what degrades, leaving _gaia_va_walk at
      # 2 (the identity view), exactly as an absent walker already did.
      errexit_was=0
      case $- in *e*) errexit_was=1 ;; esac
      set +e
      # shellcheck source=/dev/null
      . "$dir/verb-arming-walk.sh" 2>/dev/null
      if [ "$errexit_was" = 1 ]; then set -e; fi
      if type gaia_verb_arm_view >/dev/null 2>&1; then _gaia_va_walk=1; fi
    fi
  fi
  if [ "$_gaia_va_walk" = 1 ]; then
    gaia_verb_arm_view "$1"
  else
    GAIA_VERB_ARM_VIEW="$1"
  fi
}

gaia_verb_armed() {
  local frag="$1" words_spec="$2" text="$3"
  local start_re sep_re raw

  GAIA_VERB_ARM_KIND=""
  GAIA_VERB_ARM_MATCH=()
  GAIA_VERB_ARM_VIEW="$text"
  GAIA_VERB_ARM_SUPPRESSED=0

  start_re='^[[:space:]]*'"$frag"
  sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*'"$frag"

  raw=0
  if [[ "$text" =~ $start_re ]]; then
    raw=1
  elif [[ "$text" =~ $sep_re ]]; then
    raw=1
  fi

  if [ "$raw" = 1 ]; then
    _gaia_va_view "$text"
    # shellcheck disable=SC2034
    [ "$GAIA_VERB_ARM_VIEW" = "$text" ] || GAIA_VERB_ARM_SUPPRESSED=1
    if [[ "$GAIA_VERB_ARM_VIEW" =~ $start_re ]]; then
      GAIA_VERB_ARM_KIND=start
      GAIA_VERB_ARM_MATCH=(${BASH_REMATCH[@]+"${BASH_REMATCH[@]}"})
      return 0
    fi
    if [[ "$GAIA_VERB_ARM_VIEW" =~ $sep_re ]]; then
      GAIA_VERB_ARM_KIND=sep
      GAIA_VERB_ARM_MATCH=(${BASH_REMATCH[@]+"${BASH_REMATCH[@]}"})
      return 0
    fi
  fi

  if _gaia_va_first_command "$words_spec" "$text"; then
    # shellcheck disable=SC2034
    GAIA_VERB_ARM_KIND=first-command
    # shellcheck disable=SC2034
    GAIA_VERB_ARM_MATCH=()
    return 0
  fi
  return 1
}
