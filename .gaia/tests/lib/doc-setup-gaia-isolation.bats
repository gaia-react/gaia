#!/usr/bin/env bats
#
# Doc-conformance suite for the `/setup-gaia` `## Phase 3.5: Team git
# isolation policy (always evaluated)` clause (.claude/commands/setup-gaia.md),
# the existing-adopter entry point for the team git isolation policy.
#
# The clause is extracted by heading bounds (`^## Phase 3\.5` -> `^## Phase 4`)
# so every check below is scoped to it and cannot false-positive on the file's
# many other AskUserQuestion prompts. Landed in .gaia/tests/lib/ (not
# .gaia/tests/sandbox/, which no workflow runs) so audit-ci-tests.yml actually
# gates it.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Absence checks
# are written as `<positive-condition-for-the-bad-case> && return 1`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC="$REPO_ROOT/.claude/commands/setup-gaia.md"
}

# Prints "<start> <end>" (1-based, end exclusive) for the Phase 3.5 clause.
phase35_bounds() {
  local start end
  start=$(grep -n '^## Phase 3\.5' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^## Phase 4' "$DOC" | head -1 | cut -d: -f1)
  printf '%s %s\n' "$start" "$end"
}

phase35_block() {
  local start end
  read -r start end <<< "$(phase35_bounds)"
  sed -n "${start},$((end - 1))p" "$DOC"
}

@test "the Phase 3.5 heading exists and precedes Phase 4" {
  read -r start end <<< "$(phase35_bounds)"
  [ -n "$start" ]
  [ -n "$end" ]
  [ "$start" -lt "$end" ]
}

@test "the block contains exactly one AskUserQuestion" {
  local block count
  block="$(phase35_block)"
  count=$(printf '%s' "$block" | grep -o 'AskUserQuestion' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "AskUserQuestion appears after the check-admin guard (line-number ordering)" {
  read -r start end <<< "$(phase35_bounds)"

  local admin_line ask_line
  admin_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /setup-ci check-admin/ { print NR; exit }' "$DOC")
  ask_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /AskUserQuestion/ { print NR; exit }' "$DOC")

  [ -n "$admin_line" ]
  [ -n "$ask_line" ]
  [ "$ask_line" -gt "$admin_line" ]
}

@test "no JSON-writing construct besides the one CLI write shell-out" {
  local block bad_jq
  block="$(phase35_block)"

  # A real jq-to-file write redirects jq's stdout; distinguish it from the
  # intentional "2>/dev/null" stderr redirect the has()/read probes use. The
  # trailing `|| true` is load-bearing: grep -v exits 1 when it filters out
  # every line, which would otherwise abort this command substitution under
  # bats' set -e before the emptiness check below ever runs.
  bad_jq=$(printf '%s\n' "$block" | grep -n 'jq' | grep '>' | grep -v '2>/dev/null' || true)
  [ -z "$bad_jq" ] || return 1

  printf '%s' "$block" | grep -qF '<<' && return 1
  printf '%s' "$block" | grep -qF 'python -c' && return 1
  printf '%s' "$block" | grep -qF 'sed -i' && return 1
  true
}

@test "the only write is the write-isolation-policy CLI shell-out" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qF '.gaia/cli/gaia setup-ci write-isolation-policy'
}

@test "the clause carries its own commit of .gaia/automation.json" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qF 'git add .gaia/automation.json'
  printf '%s' "$block" | grep -qF 'git commit'
}

@test "the absence probe is has(\"isolation_policy\"), never the fragment's read literal" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qF 'has("isolation_policy")'
  printf '%s' "$block" | grep -qF 'isolation_policy // ' && return 1
  true
}

@test "the explainer names all four worktree costs plus the scope limit" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qF 'node_modules'
  printf '%s' "$block" | grep -qF 'editor indexes'
  printf '%s' "$block" | grep -qF 'collides on the same port'
  printf '%s' "$block" | grep -qF 'leave a worktree behind'
  printf '%s' "$block" | grep -qF '/gaia-plan'
  printf '%s' "$block" | grep -qF '/gaia-debt'
  printf '%s' "$block" | grep -qF '/update-deps'
  printf '%s' "$block" | grep -qF '/update-gaia'
}

@test "no maintainer-repo issue numbers leak into the clause" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qE '#(727|728)' && return 1
  true
}

@test "the header is Isolation policy, never Branch mode, and no fragment option label leaks in" {
  local block
  block="$(phase35_block)"
  printf '%s' "$block" | grep -qF 'Isolation policy'
  printf '%s' "$block" | grep -qF 'Branch mode' && return 1
  printf '%s' "$block" | grep -qF 'Create a feature branch in place' && return 1
  printf '%s' "$block" | grep -qF 'Create a git worktree' && return 1
  true
}

@test "UAT-010: the absent-config skip is real, first, and honest" {
  read -r start end <<< "$(phase35_bounds)"
  local block guard_line write_line
  block="$(phase35_block)"

  printf '%s' "$block" | grep -qF -- '-f .gaia/automation.json'

  guard_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /-f \.gaia\/automation\.json/ { print NR; exit }' "$DOC")
  write_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /setup-ci write-isolation-policy/ { print NR; exit }' "$DOC")
  [ -n "$guard_line" ]
  [ -n "$write_line" ]
  [ "$guard_line" -lt "$write_line" ]

  printf '%s' "$block" | grep -qF "nothing to record the team's git isolation policy in"
}

@test "UAT-009: the question never fires before both the has() probe and the RECONFIGURE gate" {
  read -r start end <<< "$(phase35_bounds)"
  local probe_line reconfigure_line ask_line

  probe_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /has\("isolation_policy"\)/ { print NR; exit }' "$DOC")
  reconfigure_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /RECONFIGURE/ { print NR; exit }' "$DOC")
  ask_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /AskUserQuestion/ { print NR; exit }' "$DOC")

  [ -n "$probe_line" ]
  [ -n "$reconfigure_line" ]
  [ -n "$ask_line" ]
  [ "$ask_line" -gt "$probe_line" ]
  [ "$ask_line" -gt "$reconfigure_line" ]
}

@test "both Phase 4 CI path-filter entries are present" {
  local yml="$REPO_ROOT/.github/workflows/audit-ci-tests.yml"
  [ -f "$yml" ]
  grep -qF "'.claude/commands/setup-gaia.md'" "$yml"
  grep -qF "'.claude/commands/gaia-init.md'" "$yml"
}

@test "both Phase 4 suites have a coverage row in the README" {
  local readme="$REPO_ROOT/.gaia/tests/lib/README.md"
  [ -f "$readme" ]
  grep -qF 'doc-setup-gaia-isolation.bats' "$readme"
  grep -qF 'doc-gaia-init-isolation.bats' "$readme"
}
