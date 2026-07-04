#!/usr/bin/env bats
# Unit tests for the with-ledger-lock.sh shared mutex helper (Contract C1).
# The helper is sourced (it defines one function: with_ledger_lock); these
# tests source a fresh copy from a tmp repo and exercise the function in
# isolation.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  LOCK_HELPER="$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh"
  LOCKDIR="$REPO/.gaia/local/specs"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

@test "1: with_ledger_lock <d> true -> status 0" {
  run bash -c ". '$LOCK_HELPER'; with_ledger_lock '$LOCKDIR' true"
  [ "$status" -eq 0 ]
}

@test "2: passthrough; command exit 7 propagates as status 7" {
  run bash -c ". '$LOCK_HELPER'; with_ledger_lock '$LOCKDIR' bash -c 'exit 7'"
  [ "$status" -eq 7 ]
}

@test "3: helper writes nothing to stdout; only command stdout passes" {
  run bash -c ". '$LOCK_HELPER'; with_ledger_lock '$LOCKDIR' bash -c 'echo HELLO'"
  [ "$status" -eq 0 ]
  [ "$output" = "HELLO" ]
}

@test "4: forced fallback; specs.lock.d appears during slow cmd, gone after" {
  # The slow command observes the lock dir from inside the held mutex and
  # records its presence; after the call the dir is released (rmdir'd).
  run bash -c "
    . '$LOCK_HELPER'
    export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
    seen=0
    with_ledger_lock '$LOCKDIR' bash -c '[ -d \"$LOCKDIR/specs.lock.d\" ] && echo INSIDE_PRESENT; sleep 0.3'
    [ -d '$LOCKDIR/specs.lock.d' ] && echo AFTER_PRESENT || echo AFTER_GONE
    # mkdir path used: the flock file must NOT have been created.
    [ -e '$LOCKDIR/specs.lock' ] && echo FLOCK_FILE_PRESENT || echo NO_FLOCK_FILE
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSIDE_PRESENT"* ]]
  [[ "$output" == *"AFTER_GONE"* ]]
  [[ "$output" == *"NO_FLOCK_FILE"* ]]
}

@test "5: timeout; second caller waiting on a held lock returns 75, stderr 'timed out'" {
  # Holder acquires the mkdir lock and sleeps; a second call with a 1s
  # timeout cannot acquire it and must return 75.
  run bash -c "
    . '$LOCK_HELPER'
    export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
    ( with_ledger_lock '$LOCKDIR' sleep 3 ) &
    holder=\$!
    # Wait until the holder actually owns the lock dir.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ -d '$LOCKDIR/specs.lock.d' ] && break
      sleep 0.1
    done
    GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 with_ledger_lock '$LOCKDIR' true
    rc=\$?
    wait \"\$holder\" 2>/dev/null || true
    exit \"\$rc\"
  "
  [ "$status" -eq 75 ]
  [[ "$output" == *"timed out"* ]]
}

@test "6: stale recovery; pre-created stale lock dir is reclaimed, cmd code returned" {
  run bash -c "
    . '$LOCK_HELPER'
    export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
    export GAIA_LEDGER_LOCK_STALE_SECS=1
    mkdir -p '$LOCKDIR/specs.lock.d'
    sleep 2   # age the stale lock past the 1s threshold
    with_ledger_lock '$LOCKDIR' bash -c 'exit 3'
  "
  # Stale dir reclaimed, command ran, its exit code (3) passed through.
  [ "$status" -eq 3 ]
}

@test "7: flock path present; two serialized calls both succeed (skip if no flock)" {
  if ! command -v flock >/dev/null 2>&1; then
    skip "flock not installed on this machine; mkdir fallback is the load-bearing path here"
  fi
  run bash -c "
    . '$LOCK_HELPER'
    unset GAIA_LEDGER_LOCK_FORCE_FALLBACK
    with_ledger_lock '$LOCKDIR' true && echo ONE
    with_ledger_lock '$LOCKDIR' true && echo TWO
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONE"* ]]
  [[ "$output" == *"TWO"* ]]
}
