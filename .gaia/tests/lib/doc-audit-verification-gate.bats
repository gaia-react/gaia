#!/usr/bin/env bats
# doc-grep coverage for `/gaia-audit`'s classification-verification gate, the
# Run-vs-Skip recommendation stated only as prose in
# `.claude/skills/gaia/references/audit.md` and read by a main conversation
# that executes it literally.
#
# The defect this pins: the two bullets did not partition. `shrink` and
# `replace` name ONE action type, not two -- `### Shrink / Convert` is the
# only block template carrying `type: replace`, under the id `shrink-{nnn}`,
# and Step 2 emits its cross-store CONFLICT resolutions as that same block.
# So "Recommend Run ... any CONFLICT-driven `replace`" and "Skip is eligible
# ... only git-reversible `shrink` / `replace` on in-repo files" both fired on
# a report of CONFLICT-driven replaces, and the gate tagged one of them
# `(Recommended)` on no stated basis -- including the Skip the Run bullet
# exists to prevent. Reachable on the ordinary path: a `.claude/rules/*.md`
# file contradicting its canonical wiki page resolves to exactly that action.
#
# THREE surfaces state the criterion and all three are pinned: the rule
# itself, the `description` string of the Skip option (what the operator
# actually reads at the `AskUserQuestion`), and the wiki concept page that
# describes the round. A fix landing on some and not the rest ships the
# superseded criterion anyway, which is not hypothetical: the first pass of
# this very fix corrected the two `audit.md` surfaces and left the wiki page
# stating the criterion it had just rejected. Two audit members found that
# independently, and the hazard is concrete rather than cosmetic: Step 2
# classifies a contradiction between two committed files as a project-internal
# CONFLICT and emits a `replace` on the non-authoritative one, so a later run
# could find the playbook contradicting the wiki page on this very subject and
# resolve it in the wrong direction.
#
# A fourth surface is a real possibility, so the sweep that found the third is
# worth repeating rather than trusting this count: `grep -rIn 'git-reversible'
# --include='*.md'` over the tracked tree.
#
# Nothing type-checks a playbook and no runtime assertion fires when a
# sentence goes missing, so this suite is the mechanism, following
# `doc-audit-remedy-set.bats` and `doc-difficulty-prose.bats` in this
# directory: grep for frozen literals, ground-truthed against the actual
# source text rather than a paraphrase.
#
# Scoping differs by surface, deliberately. The `audit.md` assertions
# (Groups 1 and 2) are **section-scoped**: started at the gate's `^## `
# heading and terminated on the `^### Dispatch` heading that follows it. The
# terminator is the H3 rather than the next `^## ` because the round owns
# three H3 subsections whose text discusses the same action names; a `^## `
# terminator would pull them in and let an assertion be satisfied from
# outside the gate. The wiki assertions (Group 3) are **whole-file**, because
# that page states the criterion in a paragraph with no stable heading
# anchor; see the `setup()` comment for what keeps that non-vacuous.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# `audit.md` is `manifest: owned`, so the shipped prose cites no issue number;
# `doc-audit-remedy-set.bats` already asserts that file-wide and this suite
# does not duplicate it.

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
# extract_section, plus guards on both ends so a renamed heading fails loudly
# instead of greening the suite.
#
# Never call this on the left of a pipe: a pipeline's exit status is its LAST
# command's, so `extract_section_or_fail ... | normalize_ws` discards the
# `return 1` and hands back an empty string with status 0, which greens every
# `&& return 1` absence check below. Capture first, normalize second.
#
# An unmatched START anchor yields an empty section, which greens every
# absence check. An unmatched TERMINATOR is the quieter hazard: awk runs to
# EOF and the "section" swallows the rest of the file, so a literal that is
# not unique file-wide could satisfy an assertion from text outside the gate
# while the gate itself had lost the sentence. The section must therefore not
# be the file's last; this one has the whole apply procedure after it.
# `doc-audit-remedy-set.bats`'s copy carries the full rationale. The copies
# are deliberately separate: the same helper name elsewhere in this directory
# guards the start anchor only.
extract_section_or_fail() {
  local out start_line
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  # Locate the start line with the SAME engine `extract_section` used: awk's
  # `-v` consumes one backslash level at assignment time, so an escaped ERE
  # means different things to awk and to `grep -E`, and an unresolved
  # `start_line` would silently become `tail -n +1`.
  start_line="$(awk -v start="$2" '$0 ~ start { print NR; exit }' "$1")"
  [ -n "$start_line" ] || {
    echo "start anchor '${2}' resolved to no line number in ${1}" >&2
    return 1
  }
  # The terminator must match STRICTLY AFTER the start line. A file-wide
  # match proves nothing while the section still runs to EOF.
  awk -v s="$start_line" -v term="$3" 'NR > s && $0 ~ term { found = 1; exit } END { exit !found }' "$1" || {
    echo "terminator '${3}' matches nothing after line ${start_line} of ${1}; the section ran to EOF and swallowed the rest of the file" >&2
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
  WIKI="$ROOT/wiki/concepts/GAIA Audit.md"

  # `-s`, not `-f`: an empty file would satisfy `-f` and then green every
  # absence check below on nothing.
  for f in "$AUDIT" "$WIKI"; do
    [ -s "$f" ] || {
      echo "missing or empty $f" >&2
      return 1
    }
  done

  GATE="$(extract_section_or_fail "$AUDIT" '^## Classification-verification round' '^### Dispatch the three lenses')"
  GATE="$(printf '%s\n' "$GATE" | normalize_ws)"

  # The wiki page states the criterion in one paragraph rather than a bounded
  # section, and the page's own headings are not stable anchors for it, so
  # this one is a whole-file read.
  #
  # What keeps it non-vacuous is the **positive/negative pairing**, not the
  # `-s` guard above. `-s` catches only absent-or-empty; a truncated page of
  # one byte passes it, leaves `WIKI_TEXT` effectively empty, and greens the
  # Group 3 absence check on nothing. The paired positive assertion is what
  # fails there. So any wiki absence check added below must keep a paired
  # positive, or it is hollow.
  WIKI_TEXT="$(normalize_ws <"$WIKI")"
}

# --- Group 1: the rule's two bullets partition -----------------------------
# Run fires on any action that is irreversible or carries contradiction risk;
# Skip is the carve-out for everything else. Overlap means neither earns the
# `(Recommended)` tag, and the case that overlapped was the destructive one.

@test "the run recommendation still names the irreversible memory actions" {
  grep -qF -- 'any memory `delete` / `delete-entry`' <<<"$GATE"
}

@test "the run recommendation names a CONFLICT-driven replace as forcing it" {
  grep -qF -- 'any CONFLICT-driven `replace`' <<<"$GATE"
}

@test "skip eligibility excludes the CONFLICT-driven actions the run bullet claims" {
  # The whole clause, not the bare exclusion: this file discusses
  # CONFLICT-driven actions in several places, and a bare grep would be
  # satisfied by any of them if the clause itself were dropped.
  grep -qF -- 'only when every action is a git-reversible, non-CONFLICT-driven `shrink` on an in-repo (non-memory) file' <<<"$GATE"
}

@test "skip eligibility is exclusive, so no report falls between the two bullets" {
  # A partition needs no gap as well as no overlap. Without this sentence the
  # default for a report of, say, promotes alone is left to inference.
  grep -qF -- 'Recommend Run in every other case' <<<"$GATE"
}

@test "the gate names how to establish the predicate from the report" {
  # Without this, the predicate is unresolvable from the artifact and the
  # failure is fail-OPEN rather than fail-to-Run: a CONFLICT-driven action is
  # emitted as the same `shrink` block as any other, and Step 2's
  # project-internal branch requires no contradiction token in `reason`, so an
  # executor reading reasons forms a confident "non-CONFLICT-driven" and
  # recommends Skip on exactly the report class the Run bullet exists to
  # force. The Summary's `Conflicts:` count is the handle that already exists.
  grep -qF -- 'Establish "non-CONFLICT-driven" from the Summary'"'"'s `Conflicts:` count' <<<"$GATE"
  grep -qF -- 'only `Conflicts: 0` establishes it' <<<"$GATE"
}

@test "skip eligibility no longer admits every replace action" {
  # The original defect, verbatim. `shrink` / `replace` is one action type
  # under two names, so this phrasing admitted the CONFLICT-driven replaces
  # the run bullet names.
  grep -qF -- 'the actions are only git-reversible `shrink` / `replace` on in-repo' <<<"$GATE" && return 1
  true
}

# --- Group 2: the operator-facing option restates the same rule ------------
# The rule is what the executor applies; this description is what the human
# reads in the AskUserQuestion. They must not disagree.

@test "the skip option description carries the exclusion the rule states" {
  grep -qF -- 'Best when every action is a git-reversible, non-CONFLICT-driven shrink on an in-repo file.' <<<"$GATE"
}

@test "the skip option description no longer states the superseded criterion" {
  grep -qF -- 'Best when the actions are only git-reversible shrinks on in-repo files' <<<"$GATE" && return 1
  true
}

# The tag is stated once, as a rule, and baked into neither literal. A rule
# that says "present the recommended option first, carrying the tag" plus a
# literal carrying it on one branch is two encodings of one instruction, and
# the second is correct only when Run is the recommendation. The likely miss
# is the tag rather than the order, which renders `Skip the round` first and
# `Run the round (Recommended)` second: two contradictory signals in one
# prompt, which is the same "(Recommended) on no stated basis" failure this
# gate was rewritten to remove.

@test "the recommended tag is stated as a rule" {
  grep -qF -- 'Present the recommended option FIRST, carrying the `(Recommended)` tag' <<<"$GATE"
}

@test "neither option literal bakes the recommended tag into label or description" {
  # Both fields, not just `label`: putting the tag in an option's
  # `description` instead reproduces the identical contradictory-signal
  # defect, and a `label`-only anchor greens on it. `[^"]*` is bounded by the
  # closing quote, so the legitimate `(Recommended)` in the rule sentence
  # cannot satisfy this from across the flattened section.
  grep -qE '(label|description): "[^"]*\(Recommended\)' <<<"$GATE" && return 1
  true
}

# --- Group 3: the wiki page states the same criterion ----------------------
# The third surface. It is the one a maintainer reads to learn what the round
# does, and it is not covered by either extraction above.

@test "the wiki page states skip eligibility as the narrow carve-out" {
  grep -qF -- 'skipping it is a legitimate recommendation only when every proposed action is a git-reversible, non-CONFLICT-driven shrink on an in-repo, non-memory file' <<<"$WIKI_TEXT"
}

@test "the wiki page no longer says a set of git-reversible shrinks may skip" {
  # The superseded phrasing, verbatim. `shrink` and `replace` are one action
  # type, so an unqualified "git-reversible shrinks" readmits exactly the
  # CONFLICT-driven case the rule excludes.
  grep -qF -- 'a set of git-reversible shrinks may legitimately skip it' <<<"$WIKI_TEXT" && return 1
  true
}
