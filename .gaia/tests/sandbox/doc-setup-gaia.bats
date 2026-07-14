#!/usr/bin/env bats
# UAT-002, UAT-006, UAT-009, UAT-011, UAT-012, UAT-014: conformance greps
# against the sandbox-decision block in .claude/commands/setup-gaia.md.
#
# The "sandbox block" is bounded by the "**Sandbox decision (runs even
# when..." heading and the following "### Step 1: install-tools" header;
# helpers below extract it by line range so checks scoped to the block don't
# false-positive on the file's many other AskUserQuestion prompts.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  DOC="$REPO_ROOT/.claude/commands/setup-gaia.md"
}

# Prints "<start> <end>" (1-based, end exclusive) for the sandbox block.
sandbox_block_bounds() {
  local start end
  start=$(grep -n '\*\*Sandbox decision (runs even when' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^### Step 1: install-tools' "$DOC" | head -1 | cut -d: -f1)
  printf '%s %s\n' "$start" "$end"
}

@test "UAT-012: sandbox-decision block contains exactly one AskUserQuestion" {
  read -r start end <<< "$(sandbox_block_bounds)"
  [ -n "$start" ]
  [ -n "$end" ]

  local count
  count=$(sed -n "${start},$((end - 1))p" "$DOC" | grep -c 'AskUserQuestion')
  [ "$count" -eq 1 ]
}

@test "UAT-006: sandbox prompt names docker/gh/terraform as backtick-delimited tokens" {
  grep -qF '`docker`' "$DOC"
  grep -qF '`gh`' "$DOC"
  grep -qF '`terraform`' "$DOC"
}

@test "DP-001: every 'gaia sandbox apply' in the sandbox block appears after its single AskUserQuestion" {
  read -r start end <<< "$(sandbox_block_bounds)"
  local ask_line
  ask_line=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /AskUserQuestion/ { print NR; exit }' "$DOC")
  [ -n "$ask_line" ]

  local apply_lines
  apply_lines=$(awk -v s="$start" -v e="$end" 'NR >= s && NR < e && /gaia sandbox apply/ { print NR }' "$DOC")
  [ -n "$apply_lines" ]

  local bad=0
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    [ "$ln" -gt "$ask_line" ] || bad=1
  done <<< "$apply_lines"

  [ "$bad" -eq 0 ]
}

@test "COV-004: prompt block reads RECOMMENDED and offers both enable and don't-enable options" {
  read -r start end <<< "$(sandbox_block_bounds)"
  local block
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  printf '%s' "$block" | grep -q 'RECOMMENDED'
  printf '%s' "$block" | grep -qF '**Enable the sandbox**'
  printf '%s' "$block" | grep -qF "**Don't enable**"
}

@test "UAT-014/COV-001: setup-gaia.md reader literal .sandbox_recommended is byte-identical to the schema writer key" {
  local schema="$REPO_ROOT/.gaia/cli/src/schemas/automation-config.ts"
  [ -f "$schema" ]

  local writer_key
  writer_key=$(grep -oE '^\s*sandbox_recommended:' "$schema" | head -1 | tr -d ' :')
  [ "$writer_key" = "sandbox_recommended" ]

  grep -qF "jq -r '.${writer_key} // false'" "$DOC"
}

@test "COV-005: sandbox decision runs in its Phase-2 carve-out position, gated on gaia sandbox status" {
  grep -qF '**Sandbox decision (runs even when `completed_at` is non-null).**' "$DOC"
  grep -qF 'gaia sandbox status' "$DOC"

  # No new SETUP_STEPS entry / mark-step call is added for the sandbox
  # decision; a clause hidden inside the completed_at short-circuit would
  # never reach a finalized adopter.
  grep -qE 'mark-step[[:space:]]+sandbox' "$DOC" && return 1
  return 0
}

@test "UAT-009/FC-4: sandbox honesty message contains all pinned substrings (spans its two adjacent paragraphs)" {
  local start end block
  start=$(grep -n '\*\*Sandbox honesty message\.\*\*' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^### Step 1: install-tools' "$DOC" | head -1 | cut -d: -f1)
  [ -n "$start" ]
  [ -n "$end" ]
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  printf '%s' "$block" | grep -qF 'enabling the sandbox alone does not protect .env'
  printf '%s' "$block" | grep -qF 'Read(.env)'
  printf '%s' "$block" | grep -qF 'Edit(.env)'
  printf '%s' "$block" | grep -qF 'sandboxed Bash'
  printf '%s' "$block" | grep -qF '.env.local'
  printf '%s' "$block" | grep -qF 'docker'
  printf '%s' "$block" | grep -qF 'MCP'
  printf '%s' "$block" | grep -qF 'Vite'
  printf '%s' "$block" | grep -qF 'unsandboxed'
}

@test "COV-003/SC7: seed blast-radius note discloses gh, uvx, and curl remain blocked" {
  local start end block
  start=$(grep -n '\*\*Sandbox honesty message\.\*\*' "$DOC" | head -1 | cut -d: -f1)
  end=$(grep -n '^### Step 1: install-tools' "$DOC" | head -1 | cut -d: -f1)
  block=$(sed -n "${start},$((end - 1))p" "$DOC")

  printf '%s' "$block" | grep -qF '`gh`'
  printf '%s' "$block" | grep -qF '`uvx`'
  printf '%s' "$block" | grep -qF '`curl`'
}

@test "UAT-011: Phase 6 wires --sandbox \"\$SANDBOX\" into the ping invocation" {
  grep -qF -- 'SANDBOX="$(.gaia/cli/gaia sandbox status --json' "$DOC"
  grep -qF -- '--sandbox "$SANDBOX"' "$DOC"
}

@test "UAT-001: the setup document carries no mentorship or coaching opt-in" {
  grep -niE 'mentorship|coaching|behavioral observ|telemetry' "$DOC" && return 1
  return 0
}
