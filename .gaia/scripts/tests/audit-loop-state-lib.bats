#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-loop-state-lib.sh: branch keying, state paths,
# schema-1 validation, the lock, atomic writes, the audited-root resolver and
# the grant/accept line grammar.
#
# AUDIT_LOOP_SCRIPTS_DIR points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-state-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIR:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  alf_init
}

# stub_git <branch-output>: a `git` on PATH whose `branch --show-current`
# prints <branch-output>.
stub_git() {
  local d="$BATS_TEST_TMPDIR/stub-git"
  mkdir -p "$d"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" >"$d/git"
  chmod +x "$d/git"
  printf '%s\n' "$d"
}

valid_state() {
  jq -n -c --arg t "$(alf_git rev-parse 'HEAD^{tree}')" --arg c "$(alf_git rev-parse HEAD)" \
    '{schema: 1, key: "branch:feat/x", branch: "feat/x", pr: null,
      history: {knobs: {checkpoint_round: 5, grant_rounds: 3},
                rounds: [{round: 1, tree: $t, commit: $c, members: ["code-audit-frontend"], closing: false, snapshot: null}],
                checkpoints: []},
      allowance: {answers: []}}'
}

@test "key: a branch and its worktree spelling normalize to one key" {
  alf_branch debt/42-fix
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "debt/42-fix" ]
  alf_git checkout -q -b worktree-debt+42-fix
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "debt/42-fix" ]
}

@test "key: a detached HEAD is rc 4" {
  alf_git checkout -q --detach
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "key: a name that cannot key a state file is rc 5" {
  local d bad
  d="$(stub_git x)"
  for bad in 'feat/a..b' 'feat//x' '/lead' 'trail/' 'sp ace' "$(printf 'x%.0s' $(seq 1 129))"; do
    d="$(stub_git "$bad")"
    PATH="$d:$PATH" run gaia_loop_key "$ALF_ROOT"
    [ "$status" -eq 5 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "key: git absent from PATH is rc 6" {
  # A fresh shell: this one has git hashed, and bash 3.2 keeps the hash
  # across a command-scoped PATH.
  PATH="$(path_shim_without git)" run bash -c '. "$1"; gaia_loop_key "$2"' _ "$SCRIPTS/audit-loop-state-lib.sh" "$ALF_ROOT"
  [ "$status" -eq 6 ]
}

@test "state path: colliding slugs a/b-c and a-b/c get distinct state files" {
  local p1 p2
  p1="$(gaia_loop_state_file /m a/b-c)"
  p2="$(gaia_loop_state_file /m a-b/c)"
  [ "$p1" = "/m/.gaia/local/audit-loop/a/b-c.json" ]
  [ "$p2" = "/m/.gaia/local/audit-loop/a-b/c.json" ]
  [ "$p1" != "$p2" ]
}

@test "read: a valid file reads back; an absent file is rc 1" {
  local f="$BATS_TEST_TMPDIR/s/x.json"
  run gaia_loop_read_state "$f"
  [ "$status" -eq 1 ]
  gaia_loop_write_state "$f" "$(valid_state)"
  run gaia_loop_read_state "$f"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.history.rounds | length')" = 1 ]
}

@test "read and write: every corrupt shape is rc 5, prints nothing, and never replaces a file" {
  local f="$BATS_TEST_TMPDIR/s/x.json" bad="$BATS_TEST_TMPDIR/bad.json" snap name json n=0
  gaia_loop_write_state "$f" "$(valid_state)"
  snap="$(snapshot_file "$f")"
  while IFS='|' read -r name json; do
    n=$((n + 1))
    printf '%s' "$json" >"$bad"
    run gaia_loop_read_state "$bad"
    [ "$status" -eq 5 ] || { echo "read accepted: $name"; return 1; }
    [ -z "$output" ] || { echo "read printed for: $name"; return 1; }
    run gaia_loop_write_state "$f" "$json"
    [ "$status" -ne 0 ] || { echo "write accepted: $name"; return 1; }
    assert_files_identical "$snap" "$f" || { echo "file changed by: $name"; return 1; }
  done <<EOF
invalid json|{"schema":1,
schema 2|$(valid_state | jq -c '.schema = 2')
missing history.rounds|$(valid_state | jq -c 'del(.history.rounds)')
non-hex tree|$(valid_state | jq -c '.history.rounds[0].tree = "HEAD"')
missing knobs with rounds|$(valid_state | jq -c 'del(.history.knobs)')
pr not an integer|$(valid_state | jq -c '.pr = "12"')
two documents|$(valid_state) $(valid_state)
EOF
  [ "$n" -eq 7 ]
}

@test "lock: two concurrent writers both land" {
  local f="$BATS_TEST_TMPDIR/s/x.json" t1 t2
  gaia_loop_write_state "$f" "$(valid_state)"
  t1="$(printf '1%.0s' $(seq 1 40))"
  t2="$(printf '2%.0s' $(seq 1 40))"
  writer() {
    gaia_loop_lock "$f" $(($(date +%s) + 20)) || return 1
    local s
    s="$(gaia_loop_read_state "$f")"
    sleep 0.3
    gaia_loop_write_state "$f" "$(printf '%s' "$s" | jq -c --arg t "$1" '.history.rounds += [.history.rounds[0] + {tree: $t}]')"
    gaia_loop_unlock "$f"
  }
  writer "$t1" &
  writer "$t2" &
  wait
  run jq -r '[.history.rounds[].tree] | join(",")' "$f"
  [ "$(jq '.history.rounds | length' "$f")" -eq 3 ]
  case "$output" in *"$t1"*) ;; *) return 1 ;; esac
  case "$output" in *"$t2"*) ;; *) return 1 ;; esac
  [ ! -d "$f.lock" ]
}

@test "lock: a stale lock is broken; a fresh held lock past the deadline is rc 1" {
  local f="$BATS_TEST_TMPDIR/s/x.json"
  mkdir -p "$f.lock"
  touch -t "$(alf_time 0)" "$f.lock"
  run gaia_loop_lock "$f" $(($(date +%s) + 5))
  [ "$status" -eq 0 ]
  [ -d "$f.lock" ]
  run gaia_loop_lock "$f" $(($(date +%s) + 1))
  [ "$status" -eq 1 ]
  gaia_loop_unlock "$f"
  [ ! -d "$f.lock" ]
}

@test "audited root: the prompt's Working root wins over cwd; cwd is the fallback" {
  local wt payload
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  wt="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "Audit this. Working root: $wt, the absolute path of the checkout." \
    '{cwd: $c, tool_input: {prompt: $p}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$wt" ]
  payload="$(jq -n -c --arg c "$ALF_ROOT" '{cwd: $c, tool_input: {prompt: "no root named here"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$ALF_ROOT" ]
}

@test "audited root: a prose-punctuated or quoted Working root resolves to the named checkout" {
  local wt payload p
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  wt="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  for p in "Working root: $wt. Audit the PR." "Working root: $wt; base main" "Working root: \`$wt\`." \
    "Working root: \"$wt\"" "(Working root: $wt)"; do
    payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "$p" '{cwd: $c, tool_input: {prompt: $p}}')"
    run gaia_loop_resolve_audited_root "$payload"
    [ "$status" -eq 0 ] || { printf 'prompt %s: status %s\n' "$p" "$status" >&2; return 1; }
    [ "$output" = "$wt" ] || { printf 'prompt %s: output %s\n' "$p" "$output" >&2; return 1; }
  done
}

@test "audited root: a named Working root that does not resolve is rc 2 naming it, never the cwd" {
  local payload
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "Working root: $BATS_TEST_TMPDIR/nogit, the path" \
    '{cwd: $c, tool_input: {prompt: $p}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 2 ]
  [ "$output" = "$BATS_TEST_TMPDIR/nogit" ]
  payload="$(jq -n -c --arg c "$ALF_ROOT" '{cwd: $c, tool_input: {prompt: "Working root: rel/path, x"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 2 ]
  [ "$output" = "rel/path" ]
}

@test "audited root: no Working root and a relative cwd is rc 1" {
  local payload
  payload="$(jq -n -c '{cwd: "rel/dir", tool_input: {prompt: "no root named here"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "parse line: the grammar table, with PATH empty" {
  local text want got raw n=0
  while IFS='|' read -r text want; do
    n=$((n + 1))
    raw="$(printf '%bX' "$text")"
    raw="${raw%X}"
    got="$(PATH='' gaia_loop_parse_line "$raw")"
    [ "$got" = "$want" ] || { echo "'$text' gave '$got', want '$want'"; return 1; }
  done <<'EOF'
audit-grant 2|grant 2
audit-grant 10|grant 10
  audit-accept\n|accept
\t audit-grant 7\r\n|grant 7
audit-grant 0|malformed
audit-grant 11|malformed
audit-grant abc|malformed
audit-grant 02|malformed
audit-grant  2|malformed
audit-grant 2 please|malformed
what does audit-grant 3 do?|malformed
audit-accept now|malformed
audit-grant\t2|malformed
hello|none
|none
EOF
  [ "$n" -eq 15 ]
}

@test "parse line: the library's own lines parse back" {
  [ "$(gaia_loop_parse_line "$(gaia_loop_grant_line 3)")" = "grant 3" ]
  [ "$(gaia_loop_parse_line "$(gaia_loop_accept_line)")" = "accept" ]
  run gaia_loop_grant_line 11
  [ "$status" -ne 0 ]
}

@test "validators: oid, uint and safe relpath" {
  gaia_loop_is_oid "$(printf 'a%.0s' $(seq 1 40))"
  gaia_loop_is_oid "$(printf 'b%.0s' $(seq 1 64))"
  gaia_loop_is_oid "$(printf 'A%.0s' $(seq 1 40))" && return 1
  gaia_loop_is_oid "HEAD" && return 1
  gaia_loop_is_uint 0
  gaia_loop_is_uint 123456789
  gaia_loop_is_uint 01 && return 1
  gaia_loop_is_uint -1 && return 1
  gaia_loop_is_uint 1234567890 && return 1
  gaia_loop_is_safe_relpath a/b.txt
  gaia_loop_is_safe_relpath 'a b/c..d'
  gaia_loop_is_safe_relpath -rf && return 1
  gaia_loop_is_safe_relpath /etc/x && return 1
  gaia_loop_is_safe_relpath a/../b && return 1
  gaia_loop_is_safe_relpath .. && return 1
  gaia_loop_is_safe_relpath "$(printf 'a\nb')" && return 1
  gaia_loop_is_safe_relpath '' && return 1
  true
}

# ---- SPEC-093: optional schema fields, pinned question, nonce, interactive check

full_state() {
  valid_state | jq -c '
    .history.context_config = {ask_tokens: 300000, ask_window_pct: 50}
    | .history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context", after_checkpoint: 0, recorded_at: "2026-10-02T00:00:00Z", session_id: "s"}]
    | .history.checkpoints = [{index: 1, at_round: 3, nonce: "0123456789abcdef", trigger: "context", accept_eligible: false,
        question: {questions: [{question: "q"}]}}]
    | .allowance.answers = [{checkpoint: 1, kind: "grant", n: 3, source: "ask", option: "Grant 3, continue here", nonce: "0123456789abcdef", at: "t", session_id: "s"}]'
}

# assert_refused <label> <json>: read returns 5 and a write refuses, file unchanged.
assert_refused() {
  local f="$BATS_TEST_TMPDIR/refuse.json" rc
  valid_state >"$f"
  cp "$f" "$f.orig"
  printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/bad.json"
  gaia_loop_read_state "$BATS_TEST_TMPDIR/bad.json" >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 5 ] || { echo "$1: read rc $rc, want 5"; return 1; }
  gaia_loop_write_state "$f" "$2" && rc=0 || rc=$?
  [ "$rc" -eq 5 ] || { echo "$1: write rc $rc, want 5"; return 1; }
  cmp -s "$f" "$f.orig" || { echo "$1: file changed"; return 1; }
}

@test "schema: a state with every new optional field reads and writes" {
  local f="$BATS_TEST_TMPDIR/s.json"
  full_state >"$f"
  run gaia_loop_read_state "$f"
  [ "$status" -eq 0 ]
  run gaia_loop_write_state "$BATS_TEST_TMPDIR/o.json" "$(full_state)"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/o.json" ]
}

@test "schema: a legacy state round-trips byte-identically" {
  local f="$BATS_TEST_TMPDIR/legacy.json" o="$BATS_TEST_TMPDIR/out.json"
  valid_state | jq . >"$f"
  gaia_loop_write_state "$o" "$(gaia_loop_read_state "$f")"
  [ "$(jq -S -c . <"$f")" = "$(jq -S -c . <"$o")" ]
  gaia_loop_write_state "$BATS_TEST_TMPDIR/o2.json" "$(gaia_loop_read_state "$o")"
  cmp -s "$o" "$BATS_TEST_TMPDIR/o2.json"
}

@test "schema: red states for the new fields are corrupt and refused" {
  assert_refused pct150 "$(full_state | jq -c '.history.context_config.ask_window_pct = 150')"
  assert_refused tokens0 "$(full_state | jq -c '.history.context_config.ask_tokens = 0')"
  assert_refused magic "$(full_state | jq -c '.history.units[0].admitted_on = "magic"')"
  assert_refused inline "$(full_state | jq -c '.history.units[0].admitted_on = "inline"')"
  assert_refused noafter "$(full_state | jq -c 'del(.history.units[0].after_checkpoint)')"
  assert_refused badnonce "$(full_state | jq -c '.history.checkpoints[0].nonce = "XYZ"')"
  assert_refused twoq "$(full_state | jq -c '.history.checkpoints[0].question.questions += [{}]')"
  assert_refused badelig "$(full_state | jq -c '.history.checkpoints[0].accept_eligible = "yes"')"
  assert_refused forged "$(full_state | jq -c '.allowance.answers[0].source = "forged"')"
  assert_refused n11 "$(full_state | jq -c '.allowance.answers[0].n = 11')"
  assert_refused ansnonce "$(full_state | jq -c '.allowance.answers[0].nonce = "nope"')"
}

# opt_count <json>: number of options in the first question.
opt_count() { printf '%s' "$1" | jq '.questions[0].options | length'; }
# at_least_two_options <json>: the invariant every pinned question must hold.
at_least_two_options() { [ "$(opt_count "$1")" -ge 2 ]; }
labels() { printf '%s' "$1" | jq -r '[.questions[0].options[].label] | join("|")'; }

@test "pinned question: labels, order, header, single question" {
  local n=0123456789abcdef q
  q="$(gaia_loop_pinned_question feat/x $n 6 3 true false context)"
  [ "$(printf '%s' "$q" | jq '.questions | length')" -eq 1 ]
  [ "$(printf '%s' "$q" | jq -r '.questions[0].header')" = "Audit loop" ]
  [ "$(printf '%s' "$q" | jq '.questions[0].multiSelect')" = false ]
  [ "$(labels "$q")" = "Grant 3, continue here|Grant 3, new session|Accept the remainder|Stop and file the remainder" ]
  case "$(printf '%s' "$q" | jq -r '.questions[0].question')" in
    *"$n"*"feat/x"*"6 rounds used (context)"*) ;;
    *) return 1 ;;
  esac
  q="$(gaia_loop_pinned_question feat/x $n 6 2 true false context)"
  [ "$(labels "$q")" = "Grant 2, continue here|Grant 2, new session|Accept the remainder|Stop and file the remainder" ]
}

@test "pinned question: eligibility and cap shape the options, never fewer than two" {
  local n=0123456789abcdef q
  q="$(gaia_loop_pinned_question feat/x $n 6 3 false false context)"
  [ "$(labels "$q")" = "Grant 3, continue here|Grant 3, new session|Stop and file the remainder" ]
  q="$(gaia_loop_pinned_question feat/x $n 10 3 true true cap)"
  [ "$(labels "$q")" = "Accept the remainder|Stop and file the remainder" ]
  q="$(gaia_loop_pinned_question feat/x $n 10 3 false true cap)"
  [ "$(labels "$q")" = "Type audit-accept instead|Stop and file the remainder" ]
  local e c
  for e in true false; do
    for c in true false; do
      q="$(gaia_loop_pinned_question feat/x $n 6 3 $e $c rubric:J2)"
      at_least_two_options "$q"
      [[ "$(labels "$q")" == *"Stop and file the remainder" ]]
      [[ "$q" == *"$n"* ]]
    done
  done
  # The cap-ineligible description names the typed line as a deliberate override.
  q="$(gaia_loop_pinned_question feat/x $n 10 3 false true cap)"
  [[ "$q" == *"audit-accept"*"deliberate override"* ]]
}

@test "pinned question red twin: a builder without the cap-ineligible option fails the two-option check" {
  local mut="$BATS_TEST_TMPDIR/mut" q
  mkdir -p "$mut"
  cp "$SCRIPTS"/*.sh "$mut/"
  sed 's/if \$cap and (\$elig | not) then/if false then/' "$SCRIPTS/audit-loop-state-lib.sh" >"$mut/audit-loop-state-lib.sh"
  if cmp -s "$SCRIPTS/audit-loop-state-lib.sh" "$mut/audit-loop-state-lib.sh"; then return 1; fi
  q="$(bash -c '. "$1"; gaia_loop_pinned_question feat/x 0123456789abcdef 10 3 false true cap' _ "$mut/audit-loop-state-lib.sh")"
  [ "$(opt_count "$q")" -eq 1 ]
  run at_least_two_options "$q"
  [ "$status" -ne 0 ]
}

@test "pinned question: bad inputs are rc 2 with empty stdout" {
  run gaia_loop_pinned_question feat/x ZZZZ 6 3 true false context
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run gaia_loop_pinned_question a..b 0123456789abcdef 6 3 true false context
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run gaia_loop_pinned_question feat/x 0123456789abcdef 6 abc true false context
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 yes false context
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

question_text() { printf '%s' "$1" | jq -r '.questions[0].question'; }

@test "pinned question: a fresh reading puts the percent and k-token figures in the text" {
  local q
  q="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "fresh 123456 400000")"
  [ "$(question_text "$q")" = "Audit checkpoint 0123456789abcdef on feat/x: 6 rounds used (context), context 30% (123k of 400k). How should the audit loop continue?" ]
}

@test "pinned question: no reading, or an unusable one, reads context unavailable" {
  local r q
  q="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context)"
  [ "$(question_text "$q")" = "Audit checkpoint 0123456789abcdef on feat/x: 6 rounds used (context), context unavailable. How should the audit loop continue?" ]
  for r in missing stale future unparseable "fresh 5 0"; do
    q="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "$r")"
    [[ "$(question_text "$q")" == *"(context), context unavailable. How"* ]]
  done
}

@test "pinned question: a malformed context reading is rc 2 with empty stdout" {
  local r
  for r in "fresh 12" "fresh a b" "fresh 1 2 3" "bogus" "fresh -1 5"; do
    run gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "$r"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "nonce: two calls differ, are 16 hex, and pin different questions" {
  local a b qa qb
  a="$(gaia_loop_new_nonce)"
  b="$(gaia_loop_new_nonce)"
  [[ "$a" =~ ^[0-9a-f]{16}$ ]]
  [[ "$b" =~ ^[0-9a-f]{16}$ ]]
  [ "$a" != "$b" ]
  qa="$(gaia_loop_pinned_question feat/x "$a" 6 3 true false context)"
  qb="$(gaia_loop_pinned_question feat/x "$b" 6 3 true false context)"
  [ "$qa" != "$qb" ]
}

@test "pinned question: with the recorder off every grant and accept description names the typed line" {
  local mut="$BATS_TEST_TMPDIR/mut0" q
  mkdir -p "$mut"
  cp "$SCRIPTS"/*.sh "$mut/"
  sed 's/^_GAIA_LOOP_ASK_RECORDER=1$/_GAIA_LOOP_ASK_RECORDER=0/' "$SCRIPTS/audit-loop-state-lib.sh" >"$mut/audit-loop-state-lib.sh"
  q="$(bash -c '. "$1"; gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context' _ "$mut/audit-loop-state-lib.sh")"
  [ "$(printf '%s' "$q" | jq '[.questions[0].options[] | select(.label | startswith("Grant") or startswith("Accept")) | select(.description | test("type `audit-(grant 3|accept)`"))] | length')" -eq 3 ]
}

@test "interactive check: cli env and an all-cli transcript pass; every other shape fails" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  printf '{"entrypoint":"cli"}\n{"type":"x"}\n{"entrypoint":"cli"}\n' >"$t"
  CLAUDE_CODE_ENTRYPOINT=cli gaia_loop_session_is_interactive "$t"
  if CLAUDE_CODE_ENTRYPOINT=sdk-cli gaia_loop_session_is_interactive "$t"; then return 1; fi
  printf '{"entrypoint":"cli"}\n{"entrypoint":"sdk-cli"}\n' >"$BATS_TEST_TMPDIR/t2.jsonl"
  if CLAUDE_CODE_ENTRYPOINT=cli gaia_loop_session_is_interactive "$BATS_TEST_TMPDIR/t2.jsonl"; then return 1; fi
  if CLAUDE_CODE_ENTRYPOINT=cli gaia_loop_session_is_interactive "$BATS_TEST_TMPDIR/missing.jsonl"; then return 1; fi
  if CLAUDE_CODE_ENTRYPOINT=cli gaia_loop_session_is_interactive ""; then return 1; fi
}

@test "sourcing the lib with PATH empty still succeeds" {
  run env PATH= /bin/bash -c ". '$SCRIPTS/audit-loop-state-lib.sh'; echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}
