#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/spec-session-lock.sh` (SPEC-052 Phase
# 1: the host-resolution spike). This phase ships `resolve-host` + `match-host`;
# the suite proves the ancestor-walk MECHANICS that the whole feature rests on.
#
# The one load-bearing fact under test: the resolved liveness token must be the
# session-lifetime HOST process, not the ephemeral per-Bash-call shell. A wrong
# token ships a silent no-op (every draft reads dormant forever). Case 1 pins
# the host-match ERE against the two ground-truth command lines (match the
# claude host, reject the `.claude/shell-snapshots/` wrapper); cases 2-3 prove
# on a REAL spawned subtree that the walk climbs to the host and that the
# resolved pid outlives the resolving shell (RT-002).
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
}

teardown() {
  if [ -n "${GC:-}" ]; then kill "$GC" 2>/dev/null || true; fi
  if [ -n "${HOST:-}" ]; then kill "$HOST" 2>/dev/null || true; fi
  return 0
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
