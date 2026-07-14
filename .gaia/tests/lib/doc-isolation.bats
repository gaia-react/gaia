#!/usr/bin/env bats
#
# Doc-conformance suite for the shared isolation reference
# (.claude/skills/gaia/references/isolation.md) and its two callers' pointer
# wiring (plan.md, debt.md).
#
# The headline gate is byte-identity: a bash renderer extracts the prompt
# literals, the option order, and the lead option FROM THE FRAGMENT, substitutes
# each caller's four slot values, and diffs the result against a golden fixture.
# The renderer never supplies the ordering itself -- if it did, the diff would
# come out clean even when the fragment instructs leading with the wrong option,
# and the gate would be measuring the renderer instead of the artifact.
#
# FIXTURE PROVENANCE (do not "simplify" this back to a working-tree read).
# fixtures/isolation/prompt-plan.txt and prompt-debt.txt were captured from GIT,
# not from the working tree:
#
#   BASE="$(git merge-base HEAD origin/main)"
#   git show "$BASE:.claude/skills/gaia/references/plan.md"
#   git show "$BASE:.claude/skills/gaia/references/debt.md"
#
# The refactor that created the fragment rewrites both of those sources, so a
# working-tree capture would diff the renderer against its own output and pass
# vacuously no matter how wrong the fragment was. A git-derived capture stays
# re-derivable at any point in the run, which keeps the byte-identity gate honest
# across a restart.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a `!`-negated
# command never fails a non-final line on any bash. Absence checks are written as
# `<positive-condition-for-the-bad-case> && return 1`, which means a test whose
# LAST statement is such a check must end with an explicit `true`.
#
# Self-exclusion (precedent: the `*-absence.bats` suite under .gaia/scripts/tests/,
# which documents this same trap; it is deliberately named by glob here, because
# its own filename embeds the retired symbol that its sibling gate greps for
# repo-wide, so spelling it out would break that gate):
# the negative-space test below asserts a literal is absent repo-wide, so this
# file necessarily contains that literal, and once committed it is tracked. An
# unexcluded `git grep` would match this suite's own text and the gate could never
# pass. The pathspec excludes this suite and its two siblings; a pathspec naming a
# not-yet-existent path is a harmless no-op, and pre-declaring them keeps a later
# phase from having to widen the grep.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FRAG="$REPO_ROOT/.claude/skills/gaia/references/isolation.md"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  DEBT_MD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/isolation"
}

# Pull the backticked value off a `... : `<value>`` literal line in the fragment.
# The greedy `.*: ` anchors on the LAST ": `" in the line, so an option line's own
# `- option `branch`, label: ` prefix does not bleed into the value.
frag_line() {
  grep -m1 -E -- "$1" "$FRAG" | sed -E 's/.*: `(.*)`$/\1/'
}

# 1-based line number of a heading in the fragment.
frag_heading_line() {
  grep -n -F -- "$1" "$FRAG" | head -1 | cut -d: -f1
}

# Render the prompt exactly as the fragment specifies it, for one caller's slots.
# Order and lead option come out of the fragment; only the marker text and the
# serialization are the renderer's.
render() {
  subject="$1"
  worker="$2"
  owner="$3"
  sibling="$4"

  question="$(frag_line '^- question: ')"
  header="$(frag_line '^- header: ')"
  order="$(grep -m1 -E '^- order: ' "$FRAG" | sed -E 's/^- order: //; s/`//g; s/,/ /g')"
  lead="$(grep -m1 -E '^- lead: ' "$FRAG" | sed -E 's/^- lead: //; s/`//g; s/ //g')"

  {
    printf 'question: %s\n' "$question"
    printf 'header: %s\n' "$header"
    n=0
    for key in $order; do
      n=$((n + 1))
      label="$(frag_line "^- option \`$key\`, label: ")"
      desc="$(frag_line "^- option \`$key\`, description: ")"
      if [ "$key" = "$lead" ]; then
        label="$label (Recommended)"
      fi
      printf 'option%s: %s | %s\n' "$n" "$label" "$desc"
    done
  } | sed -e "s/{{SUBJECT}}/$subject/g" \
          -e "s/{{WORKER}}/$worker/g" \
          -e "s/{{OWNER}}/$owner/g" \
          -e "s/{{SIBLING}}/$sibling/g"
}

@test "byte-identity: the fragment renders /gaia-plan's prompt exactly as it reads today" {
  render "this plan's work" "the orchestrator" "this plan" "another plan" \
    > "$BATS_TEST_TMPDIR/prompt-plan.txt"
  diff -u "$FIXTURES/prompt-plan.txt" "$BATS_TEST_TMPDIR/prompt-plan.txt"
}

@test "byte-identity: the fragment renders /gaia-debt's prompt exactly as it reads today" {
  render "this debt fix" "the fix" "this fix" "another task" \
    > "$BATS_TEST_TMPDIR/prompt-debt.txt"
  diff -u "$FIXTURES/prompt-debt.txt" "$BATS_TEST_TMPDIR/prompt-debt.txt"
}

@test "the recommendation marker is appended at exactly one site, never baked into a label" {
  branch_label="$(frag_line '^- option `branch`, label: ')"
  worktree_label="$(frag_line '^- option `worktree`, label: ')"
  [ -n "$branch_label" ]
  [ -n "$worktree_label" ]

  printf '%s' "$branch_label" | grep -qF '(Recommended)' && return 1
  printf '%s' "$worktree_label" | grep -qF '(Recommended)' && return 1

  # One occurrence in the whole fragment: the append rule. Phase 3 makes which
  # option leads policy-dependent, and must not need a second site to do it.
  count="$(grep -oF '(Recommended)' "$FRAG" | wc -l | tr -d ' ')"
  [ "$count" = 1 ]
}

@test "structural: the forced-worktree arm precedes the policy read, never prompts, and reaches worktree creation" {
  nomain="$(frag_heading_line '### HEAD is not on')"
  policy="$(frag_heading_line '### Policy read')"
  question="$(frag_heading_line '### The isolation question')"
  creation="$(frag_heading_line '## Worktree creation')"
  [ -n "$nomain" ]
  [ -n "$policy" ]
  [ -n "$question" ]
  [ -n "$creation" ]

  # The not-on-main arm is a correctness rule, so it is evaluated BEFORE the
  # policy read and no policy value can reach it.
  [ "$nomain" -lt "$policy" ]
  [ "$policy" -lt "$question" ]

  # Zero prompts in that arm: the token itself is absent from its block.
  asks="$(sed -n "${nomain},$((policy - 1))p" "$FRAG" | grep -cF 'AskUserQuestion' || true)"
  [ "$asks" -eq 0 ]

  # Worktree creation, and the single EnterWorktree( call, are downstream of it.
  enter="$(grep -n -F 'EnterWorktree(' "$FRAG" | head -1 | cut -d: -f1)"
  [ -n "$enter" ]
  [ "$creation" -gt "$nomain" ]
  [ "$enter" -gt "$nomain" ]
}

@test "the fragment holds exactly one EnterWorktree( call" {
  # Occurrence count, not `git grep -c`, which counts matching LINES and would
  # read two calls on one line as 1.
  count="$(grep -oF 'EnterWorktree(' "$FRAG" | wc -l | tr -d ' ')"
  [ "$count" = 1 ]
}

@test "pointer discipline: each caller names the reference exactly once and copies none of its literals" {
  plan_pointers="$(grep -oF 'skills/gaia/references/isolation.md' "$PLAN_MD" | wc -l | tr -d ' ')"
  debt_pointers="$(grep -oF 'skills/gaia/references/isolation.md' "$DEBT_MD" | wc -l | tr -d ' ')"
  [ "$plan_pointers" = 1 ]
  [ "$debt_pointers" = 1 ]

  # Neither caller carries an option label or the header literal. The grep is
  # case-insensitive, which is also what catches the "feature-branch mode" bigram.
  grep -qiF 'Create a feature branch in place' "$PLAN_MD" && return 1
  grep -qiF 'Create a git worktree' "$PLAN_MD" && return 1
  grep -qiF 'Branch mode' "$PLAN_MD" && return 1
  grep -qiF 'Create a feature branch in place' "$DEBT_MD" && return 1
  grep -qiF 'Create a git worktree' "$DEBT_MD" && return 1
  grep -qiF 'Branch mode' "$DEBT_MD" && return 1
  true
}

@test "negative space: no surface still claims the prompt fires on every main HEAD" {
  run git -C "$REPO_ROOT" grep -n 'fires every time HEAD is' \
    -- ':!.gaia/tests/lib/doc-isolation.bats' \
       ':!.gaia/tests/lib/doc-setup-gaia-isolation.bats' \
       ':!.gaia/tests/lib/doc-gaia-init-isolation.bats'
  # git grep exits 1 when it matches nothing, so emptiness of $output is the
  # assertion that matters, not the exit code.
  [ -z "$output" ]
}

@test "the generated ORCHESTRATOR.md template emits a pointer, never a snapshot" {
  start="$(grep -n -F '3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**' "$PLAN_MD" | head -1 | cut -d: -f1)"
  end="$(grep -n -F '4.  **`{PLAN_DIR}/KICKOFF.md`**' "$PLAN_MD" | head -1 | cut -d: -f1)"
  [ -n "$start" ]
  [ -n "$end" ]
  [ "$start" -lt "$end" ]

  block="$(sed -n "${start},$((end - 1))p" "$PLAN_MD")"

  pointers="$(printf '%s\n' "$block" | grep -oF 'skills/gaia/references/isolation.md' | wc -l | tr -d ' ')"
  [ "$pointers" = 1 ]

  printf '%s\n' "$block" | grep -qF 'never an inlined snapshot'

  # A snapshot would have dragged the literals into the template with it.
  printf '%s\n' "$block" | grep -qiF 'Create a feature branch in place' && return 1
  printf '%s\n' "$block" | grep -qiF 'Create a git worktree' && return 1
  printf '%s\n' "$block" | grep -qiF 'Branch mode' && return 1
  true
}

@test "the KICKOFF self-containment contract carries exactly one carve-out" {
  start="$(grep -n -F '4.  **`{PLAN_DIR}/KICKOFF.md`**' "$PLAN_MD" | head -1 | cut -d: -f1)"
  end="$(grep -n -F 'Before returning, delete `{PLAN_DIR}/.work/`' "$PLAN_MD" | head -1 | cut -d: -f1)"
  [ -n "$start" ]
  [ -n "$end" ]
  [ "$start" -lt "$end" ]

  count="$(sed -n "${start},$((end - 1))p" "$PLAN_MD" \
    | grep -oF 'with exactly one carve-out' | wc -l | tr -d ' ')"
  [ "$count" = 1 ]
}

@test "the RUNNING sentinel records the resolved mode, not the answer the user gave" {
  grep -qF 'mode: <the RESOLVED_MODE the isolation reference exported' "$PLAN_MD"

  run git -C "$REPO_ROOT" grep -in 'the isolation mode chosen\|the answer the user gave' \
    -- .claude/skills/gaia/references/plan.md
  [ -z "$output" ]
}

@test "the fragment exports RESOLVED_MODE with exactly two values" {
  grep -qF 'RESOLVED_MODE' "$FRAG"
  grep -qF '`feature-branch`' "$FRAG"
  grep -qF '`worktree`' "$FRAG"

  # debt.md has no sentinel, so it must not consume the export.
  grep -qF 'RESOLVED_MODE' "$DEBT_MD" && return 1
  true
}
