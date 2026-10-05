#!/usr/bin/env bash
# PreToolUse hook on Agent|Task: bound the pre-merge audit loop per BRANCH.
# It gates two dispatches. An `audit-loop-unit` dispatch asks to run a unit of
# up to K audit rounds off the main thread; the hook admits it against the
# main session's context reading, the rubric signals, the round cap and the
# round-count fallback, and records the unit's window. A Code Audit Team
# member dispatch on a HEAD tree not yet audited opens a round; the hook
# evaluates the previous round, records the new one, and allows it only
# inside the window of the unit that made it, or, made from the main thread,
# only where a one-round unit would be admitted. The numbers, formulas,
# defaults and the order of the decision steps live in
# .gaia/scripts/audit-loop-eval.sh's header (DECISION); the context line and K
# live in .gaia/scripts/context-checkpoint-lib.sh; the state file shape and
# its writers live in .gaia/scripts/audit-loop-state-lib.sh's header. This
# file restates none of them.
#
# WHY A HOOK AND NOT PROSE. The audit loop's fix-and-re-audit cycle has no
# stop of its own: every round's fixes buy the next dispatch, so an
# unattended run spends without bound, and the judgement "is another round
# worth it" gets made mid-loop by the session least able to make it. Running
# the loop inside a unit keeps the rounds off the main thread, but the main
# thread's context still grows with every unit it reads back, which is why
# the gate reads that context. Prose cannot hold a boundary an agent has a
# standing reason to cross. The only ways past a checkpoint are a selection of
# the pinned question recorded by audit-loop-ask-grant.sh and a line a human
# types (audit-loop-grant.sh).
#
# WHAT IS BOUNDED. The branch, not the session. The history lives in one
# state file under the main checkout's local state directory, keyed by the
# normalized branch name, so every session, sub-agent, fork and linked
# worktree on the branch reads and extends one record. session_id is NOT part
# of the key. /clear, compaction, a new session, a fork and a sub-agent leave
# history and allowance untouched, and no SessionStart registration exists.
# session_id is recorded on a checkpoint, so the grant hooks can find the
# checkpoint a session hit when its working directory is on another branch,
# and on a unit, and it selects the context reading the gate consults.
#
# WRITER CONTRACT. This hook writes every part of the state file except
# `allowance` (the grant hooks own that), under the per-branch lock, and the
# dispositions snapshots under the state's `<branch>.d/` directory through the
# audit-dispositions-check.sh invocation it makes with --snapshot-dir. The
# full contract is in audit-loop-state-lib.sh's header.
#
# WAVE IDENTITY: the audited checkout's HEAD tree. A round is one dispatch
# wave, whatever that wave spawns. Every member in a wave is dispatched
# against one HEAD, so every invocation in that wave computes the same tree
# and only the first one records a round; the rest append their member to it.
# This collapses N parallel dispatches by construction, with no timing window
# to misfire. It is sound rather than a coincidence: the workflow requires
# HEAD to move between rounds, so a genuine new round always presents a new
# tree. The one hardened re-dispatch of a member that no-op'd (see
# wiki/concepts/PR Merge Workflow.md, "No-op detection and retry for each
# dispatched member", and .claude/rules/subagent-dispatch.md) shares its
# wave's unmoved tree and is therefore free, which is correct: it is the
# first round finishing, not a new one. A dispatch on an already-audited tree
# is allowed at a checkpoint and past a window too, but it still runs the
# dispositions check below. A unit dispatch never records a round.
#
# THE ORDER OF ONE DECISION. Resolve the audited checkout and the branch; on a
# dispatch that may change the state (a unit, or a member on a new tree),
# check for uncommitted work (a member always; a unit only when the branch has
# no state yet), refuse a fork, and look the pull request up; take the lock and
# re-read the state; run the dispositions check (every path, joins included);
# join an already-recorded wave; link, close or carry over the pull request
# record; freeze the knobs and the line config when absent; evaluate the
# previous round when its snapshot is missing; read the context; decide. On an
# allowed unit the hook appends its window to `history.units`; on an allowed
# member it records the round.
#
# THE UNIT WINDOW. An admitted unit owns rounds start_round..through_round as
# recorded in its `history.units` entry. A member dispatch the unit makes is
# allowed on a new tree only while the next round falls inside the latest
# window; past it the deny is the window class below and the unit stops.
#
# IN-UNIT OR MAIN THREAD. A member dispatch counts as made inside a unit only
# when the payload carries an `agent_id` and its `agent_type` is
# `audit-loop-unit`; the harness sets both on a sub-agent's call and neither on
# the main thread's, and the same session_id reaches both. Any other member
# dispatch (the main thread, or some other sub-agent) is judged as a one-round
# unit: the cap, the rubric, a fresh grant, a spent accept, then the context
# line or the fallback, and it appends no `history.units` entry. Limit: the check trusts
# the harness's payload fields; a harness that stops sending them makes every
# dispatch read as the main thread's, which is the stricter judgement.
#
# AN ANSWER IS SPENT BY THE ROUND AFTER IT. The decision functions admit on
# an answered checkpoint until a unit consumes it. A main-thread member
# dispatch appends no unit, so on its own it would spend the same answer every
# round. This hook therefore treats the latest checkpoint's answer as spent
# once a round has been recorded after that checkpoint (decision input only;
# nothing is written), and the next dispatch is judged afresh.
#
# THE CONTEXT READING. gaia_context_read for this payload's session_id at the main
# checkout. Anything but a fresh reading (missing, stale, future-dated,
# unparseable, or a session id that is not one) falls back to the round count
# allowance, never past it. Honest limits: the reading changes only when the
# statusline renders, which is on main-thread turns, so the spend of the
# rounds a unit runs off the thread is invisible to it until the unit
# returns; that is why the rubric signals and the round cap stay independent
# bounds. The line config is frozen per branch and only lowered live.
#
# DENY CLASSES. Every deny reason starts with one of these, and a unit and the
# main thread branch on the prefix (a harness prefix may precede it):
#   `BLOCKED: audit checkpoint`    a context, cap, fallback or rubric
#                                  checkpoint; always records a checkpoint with
#                                  a fresh nonce and a pinned question,
#                                  superseding any pending one.
#   `BLOCKED: audit window`        a member dispatch past its unit's window;
#                                  records nothing new.
#   `BLOCKED: audit dispositions`  the dispositions check failed; its
#                                  violation lines follow; records nothing.
#   any other `BLOCKED:`           a fail-loud deny (below).
#
# STATED FAILURE MODES, honestly:
# - A dispatch cancelled at the permission prompt has already counted: the
#   count is taken at PreToolUse, and the round is recorded `unknown` when no
#   findings arrive. Refunding on absent evidence would make deleting a
#   sidecar a way to buy rounds. The recovery is a human answer.
# - A commit that leaves the tree byte-identical (an empty commit, a
#   message-only amend) reads as the same round. A deliberate re-dispatch on
#   an unmoved tree is likewise free; the guard cannot tell it from the
#   no-op retry. Under-counting is the safe direction for a bound that stops
#   spend rather than protecting correctness.
# - A branch renamed after its first round keeps its history only when a PR
#   links the old and new names; without one it starts again at round 1.
#
# FAIL LOUD, NOT FAIL OPEN. Every unknown denies with a message, never allows.
# Deny causes: a corrupt state file (never rewritten, with the human-run
# repair in the message), a missing jq (exit 2 through the shared arm, only
# for a call that names a member or a unit) or git, a library or the
# dispositions check script that will not load, an audited checkout that
# cannot be resolved, a detached HEAD or an unkeyable branch name, an
# unreadable HEAD, a dirty audited checkout where a round or the first unit
# would start (commit the round first), a lock that could not be taken, an
# evaluation, pinned question or state write that failed, and an internal
# deadline that passed. A harness that never delivers this event leaves the
# guard inert, and "inert" and "working" are indistinguishable from this file
# alone; the registration is checked by the registration suite, not here.
#
# DEADLINE. The whole decision runs in a background process group while this
# shell waits, with a watchdog that signals this shell after the deadline
# (default below, lowered only by GAIA_AUDIT_LOOP_DEADLINE_SECONDS, an
# integer from 1 to the default; a larger or malformed value is ignored).
# The signal makes this shell kill the process group and deny naming the
# deadline, so a slow git, a hung gh or a held lock can never stall the
# dispatch. The settings.json registration carries an explicit `timeout`
# above the deadline so the harness never cuts the hook off before it can
# answer; the measured basis for both numbers is recorded with the
# registration.
#
# SCOPE: only tool_input.subagent_type matching code-audit-* or naming
# audit-loop-unit counts, checked before any git, filesystem, context or
# settings read because the overwhelming majority of dispatches are neither.
# The roster does not pin the subagent_type a member's own internal fan-out
# carries; the filter does not need that pin: a nested dispatch shares its
# wave's HEAD tree and is free whatever it is named. A payload's top-level
# agent_type names the agent MAKING the call, the opposite question, and
# folding it into the scope would count a member's own nested dispatches as
# top-level rounds; it is read only to tell a unit's member dispatch from a
# main-thread one (IN-UNIT above).
#
# AUDITED ROOT. The dispatch prompt's `Working root:` path wins over the
# payload cwd (the orchestrator audits a linked worktree from the main
# checkout, and a unit brief carries one); a named path that does not resolve
# to a checkout denies rather than falling back to cwd, which would charge a
# tree other than the one the member audits. The state file is resolved to
# the main checkout through gaia_resolve_main_root in main-root-lib.sh, so a
# worktree and the main checkout name one record.
#
# FORK REFUSAL. A dispatch that would record a new round or admit a unit is
# denied when the audited checkout's pull request is a fork
# (cross-repository), and also when gh cannot say whether it is one; a branch
# with no pull request yet proceeds. The check and the message live in
# .claude/hooks/lib/cross-repo-refusal.sh. A dispatch joining an
# already-recorded round skips it: that round was recorded past this same
# check. This is a refusal, not a defense: on a fork head this file is itself
# the fork's copy, and only the pre-checkout guard acts before that.
set -uo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
# The literals are the two scope spellings; a subagent_type that reaches the
# scope check only through JSON escapes inside the name is not matched.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: audit-loop-bound.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the audit loop checkpoint' "$payload" tool_input 'code-audit-' 'audit-loop-unit'

deny() {
  # A deny can fire while a killed job is still being reported on stderr
  # (see cleanup); the answer is stdout only.
  exec 2>/dev/null
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Cheapest discriminators first: the tool name, then only
# tool_input.subagent_type (see SCOPE above). The caller's agent fields ride
# along in the same jq call.
fields=$(jq -r '[(.tool_name // "" | if type == "string" then . else "" end),
  ((.tool_input | objects | .subagent_type) // "" | if type == "string" then . else "" end),
  (.session_id // "" | if type == "string" then . else "" end),
  (.agent_id // "" | if type == "string" then . else "" end),
  (.agent_type // "" | if type == "string" then . else "" end)] | join("\u001f")' <<<"$payload" 2>/dev/null) ||
  deny 'BLOCKED: the audit loop checkpoint could not parse this tool call payload. Fail-loud, not fail-open: retry the dispatch.'
IFS=$'\037' read -r tool member session caller_id caller_type <<<"$fields"
case "$tool" in
  Agent | Task) ;;
  *) exit 0 ;;
esac
case "$member" in
  audit-loop-unit) kind=unit ;;
  code-audit-*) kind=member ;;
  *) exit 0 ;;
esac

GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=20
deadline=$GAIA_AUDIT_LOOP_DEADLINE_DEFAULT
if [[ "${GAIA_AUDIT_LOOP_DEADLINE_SECONDS-}" =~ ^[1-9][0-9]{0,2}$ ]] &&
  [ "$GAIA_AUDIT_LOOP_DEADLINE_SECONDS" -le "$GAIA_AUDIT_LOOP_DEADLINE_DEFAULT" ]; then
  deadline=$GAIA_AUDIT_LOOP_DEADLINE_SECONDS
fi
started=$(date +%s)
lock_deadline=$((started + (deadline > 1 ? deadline - 1 : 1)))

work=$(mktemp -d "${TMPDIR:-/tmp}/audit-loop-bound.XXXXXX" 2>/dev/null) ||
  deny 'BLOCKED: the audit loop checkpoint could not create a scratch directory. Fail-loud, not fail-open: check TMPDIR and retry.'
hook_pid=$$
child_pid=''
watchdog_pid=''

# shellcheck disable=SC2329 # invoked through the EXIT trap
cleanup() {
  # Bash reports a job that died of a signal on its own stderr, racing the
  # exit; the answer travels on stdout and the exit code only.
  exec 2>/dev/null
  if [ -n "$watchdog_pid" ]; then
    kill -TERM -- "-$watchdog_pid" 2>/dev/null
    pkill -TERM -P "$watchdog_pid" 2>/dev/null
    kill -TERM "$watchdog_pid" 2>/dev/null
  fi
  if [ -n "$child_pid" ]; then
    kill -TERM -- "-$child_pid" 2>/dev/null
    pkill -TERM -P "$child_pid" 2>/dev/null
    kill -TERM "$child_pid" 2>/dev/null
  fi
  rm -rf "$work" 2>/dev/null
}
trap cleanup EXIT
trap 'deny "BLOCKED: the audit loop checkpoint did not finish within its ${deadline}s internal deadline (a slow git or gh call, or a held state lock). Fail-loud, not fail-open: retry the dispatch, and if it repeats check the machine and the state lock under the main checkout audit-loop directory."' TERM
trap 'deny "BLOCKED: the audit loop checkpoint was interrupted before it could decide. Fail-loud, not fail-open: retry the dispatch."' INT HUP

# ---------------------------------------------------------------------------
# The decision. Runs in a background subshell, writes its verdict to
# $work/verdict (`allow`, or `deny` and the message), and never denies from
# inside a command substitution (an exit there ends only the substitution).
# A missing or malformed verdict file is itself a deny.
# ---------------------------------------------------------------------------
finish_allow() {
  printf 'allow\n' >"$work/verdict.tmp" && mv -f "$work/verdict.tmp" "$work/verdict"
  exit 0
}

finish_deny() {
  printf 'deny\n%s\n' "$1" >"$work/verdict.tmp" && mv -f "$work/verdict.tmp" "$work/verdict"
  exit 0
}

# corrupt_message <file>: why the state file reads as corrupt, plus the repair.
corrupt_message() {
  local state_file_path="$1" why stamp schema
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if ! jq -e . "$state_file_path" >/dev/null 2>&1; then
    why='is invalid JSON'
  else
    schema=$(jq -r '.schema // "missing"' "$state_file_path" 2>/dev/null) || schema='unreadable'
    if [ "$schema" != 1 ]; then
      why="has schema $schema; this hook reads schema 1 only"
    else
      why='fails the schema 1 shape check (a required key is missing or malformed)'
    fi
  fi
  printf 'BLOCKED: the audit loop state file for branch %s %s: %s\nThis hook never rewrites or resets it, and Claude must not either. From a terminal outside Claude Code, move it aside: mv '"'"'%s'"'"' '"'"'%s.corrupt-%s'"'"'; the branch then starts again at round 1. Do not retry the dispatch until a human has done that.' \
    "$BRANCH_KEY" "$why" "$state_file_path" "$state_file_path" "$state_file_path" "$stamp"
}

# checkpoint_message <state-json> <used> <trigger> <question-json>
checkpoint_message() {
  local state_json="$1" used="$2" trigger="$3" question="$4" grant_round_count
  grant_round_count=$(jq -r '.history.knobs.grant_rounds // 3' <<<"$state_json")
  printf 'BLOCKED: audit checkpoint on branch %s after %s rounds (%s).\n' "$BRANCH_KEY" "$used" "$trigger"
  jq -r '.history.rounds | to_entries[]
    | "  round \(.key + 1): A=\(.value.snapshot.A // "n/a") verdict=\(.value.snapshot.verdict // "unevaluated")"' <<<"$state_json"
  printf '\nThis stops the loop for a human decision; it is not a defect and not a merge blocker.\n'
  printf 'Interactive run: on the main thread of this session, ask this question with AskUserQuestion exactly as printed, passing the JSON below as the whole tool input (do not reword, reorder, add or drop an option). Inside an audit-loop-unit: stop with stop_reason checkpoint-deny and return; the main thread asks.\n'
  # shellcheck disable=SC2016 # the backticks are a literal Markdown fence
  printf '```json\n%s\n```\n' "$question"
  printf 'The human may instead type one of these lines as the whole prompt, in this same session (the grant hook resolves the checkpoint by this session id when the session working directory is on another branch):\n'
  printf 'Grant (type exactly as the whole prompt): %s\n' "$(gaia_loop_grant_line "$grant_round_count")"
  printf 'Accept (type exactly as the whole prompt): %s\n' "$(gaia_loop_accept_line)"
  printf 'Unattended run (no human in the session: a headless, scheduled, or /loop run): never ask; stop, leave the PR open, print the typed grant line above, and print no continuation prompt.\n'
  printf '\nClaude never writes the state file and never types or simulates these lines. A dispatch on an already-audited tree is still allowed.\n'
  # shellcheck disable=SC2016 # the backticks are literal text in the message
  printf 'Evidence and recommendation: `bash %s/audit-loop-eval.sh brief --root %s`.\n' "$scripts" "$root"
  printf 'State file: %s\n' "$file"
}

# window_message <state-json> <used>
window_message() {
  local window
  window=$(jq -r '((.history.units // []) | last) as $latest_unit
    | if $latest_unit == null then "no unit window is recorded on this branch"
      else "unit \($latest_unit.unit) was admitted for rounds \($latest_unit.start_round) through \($latest_unit.through_round)" end' <<<"$1")
  printf 'BLOCKED: audit window on branch %s: %s, and this wave would open round %s. Inside an audit-loop-unit: do not dispatch this wave; stop with stop_reason window-end and return, and the main thread admits the next unit. No round and no checkpoint were recorded.\n' \
    "$BRANCH_KEY" "$window" "$(($2 + 1))"
}

# set_member <state-json> <index> : append $member to round <index> when absent.
add_member() {
  jq -c --argjson round_index "$2" --arg member_name "$member" \
    '.history.rounds[$round_index].members |= (if index($member_name) then . else . + [$member_name] end)' <<<"$1"
}

# tree_index <state-json>: the index of the round recorded for $tree, or empty.
tree_index() {
  jq -r --arg t "$tree" \
    '[.history.rounds | to_entries[] | select(.value.tree == $t) | .key] | first // empty' <<<"$1"
}

# answer_view <state-json>: the decision input. When a round has been recorded
# after the latest checkpoint, its answer is spent (header, AN ANSWER IS
# SPENT); the view carries an in-memory unit marker past that checkpoint so
# the grant-admission step skips it. Never written.
answer_view() {
  jq -c '(.history.checkpoints | last) as $c
    | if $c != null and (.history.rounds | length) > $c.at_round
         and (((.history.units // []) | last | .after_checkpoint?) // -1) < $c.index
      then .history.units = ((.history.units // []) + [{unit: 0, start_round: 0, k: 0, through_round: 0,
             admitted_on: "context", after_checkpoint: $c.index}])
      else . end' <<<"$1"
}

# check_dispositions: the dispositions check over every round of the run
# folder; any non-zero exit denies with its violation lines.
check_dispositions() {
  local dispositions_output check_exit_status=0
  dispositions_output=$(bash "$scripts/audit-dispositions-check.sh" check-all --root "$root" --run-folder "$run_directory" --snapshot-dir "$snapshot_directory" 2>&1 </dev/null) || check_exit_status=$?
  [ "$check_exit_status" -eq 0 ] && return 0
  [ -n "$dispositions_output" ] || dispositions_output='(the check printed nothing)'
  dispositions_output=$(printf '%s\n' "$dispositions_output" | head -n 40)
  finish_deny "$(printf 'BLOCKED: audit dispositions on branch %s: the dispositions check failed (exit %s), so no audit dispatch proceeds until every dispositions file in %s passes. Nothing was recorded. A Critical or security finding is disposed fix (or file, when the branch did not author it), every non-fix disposition carries a reason, and a vetoed key is fix. Inside an audit-loop-unit: stop with stop_reason dispositions-check-failed and return. To see the violations again (read-only): bash %s/audit-dispositions-check.sh check-all --root %s --run-folder %s\n%s' \
    "$BRANCH_KEY" "$check_exit_status" "$run_directory" "$scripts" "$root" "$run_directory" "$dispositions_output")"
}

# close_state <pr>: move the state file (and its stamps) under .closed/.
close_state() {
  local closed_directory name
  closed_directory="$main/.gaia/local/protected/audit-loop/.closed"
  name="$(printf '%s' "$BRANCH_KEY" | tr '/' '+').${1:-none}.$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$closed_directory" || return 1
  mv -f "$file" "$closed_directory/$name.json" || return 1
  [ ! -d "${file%.json}.d" ] || mv -f "${file%.json}.d" "$closed_directory/$name.d" 2>/dev/null
  return 0
}

fresh_state() {
  jq -n -c --arg branch_key "$BRANCH_KEY" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: 1, key: ("branch:" + $branch_key), branch: $branch_key, pr: null, created_at: $now,
      history: {rounds: [], checkpoints: []}, allowance: {answers: []}}'
}

# gh_lookup: sets BRANCH_PR_NUMBER/BRANCH_PR_STATE from the branch's PR and LINKED_PR_STATE for the linked PR.
gh_lookup() {
  local pull_request_json linked_pr_number
  BRANCH_PR_NUMBER=''
  BRANCH_PR_STATE=''
  LINKED_PR_STATE=''
  RECORDED_PR_NUMBER=$(jq -r '.pr // empty' <<<"$state_before_lock")
  command -v gh >/dev/null 2>&1 || return 0
  if pull_request_json=$(cd "$root" 2>/dev/null && gh pr view --json number,state 2>/dev/null </dev/null); then
    BRANCH_PR_NUMBER=$(jq -r 'if (.number | type) == "number" then .number else empty end' <<<"$pull_request_json" 2>/dev/null) || BRANCH_PR_NUMBER=''
    BRANCH_PR_STATE=$(jq -r '.state // empty | strings' <<<"$pull_request_json" 2>/dev/null) || BRANCH_PR_STATE=''
  fi
  [ -n "$BRANCH_PR_NUMBER" ] || BRANCH_PR_STATE=''
  linked_pr_number="$RECORDED_PR_NUMBER"
  if [ -n "$linked_pr_number" ]; then
    if [ "$BRANCH_PR_NUMBER" = "$linked_pr_number" ]; then
      LINKED_PR_STATE="$BRANCH_PR_STATE"
    elif pull_request_json=$(cd "$root" 2>/dev/null && gh pr view "$linked_pr_number" --json state 2>/dev/null </dev/null); then
      LINKED_PR_STATE=$(jq -r '.state // empty | strings' <<<"$pull_request_json" 2>/dev/null) || LINKED_PR_STATE=''
    fi
  fi
}

# find_renamed <pr>: the one non-closed state file whose pr is <pr>.
find_renamed() {
  local candidate_file candidate_state hits=0 hit=''
  while IFS= read -r candidate_file; do
    [ "$candidate_file" != "$file" ] || continue
    candidate_state=$(gaia_loop_read_state "$candidate_file") || continue
    if [ "$(jq -r '.pr // empty' <<<"$candidate_state")" = "$1" ]; then
      hits=$((hits + 1))
      hit="$candidate_file"
    fi
  done < <(find "$main/.gaia/local/protected/audit-loop" \( -name .closed -prune \) -o -type f -name '*.json' -print 2>/dev/null)
  [ "$hits" -eq 1 ] || return 1
  printf '%s\n' "$hit"
}

# carry_over: once the new key's file is written, retire a renamed branch's old file.
carry_over() {
  [ -z "$old_file" ] || rm -f "$old_file"
  return 0
}

# adopt_renamed <old-state-json>: bring a renamed branch's round stamps and run
# folder under the new key, which is where the evaluator looks for them.
adopt_renamed() {
  local old_branch source_path destination_path
  old_branch=$(jq -r '.branch' <<<"$1")
  _gaia_loop_keyable "$old_branch" || return 0
  source_path="${old_file%.json}.d"
  destination_path="${file%.json}.d"
  [ ! -d "$source_path" ] || [ -e "$destination_path" ] || mv "$source_path" "$destination_path" 2>/dev/null
  source_path=$(gaia_loop_run_directory "$main" "$old_branch")
  destination_path=$(gaia_loop_run_directory "$main" "$BRANCH_KEY")
  [ ! -d "$source_path" ] || [ -e "$destination_path" ] || { mkdir -p "${destination_path%/*}" && mv "$source_path" "$destination_path" 2>/dev/null; }
  return 0
}

run_decision() {
  local libs_failed=0 lookup_exit_status dirty_exit_status state_under_lock used round_index snapshot decision now stamp_file slug closing NEXT_STATE current_pr_number old_file closed=0
  local verb trigger decision_third_field decision_fourth_field accept_is_eligible cap extra nonce question in_unit reading ask_tokens ask_percent config view recommended context_line
  local admitted_on start_round through_round
  HELD=''
  trap 'exit 143' TERM INT HUP
  trap '[ -z "$HELD" ] || gaia_loop_unlock "$HELD"' EXIT

  command -v git >/dev/null 2>&1 ||
    finish_deny 'BLOCKED: git is not on PATH, so the audit loop checkpoint cannot read the audited tree. Fail-loud, not fail-open: install git or fix PATH and retry.'
  scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" ||
    finish_deny 'BLOCKED: the audit loop checkpoint cannot locate its checkout. Fail-loud, not fail-open: restore the hook install.'
  scripts="$scripts/.gaia/scripts"
  # shellcheck source=/dev/null
  . "$scripts/audit-loop-state-lib.sh" 2>/dev/null || libs_failed=1
  # shellcheck source=/dev/null
  [ "$libs_failed" -eq 1 ] || . "$scripts/context-checkpoint-lib.sh" 2>/dev/null || libs_failed=1
  # shellcheck source=/dev/null
  [ "$libs_failed" -eq 1 ] || . "$scripts/audit-loop-eval.sh" 2>/dev/null || libs_failed=1
  [ "$libs_failed" -eq 1 ] || [ -f "$scripts/audit-dispositions-check.sh" ] || libs_failed=1
  [ "$libs_failed" -eq 0 ] ||
    finish_deny "BLOCKED: the audit loop checkpoint cannot load its libraries from $scripts. Fail-loud, not fail-open: restore audit-loop-state-lib.sh, context-checkpoint-lib.sh, audit-loop-eval.sh (with audit-loop-signals-lib.sh) and audit-dispositions-check.sh."
  # shellcheck source=lib/cross-repo-refusal.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/cross-repo-refusal.sh" 2>/dev/null || libs_failed=1
  if [ "$libs_failed" -ne 0 ] || ! type gaia_cross_repo_deny_reason >/dev/null 2>&1; then
    finish_deny 'BLOCKED: the audit loop checkpoint cannot load .claude/hooks/lib/cross-repo-refusal.sh, so it cannot tell whether this pull request comes from a fork. Fail-loud, not fail-open: restore the library and retry.'
  fi

  lookup_exit_status=0
  root=$(gaia_loop_resolve_audited_root "$payload") || lookup_exit_status=$?
  case "$lookup_exit_status" in
    0) ;;
    2) finish_deny "BLOCKED: the dispatch prompt names Working root: $root, which is not a git checkout, so the audit loop checkpoint will not charge this round to another tree. Name the checkout under audit as \`Working root: <absolute path>, ...\` and retry." ;;
    *)
      # shellcheck disable=SC2016 # the backticks are literal text in the message
      finish_deny 'BLOCKED: the audit loop checkpoint cannot resolve the audited checkout (no usable Working root: path in the dispatch prompt and no absolute cwd). Name the checkout in the prompt as `Working root: <absolute path>` and retry.' ;;
  esac
  lookup_exit_status=0
  BRANCH_KEY=$(gaia_loop_key "$root") || lookup_exit_status=$?
  case "$lookup_exit_status" in
    0) ;;
    4) finish_deny "BLOCKED: the audited checkout $root is on a detached HEAD, which has no branch key, so the audit loop cannot record a round. Check out the branch under audit and retry." ;;
    6) finish_deny 'BLOCKED: git is not on PATH, so the audit loop checkpoint cannot read the audited branch. Fail-loud, not fail-open: install git or fix PATH and retry.' ;;
    *) finish_deny "BLOCKED: the branch checked out at $root cannot be keyed for the audit loop (its normalized name must match [A-Za-z0-9._/-], at most 128 characters, with no .., no //, and no leading or trailing /). Rename the branch and retry." ;;
  esac
  main=$(gaia_resolve_main_root "$root" 2>/dev/null) ||
    finish_deny "BLOCKED: the audit loop checkpoint cannot resolve the main checkout of $root. Fail-loud, not fail-open: check the worktree layout and retry."
  tree=$(_gaia_loop_git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null) || tree=''
  commit=$(_gaia_loop_git -C "$root" rev-parse HEAD 2>/dev/null) || commit=''
  if ! gaia_loop_is_oid "$tree" || ! gaia_loop_is_oid "$commit"; then
    finish_deny "BLOCKED: the audit loop checkpoint cannot read HEAD of $root. Fail-loud, not fail-open: check the checkout and retry."
  fi
  file=$(gaia_loop_state_file "$main" "$BRANCH_KEY")
  snapshot_directory="${file%.json}.d"
  run_directory=$(gaia_loop_run_directory "$main" "$BRANCH_KEY")

  lookup_exit_status=0
  state_before_lock=$(gaia_loop_read_state "$file") || lookup_exit_status=$?
  case "$lookup_exit_status" in
    0) ;;
    1) state_before_lock='' ;;
    5) finish_deny "$(corrupt_message "$file")" ;;
    *) finish_deny 'BLOCKED: the audit loop state could not be read because jq is unavailable. Fail-loud, not fail-open: install jq and retry.' ;;
  esac

  # Same wave: a parallel sibling, or the one hardened re-dispatch of a no-op'd
  # member. Neither burns a round, and neither needs the prechecks below; the
  # join still takes the lock for the dispositions check.
  prechecked=0
  round_index=''
  if [ "$kind" = member ] && [ -n "$state_before_lock" ]; then
    round_index=$(tree_index "$state_before_lock")
  fi

  if [ -z "$round_index" ]; then
    prechecked=1
    # A new tree on a dirty audited checkout would audit work the round's
    # commit does not contain. A unit on a branch with history commits its
    # own rounds, and its member dispatches meet this check.
    if [ "$kind" = member ] || [ -z "$state_before_lock" ]; then
      dirty_exit_status=0
      _gaia_loop_git -C "$root" diff --quiet HEAD -- 2>/dev/null || dirty_exit_status=$?
      case "$dirty_exit_status" in
        0) ;;
        1) finish_deny "BLOCKED: the audited checkout $root has uncommitted tracked changes (modified or staged), so a new audit round on it would audit work that is not in the round's commit. Commit the round first, then dispatch the next one." ;;
        *) finish_deny "BLOCKED: the audit loop checkpoint could not check $root for uncommitted changes. Fail-loud, not fail-open: check the checkout and retry." ;;
      esac
    fi
    # Asked from the audited checkout, whose current branch is the pull
    # request in question.
    if fork_reason=$(gaia_cross_repo_deny_reason '' "$root" \
      'BLOCKED: ' \
      "BLOCKED: the audit loop checkpoint cannot tell whether the pull request for $root" \
      'so it refuses the dispatch rather than audit one. Check gh (gh auth status, the network) and retry.'); then
      finish_deny "$fork_reason"
    fi
    gh_lookup
  fi

  gaia_loop_lock "$file" "$lock_deadline" ||
    finish_deny "BLOCKED: the audit loop checkpoint could not take the state lock for branch $BRANCH_KEY before its deadline. Fail-loud, not fail-open: another dispatch holds ${file}.lock; retry the dispatch."
  HELD="$file"

  lookup_exit_status=0
  state_under_lock=$(gaia_loop_read_state "$file") || lookup_exit_status=$?
  case "$lookup_exit_status" in
    0) ;;
    1) state_under_lock='' ;;
    5) finish_deny "$(corrupt_message "$file")" ;;
    *) finish_deny 'BLOCKED: the audit loop state could not be read because jq is unavailable. Fail-loud, not fail-open: install jq and retry.' ;;
  esac

  # Every unit and member dispatch, a join included: a zero-fix round leaves
  # the tree unmoved, so its re-dispatch is a join and would otherwise skip
  # the check. Under the lock because a pass writes snapshots.
  check_dispositions

  # Re-check the wave under the lock: a parallel member may have recorded it
  # while this call waited.
  if [ "$kind" = member ] && [ -n "$state_under_lock" ]; then
    round_index=$(tree_index "$state_under_lock")
    if [ -n "$round_index" ]; then
      NEXT_STATE=$(add_member "$state_under_lock" "$round_index") || finish_deny 'BLOCKED: the audit loop checkpoint could not record this member. Fail-loud, not fail-open: retry the dispatch.'
      [ "$NEXT_STATE" = "$(jq -c . <<<"$state_under_lock")" ] ||
        gaia_loop_write_state "$file" "$NEXT_STATE" ||
        finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
      finish_allow
    fi
  fi
  [ "$prechecked" -eq 1 ] ||
    finish_deny 'BLOCKED: the audit loop state changed while this dispatch was being recorded. Retry the dispatch.'

  # --- PR link, closure and rename (one gh lookup, taken before the lock) ---
  old_file=''
  if [ -n "$state_under_lock" ]; then
    WORKING_STATE="$state_under_lock"
    current_pr_number=$(jq -r '.pr // empty' <<<"$WORKING_STATE")
    if [ -n "$current_pr_number" ] && [ "$current_pr_number" = "$RECORDED_PR_NUMBER" ]; then
      case "$LINKED_PR_STATE" in
        MERGED | CLOSED) closed=1 ;;
      esac
      if [ "$closed" -eq 0 ] && [ -n "$BRANCH_PR_NUMBER" ] && [ "$BRANCH_PR_NUMBER" != "$current_pr_number" ] && [ "$BRANCH_PR_STATE" = OPEN ]; then closed=1; fi
      if [ "$closed" -eq 1 ]; then
        close_state "$current_pr_number" ||
          finish_deny "BLOCKED: the audit loop checkpoint could not move the closed state of pull request $current_pr_number aside. Fail-loud, not fail-open: check $file and retry."
        WORKING_STATE=$(fresh_state)
        state_under_lock=''
        current_pr_number=''
      fi
    fi
    if [ -z "$current_pr_number" ] && [ -n "$BRANCH_PR_NUMBER" ] && [ "$BRANCH_PR_STATE" = OPEN ]; then
      WORKING_STATE=$(jq -c --argjson n "$BRANCH_PR_NUMBER" '.pr = $n' <<<"$WORKING_STATE")
    fi
  else
    WORKING_STATE=$(fresh_state)
    if [ -n "$BRANCH_PR_NUMBER" ] && [ "$BRANCH_PR_STATE" = OPEN ]; then
      if old_file=$(find_renamed "$BRANCH_PR_NUMBER"); then
        WORKING_STATE=$(gaia_loop_read_state "$old_file") ||
          finish_deny "BLOCKED: the audit loop checkpoint could not carry the history of pull request $BRANCH_PR_NUMBER over to branch $BRANCH_KEY. Fail-loud, not fail-open: check $old_file and retry."
        adopt_renamed "$WORKING_STATE"
        WORKING_STATE=$(jq -c --arg branch_key "$BRANCH_KEY" '.key = ("branch:" + $branch_key) | .branch = $branch_key' <<<"$WORKING_STATE")
      else
        old_file=''
        WORKING_STATE=$(jq -c --argjson n "$BRANCH_PR_NUMBER" '.pr = $n' <<<"$WORKING_STATE")
      fi
    fi
  fi

  # Frozen at the first unit or round-1 dispatch, and on first sight of a
  # legacy file that predates either field.
  if [ "$(jq -r '.history.knobs | type' <<<"$WORKING_STATE")" != object ]; then
    WORKING_STATE=$(jq -c --argjson knobs "$(gaia_loop_knobs_initial)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.history.knobs = $knobs | .created_at = $now' <<<"$WORKING_STATE") ||
      finish_deny 'BLOCKED: the audit loop checkpoint could not freeze its knobs. Fail-loud, not fail-open: retry the dispatch.'
  fi
  if [ "$(jq -r '.history.context_config | type' <<<"$WORKING_STATE")" != object ]; then
    config=$(gaia_loop_context_config_initial "$main") ||
      finish_deny 'BLOCKED: the audit loop checkpoint could not freeze its context line config. Fail-loud, not fail-open: retry the dispatch.'
    WORKING_STATE=$(jq -c --argjson c "$config" '.history.context_config = $c' <<<"$WORKING_STATE") ||
      finish_deny 'BLOCKED: the audit loop checkpoint could not freeze its context line config. Fail-loud, not fail-open: retry the dispatch.'
  fi

  used=$(jq -r '.history.rounds | length' <<<"$WORKING_STATE")
  if [ "$used" -eq 0 ]; then
    snapshot=null
  else
    snapshot=$(jq -c --argjson i "$((used - 1))" '.history.rounds[$i].snapshot' <<<"$WORKING_STATE")
    if [ "$snapshot" = null ]; then
      snapshot=$(gaia_loop_evaluate_round "$main" "$WORKING_STATE" "$used") ||
        finish_deny "BLOCKED: the audit loop checkpoint could not evaluate round $used on branch $BRANCH_KEY. Fail-loud, not fail-open: run \`bash $scripts/audit-loop-eval.sh eval --root $root\` to see why."
      WORKING_STATE=$(jq -c --argjson round_index "$((used - 1))" --argjson snapshot "$snapshot" '.history.rounds[$round_index].snapshot = $snapshot' <<<"$WORKING_STATE")
    fi
  fi

  config=$(gaia_loop_context_config_effective "$main" "$WORKING_STATE") ||
    finish_deny 'BLOCKED: the audit loop checkpoint could not compute its context line config. Fail-loud, not fail-open: retry the dispatch.'
  read -r ask_tokens ask_percent <<<"$config"
  reading=$(gaia_context_read "$main" "$session" "$(date +%s)")
  [ -n "$reading" ] || reading=unparseable

  in_unit=false
  if [ "$kind" = member ] && [ -n "$caller_id" ] && [ "$caller_type" = audit-loop-unit ]; then
    in_unit=true
  fi
  view="$WORKING_STATE"
  [ "$in_unit" = true ] || view=$(answer_view "$WORKING_STATE") ||
    finish_deny 'BLOCKED: the audit loop checkpoint could not compute its decision. Fail-loud, not fail-open: retry the dispatch.'
  if [ "$kind" = unit ]; then
    decision=$(gaia_loop_decide_unit "$view" "$snapshot" "$reading" "$ask_tokens" "$ask_percent")
  else
    decision=$(gaia_loop_decide_member "$view" "$snapshot" "$in_unit" "$reading" "$ask_tokens" "$ask_percent")
  fi || finish_deny 'BLOCKED: the audit loop checkpoint could not compute its decision. Fail-loud, not fail-open: retry the dispatch.'
  # A deny reads `deny <trigger> <accept_eligible> <cap>`; a unit allow reads
  # `allow <admitted_on> <start_round> <through_round>`.
  read -r verb trigger decision_third_field decision_fourth_field extra <<<"$decision"
  [ -z "$extra" ] ||
    finish_deny 'BLOCKED: the audit loop checkpoint got an unreadable decision. Fail-loud, not fail-open: retry the dispatch.'
  case "$verb" in
    allow) ;;
    deny)
      accept_is_eligible="$decision_third_field"
      cap="$decision_fourth_field"
      case "$accept_is_eligible $cap" in
        "true true" | "true false" | "false true" | "false false") ;;
        *) finish_deny 'BLOCKED: the audit loop checkpoint got an unreadable decision. Fail-loud, not fail-open: retry the dispatch.' ;;
      esac
      if [ "$trigger" = window ]; then
        [ "$WORKING_STATE" = "$state_under_lock" ] ||
          gaia_loop_write_state "$file" "$WORKING_STATE" ||
          finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
        carry_over
        finish_deny "$(window_message "$WORKING_STATE" "$used")"
      fi
      nonce=$(gaia_loop_new_nonce) ||
        finish_deny 'BLOCKED: the audit loop checkpoint could not draw a checkpoint nonce. Fail-loud, not fail-open: retry the dispatch.'
      recommended=$(gaia_loop_recommended "$trigger" "$snapshot") || recommended=''
      context_line=''
      if [[ $reading =~ ^fresh\ [0-9]+\ ([0-9]+)$ ]]; then
        context_line=$(gaia_context_line "${BASH_REMATCH[1]}" "$ask_tokens" "$ask_percent") || context_line=''
      fi
      question=$(gaia_loop_pinned_question "$BRANCH_KEY" "$nonce" "$used" "$GAIA_CONTEXT_UNIT_ROUNDS" "$accept_is_eligible" "$cap" "$trigger" "$reading" "$recommended" "$context_line") && [ -n "$question" ] ||
        finish_deny "BLOCKED: the audit loop checkpoint could not build its pinned question (trigger $trigger). Fail-loud, not fail-open: retry the dispatch."
      # Every checkpoint deny appends a new checkpoint; the latest is the one
      # pending, so this supersedes any earlier one, legacy ones included.
      WORKING_STATE=$(jq -c --argjson rounds_used "$used" --arg why "$trigger" --arg session_id "$session" --arg r "$root" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg nonce "$nonce" --argjson accept_is_eligible "$accept_is_eligible" --argjson pinned_question "$question" \
        '.history.checkpoints += [{index: ((.history.checkpoints | length) + 1), at_round: $rounds_used, reason: $why,
          recorded_at: $now, session_id: $session_id, audited_root: $r, nonce: $nonce, trigger: $why,
          accept_eligible: $accept_is_eligible, question: $pinned_question}]' <<<"$WORKING_STATE") ||
        finish_deny 'BLOCKED: the audit loop checkpoint could not build the checkpoint record. Fail-loud, not fail-open: retry the dispatch.'
      gaia_loop_write_state "$file" "$WORKING_STATE" ||
        finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
      carry_over
      finish_deny "$(checkpoint_message "$WORKING_STATE" "$used" "$trigger" "$question")"
      ;;
    *) finish_deny 'BLOCKED: the audit loop checkpoint got an unreadable decision. Fail-loud, not fail-open: retry the dispatch.' ;;
  esac

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$kind" = unit ]; then
    admitted_on="$trigger"
    start_round="$decision_third_field"
    through_round="$decision_fourth_field"
    case "$admitted_on" in context | grant | accept | fallback) ;; *) admitted_on='' ;; esac
    if [ -z "$admitted_on" ] || ! gaia_loop_is_uint "$start_round" || ! gaia_loop_is_uint "$through_round" ||
      [ "$start_round" -ne $((used + 1)) ] || [ "$through_round" -lt "$start_round" ]; then
      finish_deny 'BLOCKED: the audit loop checkpoint got an unreadable decision. Fail-loud, not fail-open: retry the dispatch.'
    fi
    NEXT_STATE=$(jq -c --arg admitted_on_trigger "$admitted_on" --argjson start_round "$start_round" --argjson through_round "$through_round" --argjson unit_rounds "$GAIA_CONTEXT_UNIT_ROUNDS" \
      --arg now "$now" --arg session_id "$session" \
      '.history.units = ((.history.units // []) + [{unit: (((.history.units // []) | length) + 1),
        start_round: $start_round, k: $unit_rounds, through_round: $through_round, admitted_on: $admitted_on_trigger,
        after_checkpoint: (.history.checkpoints | length), recorded_at: $now, session_id: $session_id}])' <<<"$WORKING_STATE") ||
      finish_deny 'BLOCKED: the audit loop checkpoint could not build the unit record. Fail-loud, not fail-open: retry the dispatch.'
    gaia_loop_write_state "$file" "$NEXT_STATE" ||
      finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
    carry_over
    finish_allow
  fi

  # Member allow: record round used + 1.
  slug=$(gaia_branch_slug "$root") ||
    finish_deny "BLOCKED: the audit loop checkpoint cannot derive the findings key of $root. Fail-loud, not fail-open: check the checkout and retry."
  closing=$(gaia_loop_next_closing "$WORKING_STATE")
  stamp_file=$(gaia_loop_stamp_file "$main" "$BRANCH_KEY" "$((used + 1))")
  { mkdir -p "${stamp_file%/*}" && : >"$stamp_file"; } ||
    finish_deny "BLOCKED: the audit loop checkpoint could not write the round stamp $stamp_file. Fail-loud, not fail-open: check the directory and retry."
  NEXT_STATE=$(jq -c --arg tree "$tree" --arg commit "$commit" --arg slug "$slug" --arg now "$now" --arg member_name "$member" \
    --argjson round_number "$((used + 1))" --argjson closing_flag "$closing" \
    '.history.rounds += [{round: $round_number, tree: $tree, commit: $commit, raw_branch_slug: $slug, dispatched_at: $now,
      members: [$member_name], closing: $closing_flag, snapshot: null}]' <<<"$WORKING_STATE") ||
    finish_deny 'BLOCKED: the audit loop checkpoint could not build the round record. Fail-loud, not fail-open: retry the dispatch.'
  gaia_loop_write_state "$file" "$NEXT_STATE" ||
    finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
  carry_over
  finish_allow
}

# Each background job gets its own process group so the deadline kill reaches
# whatever it spawned. Bash can lose the race to place a fast child in its
# group and says so on stderr ("child setpgid"), which would corrupt the
# answer, so the launch runs with stderr closed; cleanup falls back to
# signalling the child and its direct children when the group kill misses.
{
  set -m
  run_decision </dev/null >/dev/null 2>"$work/err" &
  child_pid=$!
  (
    sleep "$deadline"
    kill -TERM "$hook_pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  set +m
} 2>/dev/null

# The decision is complete only when `verdict` exists, whatever wait returns.
{ wait "$child_pid"; } 2>/dev/null
child_exit_status=$?
child_pid=''

verdict=''
[ ! -f "$work/verdict" ] || verdict=$(cat "$work/verdict" 2>/dev/null)
case "$verdict" in
  allow) exit 0 ;;
  deny*) deny "${verdict#deny$'\n'}" ;;
  *) deny "BLOCKED: the audit loop checkpoint ended without a decision (status $child_exit_status). Fail-loud, not fail-open: retry the dispatch." ;;
esac
