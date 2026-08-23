#!/usr/bin/env bats
# Structural guard for the per-phase post-push CI read (#1530).
#
# The phase loop a generated ORCHESTRATOR.md runs is agent-executed
# instruction prose, not code, so the read itself cannot be exercised
# end-to-end; these assertions are structural. Two surfaces describe the same
# loop -- `.claude/skills/gaia/references/plan.md` (the template every
# generated plan inherits) and `wiki/concepts/Task Orchestration.md` (the
# documented loop) -- and the defect this guards against is one of them
# losing the remote read while the other keeps it, which is silent in both
# directions: a plan generated from a template with no CI read produces
# phases that each look green while a push holds a red guard, and nothing
# between the push and the next dispatch says so.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  ORCH_MD="$REPO_ROOT/wiki/concepts/Task Orchestration.md"
}

# section_between FILE START END: prints the lines from the first line
# matching START (inclusive) up to (not including) the next line matching
# END. START/END are ERE patterns matched with awk's `~`, written without
# backslash escapes: awk expands those in a -v assignment before the regex
# ever sees them, so `\*` would arrive as a bare `*` quantifier; a literal
# asterisk is written as the bracket expression `[*]` instead. Anchoring on
# the bullet's own bold label rather than on its text is what keeps a start
# pattern from binding to a later bullet that merely mentions the label:
# extraction that slides to the wrong bullet is silent, and it hands the
# assertions content that can pass for the wrong reason.
section_between() {
  local file="$1" start="$2" end="$3"
  awk -v start="$start" -v end="$end" '
    $0 ~ start { capture=1 }
    capture && $0 ~ end && $0 !~ start { exit }
    capture { print }
  ' "$file" 2>/dev/null
}

# assert_section_nonempty NAME CONTENT: fails loudly rather than degrading to
# a whole-file grep when the delimiting heading moved or was renamed.
assert_section_nonempty() {
  local name="$1" content="$2"
  if [ -z "$content" ]; then
    echo "section '$name' is empty -- delimiting line not found" >&2
    return 1
  fi
}

@test "both surfaces describing the phase loop exist" {
  [ -f "$PLAN_MD" ]
  [ -f "$ORCH_MD" ]
}

@test "plan.md phase-order bullet carries the post-push CI read" {
  content="$( section_between "$PLAN_MD" '^    - [*][*]Phase order[*][*]' '^    - [*][*]Pre-merge Code Audit Team audit' )"
  assert_section_nonempty "plan.md Phase order bullet" "$content"
  grep -qF -- 'gh pr checks' <<<"$content"
  # The whole output, not just the audit row: the complement is where a red
  # the phase's own path-selected checks cannot see shows up.
  grep -qF -- 'not only the `GAIA-Audit` row' <<<"$content"
}

@test "plan.md phase-order bullet carries all four read caveats" {
  content="$( section_between "$PLAN_MD" '^    - [*][*]Phase order[*][*]' '^    - [*][*]Pre-merge Code Audit Team audit' )"
  assert_section_nonempty "plan.md Phase order bullet" "$content"
  # 1. reports on the pushed head, 2. pending is not green,
  # 3. red is not always a code change, 4. no PR open yet has nothing to read.
  grep -qF -- 'pushed head' <<<"$content"
  grep -qF -- 'Pending is not green' <<<"$content"
  grep -qF -- 'Red is not always a code change' <<<"$content"
  grep -qF -- 'not open yet has nothing to read' <<<"$content"
}

@test "plan.md settles a red as a fold, and stop conditions defer to it" {
  content="$( section_between "$PLAN_MD" '^    - [*][*]Phase order[*][*]' '^    - [*][*]Pre-merge Code Audit Team audit' )"
  assert_section_nonempty "plan.md Phase order bullet" "$content"
  grep -qF -- 'not a stop condition' <<<"$content"

  stop="$( section_between "$PLAN_MD" '^    - [*][*]Stop conditions' '^    - [*][*]Final summary' )"
  assert_section_nonempty "plan.md Stop conditions bullet" "$stop"
  grep -qF -- 'gh pr checks' <<<"$stop"
}

@test "Task Orchestration phase loop carries the same read and the same fold" {
  content="$( section_between "$ORCH_MD" '^3[.] [*][*]Phase loop' '^4[.] [*][*]Stop conditions' )"
  assert_section_nonempty "Task Orchestration phase loop" "$content"
  grep -qF -- 'gh pr checks' <<<"$content"
  grep -qF -- 'not a stop condition' <<<"$content"
}
