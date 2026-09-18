#!/usr/bin/env bats

# Tests for the single-flight lock in .gaia/scripts/check-updates.sh.
#
# The statusline fires the refresher on every render, and the TTL gate reads
# `checkedAt`, which is only written when a run finishes. Without a lock,
# every render between a run's start and its cache write launches another
# full run, each paging the merged-PR window through gh. These tests hold one
# run open inside a mock `harden-tally` and assert a second run neither
# starts the tally nor writes the cache, that a normal run releases the lock,
# and that a lock left behind by a killed run is reclaimed once stale rather
# than blocking every future refresh.

setup() {
  CHECK_UPDATES_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)/check-updates.sh

  REFRESH_ROOT=$(mktemp -d -t gaia-cu-lock-XXXXXX)
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" "$REFRESH_ROOT/.gaia/local/cache/shared"
  cp "$CHECK_UPDATES_SRC" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  chmod +x "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  write_mock_gaia "$REFRESH_ROOT/.gaia/cli/gaia"

  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  write_stub_gh "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"

  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  LOCK_DIR="$REFRESH_ROOT/.gaia/local/cache/shared/.update-check.lock"
  export MOCK_LOG="$BATS_TEST_TMPDIR/tally.log"
  export MOCK_HOLD="$BATS_TEST_TMPDIR/hold"
  export MOCK_ENTERED="$BATS_TEST_TMPDIR/entered"
}

teardown() {
  rm -f "$MOCK_HOLD" 2>/dev/null
  [ -n "${REFRESH_ROOT:-}" ] && rm -rf "$REFRESH_ROOT" || true
  return 0
}

# A `gaia` stub. `harden-tally` appends one line to $MOCK_LOG per invocation,
# touches $MOCK_ENTERED, then, while $MOCK_HOLD exists, waits (bounded) so a
# test can hold a run open mid-refresh. Every other subcommand answers empty.
write_mock_gaia() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  update-deps)
    out=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --emit-updates) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$out" ] && printf '{"actionable_count":0}' > "$out"
    exit 0
    ;;
  harden-tally)
    printf 'tally\n' >> "$MOCK_LOG"
    : > "$MOCK_ENTERED"
    i=0
    while [ -e "$MOCK_HOLD" ] && [ "$i" -lt 200 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    printf '{"candidate_count":2,"unclassified":null,"gh_ok":true,"window_days":90}'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$1"
}

write_stub_gh() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  release) printf 'v0.0.0\n'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

# Wait (bounded) for the held run to reach harden-tally.
wait_for_entered() {
  local i=0
  while [ ! -e "$MOCK_ENTERED" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$MOCK_ENTERED" ]
}

@test "a second run while one is in flight starts no tally and writes no cache" {
  : > "$MOCK_HOLD"
  bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" &
  held_pid=$!
  wait_for_entered

  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$CACHE_FILE" ]
  [ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 1 ]

  rm -f "$MOCK_HOLD"
  wait "$held_pid"
  [ "$(jq -r '.hardenCandidateCount' "$CACHE_FILE")" -eq 2 ]
  [ "$(wc -l < "$MOCK_LOG" | tr -d ' ')" -eq 1 ]
}

@test "a completed run releases the lock" {
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ]
  [ ! -e "$LOCK_DIR" ]
}

@test "a run inside the TTL neither takes nor leaves the lock" {
  printf '{"checkedAt":%s}' "$(date +%s)" > "$CACHE_FILE"
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK_DIR" ]
  [ ! -e "$MOCK_LOG" ]
}

@test "a fresh lock held by another run blocks this one" {
  mkdir "$LOCK_DIR"
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$CACHE_FILE" ]
  [ ! -e "$MOCK_LOG" ]
  [ -d "$LOCK_DIR" ]
}

@test "a run whose lock was reclaimed leaves its successor's lock in place on exit" {
  : > "$MOCK_HOLD"
  bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" &
  held_pid=$!
  wait_for_entered

  # A successor reclaimed the held run's lock as stale and took its own,
  # writing its own owner file as every real successor does.
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf 'other\n' > "$LOCK_DIR/owner"

  rm -f "$MOCK_HOLD"
  wait "$held_pid"
  [ -d "$LOCK_DIR" ]
}

# Two contenders saw the same stale lock; the other already reclaimed it, so
# the lock this run renames aside is live. A `find` stub reports the lock
# stale on its first probe only, which reproduces that interleaving
# deterministically: the lock on disk is fresh.
@test "a reclaim that finds the renamed lock live hands it back and does not run" {
  real_find=$(command -v find)
  cat > "$GH_BIN/find" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *.update-check.lock)
    if [ ! -e "$BATS_TEST_TMPDIR/probed" ]; then
      : > "$BATS_TEST_TMPDIR/probed"
      printf '%s\n' "\$1"
      exit 0
    fi
    ;;
esac
exec "$real_find" "\$@"
EOF
  chmod +x "$GH_BIN/find"
  mkdir "$LOCK_DIR"
  printf 'other\n' > "$LOCK_DIR/owner"

  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG" ]
  [ ! -f "$CACHE_FILE" ]
  [ "$(cat "$LOCK_DIR/owner")" = "other" ]
}

@test "a stale lock left by a killed run is reclaimed and the refresh proceeds" {
  mkdir "$LOCK_DIR"
  touch -t 200001010000 "$LOCK_DIR"
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hardenCandidateCount' "$CACHE_FILE")" -eq 2 ]
  [ ! -e "$LOCK_DIR" ]
}
