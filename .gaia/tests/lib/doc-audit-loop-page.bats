#!/usr/bin/env bats
# Doc pins for the audit loop in `wiki/concepts/PR Merge Workflow.md`: the fix
# round (`#### The fix round: fixer, verifier, gate`) and the branch
# checkpoint (`#### The branch checkpoint`), plus the one clause the Quality
# Gate page carries for them. `.claude/rules/pr-merge.md` makes the merge page
# an executed contract, so each pin below holds a sentence an orchestrator
# acts on: who edits during the loop, when a round has no fixer, what a
# resume may not re-dispatch, and what a checkpoint selection does not do.
#
# Prose-to-prose only. Whether the fences in those sections run as written is
# doc-merge-workflow-fences.bats's subject; whether the scripts behave as the
# sentences say is each script's own suite.
#
# Sentence-scoped checks split a section on ". " after collapsing whitespace.
# A period inside a path or a section number has no space after it, so it
# never splits a sentence.
#
# GAIA_AUDIT_LOOP_PAGE and GAIA_QUALITY_GATE_PAGE override the two page paths
# so a mutated scratch copy can be driven through these same cases; both
# default to the real pages.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope, so SPEC-090 UAT ids in
# the test names below are traceability, not shipped prose.

# The pinned sentences carry backticks as literal Markdown, so single quotes
# are the point.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="${GAIA_AUDIT_LOOP_PAGE:-$ROOT/wiki/concepts/PR Merge Workflow.md}"
  QG="${GAIA_QUALITY_GATE_PAGE:-$ROOT/wiki/decisions/Quality Gate.md}"
  STEP2='^### 2\. Fix all issues'
  FIXROUND='^#### The fix round: fixer, verifier, gate'
  CHECKPOINT='^#### The branch checkpoint'
  WHENSTOP='^#### When rounds stop: pre-commit a disposition for every branch'
  CROSSREMIT='^#### Cross-remit findings'
}

# section <start_ERE>: the page from the heading matching <start_ERE> up to,
# excluding, the next H3 or H4. Fails loudly on a heading that matches
# nothing, so a renamed heading never passes a scoped check vacuously.
section() {
  local out
  out="$(awk -v start="$1" '
    $0 ~ start { found = 1; print; next }
    found && /^#{3,4} / { exit }
    found { print }
  ' "$PAGE")"
  [ -n "$out" ] || {
    echo "section anchor '$1' matched nothing in $PAGE" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# sentences: stdin as one sentence per line.
sentences() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed 's/\. /.\
/g'
}

# hand_edit_sentences: the sentences of stdin that tell the main thread to
# make a repair itself.
hand_edit_sentences() {
  sentences | grep -iE '(orchestrator|main thread) (applies|makes|edits|fixes).*(repair|fix|edit)'
}

@test "the fix-round and checkpoint headings exist and the retired per-session heading does not" {
  grep -qxF -- '#### The fix round: fixer, verifier, gate' "$PAGE"
  grep -qxF -- '#### The branch checkpoint' "$PAGE"
  # The retired heading is spelled with bracket classes so this file carries
  # none of the vocabulary the repository-wide check bans.
  grep -qiE -- '^#### The three[-]round session[ ]cap' "$PAGE" && return 1
  true
}

@test "UAT-001: step 2 and the fix round name the fixer dispatch and tell the main thread to make no repair itself" {
  local s
  s="$(section "$STEP2")" || return 1
  grep -qF -- 'a fresh fixer sub-agent makes the repairs' <<<"$s" || return 1
  grep -qF -- 'During the loop the main thread never hand-edits a file a finding names.' <<<"$s" || return 1
  hand_edit_sentences <<<"$s" && return 1
  s="$(section "$FIXROUND")" || return 1
  grep -qF -- '**Fixer dispatch.** Exactly one fresh `general-purpose` sub-agent per round' <<<"$s" || return 1
  hand_edit_sentences <<<"$s" && return 1
  true
}

@test "UAT-001: the cross-remit section routes an in-scope repair to the fixer, never the orchestrator" {
  local s
  s="$(section "$CROSSREMIT")" || return 1
  grep -qF -- 'marks it `fix` in the round'"'"'s dispositions file and the fixer repairs it' <<<"$s" || return 1
  hand_edit_sentences <<<"$s" && return 1
  true
}

@test "UAT-010: the loop sections carry no clear-and-paste handoff" {
  local anchor s
  for anchor in "$STEP2" "$FIXROUND" "$CHECKPOINT"; do
    s="$(section "$anchor")" || return 1
    grep -qiE -- '/clear|continuation prompt' <<<"$s" && {
      echo "a loop section names a clear-and-paste handoff: $anchor" >&2
      return 1
    }
  done
  true
}

@test "UAT-010: a checkpoint selection changes nothing until the human types the line" {
  local s
  s="$(section "$CHECKPOINT")" || return 1
  sentences <<<"$s" | grep -qF -- 'Selecting an option changes nothing until the human types that line as the whole prompt, in this same session;' || return 1
  grep -qF -- 'Claude never types, writes, or simulates the line, and never writes the branch state file.' <<<"$s"
}

@test "UAT-008: quiet only proposes the When-rounds-stop disposition and the page's judgment decides it" {
  local s
  s="$(section "$WHENSTOP")" || return 1
  sentences <<<"$s" | grep -qE -- 'A `quiet` verdict .* only proposes this section'"'"'s disposition; this section'"'"'s own judgment of what this change authored decides it' || return 1
  s="$(section "$CHECKPOINT")" || return 1
  grep -qF -- 'a stop heuristic that proposes the [[#When rounds stop: pre-commit a disposition for every branch]] disposition and decides nothing on its own' <<<"$s"
}

@test "UAT-027: the fix round's resume rule runs drift and overrides the generic re-dispatch rule" {
  local s
  s="$(section "$FIXROUND")" || return 1
  grep -qF -- 'bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh drift --root <RESOLVED_ROOT> --baseline <RUN_FOLDER>/baseline-<r>.json' <<<"$s" || return 1
  sentences <<<"$s" | grep -qF -- "overrides the execution doctrine's generic rule to re-dispatch any dispatch whose artifact is missing: a round with \`baseline-<r>.json\` and no \`fixer-<r>-audit.json\`" || return 1
  sentences <<<"$s" | grep -qF -- 'means a fixer edited and never wrote its result: do not re-dispatch the fixer' || return 1
  grep -qF -- 'An interactive run asks the human, an unattended run stops and reports. A second fixer on top of those edits' <<<"$(sentences <<<"$s" | tr '\n' ' ')"
}

@test "UAT-017: the closing round after an accept has no fixer and records the residuals under the heading" {
  local s
  s="$(section "$CHECKPOINT")" || return 1
  sentences <<<"$s" | grep -qF -- 'No fixer is dispatched for it, so the round has no `fixer-<r>-audit.json`: the members re-audit the current tree to earn their markers, and the remaining entries are recorded under the heading `## Accepted residuals (recorded, not fixed)` in the PR body' || return 1
  sentences <<<"$s" | grep -qF -- 'A closing round never re-arms the loop: if it does not clear, the next new-tree dispatch is denied and the human decides again.'
}

@test "UAT-015: a gate log exists only for an attempt whose verifier passed" {
  local s
  s="$(section "$FIXROUND")" || return 1
  grep -qF -- 'gate-<r>-<k>.log' <<<"$s" || return 1
  sentences <<<"$s" | grep -qF -- 'A gate log exists only for an attempt whose verifier passed, because the verifier runs again after every repair continuation, before the next gate.'
}

@test "COV-001: the record is published at every round end, a round with no commit included" {
  local s
  s="$(section "$FIXROUND")" || return 1
  sentences <<<"$s" | grep -qF -- 'Publish it at every round end, not only after a push: a committed round, a clean or zero-fix round that makes no commit, the closing round, and any stop' || return 1
}

@test "COV-009: a round with zero fix entries has no baseline, fixer, verifier, gate or commit" {
  local s
  s="$(section "$FIXROUND")" || return 1
  sentences <<<"$s" | grep -qF -- 'the round has no baseline, no fixer, no verifier, no gate, and no commit.' || return 1
}

@test "DP-003 and DP-004: the fix round states the attempt rule and reads the round index from current-round" {
  local s
  s="$(section "$FIXROUND")" || return 1
  grep -qF -- 'bash .gaia/scripts/audit-loop-eval.sh current-round --root <RESOLVED_ROOT>' <<<"$s" || return 1
  sentences <<<"$s" | grep -qF -- 'Never count rounds by hand:' || return 1
  sentences <<<"$s" | grep -qF -- '`k` starts at 1 for the fixer'"'"'s first write in a round and increases by 1 on every SendMessage continuation of that fixer, a verifier retry or a gate repair alike.' || return 1
}

@test "the Quality Gate page's stop-and-report step carries the fix-round clause" {
  grep -qF -- '10. **Stop and report**: wait for user approval, except inside the PR Merge Workflow'"'"'s fix round ([[PR Merge Workflow#The fix round: fixer, verifier, gate]]).' "$QG"
}
