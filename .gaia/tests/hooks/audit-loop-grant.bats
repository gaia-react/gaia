#!/usr/bin/env bats
#
# Suite for .claude/hooks/audit-loop-grant.sh, the UserPromptSubmit hook that
# records a human's answer to an audit checkpoint. Every case drives the hook
# by direct invocation with a fixture payload and a fixture transcript.
#
# AUDIT_LOOP_GRANT_HOOK points the suite at a scratch copy of the hook (its
# libraries reached through a `.gaia` symlink beside it), which is how a mutant
# is run against it without touching the working file. GRANT_BASH selects the
# interpreter the hook runs under, so the same suite proves the hook under
# stock /bin/bash 3.2.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-grant.bats < /dev/null
#      GRANT_BASH=/bin/bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-grant.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${AUDIT_LOOP_GRANT_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-grant.sh}"
  BASH_BIN="$(command -v "${GRANT_BASH:-bash}")"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/grant
  TX_CLI="$BATS_TEST_TMPDIR/tx-cli.jsonl"
  TX_SDK="$BATS_TEST_TMPDIR/tx-sdk.jsonl"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"cli","sessionId":"s1"}' >"$TX_CLI"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"sdk-cli","sessionId":"s1"}' >"$TX_SDK"
}

# seed_pending: five recorded rounds and a pending checkpoint at round 5,
# recorded by session s1.
seed_pending() {
  local round_number
  alf_fill f.txt 5 x
  for round_number in 1 2 3 4 5; do
    alf_set_line other.txt "$round_number" "round $round_number"
    alf_commit "round $round_number"
    alf_add_round '["code-audit-frontend"]'
  done
  alf_add_checkpoint 5 allowance
}

# payload <prompt> [cwd] [session] [transcript]: a UserPromptSubmit payload.
payload() {
  "$HELPERS/mock-hook-input.sh" user-prompt-submit "${3:-s1}" "$1" |
    jq -c --arg cwd "${2:-$ALF_ROOT}" --arg transcript_path "${4:-$TX_CLI}" '.cwd = $cwd | .transcript_path = $transcript_path'
}

# send <prompt> [cwd] [session] [transcript]: deliver it to the hook.
send() {
  local payload_json
  payload_json="$(payload "$@")"
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$payload_json" "$HOOK" "$BASH_BIN"
}

# snapshot / unchanged: the state file byte-identical across a call.
snapshot() { cp "$ALF_STATE" "$BATS_TEST_TMPDIR/before.json"; }
unchanged() { cmp -s "$BATS_TEST_TMPDIR/before.json" "$ALF_STATE"; }

allowed() { gaia_loop_allowed "$(cat "$ALF_STATE")"; }

@test "a grant at a pending checkpoint records once, raises the allowance and leaves history alone" {
  seed_pending
  jq -S .history "$ALF_STATE" >"$BATS_TEST_TMPDIR/history-before"
  [ "$(allowed)" = 5 ]
  send 'audit-grant 2'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  [ "$(jq -r '.allowance.answers[0] | "\(.checkpoint) \(.kind) \(.n) \(.session_id)"' "$ALF_STATE")" = "1 grant 2 s1" ]
  [ "$(allowed)" = 7 ]
  jq -S .history "$ALF_STATE" >"$BATS_TEST_TMPDIR/history-after"
  cmp -s "$BATS_TEST_TMPDIR/history-before" "$BATS_TEST_TMPDIR/history-after"
  printf '%s' "$output" | jq -e '(.systemMessage | length) > 0 and (.hookSpecificOutput.additionalContext | length) > 0'
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"'
  printf '%s' "$output" | grep -qF 'feat/grant'
  printf '%s' "$output" | grep -qF '7'
}

@test "an sdk-cli transcript (the nested claude -p shape) records nothing and says not interactive" {
  seed_pending
  snapshot
  send 'audit-grant 3' "$ALF_ROOT" s1 "$TX_SDK"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
  printf '%s' "$output" | grep -qF 'systemMessage'
}

@test "a missing transcript file records nothing and says not interactive" {
  seed_pending
  snapshot
  send 'audit-grant 3' "$ALF_ROOT" s1 "$BATS_TEST_TMPDIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "a transcript path that is a directory records nothing" {
  seed_pending
  snapshot
  send 'audit-grant 3' "$ALF_ROOT" s1 "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "the first record carrying an entrypoint decides: sdk-cli first, cli later is not interactive" {
  seed_pending
  printf '%s\n' '{"type":"user","entrypoint":"sdk-cli"}' '{"type":"user","entrypoint":"cli"}' >"$BATS_TEST_TMPDIR/tx-mixed.jsonl"
  snapshot
  send 'audit-grant 3' "$ALF_ROOT" s1 "$BATS_TEST_TMPDIR/tx-mixed.jsonl"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "a cli transcript whose first records lack entrypoint still records when every entrypoint is cli" {
  seed_pending
  printf '%s\n' '{"type":"summary"}' '{"type":"queue"}' '{"type":"user","entrypoint":"cli"}' '{"type":"user","entrypoint":"cli"}' >"$BATS_TEST_TMPDIR/tx-late.jsonl"
  send 'audit-grant 1' "$ALF_ROOT" s1 "$BATS_TEST_TMPDIR/tx-late.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "a cli transcript that a later claude -p resume appended an sdk-cli record to records nothing" {
  seed_pending
  printf '%s\n' '{"type":"user","entrypoint":"cli"}' '{"type":"user","entrypoint":"sdk-cli"}' >"$BATS_TEST_TMPDIR/tx-resumed.jsonl"
  snapshot
  send 'audit-grant 1' "$ALF_ROOT" s1 "$BATS_TEST_TMPDIR/tx-resumed.jsonl"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "a CLAUDE_CODE_ENTRYPOINT other than cli, or unset, records nothing even over a cli transcript" {
  seed_pending
  snapshot
  CLAUDE_CODE_ENTRYPOINT=sdk-cli send 'audit-grant 1'
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
  unset CLAUDE_CODE_ENTRYPOINT
  send 'audit-grant 1'
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'not interactive'
}

@test "a grant line pasted inside longer text is rejected visibly and records nothing" {
  seed_pending
  snapshot
  send 'please run audit-grant 3 now'
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'audit-grant <n>'
}

@test "invocation with argv and empty stdin exits 1" {
  seed_pending
  snapshot
  run bash -c 'printf "" | "$2" "$1" extra' _ "$HOOK" "$BASH_BIN"
  [ "$status" -eq 1 ]
  unchanged
}

@test "invocation with argv and a valid payload exits 1 and records nothing" {
  seed_pending
  snapshot
  run bash -c 'printf %s "$1" | "$3" "$2" audit-grant' _ "$(payload 'audit-grant 2')" "$HOOK" "$BASH_BIN"
  [ "$status" -eq 1 ]
  unchanged
}

@test "empty stdin with no argv exits 1" {
  run bash -c 'printf "" | "$2" "$1"' _ "$HOOK" "$BASH_BIN"
  [ "$status" -eq 1 ]
}

@test "a PostToolUse payload naming the keyword exits 1 and records nothing" {
  seed_pending
  snapshot
  run bash -c '"$1" post-tool-use s1 Bash "echo audit-grant 3" | "$3" "$2"' _ "$HELPERS/mock-hook-input.sh" "$HOOK" "$BASH_BIN"
  [ "$status" -eq 1 ]
  unchanged
}

@test "rejected spellings record nothing and each names the accepted forms" {
  seed_pending
  snapshot
  local prompt_text
  for prompt_text in 'audit-grant 0' 'audit-grant 11' 'audit-grant abc' 'what does audit-grant 3 do?' 'audit-grant  2' 'audit-grant 02'; do
    send "$prompt_text"
    [ "$status" -eq 0 ]
    unchanged
    printf '%s' "$output" | grep -qF 'audit-grant <n>'
    printf '%s' "$output" | grep -qF 'audit-accept'
  done
}

@test "exactly audit-grant 10 and surrounding whitespace are accepted" {
  seed_pending
  send "  audit-grant 10 "
  [ "$status" -eq 0 ]
  [ "$(allowed)" = 15 ]
}

@test "a recorded grant lands in the state file under protected/audit-loop and the old state directory stays absent" {
  local OLD_STATE_DIRECTORY="$ALF_ROOT/.gaia/local/audit-loop"
  seed_pending
  send 'audit-grant 2'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.allowance.answers[0] | "\(.kind) \(.n)"' "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/grant.json")" = "grant 2" ]
  [ -e "$OLD_STATE_DIRECTORY" ] && return 1
  true
}

@test "a branch with no pending checkpoint records nothing and says none is pending" {
  seed_pending
  alf_git checkout -q -b feat/other main
  snapshot
  send 'audit-grant 2' "$ALF_ROOT" s2
  [ "$status" -eq 0 ]
  cp "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/grant.json" "$BATS_TEST_TMPDIR/after.json"
  [ "$(jq '.allowance.answers | length' "$BATS_TEST_TMPDIR/after.json")" -eq 0 ]
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending on branch feat/other for this session'
}

@test "a second grant after the first is answered records nothing" {
  seed_pending
  send 'audit-grant 2'
  [ "$status" -eq 0 ]
  snapshot
  send 'audit-grant 2'
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending'
}

@test "an accept at a pending checkpoint records one accept and allows one closing round" {
  seed_pending
  send 'audit-accept'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  [ "$(jq -r '.allowance.answers[0].kind' "$ALF_STATE")" = accept ]
  [ "$(allowed)" = 6 ]
  printf '%s' "$output" | grep -qF 'no fixer runs'
}

@test "the lines a deny message prints classify and record" {
  seed_pending
  local deny_message grant accept
  deny_message="BLOCKED: audit checkpoint on branch feat/grant after 5 rounds (allowance).
Grant (type exactly as the whole prompt): $(gaia_loop_grant_line 3)
Accept (type exactly as the whole prompt): $(gaia_loop_accept_line)"
  grant="$(printf '%s\n' "$deny_message" | sed -n 's/^Grant (type exactly as the whole prompt): //p')"
  accept="$(printf '%s\n' "$deny_message" | sed -n 's/^Accept (type exactly as the whole prompt): //p')"
  [ "$grant" = 'audit-grant 3' ]
  [ "$accept" = 'audit-accept' ]
  send "$grant"
  [ "$status" -eq 0 ]
  [ "$(allowed)" = 8 ]
  alf_add_checkpoint 8 allowance
  send "$accept"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.allowance.answers[1].kind' "$ALF_STATE")" = accept ]
  [ "$(allowed)" = 9 ]
}

@test "a prompt without either keyword exits 0 silently before any jq or git call" {
  seed_pending
  local shims="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$shims"
  printf '#!/bin/sh\n: >"%s/jq-ran"\n' "$BATS_TEST_TMPDIR" >"$shims/jq"
  printf '#!/bin/sh\n: >"%s/git-ran"\n' "$BATS_TEST_TMPDIR" >"$shims/git"
  chmod +x "$shims/jq" "$shims/git"
  run bash -c 'printf %s "$1" | PATH="$3" "$4" "$2"' _ "$(payload 'hello there')" "$HOOK" "$shims" "$BASH_BIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -e "$BATS_TEST_TMPDIR/jq-ran" ] && return 1
  [ -e "$BATS_TEST_TMPDIR/git-ran" ] && return 1
  return 0
}

@test "jq absent: the line records nothing and says jq is missing; a keyword-free prompt is silent" {
  seed_pending
  snapshot
  local empty="$BATS_TEST_TMPDIR/nopath"
  mkdir -p "$empty"
  run bash -c 'printf %s "$1" | PATH="$3" "$4" "$2"' _ "$(payload 'audit-grant 2')" "$HOOK" "$empty" "$BASH_BIN"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'jq is missing'
  run bash -c 'printf %s "$1" | PATH="$3" "$4" "$2"' _ "$(payload 'hello')" "$HOOK" "$empty" "$BASH_BIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "worktree-audited shape: a main-checkout session answers the checkpoint its own session hit" {
  seed_pending
  alf_git checkout -q main
  send 'audit-grant 2' "$ALF_ROOT" s1
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  [ "$(allowed)" = 7 ]
}

@test "two pending checkpoints with the same session id record nothing" {
  seed_pending
  jq '.key = "branch:feat/second" | .branch = "feat/second"' "$ALF_STATE" >"$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json"
  alf_git checkout -q main
  snapshot
  cp "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json" "$BATS_TEST_TMPDIR/second-before.json"
  send 'audit-grant 2' "$ALF_ROOT" s1
  [ "$status" -eq 0 ]
  unchanged
  cmp -s "$BATS_TEST_TMPDIR/second-before.json" "$ALF_ROOT/.gaia/local/protected/audit-loop/feat/second.json"
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending'
}

@test "a different session id on the main checkout records nothing and names the session rule" {
  seed_pending
  alf_git checkout -q main
  snapshot
  send 'audit-grant 2' "$ALF_ROOT" other-session
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'for this session'
  printf '%s' "$output" | grep -qF 'session whose dispatch hit the checkpoint'
}

@test "corrupt state: a message names the file and the file is untouched" {
  seed_pending
  printf '{ not json' >"$ALF_STATE"
  snapshot
  send 'audit-grant 2'
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF "$ALF_STATE"
  printf '%s' "$output" | grep -qF 'corrupt'
}

@test "a held lock past the deadline records nothing and asks for a retry" {
  seed_pending
  snapshot
  mkdir "$ALF_STATE.lock"
  send 'audit-grant 2'
  rmdir "$ALF_STATE.lock"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'Retry'
}

@test "the hook parses under stock bash and never exits 2" {
  /bin/bash -n "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
  grep -nE '^[[:space:]]*exit 2' "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh" && return 1
  return 0
}

# seed_capped: ten recorded rounds and a pending checkpoint at round 10.
seed_capped() {
  local round_number
  alf_fill f.txt 5 x
  for round_number in 1 2 3 4 5 6 7 8 9 10; do
    alf_set_line other.txt "$round_number" "round $round_number"
    alf_commit "round $round_number"
    alf_add_round '["code-audit-frontend"]'
  done
  alf_add_checkpoint 10 allowance
}

@test "UAT-013: a typed grant below round 10 records as today and carries source typed" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  seed_pending
  send "audit-grant $GAIA_CONTEXT_UNIT_ROUNDS"
  [ "$status" -eq 0 ]
  jq -e --argjson unit_rounds "$GAIA_CONTEXT_UNIT_ROUNDS" '.allowance.answers | length == 1 and .[0].kind == "grant" and .[0].n == $unit_rounds and .[0].source == "typed"' "$ALF_STATE"
}

@test "a typed accept carries source typed" {
  seed_pending
  send 'audit-accept'
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers | length == 1 and .[0].kind == "accept" and .[0].source == "typed"' "$ALF_STATE"
}

@test "a typed grant at 10 rounds used records, since past the cap each unit runs on a human answer" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  seed_capped
  send "audit-grant $GAIA_CONTEXT_UNIT_ROUNDS"
  [ "$status" -eq 0 ]
  jq -e --argjson unit_rounds "$GAIA_CONTEXT_UNIT_ROUNDS" '.allowance.answers | length == 1 and .[0].kind == "grant" and .[0].n == $unit_rounds and .[0].source == "typed"' "$ALF_STATE"
}

@test "a typed accept at 10 rounds used still records, as the deliberate override" {
  seed_capped
  send 'audit-accept'
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers | length == 1 and .[0].kind == "accept" and .[0].source == "typed"' "$ALF_STATE"
}
