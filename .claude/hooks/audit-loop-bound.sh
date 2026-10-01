#!/usr/bin/env bash
# PreToolUse hook on Agent|Task: bound the pre-merge audit loop per BRANCH.
# At each Code Audit Team dispatch on a HEAD tree not yet audited on the
# branch, it evaluates the previous round, records that round's snapshot,
# and denies when the branch's allowance is reached or the previous round's
# verdict is `stalled` or `enriching` with no human answer since. The
# numbers, formulas and defaults live in .gaia/scripts/audit-loop-eval.sh's
# header; the state file shape and its writers live in
# .gaia/scripts/audit-loop-state-lib.sh's header. This file restates neither.
#
# WHY A HOOK AND NOT PROSE. The audit loop's fix-and-re-audit cycle has no
# stop of its own: every round's fixes buy the next dispatch, so an
# unattended run spends without bound, and the judgement "is another round
# worth it" gets made mid-loop by the session least able to make it. Prose
# cannot hold a boundary an agent has a standing reason to cross. The only
# way past a checkpoint is a line a human types (see audit-loop-grant.sh).
#
# WHAT IS BOUNDED. The branch, not the session. The history lives in one
# state file under the main checkout's local state directory, keyed by the
# normalized branch name, so every session, sub-agent, fork and linked
# worktree on the branch reads and extends one record. session_id is NOT part
# of the key. /clear, compaction, a new session, a fork and a sub-agent leave
# history and allowance untouched, and no SessionStart registration exists.
# session_id is recorded only on a checkpoint, so the grant hook can find the
# checkpoint a session hit when its working directory is on another branch.
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
# is always allowed, at a checkpoint too.
#
# STATED FAILURE MODES, honestly:
# - A dispatch cancelled at the permission prompt has already counted: the
#   count is taken at PreToolUse, and the round is recorded `unknown` when no
#   findings arrive. Refunding on absent evidence would make deleting a
#   sidecar a way to buy rounds. The recovery is a grant line a human types.
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
# for a call that names a member) or git, a library that will not load, an
# audited checkout that cannot be resolved, a detached HEAD or an unkeyable
# branch name, an unreadable HEAD, a dirty audited checkout on a new tree
# (commit the round first), a lock that could not be taken, an evaluation or
# state write that failed, and an internal deadline that passed. A harness
# that never delivers this event leaves the guard inert, and "inert" and
# "working" are indistinguishable from this file alone; the registration is
# checked by the registration suite, not here.
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
# SCOPE: only tool_input.subagent_type matching code-audit-* counts, checked
# before any git or filesystem work because the overwhelming majority of
# dispatches are not members. The roster does not pin the subagent_type a
# member's own internal fan-out carries; the filter does not need that pin: a
# nested dispatch shares its wave's HEAD tree and is free whatever it is
# named. A payload's top-level agent_type names the agent MAKING the call, the
# opposite question, and folding it in would count a member's own nested
# dispatches as top-level rounds, so only tool_input.subagent_type is read.
#
# AUDITED ROOT. The dispatch prompt's `Working root:` path wins over the
# payload cwd (the orchestrator audits a linked worktree from the main
# checkout), and the state file is resolved to the main checkout through
# gaia_resolve_main_root in main-root-lib.sh, so a worktree and the main
# checkout name one record.
#
# FORK REFUSAL. A dispatch that would record a new round is denied when the
# audited checkout's pull request is a fork (cross-repository), and also when
# gh cannot say whether it is one; a branch with no pull request yet proceeds.
# The check and the message live in .claude/hooks/lib/cross-repo-refusal.sh.
# A dispatch joining an already-recorded round skips it: that round was
# recorded past this same check. This is a refusal, not a defense: on a fork
# head this file is itself the fork's copy, and only the pre-checkout guard
# acts before that.
set -uo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: audit-loop-bound.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the audit loop checkpoint' "$payload" tool_input 'code-audit-'

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
# tool_input.subagent_type (see SCOPE above).
fields=$(jq -r '[(.tool_name // "" | if type == "string" then . else "" end),
  ((.tool_input | objects | .subagent_type) // "" | if type == "string" then . else "" end),
  (.session_id // "" | if type == "string" then . else "" end)] | join("\u001f")' <<<"$payload" 2>/dev/null) ||
  deny 'BLOCKED: the audit loop checkpoint could not parse this tool call payload. Fail-loud, not fail-open: retry the dispatch.'
IFS=$'\037' read -r tool member session <<<"$fields"
case "$tool" in
  Agent | Task) ;;
  *) exit 0 ;;
esac
case "$member" in
  code-audit-*) ;;
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

# corrupt_msg <file>: why the state file reads as corrupt, plus the repair.
corrupt_msg() {
  local f="$1" why stamp schema
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if ! jq -e . "$f" >/dev/null 2>&1; then
    why='is invalid JSON'
  else
    schema=$(jq -r '.schema // "missing"' "$f" 2>/dev/null) || schema='unreadable'
    if [ "$schema" != 1 ]; then
      why="has schema $schema; this hook reads schema 1 only"
    else
      why='fails the schema 1 shape check (a required key is missing or malformed)'
    fi
  fi
  printf 'BLOCKED: the audit loop state file for branch %s %s: %s\nThis hook never rewrites or resets it, and Claude must not either. From a terminal outside Claude Code, move it aside: mv '"'"'%s'"'"' '"'"'%s.corrupt-%s'"'"'; the branch then starts again at round 1. Do not retry the dispatch until a human has done that.' \
    "$B" "$why" "$f" "$f" "$f" "$stamp"
}

# checkpoint_msg <state-json> <used> <reason>
checkpoint_msg() {
  local s="$1" used="$2" reason="$3" grant_n
  grant_n=$(jq -r '.history.knobs.grant_rounds // 3' <<<"$s")
  printf 'BLOCKED: audit checkpoint on branch %s after %s rounds (%s).\n' "$B" "$used" "$reason"
  jq -r '.history.rounds | to_entries[]
    | "  round \(.key + 1): A=\(.value.snapshot.A // "n/a") verdict=\(.value.snapshot.verdict // "unevaluated")"' <<<"$s"
  printf '\nThis stops the loop for a human decision; it is not a defect and not a merge blocker. The human types one of these lines as the whole prompt, in this same session (the grant hook resolves the checkpoint by this session id when the session working directory is on another branch):\n'
  printf 'Grant (type exactly as the whole prompt): %s\n' "$(gaia_loop_grant_line "$grant_n")"
  printf 'Accept (type exactly as the whole prompt): %s\n' "$(gaia_loop_accept_line)"
  printf '\nClaude never writes the state file and never types or simulates these lines. A dispatch on an already-audited tree is still allowed.\n'
  # shellcheck disable=SC2016 # the backticks are literal text in the message
  printf 'Interactive run: ask the human the checkpoint question from `bash %s/audit-loop-eval.sh brief --root %s`. Unattended run (/gaia-debt drain or CI): stop, push the round'"'"'s fix, leave the PR open and report this message.\n' "$scripts" "$root"
  printf 'State file: %s\n' "$file"
}

# set_member <state-json> <index> : append $member to round <index> when absent.
add_member() {
  jq -c --argjson i "$2" --arg m "$member" \
    '.history.rounds[$i].members |= (if index($m) then . else . + [$m] end)' <<<"$1"
}

# tree_index <state-json>: the index of the round recorded for $tree, or empty.
tree_index() {
  jq -r --arg t "$tree" \
    '[.history.rounds | to_entries[] | select(.value.tree == $t) | .key] | first // empty' <<<"$1"
}

# close_state <pr>: move the state file (and its stamps) under .closed/.
close_state() {
  local closed_dir name
  closed_dir="$main/.gaia/local/audit-loop/.closed"
  name="$(printf '%s' "$B" | tr '/' '+').${1:-none}.$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$closed_dir" || return 1
  mv -f "$file" "$closed_dir/$name.json" || return 1
  [ ! -d "${file%.json}.d" ] || mv -f "${file%.json}.d" "$closed_dir/$name.d" 2>/dev/null
  return 0
}

fresh_state() {
  jq -n -c --arg b "$B" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: 1, key: ("branch:" + $b), branch: $b, pr: null, created_at: $now,
      history: {rounds: [], checkpoints: []}, allowance: {answers: []}}'
}

# gh_lookup: sets BN/BSTATE from the branch's PR and MSTATE for the linked PR.
gh_lookup() {
  local out m
  BN=''
  BSTATE=''
  MSTATE=''
  PRE_M=$(jq -r '.pr // empty' <<<"$state0")
  command -v gh >/dev/null 2>&1 || return 0
  if out=$(cd "$root" 2>/dev/null && gh pr view --json number,state 2>/dev/null </dev/null); then
    BN=$(jq -r 'if (.number | type) == "number" then .number else empty end' <<<"$out" 2>/dev/null) || BN=''
    BSTATE=$(jq -r '.state // empty | strings' <<<"$out" 2>/dev/null) || BSTATE=''
  fi
  [ -n "$BN" ] || BSTATE=''
  m="$PRE_M"
  if [ -n "$m" ]; then
    if [ "$BN" = "$m" ]; then
      MSTATE="$BSTATE"
    elif out=$(cd "$root" 2>/dev/null && gh pr view "$m" --json state 2>/dev/null </dev/null); then
      MSTATE=$(jq -r '.state // empty | strings' <<<"$out" 2>/dev/null) || MSTATE=''
    fi
  fi
}

# find_renamed <pr>: the one non-closed state file whose pr is <pr>.
find_renamed() {
  local f s hits=0 hit=''
  while IFS= read -r f; do
    [ "$f" != "$file" ] || continue
    s=$(gaia_loop_read_state "$f") || continue
    if [ "$(jq -r '.pr // empty' <<<"$s")" = "$1" ]; then
      hits=$((hits + 1))
      hit="$f"
    fi
  done < <(find "$main/.gaia/local/audit-loop" \( -name .closed -prune \) -o -type f -name '*.json' -print 2>/dev/null)
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
  local old_b src dst
  old_b=$(jq -r '.branch' <<<"$1")
  _gaia_loop_keyable "$old_b" || return 0
  src="${old_file%.json}.d"
  dst="${file%.json}.d"
  [ ! -d "$src" ] || [ -e "$dst" ] || mv "$src" "$dst" 2>/dev/null
  src=$(gaia_loop_run_dir "$main" "$old_b")
  dst=$(gaia_loop_run_dir "$main" "$B")
  [ ! -d "$src" ] || [ -e "$dst" ] || { mkdir -p "${dst%/*}" && mv "$src" "$dst" 2>/dev/null; }
  return 0
}

run_decision() {
  local libs_failed=0 scripts rc dirty_rc s0 used idx snap dec reason now stampf slug closing S2 cur_pr old_file closed=0
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
  [ "$libs_failed" -eq 1 ] || . "$scripts/audit-loop-eval.sh" 2>/dev/null || libs_failed=1
  [ "$libs_failed" -eq 0 ] ||
    finish_deny "BLOCKED: the audit loop checkpoint cannot load its libraries from $scripts. Fail-loud, not fail-open: restore audit-loop-state-lib.sh and audit-loop-eval.sh."
  # shellcheck source=lib/cross-repo-refusal.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/cross-repo-refusal.sh" 2>/dev/null || libs_failed=1
  if [ "$libs_failed" -ne 0 ] || ! type gaia_pr_is_cross_repository >/dev/null 2>&1; then
    finish_deny 'BLOCKED: the audit loop checkpoint cannot load .claude/hooks/lib/cross-repo-refusal.sh, so it cannot tell whether this pull request comes from a fork. Fail-loud, not fail-open: restore the library and retry.'
  fi

  if ! root=$(gaia_loop_resolve_audited_root "$payload"); then
    # shellcheck disable=SC2016 # the backticks are literal text in the message
    finish_deny 'BLOCKED: the audit loop checkpoint cannot resolve the audited checkout (no usable Working root: path in the dispatch prompt and no absolute cwd). Name the checkout in the prompt as `Working root: <absolute path>` and retry.'
  fi
  rc=0
  B=$(gaia_loop_key "$root") || rc=$?
  case "$rc" in
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
  file=$(gaia_loop_state_file "$main" "$B")

  rc=0
  state0=$(gaia_loop_read_state "$file") || rc=$?
  case "$rc" in
    0) ;;
    1) state0='' ;;
    5) finish_deny "$(corrupt_msg "$file")" ;;
    *) finish_deny 'BLOCKED: the audit loop state could not be read because jq is unavailable. Fail-loud, not fail-open: install jq and retry.' ;;
  esac

  # Same wave: a parallel sibling, or the one hardened re-dispatch of a no-op'd
  # member. Neither burns a round.
  prechecked=0
  if [ -n "$state0" ]; then
    idx=$(tree_index "$state0")
    if [ -n "$idx" ]; then
      [ "$(jq -r --argjson i "$idx" --arg m "$member" '.history.rounds[$i].members | index($m) | if . == null then "no" else "yes" end' <<<"$state0")" = no ] || finish_allow
    fi
  fi

  if [ -z "${idx:-}" ]; then
    prechecked=1
    # A new tree on a dirty audited checkout would audit work the round's
    # commit does not contain.
    dirty_rc=0
    _gaia_loop_git -C "$root" diff --quiet HEAD -- 2>/dev/null || dirty_rc=$?
    case "$dirty_rc" in
      0) ;;
      1) finish_deny "BLOCKED: the audited checkout $root has uncommitted tracked changes (modified or staged), so a new audit round on it would audit work that is not in the round's commit. Commit the round first, then dispatch the next one." ;;
      *) finish_deny "BLOCKED: the audit loop checkpoint could not check $root for uncommitted changes. Fail-loud, not fail-open: check the checkout and retry." ;;
    esac
    # Asked from the audited checkout, whose current branch is the pull
    # request in question. The subshell keeps the cd from leaking, so it
    # prints the exit status and the failure wording back for this shell.
    fork_answer=$(cd "$root" 2>/dev/null || exit 2
      fork_status=0
      gaia_pr_is_cross_repository '' || fork_status=$?
      printf '%s\n%s' "$fork_status" "$GAIA_CROSS_REPO_GH_ERROR") || fork_answer=2
    case "${fork_answer%%$'\n'*}" in
      1) ;;
      0) finish_deny "BLOCKED: $GAIA_CROSS_REPO_REFUSAL_MESSAGE" ;;
      *)
        fork_reason=''
        case "$fork_answer" in *$'\n'*) fork_reason="${fork_answer#*$'\n'}" ;; esac
        finish_deny "BLOCKED: the audit loop checkpoint cannot tell whether the pull request for $root comes from a fork (${fork_reason:-gh could not answer}), so it refuses the dispatch rather than audit one. Check gh (gh auth status, the network) and retry. If the pull request is a fork: $GAIA_CROSS_REPO_REFUSAL_MESSAGE"
        ;;
    esac
    gh_lookup
  fi

  gaia_loop_lock "$file" "$lock_deadline" ||
    finish_deny "BLOCKED: the audit loop checkpoint could not take the state lock for branch $B before its deadline. Fail-loud, not fail-open: another dispatch holds ${file}.lock; retry the dispatch."
  HELD="$file"

  rc=0
  s0=$(gaia_loop_read_state "$file") || rc=$?
  case "$rc" in
    0) ;;
    1) s0='' ;;
    5) finish_deny "$(corrupt_msg "$file")" ;;
    *) finish_deny 'BLOCKED: the audit loop state could not be read because jq is unavailable. Fail-loud, not fail-open: install jq and retry.' ;;
  esac

  # Re-check the wave under the lock: a parallel member may have recorded it
  # while this call waited.
  if [ -n "$s0" ]; then
    idx=$(tree_index "$s0")
    if [ -n "$idx" ]; then
      S2=$(add_member "$s0" "$idx") || finish_deny 'BLOCKED: the audit loop checkpoint could not record this member. Fail-loud, not fail-open: retry the dispatch.'
      [ "$S2" = "$(jq -c . <<<"$s0")" ] ||
        gaia_loop_write_state "$file" "$S2" ||
        finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
      finish_allow
    fi
  fi
  [ "$prechecked" -eq 1 ] ||
    finish_deny 'BLOCKED: the audit loop state changed while this dispatch was being recorded. Retry the dispatch.'

  # --- PR link, closure and rename (one gh lookup, taken before the lock) ---
  old_file=''
  if [ -n "$s0" ]; then
    S="$s0"
    cur_pr=$(jq -r '.pr // empty' <<<"$S")
    if [ -n "$cur_pr" ] && [ "$cur_pr" = "$PRE_M" ]; then
      case "$MSTATE" in
        MERGED | CLOSED) closed=1 ;;
      esac
      if [ "$closed" -eq 0 ] && [ -n "$BN" ] && [ "$BN" != "$cur_pr" ] && [ "$BSTATE" = OPEN ]; then closed=1; fi
      if [ "$closed" -eq 1 ]; then
        close_state "$cur_pr" ||
          finish_deny "BLOCKED: the audit loop checkpoint could not move the closed state of pull request $cur_pr aside. Fail-loud, not fail-open: check $file and retry."
        S=$(fresh_state)
        s0=''
        cur_pr=''
      fi
    fi
    if [ -z "$cur_pr" ] && [ -n "$BN" ] && [ "$BSTATE" = OPEN ]; then
      S=$(jq -c --argjson n "$BN" '.pr = $n' <<<"$S")
    fi
  else
    S=$(fresh_state)
    if [ -n "$BN" ] && [ "$BSTATE" = OPEN ]; then
      if old_file=$(find_renamed "$BN"); then
        S=$(gaia_loop_read_state "$old_file") ||
          finish_deny "BLOCKED: the audit loop checkpoint could not carry the history of pull request $BN over to branch $B. Fail-loud, not fail-open: check $old_file and retry."
        adopt_renamed "$S"
        S=$(jq -c --arg b "$B" '.key = ("branch:" + $b) | .branch = $b' <<<"$S")
      else
        old_file=''
        S=$(jq -c --argjson n "$BN" '.pr = $n' <<<"$S")
      fi
    fi
  fi

  used=$(jq -r '.history.rounds | length' <<<"$S")
  if [ "$used" -eq 0 ]; then
    S=$(jq -c --argjson k "$(gaia_loop_knobs_initial)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.history.knobs = $k | .created_at = $now' <<<"$S") ||
      finish_deny 'BLOCKED: the audit loop checkpoint could not freeze its knobs. Fail-loud, not fail-open: retry the dispatch.'
    snap=null
  else
    snap=$(jq -c --argjson i "$((used - 1))" '.history.rounds[$i].snapshot' <<<"$S")
    if [ "$snap" = null ]; then
      snap=$(gaia_loop_eval_round "$main" "$S" "$used") ||
        finish_deny "BLOCKED: the audit loop checkpoint could not evaluate round $used on branch $B. Fail-loud, not fail-open: run \`bash $scripts/audit-loop-eval.sh eval --root $root\` to see why."
      S=$(jq -c --argjson i "$((used - 1))" --argjson s "$snap" '.history.rounds[$i].snapshot = $s' <<<"$S")
    fi
  fi

  dec=$(gaia_loop_decide "$S" "$snap") ||
    finish_deny 'BLOCKED: the audit loop checkpoint could not compute its decision. Fail-loud, not fail-open: retry the dispatch.'
  case "$dec" in
    allow) ;;
    "deny "*)
      reason="${dec#deny }"
      if [ -z "$(gaia_loop_pending_checkpoint "$S" | jq -r --argjson u "$used" 'select(.at_round == $u) | .index')" ]; then
        S=$(jq -c --argjson u "$used" --arg why "$reason" --arg sid "$session" --arg r "$root" \
          --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '.history.checkpoints += [{index: ((.history.checkpoints | length) + 1), at_round: $u, reason: $why,
            recorded_at: $now, session_id: $sid, audited_root: $r}]' <<<"$S")
      fi
      [ "$S" = "$s0" ] ||
        gaia_loop_write_state "$file" "$S" ||
        finish_deny "BLOCKED: the audit loop checkpoint could not write $file. Fail-loud, not fail-open: check the directory and retry."
      carry_over
      finish_deny "$(checkpoint_msg "$S" "$used" "$reason")"
      ;;
    *) finish_deny 'BLOCKED: the audit loop checkpoint got an unreadable decision. Fail-loud, not fail-open: retry the dispatch.' ;;
  esac

  # Allow: record round used + 1.
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  slug=$(gaia_branch_slug "$root") ||
    finish_deny "BLOCKED: the audit loop checkpoint cannot derive the findings key of $root. Fail-loud, not fail-open: check the checkout and retry."
  closing=$(gaia_loop_next_closing "$S")
  stampf=$(gaia_loop_stamp_file "$main" "$B" "$((used + 1))")
  { mkdir -p "${stampf%/*}" && : >"$stampf"; } ||
    finish_deny "BLOCKED: the audit loop checkpoint could not write the round stamp $stampf. Fail-loud, not fail-open: check the directory and retry."
  S2=$(jq -c --arg t "$tree" --arg c "$commit" --arg s "$slug" --arg now "$now" --arg m "$member" \
    --argjson n "$((used + 1))" --argjson cl "$closing" \
    '.history.rounds += [{round: $n, tree: $t, commit: $c, raw_branch_slug: $s, dispatched_at: $now,
      members: [$m], closing: $cl, snapshot: null}]' <<<"$S") ||
    finish_deny 'BLOCKED: the audit loop checkpoint could not build the round record. Fail-loud, not fail-open: retry the dispatch.'
  gaia_loop_write_state "$file" "$S2" ||
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
child_rc=$?
child_pid=''

verdict=''
[ ! -f "$work/verdict" ] || verdict=$(cat "$work/verdict" 2>/dev/null)
case "$verdict" in
  allow) exit 0 ;;
  deny*) deny "${verdict#deny$'\n'}" ;;
  *) deny "BLOCKED: the audit loop checkpoint ended without a decision (status $child_rc). Fail-loud, not fail-open: retry the dispatch." ;;
esac
