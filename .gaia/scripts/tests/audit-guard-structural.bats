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
  CRA_MD="$REPO_ROOT/.claude/agents/code-audit-frontend.md"
  HELPER="$REPO_ROOT/.gaia/scripts/audit-noop-detect.sh"

  # SPEC-042 clearance-writer surfaces (UAT-020 structural half + PLAN-001).
  SHELL_MD="$REPO_ROOT/.claude/agents/code-audit-maintainer-shell.md"
  NODE_MD="$REPO_ROOT/.claude/agents/code-audit-maintainer-node.md"
  WRITER="$REPO_ROOT/.gaia/scripts/audit-write-clearance.sh"
  AUDIT_WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  WF_TMPL_ARTIFACT="$REPO_ROOT/.gaia/cli/templates/workflows/code-review-audit.yml.tmpl"
  WF_TMPL_SOURCE="$REPO_ROOT/.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl"

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

@test "edited surfaces exist: spec.md, plan.md, code-audit-frontend.md, helper" {
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

@test "guard line: code-audit-frontend.md specialist-subagent instructions template" {
  content="$(section_between "$CRA_MD" '^### Subagent instructions template' '^## Constraints')"
  assert_section_nonempty "code-audit-frontend.md Subagent instructions template" "$content"
  grep -qF -- "$GUARD_LINE" <<<"$content"
}

@test "guard line: code-audit-frontend.md adversarial-refuter prompt" {
  content="$(section_between "$CRA_MD" '^## Finding Proof Gate' '^## Scope classification')"
  assert_section_nonempty "code-audit-frontend.md Finding Proof Gate" "$content"
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

@test "wiring: code-audit-frontend.md specialist dispatch site" {
  content="$(section_between "$CRA_MD" '^### How to run' '^### Knip findings')"
  assert_section_nonempty "code-audit-frontend.md How to run" "$content"
  assert_predicate_retry_fallback "$content"
}

@test "wiring: code-audit-frontend.md adversarial-refuter dispatch site" {
  content="$(section_between "$CRA_MD" '^## Finding Proof Gate' '^## Scope classification')"
  assert_section_nonempty "code-audit-frontend.md Finding Proof Gate" "$content"
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

@test "retry-prefix template embedded verbatim in code-audit-frontend.md" {
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
  content="$(section_between "$SPEC_MD" '^## Auto mode' '^## Hard constraints')"
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

@test "helper reference: code-audit-frontend.md calls the real audit-noop-detect.sh path" {
  grep -qF -- ".gaia/scripts/audit-noop-detect.sh" "$CRA_MD"
}

# ---------------------------------------------------------------------------
# 6. Shared clearance writer: each Code Audit Team member's definition invokes
#    the ONE shared writer, and NONE still carries the inline marker `printf`
#    or the `[ ! -f "$marker" ]` idempotence guard. This negative assertion is
#    load-bearing: a missed producer keeps writing a legacy-bodied marker that
#    every existence-only consumer honors, so the gate passes and the only
#    symptom is a member that silently never carries forward.
# ---------------------------------------------------------------------------

@test "writer surfaces exist: the three agent definitions and the writer script" {
  [ -f "$CRA_MD" ]
  [ -f "$SHELL_MD" ]
  [ -f "$NODE_MD" ]
  [ -f "$WRITER" ]
}

@test "clearance writer: each code-audit-*.md invokes the shared writer, none keeps the inline printf or the [ ! -f marker ] guard" {
  local md
  for md in "$CRA_MD" "$SHELL_MD" "$NODE_MD"; do
    # Positive: invokes the one shared writer.
    grep -qF -- ".gaia/scripts/audit-write-clearance.sh" "$md" || return 1
    # Negative: no inline marker printf (the bad case is a present match).
    grep -qF -- 'printf '\''{"sha"' "$md" && return 1
    # Negative: no idempotence guard (the bad case is a present match).
    grep -qF -- '[ ! -f "$marker" ]' "$md" && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# 7. PLAN-001: CI's agent tool policy must grant the writer, or the required
#    GAIA-Audit check never stamps. The `--allowedTools` line names the writer
#    in the live workflow AND both byte-identical bundled templates, and all
#    three agree.
# ---------------------------------------------------------------------------

@test "PLAN-001: --allowedTools names the writer in the workflow and both templates, all three identical" {
  local line_wf line_src line_art
  line_wf="$(grep -F -- '--allowedTools' "$AUDIT_WORKFLOW" | head -n1)"
  line_src="$(grep -F -- '--allowedTools' "$WF_TMPL_SOURCE" | head -n1)"
  line_art="$(grep -F -- '--allowedTools' "$WF_TMPL_ARTIFACT" | head -n1)"
  [ -n "$line_wf" ]
  grep -qF -- "audit-write-clearance.sh" <<<"$line_wf" || return 1
  grep -qF -- "audit-write-clearance.sh" <<<"$line_src" || return 1
  grep -qF -- "audit-write-clearance.sh" <<<"$line_art" || return 1
  [ "$line_wf" = "$line_src" ]
  [ "$line_src" = "$line_art" ]
}

@test "PLAN-001: the two bundled workflow templates are byte-identical" {
  local a b
  a="$(git -C "$REPO_ROOT" hash-object "$WF_TMPL_SOURCE")"
  b="$(git -C "$REPO_ROOT" hash-object "$WF_TMPL_ARTIFACT")"
  [ "$a" = "$b" ]
}

# ---------------------------------------------------------------------------
# UAT-013: the frontend member's self-skip block invokes the UNFILTERED spawn
# oracle (resolve-audit-spawn.sh --no-carry-forward). A filtered self-skip would
# stand the member down on "I was pre-cleared", disabling the one lever that can
# catch a bad carry. The block must contain ZERO bare resolve-audit-spawn.sh
# calls (every occurrence carries --no-carry-forward).
# ---------------------------------------------------------------------------

@test "UAT-013: the frontend self-skip invokes resolve-audit-spawn.sh --no-carry-forward" {
  block="$(section_between "$CRA_MD" '^## Remit and self-skip' '^## Extension Loading')"
  assert_section_nonempty "code-audit-frontend.md Remit and self-skip" "$block"
  grep -qF -- "resolve-audit-spawn.sh --no-carry-forward" <<<"$block" || return 1
}

@test "UAT-013: the self-skip block contains no bare resolve-audit-spawn.sh call (all carry --no-carry-forward)" {
  block="$(section_between "$CRA_MD" '^## Remit and self-skip' '^## Extension Loading')"
  assert_section_nonempty "code-audit-frontend.md Remit and self-skip" "$block"
  # Every line that invokes the spawn oracle must carry the flag. A bare
  # invocation (resolve-audit-spawn.sh NOT immediately followed by
  # --no-carry-forward) is the bad case.
  bare="$(grep -F -- "resolve-audit-spawn.sh" <<<"$block" | grep -vF -- "resolve-audit-spawn.sh --no-carry-forward" || true)"
  [ -z "$bare" ]
}
