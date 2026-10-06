#!/usr/bin/env bats

# .claude/hooks/usage-capture.sh: the Stop and SessionStart hook that launches
# the usage flusher detached. The synchronous path is paid on every turn end,
# so this suite pins that it forks and returns without reading a transcript
# byte or holding the hook's pipes open, and that it does nothing in CI.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/usage-capture.bats
#
# MEASUREMENT (local, never a CI gate). Machine: Apple Silicon macOS; /bin/bash
# 3.2.57 and Homebrew bash 5. Method: the hook's synchronous process alone (the
# flusher replaced by an exit-0 stub), one fixed payload, 40 runs through perl
# `system`, median wall time (the figure includes one /bin/sh spawn for
# `system`, a few ms of overhead the real harness call also pays):
#
#   event          bash 3.2    bash 5
#   Stop           ~19.5 ms    ~22.8 ms
#   SessionStart   ~19.3 ms    ~22.6 ms
#
# Per session at SPEC-087's measured frequencies (Stop median 4, p90 12;
# SessionStart once): bash 3.2 ~97 ms median, ~253 ms at p90; bash 5 ~114 ms
# median, ~297 ms at p90. The flusher's own cost runs detached and is not in
# these figures.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # The real scripts copied below reach the pricing path; the hermetic
  # suite holds every usage suite to this isolation.
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$TEMPORARY_DIRECTORY/rates-state"
  unset GITHUB_ACTIONS CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GAIA_USAGE_TEST_BARRIER
  REPO="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  STUB_LOG="$TEMPORARY_DIRECTORY/stub.log"
  STUB_DONE="$TEMPORARY_DIRECTORY/stub.done"
  mkdir -p "$PROJECTS_DIRECTORY"
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

mk_repo() {
  mkdir -p "$REPO/.claude/hooks" "$REPO/.gaia/scripts" "$REPO/.gaia/scripts/spec"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  cp "$REPO_ROOT/.claude/hooks/usage-capture.sh" "$REPO/.claude/hooks/"
  PROJECT_DIRECTORY="$PROJECTS_DIRECTORY/$(encode_project_path "$REPO")"
  mkdir -p "$PROJECT_DIRECTORY"
}

# stub_repo: a flusher that records argv and whether stdin is /dev/null,
# sleeps past the hook's return, then marks completion.
stub_repo() {
  mk_repo
  cat >"$REPO/.gaia/scripts/usage-flush.sh" <<STUB
#!/usr/bin/env bash
{ printf '%s\n' "\$*"; [ -c /dev/stdin ] && echo devnull-stdin; } >>"$STUB_LOG"
sleep 5
touch "$STUB_DONE"
STUB
}

real_repo() {
  mk_repo
  local script_name
  for script_name in usage-flush.sh usage-parse-lib.sh usage-lib.sh main-root-lib.sh branch-name-lib.sh ledger-path-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$script_name" "$REPO/.gaia/scripts/"
  done
  cp "$REPO_ROOT/.gaia/scripts/spec/with-ledger-lock.sh" "$REPO/.gaia/scripts/spec/"
}

# payload <event> <sid> [transcript_path] [stop_hook_active]
payload() {
  jq -nc --arg hook_event_name "$1" --arg session_id "$2" --arg transcript_path "${3:-}" --argjson stop_hook_active "${4:-false}" \
    '{hook_event_name: $hook_event_name, session_id: $session_id, cwd: "/", stop_hook_active: $stop_hook_active}
     + (if $transcript_path == "" then {} else {transcript_path: $transcript_path} end)'
}

# The hook runs from the tmp repo, as Claude Code runs it from the project, so
# the real flusher resolves the tmp repo and never this checkout.
fire() { run bash -c 'cd "$1" && exec bash "$2"' _ "$REPO" "${HOOK:-$REPO/.claude/hooks/usage-capture.sh}" <<<"$1"; }

wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt "${2:-100}" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# mutated_hook <sed-expr>: a scratch copy of the hook beside the original,
# failing when the sed changed nothing so a stale mutation cannot green.
mutated_hook() {
  HOOK="$REPO/.claude/hooks/usage-capture-mut.sh"
  sed "$1" "$REPO/.claude/hooks/usage-capture.sh" >"$HOOK"
  if cmp -s "$REPO/.claude/hooks/usage-capture.sh" "$HOOK"; then
    echo "mutation did not apply" >&2
    return 1
  fi
}

# ---------- UAT-015: detached, cheap, argv ----------

@test "UAT-015: Stop launches the flusher detached, returns under 2s, stdin is /dev/null" {
  stub_repo
  local transcript_path="$PROJECT_DIRECTORY/S1.jsonl" started_at_milliseconds ended_at_milliseconds
  started_at_milliseconds="$(now_ms)"
  fire "$(payload Stop S1 "$transcript_path")"
  ended_at_milliseconds="$(now_ms)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((ended_at_milliseconds - started_at_milliseconds)) -lt 2000 ]
  [ ! -e "$STUB_DONE" ]
  wait_for "$STUB_DONE" 80
  [ "$(sed -n 1p "$STUB_LOG")" = "--session S1 --transcript $transcript_path --finished-main --projects-root $PROJECTS_DIRECTORY" ]
  grep -qx devnull-stdin "$STUB_LOG"
}

@test "UAT-015: SessionStart launches the sweep detached, returns under 2s, stdin is /dev/null" {
  stub_repo
  local transcript_path="$PROJECT_DIRECTORY/S2.jsonl" started_at_milliseconds ended_at_milliseconds
  started_at_milliseconds="$(now_ms)"
  fire "$(payload SessionStart S2 "$transcript_path")"
  ended_at_milliseconds="$(now_ms)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((ended_at_milliseconds - started_at_milliseconds)) -lt 2000 ]
  [ ! -e "$STUB_DONE" ]
  wait_for "$STUB_DONE" 80
  [ "$(sed -n 1p "$STUB_LOG")" = "--sweep --self-session S2 --projects-root $PROJECTS_DIRECTORY" ]
  grep -qx devnull-stdin "$STUB_LOG"
}

@test "SessionStart without a transcript_path passes no --projects-root" {
  stub_repo
  fire "$(payload SessionStart S3)"
  [ "$status" -eq 0 ]
  wait_for "$STUB_LOG" 50
  [ "$(sed -n 1p "$STUB_LOG")" = "--sweep --self-session S3" ]
}

@test "an empty session_id launches nothing" {
  stub_repo
  fire "$(payload Stop "" "$PROJECT_DIRECTORY/x.jsonl")"
  [ "$status" -eq 0 ]
  sleep 1
  [ ! -e "$STUB_LOG" ]
}

# ---------- no transcript read ----------

@test "a transcript_path that would block on open does not stall the hook" {
  stub_repo
  mkfifo "$PROJECT_DIRECTORY/S4.jsonl"
  local started_at_milliseconds ended_at_milliseconds
  started_at_milliseconds="$(now_ms)"
  fire "$(payload Stop S4 "$PROJECT_DIRECTORY/S4.jsonl")"
  ended_at_milliseconds="$(now_ms)"
  [ "$status" -eq 0 ]
  [ $((ended_at_milliseconds - started_at_milliseconds)) -lt 2000 ]
}

@test "guard can fail: a hook that reads the transcript is killed by the watchdog on a FIFO" {
  stub_repo
  mkfifo "$PROJECT_DIRECTORY/S5.jsonl"
  mutated_hook 's|^root_args=()$|root_args=(); head -c1 "$transcript_path" >/dev/null|'
  payload Stop S5 "$PROJECT_DIRECTORY/S5.jsonl" >"$TEMPORARY_DIRECTORY/payload.json"
  # The redirects sit inside `bash -c` so they bind to the hook itself: the
  # orphaned reader would otherwise hold bats' own pipes and hang the suite.
  # SIGALRM is reset first: a runner that starts bats with it ignored (GNU
  # parallel under `bats --jobs`) would otherwise leave the alarm inert.
  run bash -c 'perl -e "\$SIG{ALRM}=q(DEFAULT); alarm 3; exec @ARGV" bash "$1" <"$2" >/dev/null 2>&1 3>&- 4>&-' _ "$HOOK" "$TEMPORARY_DIRECTORY/payload.json"
  local exit_status="$status"
  # Release the orphaned reader before asserting, so a failed assertion never
  # leaves it outliving the test.
  { : >"$PROJECT_DIRECTORY/S5.jsonl"; } </dev/null >/dev/null 2>&1 3>&- 4>&- &
  disown "$!" 2>/dev/null || true
  # 142 is 128 + SIGALRM: the watchdog fired because the read never returned.
  [ "$exit_status" -eq 142 ]
}

# ---------- detach guard ----------

@test "guard can fail: without the redirects the hook holds its pipes for the flusher's whole run" {
  stub_repo
  mutated_hook 's| </dev/null >/dev/null 2>&1 &$| \&|'
  local started_at_milliseconds ended_at_milliseconds
  started_at_milliseconds="$(now_ms)"
  fire "$(payload Stop S6 "$PROJECT_DIRECTORY/S6.jsonl")"
  ended_at_milliseconds="$(now_ms)"
  [ "$status" -eq 0 ]
  [ $((ended_at_milliseconds - started_at_milliseconds)) -ge 4000 ]
}

# ---------- UAT-028 ----------

@test "UAT-028: GITHUB_ACTIONS set launches nothing; unset control launches" {
  stub_repo
  GITHUB_ACTIONS=true fire "$(payload Stop S7 "$PROJECT_DIRECTORY/S7.jsonl")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 1
  [ ! -e "$STUB_LOG" ]
  [ ! -e "$REPO/.gaia/local/telemetry" ]
  fire "$(payload Stop S7 "$PROJECT_DIRECTORY/S7.jsonl")"
  [ "$status" -eq 0 ]
  wait_for "$STUB_LOG" 50
}

@test "UAT-028: the real flusher records nothing under GITHUB_ACTIONS" {
  real_repo
  write_session S8 "$PROJECT_DIRECTORY/S8.jsonl" 1
  GITHUB_ACTIONS=true fire "$(payload Stop S8 "$PROJECT_DIRECTORY/S8.jsonl")"
  [ "$status" -eq 0 ]
  sleep 2
  [ ! -e "$REPO/.gaia/local/telemetry" ]
  fire "$(payload Stop S8 "$PROJECT_DIRECTORY/S8.jsonl")"
  [ "$status" -eq 0 ]
  wait_cursor "$PROJECT_DIRECTORY/S8.jsonl"
}

# ---------- UAT-013 (hook side) ----------

@test "UAT-013: jq absent from PATH exits 0 and launches nothing" {
  stub_repo
  mkdir "$TEMPORARY_DIRECTORY/nojq"
  ln -s "$(command -v bash)" "$TEMPORARY_DIRECTORY/nojq/bash"
  run env PATH="$TEMPORARY_DIRECTORY/nojq" "$(command -v bash)" "$REPO/.claude/hooks/usage-capture.sh" <<<"$(payload Stop S9 "$PROJECT_DIRECTORY/S9.jsonl")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 1
  [ ! -e "$STUB_LOG" ]
  [ ! -e "$REPO/.gaia/local/telemetry" ]
}

# ---------- re-entry ----------

@test "Stop with stop_hook_active true launches nothing" {
  stub_repo
  fire "$(payload Stop S10 "$PROJECT_DIRECTORY/S10.jsonl" true)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 1
  [ ! -e "$STUB_LOG" ]
}

# ---------- UAT-011: real flusher ----------

# message_line <session_id> <id> <factor>: one assistant usage line of factor k (fresh k,
# 5m write 10k, 1h write 100k, cache read 1000k, output 10k).
message_line() {
  jq -nc --arg session_id "$1" --arg id "$2" --arg cwd "$REPO" --argjson factor "$3" \
    '{type: "assistant", uuid: ("u-" + $id),
      timestamp: ("2026-10-01T00:00:0" + ($factor | tostring) + ".000Z"),
      cwd: $cwd, sessionId: $session_id, gitBranch: "main",
      message: {id: $id, model: "claude-opus-5-5", role: "assistant",
        usage: {input_tokens: $factor, cache_creation_input_tokens: (110 * $factor),
          cache_read_input_tokens: (1000 * $factor), output_tokens: (10 * $factor),
          cache_creation: {ephemeral_5m_input_tokens: (10 * $factor), ephemeral_1h_input_tokens: (100 * $factor)}},
        content: [{type: "text", text: "x"}]}}'
}

# write_session <sid> <path> <last_k>: messages k=1..last_k, aged past every quiet window.
write_session() {
  local k=1
  : >"$2"
  while [ "$k" -le "$3" ]; do
    message_line "$1" "$1-m$k" "$k" >>"$2"
    k=$((k + 1))
  done
  touch -t 202001010000 "$2"
}

segment_totals() {
  jq -S -s -c '[.[] | select(.kind == "segment")]
    | reduce .[] as $segment ({}; reduce ($segment.by_model | to_entries[]) as $model (.;
        reduce ($model.value | to_entries[]) as $bucket (.; .[$segment.key][$model.key][$bucket.key] += $bucket.value)))' \
    "$REPO/.gaia/local/telemetry/usage.jsonl"
}

wait_cursor() {
  local transcript_file="$1" i=0 want
  want="$(wc -c <"$transcript_file" | tr -d ' ')"
  while [ "$i" -lt 200 ]; do
    [ "$(jq -r --arg transcript_path "$transcript_file" '.files[$transcript_path].offset // -1' "$REPO/.gaia/local/telemetry/usage-cursors.json" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

@test "UAT-011: a SessionStart sweep records an ended session's final turns; a resumed session adds only its new lines" {
  real_repo
  local session_file="$PROJECT_DIRECTORY/SA.jsonl"
  write_session SA "$session_file" 3
  fire "$(payload SessionStart SB "$PROJECT_DIRECTORY/SB.jsonl")"
  [ "$status" -eq 0 ]
  wait_cursor "$session_file"
  [ "$(segment_totals)" = '{"session:SA":{"claude-opus-5-5":{"cache_read":6000,"cache_write_1h":600,"cache_write_5m":60,"fresh_input":6,"output":60}}}' ]

  message_line SA SA-m4 4 >>"$session_file"
  fire "$(payload Stop SA "$session_file")"
  [ "$status" -eq 0 ]
  wait_cursor "$session_file"
  [ "$(segment_totals)" = '{"session:SA":{"claude-opus-5-5":{"cache_read":10000,"cache_write_1h":1000,"cache_write_5m":100,"fresh_input":10,"output":100}}}' ]
}

# ---------- registration ----------

@test "registration: usage-capture.sh is under Stop and SessionStart startup|resume" {
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.Stop[]' usage-capture.sh
  hook_registered "$REPO_ROOT/.claude/settings.json" '.hooks.SessionStart[] | select(.matcher == "startup|resume")' usage-capture.sh
}

@test "registration: the rooting, scope-manifest, and cwd-relative-load gates pass" {
  run bash "$REPO_ROOT/.gaia/scripts/check-hook-command-rooting.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/.gaia/scripts/check-hook-scope-manifest.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/.gaia/scripts/lint-hook-cwd-relative-loads.sh"
  [ "$status" -eq 0 ]
}
