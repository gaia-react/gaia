#!/usr/bin/env bats
# UAT-011 (SPEC-053): doc-grep coverage for the difficulty-grading prose that
# spans four adopter-shipping files. The vocabulary and rubric
# (`.claude/skills/file-tech-debt/SKILL.md`), the two machine filing routes
# that grade against it (`.claude/agents/code-audit-frontend.md`'s
# `### E. Non-security disposition pipeline`, and the out-of-scope filing
# block in `.claude/skills/gaia/references/audit.md`), and the two consumer
# subcommands that surface the grade (`.claude/skills/gaia/references/debt.md`
# `list`/`why`) exist only as prose; nothing type-checks them and no runtime
# assertion fires if a future edit drops a sentence. A prose requirement
# survives exactly as long as the next person editing those files remembers
# it, which is not a mechanism, so this suite pins it the way
# `.gaia/tests/prose-audit/spec051-countability-prose.bats` pins the
# countable-findings rewrite: grep for the frozen literals, ground-truthed
# against the actual source text, not a paraphrase.
#
# Section extraction: a copied spec051 helper terminates on the next `^## `
# heading, which only stops correctly for an H2 section. Two of this suite's
# targets are H3 (`### E. Non-security disposition pipeline`, whose siblings
# `### F.` and `### G.` sit before the next `## ` heading), so a `^## `
# terminator run from `### E.` would swallow F and G whole and a `difficulty`
# mention in either would satisfy the presence groups below and silently
# escape the absence group that exists to catch exactly that. `extract_section`
# below takes the terminator as an argument and callers pass the
# same-or-shallower pattern for the heading depth they started at
# (`^#{2,3} ` from an `### ` start, `^## ` from a `## ` start), never a bare
# `^## ` regardless of start depth.
#
# Model naming: the SPEC bans naming a concrete model anywhere in this
# feature, but three of the four edited files already name one for unrelated,
# pre-existing reasons (`code-audit-frontend.md`'s `model: opus` frontmatter,
# `audit.md`'s several `sonnet` references), so a whole-file absence grep
# fails on landing and is the wrong check. Group 2 below scopes the check to
# lines that mention `difficulty` and to the rubric section alone, which is
# how the SPEC itself scopes the ban.
#
# Declined machine-conformance mechanism (rider RT-020). The sibling severity
# vocabulary gets stronger protection than a doc-grep: each Code Audit Team
# member declares its emittable gradings in a
# `<!-- gaia-audit:gradings: ... -->` marker, backed by a shared TypeScript
# map (`.gaia/cli/src/harden/severity-map.ts`) and a divergence test. The
# difficulty vocabulary deliberately does not get the parallel marker and map:
# three fixed values, a single consumer, no deterministic non-LLM reader, and
# no dispatch keyed on the value, so the divergence class the marker guards
# against does not arise here; this doc-grep suite is the proportionate
# check. If a later change routes on the grade or adds a fourth value, that
# calculus changes and the marker becomes worth adding.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Every absence
# check below is written as `<positive-condition-for-the-bad-case> &&
# return 1`, and a test whose last statement is such a check ends with an
# explicit `true`.
#
# `.gaia/tests/` is out of `wiki-style.md`'s scope entirely and release-
# excluded, so the UAT traceability above and in test names below is correct
# and expected here, unlike in the shipped prose this suite guards.

# assert_absent_across <ERE pattern> <file...>
# Fails the calling test if <pattern> (extended regex, case-insensitive)
# matches any listed file. Same shape as spec051's helper.
assert_absent_across() {
  local pattern="$1"
  shift
  local f
  for f in "$@"; do
    grep -Eiq -- "$pattern" "$f" && {
      echo "stale/misplaced phrase /${pattern}/ survives in ${f}" >&2
      return 1
    }
  done
  return 0
}

# assert_absent_fixed_across <fixed string> <file...>
# Same as above, but a literal substring match, used where the surrounding
# markdown (backticks, pipes, regex-alternation characters) makes a
# regex-based check fragile.
assert_absent_fixed_across() {
  local needle="$1"
  shift
  local f
  for f in "$@"; do
    grep -Fiq -- "$needle" "$f" && {
      echo "stale/misplaced phrase '${needle}' survives in ${f}" >&2
      return 1
    }
  done
  return 0
}

# assert_absent_fixed_cs_across <fixed string> <file...>
# Same as assert_absent_fixed_across, but case-SENSITIVE: used only for the
# capital-D "Difficulty:" check, where the lowercase "difficulty:" label
# literal is expected and common throughout these files, so a case-
# insensitive check would false-flag every one of them.
assert_absent_fixed_cs_across() {
  local needle="$1"
  shift
  local f
  for f in "$@"; do
    grep -Fq -- "$needle" "$f" && {
      echo "stale/misplaced phrase '${needle}' survives in ${f}" >&2
      return 1
    }
  done
  return 0
}

# extract_section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> (inclusive) up to,
# excluding, the next line matching <terminator_ERE>. The terminator is the
# caller's responsibility: pass `^#{2,3} ` for an `### ` start, `^## ` for a
# `## ` start. Never hardcode `^## ` regardless of the start depth, see the
# header note above.
extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# extract_section_or_fail <file> <start_ERE> <terminator_ERE>
# extract_section, plus the guard every section-scoped ABSENCE assertion needs.
# Returns non-zero, with a diagnostic, when the region comes back empty.
#
# Why this exists: an absence check reads `<extract> | grep -q needle && return 1`.
# If the start anchor stops matching, because a heading is renamed, reworded, or
# deleted, extract_section prints nothing, grep finds nothing, the `&&` short
# circuits, and the test passes having examined no text at all. The assertion
# that a requirement did NOT attach somewhere is exactly the kind that must fail
# loudly when it loses its subject, since a vacuous pass is indistinguishable
# from a real one in the TAP output.
#
# Callers MUST capture into a variable and check the status:
#
#   section="$(extract_section_or_fail "$F" '^## Heading' '^## ')" || return 1
#   printf '%s\n' "$section" | grep -qi needle && return 1
#
# Never pipe this helper directly into grep. A pipeline's exit status is the
# LAST command's, so the guard's non-zero return is discarded and the vacuous
# pass returns.
extract_section_or_fail() {
  local out
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# section_line_range <file> <start_ERE> <terminator_ERE>
# Echoes "<start_line> <end_line>" for the same region extract_section above
# would print, for callers that need line numbers rather than content (the
# Group 5 scoped-absence check). <end_line> is the file's last line if the
# terminator never matches after the start.
section_line_range() {
  local file="$1" start_pat="$2" term_pat="$3" start end
  start=$(awk -v p="$start_pat" '$0 ~ p { print NR; exit }' "$file")
  end=$(awk -v s="$start" -v p="$term_pat" 'NR > s && $0 ~ p { print NR - 1; exit }' "$file")
  if [ -z "$end" ]; then
    end=$(wc -l <"$file")
  fi
  printf '%s %s\n' "$start" "$end"
}

# ordering_query_fence_range <file>
# Echoes "<start_line> <end_line>" of debt.md's ordering query fenced code
# block, anchored the same way .gaia/tests/lib/doc-debt-query.bats's
# extract_query_fence anchors: the last ``` fence before the unique
# `--jq '` line opens the block, the first ``` fence after it closes it.
ordering_query_fence_range() {
  local file="$1" jq_line start end
  jq_line=$(grep -n -F -- "--jq '" "$file" | head -1 | cut -d: -f1)
  start=$(awk -v n="$jq_line" 'NR < n && /^```/ { s = NR } END { print s + 0 }' "$file")
  end=$(awk -v n="$jq_line" 'NR > n && /^```/ { print NR; exit }' "$file")
  printf '%s %s\n' "$start" "$end"
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  VOCAB="$ROOT/.claude/skills/file-tech-debt/SKILL.md"
  FRONTEND="$ROOT/.claude/agents/code-audit-frontend.md"
  AUDIT="$ROOT/.claude/skills/gaia/references/audit.md"
  DEBT="$ROOT/.claude/skills/gaia/references/debt.md"

  OTHER_AGENTS=(
    "$ROOT/.claude/agents/code-audit-github-workflows.md"
    "$ROOT/.claude/agents/code-audit-maintainer-node.md"
    "$ROOT/.claude/agents/code-audit-maintainer-prose.md"
    "$ROOT/.claude/agents/code-audit-maintainer-shell.md"
  )
}

# --- Section-extraction self-check -----------------------------------------

@test "the section helper terminates ### E. at the next same-or-shallower heading, not a bare ^## " {
  local out
  out="$(extract_section_or_fail "$FRONTEND" '^### E\. Non-security disposition pipeline' '^#{2,3} ')" || return 1
  printf '%s\n' "$out" | grep -qF -- "### F." && return 1
  printf '%s\n' "$out" | grep -qF -- "### G." && return 1
  printf '%s\n' "$out" | tail -n1 | grep -qF -- "### F." && return 1
  true
}

# --- Header self-check (AC#7) -----------------------------------------------

@test "the suite's own header records the declined RT-020 machine-conformance mechanism and its reason" {
  local self="$BATS_TEST_DIRNAME/doc-difficulty-prose.bats"
  grep -qF -- "RT-020" "$self" || return 1
  grep -qF -- "severity-map.ts" "$self" || return 1
  grep -qF -- "no dispatch keyed on the value" "$self" || return 1
}

# --- Group 1: the vocabulary file owns the rubric ---------------------------

@test "UAT-004: SKILL.md defines all three difficulty labels, each its own check" {
  grep -qF -- "difficulty:easy" "$VOCAB" || return 1
  grep -qF -- "difficulty:medium" "$VOCAB" || return 1
  grep -qF -- "difficulty:hard" "$VOCAB" || return 1
}

@test "UAT-003: SKILL.md's rubric states the three rows' observable properties" {
  grep -qF -- "no design decision left to make" "$VOCAB" || return 1
  grep -qF -- "a design decision the surrounding code settles" "$VOCAB" || return 1
  grep -qF -- "a design decision the surrounding code does not settle" "$VOCAB" || return 1
}

@test "UAT-003: SKILL.md states the tie-break and the axis claim" {
  grep -qF -- "Read the three rows top to bottom and take the first whose properties all hold." "$VOCAB" || return 1
  grep -qF -- "difficulty grades how much design the fix needs" "$VOCAB" || return 1
}

@test "UAT-004: SKILL.md's step 6 states the exactly-one-severity-exactly-one-difficulty invariant" {
  grep -qF -- "exactly one severity label and exactly one difficulty label" "$VOCAB" || return 1
}

@test "SKILL.md carries the three rider paragraphs beside the rubric block" {
  grep -qF -- "omits the label rather than guessing a grade" "$VOCAB" || return 1
  grep -qF -- "byte-for-byte, before it reaches any" "$VOCAB" || return 1
  grep -qF -- "carry no information about the finding" "$VOCAB" || return 1
}

@test "UAT-005: the label loop creates all three difficulty labels and still creates the five pre-existing ones" {
  grep -qF -- "for label in tech-debt severity:critical severity:important severity:suggestion" "$VOCAB" || return 1
  grep -qF -- "difficulty:easy difficulty:medium difficulty:hard wontfix; do" "$VOCAB" || return 1
}

@test "the label-loop prose count says eight, and the stale 'all five labels' phrasing is gone" {
  grep -qF -- "Create all eight labels idempotently" "$VOCAB" || return 1
  assert_absent_fixed_across "all five labels" "$VOCAB"
}

@test "UAT-004: both gh issue create forms carry --body-file, graded and ungraded" {
  grep -qF -- 'gh issue create --label tech-debt --label severity:<tier> --label difficulty:<grade> --body-file "$body_file"' "$VOCAB" || return 1
  grep -qF -- 'gh issue create --label tech-debt --label severity:<tier> --body-file "$body_file"' "$VOCAB" || return 1
}

@test "UAT-004: the issue-body schema section carries no difficulty line, and no capital-D Difficulty: line exists anywhere" {
  local section
  section="$(extract_section_or_fail "$VOCAB" '^## 5\. Issue body schema' '^## ')" || return 1
  printf '%s\n' "$section" | grep -qi 'difficulty' && return 1
  assert_absent_fixed_cs_across "Difficulty:" "$VOCAB"
}

# --- Group 2: the vocabulary lives in exactly one file, and names no model -

@test "the rubric's three row definitions live nowhere but the vocabulary file" {
  assert_absent_fixed_across "no design decision left to make" "$FRONTEND" "$AUDIT" "$DEBT"
  assert_absent_fixed_across "a design decision the surrounding code settles" "$FRONTEND" "$AUDIT" "$DEBT"
  assert_absent_fixed_across "a design decision the surrounding code does not settle" "$FRONTEND" "$AUDIT" "$DEBT"
}

@test "no difficulty-bearing line in any of the four edited files names a concrete model" {
  local f
  for f in "$VOCAB" "$FRONTEND" "$AUDIT" "$DEBT"; do
    if grep -i 'difficulty' "$f" | grep -qiE 'opus|sonnet|haiku|claude-'; then
      echo "a difficulty-bearing line in $f names a model" >&2
      return 1
    fi
  done
  true
}

@test "the rubric section in SKILL.md (## 7. Difficulty grade) names no model" {
  local section
  section="$(extract_section_or_fail "$VOCAB" '^## 7\. Difficulty grade' '^## ')" || return 1
  printf '%s\n' "$section" | grep -qiE 'opus|sonnet|haiku|claude-' && return 1
  true
}

# --- Group 3: the producer surfaces carry the requirement -------------------

@test "UAT-001: code-audit-frontend.md's section E requires a difficulty grade at filing time" {
  local section
  section="$(extract_section "$FRONTEND" '^### E\. Non-security disposition pipeline' '^#{2,3} ')"
  printf '%s' "$section" | grep -qF -- "difficulty grade" || return 1
  printf '%s' "$section" | grep -qF -- "at filing time, not by a later pass" || return 1
}

@test "UAT-001: code-audit-frontend.md's section E names the value set and the single rubric file" {
  local section
  section="$(extract_section "$FRONTEND" '^### E\. Non-security disposition pipeline' '^#{2,3} ')"
  printf '%s' "$section" | grep -qF -- "difficulty:easy|medium|hard" || return 1
  printf '%s' "$section" | grep -qF -- ".claude/skills/file-tech-debt/SKILL.md" || return 1
}

@test "UAT-001: code-audit-frontend.md's section E lists difficulty:<grade> among the idempotently-created labels" {
  local section
  section="$(extract_section "$FRONTEND" '^### E\. Non-security disposition pipeline' '^#{2,3} ')"
  printf '%s' "$section" | grep -qF -- "difficulty:<grade>" || return 1
}

@test "UAT-002: audit.md's out-of-scope block schema carries a difficulty field, graded at filing time" {
  grep -qF -- "difficulty: {easy | medium | hard" "$AUDIT" || return 1
  grep -qF -- "at filing time, not by a later pass" "$AUDIT" || return 1
}

@test "UAT-002: audit.md's filing rules map difficulty to the difficulty:<grade> label" {
  grep -qF -- "map \`difficulty\` → the \`difficulty:<grade>\` label" "$AUDIT" || return 1
}

@test "UAT-004: audit.md carries no capital-D Difficulty: body line" {
  assert_absent_fixed_cs_across "Difficulty:" "$AUDIT"
}

# --- Group 4: the requirement attaches nowhere else -------------------------

@test "difficulty never appears in the four Code Audit Team members with no out-of-scope filing route" {
  assert_absent_across "difficulty" "${OTHER_AGENTS[@]}"
}

@test "difficulty never appears in code-audit-frontend.md's Cross-remit findings section" {
  local section
  section="$(extract_section_or_fail "$FRONTEND" '^## Cross-remit findings' '^## ')" || return 1
  printf '%s\n' "$section" | grep -qi 'difficulty' && return 1
  true
}

# --- Group 5: the consumer surfaces surface the grade, and nothing more ----

@test "UAT-006: debt.md's ordering query projects difficulty" {
  local start end
  read -r start end <<<"$(ordering_query_fence_range "$DEBT")"
  sed -n "${start},${end}p" "$DEBT" | grep -qF -- "difficulty: ([.labels[].name]" || return 1
}

@test "UAT-007: the list subcommand section states the ungraded case gets no annotation" {
  extract_section "$DEBT" '^## list subcommand' '^## ' | grep -qF -- "no difficulty annotation at all" || return 1
}

@test "UAT-007: the why subcommand section states the ungraded case is silent, not defaulted" {
  extract_section "$DEBT" '^## why subcommand' '^## ' | grep -qF -- "says nothing about difficulty" || return 1
}

@test "UAT-007: debt.md never stands a default annotation in for ungraded" {
  assert_absent_fixed_across "[difficulty: unknown]" "$DEBT"
  assert_absent_fixed_across "[ungraded]" "$DEBT"
}

@test "difficulty appears in debt.md only inside the ordering query, the two subcommand sections, and the guarantee sentence" {
  local q_start q_end list_start list_end why_start why_end guarantee_line
  read -r q_start q_end <<<"$(ordering_query_fence_range "$DEBT")"
  read -r list_start list_end <<<"$(section_line_range "$DEBT" '^## list subcommand' '^## ')"
  read -r why_start why_end <<<"$(section_line_range "$DEBT" '^## why subcommand' '^## ')"
  guarantee_line=$(grep -n -F -- "Difficulty grading never gates anything" "$DEBT" | head -1 | cut -d: -f1)
  [ -n "$guarantee_line" ] || {
    echo "the difficulty-never-gates guarantee sentence is missing from debt.md" >&2
    return 1
  }

  local hits line in_region
  hits="$(grep -in 'difficulty' "$DEBT" | cut -d: -f1)"
  for line in $hits; do
    in_region=0
    if [ "$line" -ge "$q_start" ] && [ "$line" -le "$q_end" ]; then in_region=1; fi
    if [ "$line" -ge "$list_start" ] && [ "$line" -le "$list_end" ]; then in_region=1; fi
    if [ "$line" -ge "$why_start" ] && [ "$line" -le "$why_end" ]; then in_region=1; fi
    if [ "$line" = "$guarantee_line" ]; then in_region=1; fi
    if [ "$in_region" -eq 0 ]; then
      echo "difficulty hit at debt.md:${line} falls outside the four permitted regions" >&2
      return 1
    fi
  done
  true
}

# --- Group 6: no pre-existing spelling moved --------------------------------

@test "UAT-010: every pre-existing label spelling survives in SKILL.md" {
  grep -qF -- "tech-debt" "$VOCAB" || return 1
  grep -qF -- "severity:critical" "$VOCAB" || return 1
  grep -qF -- "severity:important" "$VOCAB" || return 1
  grep -qF -- "severity:suggestion" "$VOCAB" || return 1
  grep -qF -- "wontfix" "$VOCAB" || return 1
}
