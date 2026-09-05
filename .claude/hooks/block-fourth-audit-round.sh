#!/usr/bin/env bash
# PreToolUse + SessionStart hook: deny the FOURTH Code Audit Team dispatch
# wave in one session, on one branch. The semantics live in
# wiki/concepts/PR Merge Workflow.md, "#### The three-round session cap";
# this hook enforces them, it does not restate them.
#
# WHY A HOOK AND NOT PROSE. The pre-merge audit's fix-and-re-audit loop has
# no stop of its own: every round's fixes buy the next dispatch, so an
# unattended run spends without bound while the session's own context fills
# with reports it can no longer weigh against each other. The judgement
# "is a fourth round worth it" gets made mid-loop by the session least able
# to make it. Prose cannot hold a boundary an agent has a standing reason to
# cross, the same lesson block-spec-plan-chain.sh was written for; this hook
# is that file's structural twin, same session-keyed main-anchored
# sentinel, same deny mechanism, same fail-open posture.
#
# WAVE IDENTITY: the acting tree's HEAD tree SHA. A round is one dispatch
# wave, whatever that wave spawns. Every member in a wave is dispatched
# against one HEAD, so every hook invocation in that wave computes the same
# tree and only the first one records it -- this collapses N parallel
# dispatches by construction, no timing window to misfire. It is sound
# rather than a coincidence: the workflow requires HEAD to move between
# rounds ("HEAD must move so the next audit runs against the fixed tree"),
# so a genuine new round always presents a new tree. The one hardened
# re-dispatch of a member that no-op'd (see
# wiki/concepts/PR Merge Workflow.md, "#### No-op detection and retry for
# each dispatched member", and .claude/rules/subagent-dispatch.md) shares
# its wave's unmoved tree and is therefore free, which is correct: it is
# not a new round, it is the first one finishing.
#
# STATED FAILURE MODES, honestly:
# - A deliberate re-dispatch against an unmoved tree (no intervening commit)
#   is under-counted. This is the same shape as the no-op retry and the
#   guard cannot tell the two apart without a heuristic; under-counting is
#   the safe direction for a bound that ends a session rather than
#   protecting correctness.
# - A commit that leaves the tree byte-identical (an empty commit, a
#   message-only amend) reads as the same wave, same direction, same
#   acceptance.
# - A dispatch cancelled at the permission prompt has already counted: the
#   count is taken at PreToolUse. Recovery is local: remove the gitignored
#   counter file under .gaia/local/cache/.
#
# WHY DENY AND NOT ASK. An "ask" verdict puts the "is this branch worth a
# fourth round" question back to the session mid-loop, exactly the
# judgement the cap refuses to leave there.
#
# WHY NO OVERRIDE KNOB. A knob spelled once becomes the default path, and a
# cap with a documented bypass is prose again. The sanctioned escape is the
# workflow's own: push round three, emit the continuation prompt, let a
# human start a fresh session with its own three.
#
# FAIL-OPEN POSTURE, AND ITS COST. Every unknown (unresolvable payload
# field, absent session id, unresolvable git state, unreadable counter)
# exits 0 silently, so a harness that never delivers this event, or a
# roster member named off the code-audit- convention, leaves the guard
# inert rather than misfiring. "Inert" and "working" are indistinguishable
# from this file alone, and the bats suite cannot close that: it invokes this
# script directly and never exercises the .claude/settings.json registration,
# so a matcher edit, a rename, or a dropped registration leaves every test
# green. Nothing in the tree re-proves the enforcement point, and this header
# claims no such guard. What proves it is a live drive: seed the counter with
# three dummy trees, attempt one real member dispatch, assert the deny. That
# is a step the pre-merge gate's own verify-your-own-work obligation
# (.claude/rules/pr-merge.md) puts on whoever changes the registration, not a
# fixture standing watch here.
#
# SCOPE: only tool_input.subagent_type matching code-audit-* counts. The
# roster does not pin the literal subagent_type a member's own internal
# fan-out (its specialists and refuters) carries --
# .claude/agents/code-audit-frontend.md says only "an explicit
# subagent_type (a general reviewer)" and never names general-purpose, so
# this header does not claim that literal either. The filter does not need
# that pin: a nested dispatch shares its dispatching wave's HEAD tree, so it
# is free under the wave-identity rule whatever it is named. The
# code-audit- prefix match is a second, cheaper line of defence whose real
# job is keeping this hook off the git path for the overwhelming majority
# of dispatches, which are not members at all -- put before any git or
# filesystem work for that reason.
#
# ANTI-EVASION. session_id is shared between a parent session and every
# subagent it dispatches (both report the same identifier, per
# wiki/concepts/Claude Hooks.md), so a member dispatched from inside another
# subagent still carries this session's id and still counts. Only
# .tool_input.subagent_type is read to identify the dispatched agent; there
# is no tool_input.agent_type. The agent_type field block-selfheal-paths.sh
# reads is a TOP-LEVEL payload field naming the agent MAKING the call, the
# opposite question, and folding it in here would count a member's own
# nested dispatches as if they were top-level rounds.
#
# /clear AND COMPACTION. /clear is the sanctioned reset (SessionStart,
# source == "clear"): it cannot be typed by the model or any subagent, so
# it is human-gated by construction, and it empties the very context the
# cap exists to bound. Compaction deliberately does NOT reset: by the
# fourth round the session holds three reports in a context it is about to
# compact, which is the condition the cap exists for, and a counter that
# reset on compaction would be inert exactly when it matters.
set -uo pipefail

payload=$(cat)

event=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null) || exit 0

# --- SessionStart: /clear is the sanctioned reset -----------------------------
if [ "$event" = "SessionStart" ]; then
  source_kind=$(jq -r '.source // empty' <<<"$payload" 2>/dev/null) || exit 0
  session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || exit 0
  if [ "$source_kind" = "clear" ] && [ -n "$session" ] && [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]]; then
    # Same root input as the PreToolUse arm below: the payload's own cwd when
    # it is absolute, else the process one. The arms must agree, because a
    # reset resolved from a different root than the write removes a file the
    # counter was never in, and the count then survives the one release this
    # hook documents and offers no override for.
    reset_cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null) || reset_cwd=""
    case "$reset_cwd" in
      /*) ;;
      *) reset_cwd="$PWD" ;;
    esac
    gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    if [ -n "${gaia_scripts:-}" ]; then
      gaia_scripts="$gaia_scripts/.gaia/scripts"
      # shellcheck source=/dev/null
      if source "$gaia_scripts/main-root-lib.sh" 2>/dev/null; then
        root=$(gaia_resolve_main_root "$reset_cwd" 2>/dev/null) || root=""
        [ -n "$root" ] && rm -f "$root/.gaia/local/cache/audit-rounds-${session}.json" 2>/dev/null
      fi
    fi
  fi
  exit 0
fi

[ "$event" = "PreToolUse" ] || exit 0

tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$tool" in
  Agent | Task) ;;
  *) exit 0 ;;
esac

# Cheapest discriminator after the tool name, and it keeps this hook off the
# git path for the overwhelming majority of dispatches: only
# tool_input.subagent_type, never tool_input.agent_type (does not exist) and
# never the top-level agent_type (the calling agent's identity, a different
# question -- see header).
member=$(jq -r '.tool_input.subagent_type // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$member" in
  code-audit-*) ;;
  *) exit 0 ;;
esac

session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0
# Refuse to build a path out of an unsafe session id rather than sanitizing
# it into a collision with another session's counter.
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$cwd" in
  /*) ;;
  *) cwd="$PWD" ;;
esac

tree=$(git -C "$cwd" rev-parse 'HEAD^{tree}' 2>/dev/null) || exit 0
[ -n "$tree" ] || exit 0

branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch=""
[ -n "$branch" ] || branch="(detached)"

gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0
root=$(gaia_resolve_main_root "$cwd" 2>/dev/null) || exit 0

counter_dir="$root/.gaia/local/cache"
counter="$counter_dir/audit-rounds-${session}.json"

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

ledger_dir="$root/.gaia/local/audit"

deny_msg() {
  cat <<EOF
BLOCKED: three Code Audit Team rounds are already spent in this session on branch ${branch}. The fourth dispatch wave is what the cap forbids.

This is not a defect and not a merge blocker. The cap bounds this session's context and cost, not the change: \`gh pr merge\` is still governed only by the clearance markers the merge gate already requires, and a clean round, or one carrying only accepted residuals, merges at any round number.

Do this, in order:
1. If round three's findings are not yet fixed, committed, and pushed, do that now exactly as any other round's.
2. Emit the continuation prompt described in \`wiki/concepts/PR Merge Workflow.md\`, \`#### The three-round session cap\`, fenced so it pastes as one unit. It carries the PR number, the branch and its base, that three rounds are spent, the re-run carry-forward ledger at ${ledger_dir}/<AUDIT_KEY>.rerun.json and that the fixer reads its \`remaining[]\` and \`fixed_last_round[]\`, what each round fixed, which findings are accepted residuals already recorded in the PR body, and an instruction to re-read that page and resume at step 1.
3. End the run. Do not continue the rounds in a subagent, a fork, or a session you start yourself: that spends the same budget against the same branch and defeats the bound.

A human resumes by typing /clear and pasting that prompt; /clear releases this guard so the next session starts with its own three. There is no override flag.

Round counter: ${counter}
EOF
}

# Absent, empty, or unparseable counter reads as empty state -- fail-open,
# never an error.
existing_trees=$(jq -r --arg b "$branch" '.branches[$b].trees // [] | .[]' "$counter" 2>/dev/null)

already_counted=0
if [ -n "$existing_trees" ]; then
  while IFS= read -r t; do
    [ "$t" = "$tree" ] && already_counted=1 && break
  done <<<"$existing_trees"
fi

# Same wave: a parallel sibling in this wave, or the single hardened
# re-dispatch of a no-op'd member. Neither burns a round.
[ "$already_counted" -eq 1 ] && exit 0

count=0
if [ -n "$existing_trees" ]; then
  count=$(printf '%s\n' "$existing_trees" | grep -c .)
fi

if [ "$count" -ge 3 ]; then
  deny "$(deny_msg)"
fi

mkdir -p "$(dirname "$counter")" 2>/dev/null || exit 0

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cur_json=$(jq -c '. // {}' "$counter" 2>/dev/null) || cur_json='{}'
[ -n "$cur_json" ] || cur_json='{}'

new_content=$(jq -n --argjson cur "$cur_json" \
  --arg session "$session" --arg now "$now" --arg branch "$branch" --arg tree "$tree" '
  ($cur // {}) as $c
  | {
      schema: 1,
      session_id: $session,
      updated_at: $now,
      branches: (
        ($c.branches // {}) as $b
        | $b + { ($branch): { trees: (($b[$branch].trees // []) + [$tree]) } }
      )
    }
' 2>/dev/null) || exit 0
[ -n "$new_content" ] || exit 0

tmp=$(mktemp "$counter_dir/audit-rounds-${session}.json.XXXXXX" 2>/dev/null) || exit 0
printf '%s\n' "$new_content" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
mv "$tmp" "$counter" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
