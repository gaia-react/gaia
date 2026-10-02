#!/usr/bin/env bats
#
# Registration of the audit loop hooks in .claude/settings.json, the state
# registry entry that classifies their state, and the one behavioral claim that
# depends on which events register what: a session-lifecycle event never
# changes a branch's audit state.
#
# GAIA_REGISTRATION_SETTINGS points the settings cases at a scratch copy of
# settings.json, and GAIA_REGISTRATION_HOOKS_DIR points the SessionStart case at
# a scratch hooks directory; each is how a mutant is run without touching the
# working file. Both default to the real ones.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-registration.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs and `bash -c` bodies are single-quoted so their `$` reaches
# the inner interpreter.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SETTINGS="${GAIA_REGISTRATION_SETTINGS:-$REPO_ROOT/.claude/settings.json}"
  HOOKS_DIR="${GAIA_REGISTRATION_HOOKS_DIR:-$REPO_ROOT/.claude/hooks}"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  BOUND_HOOK="$REPO_ROOT/.claude/hooks/audit-loop-bound.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
}

# --- settings: which events reach which hook ---------------------------------

@test "Agent|Task registers the bound hook and not the retired counter" {
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher == "Agent|Task")' audit-loop-bound.sh
  # The retired name is spelled as a character class so this file never holds it.
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task") | .hooks[].command] | any(test("block-fourth[-]audit-round")) | not' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "no SessionStart entry names an audit loop hook or the retired counter" {
  run jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | length > 0' "$SETTINGS"
  [ "$status" -eq 0 ]
  run jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(test("audit-loop|block-fourth[-]audit-round")) | not' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "no SessionStart entry has a clear matcher that carries only an audit hook" {
  run jq -e '[.hooks.SessionStart[] | select(.matcher == "clear")] | length == 0' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "UserPromptSubmit registers the grant hook" {
  hook_registered "$SETTINGS" '.hooks.UserPromptSubmit[]' audit-loop-grant.sh
}

@test "PostToolUse AskUserQuestion registers the ask recorder with a rooted command and a timeout" {
  hook_registered "$SETTINGS" '.hooks.PostToolUse[] | select(.matcher == "AskUserQuestion")' audit-loop-ask-grant.sh
  run jq -e '[.hooks.PostToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[]
      | select(.command | test("audit-loop-ask-grant[.]sh"))] | length == 1
      and all(.[]; (.command | startswith("\"$(git rev-parse --show-toplevel")) and (.timeout | type == "number" and . >= 10))' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "the ask recorder is registered on no event other than PostToolUse AskUserQuestion" {
  run jq -e '[.hooks | to_entries[] | .key as $event | .value[] | .matcher as $m | .hooks[]
      | select(.command | test("audit-loop-ask-grant[.]sh")) | [$event, $m]] == [["PostToolUse", "AskUserQuestion"]]' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "Edit|Write|MultiEdit registers the write guard" {
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' block-audit-loop-write.sh
}

@test "Bash|Monitor registers the write guard" {
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-audit-loop-write.sh
}

# --- settings: the registered timeout outlasts the hook's own deadline -------

# The bound hook gives up at its internal deadline and then answers; a
# registration timeout at or below that value lets the harness kill the hook
# first, which reads as a non-blocking error (the call proceeds). Both values
# are read, never assumed, and the case fails when either cannot be read.
@test "the Agent|Task timeout is at least the bound hook's deadline plus 5" {
  local deadline timeout
  deadline="$(sed -n 's/^GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=\([0-9][0-9]*\)$/\1/p' "$BOUND_HOOK")"
  case "$deadline" in '' | *[!0-9]* | *"
"*) printf 'cannot read a single numeric deadline from %s: [%s]\n' "$BOUND_HOOK" "$deadline" >&2; return 1 ;; esac
  timeout="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task") | .hooks[]
      | select(.command | test("audit-loop-bound[.]sh")) | .timeout] | first // "" | tostring' "$SETTINGS")"
  case "$timeout" in '' | null | *[!0-9]*) printf 'the bound hook registration carries no numeric timeout: [%s]\n' "$timeout" >&2; return 1 ;; esac
  [ "$timeout" -ge $((deadline + 5)) ] || { printf 'timeout %s < deadline %s + 5\n' "$timeout" "$deadline" >&2; return 1; }
}

# --- registry -----------------------------------------------------------------

@test "the state registry classifies the audit loop state and keeps no retired counter" {
  run jq -e '[.entries[] | select(.id == "audit-loop-state")] | length == 1' "$REGISTRY"
  [ "$status" -eq 0 ]
  run jq -e '[.entries[] | select((.path + " " + .id) | test("audit-rounds[-]|audit-round[-]counter"))] | length == 0' "$REGISTRY"
  [ "$status" -eq 0 ]
}

# --- UAT-005: session lifecycle never touches the branch state ---------------

# Every hook registered under SessionStart is derived from settings.json and run
# with each source value the harness can send; the state file must stay
# byte-identical, and a later dispatch from a different session on a new tree
# must still be denied at the checkpoint. HOME and every network-touching
# variable point into the test's own tree and gh is a stub, so no hook reaches
# the real machine.
@test "SessionStart hooks leave a checkpointed branch state byte-identical" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/state.saved"

  local stub="$BATS_TEST_TMPDIR/stubbin" home="$BATS_TEST_TMPDIR/home" names name src
  mkdir -p "$stub" "$home"
  # gh's own wording for a branch with no pull request: the audit loop
  # checkpoint reads it as "no PR" and proceeds to its checkpoint, where a
  # silent failure would read as gh unable to say whether the PR is a fork.
  printf '#!/bin/sh\necho "no pull requests found for branch" >&2\nexit 1\n' >"$stub/gh"
  chmod +x "$stub/gh"

  names="$(jq -r '[.hooks.SessionStart[].hooks[].command | capture("/[.]claude/hooks/(?<n>[^/\"]+[.]sh)").n] | unique | .[]' "$SETTINGS")"
  [ -n "$names" ]

  for name in $names; do
    [ -f "$HOOKS_DIR/$name" ] || { printf 'registered SessionStart hook is missing: %s\n' "$name" >&2; return 1; }
    for src in clear compact startup resume; do
      run env HOME="$home" PATH="$stub:$PATH" CLAUDE_PROJECT_DIR="$ALF_ROOT" \
        GAIA_DISABLE_NETWORK=1 GH_TOKEN= GITHUB_TOKEN= \
        bash -c 'cd "$1" && printf "%s" "$2" | bash "$3" >/dev/null 2>&1; exit 0' _ "$ALF_ROOT" \
        "$(jq -n -c --arg s "$src" --arg c "$ALF_ROOT" --arg t "$BATS_TEST_TMPDIR/transcript.jsonl" \
          '{session_id: "sess-a", transcript_path: $t, cwd: $c, hook_event_name: "SessionStart", source: $s}')" \
        "$HOOKS_DIR/$name"
      cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/state.saved" || { printf 'state changed after %s source=%s\n' "$name" "$src" >&2; return 1; }
    done
  done

  alf_set_line other.txt 99 "after sessions"
  alf_commit "after sessions"
  run env PATH="$stub:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ \
    "$(jq -n -c --arg r "$ALF_ROOT" '{session_id: "sess-other", hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $r,
      tool_input: {subagent_type: "code-audit-frontend", prompt: ("Audit the change. Working root: " + $r + ", base main")}}')" \
    "$BOUND_HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  grep -qF -- 'audit checkpoint' <<<"$output"
}
