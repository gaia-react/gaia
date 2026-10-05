#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-loop-state-lib.sh: branch keying, state paths,
# schema-1 validation, the lock, atomic writes, the audited-root resolver and
# the grant/accept line grammar.
#
# AUDIT_LOOP_SCRIPTS_DIRECTORY points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-state-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
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
  local stub_directory="$BATS_TEST_TMPDIR/stub-git"
  mkdir -p "$stub_directory"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" >"$stub_directory/git"
  chmod +x "$stub_directory/git"
  printf '%s\n' "$stub_directory"
}

valid_state() {
  jq -n -c --arg tree "$(alf_git rev-parse 'HEAD^{tree}')" --arg commit "$(alf_git rev-parse HEAD)" \
    '{schema: 1, key: "branch:feat/x", branch: "feat/x", pr: null,
      history: {knobs: {checkpoint_round: 5, grant_rounds: 3},
                rounds: [{round: 1, tree: $tree, commit: $commit, members: ["code-audit-frontend"], closing: false, snapshot: null}],
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
  local stub_directory bad
  stub_directory="$(stub_git x)"
  for bad in 'feat/a..b' 'feat//x' '/lead' 'trail/' 'sp ace' "$(printf 'x%.0s' $(seq 1 129))"; do
    stub_directory="$(stub_git "$bad")"
    PATH="$stub_directory:$PATH" run gaia_loop_key "$ALF_ROOT"
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
  local first_path second_path
  first_path="$(gaia_loop_state_file /m a/b-c)"
  second_path="$(gaia_loop_state_file /m a-b/c)"
  [ "$first_path" = "/m/.gaia/local/protected/audit-loop/a/b-c.json" ]
  [ "$second_path" = "/m/.gaia/local/protected/audit-loop/a-b/c.json" ]
  [ "$first_path" != "$second_path" ]
}

@test "read: a valid file reads back; an absent file is rc 1" {
  local state_file="$BATS_TEST_TMPDIR/s/x.json"
  run gaia_loop_read_state "$state_file"
  [ "$status" -eq 1 ]
  gaia_loop_write_state "$state_file" "$(valid_state)"
  run gaia_loop_read_state "$state_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.history.rounds | length')" = 1 ]
}

@test "read and write: every corrupt shape is rc 5, prints nothing, and never replaces a file" {
  local state_file="$BATS_TEST_TMPDIR/s/x.json" bad="$BATS_TEST_TMPDIR/bad.json" state_copy name json row_count=0
  gaia_loop_write_state "$state_file" "$(valid_state)"
  state_copy="$(snapshot_file "$state_file")"
  while IFS='|' read -r name json; do
    row_count=$((row_count + 1))
    printf '%s' "$json" >"$bad"
    run gaia_loop_read_state "$bad"
    [ "$status" -eq 5 ] || { echo "read accepted: $name"; return 1; }
    [ -z "$output" ] || { echo "read printed for: $name"; return 1; }
    run gaia_loop_write_state "$state_file" "$json"
    [ "$status" -ne 0 ] || { echo "write accepted: $name"; return 1; }
    assert_files_identical "$state_copy" "$state_file" || { echo "file changed by: $name"; return 1; }
  done <<EOF
invalid json|{"schema":1,
schema 2|$(valid_state | jq -c '.schema = 2')
missing history.rounds|$(valid_state | jq -c 'del(.history.rounds)')
non-hex tree|$(valid_state | jq -c '.history.rounds[0].tree = "HEAD"')
missing knobs with rounds|$(valid_state | jq -c 'del(.history.knobs)')
pr not an integer|$(valid_state | jq -c '.pr = "12"')
two documents|$(valid_state) $(valid_state)
EOF
  [ "$row_count" -eq 7 ]
}

@test "lock: two concurrent writers both land" {
  local state_file="$BATS_TEST_TMPDIR/s/x.json" first_tree second_tree
  gaia_loop_write_state "$state_file" "$(valid_state)"
  first_tree="$(printf '1%.0s' $(seq 1 40))"
  second_tree="$(printf '2%.0s' $(seq 1 40))"
  writer() {
    gaia_loop_lock "$state_file" $(($(date +%s) + 20)) || return 1
    local state_json
    state_json="$(gaia_loop_read_state "$state_file")"
    sleep 0.3
    gaia_loop_write_state "$state_file" "$(printf '%s' "$state_json" | jq -c --arg tree "$1" '.history.rounds += [.history.rounds[0] + {tree: $tree}]')"
    gaia_loop_unlock "$state_file"
  }
  writer "$first_tree" &
  writer "$second_tree" &
  wait
  run jq -r '[.history.rounds[].tree] | join(",")' "$state_file"
  [ "$(jq '.history.rounds | length' "$state_file")" -eq 3 ]
  case "$output" in *"$first_tree"*) ;; *) return 1 ;; esac
  case "$output" in *"$second_tree"*) ;; *) return 1 ;; esac
  [ ! -d "$state_file.lock" ]
}

@test "lock: a stale lock is broken; a fresh held lock past the deadline is rc 1" {
  local state_file="$BATS_TEST_TMPDIR/s/x.json"
  mkdir -p "$state_file.lock"
  touch -t "$(alf_time 0)" "$state_file.lock"
  run gaia_loop_lock "$state_file" $(($(date +%s) + 5))
  [ "$status" -eq 0 ]
  [ -d "$state_file.lock" ]
  run gaia_loop_lock "$state_file" $(($(date +%s) + 1))
  [ "$status" -eq 1 ]
  gaia_loop_unlock "$state_file"
  [ ! -d "$state_file.lock" ]
}

@test "audited root: the prompt's Working root wins over cwd; cwd is the fallback" {
  local worktree payload
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  worktree="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  payload="$(jq -n -c --arg cwd "$ALF_ROOT" --arg prompt "Audit this. Working root: $worktree, the absolute path of the checkout." \
    '{cwd: $cwd, tool_input: {prompt: $prompt}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$worktree" ]
  payload="$(jq -n -c --arg cwd "$ALF_ROOT" '{cwd: $cwd, tool_input: {prompt: "no root named here"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$ALF_ROOT" ]
}

@test "audited root: a prose-punctuated or quoted Working root resolves to the named checkout" {
  local worktree payload prompt_text
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  worktree="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  for prompt_text in "Working root: $worktree. Audit the PR." "Working root: $worktree; base main" "Working root: \`$worktree\`." \
    "Working root: \"$worktree\"" "(Working root: $worktree)"; do
    payload="$(jq -n -c --arg cwd "$ALF_ROOT" --arg prompt "$prompt_text" '{cwd: $cwd, tool_input: {prompt: $prompt}}')"
    run gaia_loop_resolve_audited_root "$payload"
    [ "$status" -eq 0 ] || { printf 'prompt %s: status %s\n' "$prompt_text" "$status" >&2; return 1; }
    [ "$output" = "$worktree" ] || { printf 'prompt %s: output %s\n' "$prompt_text" "$output" >&2; return 1; }
  done
}

@test "audited root: a named Working root that does not resolve is rc 2 naming it, never the cwd" {
  local payload
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  payload="$(jq -n -c --arg cwd "$ALF_ROOT" --arg prompt "Working root: $BATS_TEST_TMPDIR/nogit, the path" \
    '{cwd: $cwd, tool_input: {prompt: $prompt}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 2 ]
  [ "$output" = "$BATS_TEST_TMPDIR/nogit" ]
  payload="$(jq -n -c --arg cwd "$ALF_ROOT" '{cwd: $cwd, tool_input: {prompt: "Working root: rel/path, x"}}')"
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
  local text want got raw row_count=0
  while IFS='|' read -r text want; do
    row_count=$((row_count + 1))
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
  [ "$row_count" -eq 15 ]
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
  gaia_loop_is_safe_relative_path a/b.txt
  gaia_loop_is_safe_relative_path 'a b/c..d'
  gaia_loop_is_safe_relative_path -rf && return 1
  gaia_loop_is_safe_relative_path /etc/x && return 1
  gaia_loop_is_safe_relative_path a/../b && return 1
  gaia_loop_is_safe_relative_path .. && return 1
  gaia_loop_is_safe_relative_path "$(printf 'a\nb')" && return 1
  gaia_loop_is_safe_relative_path '' && return 1
  true
}

# ---- SPEC-093: optional schema fields, pinned question, nonce, interactive check

full_state() {
  valid_state | jq -c '
    .history.context_config = {ask_tokens: 300000, ask_window_pct: 50}
    | .history.units = [{unit: 1, start_round: 1, k: 3, through_round: 3, admitted_on: "context", after_checkpoint: 0, recorded_at: "2026-10-02T00:00:00Z", session_id: "s"}]
    | .history.checkpoints = [{index: 1, at_round: 3, nonce: "0123456789abcdef", trigger: "context", accept_eligible: false,
        question: {questions: [{question: "q"}]}}]
    | .allowance.answers = [{checkpoint: 1, kind: "grant", n: 3, source: "ask", option: "Continue audit in this session", nonce: "0123456789abcdef", at: "t", session_id: "s"}]'
}

# assert_refused <label> <json>: read returns 5 and a write refuses, file unchanged.
assert_refused() {
  local state_file="$BATS_TEST_TMPDIR/refuse.json" exit_status
  valid_state >"$state_file"
  cp "$state_file" "$state_file.orig"
  printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/bad.json"
  gaia_loop_read_state "$BATS_TEST_TMPDIR/bad.json" >/dev/null && exit_status=0 || exit_status=$?
  [ "$exit_status" -eq 5 ] || { echo "$1: read rc $exit_status, want 5"; return 1; }
  gaia_loop_write_state "$state_file" "$2" && exit_status=0 || exit_status=$?
  [ "$exit_status" -eq 5 ] || { echo "$1: write rc $exit_status, want 5"; return 1; }
  cmp -s "$state_file" "$state_file.orig" || { echo "$1: file changed"; return 1; }
}

@test "schema: a state with every new optional field reads and writes" {
  local state_file="$BATS_TEST_TMPDIR/s.json"
  full_state >"$state_file"
  run gaia_loop_read_state "$state_file"
  [ "$status" -eq 0 ]
  run gaia_loop_write_state "$BATS_TEST_TMPDIR/o.json" "$(full_state)"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/o.json" ]
}

@test "schema: a legacy state round-trips byte-identically" {
  local state_file="$BATS_TEST_TMPDIR/legacy.json" rewritten_file="$BATS_TEST_TMPDIR/out.json"
  valid_state | jq . >"$state_file"
  gaia_loop_write_state "$rewritten_file" "$(gaia_loop_read_state "$state_file")"
  [ "$(jq -S -c . <"$state_file")" = "$(jq -S -c . <"$rewritten_file")" ]
  gaia_loop_write_state "$BATS_TEST_TMPDIR/o2.json" "$(gaia_loop_read_state "$rewritten_file")"
  cmp -s "$rewritten_file" "$BATS_TEST_TMPDIR/o2.json"
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

# option_count <json>: number of options in the first question.
option_count() { printf '%s' "$1" | jq '.questions[0].options | length'; }
# at_least_two_options <json>: the invariant every pinned question must hold.
at_least_two_options() { [ "$(option_count "$1")" -ge 2 ]; }
labels() { printf '%s' "$1" | jq -r '[.questions[0].options[].label] | join("|")'; }

@test "pinned question: labels, order, header, single question" {
  local nonce=0123456789abcdef question
  question="$(gaia_loop_pinned_question feat/x $nonce 6 3 true false context)"
  [ "$(printf '%s' "$question" | jq '.questions | length')" -eq 1 ]
  [ "$(printf '%s' "$question" | jq -r '.questions[0].header')" = "Audit loop" ]
  [ "$(printf '%s' "$question" | jq '.questions[0].multiSelect')" = false ]
  [ "$(labels "$question")" = "Continue audit in a new session (Recommended)|Continue audit in this session|Accept the remainder|Stop and file the remainder" ]
  case "$(printf '%s' "$question" | jq -r '.questions[0].question')" in
    *"$nonce"*"feat/x"*"6 rounds used (context)"*) ;;
    *) return 1 ;;
  esac
  question="$(gaia_loop_pinned_question feat/x $nonce 6 2 true false context)"
  [ "$(labels "$question")" = "Continue audit in a new session (Recommended)|Continue audit in this session|Accept the remainder|Stop and file the remainder" ]
}

@test "pinned question: eligibility and cap shape the options, never fewer than two" {
  local nonce=0123456789abcdef question
  question="$(gaia_loop_pinned_question feat/x $nonce 6 3 false false context)"
  [ "$(labels "$question")" = "Continue audit in a new session (Recommended)|Continue audit in this session|Stop and file the remainder" ]
  question="$(gaia_loop_pinned_question feat/x $nonce 10 3 true true cap)"
  [ "$(labels "$question")" = "Continue audit in a new session (Recommended)|Continue audit in this session|Accept the remainder|Stop and file the remainder" ]
  question="$(gaia_loop_pinned_question feat/x $nonce 10 3 false true cap)"
  [ "$(labels "$question")" = "Continue audit in a new session (Recommended)|Continue audit in this session|Type audit-accept instead|Stop and file the remainder" ]
  local eligible cap
  for eligible in true false; do
    for cap in true false; do
      question="$(gaia_loop_pinned_question feat/x $nonce 6 3 $eligible $cap rubric:J2)"
      at_least_two_options "$question"
      [[ "$(labels "$question")" == *"Stop and file the remainder"* ]]
      [[ "$question" == *"$nonce"* ]]
    done
  done
  # The cap-ineligible description names the typed line as a deliberate override.
  question="$(gaia_loop_pinned_question feat/x $nonce 10 3 false true cap)"
  [[ "$question" == *"audit-accept"*"deliberate override"* ]]
}

@test "pinned question red twin: a builder without the grants and the cap-ineligible option fails the two-option check" {
  local mutant_directory="$BATS_TEST_TMPDIR/mut" question
  mkdir -p "$mutant_directory"
  cp "$SCRIPTS"/*.sh "$mutant_directory/"
  sed -e 's/if \$cap and (\$eligible | not) then/if false then/' -e '/{key: "grant_/d' "$SCRIPTS/audit-loop-state-lib.sh" >"$mutant_directory/audit-loop-state-lib.sh"
  if cmp -s "$SCRIPTS/audit-loop-state-lib.sh" "$mutant_directory/audit-loop-state-lib.sh"; then return 1; fi
  question="$(bash -c '. "$1"; gaia_loop_pinned_question feat/x 0123456789abcdef 10 3 false true cap' _ "$mutant_directory/audit-loop-state-lib.sh")"
  [ "$(option_count "$question")" -eq 1 ]
  run at_least_two_options "$question"
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

# ask_labels <json>: every option label, one per line.
ask_labels() { printf '%s' "$1" | jq -r '.questions[0].options[].label'; }
# first_label <json>: the leading option's label.
first_label() { printf '%s' "$1" | jq -r '.questions[0].options[0].label'; }
# option_description <json> <label-prefix>: the description of the option whose label starts with the prefix.
option_description() { printf '%s' "$1" | jq -r --arg label_prefix "$2" '.questions[0].options[] | select(.label | startswith($label_prefix)) | .description'; }
# recommended_count <json>: how many labels carry the (Recommended) suffix.
recommended_count() { printf '%s' "$1" | jq '[.questions[0].options[] | select(.label | endswith(" (Recommended)"))] | length'; }

@test "pinned question: a reading below the checkpoint line leads with continue here, and the choices carry the reading" {
  local question
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false rubric:J2 "fresh 260000 1000000" grant 400000)"
  [ "$(first_label "$question")" = "Continue audit in this session (Recommended)" ]
  [ "$(recommended_count "$question")" -eq 1 ]
  [ "$(ask_labels "$question" | sed -n 2p)" = "Continue audit in a new session" ]
  [ "$(option_description "$question" "Continue audit in this session")" = "Context 26% (260k of 1000k) is below the checkpoint line, so this session has room: records 3 more rounds and keeps working here." ]
  [[ "$(option_description "$question" "Continue audit in a new session")" == "Context 26% (260k of 1000k) is below the checkpoint line: records the same 3-round grant, then prints a continuation prompt for a fresh session."* ]]
}

@test "pinned question: a reading at or above the checkpoint line leads with new session" {
  local question reading
  for reading in "fresh 500000 1000000" "fresh 400000 1000000"; do
    question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false rubric:J2 "$reading" grant 400000)"
    [ "$(first_label "$question")" = "Continue audit in a new session (Recommended)" ]
    [ "$(recommended_count "$question")" -eq 1 ]
    [[ "$(option_description "$question" "Continue audit in a new session")" == *"is at or above the checkpoint line: records the same 3-round grant, then prints a continuation prompt for a fresh session."* ]]
  done
}

@test "pinned question: no usable reading, or no line, leads with new session and says context unavailable" {
  local question
  for reading in "" missing stale future unparseable "fresh 5 0"; do
    question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "$reading" grant 400000)"
    [ "$(first_label "$question")" = "Continue audit in a new session (Recommended)" ]
    [[ "$(option_description "$question" "Continue audit in a new session")" == "Context unavailable, so a new session is the safe choice: records the same 3-round grant"* ]]
  done
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "fresh 100000 1000000" grant)"
  [ "$(first_label "$question")" = "Continue audit in a new session (Recommended)" ]
}

@test "pinned question: an accept recommendation leads with Accept when offered, otherwise the band picks the grant" {
  local question
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false rubric:J2 "fresh 260000 1000000" accept 400000)"
  [ "$(first_label "$question")" = "Accept the remainder (Recommended)" ]
  [ "$(recommended_count "$question")" -eq 1 ]
  [ "$(ask_labels "$question" | sed -n 2,3p | paste -sd'|' -)" = "Continue audit in this session|Continue audit in a new session" ]
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 false false rubric:J2 "fresh 260000 1000000" accept 400000)"
  [ "$(first_label "$question")" = "Continue audit in this session (Recommended)" ]
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false rubric:J2 "fresh 260000 1000000" stop 400000)"
  [ "$(first_label "$question")" = "Stop and file the remainder (Recommended)" ]
  [ "$(recommended_count "$question")" -eq 1 ]
}

@test "pinned question: a context trigger always leads with new session, whatever the evaluator recommends or the band says" {
  local question recommendation
  for recommendation in grant accept stop ""; do
    question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "fresh 500000 1000000" "$recommendation" 400000)"
    [ "$(first_label "$question")" = "Continue audit in a new session (Recommended)" ]
    [ "$(recommended_count "$question")" -eq 1 ]
    [ "$(ask_labels "$question" | sed -n 2p)" = "Continue audit in this session" ]
  done
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "fresh 260000 1000000" accept 400000)"
  [ "$(first_label "$question")" = "Continue audit in a new session (Recommended)" ]
}

@test "pinned question: a bad recommendation or line is rc 2 with empty stdout" {
  run gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "" bogus 400000
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "" grant abc
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "pinned question: the line comparison is strict, so a reading exactly on the line is not below it" {
  local mutant_directory="$BATS_TEST_TMPDIR/mut-line" question
  mkdir -p "$mutant_directory"
  cp "$SCRIPTS"/*.sh "$mutant_directory/"
  sed 's/-lt "\$((10#\$line))"/-le "$((10#$line))"/' "$SCRIPTS/audit-loop-state-lib.sh" >"$mutant_directory/audit-loop-state-lib.sh"
  if cmp -s "$SCRIPTS/audit-loop-state-lib.sh" "$mutant_directory/audit-loop-state-lib.sh"; then return 1; fi
  question="$(bash -c '. "$1"; gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false rubric:J2 "fresh 400000 1000000" grant 400000' _ "$mutant_directory/audit-loop-state-lib.sh")"
  [ "$(first_label "$question")" = "Continue audit in this session (Recommended)" ]
}

@test "recommended: a context checkpoint with no denying signal is a grant, otherwise the verdict decides" {
  [ "$(gaia_loop_recommended context '{"verdict":"stalled"}')" = stop ]
  [ "$(gaia_loop_recommended context '{"verdict":"quiet","signals":{"quiet":true}}')" = grant ]
  [ "$(gaia_loop_recommended context '{"verdict":"stalled","signals":{"stalled":true}}')" = stop ]
  [ "$(gaia_loop_recommended cap '{"verdict":"enriching"}')" = accept ]
  [ "$(gaia_loop_recommended fallback '{"verdict":"continue"}')" = grant ]
  [ "$(gaia_loop_recommended cap null)" = grant ]
  true
}

@test "recommended: a stalled small tail the evaluator calls accept-eligible is an accept, not a stop" {
  [ "$(gaia_loop_recommended rubric:stalled '{"verdict":"stalled","signals":{"stalled":true,"small-tail":true},"accept_eligible":true}')" = accept ]
  [ "$(gaia_loop_recommended context '{"verdict":"stalled","signals":{"stalled":true,"small-tail":true},"accept_eligible":true}')" = accept ]
  [ "$(gaia_loop_recommended rubric:stalled '{"verdict":"stalled","signals":{"stalled":true,"small-tail":true},"accept_eligible":false}')" = stop ]
  [ "$(gaia_loop_recommended rubric:stalled '{"verdict":"stalled","signals":{"stalled":true,"small-tail":false},"accept_eligible":true}')" = stop ]
  true
}

@test "pinned question: a fresh reading puts the percent and k-token figures in the text" {
  local question
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "fresh 123456 400000")"
  [ "$(question_text "$question")" = "Audit checkpoint 0123456789abcdef on feat/x: 6 rounds used (context), context 30% (123k of 400k). How should the audit loop continue?" ]
}

@test "pinned question: no reading, or an unusable one, reads context unavailable" {
  local reading question
  question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context)"
  [ "$(question_text "$question")" = "Audit checkpoint 0123456789abcdef on feat/x: 6 rounds used (context), context unavailable. How should the audit loop continue?" ]
  for reading in missing stale future unparseable "fresh 5 0"; do
    question="$(gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "$reading")"
    [[ "$(question_text "$question")" == *"(context), context unavailable. How"* ]]
  done
}

@test "pinned question: a malformed context reading is rc 2 with empty stdout" {
  local reading
  for reading in "fresh 12" "fresh a b" "fresh 1 2 3" "bogus" "fresh -1 5"; do
    run gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context "$reading"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "nonce: two calls differ, are 16 hex, and pin different questions" {
  local first_nonce second_nonce first_question second_question
  first_nonce="$(gaia_loop_new_nonce)"
  second_nonce="$(gaia_loop_new_nonce)"
  [[ "$first_nonce" =~ ^[0-9a-f]{16}$ ]]
  [[ "$second_nonce" =~ ^[0-9a-f]{16}$ ]]
  [ "$first_nonce" != "$second_nonce" ]
  first_question="$(gaia_loop_pinned_question feat/x "$first_nonce" 6 3 true false context)"
  second_question="$(gaia_loop_pinned_question feat/x "$second_nonce" 6 3 true false context)"
  [ "$first_question" != "$second_question" ]
}

@test "pinned question: with the recorder off every grant and accept description names the typed line" {
  local mutant_directory="$BATS_TEST_TMPDIR/mut0" question
  mkdir -p "$mutant_directory"
  cp "$SCRIPTS"/*.sh "$mutant_directory/"
  sed 's/^_GAIA_LOOP_ASK_RECORDER=1$/_GAIA_LOOP_ASK_RECORDER=0/' "$SCRIPTS/audit-loop-state-lib.sh" >"$mutant_directory/audit-loop-state-lib.sh"
  question="$(bash -c '. "$1"; gaia_loop_pinned_question feat/x 0123456789abcdef 6 3 true false context' _ "$mutant_directory/audit-loop-state-lib.sh")"
  [ "$(printf '%s' "$question" | jq '[.questions[0].options[] | select(.label | startswith("Continue") or startswith("Accept")) | select(.description | test("type `audit-(grant 3|accept)`"))] | length')" -eq 3 ]
}

@test "interactive check: cli env and an all-cli transcript pass; every other shape fails" {
  local transcript_file="$BATS_TEST_TMPDIR/t.jsonl"
  printf '{"entrypoint":"cli"}\n{"type":"x"}\n{"entrypoint":"cli"}\n' >"$transcript_file"
  CLAUDE_CODE_ENTRYPOINT=cli gaia_loop_session_is_interactive "$transcript_file"
  if CLAUDE_CODE_ENTRYPOINT=sdk-cli gaia_loop_session_is_interactive "$transcript_file"; then return 1; fi
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
