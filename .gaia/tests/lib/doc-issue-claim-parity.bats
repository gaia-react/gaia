#!/usr/bin/env bats
# Doc-conformance for the `in-progress` claim's RELEASE contract, which is
# stated on two prose surfaces at two altitudes: the always-loaded operational
# rule `.claude/rules/issue-claim.md`, and the shipped concept page
# `wiki/concepts/Issue Claim.md`. Neither derives from the other and no
# machine-readable artifact holds them in step.
#
# The shape of the defect this guards. The rule enumerates the paths on which
# automatic release does NOT happen, each of which is a claim a human has to
# remove by hand. The concept page enumerates the same set for a reader who
# never opens the rule. A path added to the rule alone leaves the page asserting
# a shorter list, and a reader who trusts the page walks away believing a claim
# released itself when it did not. That direction is the dangerous one: the
# failure is silent on both ends, since the merge lands, the issue closes, and
# only the label stays, so nothing surfaces the drift at the moment it matters.
#
# The parity is therefore asserted per element rather than by count alone. A
# count-only check is satisfied by a page that carries the right NUMBER of
# entries naming the wrong ones, which is condition B in the plan this suite
# came out of: a guard pinning a sample rather than the obligation it claims.
# The disposition table below is the mapping, and it is reconciled against BOTH
# surfaces in BOTH directions, so a bullet with no row and a row with no bullet
# each stop the suite rather than passing over the gap.
#
# The two surfaces word their leads differently ON PURPOSE, since the rule is
# operational and the page is a concept-level census, so the table pairs them
# rather than demanding byte-identity. Byte-identity would be the wrong contract
# here: it would force the page down to the rule's altitude, which is the
# duplication the issue behind this suite explicitly rejected.
#
# The stated cardinality is pinned to the derived count on each surface, rather
# than left as prose. A number written into prose that nothing reads is exactly
# the class that has already cost this tree separate repairs; pinning it here is
# what stops it rotting, and it is why the count is allowed to stay in the prose
# at all.
#
# Honest limit, and it is a real one. Everything above pins what the two
# surfaces SAY about each other. Only the last test reaches the hook, and it
# reaches one structural property of it: that the no-reference lookup the
# seventh path describes still exists. It does not prove the hook's behaviour on
# any path, and there is no oracle here that could without driving a real merge.
# The rest of the release contract is verified by `.gaia/tests/hooks/
# issue-claim-release.bats`, which drives the hook itself; this suite is
# deliberately the prose half and does not restate that suite's assertions.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  RULE_REL='.claude/rules/issue-claim.md'
  PAGE_REL='wiki/concepts/Issue Claim.md'
  HOOK_REL='.claude/hooks/issue-claim-release.sh'

  RULE="$ROOT/$RULE_REL"
  PAGE="$ROOT/$PAGE_REL"
  HOOK="$ROOT/$HOOK_REL"

  RULE_SECTION='## Release on merge, and on abandonment'
  PAGE_SECTION='## Known limitations'

  # The pairing, rule lead on the left, page lead on the right, one row per
  # hand-off path, in the order both surfaces write them. A row is the only
  # thing that makes a path covered; see the header on why this is not a count.
  PAIRS=(
    'A merge run anywhere but here.|A merge run anywhere but here.'
    'A pull request that does not close the issue with a keyword.|A pull request that closes nothing by keyword.'
    'A merge that lands server-side after the command returns.|A merge queued with `--auto`.'
    'A merge that is not the first command in its tool call.|A merge that is not the first command in its tool call.'
    'A merge that names no pull request and deletes its branch.|A merge that names no pull request and deletes its branch.'
    'A controlled stop that abandons the work|A controlled stop that abandons the work.'
    'A stale claim|A session that dies mid-fix.'
  )

  # Spelled cardinalities, for the two surfaces that write one. Indexed by the
  # count itself so the lookup fails loudly on a count this table cannot spell,
  # rather than comparing against an empty string, which every prose line
  # contains.
  NUMBER_WORDS=(zero one two three four five six seven eight nine ten)
}

# section_body <file> <heading>
# Prints the lines of <file> under <heading>, stopping at the next heading of
# the same or shallower depth. Scoped rather than whole-file: a bullet added to
# another section of either surface is not a hand-off path, and counting it
# would make both the parity and the cardinality assertions answer a question
# nobody asked.
#
# Exit 1 when the heading is not present at all, so a renamed section fails by
# name instead of silently deriving zero elements. An empty derivation that
# reads as a clean pass is the failure mode the bats-assertion rule names.
section_body() {
  local file="$1" heading="$2" depth out
  depth="${heading%% *}"
  out="$(HEADING="$heading" DEPTH="$depth" awk '
    BEGIN { want = ENVIRON["HEADING"]; depth = ENVIRON["DEPTH"]; inside = 0 }
    {
      if ($0 == want) { inside = 1; next }
      if (inside && $0 ~ /^#+ /) {
        split($0, f, " ")
        if (length(f[1]) <= length(depth)) exit
      }
      if (inside) print
    }' "$file")"
  # `grep -qxF`, not a test on `out`: a section that exists and is empty and one
  # that does not exist are different repairs, and only the heading read tells
  # them apart.
  grep -qxF -- "$heading" "$file" || return 1
  printf '%s\n' "$out"
}

# bold_leads <file> <heading> <prefix>
# Prints the bold lead of every enumerated entry in that section, one per line,
# with the surrounding `**` removed. <prefix> is the literal that opens an entry
# on this surface: `- ` for the rule's list bullets, empty for the page's
# paragraph entries.
#
# Anchored to the start of the line on purpose. Both surfaces write bold inside
# running prose as well, and an unanchored read would collect emphasis that is
# not an entry at all, inflating the derived set and greening a surface that had
# actually dropped a path.
bold_leads() {
  local file="$1" heading="$2" prefix="$3" body rc
  rc=0
  body="$(section_body "$file" "$heading")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "bold_leads: ${file} carries no section '${heading}'" >&2
    return 2
  fi
  printf '%s\n' "$body" \
    | grep -oE "^${prefix}\*\*[^*]+\*\*" \
    | sed -E "s/^${prefix}\*\*//; s/\*\*$//"
}

# rule_leads / page_leads
# The two derivations, each named so a failing test says which surface it read.
rule_leads() { bold_leads "$RULE" "$RULE_SECTION" '- '; }
page_leads() { bold_leads "$PAGE" "$PAGE_SECTION" ''; }

# table_column <1|2>
# Prints one side of the disposition table, in table order.
table_column() {
  local which="$1" row
  for row in "${PAIRS[@]}"; do
    if [ "$which" = 1 ]; then printf '%s\n' "${row%%|*}"; else printf '%s\n' "${row##*|}"; fi
  done
}

# assert_same <label> <expected> <actual>
# One diff-producing comparison, so every reconciliation below reports which
# element moved rather than only that something did.
assert_same() {
  local label="$1" expected="$2" actual="$3"
  [ "$actual" = "$expected" ] && return 0
  echo "${label}: the table and the tree disagree" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  return 1
}

# --- Parity: the same set, on both surfaces, in the same order ---------------

@test "the rule's hand-off paths are the disposition table's left column, in both directions" {
  local derived rc
  # `|| rc=$?`, never a bare assignment then a `$?` read: an assignment takes
  # its command substitution's status, so under the errexit bats runs each body
  # with, the bare form abandons the test HERE and every arm below is dead.
  rc=0
  derived="$(rule_leads)" || rc=$?
  [ "$rc" -eq 2 ] && { echo "the rule's section could not be read" >&2; return 1; }
  [ -n "$derived" ] || { echo "no hand-off path derived from ${RULE_REL}; the bullet shape moved" >&2; return 1; }
  assert_same "${RULE_REL}" "$(table_column 1)" "$derived"
}

@test "the page's hand-off paths are the disposition table's right column, in both directions" {
  local derived rc
  rc=0
  derived="$(page_leads)" || rc=$?
  [ "$rc" -eq 2 ] && { echo "the page's section could not be read" >&2; return 1; }
  [ -n "$derived" ] || { echo "no hand-off path derived from ${PAGE_REL}; the entry shape moved" >&2; return 1; }
  assert_same "${PAGE_REL}" "$(table_column 2)" "$derived"
}

@test "the two surfaces enumerate the same number of paths" {
  local rule_n page_n
  rule_n="$(rule_leads | grep -c '')"
  page_n="$(page_leads | grep -c '')"
  [ "$rule_n" -eq "$page_n" ] || {
    echo "${RULE_REL} enumerates ${rule_n} paths and ${PAGE_REL} enumerates ${page_n}" >&2
    echo "the page falling behind the rule is the silent direction: a reader trusting it believes a claim released itself" >&2
    return 1
  }
  [ "$rule_n" -gt 0 ]
}

# --- Cardinality: the spelled count matches the enumerated one ---------------

# assert_cardinality <label> <file> <heading> <count> <phrase-tail>
# Asserts that <file>'s <heading> section spells <count> in front of
# <phrase-tail>.
#
# Read against the SECTION, never the file. The count belongs to the set the
# section enumerates, so a file-wide read is satisfied by the sentence sitting
# anywhere at all: moving `Seven paths need a hand` under a different heading
# and leaving the enumerating section saying `Several` keeps a whole-file grep
# green while the count and the set it counts no longer sit together. That is
# the same widening the qualifier arm was corrected for, and leaving it on these
# two arms would have been the correction applied to one instance and not to its
# siblings, which is the class this whole suite exists to catch.
assert_cardinality() {
  local label="$1" file="$2" heading="$3" n="$4" tail="$5" body rc word
  [ "$n" -lt "${#NUMBER_WORDS[@]}" ] || { echo "no spelling held for ${n}" >&2; return 1; }
  word="${NUMBER_WORDS[$n]}"
  rc=0
  body="$(section_body "$file" "$heading")" || rc=$?
  [ "$rc" -eq 0 ] || { echo "${label} carries no section '${heading}'" >&2; return 1; }
  # Case-insensitive on the word alone: both surfaces open the sentence with it.
  grep -qiE -- "(^|[^[:alnum:]])${word} ${tail}" <<<"$body" || {
    echo "${label} enumerates ${n} paths but its '${heading}' section does not say '${word} ${tail}'" >&2
    grep -nE -- "[A-Za-z]+ ${tail}" <<<"$body" >&2 || true
    return 1
  }
}

@test "the rule's spelled cardinality equals the number of paths it enumerates" {
  assert_cardinality "$RULE_REL" "$RULE" "$RULE_SECTION" "$(rule_leads | grep -c '')" 'paths need a hand'
}

@test "the page's spelled cardinality equals the number of paths it enumerates" {
  assert_cardinality "$PAGE_REL" "$PAGE" "$PAGE_SECTION" "$(page_leads | grep -c '')" 'shapes leave the claim set'
}

# --- The page's own claim about when the hook fires --------------------------

# release_claim
# Prints the mechanism claim in the page's `## Release` section: the paragraph
# naming the hook, truncated to its first two sentences.
#
# Scoped to the sentences, not to the file and not even to the section, because
# both wider reads are satisfied by text that has nothing to do with the claim.
# `first` is guaranteed present page-wide for as long as the parity table pins
# the fourth Known-limitations lead, which spells `the first command in its tool
# call` verbatim; and it survives a section read too, since the paragraph's own
# closing rationale says `while the first is still mid-review`. `MERGED` is
# likewise carried by the `--auto` entry's body. A whole-file or whole-section
# grep therefore greens a release sentence rewritten to drop both qualifiers,
# which is the condition-B shape this suite's header rejects, asserted of the
# suite itself.
#
# Two sentences rather than one: the qualifiers are split across them, the
# leading and repository conditions in the first and the MERGED condition in the
# second, while the third sentence is rationale rather than mechanism and is
# where the decoy `first` lives.
release_claim() {
  local body rc
  rc=0
  body="$(section_body "$PAGE" '## Release')" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$body" | grep -F -- 'issue-claim-release.sh' | awk '
    {
      # Cut at the second sentence break. A period with no space after it sits
      # inside a path or a filename, not at the end of a sentence.
      #
      # An abbreviation IS counted as a break: writing `e.g. ` or `i.e. ` into
      # the first sentence consumes a slot and truncates the window before the
      # MERGED sentence, so the qualifier loop reports a dropped qualifier that
      # is still there. Recorded rather than parsed around, because the
      # direction is fail-closed, a confusing red and never a false green, and
      # because teaching this splitter the abbreviations is the hand-rolled
      # parser the merge workflow names as the canonical multi-round trap. An
      # editor meeting that failure should rephrase the sentence or widen this
      # window, not chase a prose regression that did not happen.
      rest = $0; out = ""; n = 0
      while (n < 2 && match(rest, /\. /)) {
        out = out substr(rest, 1, RSTART)
        rest = substr(rest, RSTART + RLENGTH)
        n++
      }
      print (n == 2 ? out : $0)
    }'
}

@test "the page qualifies the release rather than asserting it unconditionally" {
  local claim rc
  rc=0
  claim="$(release_claim)" || rc=$?
  [ "$rc" -eq 2 ] && { echo "${PAGE_REL} carries no '## Release' section" >&2; return 1; }
  [ -n "$claim" ] || { echo "no release claim read in ${PAGE_REL}; the paragraph no longer names the hook" >&2; return 1; }

  # The three conditions the hook enforces before any label write, asserted as
  # the phrases that carry them rather than as bare words a rationale could
  # supply: the merge leads the tool call, it names this repository, and the
  # pull request reads MERGED. The superseded sentence asserted none of them.
  local q
  for q in '**first** command' 'naming this repository' '`MERGED`'; do
    grep -qF -- "$q" <<<"$claim" || {
      echo "${PAGE_REL}'s release claim drops the qualifier '${q}':" >&2
      printf '%s\n' "$claim" >&2
      return 1
    }
  done

  grep -qF -- 'fires on `gh pr merge` and strips' "$PAGE" && {
    echo "${PAGE_REL} states the release unconditionally again; the hook bails before the label write on several shapes" >&2
    return 1
  }
  return 0
}

# --- The one code-coupled assertion -----------------------------------------

# hook_code
# Prints the hook with its comment lines removed. Read code, never the whole
# file: this hook's header describes its own arms in prose, so a whole-file
# grep is satisfied by a sentence ABOUT the lookup after the lookup itself is
# gone. That is the string-decoy shape this tree has already paid for once in
# the errexit guard's parse-check credit, and it is the exact direction that
# matters here, since a hook rewritten to always carry a reference would delete
# the seventh path while its header still narrated it.
#
# Full-line comments only, deliberately. Stripping from a `#` anywhere on the
# line would cut inside `#[0-9]+` and the `"$1"`-adjacent text this hook
# genuinely runs, which trades a false green for a false red.
hook_code() {
  grep -vE '^[[:space:]]*#' "$HOOK"
}

@test "the hook still carries the no-reference lookup the branch-deleting path describes" {
  local code
  code="$(hook_code)"
  [ -n "$code" ] || { echo "read no executable line out of ${HOOK_REL}" >&2; return 1; }

  # The seventh path exists because the hook, handed no pull-request reference,
  # asks gh for the CURRENT branch's pull request, and `--delete-branch` has
  # moved the checkout off that branch by the time this hook runs. If the hook
  # ever stops taking that arm, the path stops existing and the prose on both
  # surfaces describing it becomes the drift this suite exists to catch, in the
  # other direction.
  #
  # `--json` sitting immediately after `pr view` IS the property: gh takes the
  # pull-request reference as a positional argument, so a flag in that position
  # means no reference was passed and gh falls back to the current branch. The
  # other arm reads `gh pr view --repo ... "$ref" --json` and cannot match. A
  # later `--json` field list growing a field is the same arm and stays green,
  # which is why the pattern stops at the fields it needs rather than anchoring
  # to the end of a line that also carries a redirect.
  printf '%s\n' "$code" | grep -qF -- 'gh pr view --json state,body' || {
    echo "${HOOK_REL} no longer resolves the pull request from the current branch" >&2
    echo "the branch-deleting hand-off path may no longer exist; re-read both surfaces before deleting this test" >&2
    printf '%s\n' "$code" | grep -n -- 'gh pr view' >&2 || true
    return 1
  }
  # And that the arm is genuinely the no-reference one of a pair, not an
  # unconditional lookup: a hook that dropped the reference-carrying arm would
  # still match the pattern above while behaving differently on every path.
  printf '%s\n' "$code" | grep -qF -- 'gh pr view --repo "$home" "$ref"'
}
