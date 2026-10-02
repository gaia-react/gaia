#!/usr/bin/env bats
#
# Suite for .claude/hooks/audit-loop-ask-grant.sh, the PostToolUse hook that
# records a human's selection of the question the bound hook pinned at an audit
# checkpoint. Every case drives the hook by direct invocation with a payload
# built from the redacted real capture in
# .gaia/tests/fixtures/askuserquestion-posttooluse.json, its question and
# answer replaced by the pinned question the lib builds.
#
# AUDIT_LOOP_ASK_GRANT_HOOK points the suite at a scratch copy of the hook (its
# libraries reached through a `.gaia` symlink beside it), which is how a mutant
# is run against it without touching the working file. K and the grant labels
# come from GAIA_CTX_UNIT_ROUNDS in the shared lib, never a literal.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-ask-grant.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# The jq programs and `bash -c` bodies are single-quoted so their `$` reaches
# the inner interpreter.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${AUDIT_LOOP_ASK_GRANT_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh}"
  FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/askuserquestion-posttooluse.json"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  K="$GAIA_CTX_UNIT_ROUNDS"
  NONCE=0123456789abcdef
  alf_init
  alf_branch feat/ask
  TX_CLI="$BATS_TEST_TMPDIR/tx-cli.jsonl"
  TX_SDK="$BATS_TEST_TMPDIR/tx-sdk.jsonl"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"cli","sessionId":"s1"}' >"$TX_CLI"
  printf '%s\n' '{"type":"mode","sessionId":"s1"}' '{"type":"user","entrypoint":"sdk-cli","sessionId":"s1"}' >"$TX_SDK"
}

# seed_rounds <n>: n recorded rounds on the feature branch.
seed_rounds() {
  local r
  alf_fill f.txt 5 x
  for r in $(seq 1 "$1"); do
    alf_set_line other.txt "$r" "round $r"
    alf_commit "round $r"
    alf_add_round '["code-audit-frontend"]'
  done
}

# pin_latest <nonce> <rounds> <eligible> <cap> <trigger>: pin the question on
# the latest checkpoint, as the bound hook does.
pin_latest() {
  local q
  q="$(gaia_loop_pinned_question "$ALF_B" "$1" "$2" "$K" "$3" "$4" "$5")"
  alf_state_edit '.history.checkpoints[-1] += {nonce: $n, trigger: $t, accept_eligible: $e, question: $q}' \
    --arg n "$1" --arg t "$5" --argjson e "$3" --argjson q "$q"
}

# seed_pinned [eligible] [cap]: five rounds and a pending, pinned checkpoint.
seed_pinned() {
  seed_rounds 5
  alf_add_checkpoint 5 context
  pin_latest "$NONCE" 5 "${1:-false}" "${2:-false}" context
}

state_pin() { jq -c '.history.checkpoints[-1].question' "$ALF_STATE"; }

continue_label() { printf 'Grant %s, continue here' "$K"; }
session_label() { printf 'Grant %s, new session' "$K"; }

# mk_payload <fixture-index> <label> [jq-filter]: the PostToolUse payload with
# the pinned question (PIN_USE, else the state's) asked and <label> answered,
# then <jq-filter> applied.
mk_payload() {
  local pin="${PIN_USE:-$(state_pin)}"
  jq -c --argjson i "$1" --argjson pin "$pin" --arg label "$2" --arg sid "${SID:-s1}" \
    --arg tx "${TX:-$TX_CLI}" --arg cwd "$ALF_ROOT" '
    .[$i]
    | .session_id = $sid | .transcript_path = $tx | .cwd = $cwd
    | .scratchpad_dir = "/scratch" | .prompt_id = "p"
    | ($pin.questions[0].question) as $q
    | .tool_input = ($pin + {answers: {($q): $label}, annotations: {}})
    | .tool_response = ($pin + {answers: {($q): $label}, annotations: {}})
    | '"${3:-.}" "$FIXTURE"
}

# send_payload <payload>: deliver it to the hook.
send_payload() {
  run bash -c 'printf %s "$1" | "$2"' _ "$1" "$HOOK"
}

# send <label> [jq-filter]: answer the pinned question with <label>.
send() {
  send_payload "$(mk_payload 0 "$1" "${2:-.}")"
}

snap() { cp "$ALF_STATE" "$BATS_TEST_TMPDIR/before.json"; }
unchanged() { cmp -s "$BATS_TEST_TMPDIR/before.json" "$ALF_STATE"; }

# declined <why>: the hook exited 0, left the state byte-identical, said
# nothing was recorded and named the typed fallback.
declined() {
  [ "$status" -eq 0 ] || { printf 'status %s for %s\n' "$status" "$1" >&2; return 1; }
  unchanged || { printf 'state changed for %s\n' "$1" >&2; return 1; }
  printf '%s' "$output" | jq -e '.systemMessage | length > 0' >/dev/null || { printf 'no systemMessage for %s: %s\n' "$1" "$output" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'Nothing was recorded' || { printf 'no decline text for %s: %s\n' "$1" "$output" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'audit-grant' || { printf 'fallback unnamed for %s\n' "$1" >&2; return 1; }
  printf '%s' "$output" | grep -qF 'audit-accept' || { printf 'accept fallback unnamed for %s\n' "$1" >&2; return 1; }
}

# --- UAT-011: the record ------------------------------------------------------

@test "UAT-011: the pinned grant, selected by a main-thread cli session, records one answer" {
  seed_pinned
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  jq -e --argjson k "$K" --arg n "$NONCE" --arg o "$(continue_label)" \
    '.allowance.answers[0] | .checkpoint == 1 and .kind == "grant" and .n == $k and .source == "ask" and .option == $o and .nonce == $n' "$ALF_STATE"
  printf '%s' "$output" | jq -e '(.systemMessage | length) > 0 and .hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length) > 0'
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = "$((5 + K))" ]
}

@test "every recorded answer carries at and the payload's session id" {
  seed_pinned true
  SID=s1 send "Accept the remainder"
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers[0] | (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and .session_id == "s1" and .kind == "accept" and .source == "ask"' "$ALF_STATE"
}

@test "Grant <k>, new session records the same answer shape as continue here and tells the main thread to print a prompt" {
  seed_pinned
  send "$(session_label)"
  [ "$status" -eq 0 ]
  jq -e --argjson k "$K" --arg o "$(session_label)" \
    '.allowance.answers[0] | .kind == "grant" and .n == $k and .source == "ask" and .option == $o and (keys | sort) == ["at","checkpoint","kind","n","nonce","option","session_id","source"]' "$ALF_STATE"
  printf '%s' "$output" | grep -qF 'fenced continuation prompt'
}

@test "Accept the remainder records kind accept only when it is in the pin" {
  seed_pinned true
  send "Accept the remainder"
  [ "$status" -eq 0 ]
  jq -e '.allowance.answers | length == 1 and .[0].kind == "accept" and (.[0] | has("n") | not) and .[0].option == "Accept the remainder"' "$ALF_STATE"
}

@test "an accept selected against a pin without it declines, and an accept option the pin lacks declines" {
  seed_pinned false
  snap
  send "Accept the remainder"
  declined "accept selected, not in the pin"
  local eligible_pin
  eligible_pin="$(gaia_loop_pinned_question "$ALF_B" "$NONCE" 5 "$K" true false context)"
  PIN_USE="$eligible_pin" send "Accept the remainder"
  declined "payload offers an accept option the pin lacks"
}

@test "Type audit-accept instead against a cap-ineligible pin records nothing and names typed audit-accept" {
  seed_rounds 10
  alf_add_checkpoint 10 cap
  pin_latest "$NONCE" 10 false true cap
  snap
  send "Type audit-accept instead"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'audit-accept'
  printf '%s' "$output" | grep -qF 'deliberate override'
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
}

@test "a grant label offered against a cap pin that does not carry it declines" {
  seed_rounds 10
  alf_add_checkpoint 10 cap
  pin_latest "$NONCE" 10 false true cap
  snap
  send "$(continue_label)"
  declined "grant label against a cap pin"
}

@test "UAT-030: Stop and file the remainder records nothing and names the file-and-report step" {
  seed_pinned
  snap
  send "Stop and file the remainder"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'file the remainder'
  printf '%s' "$output" | grep -qF 'leave the PR open'
  printf '%s' "$output" | grep -qF 'report'
  printf '%s' "$output" | jq -e '(.hookSpecificOutput.additionalContext | contains("Do not dispatch another audit round"))'
}

# --- UAT-012: every red state --------------------------------------------------

@test "UAT-012: Other free text records nothing" {
  seed_pinned
  snap
  send_payload "$(mk_payload 1 "free text probe")"
  declined "Other free text"
  send "free text probe"
  declined "Other free text, built payload"
}

@test "UAT-012: a label that is not in the pin records nothing" {
  seed_pinned
  snap
  send "Grant 99, continue here"
  declined "label not in the pin"
  send "grant"
  declined "partial label"
}

@test "UAT-012: a stale nonce (an older checkpoint's question) records nothing" {
  seed_pinned
  local old_pin
  old_pin="$(state_pin)"
  alf_add_checkpoint 5 context
  pin_latest fedcba9876543210 5 false false context
  snap
  PIN_USE="$old_pin" send "$(continue_label)"
  declined "stale nonce"
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 0 ]
}

@test "UAT-012: a wrong nonce records nothing" {
  seed_pinned
  snap
  PIN_USE="$(gaia_loop_pinned_question "$ALF_B" fedcba9876543210 5 "$K" false false context)" send "$(continue_label)"
  declined "wrong nonce"
}

@test "UAT-012: any change to the question the payload carries records nothing" {
  seed_pinned
  snap
  local name filter
  while IFS='|' read -r name filter; do
    send "$(continue_label)" "$filter"
    declined "$name"
  done <<'CASES'
changed question text|.tool_input.questions[0].question += " (edited)"
changed header|.tool_input.questions[0].header = "Edited"
changed option description|.tool_input.questions[0].options[0].description += " edited"
multiSelect true|.tool_input.questions[0].multiSelect = true
a second question|.tool_input.questions += [.tool_input.questions[0]]
an extra top-level key|.tool_input.extra = 1
a dropped option|.tool_input.questions[0].options |= .[1:]
CASES
}

@test "UAT-012: an agent_id on the payload records nothing" {
  seed_pinned
  snap
  send "$(continue_label)" '.agent_id = "agent-1"'
  declined "agent_id present"
  printf '%s' "$output" | grep -qF 'sub-agent'
}

@test "UAT-012: CLAUDE_CODE_ENTRYPOINT other than cli, or unset, records nothing" {
  seed_pinned
  snap
  CLAUDE_CODE_ENTRYPOINT=sdk-cli send "$(continue_label)"
  declined "sdk-cli entrypoint"
  printf '%s' "$output" | grep -qF 'not interactive'
  unset CLAUDE_CODE_ENTRYPOINT
  send "$(continue_label)"
  declined "entrypoint unset"
}

@test "UAT-012: a transcript with a non-cli entrypoint, or none, records nothing" {
  seed_pinned
  snap
  TX="$TX_SDK" send "$(continue_label)"
  declined "sdk-cli transcript"
  TX="$BATS_TEST_TMPDIR/no-such.jsonl" send "$(continue_label)"
  declined "missing transcript"
}

@test "UAT-012: a permission mode outside the allowlist, an unmeasured one, or none records nothing" {
  seed_pinned
  snap
  send "$(continue_label)" '.permission_mode = "dontAsk"'
  declined "dontAsk"
  send "$(continue_label)" '.permission_mode = "somethingNew"'
  declined "unmeasured mode"
  send "$(continue_label)" 'del(.permission_mode)'
  declined "permission_mode absent"
  send "$(continue_label)" '.permission_mode = ""'
  declined "empty permission_mode"
}

@test "every allowlisted permission mode records" {
  local mode count=0
  seed_pinned
  for mode in default acceptEdits plan auto bypassPermissions; do
    alf_state_edit '.allowance.answers = []'
    send "$(continue_label)" ".permission_mode = \"$mode\""
    [ "$status" -eq 0 ]
    [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ] || { printf 'mode %s did not record: %s\n' "$mode" "$output" >&2; return 1; }
    count=$((count + 1))
  done
  [ "$count" -eq 5 ]
}

@test "a checkpoint without a pinned question records nothing and says so" {
  seed_rounds 5
  alf_add_checkpoint 5 allowance
  snap
  PIN_USE="$(gaia_loop_pinned_question "$ALF_B" "$NONCE" 5 "$K" false false context)" send "$(continue_label)"
  declined "no pinned question"
  printf '%s' "$output" | grep -qF 'no pinned question'
}

# --- replay, scope, silence ----------------------------------------------------

@test "replay: the same valid payload sent twice records once and the second says nothing is pending" {
  seed_pinned
  local p
  p="$(mk_payload 0 "$(continue_label)")"
  send_payload "$p"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  snap
  send_payload "$p"
  declined "replay"
  printf '%s' "$output" | grep -qF 'no audit checkpoint is pending'
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "worktree-audited shape: a main-checkout session answers the checkpoint its own session hit" {
  seed_pinned
  alf_git checkout -q main
  send "$(continue_label)"
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "a different session id on the main checkout records nothing and stays silent about an unrelated question" {
  seed_pinned
  alf_git checkout -q main
  snap
  SID=other-session send "$(continue_label)"
  [ "$status" -eq 0 ]
  unchanged
  [ -z "$output" ]
}

@test "two pending checkpoints with the same session id record nothing" {
  seed_pinned
  jq '.key = "branch:feat/second" | .branch = "feat/second"' "$ALF_STATE" >"$ALF_ROOT/.gaia/local/audit-loop/feat/second.json"
  alf_git checkout -q main
  snap
  cp "$ALF_ROOT/.gaia/local/audit-loop/feat/second.json" "$BATS_TEST_TMPDIR/second-before.json"
  send "$(continue_label)"
  declined "ambiguous"
  cmp -s "$BATS_TEST_TMPDIR/second-before.json" "$ALF_ROOT/.gaia/local/audit-loop/feat/second.json"
}

@test "a tool that is not AskUserQuestion, or no audit state at all, exits 0 silently" {
  seed_pinned
  local valid
  valid="$(mk_payload 0 "$(continue_label)")"
  snap
  send_payload "$(mk_payload 0 "$(continue_label)" '.tool_name = "Bash"')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unchanged
  rm -rf "$ALF_ROOT/.gaia/local/audit-loop"
  send_payload "$valid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invocation with argv, or with empty stdin, exits 1 and records nothing" {
  seed_pinned
  snap
  run bash -c 'printf %s "$1" | "$2" extra' _ "$(mk_payload 0 "$(continue_label)")" "$HOOK"
  [ "$status" -eq 1 ]
  run bash -c 'printf "" | "$1"' _ "$HOOK"
  [ "$status" -eq 1 ]
  unchanged
}

@test "jq absent: the hook records nothing, says jq is missing and names the typed fallback" {
  seed_pinned
  snap
  local empty="$BATS_TEST_TMPDIR/nopath"
  mkdir -p "$empty"
  run bash -c 'printf %s "$1" | PATH="$3" "$(command -v bash)" "$2"' _ "$(mk_payload 0 "$(continue_label)")" "$HOOK" "$empty"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'jq is missing'
  printf '%s' "$output" | grep -qF 'audit-grant'
}

@test "corrupt state: the message names the file and the file is untouched" {
  seed_pinned
  local p
  p="$(mk_payload 0 "$(continue_label)")"
  printf '{ not json' >"$ALF_STATE"
  snap
  send_payload "$p"
  [ "$status" -eq 0 ]
  unchanged
  printf '%s' "$output" | grep -qF 'corrupt'
}

# --- concurrency ---------------------------------------------------------------

@test "two recorders racing the same payload record at most once" {
  seed_pinned
  local p
  p="$(mk_payload 0 "$(continue_label)")"
  bash -c 'printf %s "$1" | "$2" >"$3/out-a" 2>&1' _ "$p" "$HOOK" "$BATS_TEST_TMPDIR" &
  local pid_a=$!
  bash -c 'printf %s "$1" | "$2" >"$3/out-b" 2>&1' _ "$p" "$HOOK" "$BATS_TEST_TMPDIR" &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
  grep -qF 'Recorded' "$BATS_TEST_TMPDIR/out-a" "$BATS_TEST_TMPDIR/out-b"
  grep -lF 'no audit checkpoint is pending' "$BATS_TEST_TMPDIR/out-a" "$BATS_TEST_TMPDIR/out-b"
}

@test "a held lock past the deadline records nothing and is a visible decline" {
  seed_pinned
  snap
  mkdir "$ALF_STATE.lock"
  send "$(continue_label)"
  rmdir "$ALF_STATE.lock"
  declined "held lock"
  printf '%s' "$output" | grep -qF 'locked'
}

# --- the hook itself -----------------------------------------------------------

@test "the hook parses under stock bash and never exits 2" {
  /bin/bash -n "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh"
  grep -nE '^[[:space:]]*exit 2' "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  true
}

# header_has_literals <file>: the comment block before `set -u` names both.
header_has_literals() {
  local header
  header="$(sed -n '1,/^set -u$/p' "$1")"
  [ -n "$header" ] || return 1
  printf '%s' "$header" | grep -qF 'AskUserQuestion' || return 1
  printf '%s' "$header" | grep -qF 'audit-grant' || return 1
}

@test "UAT-021: both recorder headers name AskUserQuestion and audit-grant, and a header without one fails the check" {
  header_has_literals "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh"
  header_has_literals "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh"
  local twin="$BATS_TEST_TMPDIR/grant-twin.sh"
  sed 's/AskUserQuestion/AskSomething/g' "$REPO_ROOT/.claude/hooks/audit-loop-grant.sh" >"$twin"
  header_has_literals "$twin" && return 1
  sed 's/audit-grant/audit-g/g' "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" >"$twin"
  header_has_literals "$twin" && return 1
  true
}

# --- mutants: each guard can fail ----------------------------------------------

# scratch_hook <sed-expression>: a scratch copy of the hook with its libraries
# reached through a `.gaia` symlink beside it; sets HOOK and proves the edit
# changed the copy.
scratch_hook() {
  local dir="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$dir/.claude/hooks"
  ln -s "$REPO_ROOT/.gaia" "$dir/.gaia"
  sed "$1" "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" >"$dir/.claude/hooks/audit-loop-ask-grant.sh"
  chmod +x "$dir/.claude/hooks/audit-loop-ask-grant.sh"
  cmp -s "$REPO_ROOT/.claude/hooks/audit-loop-ask-grant.sh" "$dir/.claude/hooks/audit-loop-ask-grant.sh" && return 1
  HOOK="$dir/.claude/hooks/audit-loop-ask-grant.sh"
}

@test "mutant: with the question-equality check disabled, a changed question records" {
  seed_pinned
  scratch_hook 's/== \$pin'"'"' >\/dev\/null/== $pin or true'"'"' >\/dev\/null/'
  send "$(continue_label)" '.tool_input.questions[0].header = "Edited"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "mutant: with the agent_id check disabled, a sub-agent payload records" {
  seed_pinned
  scratch_hook 's/ != false \]; then/ = nope ]; then/'
  send "$(continue_label)" '.agent_id = "agent-1"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}

@test "mutant: with the permission-mode allowlist emptied of its check, an unmeasured mode records" {
  seed_pinned
  scratch_hook 's/\*" \$mode "\*) ;;/*) ;;/'
  send "$(continue_label)" '.permission_mode = "somethingNew"'
  [ "$status" -eq 0 ]
  [ "$(jq '.allowance.answers | length' "$ALF_STATE")" -eq 1 ]
}
