#!/usr/bin/env bats
# Tests for `.claude/hooks/debt-session-reconcile.sh`, the SessionStart hook that
# reconciles a currently-shown `Run /gaia-debt` nudge against GitHub on session
# start. It arms the debt-count sentinel when, and only when, the pinned cache
# already shows an open count > 0, so an empty backlog stays fully network-free.
# This backstops a `tech-debt` close that never reached a first-party hook (web
# UI, a teammate, a plain `gh issue close` in a non-hooked shell), which would
# otherwise linger until the 6h TTL.
#
# The hook reads `.gaia/local/debt/count.json` and writes the sentinel relative
# to CWD, so each test runs it inside an isolated sandbox dir.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/debt-session-reconcile.sh
  command -v jq >/dev/null 2>&1 || skip "jq required"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/.gaia/local/debt"
  SENTINEL="$SANDBOX/.gaia/local/debt/refresh-requested"
  CACHE="$SANDBOX/.gaia/local/debt/count.json"
}

# write_cache <openCount-json-fragment>: write count.json with the given raw
# openCount value (a number, or a quoted string for the malformed case).
write_cache() {
  printf '{"schema":1,"openCount":%s,"computedAt":1783395838}\n' "$1" > "$CACHE"
}

# run_hook: run the hook from the sandbox, draining a synthetic SessionStart
# payload on stdin.
run_hook() {
  run bash -c "cd '$SANDBOX' && printf '%s' '{\"hook_event_name\":\"SessionStart\"}' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
}

@test "openCount > 0 arms the sentinel" {
  write_cache 3
  run_hook
  [ -f "$SENTINEL" ]
}

@test "openCount == 1 arms the sentinel (boundary)" {
  write_cache 1
  run_hook
  [ -f "$SENTINEL" ]
}

@test "openCount == 0 leaves the sentinel unset (network-free)" {
  write_cache 0
  run_hook
  [ ! -f "$SENTINEL" ]
}

@test "missing cache: no-op, sentinel unset" {
  rm -f "$CACHE"
  run_hook
  [ ! -f "$SENTINEL" ]
}

@test "malformed openCount: no-op, sentinel unset" {
  write_cache '"abc"'
  run_hook
  [ ! -f "$SENTINEL" ]
}

@test "empty stdin is drained without error" {
  write_cache 2
  run bash -c "cd '$SANDBOX' && '$HOOK_ABS' < /dev/null"
  [ "$status" -eq 0 ]
  [ -f "$SENTINEL" ]
}
