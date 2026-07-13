#!/usr/bin/env bats

# Tests for .claude/hooks/block-spec-plan-chain.sh.
#
# The guard stops a session that authored a SPEC from planning it: /gaia-spec
# ends with a very large context, and /gaia-plan needs a clean one, so the
# handoff is a prompt the human pastes into a fresh session. Prose alone did not
# hold (a skill-invoked /gaia-spec carries an outer goal that survives the skill
# body), so the boundary is deterministic: a stamp on the entry points every
# /gaia-spec path must run, a deny on the entry points /gaia-plan cannot avoid.
#
# The stamp is keyed on session_id, so every assertion here is really two: the
# guard fires for the session that ran /gaia-spec, and is inert for one that did
# not. The hook is best-effort, not a sandbox: it always exits 0, carrying the
# allow/deny decision in stdout JSON.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-spec-plan-chain.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"

  # A real git repo: the hook resolves its sentinel against the main checkout
  # (git rev-parse --git-common-dir), so it is a no-op outside one.
  REPO=$(bash "$HELPERS/tmp-git-repo.sh")
  cd "$REPO"

  SESSION="sess-abc123"
  SENTINEL="$REPO/.gaia/local/cache/spec-chain-${SESSION}.json"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

# Quote-safe delivery: payloads carry paths and command strings of their own, so
# $json and $HOOK_ABS go in as positional args rather than being re-wrapped in an
# outer single-quoted `bash -c '...'` string.
run_hook() {
  local json="$1"
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_skill() {
  local name="$1" sid="${2:-$SESSION}"
  run_hook "$(jq -n --arg s "$sid" --arg n "$name" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Skill",
      tool_input: {name: $n, arguments: "SPEC-042"}}')"
}

run_read() {
  local path="$1" sid="${2:-$SESSION}"
  run_hook "$(jq -n --arg s "$sid" --arg p "$path" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Read",
      tool_input: {file_path: $p}}')"
}

run_bash_tool() {
  local cmd="$1" sid="${2:-$SESSION}"
  run_hook "$(jq -n --arg s "$sid" --arg c "$cmd" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Bash",
      tool_input: {command: $c}}')"
}

run_session_start() {
  local source_kind="$1" sid="${2:-$SESSION}"
  run_hook "$(jq -n --arg s "$sid" --arg src "$source_kind" \
    '{session_id: $s, hook_event_name: "SessionStart", source: $src}')"
}

# Put the session in the state it is in after /gaia-spec has started.
stamp_session() {
  run_skill "gaia-spec" "${1:-$SESSION}"
  [ -f "$REPO/.gaia/local/cache/spec-chain-${1:-$SESSION}.json" ]
}

assert_denied() {
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- The stamp ---------------------------------------------------------------

@test "Skill(gaia-spec) stamps the session and is never blocked" {
  run_skill "gaia-spec"
  assert_allowed
  [ -f "$SENTINEL" ]
  [ "$(jq -r '.session_id' "$SENTINEL")" = "$SESSION" ]
}

@test "the spec allocator stamps the session (the path a typed /gaia-spec takes)" {
  # A human-typed /gaia-spec expands at the prompt level and reaches no tool, so
  # the Skill arm never sees it. Every /gaia-spec path, fresh, resume, and auto,
  # runs the allocator, which is why that is the stamp of record.
  run_bash_tool 'bash .specify/extensions/gaia/lib/spec-allocator.sh in_progress "$PWD"'
  assert_allowed
  [ -f "$SENTINEL" ]
}

@test "the allocator stamps on the auto-mode subcommand too" {
  run_bash_tool 'bash .specify/extensions/gaia/lib/spec-allocator.sh next "$PWD"'
  assert_allowed
  [ -f "$SENTINEL" ]
}

@test "an unrelated Bash command does not stamp" {
  run_bash_tool 'pnpm typecheck'
  assert_allowed
  [ ! -f "$SENTINEL" ]
}

# --- The deny ----------------------------------------------------------------

@test "Skill(gaia-plan) is denied once the session has authored a SPEC" {
  stamp_session
  run_skill "gaia-plan"
  assert_denied
}

@test "the deny tells the agent to stop and the human to /clear" {
  stamp_session
  run_skill "gaia-plan"
  local reason
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ "$reason" == *"/clear"* ]]
  [[ "$reason" == *"STOP"* ]]
}

@test "reading the plan reference is denied (the inline-follow bypass)" {
  # Blocking only Skill(gaia-plan) would leave the hole the misfire actually
  # uses: the command body is 'Read references/plan.md and follow it exactly',
  # so an agent can plan without ever touching the Skill tool.
  stamp_session
  run_read ".claude/skills/gaia/references/plan.md"
  assert_denied
}

@test "the plan reference is denied by absolute path too" {
  stamp_session
  run_read "$REPO/.claude/skills/gaia/references/plan.md"
  assert_denied
}

@test "a plugin-namespaced or slash-prefixed gaia-plan is still denied" {
  stamp_session
  run_skill "/gaia-plan"
  assert_denied
  run_skill "some-plugin:gaia-plan"
  assert_denied
}

@test "the deny holds for a human-typed /gaia-plan (strict by design)" {
  # A typed slash command reaches no tool, but the Read of plan.md its body
  # provokes is indistinguishable from the model's. Policy is that planning is
  # always a new session, so the block holds for both; /clear releases it.
  stamp_session
  run_read ".claude/skills/gaia/references/plan.md"
  assert_denied
}

# --- Scoping: the guard must be inert everywhere else -------------------------

@test "a fresh session may invoke /gaia-plan by any route" {
  run_skill "gaia-plan"
  assert_allowed
  run_read ".claude/skills/gaia/references/plan.md"
  assert_allowed
}

@test "the stamp does not leak across sessions" {
  stamp_session "sess-spec-ran"
  run_skill "gaia-plan" "sess-other"
  assert_allowed
  run_read ".claude/skills/gaia/references/plan.md" "sess-other"
  assert_allowed
}

@test "a stamped session may still read anything else" {
  stamp_session
  run_read ".claude/skills/gaia/references/spec.md"
  assert_allowed
  run_read "app/routes/home.tsx"
  assert_allowed
}

@test "a SPEC's own colocated plan artifacts are not the plan reference" {
  # The plan lives inside the SPEC folder; nothing there is the skill body.
  stamp_session
  run_read ".gaia/local/specs/SPEC-042/plan/README.md"
  assert_allowed
  run_read ".gaia/local/specs/SPEC-042/plan/ORCHESTRATOR.md"
  assert_allowed
}

@test "grepping for gaia-plan is not planning" {
  # The Bash arm stamps; it never denies. An audit that greps the string, or
  # this very test file, must not trip the guard.
  stamp_session
  run_bash_tool 'grep -rn "gaia-plan" .claude'
  assert_allowed
  run_bash_tool 'cat .claude/skills/gaia/references/plan.md'
  assert_allowed  # documented residual gap, asserted so a future change is deliberate
}

@test "a session that only ran /gaia-plan is not stamped by it" {
  run_skill "gaia-plan"
  assert_allowed
  [ ! -f "$SENTINEL" ]
}

# --- Lifecycle ---------------------------------------------------------------

@test "/clear releases the guard" {
  stamp_session
  run_session_start "clear"
  [ "$status" -eq 0 ]
  [ ! -f "$SENTINEL" ]
  run_skill "gaia-plan"
  assert_allowed
}

@test "compaction does NOT release the guard" {
  # A compacted spec session is the same session with the same momentum. "Plan
  # in a fresh session" means a fresh session, not a smaller context.
  stamp_session
  run_session_start "compact"
  [ -f "$SENTINEL" ]
  run_skill "gaia-plan"
  assert_denied
}

@test "startup and resume leave the guard alone" {
  stamp_session
  run_session_start "startup"
  [ -f "$SENTINEL" ]
  run_session_start "resume"
  [ -f "$SENTINEL" ]
}

# --- Fail-open ----------------------------------------------------------------

@test "a payload with no session_id falls through to allow" {
  run_hook '{"hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": {"name": "gaia-plan"}}'
  assert_allowed
}

@test "a session id that is not a safe filename falls through to allow" {
  # Refuse to build a path out of it rather than sanitize it into a collision
  # with another session's sentinel.
  run_skill "gaia-spec" "../../etc/passwd"
  assert_allowed
  [ ! -f "$REPO/.gaia/local/cache/spec-chain-../../etc/passwd.json" ]
}

@test "unparseable input never blocks" {
  run_hook 'not json at all'
  [ "$status" -eq 0 ]
}

# --- Wiring -------------------------------------------------------------------

@test "the hook is registered on every event it needs" {
  local settings="${HOOKS_SRC%/hooks}/settings.json"
  # PreToolUse: the Skill arm (stamp + deny), the Bash arm (stamp), the Read arm
  # (deny). SessionStart: the /clear release.
  local matchers
  matchers=$(jq -r '
    .hooks.PreToolUse[]
    | select(.hooks[].command | test("block-spec-plan-chain"))
    | .matcher' "$settings")
  [[ "$matchers" == *"Skill"* ]]
  [[ "$matchers" == *"Bash"* ]]
  [[ "$matchers" == *"Read"* ]]

  run jq -e '
    .hooks.SessionStart[]
    | select(.hooks[].command | test("block-spec-plan-chain"))' "$settings"
  [ "$status" -eq 0 ]
}
