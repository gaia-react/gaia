#!/usr/bin/env bats
# Structural + guard-line + schema tests for the SPEC-025 adversarial-audit
# no-op guard (plan FC-3/FC-4/FC-5/FC-6/FC-7; see
# .gaia/local/specs/SPEC-025/plan/README.md for the frozen contracts).
#
# The detection predicate itself is deterministic and unit-tested by the
# sibling suite `audit-noop-detect.bats` (Phase 1). The orchestration wiring
# tested here, calling the predicate after each dispatch, retrying once,
# falling back inline, is agent-executed instruction prose, not code, so it
# cannot be exercised end-to-end; these assertions are structural: each
# dispatch site's prose is grepped for the shared predicate, the exactly-one
# retry, and the inline fallback (stronger than guard-line presence alone),
# the guard line's byte-identity across every dispatch prompt, the
# retry-prefix template, the pinned `audit_coverage` schema, and the absence
# of any machine-specific path.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so assertions below use `grep -q` /
# `[ ]` (real exit codes) or an explicit `return 1`, never a bare `[[ ]]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  CRA_MD="$REPO_ROOT/.claude/agents/code-review-audit.md"
  HELPER="$REPO_ROOT/.gaia/scripts/audit-noop-detect.sh"

  # FC-3: the byte-identical guard-line substring, verbatim.
  GUARD_LINE="Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose."
  # FC-4: the stable retry-prefix template substring (UAT-002).
  RETRY_PREFIX="RETRY (hardened, one attempt only):"
}

# section_between FILE START END: prints the lines from the first line
# matching START (inclusive) up to (not including) the next line matching
# END. END empty -> captures to EOF. START/END are ERE patterns matched with
# awk's `~`; a literal `.` in a heading number (e.g. "4.6a") matches itself,
# so no escaping is needed for the heading numbers used below.
section_between() {
  local file="$1" start="$2" end="$3"
  if [ -n "$end" ]; then
    awk -v start="$start" -v end="$end" '
      $0 ~ start { capture=1 }
      capture && $0 ~ end && $0 !~ start { exit }
      capture { print }
    ' "$file" 2>/dev/null
  else
    awk -v start="$start" '
      $0 ~ start { capture=1 }
      capture { print }
    ' "$file" 2>/dev/null
  fi
}

# assert_section_nonempty NAME CONTENT: fails loudly (not a silent skip) when
# a section extraction came back empty, the delimiting heading was not
# found. Per the plan: a missing `##### 7b-i/ii/iii` sub-heading (or any
# other site heading) is a real Phase-2 gap and must surface as a failure,
# never silently degrade to a whole-file grep.
assert_section_nonempty() {
  local name="$1" content="$2"
  if [ -z "$content" ]; then
    echo "section '$name' is empty -- delimiting heading not found (Phase-2 gap)" >&2
    return 1
  fi
}

# assert_predicate_retry_fallback CONTENT: the three literal FC-7 anchors.
assert_predicate_retry_fallback() {
  local content="$1"
  grep -qF -- "audit-noop-detect.sh" <<<"$content"
  grep -qF -- "exactly one" <<<"$content"
  grep -qF -- "inline fallback" <<<"$content"
}

# ---------------------------------------------------------------------------
# 0. The edited surfaces exist
# ---------------------------------------------------------------------------

@test "edited surfaces exist: spec.md, plan.md, code-review-audit.md, helper" {
  [ -f "$SPEC_MD" ]
  [ -f "$PLAN_MD" ]
  [ -f "$CRA_MD" ]
  [ -f "$HELPER" ]
}

# ---------------------------------------------------------------------------
# 1. Guard-line byte-identity across all 7 FC-6 prompts (FC-3; UAT-004)
# ---------------------------------------------------------------------------

@test "guard line: spec.md 6a self-review dispatch prompt" {
  content="$(section_between "$SPEC_MD" '^#### 6a' '^#### 6b')"
  assert_section_nonempty "spec.md #### 6a" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: spec.md 7a lens-auditor shared preamble" {
  content="$(section_between "$SPEC_MD" '^#### 7a' '^#### 7b')"
  assert_section_nonempty "spec.md #### 7a" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: spec.md 7b-i refuter prompt" {
  content="$(section_between "$SPEC_MD" '^##### 7b-i' '^##### 7b-ii')"
  assert_section_nonempty "spec.md ##### 7b-i" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: spec.md 7b-ii completeness-critic dispatch prompt" {
  content="$(section_between "$SPEC_MD" '^##### 7b-ii' '^##### 7b-iii')"
  assert_section_nonempty "spec.md ##### 7b-ii" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: plan.md 4.6a decomposition-lens shared preamble" {
  content="$(section_between "$PLAN_MD" '^#### 4.6a' '^#### 4.6b')"
  assert_section_nonempty "plan.md #### 4.6a" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: code-review-audit.md specialist-subagent instructions template" {
  content="$(section_between "$CRA_MD" '^### Subagent instructions template' '^## Constraints')"
  assert_section_nonempty "code-review-audit.md Subagent instructions template" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: code-review-audit.md adversarial-refuter prompt" {
  content="$(section_between "$CRA_MD" '^## Finding Proof Gate' '^## Scope classification')"
  assert_section_nonempty "code-review-audit.md Finding Proof Gate" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

# ---------------------------------------------------------------------------
# 2. Predicate + one-retry + inline-fallback in each of the 9 FC-7 sites
#    (Directive #8). Sites 3/4/5 are delimited by the `##### 7b-i/ii/iii`
#    sub-headings; an empty section here is a real Phase-2 gap, not a
#    fallback to a whole-7b grep.
# ---------------------------------------------------------------------------

@test "wiring: spec.md 6a self-review site" {
  content="$(section_between "$SPEC_MD" '^#### 6a' '^#### 6b')"
  assert_section_nonempty "spec.md #### 6a" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: spec.md 7a lens site" {
  content="$(section_between "$SPEC_MD" '^#### 7a' '^#### 7b')"
  assert_section_nonempty "spec.md #### 7a" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: spec.md 7b-i refuter site" {
  content="$(section_between "$SPEC_MD" '^##### 7b-i' '^##### 7b-ii')"
  assert_section_nonempty "spec.md ##### 7b-i" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: spec.md 7b-ii Deep completeness-critic site" {
  content="$(section_between "$SPEC_MD" '^##### 7b-ii' '^##### 7b-iii')"
  assert_section_nonempty "spec.md ##### 7b-ii" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: spec.md 7b-iii completeness-critic refuter site" {
  content="$(section_between "$SPEC_MD" '^##### 7b-iii' '^#### 7c')"
  assert_section_nonempty "spec.md ##### 7b-iii" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: spec.md 7c applier site" {
  content="$(section_between "$SPEC_MD" '^#### 7c' '^#### 7d')"
  assert_section_nonempty "spec.md #### 7c" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: plan.md 4.6a decomposition-lens site" {
  content="$(section_between "$PLAN_MD" '^#### 4.6a' '^#### 4.6b')"
  assert_section_nonempty "plan.md #### 4.6a" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: code-review-audit.md specialist dispatch site" {
  content="$(section_between "$CRA_MD" '^### How to run' '^### Knip findings')"
  assert_section_nonempty "code-review-audit.md How to run" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: code-review-audit.md adversarial-refuter dispatch site" {
  content="$(section_between "$CRA_MD" '^## Finding Proof Gate' '^## Scope classification')"
  assert_section_nonempty "code-review-audit.md Finding Proof Gate" "$content"
  assert_predicate_retry_fallback "$content"
}

# ---------------------------------------------------------------------------
# 2b. FC-4 retry-prefix template present in each edited file (UAT-002)
# ---------------------------------------------------------------------------

@test "retry-prefix template embedded verbatim in spec.md" {
  grep -qF -- "$RETRY_PREFIX" "$SPEC_MD"
}

@test "retry-prefix template embedded verbatim in plan.md" {
  grep -qF -- "$RETRY_PREFIX" "$PLAN_MD"
}

@test "retry-prefix template embedded verbatim in code-review-audit.md" {
  grep -qF -- "$RETRY_PREFIX" "$CRA_MD"
}

# ---------------------------------------------------------------------------
# 3. audit_coverage pinned record shape (FC-5; UAT-007, Directive #1)
# ---------------------------------------------------------------------------

@test "audit_coverage: pinned schema in spec.md's pacing-telemetry event list" {
  line="$(grep -F '"event": "audit_coverage"' "$SPEC_MD" | head -n1)"
  [ -n "$line" ]
  grep -qF -- '"phase"' <<<"$line"
  grep -qF -- '"disposition"' <<<"$line"
  grep -qF -- "first_pass" <<<"$line"
  grep -qF -- "retried_recovered" <<<"$line"
  grep -qF -- "inline_fallback" <<<"$line"
  grep -qF -- '"auto"' <<<"$line"
}

@test "audit_coverage: named in Auto-mode rule 12's auto-flagged event list" {
  content="$(section_between "$SPEC_MD" '^## Auto mode' '^## Profile-driven coaching preamble')"
  assert_section_nonempty "spec.md Auto mode" "$content"
  rule12="$(grep -E '^12\.' <<<"$content")"
  [ -n "$rule12" ]
  grep -qF -- "audit_coverage" <<<"$rule12"
}

# ---------------------------------------------------------------------------
# 4. No machine-specific paths in the changed files (UAT-004)
# ---------------------------------------------------------------------------

@test "portability: no /Users/ or /home/ literal paths in the edited surfaces" {
  run grep -REn "/Users/|/home/" "$SPEC_MD" "$PLAN_MD" "$CRA_MD" "$HELPER"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 5. The helper is referenced, not reinvented
# ---------------------------------------------------------------------------

@test "helper reference: spec.md calls the real audit-noop-detect.sh path" {
  grep -qF -- ".gaia/scripts/audit-noop-detect.sh" "$SPEC_MD"
}

@test "helper reference: plan.md calls the real audit-noop-detect.sh path" {
  grep -qF -- ".gaia/scripts/audit-noop-detect.sh" "$PLAN_MD"
}

@test "helper reference: code-review-audit.md calls the real audit-noop-detect.sh path" {
  grep -qF -- ".gaia/scripts/audit-noop-detect.sh" "$CRA_MD"
}
