#!/usr/bin/env bats
#
# Suite for .claude/hooks/ports-session-start.sh: session registration on every
# source, cleanup (reclaim, removed-tree reap, dead-session reap) only on a real
# session start, and the ports context line on clear and compact.
#
# Fixtures: a throwaway git repository with real linked worktrees, ephemeral
# base ports, real listeners from the shared fixture, and a stand-in session
# host (a `sleep` or a `bash` that launches a listener) that a test kills to
# simulate a session that ended. Every process a test starts is recorded in
# STARTED_PIDS and killed in teardown. Detached starts close fd 3 so bats does
# not wait on them.
#
# Run: bash .gaia/scripts/bats5.sh .gaia/tests/hooks/ports-session-start.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  # PORTS_SESSION_START_HOOK points the suite at a mutated copy to prove each guard can fail.
  HOOK="${PORTS_SESSION_START_HOOK:-$REPO_ROOT/.claude/hooks/ports-session-start.sh}"
  SERVER_LIBRARY="$REPO_ROOT/.gaia/scripts/server-process-lib.sh"
  PORTS_LIBRARY="$REPO_ROOT/.gaia/scripts/worktree-ports-lib.sh"
  LISTENER_FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/ports/listen.mjs"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  STARTED_PIDS=()
  TAB=$'\t'
  unset CLAUDE_CODE_SESSION_ID GAIA_PORTS_HOST_PID GAIA_PORTS_STATE_DIRECTORY GITHUB_ACTIONS SITE_URL
  export GAIA_PORTS_PROCESS_PROBE="${GAIA_PORTS_PROCESS_PROBE:-auto}"
  DEV_BASE=$((20000 + (RANDOM % 7000)))
  STORYBOOK_BASE=$((DEV_BASE + 300))
  export GAIA_PORTS_DEV_BASE_PORT="$DEV_BASE" GAIA_PORTS_STORYBOOK_BASE_PORT="$STORYBOOK_BASE"

  command -v node >/dev/null 2>&1 || skip "node is required for the listener fixture"
  if ! command -v lsof >/dev/null 2>&1; then
    { [ -e /proc/self ] && command -v ss >/dev/null 2>&1; } || skip "no process backend (lsof, or /proc with ss) on this host"
  fi

  mkdir -p "$SCRATCH/main/frontend" "$SCRATCH/trees"
  git init -q -b main "$SCRATCH/main"
  MAIN="$(cd "$SCRATCH/main" && pwd -P)"
  : >"$MAIN/frontend/react-router.config.ts"
  fixture_git add -A
  fixture_git commit -q -m base
  STATE="$MAIN/.gaia/local/ports"
  REAL_GIT="$(command -v git)"
  start_host_process
  LIVE_HOST_PID="$HOST_PID"
}

teardown() {
  local started_pid
  for started_pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$started_pid" ] && kill -KILL "$started_pid" 2>/dev/null
  done
  return 0
}

fixture_git() {
  git -C "$MAIN" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false "$@"
}

ports_lib() {
  bash -c '. "$1"; shift; "$@"' _ "$PORTS_LIBRARY" "$@"
}

process_running() {
  local process_state
  process_state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  process_state="${process_state// /}"
  [ -n "$process_state" ] || return 1
  case "$process_state" in
    Z*) return 1 ;;
  esac
  return 0
}

wait_until_gone() {
  local attempt=0
  while [ "$attempt" -lt 100 ]; do
    process_running "$1" || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_listening() {
  local log="$1" attempt=0
  while [ "$attempt" -lt 100 ]; do
    if [ -f "$log" ] && grep -q '^listening ' "$log"; then
      return 0
    fi
    if [ -f "$log" ] && grep -q 'E[A-Z]' "$log"; then
      return 1
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

# start_listener <directory> <port>: a detached fixture listener with cwd
# <directory>. Sets LISTENER_PID; rc 1 when it fails to bind.
start_listener() {
  local directory="$1" port="$2" log
  log="$SCRATCH/listener-$port-$RANDOM.log"
  (cd "$directory" && nohup node "$LISTENER_FIXTURE" "$port" 127.0.0.1 >"$log" 2>&1 </dev/null 3>&- &)
  wait_for_listening "$log" || return 1
  LISTENER_PID="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$log")"
  [ -n "$LISTENER_PID" ] || return 1
  STARTED_PIDS+=("$LISTENER_PID")
}

# free_port: a port in a range the base ports never reach. Sets FREE_PORT.
free_port() {
  FREE_PORT=$((28000 + (RANDOM % 2000)))
}

# start_free_listener <directory>: a listener on a free port. Sets FREE_PORT, LISTENER_PID.
start_free_listener() {
  local attempt=0
  while [ "$attempt" -lt 8 ]; do
    free_port
    start_listener "$1" "$FREE_PORT" && return 0
    attempt=$((attempt + 1))
  done
  return 1
}

start_host_process() {
  local pid_file="$SCRATCH/host-$RANDOM.pid"
  (nohup sleep 300 >/dev/null 2>&1 </dev/null 3>&- & printf '%s' "$!" >"$pid_file")
  HOST_PID="$(cat "$pid_file")"
  STARTED_PIDS+=("$HOST_PID")
}

kill_host() {
  kill -KILL "$1"
  wait_until_gone "$1"
}

identity_of() {
  bash -c '. "$1"; gaia_server_process_identity "$2"' _ "$SERVER_LIBRARY" "$1"
}

# run_hook <source> <session-id> <cwd> [<host-pid>]: runs the hook with a
# SessionStart payload; stdout is $output and stderr is $stderr.
run_hook() {
  local payload
  payload="$(printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s","cwd":"%s"}' "$2" "$1" "$3")"
  run --separate-stderr env GAIA_PORTS_HOST_PID="${4:-$LIVE_HOST_PID}" bash "$HOOK" <<<"$payload"
}

# add_tree <name>: a linked worktree holding the next slot with its port file.
# Sets TREE and SLOT.
add_tree() {
  fixture_git worktree add -q -b "$1" "$SCRATCH/trees/$1" >/dev/null 2>&1
  TREE="$(cd "$SCRATCH/trees/$1" && pwd -P)"
  SLOT="$(ports_lib gaia_ports_assign_slot "$STATE" "$TREE")"
  ports_lib gaia_ports_write_file "$TREE" "$SLOT"
}

# register_session <session-id> <host-pid>: registers through the hook itself.
register_session() {
  run_hook clear "$1" "$MAIN" "$2"
  [ "$status" -eq 0 ]
  [ -f "$STATE/sessions/$1.tsv" ]
}

# start_hosted_listener <session-id> <directory> <port> <kind> <tree>: a
# listener launched by a stand-in session host (`bash` waiting on it), the
# session registered with that host, and the launch recorded by ancestry.
# Sets HOST_PID and LISTENER_PID.
start_hosted_listener() {
  local session="$1" directory="$2" port="$3" kind="$4" tree="$5"
  local pid_file="$SCRATCH/hosted-$RANDOM.pid" log="$SCRATCH/hosted-$port-$RANDOM.log"
  (nohup bash -c 'cd "$1" || exit 1; node "$2" "$3" 127.0.0.1 & wait' _ "$directory" "$LISTENER_FIXTURE" "$port" >"$log" 2>&1 </dev/null 3>&- & printf '%s' "$!" >"$pid_file")
  HOST_PID="$(cat "$pid_file")"
  STARTED_PIDS+=("$HOST_PID")
  wait_for_listening "$log"
  LISTENER_PID="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$log")"
  [ -n "$LISTENER_PID" ]
  STARTED_PIDS+=("$LISTENER_PID")
  register_session "$session" "$HOST_PID"
  GAIA_PORTS_STATE_DIRECTORY="$STATE" run bash "$SERVER_LIBRARY" --record-launch \
    --pid "$LISTENER_PID" --port "$port" --kind "$kind" --tree "$tree"
  [ "$status" -eq 0 ]
  [ -f "$STATE/launches/$LISTENER_PID.tsv" ]
}

write_launch_record() {
  mkdir -p "$STATE/launches"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >"$STATE/launches/$1.tsv"
}

dead_pid() {
  start_host_process
  DEAD_PID="$HOST_PID"
  kill_host "$DEAD_PID"
}

line_count() {
  if [ -z "$1" ]; then
    printf '0'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

dead_session_line() {
  printf 'GAIA stopped a %s server on port %s (PID %s) launched by an ended Claude session in %s.' "$1" "$2" "$3" "$4"
}

removed_tree_line() {
  printf 'GAIA stopped a server on port %s (PID %s) left running from removed worktree %s.' "$1" "$2" "$3"
}

# ---------- dead-session reap ----------

@test "dead session: the recorded server is stopped with one report line, the unrecorded one survives" {
  start_hosted_listener session-one "$MAIN" 28101 dev "$MAIN"
  recorded_pid="$LISTENER_PID"
  recorded_host="$HOST_PID"
  start_listener "$MAIN" 28102
  unrecorded_pid="$LISTENER_PID"
  kill_host "$recorded_host"
  process_running "$recorded_pid"

  start_host_process
  run_hook startup session-two "$MAIN" "$HOST_PID"
  [ "$status" -eq 0 ]
  [ "$output" = "$(dead_session_line dev 28101 "$recorded_pid" "$MAIN")" ]
  wait_until_gone "$recorded_pid"
  process_running "$unrecorded_pid"
  [ ! -e "$STATE/launches/$recorded_pid.tsv" ]
}

# ---------- /clear and compaction stop nothing ----------

@test "clear and compact stop nothing even with work pending; startup then stops both" {
  add_tree gone
  gone_tree="$TREE"
  gone_slot="$SLOT"
  gone_port=$((DEV_BASE + gone_slot))
  start_listener "$gone_tree" "$gone_port"
  gone_pid="$LISTENER_PID"
  rm -rf "$gone_tree"

  start_hosted_listener session-one "$MAIN" 28111 dev "$MAIN"
  recorded_pid="$LISTENER_PID"
  kill_host "$HOST_PID"

  for source_name in clear compact; do
    run_hook "$source_name" session-two "$MAIN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    process_running "$gone_pid"
    process_running "$recorded_pid"
    [ -f "$STATE/launches/$recorded_pid.tsv" ]
    grep -qF -- "$gone_tree" "$STATE/slots.tsv"
  done

  run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 2 ]
  printf '%s\n' "$output" | grep -qxF -- "$(removed_tree_line "$gone_port" "$gone_pid" "$gone_tree")"
  printf '%s\n' "$output" | grep -qxF -- "$(dead_session_line dev 28111 "$recorded_pid" "$MAIN")"
  wait_until_gone "$gone_pid"
  wait_until_gone "$recorded_pid"
}

# ---------- PID reuse ----------

@test "pid reuse: a record whose pid now has a different start time is dropped and the process survives" {
  start_listener "$MAIN" 28121
  reused_pid="$LISTENER_PID"
  identity="$(identity_of "$reused_pid")"
  command_text="${identity#*"$TAB"}"
  dead_pid
  write_launch_record "$reused_pid" "Thu Jan 1 00:00:00 1970" "$command_text" "$MAIN" 28121 dev reuse "$DEAD_PID" "never-matches" "$MAIN"

  start_hosted_listener session-one "$MAIN" 28122 dev "$MAIN"
  control_pid="$LISTENER_PID"
  kill_host "$HOST_PID"

  run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(dead_session_line dev 28122 "$control_pid" "$MAIN")" ]
  wait_until_gone "$control_pid"
  process_running "$reused_pid"
  [ ! -e "$STATE/launches/$reused_pid.tsv" ]
}

# ---------- removed-tree reap at session start ----------

@test "removed tree: a listener left in a deleted worktree is stopped from the main checkout" {
  add_tree gone
  gone_tree="$TREE"
  gone_port=$((DEV_BASE + SLOT))
  start_listener "$gone_tree" "$gone_port"
  gone_pid="$LISTENER_PID"
  rm -rf "$gone_tree"
  [ "$(git -C "$MAIN" branch --show-current)" = main ]

  run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(removed_tree_line "$gone_port" "$gone_pid" "$gone_tree")" ]
  wait_until_gone "$gone_pid"
  grep -qF -- "$gone_tree" "$STATE/slots.tsv" && return 1
  return 0
}

# ---------- a live tree is untouched, every arm ----------

@test "live tree: its recorded and unrecorded servers survive while both controls are stopped" {
  add_tree live
  live_tree="$TREE"
  live_slot="$SLOT"
  add_tree gone
  gone_tree="$TREE"
  gone_port=$((DEV_BASE + SLOT))

  start_listener "$live_tree" "$((DEV_BASE + live_slot))"
  live_unrecorded_pid="$LISTENER_PID"
  start_hosted_listener live-session "$live_tree" "$((STORYBOOK_BASE + live_slot))" storybook "$live_tree"
  live_recorded_pid="$LISTENER_PID"
  live_host="$HOST_PID"

  start_listener "$gone_tree" "$gone_port"
  gone_pid="$LISTENER_PID"
  rm -rf "$gone_tree"

  start_hosted_listener ended-session "$live_tree" 28131 dev "$live_tree"
  ended_pid="$LISTENER_PID"
  kill_host "$HOST_PID"

  run_hook startup session-two "$live_tree"
  [ "$status" -eq 0 ]
  [ "$(line_count "$output")" -eq 2 ]
  printf '%s\n' "$output" | grep -qxF -- "$(removed_tree_line "$gone_port" "$gone_pid" "$gone_tree")"
  printf '%s\n' "$output" | grep -qxF -- "$(dead_session_line dev 28131 "$ended_pid" "$live_tree")"
  wait_until_gone "$gone_pid"
  wait_until_gone "$ended_pid"
  process_running "$live_unrecorded_pid"
  process_running "$live_recorded_pid"
  process_running "$live_host"
  [ -f "$STATE/launches/$live_recorded_pid.tsv" ]
}

# ---------- the lock is not held across a stop ----------

@test "lock: a stop that waits out its full window leaves the slot lock free" {
  add_tree gone
  gone_tree="$TREE"
  gone_port=$((DEV_BASE + SLOT))
  marker="$SCRATCH/term-received"
  stubborn_log="$SCRATCH/stubborn.log"
  stubborn_source='const fs=require("fs");const server=require("net").createServer(socket=>socket.end());process.on("SIGTERM",()=>fs.writeFileSync(process.argv[2],"1"));server.listen({host:"127.0.0.1",port:Number(process.argv[1])},()=>console.log("listening "+process.pid))'
  (cd "$gone_tree" && nohup node -e "$stubborn_source" "$gone_port" "$marker" >"$stubborn_log" 2>&1 </dev/null 3>&- &)
  wait_for_listening "$stubborn_log"
  stubborn_pid="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$stubborn_log")"
  STARTED_PIDS+=("$stubborn_pid")
  rm -rf "$gone_tree"

  payload="$(printf '{"hook_event_name":"SessionStart","session_id":"session-two","source":"startup","cwd":"%s"}' "$MAIN")"
  printf '%s' "$payload" >"$SCRATCH/payload.json"
  (GAIA_PORTS_HOST_PID="$LIVE_HOST_PID" nohup bash "$HOOK" <"$SCRATCH/payload.json" >"$SCRATCH/hook.out" 2>"$SCRATCH/hook.err" 3>&- & printf '%s' "$!" >"$SCRATCH/hook.pid")
  hook_pid="$(cat "$SCRATCH/hook.pid")"
  STARTED_PIDS+=("$hook_pid")

  attempt=0
  while [ ! -f "$marker" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$marker" ]
  process_running "$hook_pid"

  GAIA_PORTS_LOCK_DEADLINE_SECONDS=1 run ports_lib gaia_ports_lock "$STATE"
  [ "$status" -eq 0 ]
  ports_lib gaia_ports_unlock "$STATE"

  attempt=0
  while process_running "$hook_pid" && [ "$attempt" -lt 150 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  wait_until_gone "$stubborn_pid"
  grep -qxF -- "$(removed_tree_line "$gone_port" "$stubborn_pid" "$gone_tree")" "$SCRATCH/hook.out"
}

@test "lock: a held lock skips the reclaim, says so on stderr, and a later run finishes the work" {
  add_tree gone
  gone_tree="$TREE"
  gone_port=$((DEV_BASE + SLOT))
  start_listener "$gone_tree" "$gone_port"
  gone_pid="$LISTENER_PID"
  rm -rf "$gone_tree"

  ports_lib gaia_ports_lock "$STATE"
  GAIA_PORTS_LOCK_DEADLINE_SECONDS=1 run ports_lib gaia_ports_lock "$STATE"
  [ "$status" -eq 1 ]

  GAIA_PORTS_LOCK_DEADLINE_SECONDS=1 run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -qF -- "slot lock"
  process_running "$gone_pid"
  grep -qF -- "$gone_tree" "$STATE/slots.tsv"
  ports_lib gaia_ports_unlock "$STATE"

  run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(removed_tree_line "$gone_port" "$gone_pid" "$gone_tree")" ]
  wait_until_gone "$gone_pid"
}

# ---------- reclaim answering 1 never aborts the hook ----------

@test "reclaim failing: git unable to list worktrees still lets the dead-session reap run and stops no removed-tree server" {
  add_tree gone
  gone_tree="$TREE"
  gone_port=$((DEV_BASE + SLOT))
  start_listener "$gone_tree" "$gone_port"
  gone_pid="$LISTENER_PID"
  rm -rf "$gone_tree"

  start_hosted_listener session-one "$MAIN" 28141 dev "$MAIN"
  recorded_pid="$LISTENER_PID"
  kill_host "$HOST_PID"

  stubs="$SCRATCH/stubs"
  mkdir -p "$stubs"
  printf '#!/bin/sh\ncase "$*" in *"worktree list"*) exit 1 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" >"$stubs/git"
  chmod +x "$stubs/git"

  PATH="$stubs:$PATH" run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "$(dead_session_line dev 28141 "$recorded_pid" "$MAIN")" ]
  wait_until_gone "$recorded_pid"
  process_running "$gone_pid"
  grep -qF -- "$gone_tree" "$STATE/slots.tsv"
}

# ---------- the stat gate ----------

@test "gate: empty state never runs lsof or ss, and a dead launch record does" {
  stubs="$SCRATCH/probe-stubs"
  mkdir -p "$stubs"
  for probe in lsof ss; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.record"\nexit 0\n' "$SCRATCH" "$probe" >"$stubs/$probe"
    chmod +x "$stubs/$probe"
  done
  : >"$SCRATCH/lsof.record"
  : >"$SCRATCH/ss.record"

  PATH="$stubs:$PATH" run_hook startup session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$SCRATCH/lsof.record" ]
  [ ! -s "$SCRATCH/ss.record" ]

  start_hosted_listener session-one "$MAIN" 28151 dev "$MAIN"
  kill_host "$HOST_PID"
  PATH="$stubs:$PATH" run_hook startup session-three "$MAIN"
  [ "$status" -eq 0 ]
  [ -s "$SCRATCH/lsof.record" ] || [ -s "$SCRATCH/ss.record" ]
}

# ---------- context line ----------

expected_context_line() {
  printf "GAIA ports for this worktree (slot %s): app http://localhost:%s, Storybook http://localhost:%s. Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports." \
    "$1" "$((DEV_BASE + $1))" "$((STORYBOOK_BASE + $1))"
}

@test "context line: compact and clear in a provisioned worktree print exactly the frozen line" {
  add_tree feature
  for source_name in compact clear; do
    run_hook "$source_name" session-two "$TREE"
    [ "$status" -eq 0 ]
    [ "$output" = "$(expected_context_line "$SLOT")" ]
  done
}

@test "context line: startup prints none, main prints none, and a worktree without a port file prints none" {
  add_tree feature
  run_hook startup session-two "$TREE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run_hook clear session-two "$MAIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -f "$TREE/frontend/.gaia-ports"
  run_hook compact session-two "$TREE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- session registration ----------

@test "registration: every source writes the session file with the host pid and start" {
  host_start="$(identity_of "$LIVE_HOST_PID")"
  host_start="${host_start%%"$TAB"*}"
  for source_name in startup resume clear compact; do
    run_hook "$source_name" "session-$source_name" "$MAIN"
    [ "$status" -eq 0 ]
    IFS=$'\t' read -r recorded_pid recorded_start _ <"$STATE/sessions/session-$source_name.tsv"
    [ "$recorded_pid" = "$LIVE_HOST_PID" ]
    [ "$recorded_start" = "$host_start" ]
  done
}

@test "registration: a path-shaped session id writes nothing outside sessions" {
  payload="$(printf '{"hook_event_name":"SessionStart","session_id":"../x","source":"startup","cwd":"%s"}' "$MAIN")"
  run --separate-stderr env GAIA_PORTS_HOST_PID="$LIVE_HOST_PID" bash "$HOOK" <<<"$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$STATE/x.tsv" ]
  [ ! -e "$STATE/sessions/x.tsv" ]
  [ ! -e "$MAIN/.gaia/local/x.tsv" ]
  [ -z "$(find "$SCRATCH" -name 'x.tsv' 2>/dev/null)" ]
}

# ---------- refusals ----------

@test "CI: with GITHUB_ACTIONS set the hook writes no session file and prints nothing" {
  payload="$(printf '{"hook_event_name":"SessionStart","session_id":"session-ci","source":"clear","cwd":"%s"}' "$MAIN")"
  run --separate-stderr env GITHUB_ACTIONS=true GAIA_PORTS_HOST_PID="$LIVE_HOST_PID" bash "$HOOK" <<<"$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$STATE/sessions/session-ci.tsv" ]
}

@test "payload: an empty payload exits 0 quietly and writes nothing" {
  run --separate-stderr env GAIA_PORTS_HOST_PID="$LIVE_HOST_PID" bash "$HOOK" <<<""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$STATE/sessions" ]
}
