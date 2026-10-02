#!/usr/bin/env bash
# shellcheck shell=bash
#
# PostToolUse hook (matcher AskUserQuestion): record a human's selection of the
# question the bound hook pinned at an audit checkpoint.
#
# The bound hook stores the WHOLE checkpoint question (text, header, options,
# descriptions) in guarded state when it denies at a checkpoint. Claude authors
# none of it, so a selection of one of those options is the pinned text and
# nothing Claude chose. This hook is the only writer of `source: "ask"`
# answers; the typed `audit-grant <n>` and `audit-accept` lines stay the
# fallback (audit-loop-grant.sh). Both write only the state's `allowance`
# section, under the same lock.
#
# It records an answer only when ALL of these hold, checked in this order, and
# each decline is its own visible `systemMessage` saying nothing was recorded
# and naming the typed fallback (a silent decline reads as a recorded grant):
#
#   1. The payload has no `agent_id`: the call came from the main thread, not a
#      sub-agent.
#   2. The session is interactive (gaia_loop_session_is_interactive: the hook's
#      environment carries CLAUDE_CODE_ENTRYPOINT=cli and every transcript
#      `entrypoint` is `cli`).
#   3. `permission_mode` is in _GAIA_ASK_MODES below.
#   4. The branch resolves to exactly one pending checkpoint that carries a
#      pinned `question`: the branch of the payload cwd first, else the one
#      non-closed branch whose pending checkpoint was recorded by this same
#      session. Ambiguity records nothing. A checkpoint is answered once, so a
#      replay finds nothing pending.
#   5. The payload's `tool_input`, minus the `answers` and `annotations` keys
#      the harness adds once a human has answered, is JSON-equal to the pinned
#      question. Any other extra key, a changed word, a second question or
#      `multiSelect: true` is a mismatch.
#   6. The selected answer, `tool_response.answers[<pinned question text>]`, is
#      exactly one pinned option label. Free text typed into Other arrives in
#      the same map and never matches a label unless it spells one exactly.
#
# The pinned question marks its one recommended option with a trailing
# ` (Recommended)`. The selected label must still equal a stored label exactly;
# the kind is read from that label with the suffix stripped, and the recorded
# `option` keeps the label as selected.
#
# What each label records. `Continue audit in this session` and `Continue
# audit in a new session` record the same `{kind: "grant", n: k}` answer; k is
# GAIA_CTX_UNIT_ROUNDS from the shared lib, never a count read from a label.
# The new-session label also tells the main thread to print a fenced
# continuation prompt. `Accept the remainder`
# records `{kind: "accept"}`. `Stop and file the remainder` and `Type
# audit-accept instead` record nothing: the loop stays stopped and the message
# names the next step. Every recorded answer carries source, option, the pin's
# nonce, `at` and the payload `session_id`, beside `checkpoint`.
#
# Honest limits. The nonce binds an answer to one checkpoint; it does not prove
# who answered. That rests on the checks above (a main-thread, interactive,
# allowlisted-mode session) and on block-audit-loop-write.sh, which denies any
# Bash or Monitor command that executes this hook or audit-loop-grant.sh, so
# Claude cannot feed it a payload. Headless runs have no AskUserQuestion tool.
# A person typing a label's exact text into Other is a person answering.
#
# Never exit 2 and never block: PostToolUse cannot undo the question, and every
# decline exits 0 with a `systemMessage` (stdout JSON shows only on exit 0). A
# write failure is a visible decline. jq is checked inline rather than through
# lib/jq-availability.sh, whose missing-jq arm exits 2. Bash 3.2; never `cd`s
# outside the command substitution that locates the libraries.

set -u

# The `permission_mode` values under which AskUserQuestion waited for a human
# in a measured probe run of Claude Code 2.1.287.
# An unlisted or absent mode is a decline.
_GAIA_ASK_MODES=" default acceptEdits plan auto bypassPermissions "

# _ag_esc <text>: JSON string body, builtins only (works with jq absent).
_ag_esc() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/ }"
  s="${s//[[:cntrl:]]/ }"
  printf '%s' "$s"
}

# _ag_say <message> [claude-context]: the visible note, and optionally the same
# fact for Claude, as the PostToolUse JSON response.
_ag_say() {
  if [ -n "${2-}" ]; then
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
      "$(_ag_esc "$1")" "$(_ag_esc "$2")"
  else
    printf '{"systemMessage":"%s"}\n' "$(_ag_esc "$1")"
  fi
}

_AG_FALLBACK="Type audit-grant <n> or audit-accept as the whole prompt instead."

# _ag_decline <reason>: a visible decline that names the typed fallback.
_ag_decline() {
  _ag_say "Nothing was recorded from this AskUserQuestion: $1 $_AG_FALLBACK"
  exit 0
}

if [ "$#" -gt 0 ]; then
  printf 'audit-loop-ask-grant: runs only as a PostToolUse hook with a payload on stdin; nothing recorded\n' >&2
  exit 1
fi

payload=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' payload || true
fi
if [ -z "$payload" ]; then
  printf 'audit-loop-ask-grant: no PostToolUse payload on stdin; nothing recorded\n' >&2
  exit 1
fi

# Cheap exit before any jq or git call: the tool name must appear at all.
case "$payload" in
  *AskUserQuestion*) ;;
  *) exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  _ag_say "Nothing was recorded from this AskUserQuestion: jq is missing, so the answer cannot be read. Install jq. $_AG_FALLBACK"
  exit 0
fi

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // "" | strings' 2>/dev/null)" || tool_name=""
[ "$tool_name" = AskUserQuestion ] || exit 0

_ag_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _ag_hook_root=''
_ag_scripts="$_ag_hook_root/.gaia/scripts"
if [ -z "$_ag_hook_root" ] || [ ! -f "$_ag_scripts/audit-loop-state-lib.sh" ] || [ ! -f "$_ag_scripts/context-checkpoint-lib.sh" ]; then
  _ag_decline "the audit loop libraries were not found next to this hook."
fi
# shellcheck source=/dev/null
. "$_ag_scripts/main-root-lib.sh"
# shellcheck source=/dev/null
. "$_ag_scripts/audit-loop-state-lib.sh"
# shellcheck source=/dev/null
. "$_ag_scripts/context-checkpoint-lib.sh"

session_id="$(printf '%s' "$payload" | jq -r '.session_id // "" | strings' 2>/dev/null)" || session_id=""
cwd="$(printf '%s' "$payload" | jq -r '.cwd // "" | strings' 2>/dev/null)" || cwd=""
case "$cwd" in
  /*) ;;
  *) cwd="" ;;
esac
main=""
if [ -n "$cwd" ]; then
  main="$(gaia_resolve_main_root "$cwd" 2>/dev/null)" || main=""
fi
# No checkout, or no audit state anywhere: an AskUserQuestion unrelated to the
# audit loop, which is none of this hook's business.
[ -n "$main" ] || exit 0
statedir="$main/.gaia/local/audit-loop"
[ -d "$statedir" ] || exit 0

branch=""
branch="$(gaia_loop_key "$cwd" 2>/dev/null)" || branch=""

target=""
cand=""
rc=1
state=""
pending=""
have_state=0
if [ -n "$branch" ]; then
  cand="$(gaia_loop_state_file "$main" "$branch")"
  if [ -e "$cand" ]; then
    have_state=1
    state="$(gaia_loop_read_state "$cand" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      pending="$(gaia_loop_pending_checkpoint "$state")"
      [ -n "$pending" ] && target="$cand"
    fi
  fi
fi

matches=0
if [ -z "$target" ] && [ -n "$session_id" ]; then
  while IFS= read -r cand; do
    cstate="$(gaia_loop_read_state "$cand" 2>/dev/null)" || continue
    cpending="$(gaia_loop_pending_checkpoint "$cstate")"
    [ -n "$cpending" ] || continue
    csid="$(printf '%s' "$cpending" | jq -r '.session_id // "" | strings' 2>/dev/null)" || csid=""
    if [ "$csid" = "$session_id" ]; then
      matches=$((matches + 1))
      target="$cand"
    fi
  done < <(find "$statedir" -name .closed -prune -o -type f -name '*.json' -print 2>/dev/null)
  if [ "$matches" -gt 1 ]; then
    target=""
  fi
fi

# No state for this branch and no pending checkpoint of this session anywhere:
# nothing in the audit loop is waiting on this question.
if [ "$have_state" -eq 0 ] && [ "$matches" -eq 0 ]; then
  exit 0
fi

# 1. Main thread only.
if [ "$(printf '%s' "$payload" | jq -r 'has("agent_id")' 2>/dev/null)" != false ]; then
  _ag_decline "the call came from a sub-agent (the payload carries agent_id), and only the main thread's question is recorded."
fi

# 2. Interactive session.
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // "" | strings' 2>/dev/null)" || transcript=""
if ! gaia_loop_session_is_interactive "$transcript"; then
  _ag_decline "this session is not interactive (a person must answer in a Claude Code terminal session)."
fi

# 3. Permission mode.
mode="$(printf '%s' "$payload" | jq -r '.permission_mode // "" | strings' 2>/dev/null)" || mode=""
case "$mode" in
  '' | *[!A-Za-z]*) _ag_decline "the permission mode is absent or not one this hook measured." ;;
esac
case "$_GAIA_ASK_MODES" in
  *" $mode "*) ;;
  *) _ag_decline "the permission mode '$mode' is not one this hook measured." ;;
esac

# 4. A single pending checkpoint carrying a question.
if [ "$have_state" -eq 1 ] && [ "$rc" -eq 5 ] && [ -z "$target" ]; then
  _ag_decline "the audit state file $cand is corrupt and was left untouched."
fi
if [ -z "$target" ]; then
  _ag_decline "no audit checkpoint is pending on branch ${branch:-(none)} for this session, or it was already answered; answer in the session whose dispatch hit the checkpoint."
fi
if [ -z "$(printf '%s' "$(gaia_loop_read_state "$target" 2>/dev/null)" | jq -c '.history.checkpoints | last | .question // empty' 2>/dev/null)" ]; then
  _ag_decline "the pending checkpoint carries no pinned question to match."
fi

# _ag_check <state-json>: prints one of `ok <label> <nonce> <index>` or a
# `no <reason>` line for the payload against the pending checkpoint of
# <state-json>. Used before and again under the lock.
_ag_check() {
  local st="$1" pend pin qtext label nonce idx
  pend="$(gaia_loop_pending_checkpoint "$st")"
  if [ -z "$pend" ]; then
    printf 'no no audit checkpoint is pending on branch %s for this session, or it was already answered.\n' "${branch:-(none)}"
    return 0
  fi
  pin="$(printf '%s' "$pend" | jq -c '.question // empty' 2>/dev/null)"
  if [ -z "$pin" ]; then
    printf 'no the pending checkpoint carries no pinned question to match.\n'
    return 0
  fi
  if ! printf '%s' "$payload" | jq -e --argjson pin "$pin" '(.tool_input | type == "object") and (.tool_input | del(.answers, .annotations)) == $pin' >/dev/null 2>&1; then
    printf 'no the question asked is not the pinned checkpoint question (any difference in its text, header, options or settings declines).\n'
    return 0
  fi
  qtext="$(printf '%s' "$pin" | jq -r '.questions[0].question')"
  label="$(printf '%s' "$payload" | jq -r --arg q "$qtext" 'if (.tool_response.answers | type == "object") and ((.tool_response.answers | keys) == [$q]) and (.tool_response.answers[$q] | type == "string") then .tool_response.answers[$q] else empty end' 2>/dev/null)"
  if [ -z "$label" ]; then
    printf 'no no single answer to the pinned question was found in the response.\n'
    return 0
  fi
  if ! printf '%s' "$pin" | jq -e --arg l "$label" 'any(.questions[0].options[]; .label == $l)' >/dev/null 2>&1; then
    printf 'no the answer is not one of the pinned options (free text typed into Other is never recorded).\n'
    return 0
  fi
  nonce="$(printf '%s' "$pend" | jq -r '.nonce // ""')"
  idx="$(printf '%s' "$pend" | jq -r '.index')"
  printf 'ok\t%s\t%s\t%s\n' "$label" "$nonce" "$idx"
}

# _ag_decline_check <line>: turn a `no <reason>` line into the visible decline.
_ag_decline_check() {
  _ag_decline "${1#no }"
}

state="$(gaia_loop_read_state "$target" 2>/dev/null)" || _ag_decline "the audit state file $target could not be read."
verdict="$(_ag_check "$state")"
case "$verdict" in
  no*) _ag_decline_check "$verdict" ;;
esac

# Classify the label before taking the lock: only the grant and accept labels
# record. A grant records K from the shared lib, never a count read from the payload.
label="$(printf '%s' "$verdict" | cut -f2)"
unit_rounds="$GAIA_CTX_UNIT_ROUNDS"
kind=""
base="${label% (Recommended)}"
case "$base" in
  "Continue audit in this session" | "Continue audit in a new session") kind=grant ;;
  "Accept the remainder") kind=accept ;;
  "Stop and file the remainder")
    _ag_say "Nothing was recorded: Stop and file the remainder was selected, so the loop stays stopped. Claude: do not dispatch another audit round; file the remainder as tech debt, leave the PR open, and report to the human." \
      "The human selected Stop and file the remainder at the audit checkpoint. Do not dispatch another audit round. File the remainder as tech debt, leave the PR open, and report."
    exit 0
    ;;
  "Type audit-accept instead")
    _ag_say "Nothing was recorded: round 10 is the cap and accept is not offered. The human may type audit-accept as the whole prompt as a deliberate override of the eligibility gate, or stop and file the remainder." \
      "The human selected Type audit-accept instead. Nothing was recorded and the loop stays stopped. Wait for the human to type audit-accept, or file the remainder."
    exit 0
    ;;
  *)
    _ag_decline "the selected option '$base' is not one this hook records."
    ;;
esac

# Record under the lock, re-reading and re-checking after acquiring it.
if ! gaia_loop_lock "$target" "$(($(date +%s) + 5))"; then
  _ag_decline "the audit state file is locked by another writer."
fi
state="$(gaia_loop_read_state "$target" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  gaia_loop_unlock "$target"
  if [ "$rc" -eq 5 ]; then
    _ag_decline "the audit state file $target is corrupt and was left untouched."
  fi
  _ag_decline "the audit state file $target could not be read."
fi
verdict="$(_ag_check "$state")"
case "$verdict" in
  no*)
    gaia_loop_unlock "$target"
    _ag_decline_check "$verdict"
    ;;
esac
nonce="$(printf '%s' "$verdict" | cut -f3)"
idx="$(printf '%s' "$verdict" | cut -f4)"
at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$kind" = grant ]; then
  new="$(printf '%s' "$state" | jq -c --argjson cp "$idx" --argjson n "$unit_rounds" --arg at "$at" --arg sid "$session_id" \
    --arg opt "$label" --arg nonce "$nonce" \
    '.allowance.answers += [{checkpoint: $cp, kind: "grant", n: $n, source: "ask", option: $opt, nonce: $nonce, at: $at, session_id: $sid}]' 2>/dev/null)" || new=""
else
  new="$(printf '%s' "$state" | jq -c --argjson cp "$idx" --arg at "$at" --arg sid "$session_id" \
    --arg opt "$label" --arg nonce "$nonce" \
    '.allowance.answers += [{checkpoint: $cp, kind: "accept", source: "ask", option: $opt, nonce: $nonce, at: $at, session_id: $sid}]' 2>/dev/null)" || new=""
fi
if [ -z "$new" ] || ! gaia_loop_write_state "$target" "$new"; then
  gaia_loop_unlock "$target"
  _ag_decline "the audit state file could not be written."
fi
gaia_loop_unlock "$target"

bname="$(printf '%s' "$new" | jq -r '.branch')"
if [ "$kind" = grant ]; then
  msg="Recorded: $base on branch $bname (checkpoint $idx), $unit_rounds more rounds."
  ctx="$msg Claude: the human selected this pinned option; continue the loop within that allowance."
  case "$base" in
    *"in a new session")
      ctx="$ctx Print one instruction line, then the fenced continuation prompt for a fresh session with the branch, PR and run folder, and stop: do not start another round in this session."
      ctx="$ctx The line is 'Run \`/clear\`, then paste the prompt below.' by default."
      ctx="$ctx Use 'Kill this session with Ctrl+C, start a new one (\`claude\`, with any needed environment variable), then paste the prompt below.' instead when the next session needs something only a fresh launch provides: an environment variable, or an agent, hook or settings change that loads at session start, such as the branch having edited .claude/agents/, .claude/hooks/ or .claude/settings.json since this session started."
      ;;
  esac
else
  msg="Recorded: $base on branch $bname (checkpoint $idx). Exactly one closing round is allowed and no fixer runs in it."
  ctx="$msg Claude: the human selected this pinned option; continue the loop within that allowance."
fi
_ag_say "$msg" "$ctx"
exit 0
