#!/usr/bin/env bats
#
# Every run that owes a cost record writes it through `usage.sh record` with its
# own workflow, and no tracked file calls the retired tally. Each writer is
# located by its content, so moving a step to another section keeps the suite
# green while deleting the call turns it red. A writer whose anchor cannot be
# found fails the case: an absent anchor never passes vacuously.
#
# The honest limit: a doc-and-code grep proves the instruction is present and
# names the right workflow, not that the model carries it out; the recipe
# itself is exercised end to end in the record suite.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES="$REPO_ROOT/.claude/skills/gaia/references"
}

# require_in <file> <extended regex> <what it must carry>: fails with a message
# naming the file and the missing anchor.
require_in() {
  [ -f "$1" ] || { printf 'writer file missing: %s\n' "$1" >&2; return 1; }
  grep -q -E -- "$2" "$1" || { printf '%s: no %s\n' "$1" "$3" >&2; return 1; }
}

# argv_block <file> <start literal>: the lines from the start marker to the first
# closing bracket, with whitespace removed so a reformat cannot hide a token.
argv_block() {
  [ -f "$1" ] || { printf 'writer file missing: %s\n' "$1" >&2; return 1; }
  awk -v start="$2" 'index($0, start) { found = 1 } found { print } found && /\]/ { exit }' "$1" | tr -d ' \t\n'
}

@test "spec.md records the gaia-spec run at the save step" {
  require_in "$REFERENCES/spec.md" 'usage\.sh record spec:\$\{SPEC_ID\} --workflow gaia-spec' 'gaia-spec record call'
}

@test "plan.md records the gaia-plan run for both a spec-derived and a spec-less plan" {
  require_in "$REFERENCES/plan.md" 'usage\.sh record spec:<SPEC-NNN> --workflow gaia-plan' 'spec-derived gaia-plan record call'
  require_in "$REFERENCES/plan.md" 'usage\.sh record plan:<PLAN-NNN> --workflow gaia-plan' 'spec-less gaia-plan record call'
}

@test "planner.md prints the full-cycle line before merge and links the branch before the first phase dispatch" {
  require_in "$REFERENCES/plan/planner.md" 'usage\.sh initiative <root> --line' 'initiative --line call'
  require_in "$REFERENCES/plan/planner.md" 'before the merge' 'before-merge placement of the full-cycle line'
  require_in "$REFERENCES/plan/planner.md" 'before the first phase dispatch.*usage\.sh link branch:' 'branch link before the first phase dispatch'
}

@test "cost-record.md holds the shared recipe with the command placeholder" {
  require_in "$REFERENCES/cost-record.md" 'usage\.sh record command:\{\{COMMAND\}\} --workflow \{\{COMMAND\}\}' 'recipe call with {{COMMAND}}'
}

@test "harden, debt and residue apply the shared recipe with their own command" {
  local command
  for command in harden debt residue; do
    require_in "$REFERENCES/$command.md" 'references/cost-record\.md.*\{\{COMMAND\}\}` = `gaia-'"$command"'`' "cost-record.md reference for gaia-$command"
  done
}

@test "audit and fitness record their own workflow" {
  require_in "$REFERENCES/audit.md" 'usage\.sh record command:gaia-audit --workflow gaia-audit' 'gaia-audit record call'
  require_in "$REFERENCES/fitness.md" 'usage\.sh record command:gaia-fitness --workflow gaia-fitness' 'gaia-fitness record call'
}

@test "forensics records its workflow, and passes the issue through only for gaia-react/gaia" {
  require_in "$REFERENCES/forensics.md" 'usage\.sh record command:gaia-forensics --workflow gaia-forensics$' 'bare gaia-forensics record call'
  require_in "$REFERENCES/forensics.md" '`--issue <N>` only when the current repo is `gaia-react/gaia`' 'same-repo condition on --issue'
  require_in "$REFERENCES/forensics.md" 'otherwise record the bare call' 'bare call fallback for any other repo'
  require_in "$REFERENCES/forensics.md" '^[[:space:]]+--issue <N>$' '--issue pass-through continuation line'
}

@test "the wiki chain records command:gaia-wiki with its workflow, and its test pins that argv" {
  local code_block test_block expected="'record','command:gaia-wiki','--workflow','gaia-wiki'"
  code_block="$(argv_block "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts" 'USAGE_SCRIPT,')"
  [ -n "$code_block" ] || { printf 'chain.ts: no record argv block\n' >&2; return 1; }
  case "$code_block" in *"$expected"*) ;; *) printf 'chain.ts argv: %s\n' "$code_block" >&2; return 1 ;; esac
  test_block="$(argv_block "$REPO_ROOT/.gaia/cli/src/wiki/chain.test.ts" 'USAGE_SCRIPT,')"
  [ -n "$test_block" ] || { printf 'chain.test.ts: no record argv block\n' >&2; return 1; }
  case "$test_block" in *"$expected"*) ;; *) printf 'chain.test.ts argv: %s\n' "$test_block" >&2; return 1 ;; esac
}

@test "no tracked file invokes the retired tally script" {
  # The name is assembled so this file does not hold it.
  local retired="token-""tally.sh" files
  [ "$(git -C "$REPO_ROOT" ls-files | wc -l | tr -d ' ')" -gt 963 ]
  files="$(git -C "$REPO_ROOT" grep -l -F -- "$retired" -- . \
    ':!CHANGELOG.md' ':!wiki/log.md' ':!wiki/meta' ':!wiki/decisions' \
    ':!.gaia/tests/fixtures/dedup-key-corpus' \
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv' \
    ':!.gaia/scripts/tests/fixtures/usage/baseline-e4b57e23' \
    ':!.gaia/audit-ci.yml' ':!.gaia/scripts/tests/cost-stack-absence.bats' || true)"
  [ -z "$files" ] || { printf '%s\n' "$files" >&2; return 1; }
}
