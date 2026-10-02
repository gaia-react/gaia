#!/usr/bin/env bats
#
# Doc-conformance suite for the prose that describes the audit loop's branch
# checkpoint outside the PR Merge Workflow page: the always-loaded rules, the
# `/gaia-debt` and `/gaia-harden` references, the audit agent text, and the
# hook and script inventories.
#
# What it guards. The checkpoint has two audiences with opposite instructions:
# an interactive run asks the human in-session, an unattended drain asks
# nothing and reports. Prose that drifts back to a continuation prompt, or
# that lets a drain ask, silently reopens the loop's old failure. Each case
# reads one line or one section by its own text, never by line number, and
# every forbidden phrase is checked inside the paragraph that owns the
# instruction so an unrelated mention elsewhere in the file cannot green it.
#
# Each target path reads through an env override that defaults to the real
# file, so a mutant copy proves a case can fail without touching the tree.
# Absence checks are written `positive && return 1` per
# .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="${DOC_AUDIT_LOOP_DEBT_MD:-$REPO_ROOT/.claude/skills/gaia/references/debt.md}"
  HARDEN_MD="${DOC_AUDIT_LOOP_HARDEN_MD:-$REPO_ROOT/.claude/skills/gaia/references/harden.md}"
  PR_MERGE_MD="${DOC_AUDIT_LOOP_PR_MERGE_MD:-$REPO_ROOT/.claude/rules/pr-merge.md}"
  QUALITY_GATE_MD="${DOC_AUDIT_LOOP_QUALITY_GATE_MD:-$REPO_ROOT/.claude/rules/quality-gate.md}"
  HOOKS_WIKI="${DOC_AUDIT_LOOP_HOOKS_WIKI:-$REPO_ROOT/wiki/concepts/Claude Hooks.md}"
  SCRIPTS_WIKI="${DOC_AUDIT_LOOP_SCRIPTS_WIKI:-$REPO_ROOT/wiki/concepts/GAIA Scripts.md}"
  REVIEW_WIKI="${DOC_AUDIT_LOOP_REVIEW_WIKI:-$REPO_ROOT/wiki/concepts/Code Review Audit Agent.md}"
  FRONTEND_AGENT="${DOC_AUDIT_LOOP_FRONTEND_AGENT:-$REPO_ROOT/.claude/agents/code-audit-frontend.md}"
}

# line_starting <file> <literal-prefix>
# Prints the first line of the file that starts with the literal prefix. The
# caller asserts it is non-empty, so a missing paragraph fails loudly.
line_starting() {
  awk -v want="$2" 'index($0, want) == 1 { print; exit }' "$1"
}

# --- UAT-011: the unattended checkpoint ending -----------------------------

@test "UAT-011: debt.md's checkpoint ending pushes, keeps the PR and claim, reports, and names the typed line" {
  para="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$para" ]
  grep -qF -- 'pushed' <<<"$para"
  grep -qF -- 'the PR stays open' <<<"$para"
  grep -qF -- '`in-progress` claim stays' <<<"$para"
  grep -qF -- 'verdict' <<<"$para"
  grep -qF -- 'per-round evidence' <<<"$para"
  grep -qF -- 'recommendation' <<<"$para"
  grep -qF -- 'audit-loop-eval.sh brief' <<<"$para"
  grep -qF -- 'grant or accept line' <<<"$para"
  grep -qF -- 'interactive session on that branch' <<<"$para"
  grep -qF -- 'never grants itself rounds' <<<"$para"
}

@test "UAT-011: debt.md's checkpoint ending neither asks nor emits a continuation prompt" {
  para="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$para" ]
  grep -qF -- 'AskUserQuestion' <<<"$para" && return 1
  grep -qiF -- 'continuation prompt' <<<"$para" && return 1
  true
}

@test "COV-010: debt.md's fix-round stop pushes nothing, keeps the PR and claim, and reports reason and paths" {
  para="$(line_starting "$DEBT_MD" '- **A stop inside the fix round**')"
  [ -n "$para" ]
  grep -qF -- 'third Quality Gate failure' <<<"$para"
  grep -qF -- 'second verifier failure' <<<"$para"
  grep -qF -- 'second consecutive fixer no-op' <<<"$para"
  grep -qF -- 'Push nothing uncommitted' <<<"$para"
  grep -qF -- 'leave the PR open' <<<"$para"
  grep -qF -- 'keep the `in-progress` claim' <<<"$para"
  grep -qF -- 'stop reason' <<<"$para"
  grep -qF -- 'run-folder paths' <<<"$para"
  grep -qF -- 'AskUserQuestion' <<<"$para" && return 1
  grep -qiF -- 'continuation prompt' <<<"$para" && return 1
  true
}

# --- UAT-029: /gaia-harden asks at the checkpoint --------------------------

@test "UAT-029: harden.md's audit paragraph asks the checkpoint question and emits no continuation prompt" {
  para="$(line_starting "$HARDEN_MD" '**Run the audit, on every path.**')"
  [ -n "$para" ]
  grep -qF -- '#### The branch checkpoint' <<<"$para"
  grep -qF -- 'checkpoint `AskUserQuestion`' <<<"$para"
  grep -qF -- 'audit-loop-eval.sh brief' <<<"$para"
  grep -qiF -- 'continuation prompt' <<<"$para" && return 1
  grep -qiF -- 'is a stop' <<<"$para" && return 1
  true
}

# --- the always-loaded rules ------------------------------------------------

@test "pr-merge.md's checkpoint paragraph says Claude never writes grants or loop state, within the old byte budget" {
  para="$(line_starting "$PR_MERGE_MD" '**The audit loop runs on its own until the branch checkpoint.**')"
  [ -n "$para" ]
  grep -qF -- 'Claude never writes grants or loop state' <<<"$para"
  grep -qF -- '#### The branch checkpoint' <<<"$para"
  bytes="$(printf '%s\n' "$para" | wc -c | tr -d ' ')"
  [ "$bytes" -le 724 ]
}

@test "quality-gate.md carries the fix-round exception to its STOP clause" {
  grep -qF -- 'STOP and report before committing, except inside the fix round of `wiki/concepts/PR Merge Workflow.md` (`#### The fix round: fixer, verifier, gate`), where the branch checkpoint is the review point.' "$QUALITY_GATE_MD"
}

# --- wiki inventories -------------------------------------------------------

@test "Claude Hooks.md's table has a row for each audit-loop hook and none for the removed one" {
  for hook in audit-loop-ask-grant.sh audit-loop-bound.sh audit-loop-grant.sh block-audit-loop-write.sh; do
    grep -qF -- "| \`$hook\` |" "$HOOKS_WIKI" || { echo "missing table row: $hook" >&2; return 1; }
  done
  grep -qE -- 'block-fourth[-]audit-round' "$HOOKS_WIKI" && return 1
  true
}

@test "GAIA Scripts.md has a row for each audit-loop script" {
  for script in audit-fix-verify.sh audit-loop-eval.sh audit-loop-record.sh audit-loop-state-lib.sh; do
    grep -qF -- "| \`$script\` | yes |" "$SCRIPTS_WIKI" || { echo "missing row: $script" >&2; return 1; }
  done
}

# --- COV-007: the fixer is not briefed from the ledger ---------------------

@test "COV-007: Code Review Audit Agent.md says the ledger briefs the re-audit and the fixer reads dispositions" {
  grep -qF -- 'the fixer is briefed from the main thread' "$REVIEW_WIKI"
  grep -qF -- 'the fixer read the ledger' "$REVIEW_WIKI" && return 1
  true
}

@test "COV-007: code-audit-frontend.md no longer has the fixer reading the ledger" {
  [ "$(grep -cF -- "the fixer is briefed from the main thread's dispositions file" "$FRONTEND_AGENT")" -ge 2 ]
  grep -qF -- 'and the fixer read' "$FRONTEND_AGENT" && return 1
  grep -qF -- 'the next re-audit and the fixer' "$FRONTEND_AGENT" && return 1
  true
}

# --- the shared ledger is removed by the clearance writer, never a member ---
# One ledger serves every dispatched member, so a member deleting it on its own
# clean pass discards a co-dispatched member's open remaining[] entries
# (gaia-react/gaia#2416).

@test "code-audit-frontend.md never removes the shared re-run ledger itself" {
  grep -qF -- 'Never remove the ledger yourself' "$FRONTEND_AGENT"
  grep -qE -- 'rm[[:space:]].*\.rerun\.json' "$FRONTEND_AGENT" && return 1
  grep -qF -- 'Ledger cleanup' "$FRONTEND_AGENT" && return 1
  true
}
