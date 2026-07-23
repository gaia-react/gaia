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
#
# Policy-branch cases (added once the fragment's guarded policy read exists):
# UAT-007 check (iii)'s full `\(recommended\) or a git worktree|fires every time
# HEAD is` grep is the SPEC's binding acceptance gate. Phase 5 rewords the last
# prose sites that carried the first alternative, so the combined pattern is
# asserted below rather than just the `fires every time HEAD is` half.

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
        # The `Default. ` prefix is applied at one site, and only to the branch
        # option when it leads. Baked into the literal it would survive into
        # prefer-worktree, where it would contradict the marker by calling the
        # non-recommended option the default.
        if [ "$key" = branch ]; then
          desc="Default. $desc"
        fi
      fi
      printf 'option%s: %s | %s\n' "$n" "$label" "$desc"
    done
  } | sed -e "s/{{SUBJECT}}/$subject/g" \
          -e "s/{{WORKER}}/$worker/g" \
          -e "s/{{OWNER}}/$owner/g" \
          -e "s/{{SIBLING}}/$sibling/g"
}

# Same as render(), except order/lead come from ONE policy's own heading-bounded
# block (`##### \`prefer-branch\`` or `##### \`prefer-worktree\``) instead of
# grep -m1's first-match-in-file. This is what keeps the per-policy assertions
# honest: a fragment that instructed leading with the wrong option under a given
# policy would fail here even though the plain byte-identity tests above (which
# only ever exercise the first order/lead pair, i.e. prefer-branch's) would not
# catch it.
render_for_policy() {
  policy="$1"
  subject="$2"
  worker="$3"
  owner="$4"
  sibling="$5"

  pb_start="$(frag_heading_line '##### `prefer-branch`')"
  pw_start="$(frag_heading_line '##### `prefer-worktree`')"
  creation="$(frag_heading_line '## Worktree creation')"

  case "$policy" in
    prefer-worktree) start="$pw_start"; end="$((creation - 1))" ;;
    *)               start="$pb_start"; end="$((pw_start - 1))" ;;
  esac

  question="$(frag_line '^- question: ')"
  header="$(frag_line '^- header: ')"
  order="$(sed -n "${start},${end}p" "$FRAG" | grep -m1 -E '^- order: ' | sed -E 's/^- order: //; s/`//g; s/,/ /g')"
  lead="$(sed -n "${start},${end}p" "$FRAG" | grep -m1 -E '^- lead: ' | sed -E 's/^- lead: //; s/`//g; s/ //g')"

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
        # The `Default. ` prefix is applied at one site, and only to the branch
        # option when it leads. Baked into the literal it would survive into
        # prefer-worktree, where it would contradict the marker by calling the
        # non-recommended option the default.
        if [ "$key" = branch ]; then
          desc="Default. $desc"
        fi
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

@test "UAT-007 check (iii): no surface hardcodes a recommendation or claims the prompt fires unconditionally" {
  run git -C "$REPO_ROOT" grep -inE '\(recommended\) or a git worktree|fires every time HEAD is' \
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

@test "the policy read literal defaults to prefer-branch: no file, an unreadable file, and an empty object" {
  policy_line="$(grep -m1 -F 'POLICY="$(jq -r' "$FRAG")"
  [ -n "$policy_line" ]

  # Write the fragment's real literal to a script, rather than re-typing it,
  # so this test executes the artifact instead of a paraphrase of it.
  script="$BATS_TEST_TMPDIR/policy-read.sh"
  printf '%s\nprintf %%s "$POLICY"\n' "$policy_line" > "$script"

  mkdir -p "$BATS_TEST_TMPDIR/case-absent"
  run bash -c "cd '$BATS_TEST_TMPDIR/case-absent' && bash '$script'"
  [ "$status" -eq 0 ]
  [ "$output" = "prefer-branch" ]

  # Root reads through the mode bits, so chmod 000 proves nothing there.
  if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$BATS_TEST_TMPDIR/case-unreadable/.gaia"
    printf '{"isolation_policy":"prefer-worktree"}' \
      > "$BATS_TEST_TMPDIR/case-unreadable/.gaia/automation.json"
    chmod 000 "$BATS_TEST_TMPDIR/case-unreadable/.gaia/automation.json"
    run bash -c "cd '$BATS_TEST_TMPDIR/case-unreadable' && bash '$script'"
    chmod 644 "$BATS_TEST_TMPDIR/case-unreadable/.gaia/automation.json"
    [ "$status" -eq 0 ]
    [ "$output" = "prefer-branch" ]
  fi

  mkdir -p "$BATS_TEST_TMPDIR/case-empty/.gaia"
  printf '{}' > "$BATS_TEST_TMPDIR/case-empty/.gaia/automation.json"
  run bash -c "cd '$BATS_TEST_TMPDIR/case-empty' && bash '$script'"
  [ "$status" -eq 0 ]
  [ "$output" = "prefer-branch" ]
}

@test "UAT-013: an unrecognized isolation_policy degrades to prefer-branch and names the value in one line" {
  policy_start="$(frag_heading_line '### Policy read')"
  aw_start="$(frag_heading_line "### \`always-worktree\`")"
  [ -n "$policy_start" ]
  [ -n "$aw_start" ]

  policy_block="$(sed -n "${policy_start},$((aw_start - 1))p" "$FRAG")"

  case_open_rel="$(printf '%s\n' "$policy_block" | grep -n -F 'case "$POLICY" in' | head -1 | cut -d: -f1)"
  case_close_rel="$(printf '%s\n' "$policy_block" | grep -n -F 'esac' | head -1 | cut -d: -f1)"
  [ -n "$case_open_rel" ]
  [ -n "$case_close_rel" ]

  case_text="$(printf '%s\n' "$policy_block" | sed -n "${case_open_rel},${case_close_rel}p")"

  # The `*)` default arm's own body: from its `*)` line to the case's `esac`.
  star_rel="$(printf '%s\n' "$case_text" | grep -n -F '*)' | head -1 | cut -d: -f1)"
  [ -n "$star_rel" ]
  arm_body="$(printf '%s\n' "$case_text" | sed -n "${star_rel},\$p")"

  # (a) carries an emit instruction, (b) interpolates the unrecognized value,
  # rather than a generic message with no value in it.
  printf '%s\n' "$arm_body" | grep -qE 'printf|echo' || return 1
  printf '%s\n' "$arm_body" | grep -qF '"$POLICY"' || return 1
  printf '%s\n' "$arm_body" | grep -qF 'POLICY=prefer-branch' || return 1

  # End-to-end: run the real policy read + case against an unrecognized value.
  policy_line="$(grep -m1 -F 'POLICY="$(jq -r' "$FRAG")"
  script="$BATS_TEST_TMPDIR/policy-unrecognized.sh"
  {
    printf '%s\n' "$policy_line"
    printf '%s\n' "$case_text"
    printf 'printf %%s "$POLICY"\n'
  } > "$script"

  mkdir -p "$BATS_TEST_TMPDIR/case-bogus/.gaia"
  printf '{"isolation_policy":"always-wortree"}' > "$BATS_TEST_TMPDIR/case-bogus/.gaia/automation.json"

  # `run` captures stdout+stderr combined; the diagnostic (stderr, by design --
  # see the block-body assertions above) must not contaminate the $POLICY value
  # this checks, so capture stdout alone here and check stderr's content next.
  stdout_only="$(bash -c "cd '$BATS_TEST_TMPDIR/case-bogus' && bash '$script' 2>'$BATS_TEST_TMPDIR/stderr.txt'")"
  [ "$stdout_only" = "prefer-branch" ]
  grep -qF 'always-wortree' "$BATS_TEST_TMPDIR/stderr.txt" || return 1
}

@test "UAT-003/UAT-006: the always-worktree branch never prompts and names its worktree-creation-failure fallback" {
  aw_start="$(frag_heading_line "### \`always-worktree\`")"
  question="$(frag_heading_line '### The isolation question')"
  [ -n "$aw_start" ]
  [ -n "$question" ]
  [ "$aw_start" -lt "$question" ]

  block="$(sed -n "${aw_start},$((question - 1))p" "$FRAG")"

  asks="$(printf '%s\n' "$block" | grep -cF 'AskUserQuestion' || true)"
  [ "$asks" -eq 0 ]

  printf '%s\n' "$block" | grep -qF 'RESOLVED_MODE=worktree' || return 1
  printf '%s\n' "$block" | grep -qiF 'fails' || return 1
  printf '%s\n' "$block" | grep -qiF 'question below' || return 1
}

@test "UAT-023: the always-worktree arm and its creation-failure fallback both set RESOLVED_MODE" {
  aw_start="$(frag_heading_line "### \`always-worktree\`")"
  question="$(frag_heading_line '### The isolation question')"
  [ -n "$aw_start" ]
  [ -n "$question" ]

  block="$(sed -n "${aw_start},$((question - 1))p" "$FRAG")"

  # One for the direct success path, one for the fallback path: neither is left
  # to write RESOLVED_MODE implicitly.
  occurrences="$(printf '%s\n' "$block" | grep -cF 'RESOLVED_MODE')"
  [ "$occurrences" -ge 2 ]
}

@test "UAT-004/UAT-005: each policy names its lead option first, and only one (Recommended) site exists" {
  branch_rendered="$(render_for_policy "prefer-branch" "this plan's work" "the orchestrator" "this plan" "another plan")"
  printf '%s\n' "$branch_rendered" | grep -qF 'option1: Create a feature branch in place (Recommended)' || return 1
  printf '%s\n' "$branch_rendered" | grep -qF 'option2: Create a git worktree |' || return 1

  worktree_rendered="$(render_for_policy "prefer-worktree" "this plan's work" "the orchestrator" "this plan" "another plan")"
  printf '%s\n' "$worktree_rendered" | grep -qF 'option1: Create a git worktree (Recommended)' || return 1
  printf '%s\n' "$worktree_rendered" | grep -qF 'option2: Create a feature branch in place |' || return 1

  # Still exactly one append site fragment-wide, regardless of how many
  # policy-branch order/lead pairs now exist.
  count="$(grep -oF '(Recommended)' "$FRAG" | wc -l | tr -d ' ')"
  [ "$count" = 1 ]
}

@test "no option's DESCRIPTION carries a recommendation signal the marker does not own" {
  # The marker assertions above only inspect labels. A recommendation word baked
  # into a description would sail past them: under prefer-worktree the branch
  # option is presented second, unmarked, and a description opening with
  # `Default.` would tell the user the non-recommended option is the default, on
  # every run. Inspect past the `|` separator, where the descriptions live.
  worktree_rendered="$(render_for_policy "prefer-worktree" "this plan's work" "the orchestrator" "this plan" "another plan")"

  descriptions="$(printf '%s\n' "$worktree_rendered" | grep '^option' | sed -E 's/^[^|]*\| //')"
  printf '%s\n' "$descriptions" | grep -qiE 'default\.|recommended' && return 1

  # ...while prefer-branch, where the branch option genuinely IS the default and
  # leads, still says so. The prefix is policy-driven, not deleted.
  branch_rendered="$(render_for_policy "prefer-branch" "this plan's work" "the orchestrator" "this plan" "another plan")"
  printf '%s\n' "$branch_rendered" \
    | grep -qF 'option1: Create a feature branch in place (Recommended) | Default. Branch is cut from HEAD' || return 1

  # The prefix is never baked into the description literal, so it cannot leak
  # into a policy that does not lead with the branch option.
  ! grep -qE '^- option `branch`, description: `Default\. ' "$FRAG"
}

@test "the Default. prefix rule is stated in the fragment, not only in this renderer" {
  # render() and render_for_policy() SYNTHESIZE the prefix, hardcoding
  # `desc="Default. $desc"` just as they hardcode ` (Recommended)`. That is only
  # safe while the fragment is independently pinned to still CARRY the rule.
  # Without this test, deleting the rule paragraph leaves every other test here
  # green -- the renderer keeps emitting the prefix, so the fixtures still match
  # byte-for-byte -- while the shipped fragment no longer tells the agent to
  # apply it. The gate would be measuring the renderer instead of the artifact,
  # the exact trap this suite's header opens by warning about. The marker rule
  # is pinned by its own count assertion above; this is the prefix rule's.
  grep -qF 'Prefix the `branch` option' "$FRAG" || return 1
  grep -qF 'when, and only when, `branch` is the **lead**' "$FRAG" || return 1

  # Exactly one `Default. ` fragment-wide: the rule's own backticked literal.
  # Zero means the rule was dropped; two would mean it was ALSO baked back into
  # the description literal, which the test above forbids on its last line.
  count="$(grep -oF 'Default. ' "$FRAG" | wc -l | tr -d ' ')"
  [ "$count" = 1 ]
}

@test "UAT-016: already-inside-a-linked-worktree detection calls the shared resolver and runs first" {
  already="$(frag_heading_line '### Already inside a linked worktree')"
  nomain="$(frag_heading_line '### HEAD is not on')"
  policy="$(frag_heading_line '### Policy read')"
  [ -n "$already" ]
  [ -n "$nomain" ]
  [ -n "$policy" ]

  [ "$already" -lt "$nomain" ]
  [ "$already" -lt "$policy" ]

  grep -qF -- 'main-root-lib.sh --is-worktree' "$FRAG" || return 1
}
