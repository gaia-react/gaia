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
extract_section_or_fail() {
  local out
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
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

  [ -f "$AUDIT" ] || {
    echo "missing $AUDIT" >&2
    return 1
  }

  STEP3="$(extract_section_or_fail "$AUDIT" '^## Step 3, Auto-load budget' '^## ' | normalize_ws)"
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
  grep -qF -- "the \`promote\`'s \`source_path\` is also that \`replace\`'s \`path\`" <<<"$STEP3"
}

@test "remedy 1 sends a blocked evaluation on to remedy 2 rather than stopping" {
  grep -qF -- 'Record the blocker against this remedy, then evaluate remedy 2' <<<"$STEP3"
}

@test "remedy 2 is a single replace and is named as unblocked" {
  grep -qF -- 'A single `replace` on one path, which nothing in `## Ordering` blocks' <<<"$STEP3"
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
  summary="$(extract_section_or_fail "$AUDIT" '^### Report template' '^````$' | normalize_ws)"
  grep -qF -- 'Over-budget files: {list; per file, the remedy proposed or, if none, all three remedies with the reason each was rejected}' <<<"$summary"
}

# --- Group 5: portability -------------------------------------------------
# This file is `manifest: owned` and ships to adopters, where a
# gaia-react/gaia issue number identifies nothing. The blocking condition is
# described, never cited.

@test "audit.md cites no issue number anywhere" {
  grep -qE '#[0-9]{3,}' "$AUDIT" && return 1
  true
}
