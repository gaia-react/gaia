#!/usr/bin/env bats
#
# Property suite over the BOUNDARY ANCHORS in
# .gaia/scripts/capability-oracle-lib.sh: the constants a detector composes
# against to decide whether a word sits in command position. This file
# discovers them from the library source and derives their vocabularies from
# their own values, so nothing below names an anchor, a keyword, or a boundary
# character.
#
# Why a second oracle suite rather than more cases in the existing ones.
# `check-script-capabilities.bats` pins the anchors by IDIOM: a hand-written
# positive and the paired negative that would fire if the anchor were widened
# by one notch, one pair per shape this tree actually writes. That is the right
# instrument for a shape somebody chose, and it is blind along one axis: a
# keyword added to an anchor tomorrow is covered only if whoever adds it also
# writes the pair. The anchor-side defects this library has carried were all of
# that kind -- an arm matching inside a path token (#1549), a recognized shape
# read as a call edge it is not (#1599), a constant carrying no statement of
# what it misses (#1601). None of them was a case somebody wrote and got wrong;
# each was a case nobody wrote.
#
# So every assertion here derives its set from the artifact that owns it and
# asserts per element, per .claude/rules/bats-assertions.md. Each derivation
# carries its own short-read guard, because a derivation that silently returns
# a subset leaves a green suite driving less than its names claim.
#
# And a short-read guard is itself a coverage claim, which is the rule this
# file had to learn twice. A guard states what it reads; nothing rereads that
# statement; the statement decays into a per-site memory the next derivation
# does not inherit. Three separate derivations in this file shipped a guard
# narrower than its own stated coverage, the third one inside the second one's
# repair, and the deterministic battery was green for all three. A second
# in-file predicate does not close it: whatever checks the checker is then
# making an unchecked claim of its own, one level out.
#
# The rule that does close it, for any derivation added here: decide the
# coverage claim against an authority OUTSIDE this file's vocabulary, per run.
# Where such an authority exists the claim stops being prose. It exists more
# often than it looks: the vocabulary guard counts the artifact's own letters,
# the roster guard compares two independent readings of the library, and the
# wide predicate is bash itself, sourcing the library and reporting what then
# exists. Where no authority exists, say what is unchecked instead of
# asserting coverage.
#
# One corollary, learned by getting it wrong a fourth time. CONSULTING an
# authority over an enumerated set of inputs is not the same as BEING one.
# The wide predicate first approximated bash with a regex and checked that
# regex against bash over a GENERATED space of spellings. The space was then
# the coverage claim, and three consecutive reviews each found a branch the
# regex read that no generated spelling drove, the last of them three at once,
# every round against a green suite. An enumeration standing between a
# derivation and its authority reintroduces the exact claim the authority was
# brought in to retire. So where the authority can answer the question
# directly, let it answer: the enumeration then does not need a guard of its
# own, it is gone.
#
# What this suite does NOT do, stated because a property suite reads as
# stronger than it is. It does not judge whether an anchor's vocabulary is the
# RIGHT one; that is decided per detector, argued at length in each constant's
# own header, and is not mechanically checkable. And an arm DELETED from an
# anchor leaves this suite green, because the vocabulary is derived from the
# same constant the arm was deleted from: what a derived suite catches is a
# vocabulary that disagrees with the behaviour, a divergence nobody wrote down,
# and an arm that reaches somewhere it should not. Deletion is what the idiom
# pairs in `check-script-capabilities.bats` are for, and the two suites are
# complementary rather than alternative.
#
# Run under bash 5 (`source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/capability-oracle-anchors.bats`). The library refuses to
# load under bash 3.2 by design, so there is no weaker local reading of this
# file to be misled by.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_DIR/capability-oracle-lib.sh"
  # shellcheck source=.gaia/scripts/capability-oracle-lib.sh
  source "$LIB"

  # A repo root with one resolvable target, for the arms that assert an anchor
  # ADMITS a shape. TARGET_REL is what a positive line executes or sources;
  # MISS_REL names nothing on disk, so a site the anchor accepts and cannot
  # resolve surfaces as a record carrying its RAW token rather than a resolved
  # path. The negative arms use MISS_REL for exactly that reason: a resolved
  # record reports the path the resolver produced and hides the token the
  # anchor actually read, which is the field every in-token defect lives in.
  FIXTURE="$BATS_TEST_TMPDIR/tree"
  TARGET_REL="t/target.sh"
  MISS_REL="zz/nothing-here.sh"
  mkdir -p "$FIXTURE/t"
  printf '#!/usr/bin/env bash\ntrue\n' >"$FIXTURE/$TARGET_REL"

  # The floor the admitting-header arm applies. It guards ABSENCE, not quality:
  # the defect it exists to catch shipped a constant with no comment above it
  # at all, and any floor above zero catches that. It sits high enough that a
  # placeholder line cannot satisfy it and far enough below what every anchor
  # in the library carries today that it never argues with a terse header.
  ANCHOR_HEADER_MIN_LINES=8
}

# --- Derivations -----------------------------------------------------------

# anchor_names [<library>]: every boundary anchor, one per line, discovered by
# the shape of its value rather than by its name. An anchor opens with the
# alternation `(^|`, which is what makes it a position test instead of one of
# this library's word lists. A future anchor is picked up here with nobody
# editing this file; a word list is not.
anchor_names() {
  sed -n "s/^\(_GAIA_CAPCHECK_[A-Za-z_]*\)='(\^|.*/\1/p" "${1:-$LIB}"
}

# position_test_constants [<library>]: the same set, read WIDER than
# anchor_names, for the arm that holds the narrow one to account. It is not a
# second reader of the library's text. It sources the library in its own bash
# and reports the constants that then exist carrying an anchor value, so every
# spelling bash accepts in front of a name is already in this set and a
# spelling the narrow predicate cannot read is the only thing the two can
# disagree about.
#
# Why a wide predicate at all. anchor_names is the derivation every arm in
# this file walks, so a spelling it misses does not shrink one arm, it shrinks
# all of them at once and each still reports green: the suite drives fewer
# anchors while its names go on claiming every anchor. A wholesale respelling
# is loud, since anchor_names comes back empty and the non-empty arm above
# catches it. A PARTIAL one is the silent case, and it is the same shape as the
# in-token defect this suite exists for, one level further out.
#
# Why bash rather than a wider regex, which is this derivation's whole history
# and the reason the rule in this file's header is written the way it is. A
# predicate whose job is to be wider than another one is making a coverage
# claim, and a coverage claim decided inside this file's own vocabulary is a
# fact about the code that nothing rereads. A regex version of this predicate
# carried a paragraph claiming a keyword-and-nameref limit while its body read
# three spellings of seven. Checking that regex against bash over a GENERATED
# space of spellings did not end it either, and that is the part worth keeping:
# the generated space is itself a coverage claim. Three consecutive reviews
# each found a branch the predicate read that no generated spelling drove, the
# last of them three at once, and every one of those rounds ran against a
# green suite.
#
# The regress ends where the approximation does. This predicate has no branches
# to cover and no input space to enumerate, because it is not an approximation
# of bash: it is bash. A name it reports is one that exists once the library
# loads, which is the only reading of "the library defines this constant" that
# is nobody's reading of a line.
#
# Two things bash decides here for free, which the hand-widened regex got
# wrong in both directions. `local` at file scope is an error defining
# nothing, so a `local` line contributes no name here and cannot be claimed;
# a strip list growing `local` as a keyword did claim one. And a line that
# does not parse aborts the load, so it surfaces as a short set against
# anchor_names rather than as a name nobody can use. Neither needed a rule.
#
# The nested interpreter is `$BASH`, the one running this suite, rather than
# whatever `bash` resolves to on PATH. The library refuses to load under bash
# 3.2 by design, so a bare `bash` could answer this question under a different
# interpreter than every other arm is using: green here, red everywhere else,
# or the reverse. Asking the suite's own bash keeps the answer about the
# interpreter the file says it runs under.
position_test_constants() {
  "$BASH" -c '
    source "$1" >/dev/null 2>&1
    for n in ${!_GAIA_CAPCHECK_@}; do
      case "${!n}" in "(^|"*) printf "%s\n" "$n" ;; esac
    done
  ' _ "${1:-$LIB}"
}

# declass <regex>: the regex with every POSIX character-class name removed, so
# the class's own letters (`space` in `[[:space:]]`) cannot be read as an
# anchor keyword. Only the `[:name:]` payload goes and the surrounding brackets
# stay, which is what keeps a bracket expression that merely CONTAINS a class
# (`[[:space:]|&;]`) from collapsing into something else.
declass() {
  local v="$1" c
  for c in alpha alnum blank cntrl digit graph lower print punct space upper xdigit; do
    v="${v//\[:$c:\]/}"
  done
  printf '%s' "$v"
}

# anchor_vocab <regex>: the keyword vocabulary of one anchor, space separated.
# Every maximal run of lowercase letters left after declassing is a keyword,
# plus `!` when the anchor carries one, since that is a keyword the shell
# spells without letters. An anchor with no keywords returns empty, which is a
# real answer rather than a short read; the arms needing a non-empty vocabulary
# say so and skip an anchor that legitimately has none.
anchor_vocab() {
  local v rest out=""
  v="$(declass "$1")"
  rest="$v"
  while [[ $rest =~ ([a-z]+) ]]; do
    out="${out:+$out }${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[1]}"}"
  done
  case "$v" in *'!'*) out="${out:+$out }!" ;; esac
  printf '%s' "$out"
}

# vocab_is_complete <regex>: the short-read guard for anchor_vocab. Every
# lowercase letter surviving declassing belongs to some keyword, so the letters
# the vocabulary accounts for and the letters the anchor carries are the same
# count. A run the extraction walked past leaves the two disagreeing, which is
# the failure a non-empty check cannot see.
vocab_is_complete() {
  local v letters extracted="" k
  v="$(declass "$1")"
  letters="${v//[^a-z]/}"
  for k in $(anchor_vocab "$1"); do
    [ "$k" = '!' ] && continue
    extracted="$extracted$k"
  done
  [ "${#letters}" -eq "${#extracted}" ]
}

# anchor_header <anchor-name> [<library>]: the contiguous comment block
# immediately above the anchor's assignment, which is where this library states
# what a site admits and what it misses.
anchor_header() {
  local name="$1" lib="${2:-$LIB}"
  awk -v want="$name" '
    $0 ~ "^" want "=" { for (i = 1; i <= n; i++) print block[i]; exit }
    /^#/ { block[++n] = $0; next }
    { n = 0 }
  ' "$lib"
}

# header_names_keyword <anchor-name> <keyword> [<library>]: true when the
# anchor's header names <keyword> as code rather than as English. The backtick
# is what draws that line: `until` in a header is the keyword, until in a
# sentence is a conjunction, and a bare word match reads the second as
# documentation of the first.
header_names_keyword() {
  anchor_header "$1" "${3:-$LIB}" | grep -qE "\`${2}([^A-Za-z]|\$)"
}

# fn_body <function-name> [<library>]: one function's definition, for reading
# which constants it composes against. Asked of bash rather than read off the
# file, for the reason position_test_constants gives at length: a reader that
# matches one spelling of a definition is making a coverage claim about every
# other spelling bash accepts, and nothing rereads it. `declare -f` answers for
# whatever spelling the library actually used.
#
# It is a re-rendering, not the source text, and the difference runs both ways:
# it ADDS the lowercase name and the braces the awk reader skipped, and it
# REMOVES every comment while re-indenting the body and normalising command
# separators. What makes the substitution safe for the callers here is not that
# the output is a superset, because it is not. It is that every caller
# substring-matches UPPERCASE anchor names, which appear in code rather than in
# prose and survive deparsing intact. A caller wanting a comment marker, a
# lowercase token, or the original whitespace must not ask this function for
# it. Bash prints nothing and fails for a function that does not exist, which
# is the same empty answer the reader gave for one it could not parse.
fn_body() {
  "$BASH" -c 'source "$1" >/dev/null 2>&1; declare -f "$2"' _ "${2:-$LIB}" "$1"
}

# scanner_anchor <scanner-name>: the vocabulary-carrying anchor a scanner
# composes against, read out of the scanner's own body rather than mapped here.
# A scanner also composes against anchors with no keyword vocabulary, and those
# are not this function's answer: the arms calling it drive keywords, and an
# anchor with none has nothing for them to drive. Prints nothing when the
# scanner names none or more than one, so a caller asserting a single name
# fails on both.
scanner_anchor() {
  local body n found="" count=0
  body="$(fn_body "$1")"
  for n in $(anchor_names); do
    [ -n "$(anchor_vocab "${!n}")" ] || continue
    case "$body" in *"$n"*) found="$n" && count=$((count + 1)) ;; esac
  done
  [ "$count" -eq 1 ] || return 0
  printf '%s' "$found"
}

# scan_line <scanner> <line>: one scanner's records for one line of text, with
# the fixture tree as the repo root.
scan_line() {
  "$1" "$FIXTURE" "a/s.sh" "" "$2" "a/s.sh:1"
}

# raw_tokens <records>: the raw token off every record that carries one. A
# resolved record reports the path the resolver produced; an unresolved one
# reports what the anchor actually read, and that is the field an in-token
# defect is visible in.
raw_tokens() {
  printf '%s\n' "$1" | sed -n 's/^UNRESC\t[^\t]*\t\(.*\)$/\1/p'
}

# token_at_word_boundary <line> <token>: true when some occurrence of <token>
# in <line> starts at a word boundary -- the line's start, or behind a
# character no path token can carry.
#
# This is the shape an in-token anchor match has to be caught by, and the
# reason the obvious property is not enough: an arm that eats letters off the
# front of a path leaves a SUFFIX of that path, and a suffix is still a
# verbatim substring of the line. `X=1 docs/build.sh` read through an arm
# missing its trailing boundary yields `cs/build.sh`, which any "does the token
# appear in the line" assertion accepts. What it is not is a word: it begins
# mid-token, behind an `o`. Every occurrence is checked, so a token appearing
# twice is judged on its best position rather than on its first.
token_at_word_boundary() {
  local line="$1" tok="$2" prefix rest="$1" consumed=0 last
  while :; do
    case "$rest" in *"$tok"*) ;; *) return 1 ;; esac
    prefix="${rest%%"$tok"*}"
    consumed=$((consumed + ${#prefix}))
    [ "$consumed" -eq 0 ] && return 0
    last="${line:consumed-1:1}"
    case "$last" in
      [A-Za-z0-9_./-]) ;;
      *) return 0 ;;
    esac
    rest="${rest#*"$prefix$tok"}"
    consumed=$((consumed + ${#tok}))
  done
}

# --- The derivations themselves --------------------------------------------

@test "the anchor set is discovered from the library and is not empty" {
  # Every arm below iterates this set. A derivation coming back empty makes all
  # of them trivially true, so it is asserted once here rather than assumed at
  # each site.
  local names
  names="$(anchor_names)"
  [ -n "$names" ]
}

@test "every position-test constant in the library is discovered as an anchor" {
  # The short-read guard for anchor_names, which the arm above does not supply:
  # a non-empty set is not a complete one, and this is the derivation whose
  # short read shrinks every other arm in this file at once rather than failing
  # anywhere. Set equality rather than a count, because a count agrees with
  # itself when one spelling is missed and another is picked up.
  #
  # What to do when this reds: either spell the new anchor the way the rest of
  # them are spelled, or widen anchor_names deliberately. Both are fine and the
  # point is that neither happens by accident, which is what a suite driving
  # fewer anchors than it claims would be.
  #
  # So the width the wide predicate gets from being bash is deliberately NOT
  # mirrored onto anchor_names. Every spelling the wide one reads and the
  # narrow one cannot -- an assignment keyword, a digit in the name, leading
  # indentation -- is a spelling that reds this arm the moment the library
  # carries it, which is the loud signal. Teaching anchor_names the same
  # spellings would make the pair agree again and put the anchor back into the
  # driven set silently, which is the state this arm exists to refuse.
  #
  # What this pair does NOT catch, stated rather than left to be discovered,
  # because the rule in this file's header asks for exactly that where no
  # authority covers a case. The signal is a DISAGREEMENT, so a respelling both
  # predicates miss keeps them equal and this arm green while every arm below
  # drives one anchor fewer. The shape that surfaced when this was probed, and
  # the enumeration is a record of what was driven rather than a claim about
  # what exists, is an anchor moved inside a function AND indented with it,
  # which is how anyone moving one would write it: bash reports no file-scope
  # constant, correctly, and the narrow regex wants the name at column zero, so
  # the two agree on the miss. Left at column zero inside the function they
  # diverge and this arm reds, and so do they when the function is called at
  # load, so it is the indented spelling alone that is quiet.
  # It is not a regression, the regex predicate this one replaced missed it the
  # same way, and it is not live, since a function-scoped anchor would leave
  # the detectors that compose against it referring to nothing. Everything else
  # probed diverges loudly: a library that fails to load reports a short set,
  # including a partial load from an error part-way down, and an anchor built
  # by expansion rather than a literal is caught here even though the prose
  # this file used to carry named it as beyond reach.
  local wide narrow
  wide="$(position_test_constants | sort)"
  narrow="$(anchor_names | sort)"
  [ -n "$wide" ]
  [ "$wide" = "$narrow" ]
}

@test "the anchor-discovery arm fails on an anchor the narrow predicate cannot see" {
  # Non-vacuity control for the equality arm above, driven across every axis a
  # review has caught this pair failing to diverge on. The library is copied
  # with one sampled anchor respelt, and the arm requires the wide predicate to
  # keep seeing it while the narrow one loses it. That gap is the loud signal
  # the equality arm exists to produce, so a control proving the gap is real is
  # what keeps that arm from passing by agreeing with the defect it guards.
  #
  # The copy is SOURCED now rather than only read, because the wide predicate
  # is bash. So every respelling here has to be one that actually loads. That
  # is a stricter bar than the line-wise reading this control used to apply,
  # and a more honest one: a spelling that would not load is not a spelling the
  # library could carry, so a control built on one proves nothing.
  #
  # This list is not a coverage claim, and the difference matters because the
  # thing it replaces was one. The wide side is bash, so it needs no input
  # space to be complete and no arm rereads this list as though it were the
  # space. These are the spellings that have actually shipped defects in this
  # derivation, kept as evidence that the control still controls; a spelling
  # missing from it costs the suite nothing.
  #
  # Both greps match the WHOLE line. Each derivation emits one name per line,
  # and a name can be a strict prefix of one added later, so an unanchored
  # match breaks both arms at once and in opposite directions: the first goes
  # green off the longer name even when the wide predicate has stopped seeing
  # the sampled one, which is a control that has stopped controlling, and the
  # second matches the longer name and reds a suite that is correct (#1606).
  local copy="$BATS_TEST_TMPDIR/respelt-lib.sh" n tab desc expr
  tab="$(printf '\t')"
  n="$(anchor_names | head -n 1)"
  [ -n "$n" ]
  while IFS='|' read -r desc expr; do
    [ -n "$desc" ] || continue
    sed "$expr" "$LIB" >"$copy"
    if ! position_test_constants "$copy" | grep -qxF -- "$n"; then
      printf 'the wide predicate lost the anchor under: %s\n' "$desc" >&2
      return 1
    fi
    if anchor_names "$copy" | grep -qxF -- "$n"; then
      printf 'the narrow predicate still reads the anchor under: %s\n' "$desc" >&2
      return 1
    fi
  done <<EOF
readonly|s/^$n=/readonly $n=/
export|s/^$n=/export $n=/
declare -g|s/^$n=/declare -g $n=/
declare with tab separators|s/^$n=/declare${tab}-g${tab}$n=/
declare with a plus flag|s/^$n=/declare +x $n=/
space indent|s/^$n=/  $n=/
tab indent|s/^$n=/${tab}$n=/
EOF

  # The double-quoted respelling gets its own block, because producing it is
  # not a prefix edit and because bash, not this file, decided what it has to
  # look like. The narrow predicate reads a single-quoted value only, so double
  # quoting is a real divergence axis. But these anchors carry a backtick and a
  # `$` inside their character class, and both are live in a double-quoted
  # string: converting the quotes and nothing else does not respell the anchor,
  # it opens a command substitution and leaves the constant undefined. So the
  # value is escaped to mean the same bytes, and the arm proves it does before
  # trusting the case at all. A control that silently changed what the anchor
  # matches would be testing a library this repository does not have.
  #
  # The replacement travels through the environment rather than `awk -v`, which
  # processes escape sequences in the value it is handed and would undo exactly
  # the escaping this case exists to apply.
  local raw esc
  raw="$(sed -n "s/^$n='\(.*\)'\$/\1/p" "$LIB")"
  [ -n "$raw" ]
  esc="${raw//\\/\\\\}"
  esc="${esc//\`/\\\`}"
  esc="${esc//\$/\\\$}"
  esc="${esc//\"/\\\"}"
  GAIA_ANCHOR_REPL="$n=\"$esc\"" \
    awk -v n="$n" '$0 ~ "^" n "=" { print ENVIRON["GAIA_ANCHOR_REPL"]; next } { print }' \
    "$LIB" >"$copy"
  [ "$("$BASH" -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2-}"' _ "$copy" "$n")" = "$raw" ]
  position_test_constants "$copy" | grep -qxF -- "$n"
  anchor_names "$copy" | grep -qxF -- "$n" && return 1
  true
}

@test "a spelling that defines no constant is claimed by neither predicate" {
  # The other direction, and the case a hand-widened regex got wrong. `local`
  # at file scope is an error that defines nothing, so an anchor respelt behind
  # it is absent from the library once loaded and neither predicate may claim
  # it. A strip list that grew `local` alongside the real assignment keywords
  # would emit a name with no constant behind it, which reaches the equality
  # arm as a respelling nobody made.
  #
  # Nothing in this file decides that, and nothing in it has to. bash refuses
  # the line, so the wide predicate reports no name without being told.
  local copy="$BATS_TEST_TMPDIR/local-lib.sh" n
  n="$(anchor_names | head -n 1)"
  [ -n "$n" ]
  sed "s/^$n=/local $n=/" "$LIB" >"$copy"
  position_test_constants "$copy" | grep -qxF -- "$n" && return 1
  anchor_names "$copy" | grep -qxF -- "$n" && return 1
  true
}

@test "each anchor's keyword vocabulary accounts for every letter that anchor carries" {
  # The short-read guard for anchor_vocab, run per anchor. Without it a
  # vocabulary silently dropping a keyword leaves the arms below green over a
  # smaller set than their names claim.
  local n failed=0
  for n in $(anchor_names); do
    if ! vocab_is_complete "${!n}"; then
      printf 'vocabulary derivation is a short read for %s: [%s]\n' \
        "$n" "$(anchor_vocab "${!n}")" >&2
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "each scanner that drives keywords composes against exactly one keyword-carrying anchor" {
  # The short-read guard for scanner_anchor, which the arms below depend on. A
  # scanner naming no keyword-carrying anchor, or naming several, returns empty
  # rather than a wrong one, and that empty would silently skip the scanner
  # everywhere it is driven.
  local s
  for s in $(scanners); do
    [ -n "$(scanner_anchor "$s")" ] || return 1
  done
  true
}

@test "the scanner roster this suite drives holds every scanner the library anchors on keywords" {
  # The membership guard for scanners(), which is hand-written. Without it the
  # roster is the one set in this file whose short read nothing counts, and a
  # short read here is not a smaller suite that says so: a scanner added to the
  # library with a keyword-carrying anchor of its own is driven by nothing, so
  # the very defect class the arms below exist for goes uncaught while all of
  # them report green.
  #
  # Both directions, because each fails differently. A library scanner missing
  # from the roster is the uncovered case above; a roster entry the library no
  # longer holds is an arm driving a function that is not there, which reads as
  # coverage and asserts nothing.
  local derived roster
  derived="$(library_scanners | sort)"
  roster="$(scanners | sort)"
  [ -n "$derived" ]
  [ "$derived" = "$roster" ]
}

@test "the roster arm fails when the library grows a scanner the roster lacks" {
  # Non-vacuity control for the arm above. The library is copied with one extra
  # scanner appended, composing against an anchor the real library already
  # carries so the copy stays loadable, and the same derivation runs over it.
  #
  # The rows below, and every one after the first is what keeps this derivation
  # on bash. Every function in the library today is written the one way the
  # regexes this derivation used to use could read, so reverting them breaks
  # nothing measurable against the real library and the conversion would be
  # free to rot. Each added spelling is a definition bash accepts that one of
  # those readers refused, so each pins one of them:
  #
  #   `_v2` carries a digit, which the discovery regex's `[a-z_]*` refused.
  #   `function NAME {` carries no parens, which BOTH the discovery regex and
  #   the body reader's `^NAME() {` refused.
  #   `_capcheck_...`, with no `_gaia` on the front, which the name filter an
  #   earlier spelling of the discovery step applied refused. Nothing in the
  #   tree enforces that prefix, so a library function may legitimately carry
  #   any name; membership is the library's own, decided by what loading it
  #   adds.
  #
  # A refused spelling was dropped from this set AND from the hand-written
  # roster at once, so the membership arm saw them equal and passed over a
  # scanner nothing in the file drove. That is the shape that reads as
  # coverage, and it is the class this suite spent its review rounds retiring
  # at the anchor predicate.
  #
  # Unlike the anchor control above, whose rows are evidence and whose absence
  # costs the suite nothing, these rows are load-bearing and nothing protects
  # them. This is the only arm that reds on either reader reverting, so
  # dropping a row reds nothing today and retires the pin on the reader it
  # stood for, which is the state both conversions were made to leave. Said
  # rather than guarded, because the guard would have to enumerate the
  # spellings bash accepts that a regex refuses, and no authority outside this
  # file can produce that list: this is the fallback the header names for
  # exactly that case.
  local copy="$BATS_TEST_TMPDIR/extra-scanner-lib.sh" a fn header
  a="$(scanner_anchor "$(scanners | head -n 1)")"
  [ -n "$a" ]
  while IFS='|' read -r fn header; do
    [ -n "$fn" ] || continue
    cp "$LIB" "$copy"
    {
      printf '%s\n' "$header"
      printf '  local pat="${%s}x"\n' "$a"
      printf '%s\n' '  printf "%s" "$pat" >/dev/null' '}'
    } >>"$copy"
    # Whole-line, for the reason the anchor-discovery control above gives: this
    # derivation emits one name per line too, and a substring match goes green
    # off any name that merely contains this one.
    if ! library_scanners "$copy" | grep -qxF -- "$fn"; then
      printf 'the derivation did not discover: %s\n' "$fn" >&2
      return 1
    fi
  done <<EOF
_gaia_capcheck_scan_extra_invocations|_gaia_capcheck_scan_extra_invocations() {
_gaia_capcheck_scan_v2_invocations|_gaia_capcheck_scan_v2_invocations() {
_gaia_capcheck_scan_v3_invocations|function _gaia_capcheck_scan_v3_invocations {
_capcheck_scan_legacy_invocations|_capcheck_scan_legacy_invocations() {
EOF
}

# scanners: the scanners this suite drives keywords through. This roster and
# the line each entry drives are hand-written, because the IDIOM a scanner
# recognizes is the thing that scanner is for, and it appears in the library
# only as a regex fragment inside the pattern the scanner composes. The
# roster's MEMBERSHIP is derivable and is checked against the library by the
# arm above; what is not derivable is the line to drive each member with, which
# is why a new scanner needs an entry here rather than being picked up silently.
#
# Deliberately not members, each for a reason rather than by omission:
# `_gaia_capcheck_scan_writes` anchors write COMMANDS through a
# vocabulary-free anchor, so it has no keywords for these arms to drive, and
# the per-term detectors do the same. Neither is discovered by
# library_scanners either, so the membership arm agrees with this paragraph
# rather than merely being told about it.
scanners() {
  printf '%s\n' _gaia_capcheck_scan_invocations _gaia_capcheck_scan_bare_invocations
}

# library_scanners [<library>]: every function in the library whose body
# composes against a keyword-carrying anchor, discovered rather than listed.
# This is deliberately a wider test than scanner_anchor's: a function naming
# SEVERAL such anchors is a member here and resolves to none there, so the two
# arms above disagree about it and the suite stops instead of skipping it.
#
# Discovery is bash's answer too, and for the same reason as everything else
# here: the regex this replaced read one function spelling (lowercase name at
# column zero, `() {` with one space and nothing after), so a scanner written
# any other way bash accepts entered neither this set NOR the hand-written
# roster, the membership arm saw them equal, and the scanner was driven by no
# arm in the file. Both sides missing it is exactly the shape that reads as
# coverage, which is the class this suite spent its review rounds retiring at
# the anchor predicate.
#
# Membership is the whole of bash's answer, with no name filter over it, and
# that is a correction rather than a flourish. Asking bash and then keeping
# only the names matching `_gaia_capcheck_*` put the same defect back one axis
# over: the prefix is a decision made in this file, so a scanner named outside
# it was absent from this set and from the hand-written roster alike, and the
# membership arm read the two as equal again. Nothing in the tree enforces the
# prefix, so it was a convention this file was quietly treating as a guarantee.
#
# What bounds the walk instead is the source itself. The names present BEFORE
# the library loads are subtracted from the names present after, so the set is
# what this library defines rather than what the surrounding process happens
# to carry: a bats run exports functions of its own, and they belong to the
# harness rather than to the artifact under test.
library_scanners() {
  local lib="${1:-$LIB}" f
  for f in $("$BASH" -c '
      before="$(declare -F | while read -r _ _ n; do printf "%s\n" "$n"; done)"
      source "$1" >/dev/null 2>&1
      declare -F | while read -r _ _ n; do
        printf "%s\n" "$before" | grep -qxF -- "$n" || printf "%s\n" "$n"
      done' _ "$lib"); do
    fn_names_keyword_anchor "$f" "$lib" || continue
    printf '%s\n' "$f"
  done
}

# fn_names_keyword_anchor <function-name> [<library>]: true when the function's
# body names any anchor that carries a keyword vocabulary.
fn_names_keyword_anchor() {
  local body n
  body="$(fn_body "$1" "${2:-$LIB}")"
  for n in $(anchor_names); do
    [ -n "$(anchor_vocab "${!n}")" ] || continue
    case "$body" in *"$n"*) return 0 ;; esac
  done
  return 1
}

# scanner_call_line <scanner> <path>: the line that scanner reads a call to
# <path> out of, absent any anchor prefix. The source scanner needs the `.`
# builtin in front of its operand; the bare-path scanner needs the path alone.
scanner_call_line() {
  case "$1" in
    *bare_invocations) printf '%s' "$2" ;;
    *) printf '. %s' "$2" ;;
  esac
}

# --- The anchors admit what their vocabularies say they admit ---------------

@test "every keyword on a scanner's anchor admits a call in that position" {
  # The failure this arm exists for is SILENCE. A keyword that derives from an
  # anchor and does not actually admit its idiom produces no record at all, and
  # the target's whole subtree leaves the closure with nothing saying so. The
  # spellings that reach it are the ones leaving the vocabulary intact while
  # breaking the match: an arm demanding a boundary the shell does not write, a
  # keyword mistyped in the constant and in nothing else.
  local s a kw hits=0 failed=0 out line
  for s in $(scanners); do
    a="$(scanner_anchor "$s")"
    [ -n "$a" ] || continue
    for kw in $(anchor_vocab "${!a}"); do
      hits=$((hits + 1))
      line=" $kw $(scanner_call_line "$s" "$TARGET_REL")"
      out="$(scan_line "$s" "$line")"
      if ! grep -qF -- "CALL	$TARGET_REL" <<<"$out"; then
        printf 'keyword %s on %s admits no call through %s: line [%s] gave [%s]\n' \
          "$kw" "$a" "$s" "$line" "$out" >&2
        failed=1
      fi
    done
  done
  [ "$hits" -gt 0 ]
  [ "$failed" -eq 0 ]
}

# --- The span blanker covers the anchor it defends -------------------------

@test "every keyword the bare-path anchor carries is defused inside a quoted span" {
  # _gaia_capcheck_blank_quoted_anchors spells the keyword set it removes as a
  # literal list, and the anchor spells its own. Nothing holds a literal list in
  # step with a constant, and the divergence is silent in the direction that
  # matters: a keyword added to the anchor and not to the blanker puts every
  # message string carrying that word back in command position, which is the
  # fabricated-edge class the blanker exists to close. So the set is derived
  # from the anchor here and each element driven through the real blanker.
  local a kw hits=0 failed=0 line out
  a="$(scanner_anchor _gaia_capcheck_scan_bare_invocations)"
  [ -n "$a" ]
  for kw in $(anchor_vocab "${!a}"); do
    hits=$((hits + 1))
    line="msg=\"lead $kw $TARGET_REL tail\""
    _gaia_capcheck_blank_quoted_anchors "$line"
    out="$(scan_line _gaia_capcheck_scan_bare_invocations "$_GAIA_CAPCHECK_RET")"
    if [ -n "$out" ]; then
      printf 'keyword %s on %s still reaches through a quoted span: [%s] gave [%s]\n' \
        "$kw" "$a" "$line" "$out" >&2
      failed=1
    fi
  done
  [ "$hits" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "the span-blanker arm fails against a blanker that misses one keyword" {
  # Non-vacuity control for the arm above, sampling one keyword. It respells the
  # blanker so a single keyword survives, which is exactly the divergence the
  # arm exists to catch, and drives that keyword through the respelled function.
  local a kw line out
  a="$(scanner_anchor _gaia_capcheck_scan_bare_invocations)"
  [ -n "$a" ]
  kw="$(anchor_vocab "${!a}")"
  kw="${kw%% *}"
  [ -n "$kw" ]
  eval "$(declare -f _gaia_capcheck_blank_quoted_anchors \
    | sed "s/ '$kw' / /")"
  line="msg=\"lead $kw $TARGET_REL tail\""
  _gaia_capcheck_blank_quoted_anchors "$line"
  out="$(scan_line _gaia_capcheck_scan_bare_invocations "$_GAIA_CAPCHECK_RET")"
  [ -n "$out" ]
}

# --- No arm reaches inside a token -----------------------------------------

@test "no keyword arm matches inside a longer word" {
  # The #1549 class, driven per keyword rather than per shape. An arm without a
  # boundary after its keyword matches those letters wherever they appear,
  # including at the front of a path token, and hands the resolver a file that
  # does not exist -- or, worse, one that does.
  #
  # Two shapes per keyword, because the two ends of an arm fail differently.
  # The keyword's letters at the front of the OPERAND is what surfaces as a
  # truncated token; the keyword's letters at the front of a longer COMMAND
  # word is what surfaces as a site that should not have been read at all.
  local s a kw tok hits=0 failed=0 line out
  for s in $(scanners); do
    a="$(scanner_anchor "$s")"
    [ -n "$a" ] || continue
    for kw in $(anchor_vocab "${!a}"); do
      [ "$kw" = '!' ] && continue
      hits=$((hits + 1))

      line="X=1 ${kw}$(scanner_call_line "$s" "$MISS_REL")"
      out="$(scan_line "$s" "$line")"
      for tok in $(raw_tokens "$out"); do
        if ! token_at_word_boundary "$line" "$tok"; then
          printf 'keyword %s on %s read [%s] out of the middle of [%s]\n' \
            "$kw" "$a" "$tok" "$line" >&2
          failed=1
        fi
      done

      line="X=1 ${kw}FOO $(scanner_call_line "$s" "$MISS_REL")"
      out="$(scan_line "$s" "$line")"
      if [ -n "$out" ]; then
        printf 'keyword %s on %s matched inside [%sFOO]: [%s]\n' "$kw" "$a" "$kw" "$out" >&2
        failed=1
      fi
    done
  done
  [ "$hits" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "the in-token arm fails against the anchor spelling that shipped the defect" {
  # Non-vacuity control for the arm above. It SAMPLES one anchor and one
  # mutation on purpose: a control proves an assertion can fail, and one
  # element establishes that, where mutating every anchor buys the same signal
  # at N times the cost. Coverage is the arm above; this is its proof of life.
  #
  # The mutation is the real one, the bare-path anchor as it was spelled before
  # #1549: each keyword arm carrying its leading boundary and not its trailing
  # one. It is applied to the derived vocabulary rather than pasted in, so the
  # control keeps testing the shipped spelling as that spelling changes.
  local s a kw mutated line out caught=0
  for s in $(scanners); do
    a="$(scanner_anchor "$s")"
    [ -n "$a" ] || continue
    mutated="${!a}"
    for kw in $(anchor_vocab "${!a}"); do
      [ "$kw" = '!' ] && continue
      mutated="${mutated//\[\[:space:\]\]$kw\[\[:space:\]\]/[[:space:]]$kw}"
    done
    [ "$mutated" = "${!a}" ] && continue
    printf -v "$a" '%s' "$mutated"
    for kw in $(anchor_vocab "$mutated"); do
      [ "$kw" = '!' ] && continue
      line="X=1 ${kw}$(scanner_call_line "$s" "$MISS_REL")"
      out="$(scan_line "$s" "$line")"
      for tok in $(raw_tokens "$out"); do
        token_at_word_boundary "$line" "$tok" || caught=1
      done
    done
  done
  [ "$caught" -eq 1 ]
}

# --- A divergence between anchors is written down --------------------------

@test "a keyword one anchor carries and another lacks is named in the lacking anchor's header" {
  # The #1601 class at the vocabulary level. Anchors meant to be one vocabulary
  # have diverged deliberately more than once, and each divergence is argued in
  # the header of the anchor that does NOT carry the keyword, because that is
  # the header a reader chasing a missed shape opens. A divergence nobody wrote
  # down reads as an oversight to the next person and gets "fixed" back.
  #
  # The set is every ordered pair of keyword-carrying anchors, so both
  # directions are covered and a direction that is legitimately empty
  # contributes nothing rather than making the arm vacuous. The pair count is
  # what is asserted non-zero, not the divergence count: anchors agreeing
  # completely is a valid state of the library and must not read as a failure.
  local a b kw pairs=0 failed=0
  for a in $(anchor_names); do
    [ -n "$(anchor_vocab "${!a}")" ] || continue
    for b in $(anchor_names); do
      [ "$a" = "$b" ] && continue
      [ -n "$(anchor_vocab "${!b}")" ] || continue
      pairs=$((pairs + 1))
      for kw in $(anchor_vocab "${!a}"); do
        [ "$kw" = '!' ] && continue
        case " $(anchor_vocab "${!b}") " in *" $kw "*) continue ;; esac
        if ! header_names_keyword "$b" "$kw"; then
          printf '%s lacks keyword %s that %s carries, and its header does not say so\n' \
            "$b" "$kw" "$a" >&2
          failed=1
        fi
      done
    done
  done
  [ "$pairs" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "the divergence arm fails on a keyword no header names" {
  # Non-vacuity control for the arm above, sampling one anchor and one keyword.
  # The keyword is a shell keyword no anchor carries and no header mentions, so
  # a pass here can only come from the check reading the header it claims to
  # read rather than matching something incidental.
  local n found=0
  for n in $(anchor_names); do
    if ! header_names_keyword "$n" 'case'; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ]
}

# --- Every anchor states what it misses ------------------------------------

@test "every anchor carries an admitting header" {
  # #1601 itself. This library's own header says every site here is
  # deliberately incomplete in one direction and says so in its own header; an
  # anchor is where that matters most, because its silence is indistinguishable
  # from a clean run. Nothing enforced the discipline until this arm, and the
  # constant with the widest blast radius in the file was the one that shipped
  # without it.
  local n lines hits=0 failed=0
  for n in $(anchor_names); do
    hits=$((hits + 1))
    lines="$(anchor_header "$n" | wc -l | tr -d ' ')"
    if [ "$lines" -lt "$ANCHOR_HEADER_MIN_LINES" ]; then
      printf '%s carries a header of %s lines\n' "$n" "$lines" >&2
      failed=1
    fi
  done
  [ "$hits" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "the admitting-header arm fails against an anchor that has none" {
  # Non-vacuity control, sampling one anchor. The library is copied with the
  # sampled anchor's header stripped, which is the state #1601 was filed
  # against, and the same derivation runs over the copy.
  local copy="$BATS_TEST_TMPDIR/stripped-lib.sh" n
  n="$(anchor_names | head -n 1)"
  awk -v want="$n" '
    $0 ~ "^" want "=" { held = 0; print; next }
    /^#/ { hold[++held] = $0; next }
    { for (i = 1; i <= held; i++) print hold[i]; held = 0; print }
    END { for (i = 1; i <= held; i++) print hold[i] }
  ' "$LIB" >"$copy"
  [ -s "$copy" ]
  [ -n "$(anchor_names "$copy")" ]
  [ "$(anchor_header "$n" "$copy" | wc -l | tr -d ' ')" -lt "$ANCHOR_HEADER_MIN_LINES" ]
}

# anchor_boundary_chars <regex>: the boundary CHARACTERS of one anchor, one per
# line. The anchor spells them as its first bracket expression; a POSIX class
# spelled `[[:space:]]` cannot be it, because the anchor's own alternation puts
# the character class first. Empty is a real answer for an anchor that has no
# character boundaries, and the arm below says so rather than reading it as a
# vocabulary it can skip.
anchor_boundary_chars() {
  local v cls i
  v="$1"
  case "$v" in *'['*) ;; *) return 0 ;; esac
  cls="${v#*[}"
  cls="${cls%%]*}"
  i=0
  while [ "$i" -lt "${#cls}" ]; do
    printf '%s\n' "${cls:i:1}"
    i=$((i + 1))
  done
}

@test "every boundary character the bare-path anchor carries is defused inside a quoted span" {
  # The character half of the arm above. The blanker spells its own separator
  # set as a literal `[;|&]` and the anchor spells its boundary class
  # separately, so the two can drift for the same reason and in the same silent
  # direction: a boundary character added to the anchor and not to the blanker
  # puts every message string carrying it back in command position.
  #
  # A backtick is on the anchor and is NOT blanked, deliberately: the blanker
  # bails on it because a backtick inside a span is a real substitution opener
  # whose body is code, so blanking it would lose calls rather than fabricate
  # them. That bail is stated here as an explicit skip rather than left as a
  # silent absence, which is what makes the rest of the set an assertion.
  local a ch hits=0 skipped=0 failed=0 line out
  a="$(scanner_anchor _gaia_capcheck_scan_bare_invocations)"
  [ -n "$a" ]
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    if [ "$ch" = '`' ]; then
      skipped=$((skipped + 1))
      continue
    fi
    hits=$((hits + 1))
    line="msg=\"lead $ch $TARGET_REL tail\""
    _gaia_capcheck_blank_quoted_anchors "$line"
    out="$(scan_line _gaia_capcheck_scan_bare_invocations "$_GAIA_CAPCHECK_RET")"
    if [ -n "$out" ]; then
      printf 'boundary %s on %s still reaches through a quoted span: [%s] gave [%s]\n' \
        "$ch" "$a" "$line" "$out" >&2
      failed=1
    fi
  done < <(anchor_boundary_chars "${!a}")
  # A derivation that came back empty would make the loop assert nothing while
  # its name says every, and the skip has to have found its one member or the
  # bail above is skipping something that is no longer there.
  [ "$hits" -gt 1 ]
  [ "$skipped" -eq 1 ]
  [ "$failed" -eq 0 ]
}

@test "the boundary-character arm fails against a blanker that misses one" {
  # Non-vacuity control for the arm above, sampling one character. It respells
  # the blanker so a single separator survives and drives that separator
  # through the respelled function, which is the divergence the arm exists for.
  local a ch line out
  a="$(scanner_anchor _gaia_capcheck_scan_bare_invocations)"
  [ -n "$a" ]
  ch="$(anchor_boundary_chars "${!a}" | grep -vFx '`' | head -1)"
  [ -n "$ch" ]
  eval "$(declare -f _gaia_capcheck_blank_quoted_anchors \
    | sed "s/;|&/|\&/")"
  line="msg=\"lead $ch $TARGET_REL tail\""
  _gaia_capcheck_blank_quoted_anchors "$line"
  out="$(scan_line _gaia_capcheck_scan_bare_invocations "$_GAIA_CAPCHECK_RET")"
  [ -n "$out" ]
}
