#!/usr/bin/env bats
#
# .claude/hooks/provision-worktree.sh, the ports stage: slot assignment from the
# main-anchored ledger, the per-tree port file, removal and dead-session
# cleanup, and the context line Claude is told.
#
# Every test builds a fixture main checkout that carries the hook and both port
# libraries, adds linked worktrees under it, and runs the hook the way a session
# does. Listeners come from the shared fixture (.gaia/tests/fixtures/ports/
# listen.mjs) so a "server" is a real process with a real working directory.
# The dev and Storybook base ports are pinned to a random ephemeral range per
# test, so a developer's real servers on 5173 and 6006 never take part.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  HOOK_ABSOLUTE_PATH="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/provision-worktree.sh"
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  LISTENER_FIXTURE="$REPO_ROOT_REAL/.gaia/tests/fixtures/ports/listen.mjs"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  TAB=$'\t'
  STARTED_PIDS=()

  unset GITHUB_ACTIONS CLAUDE_CODE_SESSION_ID GAIA_PORTS_HOST_PID GAIA_PORTS_STATE_DIRECTORY
  unset GAIA_PORTS_LOCK_DEADLINE_SECONDS SITE_URL
  DEV_BASE=$((20000 + RANDOM % 8000))
  STORYBOOK_BASE=$((DEV_BASE + 1000))
  export GAIA_PORTS_DEV_BASE_PORT="$DEV_BASE"
  export GAIA_PORTS_STORYBOOK_BASE_PORT="$STORYBOOK_BASE"
  export GAIA_PORTS_PROCESS_PROBE="${GAIA_PORTS_PROCESS_PROBE:-auto}"
}

teardown() {
  local started_pid
  for started_pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$started_pid" ] && kill -KILL "$started_pid" 2>/dev/null
  done
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
  return 0
}

# require_process_backend: the cleanup and foreign-port arms need a way to see
# listeners; a host with neither lsof nor ss and /proc cannot run them.
require_process_backend() {
  command -v node >/dev/null 2>&1 || skip "node is required for the listener fixture"
  if ! command -v lsof >/dev/null 2>&1; then
    { [ -e /proc/self ] && command -v ss >/dev/null 2>&1; } || skip "no process backend (lsof, or /proc with ss) on this host"
  fi
}

# make_main: a fixture main checkout carrying the hook, both libraries, and the
# registry, committed so a linked worktree checks out its own copies.
make_main() {
  MAIN="$(mktemp -d -t gaia-provision-ports-XXXXXX)"
  MAIN="$(cd "$MAIN" && pwd -P)"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.claude/hooks/lib" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" "$MAIN/frontend"
  cp "$HOOK_ABSOLUTE_PATH" "$MAIN/.claude/hooks/provision-worktree.sh"
  cp "$REPO_ROOT_REAL/.claude/hooks/lib/gaia-packages.sh" "$MAIN/.claude/hooks/lib/"
  echo 'export default {};' >"$MAIN/frontend/react-router.config.ts"
  cp "$REPO_ROOT_REAL/.gaia/scripts/main-root-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/state-registry-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/link-worktree.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/worktree-ports-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/scripts/server-process-lib.sh" "$MAIN/.gaia/scripts/"
  cp "$REPO_ROOT_REAL/.gaia/state-registry.json" "$MAIN/.gaia/"
  chmod +x "$MAIN/.claude/hooks/provision-worktree.sh" "$MAIN"/.gaia/scripts/*.sh

  echo init >"$MAIN/f"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init
  STATE="$MAIN/.gaia/local/ports"
  LEDGER="$STATE/slots.tsv"
}

# add_worktree <name>: a linked worktree of MAIN, echoed as a physical path.
add_worktree() {
  local name="$1"
  git -C "$MAIN" worktree add -q -b "$name" "$MAIN/.claude/worktrees/$name" >/dev/null 2>&1
  (cd "$MAIN/.claude/worktrees/$name" && pwd -P)
}

# provision <tree>: the direct-call form. Stdout and stderr land in separate
# files so a test can assert on each alone; the exit status is PROVISION_STATUS.
provision() {
  PROVISION_STDOUT="$SCRATCH/provision.stdout"
  PROVISION_STDERR="$SCRATCH/provision.stderr"
  PROVISION_STATUS=0
  bash "$1/.claude/hooks/provision-worktree.sh" "$1" >"$PROVISION_STDOUT" 2>"$PROVISION_STDERR" </dev/null || PROVISION_STATUS=$?
}

# provision_with_payload <tree> <payload>: the hook-payload form, no argument.
provision_with_payload() {
  PROVISION_STDOUT="$SCRATCH/provision.stdout"
  PROVISION_STDERR="$SCRATCH/provision.stderr"
  PROVISION_STATUS=0
  printf '%s' "$2" | bash "$1/.claude/hooks/provision-worktree.sh" >"$PROVISION_STDOUT" 2>"$PROVISION_STDERR" || PROVISION_STATUS=$?
}

port_file() {
  printf '%s/frontend/.gaia-ports' "$1"
}

# port_value <tree> <KEY>: the value of one key in the tree's port file.
port_value() {
  sed -n "s/^$2=//p" "$(port_file "$1")"
}

# expected_context_line <slot>: the C8 context line for a stock fixture tree.
expected_context_line() {
  printf 'GAIA ports for this worktree (slot %s): app http://localhost:%s, Storybook http://localhost:%s. Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree'"'"'s ports.' \
    "$1" "$((DEV_BASE + $1))" "$((STORYBOOK_BASE + $1))"
}

ledger_slot_for() {
  awk -F '\t' -v tree="$1" '$2 == tree { print $1 }' "$LEDGER"
}

# ---------- listener helpers ----------

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
  while [ "$attempt" -lt 50 ]; do
    process_running "$1" || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

# start_listener <directory> <port>: a detached fixture listener with cwd
# <directory>. Sets LISTENER_PID; rc 1 when it never reports listening.
start_listener() {
  local directory="$1" port="$2" log attempt=0
  log="$SCRATCH/listener-$port-$RANDOM.log"
  (cd "$directory" && nohup node "$LISTENER_FIXTURE" "$port" 127.0.0.1 >"$log" 2>&1 </dev/null 3>&- &)
  while [ "$attempt" -lt 100 ]; do
    if [ -f "$log" ] && grep -q '^listening ' "$log"; then
      LISTENER_PID="$(sed -n 's/^listening \([0-9][0-9]*\)$/\1/p' "$log")"
      [ -n "$LISTENER_PID" ] || return 1
      STARTED_PIDS+=("$LISTENER_PID")
      return 0
    fi
    sleep 0.1
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

# ---------- main pays nothing ----------

@test "the main checkout gets no port file, no ports state, and prints nothing" {
  make_main
  provision "$MAIN"
  [ "$PROVISION_STATUS" -eq 0 ]
  [ ! -e "$MAIN/frontend/.gaia-ports" ]
  [ ! -e "$MAIN/.gaia/local/ports" ]
  [ ! -s "$PROVISION_STDOUT" ]
}

@test "under GitHub Actions the ports stage does nothing" {
  make_main
  local tree
  tree="$(add_worktree a)"
  GITHUB_ACTIONS=true provision "$tree"
  [ "$PROVISION_STATUS" -eq 0 ]
  [ ! -e "$(port_file "$tree")" ]
  [ ! -s "$PROVISION_STDOUT" ]
}

# ---------- slot and file ----------

@test "the first worktree gets slot 1, a port file with base+1 ports, and one marked ledger line" {
  make_main
  local tree
  tree="$(add_worktree a)"
  provision "$tree"
  [ "$PROVISION_STATUS" -eq 0 ]
  [ "$(port_value "$tree" GAIA_PORT_SLOT)" = "1" ]
  [ "$(port_value "$tree" DEV_PORT)" = "$((DEV_BASE + 1))" ]
  [ "$(port_value "$tree" STORYBOOK_PORT)" = "$((STORYBOOK_BASE + 1))" ]
  [ "$(wc -l <"$LEDGER" | tr -d ' ')" -eq 1 ]
  local slot ledger_tree marker
  IFS=$'\t' read -r slot ledger_tree marker <"$LEDGER"
  [ "$slot" = "1" ]
  [ "$ledger_tree" = "$tree" ]
  case "$marker" in
    *:*) ;;
    *) return 1 ;;
  esac
}

@test "a foreign listener on the first slot's dev port sends the new worktree to slot 2" {
  require_process_backend
  make_main
  local outside="$SCRATCH/outside" tree
  mkdir -p "$outside"
  git -C "$outside" init -q
  start_listener "$outside" "$((DEV_BASE + 1))"
  tree="$(add_worktree a)"
  provision "$tree"
  [ "$(port_value "$tree" GAIA_PORT_SLOT)" = "2" ]
  [ "$(port_value "$tree" DEV_PORT)" = "$((DEV_BASE + 2))" ]
  # The foreign server was only skipped, never stopped.
  process_running "$LISTENER_PID"
}

@test "a slot stays put after a peer is removed and its port file is byte-identical" {
  make_main
  local tree_a tree_b
  tree_a="$(add_worktree a)"
  tree_b="$(add_worktree b)"
  provision "$tree_a"
  provision "$tree_b"
  [ "$(port_value "$tree_b" GAIA_PORT_SLOT)" = "2" ]
  cp "$(port_file "$tree_b")" "$SCRATCH/b-before"
  git -C "$MAIN" worktree remove --force "$tree_a"
  provision "$tree_b"
  [ "$(port_value "$tree_b" GAIA_PORT_SLOT)" = "2" ]
  cmp -s "$SCRATCH/b-before" "$(port_file "$tree_b")"
}

@test "a reclaimed slot is reused by the next new worktree, with one ledger line for it" {
  make_main
  local tree_a tree_b tree_c
  tree_a="$(add_worktree a)"
  tree_b="$(add_worktree b)"
  provision "$tree_a"
  provision "$tree_b"
  git -C "$MAIN" worktree remove --force "$tree_a"
  provision "$tree_b"
  tree_c="$(add_worktree c)"
  provision "$tree_c"
  [ "$(port_value "$tree_c" GAIA_PORT_SLOT)" = "1" ]
  [ "$(port_value "$tree_c" DEV_PORT)" = "$((DEV_BASE + 1))" ]
  [ "$(port_value "$tree_c" STORYBOOK_PORT)" = "$((STORYBOOK_BASE + 1))" ]
  [ "$(awk -F '\t' '$1 == 1' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(ledger_slot_for "$tree_c")" = "1" ]
  [ -z "$(ledger_slot_for "$tree_a")" ]
}

@test "ledger authority: a hand-edited port file is rewritten to the ledger's slot" {
  make_main
  local tree
  tree="$(add_worktree a)"
  provision "$tree"
  cp "$(port_file "$tree")" "$SCRATCH/original"
  sed -i.bak -e 's/^GAIA_PORT_SLOT=.*/GAIA_PORT_SLOT=7/' -e 's/^DEV_PORT=.*/DEV_PORT=1234/' "$(port_file "$tree")"
  rm -f "$(port_file "$tree").bak"
  provision "$tree"
  cmp -s "$SCRATCH/original" "$(port_file "$tree")"
}

# ---------- reclaim and cleanup ----------

@test "reclaim stops a removed tree's server, hands out its slot, and leaves a live tree's server alone" {
  require_process_backend
  make_main
  local tree_x tree_y tree_w x_pid y_pid
  tree_x="$(add_worktree x)"
  tree_y="$(add_worktree y)"
  provision "$tree_x"
  provision "$tree_y"
  [ "$(port_value "$tree_x" GAIA_PORT_SLOT)" = "1" ]
  [ "$(port_value "$tree_y" GAIA_PORT_SLOT)" = "2" ]
  start_listener "$tree_x" "$((DEV_BASE + 1))"
  x_pid="$LISTENER_PID"
  start_listener "$tree_y" "$((DEV_BASE + 2))"
  y_pid="$LISTENER_PID"
  git -C "$MAIN" worktree remove --force "$tree_x"
  tree_w="$(add_worktree w)"
  provision "$tree_w"
  wait_until_gone "$x_pid"
  grep -qxF "GAIA stopped a server on port $((DEV_BASE + 1)) (PID $x_pid) left running from removed worktree $tree_x." "$PROVISION_STDOUT"
  [ "$(port_value "$tree_w" GAIA_PORT_SLOT)" = "1" ]
  # Positive control above (the removed tree's server went); the live tree's survives.
  process_running "$y_pid"
}

@test "a dead session's recorded server is stopped, with a dead-session line" {
  require_process_backend
  make_main
  local tree host_pid
  tree="$(add_worktree y)"
  provision "$tree"
  start_host_process
  host_pid="$HOST_PID"
  bash -c '. "$1"; gaia_server_session_register "$2" "$3" "$4"' _ \
    "$MAIN/.gaia/scripts/server-process-lib.sh" "$STATE" session-y "$host_pid"
  start_listener "$tree" "$((DEV_BASE + 1))"
  CLAUDE_CODE_SESSION_ID=session-y bash "$MAIN/.gaia/scripts/server-process-lib.sh" --record-launch \
    --pid "$LISTENER_PID" --port "$((DEV_BASE + 1))" --kind dev --tree "$tree"
  [ -f "$STATE/launches/$LISTENER_PID.tsv" ]

  # While the host lives, a rerun leaves the server alone.
  provision "$tree"
  process_running "$LISTENER_PID"

  kill -KILL "$host_pid"
  wait_until_gone "$host_pid"
  provision "$tree"
  wait_until_gone "$LISTENER_PID"
  grep -qxF "GAIA stopped a dev server on port $((DEV_BASE + 1)) (PID $LISTENER_PID) launched by an ended Claude session in $tree." "$PROVISION_STDOUT"
  [ ! -e "$STATE/launches/$LISTENER_PID.tsv" ]
}

@test "PID reuse: a record whose start time differs survives the reap and the record is dropped" {
  require_process_backend
  make_main
  local tree host_pid identity command_text
  tree="$(add_worktree y)"
  provision "$tree"
  start_host_process
  host_pid="$HOST_PID"
  kill -KILL "$host_pid"
  wait_until_gone "$host_pid"
  start_listener "$tree" "$((DEV_BASE + 1))"
  identity="$(bash -c '. "$1"; gaia_server_process_identity "$2"' _ "$MAIN/.gaia/scripts/server-process-lib.sh" "$LISTENER_PID")"
  command_text="${identity#*"$TAB"}"
  mkdir -p "$STATE/launches"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LISTENER_PID" "Thu Jan  1 00:00:00 1970" "$command_text" "$tree" "$((DEV_BASE + 1))" dev session-y \
    "$host_pid" "Thu Jan  1 00:00:00 1970" "$tree" >"$STATE/launches/$LISTENER_PID.tsv"
  provision "$tree"
  [ "$PROVISION_STATUS" -eq 0 ]
  process_running "$LISTENER_PID"
  [ ! -e "$STATE/launches/$LISTENER_PID.tsv" ]
  grep -qF 'GAIA stopped' "$PROVISION_STDOUT" && return 1
  return 0
}

@test "an rm -rf'd tree loses its entry, a locked tree keeps its own" {
  make_main
  local tree_d tree_e tree_f
  tree_d="$(add_worktree d)"
  tree_e="$(add_worktree e)"
  provision "$tree_d"
  provision "$tree_e"
  [ "$(ledger_slot_for "$tree_e")" = "2" ]
  git -C "$MAIN" worktree lock "$tree_d"
  rm -rf "$tree_e"
  tree_f="$(add_worktree f)"
  provision "$tree_f"
  [ -z "$(ledger_slot_for "$tree_e")" ]
  [ "$(ledger_slot_for "$tree_d")" = "1" ]
  # The removed tree's slot is free and went to the next new worktree.
  [ "$(port_value "$tree_f" GAIA_PORT_SLOT)" = "2" ]
}

@test "a tree recreated at the same path loses its old server and takes a new marker" {
  require_process_backend
  make_main
  local tree old_marker new_marker old_pid slot
  tree="$(add_worktree z)"
  provision "$tree"
  old_marker="$(awk -F '\t' -v tree="$tree" '$2 == tree { print $3 }' "$LEDGER")"
  start_listener "$tree" "$((DEV_BASE + 1))"
  old_pid="$LISTENER_PID"
  git -C "$MAIN" worktree remove --force "$tree"
  git -C "$MAIN" worktree add -q -b z-again "$tree" >/dev/null 2>&1
  provision "$tree"
  wait_until_gone "$old_pid"
  grep -qxF "GAIA stopped a server on port $((DEV_BASE + 1)) (PID $old_pid) left running from removed worktree $tree." "$PROVISION_STDOUT"
  new_marker="$(awk -F '\t' -v tree="$tree" '$2 == tree { print $3 }' "$LEDGER")"
  [ -n "$new_marker" ]
  [ "$new_marker" != "$old_marker" ]
  [ "$(awk -F '\t' -v tree="$tree" '$2 == tree' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]

  # A server started in the new tree afterwards is its own and survives a rerun.
  slot="$(ledger_slot_for "$tree")"
  start_listener "$tree" "$((DEV_BASE + slot))"
  provision "$tree"
  process_running "$LISTENER_PID"
}

@test "a failing worktree listing does not abort the hook: the port file is still written" {
  make_main
  local tree_a tree_b stub_directory real_git
  tree_a="$(add_worktree a)"
  tree_b="$(add_worktree b)"
  provision "$tree_a"
  cp "$LEDGER" "$SCRATCH/ledger-before"
  real_git="$(command -v git)"
  stub_directory="$SCRATCH/failing-git"
  mkdir -p "$stub_directory"
  cat >"$stub_directory/git" <<SH
#!/bin/sh
case " \$* " in
  *" worktree list "*) exit 1 ;;
esac
exec "$real_git" "\$@"
SH
  chmod +x "$stub_directory/git"
  PATH="$stub_directory:$PATH" provision "$tree_b"
  [ "$PROVISION_STATUS" -eq 0 ]
  [ "$(port_value "$tree_b" GAIA_PORT_SLOT)" = "2" ]
  # Reclaim could not list, so it removed nothing: the first tree's entry stands.
  [ "$(ledger_slot_for "$tree_a")" = "1" ]
}

# ---------- context line ----------

@test "SessionStart: stdout is exactly one context line with concrete values" {
  make_main
  local tree payload
  tree="$(add_worktree a)"
  payload="$(jq -nc --arg tree_path "$tree" '{hook_event_name: "SessionStart", source: "startup", cwd: $tree_path}')"
  provision_with_payload "$tree" "$payload"
  [ "$PROVISION_STATUS" -eq 0 ]
  [ "$(wc -l <"$PROVISION_STDOUT" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$PROVISION_STDOUT")" = "$(expected_context_line 1)" ]
  # stderr is where the logs go and is not part of the channel.
  [ -s "$PROVISION_STDERR" ]
}

@test "a direct call prints the same plain context line" {
  make_main
  local tree
  tree="$(add_worktree a)"
  provision "$tree"
  [ "$(cat "$PROVISION_STDOUT")" = "$(expected_context_line 1)" ]
}

@test "EnterWorktree with jq: stdout is one JSON object carrying the context line" {
  make_main
  local tree payload
  tree="$(add_worktree a)"
  payload="$(jq -nc --arg tree_path "$tree" '{hook_event_name: "PostToolUse", tool_name: "EnterWorktree", cwd: $tree_path, tool_response: {worktreePath: $tree_path}}')"
  provision_with_payload "$tree" "$payload"
  [ "$PROVISION_STATUS" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' "$PROVISION_STDOUT" >/dev/null
  [ "$(jq -r '.hookSpecificOutput.additionalContext' "$PROVISION_STDOUT")" = "$(expected_context_line 1)" ]
}

@test "EnterWorktree without jq: the port file is written and stdout is one valid JSON object" {
  make_main
  local tree stub_directory tool tool_path payload bash_path
  tree="$(add_worktree a)"
  bash_path="$(command -v bash)"
  stub_directory="$SCRATCH/no-jq-bin"
  mkdir -p "$stub_directory"
  for tool in bash env git sed cat mkdir rmdir mv rm date find sort stat ls dirname basename sleep ps lsof ss awk grep tr head tail wc cp ln uname readlink cut mktemp node uniq expr xargs chmod touch; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    case "$tool_path" in /*) ln -s "$tool_path" "$stub_directory/$tool" ;; esac
  done
  [ ! -e "$stub_directory/jq" ]
  PATH="$stub_directory" command -v jq >/dev/null 2>&1 && return 1
  payload="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"EnterWorktree\",\"cwd\":\"$tree\",\"tool_response\":{\"worktreePath\":\"$tree\"}}"
  PROVISION_STDOUT="$SCRATCH/provision.stdout"
  PROVISION_STDERR="$SCRATCH/provision.stderr"
  printf '%s' "$payload" | PATH="$stub_directory" "$bash_path" "$tree/.claude/hooks/provision-worktree.sh" >"$PROVISION_STDOUT" 2>"$PROVISION_STDERR"
  [ -f "$(port_file "$tree")" ]
  [ "$(port_value "$tree" GAIA_PORT_SLOT)" = "1" ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' "$PROVISION_STDOUT" >/dev/null
  [ "$(jq -r '.hookSpecificOutput.additionalContext' "$PROVISION_STDOUT")" = "$(expected_context_line 1)" ]
}

# ---------- locking ----------

@test "concurrent allocation: two runs held on the lock get different slots" {
  make_main
  local tree_a tree_b pid_a pid_b
  tree_a="$(add_worktree a)"
  tree_b="$(add_worktree b)"
  mkdir -p "$STATE/slots.lock"
  GAIA_PORTS_LOCK_DEADLINE_SECONDS=10 bash "$tree_a/.claude/hooks/provision-worktree.sh" "$tree_a" >"$SCRATCH/a.stdout" 2>"$SCRATCH/a.stderr" </dev/null &
  pid_a=$!
  GAIA_PORTS_LOCK_DEADLINE_SECONDS=10 bash "$tree_b/.claude/hooks/provision-worktree.sh" "$tree_b" >"$SCRATCH/b.stdout" 2>"$SCRATCH/b.stderr" </dev/null &
  pid_b=$!
  sleep 1
  # Both runs are blocked on the held lock; releasing it lets them through one at a time.
  [ ! -f "$LEDGER" ]
  rmdir "$STATE/slots.lock"
  wait "$pid_a"
  wait "$pid_b"
  [ "$(wc -l <"$LEDGER" | tr -d ' ')" -eq 2 ]
  [ "$(port_value "$tree_a" GAIA_PORT_SLOT)" != "$(port_value "$tree_b" GAIA_PORT_SLOT)" ]
  [ "$(port_value "$tree_a" GAIA_PORT_SLOT)" = "$(ledger_slot_for "$tree_a")" ]
  [ "$(port_value "$tree_b" GAIA_PORT_SLOT)" = "$(ledger_slot_for "$tree_b")" ]
}

@test "a held lock never blocks: the existing file stays, the timeout is logged, the context line still prints" {
  make_main
  local tree started elapsed
  tree="$(add_worktree a)"
  provision "$tree"
  cp "$(port_file "$tree")" "$SCRATCH/file-before"
  mkdir -p "$STATE/slots.lock"
  started="$(date +%s)"
  GAIA_PORTS_LOCK_DEADLINE_SECONDS=1 provision "$tree"
  elapsed=$(($(date +%s) - started))
  [ "$PROVISION_STATUS" -eq 0 ]
  [ "$elapsed" -le 8 ]
  cmp -s "$SCRATCH/file-before" "$(port_file "$tree")"
  grep -qF "provision-worktree: PORTS LOCK TIMEOUT (non-fatal): kept the existing port file for $tree" "$PROVISION_STDERR"
  [ "$(cat "$PROVISION_STDOUT")" = "$(expected_context_line 1)" ]
}
