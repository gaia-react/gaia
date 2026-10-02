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
  QUALITY_GATE_PAGE="${GAIA_QUALITY_GATE_PAGE:-$ROOT/wiki/decisions/Quality Gate.md}"
  STEP2='^### 2\. Fix all issues'
  FIXROUND='^#### The fix round: fixer, verifier, gate'
  CHECKPOINT='^#### The branch checkpoint'
  WHENSTOP='^#### When rounds stop: pre-commit a disposition for every branch'
  CROSSREMIT='^#### Cross-remit findings'
  UNIT='^#### The audit loop unit'
  UNIT_AGENT="${GAIA_AUDIT_LOOP_UNIT_AGENT:-$ROOT/.claude/agents/audit-loop-unit.md}"
  PR_MERGE_RULE="${GAIA_PR_MERGE_RULE:-$ROOT/.claude/rules/pr-merge.md}"
  FIX_VERIFY="${GAIA_AUDIT_FIX_VERIFY:-$ROOT/.gaia/scripts/audit-fix-verify.sh}"
}

# section <start_ERE>: the page from the heading matching <start_ERE> up to,
# excluding, the next H3 or H4. Fails loudly on a heading that matches
# nothing, so a renamed heading never passes a scoped check vacuously.
section() {
  local extracted_section
  extracted_section="$(awk -v start="$1" '
    $0 ~ start { found = 1; print; next }
    found && /^#{3,4} / { exit }
    found { print }
  ' "$PAGE")"
  [ -n "$extracted_section" ] || {
    echo "section anchor '$1' matched nothing in $PAGE" >&2
    return 1
  }
  printf '%s\n' "$extracted_section"
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
  local section_text
  section_text="$(section "$STEP2")" || return 1
  grep -qF -- 'a fresh fixer sub-agent makes the repairs' <<<"$section_text" || return 1
  grep -qF -- 'During the loop the main thread never hand-edits a file a finding names.' <<<"$section_text" || return 1
  hand_edit_sentences <<<"$section_text" && return 1
  section_text="$(section "$FIXROUND")" || return 1
  grep -qF -- '**Fixer dispatch.** Exactly one fresh `general-purpose` sub-agent per round' <<<"$section_text" || return 1
  hand_edit_sentences <<<"$section_text" && return 1
  true
}

@test "UAT-001: the cross-remit section routes an in-scope repair to the fixer, never the orchestrator" {
  local section_text
  section_text="$(section "$CROSSREMIT")" || return 1
  grep -qF -- 'marks it `fix` in the round'"'"'s dispositions file and the fixer repairs it' <<<"$section_text" || return 1
  hand_edit_sentences <<<"$section_text" && return 1
  true
}

@test "UAT-010: the loop sections carry no clear-and-paste handoff" {
  local anchor section_text
  for anchor in "$STEP2" "$UNIT" "$FIXROUND"; do
    section_text="$(section "$anchor")" || return 1
    grep -qiE -- '/clear|continuation prompt' <<<"$section_text" && {
      echo "a loop section names a clear-and-paste handoff: $anchor" >&2
      return 1
    }
  done
  true
}

@test "UAT-010: a checkpoint selection records only through the pinned question, and Claude never types the line" {
  local section_text
  section_text="$(section "$CHECKPOINT")" || return 1
  grep -qF -- 'Selecting an option changes nothing until the human types that line' <<<"$section_text" && return 1
  sentences <<<"$section_text" | grep -qF -- 'records a selection as the answer only when the question came from the main thread of an interactive session' || return 1
  sentences <<<"$section_text" | grep -qF -- "the call's \`tool_input\` equals the pinned question exactly" || return 1
  sentences <<<"$section_text" | grep -qF -- 'Any other answer records nothing and leaves the state byte-identical' || return 1
  grep -qF -- 'Claude never types, writes, or simulates the line, and never writes the branch state file.' <<<"$section_text"
}

@test "UAT-008: quiet only proposes the When-rounds-stop disposition and the page's judgment decides it" {
  local section_text
  section_text="$(section "$WHENSTOP")" || return 1
  sentences <<<"$section_text" | grep -qE -- 'A `quiet` verdict .* only proposes this section'"'"'s disposition; this section'"'"'s own judgment of what this change authored decides it' || return 1
  section_text="$(section "$CHECKPOINT")" || return 1
  grep -qF -- 'a stop heuristic that proposes the [[#When rounds stop: pre-commit a disposition for every branch]] disposition and decides nothing on its own' <<<"$section_text"
}

@test "UAT-027: the fix round's resume rule runs drift and overrides the generic re-dispatch rule" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  grep -qF -- 'bash <RUN_FOLDER>/verifier-bin-<r>/audit-fix-verify.sh drift --root <RESOLVED_ROOT> --baseline <RUN_FOLDER>/baseline-<r>.json' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- "overrides the execution doctrine's generic rule to re-dispatch any dispatch whose artifact is missing: a round with \`baseline-<r>.json\` and no \`fixer-<r>-audit.json\`" || return 1
  sentences <<<"$section_text" | grep -qF -- 'means a fixer edited and never wrote its result: do not re-dispatch the fixer' || return 1
  grep -qF -- 'An interactive run asks the human, an unattended run stops and reports. A second fixer on top of those edits' <<<"$(sentences <<<"$section_text" | tr '\n' ' ')"
}

@test "UAT-017: the closing round after an accept has no fixer and records the residuals under the heading" {
  local section_text
  section_text="$(section "$CHECKPOINT")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'No fixer is dispatched for it, so the round has no `fixer-<r>-audit.json`: the members re-audit the current tree to earn their markers, and the remaining entries are recorded under the heading `## Accepted residuals (recorded, not fixed)` in the PR body' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A closing round never re-arms the loop: if it does not clear, the next new-tree dispatch is denied and the human decides again.'
}

@test "UAT-015: a gate log exists only for an attempt whose verifier passed" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  grep -qF -- 'gate-<r>-<k>.log' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'A gate log exists only for an attempt whose verifier passed, because the verifier runs again after every repair continuation, before the next gate.'
}

@test "COV-001: the record is published at every round end, a round with no commit included" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'Publish it at every round end, not only after a push: a committed round, a clean or zero-fix round that makes no commit, the closing round, and any stop' || return 1
}

@test "COV-009: a round with zero fix entries has no baseline, fixer, verifier, gate or commit" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'the round has no baseline, no fixer, no verifier, no gate, and no commit.' || return 1
}

@test "DP-003 and DP-004: the fix round states the attempt rule and reads the round index from current-round" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  grep -qF -- 'bash .gaia/scripts/audit-loop-eval.sh current-round --root <RESOLVED_ROOT>' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'Never count rounds by hand:' || return 1
  sentences <<<"$section_text" | grep -qF -- '`k` starts at 1 for the fixer'"'"'s first write in a round and increases by 1 on every SendMessage continuation of that fixer, a verifier retry or a gate repair alike.' || return 1
}

@test "the Quality Gate page's stop-and-report step carries the fix-round clause" {
  grep -qF -- '10. **Stop and report**: wait for user approval, except inside the PR Merge Workflow'"'"'s fix round ([[PR Merge Workflow#The fix round: fixer, verifier, gate]]).' "$QUALITY_GATE_PAGE"
}

# --- the audit loop unit ----------------------------------------------------

# anchors_resolve <page> <agent>: every `#### ...` anchor the agent names
# resolves to exactly one heading line in the page. Derived from the agent
# file; an empty derivation is a failure, never a pass.
anchors_resolve() {
  local page="$1" agent="$2" anchors anchor count=0
  anchors="$(grep -oE '`#### [^`]+`' "$agent" | tr -d '`')"
  [ -n "$anchors" ] || {
    echo "no #### anchor derived from $agent" >&2
    return 1
  }
  while IFS= read -r anchor; do
    count=$((count + 1))
    [ "$(grep -cxF -- "$anchor" "$page")" -eq 1 ] || {
      echo "anchor does not resolve to exactly one heading: $anchor" >&2
      return 1
    }
  done <<<"$anchors"
  [ "$count" -ge 4 ] || {
    echo "derived only $count anchors from $agent" >&2
    return 1
  }
}

@test "UAT-021: the audit loop unit heading exists exactly once" {
  [ "$(grep -cxF -- '#### The audit loop unit' "$PAGE")" -eq 1 ]
}

@test "DP-018: every anchor the unit agent names resolves to exactly one heading, and the check has a red twin" {
  anchors_resolve "$PAGE" "$UNIT_AGENT" || return 1
  grep -qxF -- '#### The audit loop unit' "$PAGE" || return 1
  local copy="$BATS_TEST_TMPDIR/page-renamed.md"
  sed 's/^#### The audit loop unit$/#### The audit loop unit renamed/' "$PAGE" >"$copy"
  anchors_resolve "$copy" "$UNIT_AGENT" 2>/dev/null && return 1
  copy="$BATS_TEST_TMPDIR/page-duplicated.md"
  { cat "$PAGE"; printf '\n#### The audit loop unit\n'; } >"$copy"
  anchors_resolve "$copy" "$UNIT_AGENT" 2>/dev/null && return 1
  true
}

@test "the unit section states the main thread's loop: next-unit, pre-clear, one blocking wait, the classifier call" {
  local section_text
  section_text="$(section "$UNIT")" || return 1
  grep -qF -- 'audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>' <<<"$section_text" || return 1
  grep -qF -- 'rm -f <RUN_FOLDER>/unit-<u>.json' <<<"$section_text" || return 1
  grep -qF -- 'one blocking Monitor until-loop on `<RUN_FOLDER>/unit-<u>.json`' <<<"$section_text" || return 1
  grep -qF -- 'audit-noop-detect.sh --shape agent-report-file --path <RUN_FOLDER>/unit-<u>.json --report-key rounds --min-count 1' <<<"$section_text" || return 1
  grep -qF -- 'subagent_type: "audit-loop-unit"' <<<"$section_text" || return 1
  grep -qF -- 'Claude Code 2.1.287 or later' <<<"$section_text" || return 1
}

@test "the unit section maps every stop_reason and every deny class the agent classifies" {
  local section_text reason
  section_text="$(section "$UNIT")" || return 1
  for reason in clean window-end checkpoint-deny dispositions-check-failed needs-human failure nesting-unavailable; do
    grep -qF -- "\`$reason\`" <<<"$section_text" || { echo "stop_reason missing: $reason" >&2; return 1; }
  done
  grep -qF -- 'PreToolUse:Agent hook error: BLOCKED: ...' <<<"$section_text" || return 1
  grep -qF -- '`BLOCKED: audit checkpoint` maps to `checkpoint-deny`, `BLOCKED: audit window` to `window-end`, `BLOCKED: audit dispositions` to `dispositions-check-failed`, and any other `BLOCKED:` to `failure`' <<<"$section_text" || return 1
  grep -qF -- "audit-loop-bound.sh\`'s header owns the deny text" <<<"$section_text" || return 1
  grep -qF -- 'audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>' <<<"$section_text" || return 1
}

@test "the unit section states the in-unit rule: agent_id and agent_type, anything else is a one-round unit" {
  local section_text
  section_text="$(section "$UNIT")" || return 1
  grep -qF -- 'only when its payload carries an `agent_id` and its `agent_type` is `audit-loop-unit`' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- "Any other member dispatch, the main thread's included, is judged inline as a one-round unit" || return 1
  sentences <<<"$section_text" | grep -qF -- 'An answered checkpoint is spent once a later round is recorded, so in the fallback one grant admits the next round, not every dispatch up to the cap.' || return 1
}

@test "the unit section builds the waiver table from the dispositions files and binds a veto to the next unit's rounds" {
  local section_text
  section_text="$(section "$UNIT")" || return 1
  grep -qF -- 'audit-dispositions-check.sh waiver-table --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --rounds <a>-<b>' <<<"$section_text" || return 1
  grep -qF -- 'never from the informational `waiver_table` in `unit-<u>.json`' <<<"$section_text" || return 1
  grep -qF -- '`<RUN_FOLDER>/vetoes.json` with Bash at the main checkout' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'Each veto'"'"'s `effective_from_round` is the `<s>` that `next-unit` prints at that moment, so a veto binds the next unit'"'"'s rounds and never re-grades the round that held the waiver.' || return 1
  sentences <<<"$section_text" | grep -qF -- 'its commit rotates the owning member'"'"'s digest' || return 1
}

@test "the unit section assigns the three PR-body sections to the unit and the rewrite after a veto to the main thread" {
  local section_text heading
  section_text="$(section "$UNIT")" || return 1
  for heading in '## Accepted residuals (recorded, not fixed)' '## Out-of-scope machinery findings (recorded, not filed)' '## Waived below triage threshold (not filed)'; do
    grep -qF -- "$heading" <<<"$section_text" || { echo "heading missing: $heading" >&2; return 1; }
  done
  sentences <<<"$section_text" | grep -qF -- 'The main thread rewrites those sections after a veto' || return 1
  grep -qF -- 'audit-dispositions-check.sh pr-sections' <<<"$section_text"
}

@test "the unit section never lets the unit merge, and a missing unit file stops for the human" {
  local section_text
  section_text="$(section "$UNIT")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'It runs no `gh pr merge`, posts no `GAIA-Audit` status, writes no marker, edits no `CHANGELOG.md`, and never writes the loop state or `vetoes.json`.' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A unit that returns with no `unit-<u>.json` stops the main thread for the human; it never falls back inline on its own.' || return 1
  grep -qF -- 'the main thread reads this section, [[#The branch checkpoint]], [[#Posting the status last]] and the CHANGELOG gate, and does not read the round procedure' <<<"$(sentences <<<"$section_text" | tr '\n' ' ')" || return 1
}

@test "the fix round runs the dispositions check before the baseline, and states unit recovery beside the resume override" {
  local section_text check_line baseline_line
  section_text="$(section "$FIXROUND")" || return 1
  check_line="$(grep -nF -- 'audit-dispositions-check.sh check --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER> --round <r>' <<<"$section_text" | head -1 | cut -d: -f1)"
  baseline_line="$(grep -nF -- '**Baseline.**' <<<"$section_text" | head -1 | cut -d: -f1)"
  [ -n "$check_line" ] && [ -n "$baseline_line" ] || return 1
  [ "$check_line" -lt "$baseline_line" ] || return 1
  grep -qF -- 'with no `--snapshot-dir` (only the bound hook writes snapshots;' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'runs the `drift` check above on any `baseline-<r>.json` that has no `fixer-<r>-audit.json`: exit 1 stops it `needs-human`.' || return 1
  grep -qF -- '**Unit recovery.**' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'the unit calls `audit-loop-record.sh` itself' || return 1
  sentences <<<"$section_text" | grep -qF -- 'The procedure each round runs, inside the unit (or on the main thread in the nesting-unavailable fallback), in this order.' || return 1
}

# pinned_labels: the option labels the evaluator's pinned question can carry,
# one per line, without the (Recommended) suffix. Derived from the builder, not retyped.
pinned_labels() {
  bash -c '
    . "$1/.gaia/scripts/context-checkpoint-lib.sh"
    . "$1/.gaia/scripts/audit-loop-state-lib.sh"
    unit_round_count="$GAIA_CTX_UNIT_ROUNDS"
    { gaia_loop_pinned_question feat/x 0123456789abcdef 6 "$unit_round_count" true false context
      gaia_loop_pinned_question feat/x 0123456789abcdef 10 "$unit_round_count" false true cap
    } | jq -r ".questions[0].options[].label" | sed "s/ (Recommended)$//" | sort -u
  ' _ "$ROOT"
}

@test "the checkpoint section quotes every pinned option label and says the recommended one leads" {
  local section_text labels label label_count=0
  section_text="$(section "$CHECKPOINT")" || return 1
  labels="$(pinned_labels)"
  [ -n "$labels" ] || { echo "no labels derived from the pinned question builder" >&2; return 1; }
  while IFS= read -r label; do
    label_count=$((label_count + 1))
    grep -qF -- "\`$label\`" <<<"$section_text" || { echo "label not quoted: $label" >&2; return 1; }
  done <<<"$labels"
  [ "$label_count" -eq 5 ] || { echo "expected 5 distinct labels, derived $label_count" >&2; return 1; }
  grep -qF -- '(Recommended)' <<<"$section_text" || return 1
  grep -qF -- 'leads' <<<"$section_text" || return 1
  grep -qF -- 'context-checkpoint-lib.sh' <<<"$section_text" || return 1
  true
}

@test "the checkpoint section names the recorder, the pinned-question printer and both owners of the numbers" {
  local section_text
  section_text="$(section "$CHECKPOINT")" || return 1
  grep -qF -- 'audit-loop-ask-grant.sh' <<<"$section_text" || return 1
  grep -qF -- 'audit-loop-eval.sh pinned-question --root <RESOLVED_ROOT>' <<<"$section_text" || return 1
  grep -qF -- "\`.gaia/scripts/audit-loop-eval.sh\`'s header" <<<"$section_text" || return 1
  grep -qF -- '.gaia/scripts/context-checkpoint-lib.sh' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'This page restates none of them.' || return 1
  grep -qE -- '(300000|200000|1800) ' <<<"$section_text" && return 1
  true
}

@test "UAT-014: the new-session option prints a fenced continuation prompt and an unattended run prints the typed line and none" {
  local section_text fence
  section_text="$(section "$CHECKPOINT")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'for the human to paste into a fresh session' || return 1
  grep -qF -- 'Run `/clear`, then paste the prompt below.' <<<"$section_text" || return 1
  grep -qF -- 'Kill this session with Ctrl+C, start a new one (`claude`, with any needed environment variable), then paste the prompt below.' <<<"$section_text" || return 1
  grep -qF -- 'only a fresh launch provides' <<<"$section_text" || return 1
  fence="$(awk '/^```text$/ { open = 1; next } /^```$/ { open = 0 } open { print }' <<<"$section_text")"
  grep -qF -- 'Resume the PR merge workflow for PR #<N>' <<<"$fence" || return 1
  grep -qF -- 'audit-loop-eval.sh next-unit --root <RESOLVED_ROOT>' <<<"$fence" || return 1
  sentences <<<"$section_text" | grep -qF -- "It prints the typed \`audit-grant <n>\` line from the brief's \`grant_line\` and no continuation prompt" || return 1
  sentences <<<"$section_text" | grep -qF -- 'An unattended run never asks and never grants.' || return 1
}

@test "the clean-stop last guard is read-only and reads the branch's frozen snapshots" {
  local row
  row="$(grep -F -- 'audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>` once more as a last guard' "$PAGE")" || return 1
  grep -qF -- 'read-only: with no `--snapshot-dir` it re-grades each round from the branch'"'"'s frozen snapshots' <<<"$row" || return 1
  grep -qF -- 'it writes nothing' <<<"$row" || return 1
  grep -qF -- 'no snapshot directory)' <<<"$row" && return 1
  true
}

@test "the checkpoint section states the context gate, the fallback, the cap, one grant per unit, and the guard's false-deny" {
  local section_text
  section_text="$(section "$CHECKPOINT")" || return 1
  grep -qF -- '**The context gate.**' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'A reading that is missing, stale, future-dated or unparseable falls back to the round-count checkpoint and never allows past it.' || return 1
  sentences <<<"$section_text" | grep -qF -- 'a dispatch that would open a round past the hard cap is denied whatever was granted' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A grant answering the latest checkpoint admits exactly one unit of K rounds' || return 1
  grep -qF -- 'a Bash heredoc or inline script whose text merely names those paths or a recorder' <<<"$section_text" || return 1
  grep -qF -- 'write such files with the Write or Edit tools' <<<"$section_text" || return 1
}

# --- UAT-021: sentences the unit made false stay out of the loop prose -------

# stale_present <file> <literal>: rc 0 when the fixed string is in the file.
stale_present() {
  grep -qF -- "$2" "$1"
}

# stale_pairs: `<file-key>|<literal>` lines, one per retired sentence.
stale_pairs() {
  cat <<'PAIRS'
page|Nothing raises the allowance from a PR-body edit, an environment knob above the default, or an AskUserQuestion selection
page|Selecting an option changes nothing until the human types that line
page|The main thread writes it locally at every round end
page|The checkpoint round sits where the normal branch has already finished
page|on every `Agent` dispatch of a `code-audit-*` member
page|The procedure the main thread runs for every round
page|`dispositions-<r>.json` (main thread)
page|dispositions-<r>.json (main thread)
page|The main thread stages, commits, and pushes the verified round
rule|only a human typing the grant or accept line raises it
verify|dispositions-<r>.json (main thread)
PAIRS
}

# stale_file <file-key>: the path a pair's key names.
stale_file() {
  case "$1" in
    page) printf '%s\n' "$PAGE" ;;
    rule) printf '%s\n' "$PR_MERGE_RULE" ;;
    verify) printf '%s\n' "$FIX_VERIFY" ;;
    *) return 1 ;;
  esac
}

@test "UAT-021: no sentence the unit made false survives, and restoring any one of them fails the check" {
  local pairs key literal file pair_count=0 copy
  pairs="$(stale_pairs)"
  while IFS='|' read -r key literal; do
    pair_count=$((pair_count + 1))
    file="$(stale_file "$key")" || return 1
    [ -f "$file" ] || { echo "file missing for $key: $file" >&2; return 1; }
    stale_present "$file" "$literal" && { echo "retired sentence present in $key: $literal" >&2; return 1; }
    copy="$BATS_TEST_TMPDIR/stale-$pair_count.txt"
    { cat "$file"; printf '%s\n' "$literal"; } >"$copy"
    stale_present "$copy" "$literal" || { echo "red twin did not fail for: $literal" >&2; return 1; }
  done <<<"$pairs"
  [ "$pair_count" -eq 11 ] || { echo "expected 11 pairs, read $pair_count" >&2; return 1; }
}
