#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-oracle-blind-invocations.sh: flag a script invocation the capability
# oracle's anchors cannot see. Exit 1 with a file:line report on any hit, exit 0
# when clean, exit 2 on the check's own failure. Run it directly from the repo
# root: `bash .gaia/scripts/lint-oracle-blind-invocations.sh`.
# gaia:maintainer-only:start
#
# Enforced twice, the same way every lint beside it is, and only one of the two
# blocks a merge. The sibling bats suite
# .gaia/scripts/tests/lint-oracle-blind-invocations.bats runs in the
# `Audit CI Tests` scripts shard, a declared-required context; it fails when
# this scan finds a hit and self-tests the detector against known-bad fixtures.
# That job's `code` filter is what arms it, so every root the scan walks has to
# be named there by a glob broad enough to cover it; a path the scan reads and
# the filter misses reports green having run this assertion zero times.
# `Shell Lint` runs the same scan a second way through .gaia/tests/shell-lint.sh;
# it is advisory rather than required, so it reports a regression without
# blocking the merge.
# gaia:maintainer-only:end
#
# Why: .gaia/scripts/capability-oracle-lib.sh decides what a hook or an
# allowlisted script reaches for by matching two ANCHORS against a line of
# shell -- _GAIA_CAPCHECK_DOTCMD for a `.` load and _GAIA_CAPCHECK_PATHCMD for a
# bare path in command position. Both are regular expressions approximating a
# grammar, both name their misses in their own headers, and a shape they reject
# produces SILENCE rather than a finding: the unresolved-reporting channel sits
# downstream of the anchors, so nothing tells the author that the file they just
# wrote reaches for something the oracle did not record. On the hook surface the
# artifact that under-reports is .gaia/hook-capabilities.json, which an adopter
# reads as complete. gaia-react/gaia#1549 is that failure having already
# happened once: the tree grew `if . "$p"; then` and the oracle could not see it.
#
# Two mechanisms produce the class and only one of them has ever been guarded.
# Repairing the grammar adds grammar, which is anchor-side and is what the
# derived property suite in .gaia/scripts/tests/capability-oracle-anchors.bats
# now watches. The tree growing an idiom faster than the oracle models it is
# EXOGENOUS -- no change to the oracle causes it and no suite over the oracle
# sees it -- and this check is the only thing that addresses it. It turns "the
# oracle silently missed it" into "the gate told the author at write time".
#
# ---------------------------------------------------------------------------
# How it decides, and why bash rather than a second regex
# ---------------------------------------------------------------------------
#
# The check is a DIFFERENTIAL between two readings of the same line:
#
#   bash's reading      is this token in COMMAND POSITION?
#   the oracle's        do the anchors emit a record for this line?
#
# A token bash calls a command and the anchors do not is the finding. Nothing
# here re-states which shapes the anchors miss, so there is no enumeration to
# rot: the anchors are sourced and asked, and whatever they answer today is the
# subtrahend.
#
# The reading that could have been a second approximation is the first one, and
# it is not one. Bash expands an ALIAS only for a word in command position, and
# it does that expansion at PARSE time. So the check rewrites each candidate
# word to a unique sentinel, defines an alias for every sentinel, wraps the
# whole file in a function, and asks bash to print the function back with
# `declare -f`. A sentinel that comes back expanded was in command position;
# one that comes back verbatim was an argument, a string, or a comment. The
# file is parsed and never run: `declare -f` serializes the function bash
# already built, and the function is never called.
#
# That is the rule .gaia/scripts/tests/capability-oracle-anchors.bats' header
# states, applied one level out: decide a coverage claim against an authority
# OUTSIDE the vocabulary under test. Here the thing under test is a regular
# expression approximating bash's grammar, and bash is free, present, and
# already this repo's interpreter. A hand-written "looks like an execution"
# reader would have been the same approximation with its failure direction
# reversed, and its false positives would have been prose -- which is precisely
# what a deny message naming a script path inside a sentence looks like, and
# this tree is full of them.
#
# ---------------------------------------------------------------------------
# What this check does NOT cover
# ---------------------------------------------------------------------------
#
# Stated rather than guarded, because no authority here answers them and a
# claim of coverage that the code does not have reads as a passing check:
#
#   A COMMAND-PREFIX WORD THAT CARRIES ITS OWN ARGUMENTS. Bash parses `exec x`
#   with `exec` as the command word and `x` as an argument, so the sentinel in
#   `x` does not expand on its own. The fix for the single-word prefixes is
#   bash's own rule that an alias whose value ends in a SPACE makes the next
#   word alias-expandable too, which is what PREFIX_WORDS below buys and what
#   makes `exec`, `command`, `nohup`, `builtin` and `time` read correctly. A
#   prefix taking arguments of its own -- `env FOO=1 <path>`, `timeout 5
#   <path>`, `xargs <path>` -- cannot be expressed that way, because the word
#   after the prefix is the prefix's argument rather than the command. Those
#   read as arguments here and are not reported. PREFIX_WORDS is an enumeration
#   and therefore a coverage claim; the sibling suite drives every word on it,
#   so a word that stops working fails loudly, and no arm claims a word that is
#   not on it.
#
#   A TOKEN INSIDE A COMMAND SUBSTITUTION. `declare -f` reproduces a `$( ... )`
#   body verbatim rather than re-serializing it, so a sentinel in there comes
#   back unexpanded and reads as an argument. It costs nothing: `$(` is on
#   _GAIA_CAPCHECK_PATHCMD, so the oracle is not blind to that position and
#   there is no divergence to report.
#
#   ANYTHING OUTSIDE THE SCAN ROOTS. SCAN_ROOTS below is the boundary of the
#   claim, and its own comment says why that boundary has to be the oracle's
#   closure rather than the two directories the oracle is usually described by.
#   Widening it is two edits, here and in the `code` filter named at the top of
#   this header.
#
# The substitution itself is textual, and a textual rewrite of shell can break
# the parse -- a word carrying an unbalanced quote, a `${var:-}` whose interior
# looks path-shaped. That failure is NOT silent: a file whose probe does not
# come back as a parseable function is reported as `unprobeable` and exits 1
# like any other finding, because a file this check cannot read is a file the
# oracle's blindness is unmeasured over, which is the exact condition the check
# exists to end.

set -uo pipefail

# Needs bash 5, for the reason capability-oracle-lib.sh's own guard states: on
# bash 3.2 the oracle crashes partway through a file's walk and the records past
# that point are lost. This check sources that oracle to ask it what it sees, so
# it inherits the dependency whole. Re-exec under a Homebrew bash 5 when there
# is one, the way .gaia/scripts/bats5.sh discovers it, and refuse rather than
# answer wrongly when there is not: a truncated subtrahend makes the oracle look
# blinder than it is, which is a report of findings that are not there.
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  _gaia_obi_bash5_found=""
  for _gaia_obi_bash5 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$_gaia_obi_bash5" ] || continue
    # The single quotes are the point: the expansion is for the CANDIDATE bash to
    # perform, not this one.
    # shellcheck disable=SC2016
    [ "$("$_gaia_obi_bash5" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 5 ] 2>/dev/null || continue
    _gaia_obi_bash5_found="$_gaia_obi_bash5"
    [ "${BASH_SOURCE[0]}" = "$0" ] && exec "$_gaia_obi_bash5_found" "$0" "$@"
    break
  done
  printf 'lint-oracle-blind-invocations: requires bash >= 5, found %s\n' "${BASH_VERSION}" >&2
  exit 2
fi

# Scanned from the CURRENT DIRECTORY, which is how CI runs it and how the
# sibling lints beside it work: the fixture trees the guard suite drives are
# plain temporary directories rather than repositories, and a `git ls-files`
# discovery would resolve zero files in one and report a clean tree.
REPO_ROOT="$PWD"

_gaia_obi_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_gaia_obi_lib_dir" = "${BASH_SOURCE[0]}" ] && _gaia_obi_lib_dir="."
_gaia_obi_lib_dir="$(cd "$_gaia_obi_lib_dir" 2>/dev/null && pwd)"
if [ -f "$_gaia_obi_lib_dir/capability-oracle-lib.sh" ]; then
  # shellcheck source=.gaia/scripts/capability-oracle-lib.sh
  . "$_gaia_obi_lib_dir/capability-oracle-lib.sh"
else
  printf 'lint-oracle-blind-invocations: capability-oracle-lib.sh is missing beside this script\n' >&2
  exit 2
fi

# The scan roots, relative to the invoking directory. `tests/` is excluded under
# all of them: a suite's own fixtures are written to be read wrongly, and the
# oracle's closure never reaches them.
#
# This list has to cover every directory the oracle's CLOSURE walks, not the two
# obvious ones. The closure starts at the registered hooks and the allowlisted
# scripts and follows each `invokes:` edge it resolves, so it leaves both
# directories: today it reaches `.claude/hooks/lib/` (under the first root) and
# `.specify/extensions/gaia/lib/`, and `.github/audit/` is inside a registered
# hook's closure by the same mechanism. A root the closure walks and this list
# omits is a file the oracle can be blind in with the check reporting clean,
# which is the failure this check exists to end, reproduced one level up.
#
# The list is held to that surface by the sibling suite rather than by memory:
# an arm there derives the same directories out of the ERE the audit workflow's
# hook-capabilities gate carries, and reds when this list covers less. The
# limit that arm cannot close is stated with it. Over-covering is free here and
# under-covering is silent, so a root the closure does not currently reach
# stays on the list.
SCAN_ROOTS=(.claude/hooks .gaia/scripts .specify/extensions/gaia/lib .github/audit)

# Command-prefix words whose operand is still a command. Each is aliased to
# itself PLUS A TRAILING SPACE, which is bash's own rule for making the next
# word alias-expandable. See the coverage note in the header: this list is an
# enumeration, every member is driven by the sibling suite, and a prefix that
# takes arguments of its own cannot be written here at all.
PREFIX_WORDS=(exec command nohup builtin time)

# A repo-relative path ending in `.sh`, loose enough to carry an expansion.
# It only has to LOCATE a candidate word; bash decides whether the word is a
# command, so a match on something that is not a path costs a wasted sentinel
# rather than a wrong verdict.
PATH_SHAPE='[A-Za-z0-9_.$@{}~+/:-]*/[A-Za-z0-9_.$@{}~+/:-]*\.sh'

# ---------------------------------------------------------------------------
# The oracle's half of the differential
# ---------------------------------------------------------------------------

# _obi_anchors_see <logical-line>: 0 when either invocation scanner emits a
# record for the line, 1 when both are silent. The line is put through the same
# two strippers _gaia_capcheck_file_sites runs before the detectors, so what is
# asked here is exactly what the oracle asks. Both a resolved `CALL` and an
# `UNRESC` count as seeing it: the anchor matched either way, and an operand the
# resolver cannot place is a loud finding on the oracle's own channel rather
# than the silence this check is about.
_obi_anchors_see() {
  local text="$1" out
  _gaia_capcheck_strip_literals "$text"
  _gaia_capcheck_strip_quoted_code "$_GAIA_CAPCHECK_RET"
  out="$(
    {
      _gaia_capcheck_scan_invocations "$REPO_ROOT" "$_obi_rel" "-" "$_GAIA_CAPCHECK_RET" "probe:0"
      _gaia_capcheck_scan_bare_invocations "$REPO_ROOT" "$_obi_rel" "-" "$_GAIA_CAPCHECK_RET" "probe:0"
    } 2>/dev/null
  )"
  [ -n "$out" ]
}

# ---------------------------------------------------------------------------
# The substitution
# ---------------------------------------------------------------------------

# _obi_balanced <word>: 0 when the word carries an even number of double quotes
# and an even number of single quotes. It decides whether the WHOLE word can be
# swapped for a sentinel or only the path substring inside it, and both
# directions are needed. `"${lib:-}/x.sh"` must go whole, or the swap lands
# inside the expansion and severs the quote; `(.gaia/x.sh)"` -- a path in a
# parenthetical inside a sentence -- must not, for the mirror reason.
_obi_balanced() {
  local w="$1" d s
  d="${w//[^\"]/}"
  s="${w//[^\']/}"
  d="${#d}"
  s="${#s}"
  [ $(( d % 2 )) -eq 0 ] && [ $(( s % 2 )) -eq 0 ]
}

# _obi_rewrite_line <line> <lineno>: the line with every candidate word replaced
# by a sentinel, into _OBI_OUT; one alias definition per sentinel appended to
# _OBI_ALIASES; the line's text and number recorded per sentinel index.
#
# A candidate is a word carrying a repo `.sh` path, or the bare word `.` or
# `source`. The word is peeled of leading and trailing shell punctuation first,
# so `( .gaia/x.sh )` and `"$d/x.sh";` present the same core the plain spelling
# does, and an ASSIGNMENT PREFIX is split off and kept: `lib="$d/x.sh"` is an
# assignment, and swapping the whole word for a sentinel would turn it into a
# bare command word and manufacture a finding on every such line in the tree.
_obi_rewrite_line() {
  local line="$1" lineno="$2"
  local rest="$line" out="" lead word core lp tp asn repl tok
  while [ -n "$rest" ]; do
    lead="${rest%%[! $'\t']*}"
    rest="${rest#"$lead"}"
    if [ -z "$rest" ]; then out="$out$lead"; break; fi
    word="${rest%%[ $'\t']*}"
    rest="${rest#"$word"}"
    lp=""; tp=""; core="$word"
    while :; do
      case "$core" in
        ['({;&|']*) lp="$lp${core:0:1}"; core="${core:1}" ;;
        *) break ;;
      esac
    done
    while :; do
      case "$core" in
        *[';&|)']) tp="${core: -1}$tp"; core="${core%?}" ;;
        *) break ;;
      esac
    done
    if ! { [[ $core =~ $PATH_SHAPE ]] || [ "$core" = "." ] || [ "$core" = "source" ]; }; then
      out="$out$lead$word"
      continue
    fi
    asn=""
    if [[ $core =~ ^([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=) ]]; then
      asn="${BASH_REMATCH[1]}"
      core="${core#"$asn"}"
    fi
    if [ "$core" = "." ] || [ "$core" = "source" ] || _obi_balanced "$core"; then
      repl="GAIAPROBE_$((_OBI_N + 1))"
    else
      tok=""
      [[ $core =~ $PATH_SHAPE ]] && tok="${BASH_REMATCH[0]}"
      if [ -z "$tok" ]; then
        out="$out$lead$word"
        continue
      fi
      repl="${core%%"$tok"*}GAIAPROBE_$((_OBI_N + 1))${core#*"$tok"}"
    fi
    _OBI_N=$((_OBI_N + 1))
    _OBI_ALIASES="$_OBI_ALIASES alias GAIAPROBE_$_OBI_N='__GAIACMD_${_OBI_N}__';"
    _OBI_TEXT[_OBI_N]="$line"
    _OBI_LINENO[_OBI_N]="$lineno"
    out="$out$lead$lp$asn$repl$tp"
  done
  _OBI_OUT="$out"
}

# ---------------------------------------------------------------------------
# Per-file scan
# ---------------------------------------------------------------------------

# _obi_scan_file <rel>: emit one report line per finding. Two shapes, both
# exit-worthy: `blind` for a command the anchors do not see, and `unprobeable`
# for a file whose rewritten form does not parse, which leaves the file's
# blindness unmeasured rather than clean.
_obi_scan_file() {
  local rel="$1" file="$REPO_ROOT/$1"
  local line lineno=0 body="" out i w
  local -a starts=() logicals=()
  _obi_rel="$rel"
  _OBI_N=0; _OBI_ALIASES=""; _OBI_TEXT=(); _OBI_LINENO=(); _OBI_OUT=""

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Cheap prefilter. A line carrying no `.sh` and no `.`/`source` word has no
    # candidate in it, and the word walk below is the expensive part.
    case "$line" in
      *.sh*|*.\ *|*source\ *)
        _obi_rewrite_line "$line" "$lineno"
        body="$body$_OBI_OUT"$'\n'
        ;;
      *) body="$body$line"$'\n' ;;
    esac
  done < "$file"
  [ "$_OBI_N" -gt 0 ] || return 0

  out="$(
    {
      printf 'shopt -s expand_aliases\n'
      for w in ${PREFIX_WORDS[@]+"${PREFIX_WORDS[@]}"}; do printf "alias %s='%s ';\n" "$w" "$w"; done
      printf '%s\n' "$_OBI_ALIASES"
      printf '__gaia_obi_probe() {\n%s\n}\ndeclare -f __gaia_obi_probe\n' "$body"
    } | bash 2>&1
  )"
  case "$out" in
    *__gaia_obi_probe*) ;;
    *)
      printf '%s: unprobeable: the file does not parse under the sentinel rewrite, so its blindness here is unmeasured (%s)\n' \
        "$rel" "$(printf '%s' "$out" | head -1)"
      return 0
      ;;
  esac

  # The oracle reads LOGICAL lines -- continuations joined, comments and
  # heredoc bodies dropped -- and a probe lands on a PHYSICAL one. Asking the
  # anchors about the physical line would hand them a fragment whose command
  # position lives on the line above, and the fragment reads as anchored at `^`
  # when the joined line is not: a false clean, in the direction this check
  # exists to close.
  while IFS=$'\t' read -r i _ line; do
    [ -n "$i" ] || continue
    starts[${#starts[@]}]="$i"
    logicals[${#logicals[@]}]="$line"
  done < <(_gaia_capcheck_logical_lines "$file")

  local want j pick
  for ((i = 1; i <= _OBI_N; i++)); do
    case "$out" in
      *"__GAIACMD_${i}__"*) ;;
      *) continue ;;
    esac
    want="${_OBI_LINENO[$i]}"
    pick=-1
    for ((j = 0; j < ${#starts[@]}; j++)); do
      [ "${starts[$j]}" -le "$want" ] || break
      pick="$j"
    done
    [ "$pick" -ge 0 ] || continue
    _obi_anchors_see "${logicals[$pick]}" && continue
    printf '%s:%s: invocation in a shape the capability oracle cannot see: %s\n' \
      "$rel" "$want" "${_OBI_TEXT[$i]}"
  done
}

# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------

scan_files=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */tests/*) continue ;; esac
  scan_files[${#scan_files[@]}]="${f#./}"
done < <(
  for r in ${SCAN_ROOTS[@]+"${SCAN_ROOTS[@]}"}; do
    [ -d "$REPO_ROOT/$r" ] && find "$r" -type f -name '*.sh'
  done | LC_ALL=C sort -u
)

if [ "${#scan_files[@]}" -eq 0 ]; then
  printf 'lint-oracle-blind-invocations: the scan roots resolved zero tracked files\n' >&2
  exit 2
fi

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$REPO_ROOT/$f" ] || continue
  hits="$(_obi_scan_file "$f")"
  [ -z "$hits" ] || report="$report$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  printf 'Each line above reaches for a script the oracle records nothing for, so the\n' >&2
  printf 'capability manifests are incomplete about it and nothing else will say so.\n' >&2
  printf 'Rewrite the call into a shape the anchors accept -- most often by giving it a\n' >&2
  printf 'line of its own -- or widen the anchor in .gaia/scripts/capability-oracle-lib.sh\n' >&2
  printf 'and re-derive the manifests.\n' >&2
  exit 1
fi

echo "lint-oracle-blind-invocations: clean" >&2
exit 0
