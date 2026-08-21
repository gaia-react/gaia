#!/usr/bin/env bats
#
# Doc-conformance suite for the single-carrier rule in `/gaia-debt`'s playbook
# (.claude/skills/gaia/references/debt.md): the PR body is the only place a
# `Closes #N` may live, because it is the only carrier the drop path can
# correct.
#
# What it guards. A squash merge concatenates the branch's commit bodies into
# the merge commit message and GitHub parses closing keywords out of that
# message, so a trailer written into a commit closes its issue no matter what
# the PR body says. A member dropped from a batch after its commits exist
# therefore closes as `COMPLETED` with nothing fixed, silently: the issue
# leaves the backlog, leaves the count, and a closed issue is indistinguishable
# from a fixed one.
#
# Four invariants, one per failure route:
#   1. the commit step forbids a closing keyword in any commit message, and
#      says why (the squash concatenation), so the rule is not folklore;
#   2. a drop after the commits are written rewrites those commit messages,
#      not just the PR body;
#   3. the post-merge block verifies the set of issues the merge actually
#      closed against the set the run intended to close, which is what turns a
#      silent wrong outcome into a visible one;
#   4. all three pre-implementation peels (the security, staleness, and spec
#      screens)
#      state that their position ahead of the commit step is load-bearing, so a
#      later reordering onto the drop path is a deliberate act rather than an
#      accident.
#
# Section-scoped, not whole-file: every assertion runs over the body of the one
# section that owns the invariant, so a phrase surviving somewhere else in the
# file cannot green a section that dropped it. Extraction terminates on the
# next same-or-shallower heading, so an H2's H3 children stay inside it and an
# H3's H3 siblings do not.
#
# The same hazard reappears WITHIN a section, and two needles here are chosen
# against it: a bare `fixes` is satisfied by unrelated prose in the section
# that owns the keyword rule, and a bare `Closes #N` by a second occurrence in
# the section that owns the drop path. Each needle below is pinned to text only
# its own clause can produce; prove any new one by deleting the clause it
# guards and watching the test go red.
#
# Extraction constraint: the terminator arm matches a `#`-prefixed line with no
# fence tracking, so a shell comment at column 0 inside a fenced block would
# read as an H1 and truncate the haystack early. No section read here carries
# one. The error direction is over-strict (a truncated haystack fails, it never
# passes falsely), so adding such a fenced example is a deliberate choice that
# reds this suite rather than a silent hole.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
}

# extract_section <heading-line-prefix>
# Prints the body of the first section whose heading line starts with the given
# literal prefix (heading included), up to but excluding the next heading of
# the same or a shallower level. Prints nothing when no heading matches, which
# fails the non-empty assertion each test opens with rather than passing
# vacuously over an empty haystack.
extract_section() {
  awk -v want="$1" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "$DEBT_MD"
}

# --- 1. the commit step forbids a closing keyword ---------------------------

@test "the commit step forbids a closing keyword in any commit message" {
  section="$(extract_section '## Resolve the selected unit')"
  [ -n "$section" ]
  grep -Eiq "closing keyword" <<<"$section"
  grep -Eiq "no commit message" <<<"$section"
}

@test "the commit step names the alternate closing-keyword spellings" {
  # `Closes` is not the only spelling GitHub acts on; a rule naming it alone
  # reads as a ban on one word rather than on the keyword family.
  #
  # The needle is the keyword pair as written, not the bare words: this same
  # section's step 3 reads "Implement all fixes in the unit", so a bare
  # `fixes` needle is satisfied by prose that has nothing to do with the rule
  # and stays green when step 4 drops the spelling.
  section="$(extract_section '## Resolve the selected unit')"
  [ -n "$section" ]
  grep -qF -- '`fixes` / `resolves`' <<<"$section"
}

@test "the commit step names the squash concatenation as the reason" {
  section="$(extract_section '## Resolve the selected unit')"
  [ -n "$section" ]
  grep -Eiq "squash merge concatenates" <<<"$section"
}

@test "the PR body is stated as the sole carrier" {
  section="$(extract_section '## Resolve the selected unit')"
  [ -n "$section" ]
  grep -Eiq "sole carrier" <<<"$section"
}

# --- 2. the drop path reaches the commit messages ---------------------------

@test "the drop path rewrites the commit messages, not only the PR body" {
  section="$(extract_section '### Dropping a member after its commits are written')"
  [ -n "$section" ]
  grep -qF -- "--amend" <<<"$section"
  grep -Eiq "force-push" <<<"$section"
}

@test "the drop path also corrects the PR body and releases the claim" {
  # Pins the correction step, not the bare `Closes #N` token: the section's
  # closing paragraph carries that token too, so a token needle greens even
  # with the correction step deleted, which is the outcome this invariant
  # exists to prevent.
  section="$(extract_section '### Dropping a member after its commits are written')"
  [ -n "$section" ]
  grep -qF -- "line from the PR body" <<<"$section"
  grep -qF -- "--remove-label in-progress" <<<"$section"
}

# --- 3. the post-merge close-set check --------------------------------------

@test "the post-merge block verifies the closed set against the intended set" {
  section="$(extract_section '## Drive the PR to merge')"
  [ -n "$section" ]
  grep -Eiq "intended close set" <<<"$section"
  grep -qF -- "gh issue reopen" <<<"$section"
}

# --- 4. the three pre-implementation peels pin their ordering ---------------

@test "the security screen states its pre-implementation position is load-bearing" {
  section="$(extract_section '## Fix-time security screen')"
  [ -n "$section" ]
  grep -Eiq "load-bearing" <<<"$section"
  grep -Eiq "no commits" <<<"$section"
}

@test "the staleness screen states its pre-implementation position is load-bearing" {
  section="$(extract_section '## Fix-time staleness screen')"
  [ -n "$section" ]
  grep -Eiq "load-bearing" <<<"$section"
  grep -Eiq "no commits" <<<"$section"
}

@test "the spec screen states its pre-implementation position is load-bearing" {
  section="$(extract_section '## Fix-time spec screen')"
  [ -n "$section" ]
  grep -Eiq "load-bearing" <<<"$section"
  grep -Eiq "no commits" <<<"$section"
}
