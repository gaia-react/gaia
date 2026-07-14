#!/usr/bin/env bats
#
# Doc-conformance suite for the /gaia-init Step 9 "Team git isolation policy"
# block (.claude/commands/gaia-init.md) and its terminal write in "### Apply
# the answer".
#
# The load-bearing gate is case 4: the /setup-gaia isolation clause (the
# sibling doc-conformance suite covers it) fires only when
# `isolation_policy` is ABSENT from .gaia/automation.json. A regression that
# pre-sets `--isolation-policy` to a default value on a non-response would
# make that entry point unreachable for every project /gaia-init creates,
# and nothing else in this repo would catch it: .claude/commands/gaia-init.md
# appeared in no workflow path filter before this suite landed.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Absence
# checks are written as `<positive-condition-for-the-bad-case> && return 1`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC="$REPO_ROOT/.claude/commands/gaia-init.md"
}

# Prints "<start> <end>" (1-based, end exclusive) for the isolation block.
isolation_block_bounds() {
  local start end
  start=$(grep -n '^### Team git isolation policy' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^### Apply the answer' "$DOC" | head -1 | cut -d: -f1)
  printf '%s %s\n' "$start" "$end"
}

# Prints "<start> <end>" (1-based, end exclusive) for the Apply-the-answer block.
apply_block_bounds() {
  local start end
  start=$(grep -n '^### Apply the answer' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^## Step 10: Refresh the wiki' "$DOC" | head -1 | cut -d: -f1)
  printf '%s %s\n' "$start" "$end"
}

@test "the isolation block contains exactly one AskUserQuestion" {
  read -r start end <<< "$(isolation_block_bounds)"
  [ -n "$start" ]
  [ -n "$end" ]

  local count
  count=$(sed -n "${start},$((end - 1))p" "$DOC" | grep -c 'AskUserQuestion')
  [ "$count" -eq 1 ]
}

@test "the header is Isolation policy, and the block does not contain Branch mode" {
  read -r start end <<< "$(isolation_block_bounds)"
  local block
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  printf '%s' "$block" | grep -qF 'header `Isolation policy`' || return 1
  printf '%s' "$block" | grep -qi 'Branch mode' && return 1
  true
}

@test "the omit-on-non-response rule is stated in both the isolation block and Apply the answer" {
  read -r i_start i_end <<< "$(isolation_block_bounds)"
  read -r a_start a_end <<< "$(apply_block_bounds)"

  local isolation_block apply_block
  isolation_block=$(sed -n "${i_start},$((i_end - 1))p" "$DOC")
  apply_block=$(sed -n "${a_start},$((a_end - 1))p" "$DOC")

  printf '%s' "$isolation_block" | grep -qi 'omit the flag entirely' || return 1
  printf '%s' "$apply_block" | grep -qi 'omit the flag entirely' || return 1
}

@test "no baked default: --isolation-policy never appears followed by a literal policy value" {
  grep -nE -- '--isolation-policy[[:space:]]+(prefer-branch|prefer-worktree|always-worktree)' "$DOC" && return 1
  true
}

@test "the three option labels and value mapping match FC-4, with Prefer branches (Recommended) leading" {
  read -r start end <<< "$(isolation_block_bounds)"
  local block
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  local branch_line worktree_line always_line
  branch_line=$(printf '%s\n' "$block" | grep -n -F '**Prefer branches (Recommended).**' | head -1 | cut -d: -f1)
  worktree_line=$(printf '%s\n' "$block" | grep -n -F '**Prefer worktrees.**' | head -1 | cut -d: -f1)
  always_line=$(printf '%s\n' "$block" | grep -n -F '**Always use worktrees.**' | head -1 | cut -d: -f1)

  [ -n "$branch_line" ]
  [ -n "$worktree_line" ]
  [ -n "$always_line" ]

  # Lead option: appears before the other two.
  [ "$branch_line" -lt "$worktree_line" ]
  [ "$branch_line" -lt "$always_line" ]

  printf '%s' "$block" | grep -qF 'prefer-branch`, `prefer-worktree`, or `always-worktree`' || return 1
}

@test "no maintainer-repo issue numbers leak into the isolation block" {
  read -r start end <<< "$(isolation_block_bounds)"
  sed -n "${start},$((end - 1))p" "$DOC" | grep -nE '#(727|728)' && return 1
  true
}

@test "the Apply the answer block shows --isolation-policy as an optional, bracketed flag" {
  read -r start end <<< "$(apply_block_bounds)"
  local block
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  printf '%s' "$block" | grep -qF '[--isolation-policy <always-worktree|prefer-worktree|prefer-branch>]' || return 1
}
