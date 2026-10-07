#!/usr/bin/env bats
# Pins for the three shipped surfaces that tell the maintainer how to verify
# their own work: the merge workflow wiki page, the pr-merge rule and the
# audit-loop-unit agent. Each must name the one verification command (branch
# mode before the first dispatch, round mode per audit round) inside its
# maintainer-only blocks, never as separate shell-lint, selector and bats5
# steps, and never outside a block (the release leak check refuses a mention of
# a release-excluded path in shipped text).
#
# GAIA_VERIFY_SURFACE_WIKI, GAIA_VERIFY_SURFACE_RULE and
# GAIA_VERIFY_SURFACE_AGENT override the surface paths so a scratch copy can be
# driven through the same predicates; each defaults to the real file. Every
# presence and absence check has a red twin run against such a copy.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WIKI="${GAIA_VERIFY_SURFACE_WIKI:-$ROOT/wiki/concepts/PR Merge Workflow.md}"
  RULE="${GAIA_VERIFY_SURFACE_RULE:-$ROOT/.claude/rules/pr-merge.md}"
  AGENT="${GAIA_VERIFY_SURFACE_AGENT:-$ROOT/.claude/agents/audit-loop-unit.md}"
}

# maintainer_text <file>: only the lines inside maintainer-only marker pairs.
maintainer_text() {
  awk '
    /<!-- gaia:maintainer-only:start -->/ { inside = 1; next }
    /<!-- gaia:maintainer-only:end -->/ { inside = 0; next }
    inside { print }
  ' "$1"
}

# outside_text <file>: only the lines outside maintainer-only marker pairs.
outside_text() {
  awk '
    /<!-- gaia:maintainer-only:start -->/ { inside = 1; next }
    /<!-- gaia:maintainer-only:end -->/ { inside = 0; next }
    !inside { print }
  ' "$1"
}

# block_has <file> <literal>: rc 0 when a maintainer-only block carries it.
block_has() {
  maintainer_text "$1" | grep -qF -- "$2"
}

# runner_outside_block <file>: rc 0 when a line outside every block names the
# runner.
runner_outside_block() {
  outside_text "$1" | grep -qF -- 'verify-harness.sh'
}

# separate_steps_listed <file>: rc 0 when a block names the shell-lint path or
# the selector, the old separate steps.
separate_steps_listed() {
  block_has "$1" '.gaia/tests/shell-lint.sh' || block_has "$1" 'bats-suites-for-change.sh'
}

# scratch_without <file> <literal> <name>: copy of the file with every line
# carrying the literal removed; prints its path.
scratch_without() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/$3"
  grep -vF -- "$2" "$1" >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# scratch_with_old_step <file> <name>: copy with the old separate steps added
# inside a maintainer-only block; prints its path.
scratch_with_old_step() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/$2"
  {
    cat "$1"
    printf '<!-- gaia:maintainer-only:start -->\n'
    printf 'Run `bash .gaia/tests/shell-lint.sh` and `bash .gaia/scripts/bats-suites-for-change.sh`.\n'
    printf '<!-- gaia:maintainer-only:end -->\n'
  } >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# scratch_with_outside_mention <file> <name>: copy with a runner mention
# outside any block; prints its path.
scratch_with_outside_mention() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/$2"
  {
    cat "$1"
    printf '\nRun bash .gaia/tests/verify-harness.sh branch here.\n'
  } >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# assert_block_pinned <file> <literal> <name>: present inside a block of the
# real file, absent from the scratch copy that drops it.
assert_block_pinned() {
  block_has "$1" "$2" || { echo "missing in a maintainer-only block of $1: $2" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1" "$2" "$3")"
  block_has "$copy" "$2" && { echo "red twin did not fail: $2" >&2; return 1; }
  true
}

@test "wiki and rule name branch mode inside their maintainer-only blocks" {
  assert_block_pinned "$WIKI" 'bash .gaia/tests/verify-harness.sh branch' wiki-without-branch.md
  assert_block_pinned "$RULE" 'bash .gaia/tests/verify-harness.sh branch' rule-without-branch.md
}

@test "all three surfaces name round mode inside their maintainer-only blocks" {
  assert_block_pinned "$WIKI" 'verify-harness.sh round' wiki-without-round.md
  assert_block_pinned "$RULE" 'verify-harness.sh round' rule-without-round.md
  assert_block_pinned "$AGENT" 'verify-harness.sh round' agent-without-round.md
}

@test "no surface lists shell-lint, the selector and bats5 as separate steps in a block" {
  separate_steps_listed "$WIKI" && return 1
  separate_steps_listed "$RULE" && return 1
  separate_steps_listed "$AGENT" && return 1
  true
}

@test "separate-steps red twin: restoring the old steps inside a block makes the predicate fire" {
  local copy
  for surface in "$WIKI" "$RULE" "$AGENT"; do
    copy="$(scratch_with_old_step "$surface" old-step.md)"
    separate_steps_listed "$copy" || { echo "red twin did not fail for $surface" >&2; return 1; }
  done
  true
}

@test "every line naming the runner sits inside a maintainer-only block" {
  runner_outside_block "$WIKI" && return 1
  runner_outside_block "$RULE" && return 1
  runner_outside_block "$AGENT" && return 1
  true
}

@test "outside-block red twin: a runner mention outside a block makes the predicate fire" {
  local copy
  for surface in "$WIKI" "$RULE" "$AGENT"; do
    copy="$(scratch_with_outside_mention "$surface" outside.md)"
    runner_outside_block "$copy" || { echo "red twin did not fail for $surface" >&2; return 1; }
  done
  true
}

@test "wiki and rule state the commit-first precondition" {
  assert_block_pinned "$WIKI" 'exit 3' wiki-without-exit3.md
  assert_block_pinned "$RULE" 'exit 3' rule-without-exit3.md
}

@test "wiki states branch mode comes after every other pre-dispatch commit" {
  assert_block_pinned "$WIKI" 'after every other pre-dispatch commit' wiki-without-order.md
}

@test "wiki, rule and agent name the dispatch refusal or its consequence" {
  assert_block_pinned "$WIKI" 'BLOCKED: audit verify' wiki-without-deny.md
  assert_block_pinned "$AGENT" 'BLOCKED: audit verify' agent-without-deny.md
}

@test "round-mode timeout is a failed verification, never a pass, on the wiki and the agent" {
  assert_block_pinned "$WIKI" 'never a pass' wiki-without-timeout.md
  assert_block_pinned "$AGENT" 'never a pass' agent-without-timeout.md
}
