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
# wide-predicate guard asks bash which spellings define a constant. Where no
# authority exists, say what is unchecked instead of asserting coverage.
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

  # The value every generated spelling assigns, for the oracle arm below. It
  # opens with the alternation that makes a constant a position test, so a
  # spelling the predicate reads at all is one it emits, and it carries no `$`,
  # so the single-quoted and double-quoted spellings assign the same bytes and
  # the arm judges the quoting form rather than an expansion.
  SPELL_VALUE='(^|[;|&])'
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

# position_test_constants [<library>]: the same set, read by a WIDER predicate,
# for the arm that holds anchor_names to it. It reads past whatever quote the
# assignment uses and past an assignment keyword in front of the name, so an
# anchor spelled in either of those ways is in this set and absent from the
# narrow one, which is what makes the disagreement visible.
#
# Why a second predicate at all. anchor_names is the derivation every arm in
# this file walks, so a spelling it misses does not shrink one arm, it shrinks
# all of them at once and each still reports green: the suite drives fewer
# anchors while its names go on claiming every anchor. A wholesale respelling
# is loud, since anchor_names comes back empty and the non-empty arm above
# catches it. A PARTIAL one is the silent case, and it is the same shape as the
# in-token defect this suite exists for, one level further out.
#
# Its own honest limit is NOT stated here. A predicate whose job is to be wider
# than another one is making a coverage claim, and a coverage claim written
# beside the code it describes is a fact about the code that nothing rereads:
# the paragraph this comment replaces claimed a `readonly` or `declare` keyword
# and an `eval`-or-nameref limit, while the body read three spellings of seven
# and missed four a line-wise reader plainly sees. The claim is decided instead,
# every run, by the oracle arm below, against bash. What survives as prose is
# the input space that arm generates, and an input space is an untested case
# rather than a false claim.
#
# `local` is deliberately not stripped, and bash is why rather than judgment:
# `local` outside a function is an error, so a `local` line defines no library
# constant and this predicate must not claim one. The oracle arm generates that
# spelling and would red if the strip list grew it.
position_test_constants() {
  awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      while (sub(/^(export|readonly|declare|typeset)[ \t]+/, "", line)) {
        while (sub(/^[-+][a-zA-Z]+[ \t]+/, "", line)) { }
      }
      if (line !~ /^_GAIA_CAPCHECK_[A-Za-z0-9_]*=/) next
      name = line
      sub(/=.*/, "", name)
      value = line
      sub(/^[^=]*=/, "", value)
      first = substr(value, 1, 1)
      if (first != "\"" && first != sprintf("%c", 39)) next
      value = substr(value, 2)
      if (index(value, "(^|") == 1) print name
    }
  ' "${1:-$LIB}"
}

# position_test_constants_prewidening [<library>]: the predicate exactly as it
# read before the oracle arm below existed, kept as that arm's mutation control
# rather than as a second reader. It is frozen on purpose: its subject is the
# historical shape, the way the in-token control's subject is the pre-boundary
# anchor spelling, so it does not track the predicate above and must not.
position_test_constants_prewidening() {
  awk '
    {
      line = $0
      sub(/^readonly[ \t]+/, "", line)
      sub(/^declare[ \t]+-[a-zA-Z]+[ \t]+/, "", line)
      if (line !~ /^_GAIA_CAPCHECK_[A-Za-z_]*=/) next
      name = line
      sub(/=.*/, "", name)
      value = line
      sub(/^[^=]*=/, "", value)
      first = substr(value, 1, 1)
      if (first == "\"" || first == sprintf("%c", 39)) value = substr(value, 2)
      if (index(value, "(^|") == 1) print name
    }
  ' "${1:-$LIB}"
}

# assignment_spellings: the input space the oracle arm drives, one
# `<name><US><line>` per spelling, delimited by the unit separator rather than
# by a tab. The delimiter is load-bearing and not a style choice: a tab IS IFS
# whitespace, so `IFS=<tab> read` strips a leading tab off the payload, and a
# tab-indented spelling sent down a tab-delimited transport arrives as a
# duplicate of the un-indented one. It would look like added coverage and drive
# nothing. The unit separator is not IFS whitespace, so the payload survives.
#
# It is a cross product of four axes rather
# than a list of cases, one axis per branch the predicate reads: leading
# indentation; the assignment-prefix keywords bash accepts in front of a name,
# with and without flag words and stacked; a name with and without a digit; and
# the three quoting forms, including the unquoted one that does not parse. A
# cross product rather than one axis varied around a base, because the axes
# interact: the indent has to be consumed BEFORE the keyword loop, and no
# spelling carrying only one of the two shows that.
#
# Nothing here labels a spelling in or out of the predicate's coverage, which is
# the whole point: bash labels them.
#
# This enumeration is the honest limit that remains. A spelling nobody thought
# to generate is untested, which is a different and smaller failure than a
# paragraph asserting coverage the code does not have: the arm never claims a
# spelling it did not drive.
assignment_spellings() {
  local indent prefix name quote tab
  tab="$(printf '\t')"
  for indent in '' '  ' "$tab"; do
    for prefix in '' 'export ' 'readonly ' 'declare ' 'typeset ' 'local ' \
      'declare -g ' 'declare -gr ' 'readonly declare ' 'export readonly '; do
      for name in _GAIA_CAPCHECK_SPELL _GAIA_CAPCHECK_SPELL2; do
        for quote in "'" '"' ''; do
          printf '%s\037%s%s%s=%s%s%s\n' \
            "$name" "$indent" "$prefix" "$name" "$quote" "$SPELL_VALUE" "$quote"
        done
      done
    done
  done
}

# bash_defines <line> <name>: true when sourcing a file holding <line> leaves
# <name> carrying the anchor value. This is the oracle the arm below decides
# coverage against, and it is outside this file's own vocabulary on purpose: a
# predicate checked by a second predicate leaves the second one's coverage as a
# fresh unchecked claim, which is the regress that put three instances of one
# class in this file. Whether a line defines a shell constant is a question
# bash answers, and bash is already this suite's interpreter.
#
# One file and one bash per spelling, not one file holding all of them: a
# spelling that does not parse aborts the whole source, and a `readonly` from
# an earlier spelling would refuse a later assignment to the same name.
bash_defines() {
  local line="$1" name="$2" file="$BATS_TEST_TMPDIR/oracle-spelling.sh" got
  printf '%s\n' "$line" >"$file"
  got="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2-}"' _ "$file" "$name")"
  [ "$got" = "$SPELL_VALUE" ]
}

# predicate_disagreements <predicate-fn>: every generated spelling the named
# predicate and bash label differently, one `<verdict> <line>` per line. Empty
# is agreement.
predicate_disagreements() {
  local fn="$1" name line file="$BATS_TEST_TMPDIR/predicate-spelling.sh" seen wanted
  while IFS="$(printf '\037')" read -r name line; do
    [ -n "$name" ] || continue
    printf '%s\n' "$line" >"$file"
    if "$fn" "$file" | grep -qxF -- "$name"; then seen=yes; else seen=no; fi
    if bash_defines "$line" "$name"; then wanted=yes; else wanted=no; fi
    [ "$seen" = "$wanted" ] && continue
    printf 'predicate=%s bash=%s\t%s\n' "$seen" "$wanted" "$line"
  done <<EOF
$(assignment_spellings)
EOF
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

# fn_body <function-name> [<library>]: one function's body, for reading which
# constants it composes against.
fn_body() {
  awk -v want="$1" '
    $0 ~ "^" want "\\(\\) \\{" { inside = 1; next }
    inside && /^\}/ { exit }
    inside { print }
  ' "${2:-$LIB}"
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
  # So the widening the oracle arm forces on the wide predicate is deliberately
  # NOT mirrored onto anchor_names. Every spelling the wide one learns to read
  # and the narrow one still cannot -- an assignment keyword, a digit in the
  # name, leading indentation -- is a spelling that reds this arm the moment the
  # library carries it, which is the loud signal. Teaching anchor_names the same
  # spellings would make the pair agree again and put the anchor back into the
  # driven set silently, which is the state this arm exists to refuse.
  local wide narrow
  wide="$(position_test_constants | sort)"
  narrow="$(anchor_names | sort)"
  [ -n "$wide" ]
  [ "$wide" = "$narrow" ]
}

@test "the anchor-discovery arm fails on an anchor the narrow predicate cannot see" {
  # Non-vacuity control, sampling one anchor and one respelling. The library is
  # copied with the sampled anchor's assignment put behind a `readonly`, one of
  # the spellings the narrow predicate cannot read, and both derivations run
  # over the copy.
  #
  # The copy is read and never sourced, so the respelling only has to be
  # something a line-wise reader must handle, not something that would load.
  #
  # Both greps match the WHOLE line. Each derivation emits one name per line,
  # and a name can be a strict prefix of one added later, so an unanchored
  # match breaks both arms at once and in opposite directions: the first goes
  # green off the longer name even when the wide predicate has stopped seeing
  # the sampled one, which is a control that has stopped controlling, and the
  # second matches the longer name and reds a suite that is correct (#1606).
  local copy="$BATS_TEST_TMPDIR/respelt-lib.sh" n
  n="$(anchor_names | head -n 1)"
  [ -n "$n" ]
  sed "s/^$n=/readonly $n=/" "$LIB" >"$copy"
  position_test_constants "$copy" | grep -qxF -- "$n"
  anchor_names "$copy" | grep -qxF -- "$n" && return 1
  true
}

@test "the wide predicate and bash agree on which spellings define a constant" {
  # The coverage claim of the predicate above, decided rather than remembered.
  # Every arm in this file walks a set the narrow derivation produces, and the
  # wide predicate is the only thing standing between that set and a silent
  # shrink; a wide predicate that is not actually wider makes the equality arm
  # pass by agreeing with the defect it exists to catch.
  #
  # Both directions matter and they fail differently. A spelling bash defines
  # and the predicate misses is the silent shrink. A spelling bash rejects and
  # the predicate emits is a name the equality arm reds on with no anchor
  # behind it, which reads as a respelling nobody made.
  local out
  out="$(predicate_disagreements position_test_constants)"
  [ -n "$(assignment_spellings)" ]
  if [ -n "$out" ]; then
    printf 'the wide predicate disagrees with bash:\n%s\n' "$out" >&2
    return 1
  fi
  true
}

@test "the coverage arm fails against the predicate spelling that shipped the defect" {
  # Non-vacuity control for the arm above, against the real historical shape
  # rather than an invented one: the predicate as it read when it claimed a
  # coverage it did not have. A control built from the defect keeps the arm
  # honest about the case it was written for, the way the in-token control
  # applies the pre-boundary anchor spelling.
  #
  # The count is not asserted, only that some spelling disagrees. What the old
  # predicate missed is a property of the input space above, and pinning a
  # number here would be a claim about that space that nothing rederives.
  local out
  out="$(predicate_disagreements position_test_constants_prewidening)"
  [ -n "$out" ]
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
  local copy="$BATS_TEST_TMPDIR/extra-scanner-lib.sh" a
  a="$(scanner_anchor "$(scanners | head -n 1)")"
  [ -n "$a" ]
  cp "$LIB" "$copy"
  {
    printf '%s\n' '_gaia_capcheck_scan_extra_invocations() {'
    printf '  local pat="${%s}x"\n' "$a"
    printf '%s\n' '  printf "%s" "$pat" >/dev/null' '}'
  } >>"$copy"
  # Whole-line, for the reason the anchor-discovery control above gives: this
  # derivation emits one name per line too, and a substring match goes green
  # off any name that merely contains this one.
  library_scanners "$copy" | grep -qxF -- '_gaia_capcheck_scan_extra_invocations'
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
library_scanners() {
  local lib="${1:-$LIB}" f
  for f in $(sed -n 's/^\(_gaia_capcheck_[a-z_]*\)() {$/\1/p' "$lib"); do
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
