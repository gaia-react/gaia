#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/spec-renumber.sh`'s best-effort
# `.lock` re-key: a SPEC renumbered while its liveness lock is live must have
# the lock follow the id, not strand under the old one (a stranded lock would
# make `status <new_id>` read dormant even though the session is still
# authoring).
#
# Uses helpers/tmp-spec-repo.sh (already copies spec-renumber.sh into the tmp
# lib dir). Each test spins up its own tmp git repo and tears it down;
# hermetic, no reliance on the real project ledger/specs tree.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on
# macOS's system bash 3.2). This suite uses `[ ... ]` for everything but a
# test's last statement.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  RENUMBER=".specify/extensions/gaia/lib/spec-renumber.sh"
  CACHE=".gaia/local/cache"
}

teardown() {
  # The spawned stand-in "session host" process outlives the test unless
  # killed here; it is never reaped by the script under test.
  if [ -n "${SPAWN_PID:-}" ]; then
    kill "$SPAWN_PID" 2>/dev/null || true
    wait "$SPAWN_PID" 2>/dev/null || true
  fi
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_renumber() {
  bash "$REPO/$RENUMBER" "$@"
}

# --- 1: renumber-while-live re-keys the .lock, preserving its live pid ------

@test "1: renumbering a draft with a live-shaped .lock re-keys it and keeps the recorded pid" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-901)"

  # Stand in for a live session-host: a real, long-lived background process
  # whose pid the lock records, so "is the pid still alive" is genuinely true.
  sleep 300 &
  SPAWN_PID=$!

  jq -n --arg id "SPEC-901" --argjson pid "$SPAWN_PID" \
    '{spec_id: $id, hostname: "test-host", host_pid: $pid,
      host_lstart: "irrelevant-for-this-test", host_nonce: "test-nonce",
      acquired_at: "2026-01-01T00:00:00Z"}' \
    > "$REPO/$CACHE/spec-session-SPEC-901.lock"

  run _renumber "$REPO" SPEC-901 SPEC-902
  [ "$status" -eq 0 ]

  [ -f "$REPO/$CACHE/spec-session-SPEC-902.lock" ]
  [ ! -e "$REPO/$CACHE/spec-session-SPEC-901.lock" ]

  # The pid rides along unchanged, so a `status SPEC-902` kill-0 check would
  # still find it alive: the live session's lock followed the id rather than
  # stranding under the old one.
  [ "$(jq -r '.host_pid' "$REPO/$CACHE/spec-session-SPEC-902.lock")" = "$SPAWN_PID" ]
  [ "$(jq -r '.spec_id' "$REPO/$CACHE/spec-session-SPEC-902.lock")" = "SPEC-902" ]
}

# --- 2: a missing lock is a normal no-op ------------------------------------

@test "2: renumbering a draft with no .lock file is a no-op for the lock re-key" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-903)"

  run _renumber "$REPO" SPEC-903 SPEC-904
  [ "$status" -eq 0 ]

  [ ! -e "$REPO/$CACHE/spec-session-SPEC-903.lock" ]
  [ ! -e "$REPO/$CACHE/spec-session-SPEC-904.lock" ]
}
