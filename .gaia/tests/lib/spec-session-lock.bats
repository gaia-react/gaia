#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/spec-session-lock.sh`: the
# ancestor-walk (`resolve-host` / `match-host`) plus the liveness-lock helper
# built on top of it (`acquire` / `status` / `release`).
#
# The one load-bearing fact under test in cases 1-6: the resolved liveness
# token must be the session-lifetime HOST process, not the ephemeral
# per-Bash-call shell. A wrong token ships a silent no-op (every draft reads
# dormant forever). Case 1 pins the host-match ERE against the two
# ground-truth command lines (match the claude host, reject the
# `.claude/shell-snapshots/` wrapper); cases 2-3 prove on a REAL spawned
# subtree that the walk climbs to the host and that the resolved pid outlives
# the resolving shell (RT-002).
#
# Assertion style (`.claude/rules/bats-assertions.md`): macOS `/bin/bash` (3.2)
# does not fail a bats @test on a false bare `[[ ... ]]` that is not the test's
# last command, so non-final substring checks use `grep -qF` via assert_contains
# and everything else uses POSIX `[ ... ]`. Run under bash 5 via
# `.gaia/scripts/bats5.sh` so local matches CI.
#
# The walk needs no ledger/repo fixture -- it operates on live process ancestry
# -- so this suite does NOT use helpers/tmp-spec-repo.sh. Cases 2 and 3 spawn a
# real long-lived subtree (a bash renamed `bats-fake-host` via `exec -a`, a
# child bash, a grandchild sleeper) and point the walk at the grandchild; the
# overridden GAIA_SPEC_LOCK_HOST_PATTERN matches the fake host's argv so no real
# `claude` process is required.
#
# Cases 7+ (the liveness-lock helper: acquire/status/release) use a plain
# `<repo_root>` = $BATS_TEST_TMPDIR, needing no git fixture either. `status`
# cases stamp a lock file directly with `jq -n` and drive liveness with a
# plain backgrounded `sleep` (a real controllable pid + its real
# `ps -o lstart=`); `acquire` cases reuse `_spawn_fake_host` above so the walk
# resolves to a controllable process, never a real `claude` ancestor. Every
# call site in this file is kept free of a bare `claude` word in the same
# shell command line -- belt-and-suspenders atop the snapshot-wrapper
# exclusion in the script itself, so this suite can never accidentally walk to
# a real Claude Code host process running this very session.
#
# Case 14 uses `run --separate-stderr` to assert empty stderr independently of
# stdout.
bats_require_minimum_version 1.5.0

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  # Three `..` from .gaia/tests/lib/ up to the repo root, then into the lib dir.
  LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.specify/extensions/gaia/lib" && pwd)"
  SCRIPT="$LIB_DIR/spec-session-lock.sh"
  [ -f "$SCRIPT" ] || {
    echo "script under test not found: $SCRIPT" >&2
    return 1
  }
  # The overridden pattern cases 2-3 match against the spawned fixture's argv.
  FAKE_PATTERN='(^|/)bats-fake-host([[:space:]]|$)'
  # Fixture repo root for the acquire/status/release cases (7+); no git
  # fixture needed, just a plain directory the helper can mkdir -p under.
  REPO="$BATS_TEST_TMPDIR"
  # Space-separated extra pids the liveness-lock cases spawn (beyond GC/HOST),
  # reaped by teardown below.
  EXTRA_PIDS=""
}

teardown() {
  if [ -n "${GC:-}" ]; then kill "$GC" 2>/dev/null || true; fi
  if [ -n "${HOST:-}" ]; then kill "$HOST" 2>/dev/null || true; fi
  local p
  for p in ${EXTRA_PIDS:-}; do
    kill "$p" 2>/dev/null || true
  done
  return 0
}

# _write_lock <repo_root> <spec_id> <hostname> <host_pid> <host_lstart>
# <host_nonce>: composes and writes a lock file BY HAND (independent of the
# script's own compose helper -- this proves the on-disk CONTRACT, not the
# implementation). host_pid is written unquoted via --argjson so it lands as
# a JSON number, matching the frozen lock-body shape.
_write_lock() {
  local repo_root="$1" spec_id="$2" hn="$3" pid="$4" lstart="$5" nonce="$6"
  mkdir -p "$repo_root/.gaia/local/cache"
  jq -n --arg h "$hn" --argjson p "$pid" --arg l "$lstart" --arg n "$nonce" --arg id "$spec_id" \
    '{spec_id: $id, hostname: $h, host_pid: $p, host_lstart: $l, host_nonce: $n, acquired_at: "2026-01-01T00:00:00Z"}' \
    > "$repo_root/.gaia/local/cache/spec-session-${spec_id}.lock"
}

# _lock_file_path <repo_root> <spec_id>: mirrors the script's own _lock_path,
# kept as a separate literal here (not sourced from the script) so a drift in
# the script's path format shows up as a test failure instead of both sides
# silently agreeing with each other.
_lock_file_path() {
  printf '%s/.gaia/local/cache/spec-session-%s.lock' "$1" "$2"
}

# _spawn_alive: backgrounds a real, controllable process (a plain `sleep`, not
# the fake-host walk -- `status` never walks ancestry). Sets ALIVE_PID /
# ALIVE_LSTART and registers the pid for teardown.
_spawn_alive() {
  sleep 300 &
  ALIVE_PID=$!
  EXTRA_PIDS="${EXTRA_PIDS:-} $ALIVE_PID"
  ALIVE_LSTART="$(ps -o lstart= -p "$ALIVE_PID")"
}

# _kill_and_reap <pid>: kill then wait, so a subsequent `kill -0` reliably
# reads dead rather than transiently seeing an unreaped zombie.
_kill_and_reap() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# Spawn a real host subtree: host (a bash whose argv0 is rewritten to
# `bats-fake-host` so its command line matches FAKE_PATTERN) -> child bash ->
# grandchild sleeper. Records the grandchild pid so the walk starts two levels
# below the host. Sets globals HOST and GC (read by teardown).
_spawn_fake_host() {
  export GCPF="$BATS_TEST_TMPDIR/gc.pid"
  export SPAWNER="$BATS_TEST_TMPDIR/spawner.sh"
  rm -f "$GCPF"
  # Single-quoted heredoc: $! and $GCPF are written literally and expand when
  # the spawner runs, not now. GCPF reaches the grandchild's shell via the
  # exported env.
  cat > "$SPAWNER" <<'SP'
#!/usr/bin/env bash
# Host process (argv0 rewritten to bats-fake-host by the caller's exec -a).
# Spawn a child bash that spawns a grandchild sleeper, then wait so the whole
# tree stays alive for the walk.
bash -c 'sleep 300 & echo "$!" > "$GCPF"; wait' &
wait
SP
  bash -c 'exec -a bats-fake-host bash "$SPAWNER"' &
  HOST=$!
  local waited=0
  while [ ! -s "$GCPF" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  GC="$(cat "$GCPF" 2>/dev/null)"
  [ -n "$GC" ] || {
    echo "fixture failed to spawn grandchild sleeper" >&2
    return 1
  }
}

# --- 1: the pinned default ERE matches the host, rejects the .claude/ wrapper ---
@test "1: default host pattern matches the claude host and rejects the .claude/ wrapper" {
  # Ground-truth level 2 (THE HOST) matches.
  run bash "$SCRIPT" match-host 'claude --dangerously-skip-permissions'
  [ "$status" -eq 0 ]

  # Ground-truth level 1 (throwaway wrapper whose command line CONTAINS
  # `.claude/shell-snapshots/`) must NOT match. `/Users/you` is a neutral
  # placeholder, not a real machine path.
  run bash "$SCRIPT" match-host '/bin/zsh -c source /Users/you/.claude/shell-snapshots/snapshot-x.sh'
  [ "$status" -eq 1 ]

  # The wrapper's argv embeds the caller's command text. Even when that text
  # carries a bare `claude` token that WOULD satisfy the host pattern, the
  # snapshot signature excludes the wrapper outright, so the walk never records
  # this ephemeral per-call shell as the host.
  run bash "$SCRIPT" match-host '/bin/zsh -c source /Users/you/.claude/shell-snapshots/snapshot-x.sh && claude --version'
  [ "$status" -eq 1 ]

  # A node-install host invocation matches (shape 2), while a `.claude/` config
  # path does not (a directory path is never the host).
  run bash "$SCRIPT" match-host 'node /Users/you/.nvm/lib/node_modules/@anthropic-ai/claude-code/cli.js --dangerously-skip-permissions'
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" match-host 'grep claude-code /Users/you/.claude/settings.json'
  [ "$status" -eq 1 ]
}

# --- 2: resolve-host climbs a real spawned subtree to the host (RT-002 seed) ---
@test "2: resolve-host climbs a real spawned subtree to the host" {
  _spawn_fake_host

  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" \
    GAIA_SPEC_LOCK_START_PID="$GC" bash "$SCRIPT" resolve-host
  [ "$status" -eq 0 ]
  # First printed line is the walked-up host pid, not the grandchild we started
  # from -- proving the walk climbed rather than recording its start.
  [ "${lines[0]}" = "$HOST" ]

  # Second line is host_lstart, compared BYTE-FOR-BYTE against a dedicated
  # `ps -o lstart= -p` call (DP-003). Captured via command substitution so the
  # field's trailing padding survives intact.
  got_lstart="$(env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" \
    GAIA_SPEC_LOCK_START_PID="$GC" bash "$SCRIPT" resolve-host | sed -n '2p')"
  [ "$got_lstart" = "$(ps -o lstart= -p "$HOST")" ]
}

# --- 3: the resolved pid outlives the shell that resolved it (RT-002 e2e seed) ---
@test "3: the resolved pid survives the resolving shell's exit" {
  _spawn_fake_host

  # Resolve inside a command-substitution SUBSHELL and capture the printed pid;
  # that subshell then exits. Because the host is a separate long-lived process,
  # the pid is still alive -- a design that recorded the resolving subshell's
  # own pid would fail the kill -0 below. This is the RT-002 guarantee in seed
  # form.
  captured="$(env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" \
    GAIA_SPEC_LOCK_START_PID="$GC" bash "$SCRIPT" resolve-host | sed -n '1p')"
  [ "$captured" = "$HOST" ]
  kill -0 "$captured"
}

# --- 4: no matching ancestor -> exit 1, empty stdout ---
@test "4: no matching ancestor exits 1 with empty stdout" {
  # An unmatchable pattern: the real ancestry never matches it, so the walk
  # climbs to init and reports no host found.
  run env GAIA_SPEC_LOCK_HOST_PATTERN='zzzz-nonexistent-host-token-zzzz' \
    bash "$SCRIPT" resolve-host
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- 5: the walk is bounded and never hangs ---
@test "5: the walk is bounded and returns without hanging" {
  # No timeout(1) on stock macOS, so bound it by hand: background the call, poll
  # briefly, kill on hang. The unmatchable pattern forces a full climb to init,
  # proving the loop terminates rather than spinning.
  env GAIA_SPEC_LOCK_HOST_PATTERN='zzzz-nonexistent-host-token-zzzz' \
    bash "$SCRIPT" resolve-host >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi
  local exit_status=0
  wait "$pid" || exit_status=$?
  [ "$exit_status" -eq 1 ]
}

# --- 6: unknown subcommand -> exit 1 with a usage message ---
@test "6: unknown subcommand exits 1 with a usage message" {
  run bash "$SCRIPT" not-a-subcommand
  [ "$status" -eq 1 ]
  assert_contains "usage: spec-session-lock.sh"
}

# --- 7: status = live (a real alive pid + its real lstart + this hostname) ---
@test "7: status reports live for a lock recording a real alive pid" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-950" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "n"

  run bash "$SCRIPT" status "$REPO" "SPEC-950"
  [ "$status" -eq 0 ]
  [ "$output" = "live" ]
}

# --- 8: status = dormant, dead pid (reclaimable, but status never deletes) ---
@test "8: status reports dormant for a lock recording an exited pid" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-951" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "n"
  _kill_and_reap "$ALIVE_PID"

  # Only the verdict is asserted; status must NOT delete the lock (TST-008 --
  # reclaim is deferred to the next acquire).
  run bash "$SCRIPT" status "$REPO" "SPEC-951"
  [ "$status" -eq 0 ]
  [ "$output" = "dormant" ]
}

# --- 9: status = dormant, no lock file at all ---
@test "9: status reports dormant when no lock file exists" {
  run bash "$SCRIPT" status "$REPO" "SPEC-952"
  [ "$status" -eq 0 ]
  [ "$output" = "dormant" ]
}

# --- 10: mtime is never consulted, in both directions ---
@test "10: status ignores lock-file mtime in both directions" {
  # (a) live pid + mtime stamped far in the past -> still live.
  _spawn_alive
  _write_lock "$REPO" "SPEC-953" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "n"
  touch -t 202001010000 "$(_lock_file_path "$REPO" SPEC-953)"
  run bash "$SCRIPT" status "$REPO" "SPEC-953"
  [ "$status" -eq 0 ]
  [ "$output" = "live" ]

  # (b) dead pid + a fresh mtime (the default, just written) -> still dormant.
  _kill_and_reap "$ALIVE_PID"
  run bash "$SCRIPT" status "$REPO" "SPEC-953"
  [ "$status" -eq 0 ]
  [ "$output" = "dormant" ]
}

# --- 11: acquire records a pid that outlives its own acquiring shell ---
@test "11: acquire records the fixture host pid and status reads live after the acquiring shell exits" {
  _spawn_fake_host

  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-954
  [ "$status" -eq 0 ]
  [ -f "$(_lock_file_path "$REPO" SPEC-954)" ]
  [ "$(jq -r .host_pid "$(_lock_file_path "$REPO" SPEC-954)")" = "$HOST" ]

  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" status "$REPO" SPEC-954
  [ "$output" = "live" ]

  # End-to-end leg (RT-002): acquire inside a subshell that then exits; the
  # recorded pid is the separate long-lived fixture host, not the acquiring
  # subshell, so status still reads live afterward.
  ( env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
      bash "$SCRIPT" acquire "$REPO" SPEC-954 >/dev/null )
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" status "$REPO" SPEC-954
  [ "$output" = "live" ]
}

# --- 12: host-mismatch -> dormant (a copied checkout never reads live) ---
@test "12: status reports dormant when the recorded hostname does not match this machine" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-955" "not-this-machine" "$ALIVE_PID" "$ALIVE_LSTART" "n"

  run bash "$SCRIPT" status "$REPO" "SPEC-955"
  [ "$status" -eq 0 ]
  [ "$output" = "dormant" ]
}

# --- 13: stale/pid-reuse -> dormant (alive pid, but wrong recorded lstart) ---
@test "13: status reports dormant when host_lstart does not match the live pid's actual start time" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-956" "$(uname -n)" "$ALIVE_PID" "Wed Jan  1 00:00:00 2020" "n"

  run bash "$SCRIPT" status "$REPO" "SPEC-956"
  [ "$status" -eq 0 ]
  [ "$output" = "dormant" ]
}

# --- 14: garbage/unreadable lock -> error, empty stderr, exit 0 ---
@test "14: status reports error for a non-JSON or field-incomplete lock, with empty stderr" {
  mkdir -p "$REPO/.gaia/local/cache"
  printf 'not json at all' > "$(_lock_file_path "$REPO" SPEC-957)"

  run --separate-stderr bash "$SCRIPT" status "$REPO" "SPEC-957"
  [ "$status" -eq 0 ]
  [ "$output" = "error" ]
  [ -z "$stderr" ]

  # Missing a required field (host_pid / host_lstart) -> also error.
  jq -n '{spec_id: "SPEC-958", hostname: "x"}' > "$(_lock_file_path "$REPO" SPEC-958)"
  run bash "$SCRIPT" status "$REPO" "SPEC-958"
  [ "$status" -eq 0 ]
  [ "$output" = "error" ]
}

# --- 15: acquire reclaims a stale (dead-pid) lock (COV-005) ---
@test "15: acquire overwrites a stale lock and the reclaimed lock reads live" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-959" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "n"
  _kill_and_reap "$ALIVE_PID"

  _spawn_fake_host
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-959
  [ "$status" -eq 0 ]
  [ "$(jq -r .host_pid "$(_lock_file_path "$REPO" SPEC-959)")" = "$HOST" ]

  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" status "$REPO" SPEC-959
  [ "$output" = "live" ]
}

# --- 16: acquire is exclusive against a live foreign lock (RT-004) ---
@test "16: acquire exits 3 against a live foreign lock without overwriting it, and is idempotent against its own" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-960" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "foreign-nonce"

  _spawn_fake_host
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-960
  [ "$status" -eq 3 ]
  [ "$(jq -r .host_pid "$(_lock_file_path "$REPO" SPEC-960)")" = "$ALIVE_PID" ]

  # A live lock that IS ours (same host fixture identity) re-acquires idempotently.
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-961
  [ "$status" -eq 0 ]
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-961
  [ "$status" -eq 0 ]
}

# --- 17: acquire --override force-reclaims a live foreign lock (COV-001/DP-001) ---
@test "17: acquire --override exits 0 and reclaims a live foreign lock" {
  _spawn_alive
  _write_lock "$REPO" "SPEC-962" "$(uname -n)" "$ALIVE_PID" "$ALIVE_LSTART" "foreign-nonce"

  _spawn_fake_host
  # Plain acquire (contrast case): exits 3, does not overwrite.
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-962
  [ "$status" -eq 3 ]

  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire --override "$REPO" SPEC-962
  [ "$status" -eq 0 ]
  [ "$(jq -r .host_pid "$(_lock_file_path "$REPO" SPEC-962)")" = "$HOST" ]
}

# --- 18: acquire ownership fallback when no stable session-id nonce (DP-005) ---
@test "18: acquire re-acquires its own live lock idempotently with no CLAUDE_CODE_SESSION_ID set" {
  _spawn_fake_host

  run env -u CLAUDE_CODE_SESSION_ID GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" \
    GAIA_SPEC_LOCK_START_PID="$GC" bash "$SCRIPT" acquire "$REPO" SPEC-963
  [ "$status" -eq 0 ]

  # A second call generates a brand-new per-call nonce (no stable session id),
  # yet must still read as OUR OWN live lock via the host_pid + host_lstart
  # fallback (DP-005), not as a foreign lock.
  run env -u CLAUDE_CODE_SESSION_ID GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" \
    GAIA_SPEC_LOCK_START_PID="$GC" bash "$SCRIPT" acquire "$REPO" SPEC-963
  [ "$status" -eq 0 ]
}

# --- 19: release removes the lock (UAT-006 holder-path unit) ---
@test "19: release deletes the lock file and a subsequent status reads dormant" {
  _spawn_fake_host
  run env GAIA_SPEC_LOCK_HOST_PATTERN="$FAKE_PATTERN" GAIA_SPEC_LOCK_START_PID="$GC" \
    bash "$SCRIPT" acquire "$REPO" SPEC-964
  [ "$status" -eq 0 ]
  [ -f "$(_lock_file_path "$REPO" SPEC-964)" ]

  run bash "$SCRIPT" release "$REPO" SPEC-964
  [ "$status" -eq 0 ]
  [ ! -f "$(_lock_file_path "$REPO" SPEC-964)" ]

  run bash "$SCRIPT" status "$REPO" SPEC-964
  [ "$output" = "dormant" ]
}
