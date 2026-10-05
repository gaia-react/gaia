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
  paragraph="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$paragraph" ]
  grep -qF -- 'pushed' <<<"$paragraph"
  grep -qF -- 'the PR stays open' <<<"$paragraph"
  grep -qF -- '`in-progress` claim stays' <<<"$paragraph"
  grep -qF -- 'verdict' <<<"$paragraph"
  grep -qF -- 'per-round evidence' <<<"$paragraph"
  grep -qF -- 'recommendation' <<<"$paragraph"
  grep -qF -- 'audit-loop-eval.sh brief' <<<"$paragraph"
  grep -qF -- 'grant or accept line' <<<"$paragraph"
  grep -qF -- 'interactive session on that branch' <<<"$paragraph"
  grep -qF -- 'never grants itself rounds' <<<"$paragraph"
}

@test "UAT-011: debt.md's checkpoint ending neither asks nor emits a continuation prompt" {
  paragraph="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$paragraph" ]
  grep -qF -- 'AskUserQuestion' <<<"$paragraph" && return 1
  grep -qiF -- 'continuation prompt' <<<"$paragraph" && return 1
  true
}

@test "COV-010: debt.md's fix-round stop pushes nothing, keeps the PR and claim, and reports reason and paths" {
  paragraph="$(line_starting "$DEBT_MD" '- **A stop inside the fix round**')"
  [ -n "$paragraph" ]
  grep -qF -- 'third Quality Gate failure' <<<"$paragraph"
  grep -qF -- 'second verifier failure' <<<"$paragraph"
  grep -qF -- 'second consecutive fixer no-op' <<<"$paragraph"
  grep -qF -- 'Push nothing uncommitted' <<<"$paragraph"
  grep -qF -- 'leave the PR open' <<<"$paragraph"
  grep -qF -- 'keep the `in-progress` claim' <<<"$paragraph"
  grep -qF -- 'stop reason' <<<"$paragraph"
  grep -qF -- 'run-folder paths' <<<"$paragraph"
  grep -qF -- 'AskUserQuestion' <<<"$paragraph" && return 1
  grep -qiF -- 'continuation prompt' <<<"$paragraph" && return 1
  true
}

# --- UAT-029: /gaia-harden asks at the checkpoint --------------------------

@test "UAT-029: harden.md's audit paragraph asks the checkpoint question and emits no continuation prompt" {
  paragraph="$(line_starting "$HARDEN_MD" '**Run the audit, on every path.**')"
  [ -n "$paragraph" ]
  grep -qF -- '#### The branch checkpoint' <<<"$paragraph"
  grep -qF -- 'checkpoint `AskUserQuestion`' <<<"$paragraph"
  grep -qF -- 'audit-loop-eval.sh brief' <<<"$paragraph"
  grep -qiF -- 'continuation prompt' <<<"$paragraph" && return 1
  grep -qiF -- 'is a stop' <<<"$paragraph" && return 1
  true
}

# --- the always-loaded rules ------------------------------------------------

@test "pr-merge.md's checkpoint paragraph says Claude never writes grants or loop state, within the old byte budget" {
  paragraph="$(line_starting "$PR_MERGE_MD" '**The audit loop runs on its own until the branch checkpoint.**')"
  [ -n "$paragraph" ]
  grep -qF -- 'Claude never writes grants or loop state' <<<"$paragraph"
  grep -qF -- '#### The branch checkpoint' <<<"$paragraph"
  bytes="$(printf '%s\n' "$paragraph" | wc -c | tr -d ' ')"
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
  grep -qF -- "the fixer is briefed from the dispositions file the round's orchestrator writes" "$REVIEW_WIKI"
  grep -qF -- "the fixer is briefed from the main thread's dispositions file" "$REVIEW_WIKI" && return 1
  grep -qF -- 'the fixer read the ledger' "$REVIEW_WIKI" && return 1
  true
}

@test "COV-007: code-audit-frontend.md no longer has the fixer reading the ledger" {
  [ "$(grep -cF -- "the fixer is briefed from the dispositions file the round's orchestrator writes" "$FRONTEND_AGENT")" -ge 2 ]
  grep -qF -- "the fixer is briefed from the main thread's dispositions file" "$FRONTEND_AGENT" && return 1
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

# --- a closing round applies no self-heal ----------------------------------
# A self-heal writes no marker and a closing round makes no commit, so a member
# that self-heals there can never clear it. The member reads the closing flag
# from branch state itself, never from a brief, and the two sites that would
# otherwise send it to self-heal point at the section.

@test "code-audit-frontend.md reads the closing flag itself and applies no self-heal in a closing round" {
  local closing needle
  closing="$(awk '/^## Closing round$/ {inside_closing_section=1; next} /^## / {inside_closing_section=0} inside_closing_section' "$FRONTEND_AGENT")"
  [ -n "$closing" ]
  for needle in \
    'audit-loop-eval.sh unit-window --root <root>' \
    'exits 0 and its fourth field is `true`' \
    'apply no self-heal and promote no out-of-scope finding' \
    '`AUDIT_SELF_HEALED` stays `"false"`' \
    'do not withhold the marker' \
    'Preconditions 1, 2 and 4 are unchanged'; do
    grep -qF -- "$needle" <<<"$closing" || { echo "not under Closing round: $needle" >&2; return 1; }
  done
  [ "$(grep -cF -- 'in a closing round (see "Closing round")' "$FRONTEND_AGENT")" -ge 3 ]
}
