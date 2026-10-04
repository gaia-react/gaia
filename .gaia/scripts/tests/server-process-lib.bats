#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/server-process-lib.sh, the library every
# automated dev-server stop goes through, and for the listener fixture the port
# suites share (.gaia/tests/fixtures/ports/listen.mjs).
#
# Run it once per process backend:
#   GAIA_PORTS_PROCESS_PROBE=lsof bash .gaia/scripts/bats5.sh .gaia/scripts/tests/server-process-lib.bats
#   GAIA_PORTS_PROCESS_PROBE=proc bash .gaia/scripts/bats5.sh .gaia/scripts/tests/server-process-lib.bats
# A backend the host lacks skips every test with the reason (the `proc` run
# needs Linux /proc and `ss`). Unset, the suite uses `auto`, and the "forced
# proc backend" tests below still exercise `proc` wherever it exists, so a
# default Linux run covers both backends.
#
# Every listener and stand-in host process a test starts is recorded in
# STARTED_PIDS and killed in teardown. Listeners run detached (a subshell that
# backgrounds and exits), so a stopped one is reaped by init instead of lingering
# as this shell's zombie; fd 3 is closed so bats does not wait on them.
#
# Library calls run in a child bash (run_library), never in the test shell: the
# library is written for no `set -e`, and a child keeps the test shell an
# ancestor of the caller, which the self and ancestor refusals rely on.

bats_require_minimum_version 1.5.0

setup() {
  LIBRARY_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)/server-process-lib.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  LISTENER_FIXTURE="$REPO_ROOT/.gaia/tests/fixtures/ports/listen.mjs"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  STATE="$SCRATCH/state"
  mkdir -p "$STATE"
  STARTED_PIDS=()
  TAB=$'\t'
  unset CLAUDE_CODE_SESSION_ID GAIA_PORTS_HOST_PID GAIA_PORTS_STATE_DIRECTORY
  unset GAIA_PORTS_DEV_BASE_PORT GAIA_PORTS_STORYBOOK_BASE_PORT
  export GAIA_PORTS_PROCESS_PROBE="${GAIA_PORTS_PROCESS_PROBE:-auto}"

  command -v node >/dev/null 2>&1 || skip "node is required for the listener fixture"
  case "$GAIA_PORTS_PROCESS_PROBE" in
    lsof)
      command -v lsof >/dev/null 2>&1 || skip "GAIA_PORTS_PROCESS_PROBE=lsof but lsof is not installed"
      ;;
    proc)
      [ -e /proc/self ] || skip "GAIA_PORTS_PROCESS_PROBE=proc needs Linux /proc; this host has none"
      command -v ss >/dev/null 2>&1 || skip "GAIA_PORTS_PROCESS_PROBE=proc needs ss; not installed"
      ;;
    auto)
      if ! command -v lsof >/dev/null 2>&1; then
        { [ -e /proc/self ] && command -v ss >/dev/null 2>&1; } || skip "no process backend (lsof, or /proc with ss) on this host"
      fi
      ;;
    *) skip "unrecognized GAIA_PORTS_PROCESS_PROBE '$GAIA_PORTS_PROCESS_PROBE'" ;;
  esac
}

teardown() {
  local started_pid
  for started_pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$started_pid" ] && kill -KILL "$started_pid" 2>/dev/null
  done
  return 0
}

# run_library <function> <args...>: runs one library function in a child bash.
run_library() {
  bash -c '. "$1"; shift; "$@"' _ "$LIBRARY_SCRIPT" "$@"
}

# run_library_with <override-source> <function> <args...>: as run_library, with
# a function override evaluated after sourcing (the stub seam).
run_library_with() {
  local override="$1"
  shift
  bash -c '. "$1"; eval "$2"; shift 2; "$@"' _ "$LIBRARY_SCRIPT" "$override" "$@"
}

random_port() {
  printf '%s' "$((20000 + RANDOM % 10000))"
}

# process_running <pid>: rc 0 when the process exists and is not a zombie.
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

# wait_until_gone <pid>: polls up to 5 s for the process to exit.
wait_until_gone() {
  local attempt=0
  while [ "$attempt" -lt 50 ]; do
    process_running "$1" || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

# wait_for_listening <log>: rc 0 once the fixture printed its line, 1 when it
# failed to bind or never answered within 10 s.
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

# start_listener <directory> <port> [host]: a detached fixture listener with
# cwd <directory>. Sets LISTENER_PID and LISTENER_LOG; rc 1 when it fails to bind.
start_listener() {
  local directory="$1" port="$2" host="${3:-127.0.0.1}"
  LISTENER_LOG="$SCRATCH/listener-$port-$RANDOM.log"
  (cd "$directory" && nohup node "$LISTENER_FIXTURE" "$port" "$host" >"$LISTENER_LOG" 2>&1 </dev/null 3>&- &)
  wait_for_listening "$LISTENER_LOG" || return 1
  LISTENER_PID="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$LISTENER_LOG")"
  [ -n "$LISTENER_PID" ] || return 1
  STARTED_PIDS+=("$LISTENER_PID")
}

# start_listener_on_free_port <directory> [host]: retries random ports until one
# binds. Sets LISTENER_PORT, LISTENER_PID, LISTENER_LOG.
start_listener_on_free_port() {
  local directory="$1" host="${2:-127.0.0.1}" attempt=0
  while [ "$attempt" -lt 8 ]; do
    LISTENER_PORT="$(random_port)"
    if start_listener "$directory" "$LISTENER_PORT" "$host"; then
      return 0
    fi
    grep -q 'EADDRINUSE' "$LISTENER_LOG" 2>/dev/null || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

# start_host_process: a detached stand-in for a Claude session host. Sets HOST_PID.
start_host_process() {
  local pid_file="$SCRATCH/host-$RANDOM.pid"
  (nohup sleep 300 >/dev/null 2>&1 </dev/null 3>&- & printf '%s' "$!" >"$pid_file")
  HOST_PID="$(cat "$pid_file")"
  STARTED_PIDS+=("$HOST_PID")
}

# dead_pid: the pid of a process that has exited. Sets DEAD_PID.
dead_pid() {
  start_host_process
  DEAD_PID="$HOST_PID"
  kill -KILL "$DEAD_PID"
  wait_until_gone "$DEAD_PID"
}

# read_identity <pid>: sets IDENTITY_START and IDENTITY_COMMAND.
read_identity() {
  local identity
  identity="$(run_library gaia_server_process_identity "$1")"
  IDENTITY_START="${identity%%"$TAB"*}"
  IDENTITY_COMMAND="${identity#*"$TAB"}"
  [ -n "$IDENTITY_START" ] && [ -n "$IDENTITY_COMMAND" ]
}

# make_tree <path>: a checkout root (a `.git` directory) with a frontend folder.
make_tree() {
  mkdir -p "$1/.git" "$1/frontend"
}

# write_session <session-id> <host-pid>: a session record for a live host.
write_session() {
  local identity
  identity="$(run_library gaia_server_process_identity "$2")"
  mkdir -p "$STATE/sessions"
  printf '%s\t%s\t%s\n' "$2" "$identity" "$(date +%s)" >"$STATE/sessions/$1.tsv"
}

# write_launch_record <pid> <start> <command> <cwd> <port> <kind> <session>
# <host-pid> <host-start> <tree-root>
write_launch_record() {
  mkdir -p "$STATE/launches"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >"$STATE/launches/$1.tsv"
}

# ---------- listener fixture ----------

@test "fixture: prints listening with its own PID and holds the port" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  process_running "$LISTENER_PID"
  ps -o command= -p "$LISTENER_PID" | grep -qF -- "listen.mjs $LISTENER_PORT 127.0.0.1"
  run run_library gaia_server_listeners "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  [ "$output" = "$LISTENER_PORT$TAB$LISTENER_PID" ]
}

@test "fixture: exits 0 on SIGTERM" {
  local port log pid exit_status=0
  port="$(random_port)"
  log="$SCRATCH/sigterm.log"
  node "$LISTENER_FIXTURE" "$port" 127.0.0.1 >"$log" 2>&1 3>&- &
  pid=$!
  STARTED_PIDS+=("$pid")
  wait_for_listening "$log"
  kill -TERM "$pid"
  wait "$pid" || exit_status=$?
  [ "$exit_status" -eq 0 ]
}

@test "fixture: a second instance on the same port exits 1 with EADDRINUSE on stderr" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run --separate-stderr node "$LISTENER_FIXTURE" "$LISTENER_PORT" 127.0.0.1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -qF -- 'EADDRINUSE' <<<"$stderr"
}

@test "fixture: its cwd is the directory it was started from" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run run_library gaia_server_process_cwds "$LISTENER_PID"
  [ "$status" -eq 0 ]
  [ "$output" = "$LISTENER_PID$TAB$SCRATCH/tree/frontend${TAB}live" ]
}

# ---------- listeners ----------

@test "listeners: IPv4 and IPv6 listeners are both reported by one call" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend" 127.0.0.1
  local ipv4_port="$LISTENER_PORT" ipv4_pid="$LISTENER_PID"
  if ! start_listener_on_free_port "$SCRATCH/tree/frontend" ::1; then
    skip "this host cannot bind ::1 (no IPv6 loopback): $(cat "$LISTENER_LOG")"
  fi
  local ipv6_port="$LISTENER_PORT" ipv6_pid="$LISTENER_PID"
  run run_library gaia_server_listeners "$ipv4_port" "$ipv6_port"
  [ "$status" -eq 0 ]
  grep -qxF -- "$ipv4_port$TAB$ipv4_pid" <<<"$output"
  grep -qxF -- "$ipv6_port$TAB$ipv6_pid" <<<"$output"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "listeners: a port with no listener prints nothing" {
  run run_library gaia_server_listeners "$(random_port)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- owning tree ----------

@test "owning tree: a nested worktree owns its own paths, never the checkout around it" {
  make_tree "$SCRATCH/main"
  mkdir -p "$SCRATCH/main/.claude/worktrees/w/frontend"
  printf 'gitdir: %s/main/.git/worktrees/w\n' "$SCRATCH" >"$SCRATCH/main/.claude/worktrees/w/.git"
  run run_library gaia_server_owning_tree "$SCRATCH/main/.claude/worktrees/w/frontend"
  [ "$status" -eq 0 ]
  [ "$output" = "$SCRATCH/main/.claude/worktrees/w" ]
  run run_library gaia_server_owning_tree "$SCRATCH/main/frontend"
  [ "$output" = "$SCRATCH/main" ]
}

@test "owning tree: rc 1 for a missing directory and for a path with no .git ancestor" {
  run run_library gaia_server_owning_tree "$SCRATCH/does-not-exist"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # A host with a .git above the scratch directory makes the second half
  # unprovable rather than wrong.
  local ancestor="$SCRATCH"
  while [ -n "$ancestor" ]; do
    [ -e "$ancestor/.git" ] && skip "an ancestor of the scratch directory holds .git: $ancestor"
    ancestor="${ancestor%/*}"
  done
  [ -e /.git ] && skip "the filesystem root holds .git"
  mkdir -p "$SCRATCH/plain/deeper"
  run run_library gaia_server_owning_tree "$SCRATCH/plain/deeper"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------- listener owner ----------

@test "owner: own for a listener whose cwd is inside the tree" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "own $LISTENER_PID" ]
}

@test "owner: foreign with the cwd for a listener in another tree" {
  make_tree "$SCRATCH/tree"
  make_tree "$SCRATCH/other"
  start_listener_on_free_port "$SCRATCH/other/frontend"
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "foreign $LISTENER_PID $SCRATCH/other/frontend" ]
}

@test "owner: tree /x/tree does not own a listener in /x/tree-2" {
  make_tree "$SCRATCH/tree"
  make_tree "$SCRATCH/tree-2"
  start_listener_on_free_port "$SCRATCH/tree-2/frontend"
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$output" = "foreign $LISTENER_PID $SCRATCH/tree-2/frontend" ]
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree-2"
  [ "$output" = "own $LISTENER_PID" ]
}

@test "owner: free when nothing listens" {
  make_tree "$SCRATCH/tree"
  run run_library gaia_server_listener_owner "$(random_port)" "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "free" ]
}

@test "owner: unknown when no process backend is available, even with a listener present" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  # A PATH carrying every tool the library needs except lsof and ss.
  local restricted_bin="$SCRATCH/restricted-bin" tool tool_path bash_path
  mkdir -p "$restricted_bin"
  for tool in ps stat readlink sleep date mv rm mkdir cut tr cat dirname; do
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$restricted_bin/$tool"
  done
  bash_path="$(command -v bash)"
  [ ! -e "$restricted_bin/lsof" ]
  run env PATH="$restricted_bin" "$bash_path" -c '. "$1"; shift; "$@"' _ "$LIBRARY_SCRIPT" gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  run env PATH="$restricted_bin" "$bash_path" -c '. "$1"; gaia_server_listeners "$2"; echo "rc=$?"' _ "$LIBRARY_SCRIPT" "$LISTENER_PORT"
  [ "$output" = "rc=3" ]
}

@test "owner: a nested worktree's listener is foreign to main and own to the worktree" {
  make_tree "$SCRATCH/main"
  local worktree="$SCRATCH/main/.claude/worktrees/w"
  mkdir -p "$worktree/frontend"
  printf 'gitdir: %s/main/.git/worktrees/w\n' "$SCRATCH" >"$worktree/.git"
  start_listener_on_free_port "$worktree/frontend"
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/main"
  [ "$status" -eq 0 ]
  [ "$output" = "foreign $LISTENER_PID $worktree/frontend" ]
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$worktree"
  [ "$output" = "own $LISTENER_PID" ]
}

@test "owner: a listener whose cwd was deleted is foreign" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  rm -rf "$SCRATCH/tree/frontend"
  mkdir -p "$SCRATCH/tree/frontend"
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$output" = "foreign $LISTENER_PID $SCRATCH/tree/frontend" ]
}

# ---------- removed-tree stop ----------

@test "removed tree: a listener left in a removed tree is stopped and reported" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  rm -rf "$SCRATCH/tree"
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  [ "$output" = "GAIA stopped a server on port $LISTENER_PORT (PID $LISTENER_PID) left running from removed worktree $SCRATCH/tree." ]
  wait_until_gone "$LISTENER_PID"
}

@test "removed tree refusal: a live tree's listener survives and nothing is printed" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  process_running "$LISTENER_PID"
}

@test "removed tree refusal: a listener in /x/tree-2 is not under removed tree /x/tree" {
  # No .git in the sibling, so the path boundary alone decides.
  mkdir -p "$SCRATCH/tree-2/frontend"
  start_listener_on_free_port "$SCRATCH/tree-2/frontend"
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ -z "$output" ]
  process_running "$LISTENER_PID"
  read_identity "$LISTENER_PID"
  run run_library gaia_server_stop_verified "$LISTENER_PID" "$IDENTITY_START" "$IDENTITY_COMMAND" "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 1 ]
  process_running "$LISTENER_PID"
}

@test "removed tree refusal: a live checkout nested between the tree and the cwd makes it ambiguous" {
  make_tree "$SCRATCH/tree"
  local nested="$SCRATCH/tree/.claude/worktrees/n"
  mkdir -p "$nested/frontend"
  printf 'gitdir: elsewhere\n' >"$nested/.git"
  start_listener_on_free_port "$nested/frontend"
  rm -rf "$nested/frontend"
  mkdir -p "$nested/frontend"
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ -z "$output" ]
  process_running "$LISTENER_PID"
}

@test "recreated tree: a cwd removed and recreated at the same path reads deleted and is stopped" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  local old_pid="$LISTENER_PID" port="$LISTENER_PORT"
  rm -rf "$SCRATCH/tree"
  make_tree "$SCRATCH/tree"
  run run_library gaia_server_process_cwds "$old_pid"
  [ "$output" = "$old_pid$TAB$SCRATCH/tree/frontend${TAB}deleted" ]
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$port"
  [ "$output" = "GAIA stopped a server on port $port (PID $old_pid) left running from removed worktree $SCRATCH/tree." ]
  wait_until_gone "$old_pid"

  start_listener "$SCRATCH/tree/frontend" "$port"
  run run_library gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$port"
  [ -z "$output" ]
  process_running "$LISTENER_PID"
}

@test "removed tree refusal: an unreadable cwd never stops" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  rm -rf "$SCRATCH/tree"
  local stub='gaia_server_process_cwds() { local pid; for pid in "$@"; do printf "%s\tunknown\tunknown\n" "$pid"; done; }'
  run run_library_with "$stub" gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  process_running "$LISTENER_PID"
  # The verified stop re-reads the cwd too; this pins the selection layer on
  # its own: an unreadable cwd is never even handed to the stop.
  local recorder='gaia_server_stop_verified() { printf "attempted %s\n" "$1"; return 0; }'
  run run_library_with "$stub
$recorder" gaia_server_stop_removed_tree_listeners "$SCRATCH/tree" "$LISTENER_PORT"
  [ -z "$output" ]
  process_running "$LISTENER_PID"
}

# ---------- verified stop ----------

@test "verified stop: each mismatched field refuses with rc 1 and the process survives" {
  make_tree "$SCRATCH/tree"
  make_tree "$SCRATCH/other"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  read_identity "$LISTENER_PID"
  local unused_port
  unused_port="$(random_port)"
  [ "$unused_port" != "$LISTENER_PORT" ] || unused_port=$((LISTENER_PORT + 1))

  run run_library gaia_server_stop_verified "$LISTENER_PID" "Mon Jan 1 00:00:00 2001" "$IDENTITY_COMMAND" "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 1 ]
  process_running "$LISTENER_PID"

  run run_library gaia_server_stop_verified "$LISTENER_PID" "$IDENTITY_START" "node something-else.mjs" "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 1 ]
  process_running "$LISTENER_PID"

  run run_library gaia_server_stop_verified "$LISTENER_PID" "$IDENTITY_START" "$IDENTITY_COMMAND" "$SCRATCH/other" "$LISTENER_PORT"
  [ "$status" -eq 1 ]
  process_running "$LISTENER_PID"

  run run_library gaia_server_stop_verified "$LISTENER_PID" "$IDENTITY_START" "$IDENTITY_COMMAND" "$SCRATCH/tree" "$unused_port"
  [ "$status" -eq 1 ]
  process_running "$LISTENER_PID"
}

@test "verified stop: every field matching stops the process with rc 0" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  read_identity "$LISTENER_PID"
  run run_library gaia_server_stop_verified "$LISTENER_PID" "$IDENTITY_START" "$IDENTITY_COMMAND" "$SCRATCH/tree" "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  wait_until_gone "$LISTENER_PID"
}

@test "verified stop: an exited PID returns rc 2" {
  dead_pid
  run run_library gaia_server_stop_verified "$DEAD_PID" "Mon Jan 1 00:00:00 2001" "sleep 300" "$SCRATCH" "$(random_port)"
  [ "$status" -eq 2 ]
}

@test "verified stop refusal: the test shell's own PID returns rc 1 and the shell survives" {
  read_identity "$$"
  run run_library gaia_server_stop_verified "$$" "$IDENTITY_START" "$IDENTITY_COMMAND" "/" "$(random_port)"
  [ "$status" -eq 1 ]
  grep -qF -- "ancestors" <<<"$output"
  process_running "$$"
}

@test "verified stop refusal: the caller's own ancestor is never signalled even when every field matches" {
  make_tree "$SCRATCH/tree"
  local port
  port="$(random_port)"
  # A listener that runs the library as its own child, so the target it hands
  # over (its own PID, its own cwd, the port it holds) matches on every field
  # and only the ancestor refusal stands between it and SIGTERM.
  local child_script='. "$1"
identity="$(gaia_server_process_identity "$PPID")"
start="${identity%%	*}"
command="${identity#*	}"
gaia_server_stop_verified "$PPID" "$start" "$command" "$PWD" "$2"
echo "rc=$?"
gaia_server_listeners "$2"'
  local node_script='
const { createServer } = require("node:net");
const { spawnSync } = require("node:child_process");
const [childScript, library, port] = process.argv.slice(1);
const server = createServer();
server.listen({ host: "127.0.0.1", port: Number(port) }, () => {
  const result = spawnSync("bash", ["-c", childScript, "_", library, port], { encoding: "utf8" });
  process.stdout.write(`${result.stdout}${result.stderr}alive ${process.pid}\n`);
  server.close();
});
server.on("error", (error) => { process.stdout.write(`bind-failed ${error.code}\n`); });'
  run bash -c 'cd "$1" && node -e "$2" "$3" "$4" "$5" 3>&-' _ "$SCRATCH/tree/frontend" "$node_script" "$child_script" "$LIBRARY_SCRIPT" "$port"
  [ "$status" -eq 0 ]
  grep -qF -- "bind-failed" <<<"$output" && skip "random port $port was taken"
  grep -qxF -- "rc=1" <<<"$output"
  grep -qF -- "ancestors" <<<"$output"
  # Positive control: the library saw the listener on the port, so every
  # other field could have matched.
  grep -qE -- "^$port${TAB}[0-9]+\$" <<<"$output"
  grep -qE -- '^alive [0-9]+$' <<<"$output"
}

# ---------- dead-session reap ----------

@test "PID reuse: a live process whose start time differs from the record survives and the record is dropped" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  read_identity "$LISTENER_PID"
  dead_pid
  write_launch_record "$LISTENER_PID" "Mon Jan 1 00:00:00 2001" "$IDENTITY_COMMAND" "$SCRATCH/tree/frontend" \
    "$LISTENER_PORT" dev session-a "$DEAD_PID" "Mon Jan 1 00:00:00 2001" "$SCRATCH/tree"
  run run_library gaia_server_reap_dead_sessions "$STATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  process_running "$LISTENER_PID"
  [ ! -e "$STATE/launches/$LISTENER_PID.tsv" ]
}

@test "dead session: a recorded server whose host died is stopped, reported, and its record dropped" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  read_identity "$LISTENER_PID"
  local server_start="$IDENTITY_START" server_command="$IDENTITY_COMMAND"
  start_host_process
  read_identity "$HOST_PID"
  write_session session-a "$HOST_PID"
  write_launch_record "$LISTENER_PID" "$server_start" "$server_command" "$SCRATCH/tree/frontend" \
    "$LISTENER_PORT" dev session-a "$HOST_PID" "$IDENTITY_START" "$SCRATCH/tree"
  kill -KILL "$HOST_PID"
  wait_until_gone "$HOST_PID"
  run run_library gaia_server_reap_dead_sessions "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = "GAIA stopped a dev server on port $LISTENER_PORT (PID $LISTENER_PID) launched by an ended Claude session in $SCRATCH/tree." ]
  wait_until_gone "$LISTENER_PID"
  [ ! -e "$STATE/launches/$LISTENER_PID.tsv" ]
  [ ! -e "$STATE/sessions/session-a.tsv" ]
}

@test "dead session refusal: a live host keeps its server running and its record" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  read_identity "$LISTENER_PID"
  local server_start="$IDENTITY_START" server_command="$IDENTITY_COMMAND"
  start_host_process
  read_identity "$HOST_PID"
  write_session session-a "$HOST_PID"
  write_launch_record "$LISTENER_PID" "$server_start" "$server_command" "$SCRATCH/tree/frontend" \
    "$LISTENER_PORT" dev session-a "$HOST_PID" "$IDENTITY_START" "$SCRATCH/tree"
  run run_library gaia_server_reap_dead_sessions "$STATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  process_running "$LISTENER_PID"
  [ -f "$STATE/launches/$LISTENER_PID.tsv" ]
  [ -f "$STATE/sessions/session-a.tsv" ]
}

# ---------- session registration ----------

@test "session register: records the host named by GAIA_PORTS_HOST_PID and rewrites only on change" {
  start_host_process
  read_identity "$HOST_PID"
  GAIA_PORTS_HOST_PID="$HOST_PID" run run_library gaia_server_session_register "$STATE" session-a
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(cat "$STATE/sessions/session-a.tsv")"
  case "$first_line" in
    "$HOST_PID$TAB$IDENTITY_START$TAB$IDENTITY_COMMAND$TAB"*) ;;
    *) return 1 ;;
  esac
  # A changed epoch alone is not a change: the file keeps its first epoch.
  printf '%s\n' "${first_line%"$TAB"*}${TAB}1" >"$STATE/sessions/session-a.tsv"
  GAIA_PORTS_HOST_PID="$HOST_PID" run run_library gaia_server_session_register "$STATE" session-a
  [ "$(cat "$STATE/sessions/session-a.tsv")" = "${first_line%"$TAB"*}${TAB}1" ]
}

@test "session register refusal: an invalid session id writes nothing" {
  start_host_process
  GAIA_PORTS_HOST_PID="$HOST_PID" run run_library gaia_server_session_register "$STATE/inner" ../evil
  [ "$status" -eq 1 ]
  [ ! -e "$STATE/evil.tsv" ]
  [ ! -e "$STATE/inner" ]
}

# ---------- launch recording ----------

@test "record launch: a server descended from a registered live host is recorded with its identity" {
  make_tree "$SCRATCH/tree"
  local port log pid_file host_pid server_pid
  port="$(random_port)"
  log="$SCRATCH/descendant.log"
  pid_file="$SCRATCH/descendant-host.pid"
  (nohup bash -c 'cd "$1" && node "$2" "$3" 127.0.0.1 >"$4" 2>&1; exit 0' _ "$SCRATCH/tree/frontend" "$LISTENER_FIXTURE" "$port" "$log" \
    >/dev/null 2>&1 </dev/null 3>&- & printf '%s' "$!" >"$pid_file")
  host_pid="$(cat "$pid_file")"
  STARTED_PIDS+=("$host_pid")
  wait_for_listening "$log" || skip "random port $port was taken"
  server_pid="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$log")"
  STARTED_PIDS+=("$server_pid")
  [ "$server_pid" != "$host_pid" ]

  GAIA_PORTS_HOST_PID="$host_pid" run run_library gaia_server_session_register "$STATE" session-a
  [ "$status" -eq 0 ]
  read_identity "$host_pid"
  local host_start="$IDENTITY_START"
  read_identity "$server_pid"
  run run_library gaia_server_record_launch "$STATE" "$server_pid" "$port" dev "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/launches/$server_pid.tsv")" = "$server_pid$TAB$IDENTITY_START$TAB$IDENTITY_COMMAND$TAB$SCRATCH/tree/frontend$TAB$port${TAB}dev${TAB}session-a$TAB$host_pid$TAB$host_start$TAB$SCRATCH/tree" ]
}

@test "record launch refusal: no registered ancestor and no session id writes nothing" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  start_host_process
  write_session session-a "$HOST_PID"
  run run_library gaia_server_record_launch "$STATE" "$LISTENER_PID" "$LISTENER_PORT" dev "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/launches" ] || [ -z "$(ls -A "$STATE/launches")" ]
}

@test "record launch: a reparented server falls back to the session CLAUDE_CODE_SESSION_ID names" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  start_host_process
  write_session session-a "$HOST_PID"
  read_identity "$HOST_PID"
  CLAUDE_CODE_SESSION_ID=session-a run run_library gaia_server_record_launch "$STATE" "$LISTENER_PID" "$LISTENER_PORT" storybook "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  local record
  record="$(cat "$STATE/launches/$LISTENER_PID.tsv")"
  case "$record" in
    *"${TAB}storybook${TAB}session-a$TAB$HOST_PID$TAB$IDENTITY_START$TAB$SCRATCH/tree") ;;
    *) return 1 ;;
  esac
}

@test "record launch refusal: CLAUDE_CODE_SESSION_ID=../evil writes nothing anywhere" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  start_host_process
  mkdir -p "$STATE/sessions"
  write_session session-a "$HOST_PID"
  cp "$STATE/sessions/session-a.tsv" "$STATE/evil.tsv"
  local before
  before="$(cd "$SCRATCH" && find . | LC_ALL=C sort)"
  CLAUDE_CODE_SESSION_ID=../evil run run_library gaia_server_record_launch "$STATE" "$LISTENER_PID" "$LISTENER_PORT" dev "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$(cd "$SCRATCH" && find . | LC_ALL=C sort)" = "$before" ]
}

@test "record launch CLI: writes under GAIA_PORTS_STATE_DIRECTORY and refuses bad usage with exit 2" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  start_host_process
  write_session session-a "$HOST_PID"
  GAIA_PORTS_STATE_DIRECTORY="$STATE" CLAUDE_CODE_SESSION_ID=session-a run bash "$LIBRARY_SCRIPT" --record-launch \
    --pid "$LISTENER_PID" --port "$LISTENER_PORT" --kind dev --tree "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ -f "$STATE/launches/$LISTENER_PID.tsv" ]
  run bash "$LIBRARY_SCRIPT" --record-launch --pid "$LISTENER_PID" --port "$LISTENER_PORT" --kind web --tree "$SCRATCH/tree"
  [ "$status" -eq 2 ]
  run bash "$LIBRARY_SCRIPT" --listener-owner not-a-port "$SCRATCH/tree"
  [ "$status" -eq 2 ]
  run bash "$LIBRARY_SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "listener owner CLI: prints the owner and exits 0" {
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run bash "$LIBRARY_SCRIPT" --listener-owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$status" -eq 0 ]
  [ "$output" = "own $LISTENER_PID" ]
  run bash "$LIBRARY_SCRIPT" --listeners "$LISTENER_PORT"
  [ "$status" -eq 0 ]
  [ "$output" = "$LISTENER_PORT$TAB$LISTENER_PID" ]
}

# ---------- cleanup gate ----------

# make_probe_recorders: lsof and ss stubs that log each call, first on PATH.
make_probe_recorders() {
  RECORDER_BIN="$SCRATCH/recorder-bin"
  RECORDS="$SCRATCH/records"
  mkdir -p "$RECORDER_BIN" "$RECORDS"
  local probe
  for probe in lsof ss; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.calls"\nexit 1\n' "$RECORDS" "$probe" >"$RECORDER_BIN/$probe"
    chmod +x "$RECORDER_BIN/$probe"
  done
}

@test "cleanup gate: empty state returns 1 without invoking lsof or ss" {
  make_probe_recorders
  PATH="$RECORDER_BIN:$PATH" run run_library gaia_server_cleanup_needed "$STATE"
  [ "$status" -eq 1 ]
  [ ! -s "$RECORDS/lsof.calls" ]
  [ ! -s "$RECORDS/ss.calls" ]
  # Positive control: the recorders do capture a probe the library makes.
  PATH="$RECORDER_BIN:$PATH" run run_library gaia_server_listeners 21000
  [ -s "$RECORDS/lsof.calls" ] || [ -s "$RECORDS/ss.calls" ]
}

@test "cleanup gate: a live host's record, a present slot tree, and no tombstone return 1" {
  make_tree "$SCRATCH/tree"
  printf '1\t%s\t1:2\n' "$SCRATCH/tree" >"$STATE/slots.tsv"
  mkdir -p "$STATE/tombstones"
  start_host_process
  read_identity "$HOST_PID"
  write_launch_record 4242 "Mon Jan 1 00:00:00 2001" "node x" "$SCRATCH/tree/frontend" 5174 dev session-a "$HOST_PID" "$IDENTITY_START" "$SCRATCH/tree"
  run run_library gaia_server_cleanup_needed "$STATE"
  [ "$status" -eq 1 ]
}

@test "cleanup gate: a launch record whose host is dead returns 0" {
  dead_pid
  write_launch_record 4242 "Mon Jan 1 00:00:00 2001" "node x" "$SCRATCH/tree/frontend" 5174 dev session-a "$DEAD_PID" "Mon Jan 1 00:00:00 2001" "$SCRATCH/tree"
  run run_library gaia_server_cleanup_needed "$STATE"
  [ "$status" -eq 0 ]
}

@test "cleanup gate: a ledger entry whose directory is missing returns 0" {
  printf '1\t%s\t1:2\n' "$SCRATCH/gone" >"$STATE/slots.tsv"
  run run_library gaia_server_cleanup_needed "$STATE"
  [ "$status" -eq 0 ]
}

@test "cleanup gate: a tombstone file returns 0" {
  mkdir -p "$STATE/tombstones"
  printf '1\t%s\t%s\n' "$SCRATCH/gone" "$(date +%s)" >"$STATE/tombstones/1.$(date +%s).tsv"
  run run_library gaia_server_cleanup_needed "$STATE"
  [ "$status" -eq 0 ]
}

# ---------- tombstone reap ----------

# setup_tombstoned_listener <slot>: a listener on the slot's dev port inside a
# tree that is then removed; the port bases are pinned so the slot maps to it.
setup_tombstoned_listener() {
  local slot="$1"
  make_tree "$SCRATCH/removed"
  start_listener_on_free_port "$SCRATCH/removed/frontend"
  export GAIA_PORTS_DEV_BASE_PORT=$((LISTENER_PORT - slot))
  export GAIA_PORTS_STORYBOOK_BASE_PORT=$((LISTENER_PORT + 1 - slot))
  rm -rf "$SCRATCH/removed"
  mkdir -p "$STATE/tombstones"
}

@test "tombstone reap: stops the qualifying listener, drops the stale record, deletes the tombstone" {
  setup_tombstoned_listener 3
  local now
  now="$(date +%s)"
  printf '3\t%s\t%s\n' "$SCRATCH/removed" "$now" >"$STATE/tombstones/3.$now.tsv"
  dead_pid
  write_launch_record "$DEAD_PID" "Mon Jan 1 00:00:00 2001" "node gone" "$SCRATCH/removed/frontend" "$LISTENER_PORT" dev session-a "$DEAD_PID" "Mon Jan 1 00:00:00 2001" "$SCRATCH/removed"
  run run_library gaia_server_reap_tombstones "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = "GAIA stopped a server on port $LISTENER_PORT (PID $LISTENER_PID) left running from removed worktree $SCRATCH/removed." ]
  wait_until_gone "$LISTENER_PID"
  [ ! -e "$STATE/launches/$DEAD_PID.tsv" ]
  [ ! -e "$STATE/tombstones/3.$now.tsv" ]
}

@test "tombstone reap: an expired tombstone's qualifying listener is stopped before the tombstone is deleted" {
  setup_tombstoned_listener 2
  local old_epoch=$(($(date +%s) - 8 * 24 * 60 * 60))
  printf '2\t%s\t%s\n' "$SCRATCH/removed" "$old_epoch" >"$STATE/tombstones/2.$old_epoch.tsv"
  run run_library gaia_server_reap_tombstones "$STATE"
  [ "$output" = "GAIA stopped a server on port $LISTENER_PORT (PID $LISTENER_PID) left running from removed worktree $SCRATCH/removed." ]
  wait_until_gone "$LISTENER_PID"
  [ ! -e "$STATE/tombstones/2.$old_epoch.tsv" ]
}

@test "tombstone reap: a tombstone with no qualifying listener is deleted and the live tree's listener survives" {
  make_tree "$SCRATCH/live"
  start_listener_on_free_port "$SCRATCH/live/frontend"
  export GAIA_PORTS_DEV_BASE_PORT=$((LISTENER_PORT - 4))
  export GAIA_PORTS_STORYBOOK_BASE_PORT=$((LISTENER_PORT + 1 - 4))
  mkdir -p "$STATE/tombstones"
  local now
  now="$(date +%s)"
  printf '4\t%s\t%s\n' "$SCRATCH/removed" "$now" >"$STATE/tombstones/4.$now.tsv"
  run run_library gaia_server_reap_tombstones "$STATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  process_running "$LISTENER_PID"
  [ ! -e "$STATE/tombstones/4.$now.tsv" ]
}

@test "tombstone reap: a still-qualifying listener keeps a young tombstone and an old one expires only after the stop attempt" {
  setup_tombstoned_listener 5
  local now old_epoch
  now="$(date +%s)"
  old_epoch=$((now - 8 * 24 * 60 * 60))
  printf '5\t%s\t%s\n' "$SCRATCH/removed" "$now" >"$STATE/tombstones/5.$now.tsv"
  # A stop that always skips leaves the listener qualifying.
  local stub='gaia_server_stop_verified() { printf "attempted %s\n" "$1" >&2; return 1; }'
  run --separate-stderr run_library_with "$stub" gaia_server_reap_tombstones "$STATE"
  [ -f "$STATE/tombstones/5.$now.tsv" ]
  grep -qxF -- "attempted $LISTENER_PID" <<<"$stderr"
  process_running "$LISTENER_PID"

  rm -f "$STATE/tombstones/5.$now.tsv"
  printf '5\t%s\t%s\n' "$SCRATCH/removed" "$old_epoch" >"$STATE/tombstones/5.$old_epoch.tsv"
  run --separate-stderr run_library_with "$stub" gaia_server_reap_tombstones "$STATE"
  grep -qxF -- "attempted $LISTENER_PID" <<<"$stderr"
  [ ! -e "$STATE/tombstones/5.$old_epoch.tsv" ]
}

# ---------- forced proc backend (Linux) ----------

@test "forced proc backend: listeners and live and deleted cwds read through ss and /proc" {
  [ -e /proc/self ] || skip "the proc backend needs Linux /proc; this host has none"
  command -v ss >/dev/null 2>&1 || skip "the proc backend needs ss; not installed"
  export GAIA_PORTS_PROCESS_PROBE=proc
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run run_library gaia_server_listeners "$LISTENER_PORT"
  [ "$output" = "$LISTENER_PORT$TAB$LISTENER_PID" ]
  run run_library gaia_server_process_cwds "$LISTENER_PID"
  [ "$output" = "$LISTENER_PID$TAB$SCRATCH/tree/frontend${TAB}live" ]
  run run_library gaia_server_listener_owner "$LISTENER_PORT" "$SCRATCH/tree"
  [ "$output" = "own $LISTENER_PID" ]
  rm -rf "$SCRATCH/tree"
  make_tree "$SCRATCH/tree"
  run run_library gaia_server_process_cwds "$LISTENER_PID"
  [ "$output" = "$LISTENER_PID$TAB$SCRATCH/tree/frontend${TAB}deleted" ]
}

@test "forced lsof backend: listeners and live and deleted cwds read through lsof" {
  command -v lsof >/dev/null 2>&1 || skip "lsof is not installed"
  export GAIA_PORTS_PROCESS_PROBE=lsof
  make_tree "$SCRATCH/tree"
  start_listener_on_free_port "$SCRATCH/tree/frontend"
  run run_library gaia_server_listeners "$LISTENER_PORT"
  [ "$output" = "$LISTENER_PORT$TAB$LISTENER_PID" ]
  run run_library gaia_server_process_cwds "$LISTENER_PID"
  [ "$output" = "$LISTENER_PID$TAB$SCRATCH/tree/frontend${TAB}live" ]
  rm -rf "$SCRATCH/tree"
  make_tree "$SCRATCH/tree"
  run run_library gaia_server_process_cwds "$LISTENER_PID"
  [ "$output" = "$LISTENER_PID$TAB$SCRATCH/tree/frontend${TAB}deleted" ]
}
