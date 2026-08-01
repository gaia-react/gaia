#!/usr/bin/env bats
# SPEC-064: doc-grep coverage for the widened machinery-path waive rule,
# stated in two places that no type-checker and no runtime assertion ever
# reads: the orchestrator's disposition rule in
# `wiki/concepts/PR Merge Workflow.md`'s `#### Cross-remit findings` section
# (the rule's owner), and the default Code Audit Team member's own
# member-side restatement in `.claude/agents/code-audit-frontend.md`'s
# `### B-mw. Machinery-path waive (file side)` section, plus the routing
# sentence all five Code Audit Team members carry identically. A prose
# requirement survives exactly as long as the next person editing those
# files remembers it, which is not a mechanism; this suite is the mechanism,
# the same pattern `doc-difficulty-prose.bats` in this directory uses: grep
# for the frozen literals, ground-truthed against the actual source text
# (verified against the merge-base-with-main commit, the tree as it stood
# before this SPEC's own Phase 1/2 changes landed), never a paraphrase.
#
# Section extraction: `extract_section` takes its terminator as an argument
# so a shallow scan never swallows a sibling section whole (see
# doc-difficulty-prose.bats's header for the concrete swallow hazard). The
# cross-remit section starts at `#### ` (H4) and its own doc names the
# terminator `^#{3,4} `; the B-mw section starts at `### ` (H3) and its doc
# names `^#{2,3} `. Both are used verbatim below, never a bare `^## `.
#
# B-mw start anchor stops at "Machinery-path waive", short of the trailing
# "(file side)": macOS's /usr/bin/awk strips a backslash out of a `-v`
# assignment's value before the regex engine ever sees it (`-v s='\(x\)'`
# arrives as the literal string `(x)`, unescaped grouping metacharacters,
# not a literal paren pair), so an anchor built with `\(...\)` silently
# fails to match on this platform. The heading is unique without the
# parenthesized suffix, so the anchor omits it rather than fighting the
# escaping.
#
# Add-then-pin vs sweep-then-pin: `wiki/concepts/PR Merge Workflow.md`
# carried no machinery-disposition prose at all before this SPEC, so Group 1
# below pins prose that was newly ADDED to that page, not swept from an
# older machinery-only phrasing (unlike `code-audit-frontend.md`, which
# Group 2 sweeps). There is deliberately no Group-2-style absence check on
# the wiki page: nothing to sweep there is not an oversight.
#
# Honest limits: Group 3 (the pull-request-body record) and Group 5
# (cross-member coverage) pin only what is greppable in these two prose
# surfaces, never whether an orchestrator actually disposes a live finding
# that way. The behavioral half of Group 5's claim is pinned separately, by
# task-tests-abuse-check's fixture case asserting a contract-shaped
# orchestrator waive on a `.gaia/cli/src/` path clears the abuse-check.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is
# 3.2, where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Every
# absence check below is written as `<positive-condition-for-the-bad-case>
# && return 1`, and a test whose last statement is such a check ends with an
# explicit `true`.
#
# `.gaia/tests/` is out of `wiki-style.md`'s scope entirely and release-
# excluded, so SPEC traceability above and in test names below is correct
# and expected here, unlike in the shipped prose this suite guards.

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

# extract_orchestrator_paragraph <file>
# Prints the "The orchestrator owns the disposition." paragraph: every
# physical line from the first line matching that opening sentence up to
# (excluding) the next blank line, so the same paragraph hard-wrapped at a
# different width in another file is still captured whole.
extract_orchestrator_paragraph() {
  awk '
    /^The orchestrator owns the disposition\./ { found=1 }
    found && NF==0 { exit }
    found { print }
  ' "$1"
}

# normalize_ws
# Collapses newlines and runs of whitespace to single spaces and trims the
# ends, so a paragraph wrapped at one width compares equal to the same
# paragraph wrapped at another.
normalize_ws() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  FRONTEND="$ROOT/.claude/agents/code-audit-frontend.md"
  WIKI="$ROOT/wiki/concepts/PR Merge Workflow.md"

  ALL_AGENTS=(
    "$FRONTEND"
    "$ROOT/.claude/agents/code-audit-github-workflows.md"
    "$ROOT/.claude/agents/code-audit-maintainer-node.md"
    "$ROOT/.claude/agents/code-audit-maintainer-prose.md"
    "$ROOT/.claude/agents/code-audit-maintainer-shell.md"
  )

  # Resolved offender label (decision 2), interpolated verbatim, never
  # re-derived.
  LABEL="machinery-waived-not-eligible"
}

# --- Group 1: the union rule is stated at both surfaces ---------------------

@test "Group 1: cross-remit section names both eligibility terms, gate-machinery and PR-changed-file" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "gate-machinery path" || return 1
  printf '%s\n' "$section" | grep -qF -- "already changes" || return 1
}

@test "Group 1: cross-remit section names the machinery-classifier identifier" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qE -- 'audit_path_is_machinery|AUDIT_MACHINERY_PATHS' || return 1
}

@test "Group 1: cross-remit section states an empty eligibility set disengages rather than opens the waive" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "disengages" || return 1
  printf '%s\n' "$section" | grep -qF -- "rather than opening it" || return 1
}

@test "Group 1: section B-mw names both eligibility terms, gate-machinery and PR-changed-file" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "gate-machinery path" || return 1
  printf '%s\n' "$section" | grep -qF -- "already changes" || return 1
}

@test "Group 1: section B-mw names the machinery-classifier identifier" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qE -- 'audit_path_is_machinery|AUDIT_MACHINERY_PATHS' || return 1
}

@test "Group 1: section B-mw states an empty eligibility set disengages rather than opens the waive" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "disengages" || return 1
  printf '%s\n' "$section" | grep -qF -- "rather than opening it" || return 1
}

# --- Group 2: no machinery-only phrasing survives ----------------------------
# wiki/concepts/PR Merge Workflow.md carries no absence checks here: it had
# no machinery-disposition prose to sweep before this SPEC (see header).

@test "Group 2: the retired offender label is absent from code-audit-frontend.md and PR Merge Workflow.md" {
  local f
  for f in "$FRONTEND" "$WIKI"; do
    grep -qF -- "machinery-waived-not-machinery" "$f" && {
      echo "retired offender label survives in $f" >&2
      return 1
    }
  done
  true
}

@test "Group 2: code-audit-frontend.md drops the retired B-mw condition-2 machinery-only phrasing" {
  grep -qF -- "is a **gate-machinery path**" "$FRONTEND" && return 1
  true
}

@test "Group 2: code-audit-frontend.md drops the retired abuse-check 'is not a machinery path' phrasing" {
  grep -qF -- "is **not** a machinery path" "$FRONTEND" && return 1
  true
}

@test "Group 2: code-audit-frontend.md drops the retired 'only for a genuine machinery path' closing instruction" {
  grep -qF -- "only for a genuine machinery path" "$FRONTEND" && return 1
  true
}

@test "Group 2: code-audit-frontend.md drops the retired disposition-semantics 'on a gate-machinery path' phrasing" {
  grep -qF -- "on a gate-machinery path" "$FRONTEND" && return 1
  true
}

# --- Group 3: the pull-request-body record -----------------------------------
# The heading literal is asserted WITH its surrounding backtick, per its own
# doc: it appears inline in backticks in both files, deliberately, never as
# a column-0 heading (both target files parse their own column-0 headings
# structurally). Matching the backtick-wrapped form is what rules out a
# stray column-0 occurrence satisfying this check by accident.

@test "Group 3: cross-remit section carries the pull-request-body heading and all three record fields" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- '`## Out-of-scope machinery findings (recorded, not filed)`' || return 1
  printf '%s\n' "$section" | grep -qF -- "file:line" || return 1
  printf '%s\n' "$section" | grep -qF -- "failure mode" || return 1
  printf '%s\n' "$section" | grep -qF -- "dedup key" || return 1
}

@test "Group 3: section B-mw carries the pull-request-body heading and all three record fields" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- '`## Out-of-scope machinery findings (recorded, not filed)`' || return 1
  printf '%s\n' "$section" | grep -qF -- "file:line" || return 1
  printf '%s\n' "$section" | grep -qF -- "failure mode" || return 1
  printf '%s\n' "$section" | grep -qF -- "dedup key" || return 1
}

# --- Group 4: the waive files nothing ----------------------------------------
# Presence checks on the three negative statements, not absence-of-token:
# the cross-remit section legitimately names the file-tech-debt skill in its
# filing branch, so an absence check would contradict the rule's own text.

@test "Group 4: cross-remit section states the waive files nothing" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "no tech-debt issue" || return 1
  printf '%s\n' "$section" | grep -qF -- "no issue number" || return 1
  printf '%s\n' "$section" | grep -qF -- ".gaia/local/debt/refresh-requested" || return 1
}

@test "Group 4: section B-mw states the waive files nothing" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "do **not** file a \`tech-debt\` issue" || return 1
  printf '%s\n' "$section" | grep -qF -- "\`issue_number\` unset" || return 1
  printf '%s\n' "$section" | grep -qF -- "do **not** touch the debt-count sentinel" || return 1
}

# --- Group 5: cross-member coverage is stated --------------------------------
# Greppable half only; the behavioral half (a live orchestrator waive on a
# non-default-member path) is pinned by task-tests-abuse-check's fixture.

@test "Group 5: cross-remit section states cross-member coverage regardless of surfacing member" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "every out-of-scope finding the orchestrator disposes" || return 1
}

@test "Group 5: cross-remit section names the four non-default-member surfaces" {
  local section
  section="$(extract_section_or_fail "$WIKI" '^#### Cross-remit findings' '^#{3,4} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- ".gaia/cli/src/" || return 1
  printf '%s\n' "$section" | grep -qF -- ".claude/skills/" || return 1
  printf '%s\n' "$section" | grep -qF -- ".gaia/scripts/" || return 1
  printf '%s\n' "$section" | grep -qF -- ".claude/hooks/" || return 1
}

# --- Group 6: the routing sentence is one sentence in five files ------------

@test "Group 6: the routing paragraph is present in all five Code Audit Team members" {
  local f out
  for f in "${ALL_AGENTS[@]}"; do
    out="$(extract_orchestrator_paragraph "$f")"
    [ -n "$out" ] || {
      echo "the orchestrator-owns-the-disposition paragraph is missing from $f" >&2
      return 1
    }
  done
}

@test "Group 6: the routing paragraph is byte-identical across all five members after whitespace normalization" {
  local f first cur
  first="$(extract_orchestrator_paragraph "${ALL_AGENTS[0]}" | normalize_ws)"
  for f in "${ALL_AGENTS[@]}"; do
    cur="$(extract_orchestrator_paragraph "$f" | normalize_ws)"
    [ "$cur" = "$first" ] || {
      echo "routing paragraph in $f diverges from ${ALL_AGENTS[0]} after whitespace normalization" >&2
      return 1
    }
  done
}

@test "Group 6: each member's routing paragraph names gate machinery and the pull request's own changed files" {
  local f para
  for f in "${ALL_AGENTS[@]}"; do
    para="$(extract_orchestrator_paragraph "$f")"
    printf '%s\n' "$para" | grep -qF -- "gate machinery" || {
      echo "$f's routing paragraph does not name gate machinery" >&2
      return 1
    }
    printf '%s\n' "$para" | grep -qF -- "already changes" || {
      echo "$f's routing paragraph does not name the pull request's own changed files" >&2
      return 1
    }
  done
}

@test "Group 6: no member's routing paragraph still carries the retired unconditional clause" {
  local f para
  for f in "${ALL_AGENTS[@]}"; do
    para="$(extract_orchestrator_paragraph "$f")"
    printf '%s\n' "$para" | grep -qF -- "or files it as a tech-debt issue when it is not" && {
      echo "$f's routing paragraph still carries the retired unconditional clause" >&2
      return 1
    }
  done
  true
}

# --- Group 7: the label literal ----------------------------------------------

@test "Group 7: section B-mw's abuse-check paragraph names the resolved offender label" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^### B-mw\. Machinery-path waive' '^#{2,3} ')" || return 1
  printf '%s\n' "$section" | grep -qF -- "$LABEL" || return 1
}
