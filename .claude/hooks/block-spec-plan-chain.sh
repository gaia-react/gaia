#!/usr/bin/env bash
# PreToolUse + SessionStart hook: a session that authored a SPEC may not go on
# to plan it. /gaia-spec ends with a very large context (Socratic loop, gate
# renders, self-review, adversarial audit); /gaia-plan's deep synthesis needs a
# clean one. So the handoff is a copy-pasteable prompt the human runs in a fresh
# session, never an in-session chain.
#
# spec.md has said "print the handoff and stop" in prose since the flow was
# written, and the model still chains anyway: when /gaia-spec is invoked as a
# skill rather than typed by the human, the driving agent carries an outer goal
# ("spec and build X") that outlives the skill body, and step 11's stop reads as
# a suggestion. Prose cannot hold a boundary the agent has a standing reason to
# cross. This makes it deterministic.
#
# HOW IT WORKS. Both commands are thin dispatchers whose body is "Read
# .claude/skills/gaia/references/<x>.md and follow it exactly", so every entry
# path, human or model, funnels through tool calls this hook sees:
#
#   STAMP (a spec session is underway; allow, never block):
#     - Skill        whose skill NAME (never its arguments) resolves to gaia-spec
#     - Bash         INVOKING lib/spec-allocator.sh, i.e. the path followed by one
#                    of its own subcommands (the SPEC-id allocation every
#                    /gaia-spec path runs: fresh, resume, and auto). Merely naming
#                    the allocator (a grep, a shellcheck, a git log, this hook's
#                    own tests) is not an invocation and must never stamp.
#   DENY (that stamp is live for this session_id):
#     - Skill        whose skill name resolves to gaia-plan
#     - Read         of .claude/skills/gaia/references/plan.md
#
# The sentinel is keyed on session_id, so the guard is scoped to the session
# that ran /gaia-spec and is inert everywhere else: a fresh session may invoke
# /gaia-plan by any route, including the model's own natural-language dispatch.
#
# WHY NOT STAMP ON A Read OF spec.md. It is the other obvious chokepoint, but
# audit runbooks cite spec.md step 7 AND plan.md step 4.6 as the canonical
# audit pattern, so an audit session reads both references and would deny
# itself. An allocator INVOCATION carries no such ambiguity: nothing
# allocates a SPEC id except a live authoring session. The distinction is the
# whole point, and it is load-bearing in the other direction too, since a
# maintainer session that greps or lints the allocator (a shell audit, a fitness
# run) must not be read as authoring and lose /gaia-plan for a SPEC it never
# wrote. A false stamp is a false deny one step later, so the stamp arm is held
# to the same fail-open standard as everything else here.
#
# STRICT BY DESIGN. A PreToolUse hook cannot distinguish a human-typed
# /gaia-plan from a model-initiated one at the Read chokepoint (a typed slash
# command expands at the prompt level and reaches no tool, but the Read of
# plan.md it provokes is identical either way). The block therefore holds for
# both, which is the stated policy: planning is always a new session. The
# correct path is one keystroke away, /clear drops the sentinel (the
# SessionStart arm below), and the deny names it.
#
# RESIDUAL GAPS (documented, not bugs): an agent that reads plan.md through Bash
# (`cat`/`sed`) rather than the Read tool, or that reconstructs planning ad hoc
# without reading plan.md at all, is not caught. A Bash arm was considered and
# rejected: matching plan.md in a command string denies innocent greps for
# "gaia-plan" (an audit, this very hook's own tests), and the false-positive
# cost outweighs a vector no observed misfire has used. Prose covers the rest,
# spec.md's Hard constraint 6 and step 11.
#
# Best-effort, never a sandbox: always exits 0, carrying the decision in stdout
# JSON. Any ambiguity (no git, no session_id, unparseable payload) falls through
# to allow, an authoring session that cannot be proven is never blocked.
# Policy: wiki/concepts/GAIA Spec.md (step 11).
set -uo pipefail

payload=$(cat)

event=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null) || exit 0
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0

# Session ids are opaque; refuse to build a path out of one that is not a safe
# filename rather than sanitizing it into a collision with another session's.
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

# Resolve the MAIN checkout, not the current worktree: a session can author a
# SPEC in the main checkout and enter a worktree before planning, and the guard
# must still hold across that move. The shared resolver, sourced from this
# hook's own checkout via BASH_SOURCE (never process cwd), is the one place
# that answers "where is main".
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0
root=$(gaia_resolve_main_root 2>/dev/null) || exit 0
sentinel="$root/.gaia/local/cache/spec-chain-${session}.json"

# --- SessionStart: /clear is the sanctioned reset -----------------------------
# /clear is exactly the state the guard exists to force, so it releases it.
# Compaction deliberately does NOT: a compacted spec session is the same session
# with the same momentum, and "plan in a fresh session" means a fresh session.
if [ "$event" = "SessionStart" ]; then
  source_kind=$(jq -r '.source // empty' <<<"$payload" 2>/dev/null) || exit 0
  [ "$source_kind" = "clear" ] && rm -f "$sentinel" 2>/dev/null
  exit 0
fi

[ "$event" = "PreToolUse" ] || exit 0

tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0

stamp() {
  mkdir -p "$(dirname "$sentinel")" 2>/dev/null || exit 0
  jq -n --arg s "$session" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{session_id: $s, stamped_at: $t}' > "$sentinel" 2>/dev/null || true
  exit 0
}

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

deny_msg() {
  echo "/gaia-spec ran in this session, so /gaia-plan cannot: planning always starts in a fresh session. A spec session ends with a very large context and the planner needs a clean one. Print the handoff block and STOP; the human runs /clear and pastes '/gaia-plan SPEC-NNN'. (/clear releases this guard. Sentinel: ${sentinel#"$root"/}.)"
}

# Resolve the skill name across harness builds: the field has been .name and
# .skill in different versions, so try an explicit candidate list. Deliberately
# NOT a scan of every string in tool_input: the skill's ARGUMENTS are in there
# too, so a scan reads a mention as an invocation (a `Skill(gaia-audit, args:
# "review the gaia-spec flow")` would stamp) — the same mention-vs-invocation
# error the Bash arm above must avoid. If none of the candidate fields exist,
# this arm goes inert rather than guessing from content: the Read arm is the
# load-bearing one and still holds the boundary on its own.
skill_name() {
  local n
  n=$(jq -r '.tool_input.name // .tool_input.skill // .tool_input.skill_name
             // .tool_input.command // empty' <<<"$payload" 2>/dev/null) || return 1
  printf '%s' "$n"
}

# Matches a bare `gaia-plan`, a leading-slash `/gaia-plan`, and a
# plugin-namespaced `some-plugin:gaia-plan`.
is_skill() {
  local want="$1" got="$2"
  [[ "$got" =~ ^/?([A-Za-z0-9_-]+:)?"$want"$ ]]
}

case "$tool" in
  Skill)
    name=$(skill_name) || exit 0
    [ -n "$name" ] || exit 0
    is_skill gaia-spec "$name" && stamp
    is_skill gaia-plan "$name" && [ -f "$sentinel" ] && deny "$(deny_msg)"
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
    # Anchor on an INVOCATION, never a mention. A bare substring match stamps on
    # `grep -rn spec-allocator.sh`, `shellcheck <it>`, `git log -- <it>`, and this
    # hook's own tests, and a session that merely READ ABOUT the allocator would
    # then lose /gaia-plan with a deny that claims, falsely, that it authored a
    # SPEC. That is the fail-closed direction this hook's contract forbids, and
    # it is the same mention-vs-invocation objection that rules out a Bash deny
    # arm (see RESIDUAL GAPS). Requiring the allocator's own subcommand
    # vocabulary to follow the path makes naming it inert and running it a stamp.
    # Narrowing accepted: an invocation indirected through a variable in the same
    # command string no longer stamps. No call site writes it that way; spec.md
    # runs `in_progress` and the specify preset runs `next`, both literal.
    [[ "$cmd" =~ spec-allocator\.sh[[:space:]]+(next|highest|in_progress|reserve_pending)([[:space:]]|$) ]] \
      && stamp
    ;;
  Read)
    path=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || exit 0
    # Suffix match, so it holds for the absolute, repo-relative, and
    # worktree-prefixed forms of the same reference. Anchored on the full
    # reference path so a SPEC's own colocated plan/ artifacts never trip it.
    [[ "$path" == *".claude/skills/gaia/references/plan.md" ]] \
      && [ -f "$sentinel" ] && deny "$(deny_msg)"
    ;;
esac

exit 0
