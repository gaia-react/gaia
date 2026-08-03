#!/usr/bin/env bats
# doc-grep coverage for `/gaia-audit`'s over-budget remedy contract, stated
# only as prose in `.claude/skills/gaia/references/audit.md` Step 3 and read
# by a Sonnet Stage 1 that executes it literally. The defect this pins:
# Step 3 listed three remedies as a menu ("propose one of: ...") with nothing
# saying they are independent, so a run that found the first remedy blocked
# concluded the whole file was unfixable and proposed nothing at all, for
# every file, on every round. Two of the three were never blocked.
#
# Nothing type-checks a playbook and no runtime assertion fires when a
# sentence goes missing, so this suite is the mechanism, following
# `doc-difficulty-prose.bats` and `doc-machinery-waive-prose.bats` in this
# directory: grep for frozen literals, ground-truthed against the actual
# source text rather than a paraphrase.
#
# Section extraction: every scoped assertion runs against the `## Step 3`
# section only, terminated on the next `^## `. Step 3 starts at H2 and owns
# an H3 subsection, so `^## ` is the correct same-or-shallower terminator
# and keeps that subsection inside the match (see doc-difficulty-prose.bats's
# header for the swallow hazard the argument exists to avoid). The one
# unscoped group is the portability check, which is a whole-file absence.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Every
# absence check below is written as `<positive-condition-for-the-bad-case>
# && return 1`, and a test whose last statement is such a check ends with an
# explicit `true`.
#
# `.gaia/tests/` is release-excluded and outside `wiki-style.md`'s scope, so
# the failure-mode narration above is correct here in a way it would not be
# in the shipped prose this suite guards.

# extract_section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> (inclusive) up to,
# excluding, the next line matching <terminator_ERE>.
extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# extract_section_or_fail <file> <start_ERE> <terminator_ERE>
# extract_section, plus a guard: fails loudly, rather than passing
# vacuously, when the start anchor matches nothing (a renamed or deleted
# heading).
#
# Never call this on the left of a pipe. A pipeline's exit status is its
# LAST command's, so `extract_section_or_fail ... | normalize_ws` discards
# this function's `return 1` and hands back an empty string with status 0,
# which greens every `&& return 1` absence check in the suite on a section
# that no longer exists. Capture first, normalize second; both call sites
# below do.
#
# Both ends are guarded. An unmatched START anchor yields an empty section,
# which greens every absence check. An unmatched TERMINATOR is the quieter
# hazard: awk runs to EOF and the "section" swallows the rest of the file, so
# a literal that is not unique file-wide (`per file`, `source_expect_sha256`)
# could satisfy a scoped assertion from text outside the section while the
# section itself had lost the sentence.
#
# Two constraints on callers, both deliberate:
#
#   - **The section must not be the file's last.** A final section has no
#     terminator after it by construction and running to EOF is the correct
#     extraction there, but this helper cannot tell that case from a deleted
#     heading, so it refuses both. Both call sites below scope a section with
#     content after it. A caller that needs a final section wants a different
#     helper, not a loosened terminator arm.
#   - **This guard is local to this suite.** The same helper name in
#     `doc-difficulty-prose.bats` and `doc-machinery-waive-prose.bats` guards
#     the start anchor only, and the former's `section_line_range` documents
#     the opposite convention (fall back to the file's last line). Do not
#     assume a shared contract across the three; they are separate copies.
extract_section_or_fail() {
  local out start_line
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  # The terminator must match somewhere STRICTLY AFTER the start line. A
  # file-wide match proves nothing (`^## ` matches every earlier H2 while
  # this section still runs to EOF), and the start line itself can match the
  # terminator by design, since a `## ` section is bounded by the next `## `.
  #
  # Locate that line with the SAME engine `extract_section` used. awk's `-v`
  # consumes one backslash level at assignment time, so an escaped ERE means
  # different things to awk and to `grep -E`; re-finding the line with grep
  # would let the two disagree, and an unresolved `start_line` would silently
  # become `tail -n +1`, degrading this back into the file-wide check the
  # paragraph above rejects.
  start_line="$(awk -v start="$2" '$0 ~ start { print NR; exit }' "$1")"
  [ -n "$start_line" ] || {
    echo "start anchor '${2}' resolved to no line number in ${1}" >&2
    return 1
  }
  # Same engine for the terminator, for the same reason: `grep -E` and awk
  # disagree on an escaped ERE, so validating the boundary with grep can
  # accept a line the extraction never terminated on.
  awk -v s="$start_line" -v term="$3" 'NR > s && $0 ~ term { found = 1; exit } END { exit !found }' "$1" || {
    echo "terminator '${3}' matches nothing after line ${start_line} of ${1}; either the section ran to EOF and swallowed the rest of the file, or it is the file's last section, which this helper does not support" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# normalize_ws
# Collapses newlines and runs of whitespace to single spaces and trims the
# ends, so a sentence rewrapped at another width still compares equal.
normalize_ws() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AUDIT="$ROOT/.claude/skills/gaia/references/audit.md"

  # `-s`, not `-f`: an empty file would satisfy `-f` and then green the
  # whole-file absence check in Group 5 on nothing.
  [ -s "$AUDIT" ] || {
    echo "missing or empty $AUDIT" >&2
    return 1
  }

  STEP3="$(extract_section_or_fail "$AUDIT" '^## Step 3, Auto-load budget' '^## ')"
  STEP3="$(printf '%s\n' "$STEP3" | normalize_ws)"
}

# --- Group 1: the budget is per file, with no aggregate over rules ---------
# The DECISION this pins: a split into two under-budget rules satisfies the
# budget. It is settled by the oracle that RAISES the nudge Step 3 answers
# (`check-updates.sh`'s per-file `project_drift` loop), so an audit asserting
# an aggregate would propose work that cannot clear the indicator.

@test "step 3 states the budget is per file" {
  grep -qF -- 'per file' <<<"$STEP3"
}

@test "step 3 denies any aggregate budget over the rules directory" {
  grep -qF -- 'no aggregate budget exists over `.claude/rules/*.md`' <<<"$STEP3"
}

@test "step 3 answers the split question outright, not by implication" {
  grep -qF -- 'splitting one over-budget rule into two rules that are each under budget satisfies the budget' <<<"$STEP3"
}

@test "step 3 names the per-file signal that raises the nudge it answers" {
  grep -qF -- 'project_drift' <<<"$STEP3"
}

# --- Group 2: the three remedies are independent, not a menu ---------------

@test "step 3 requires all three remedies to be evaluated, in order" {
  grep -qF -- 'Evaluate all three, in this order' <<<"$STEP3"
}

@test "step 3 states that one blocked remedy never makes a file unfixable" {
  grep -qF -- 'a single blocked remedy never makes a file unfixable' <<<"$STEP3"
}

@test "step 3 no longer offers the remedies as a pick-one menu" {
  # The original defect, verbatim: a menu sentence with nothing saying the
  # three are independent.
  grep -qF -- 'propose one of: inline facts' <<<"$STEP3" && return 1
  true
}

@test "step 3 forbids proposing nothing for a file on one remedy's blocker" {
  grep -qF -- 'Never report an over-budget file as unfixable, or propose nothing for it, on the strength of one blocked remedy' <<<"$STEP3"
}

# --- Group 3: each remedy names its action shape and its blocker ----------

@test "remedy 1 names the same-file drift condition that blocks it" {
  grep -qF -- 'source_expect_sha256' <<<"$STEP3"
  grep -qF -- "a \`promote\` whose \`source_path\` is the over-budget file" <<<"$STEP3"
}

@test "remedy 1 is stated as unavailable outright, not as a live conditional" {
  # Both of remedy 1's actions name the over-budget file by construction, so
  # a conditional phrasing ("unavailable whenever source and target are the
  # same file") is always true and reads as though some other case applies.
  # A Stage 1 hunting for that case finds none and cannot satisfy the
  # closing rule that a file is never reported unfixable.
  grep -qF -- 'unavailable for an over-budget file outright, not conditionally' <<<"$STEP3"
}

@test "remedy 1 forbids constructing the pair rather than relying on a skip" {
  # `## Ordering` orders the pair, but Step 5's drift bullets name
  # `expect_sha256` / `before:` / `expect:`, none of which a promote carries,
  # so nothing in the playbook guarantees Stage 2 skips one. The instruction
  # not to build the pair is what makes remedy 1's unavailability safe, and
  # it must not decay back into a claim about what Stage 2 does.
  grep -qF -- 'Do not construct that pair' <<<"$STEP3"
  grep -qF -- 'reads that as drift, and skips' <<<"$STEP3" && return 1
  true
}

@test "remedy 1 sends a blocked evaluation on to remedy 2 rather than stopping" {
  grep -qF -- 'Record the blocker against this remedy, then evaluate remedy 2' <<<"$STEP3"
}

@test "remedy 2 is a single shrink and is named as unblocked" {
  grep -qF -- 'A single `shrink` on one path, which nothing in `## Ordering` blocks' <<<"$STEP3"
}

# No backticks in a test name: bats evaluates the name in a context where a
# backticked run is command substitution, so the name silently loses the text
# and, with a different payload, would run it.
@test "the remedies name actions in the vocabulary the Ordering section uses" {
  # `## Ordering` sequences `shrink`, never `replace`, so a remedy asserting
  # something about that section in terms of `replace` sends a reader to a
  # section where the word does not appear. The identity is bound once, at
  # remedy 1's first use.
  grep -qF -- 'a `shrink` (`type: replace`) on that same file' <<<"$STEP3"
}

@test "remedy 3 states that no action type expresses a split" {
  grep -qF -- 'Not expressible as an action' <<<"$STEP3"
  grep -qF -- 'no action type creates a new non-wiki file' <<<"$STEP3"
}

@test "remedy 3 routes to the out-of-scope section so the work is tracked" {
  grep -qF -- 'Record it in `## Out-of-scope findings`' <<<"$STEP3"
}

@test "remedy 3 requires the split to carry its own paths scope" {
  # Without this, two same-glob siblings always co-load: the count is
  # satisfied and nothing a session loads is reduced.
  grep -qF -- 'carry its own `paths:` scope' <<<"$STEP3"
}

# --- Group 4: the requirement has a home in the strict report schema -------
# Step 3's contract is only executable if Stage 1 has somewhere to write the
# per-remedy outcome. The Summary template's over-budget line is that place.

@test "the report template's over-budget line carries the per-remedy outcome" {
  # The template body is a fenced block whose own contents open with `##`
  # headings, so a `^## ` terminator would exit at the fence's first
  # `## Summary` line and never reach the line under test. Terminate on the
  # fence close instead, which bounds the assertion to the template itself.
  local summary
  summary="$(extract_section_or_fail "$AUDIT" '^### Report template' '^````$')"
  summary="$(printf '%s\n' "$summary" | normalize_ws)"
  # The oos slot is load-bearing: remedy 3 is never *proposed*, it is
  # recorded, so a template admitting only a proposal renders the one case
  # this contract exists to create as "every remedy rejected".
  grep -qF -- 'Over-budget files: {list; per file, the remedy proposed or the oos-{nnn} recorded, plus the outcome of every remedy not taken}' <<<"$summary"
}

@test "the report template does not demand an aggregate budget over the rules" {
  local summary
  summary="$(extract_section_or_fail "$AUDIT" '^### Report template' '^````$')"
  summary="$(printf '%s\n' "$summary" | normalize_ws)"
  # Names the two rows rather than a category word Step 3 never uses, so the
  # number is read off the table instead of guessed.
  grep -qF -- "the sum of Step 3's budgets for wiki/hot.md and root CLAUDE.md; the rules aggregate has none" <<<"$summary"
}

# --- Group 5: portability -------------------------------------------------
# This file is `manifest: owned` and ships to adopters, where a
# gaia-react/gaia issue number identifies nothing. The blocking condition is
# described, never cited.

@test "audit.md cites no issue number anywhere" {
  grep -qE '#[0-9]{3,}' "$AUDIT" && return 1
  true
}
