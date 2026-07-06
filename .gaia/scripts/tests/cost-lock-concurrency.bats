#!/usr/bin/env bats
#
# Concurrency oracle for token-tally.sh's cost-ledger write under the shared cost
# mutex. cost.jsonl resolves to the main checkout, so every parallel-worktree
# session appends to one shared file; the append plus (execute only) the
# clear_prior_finals read -> rewrite -> mv is a read-modify-write hazard. This
# suite proves the mutex serializes that hazard so no row is lost:
#   UAT-001  N concurrent execute writers all land, on both lock paths.
#   UAT-002  two linked worktrees serialize on ONE main-checkout lock.
#   UAT-003  a lock-acquisition timeout degrades to append-without-rewrite.
#
# Assertion style note (mirrors token-cost-e2e.bats): on macOS's system
# /bin/bash (3.2) a failing bare `[[ ... ]]` inside a bats @test does NOT fail
# the test, so every non-final assertion here uses POSIX `[ ... ]`, `grep -qF`,
# `jq -e`, or a helper ending in an explicit `return 1`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TALLY="$SCRIPT_DIR/token-tally.sh"
  LEDGER_LIB="$SCRIPT_DIR/ledger-path-lib.sh"

  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"
  ANCHOR="$FIX/projects"
  SESSION="fixturesession0001"

  # Git identity for the throwaway worktree sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- helpers ----------

# Append one real execute row to the given ledger (a prior final for the fixed
# (session, spec) key, so clear_prior_finals has a snapshot to rewrite).
seed_one_execute() {
  bash "$TALLY" --action execute --spec-id SPEC-026 --plan-slug spec-026-cost-lock-folder-delete \
    --out-dir "$BATS_TEST_TMPDIR/seed-out" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$1" >/dev/null 2>&1
}

# Launch N execute writers blocked on a shared start-flag barrier, release the
# barrier, then wait for all. Each writer gets its own --out-dir so only the
# ledger is contended. The lock mode (flock vs forced fallback) is inherited
# from the caller's exported environment.
race_writers() {
  local n="$1" ledger="$2" barrier="$3" i p
  local pids=()
  for i in $(seq 1 "$n"); do
    ( until [ -f "$barrier" ]; do :; done
      bash "$TALLY" --action execute --spec-id SPEC-026 --plan-slug spec-026-cost-lock-folder-delete \
        --out-dir "$BATS_TEST_TMPDIR/out-$i" --session-id "$SESSION" \
        --projects-root "$ANCHOR" --ledger "$ledger" >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  : > "$barrier"
  for p in "${pids[@]}"; do wait "$p"; done
}

# The ledger has exactly `expected` lines, every line is a JSON object (no
# truncation/interleaving), and no execute row is missing its total.
assert_all_landed() {
  local ledger="$1" expected="$2" lines line
  lines="$(wc -l < "$ledger" | tr -d ' ')"
  [ "$lines" -eq "$expected" ] || {
    echo "cost.jsonl has $lines lines, expected $expected (a lost/raced append)" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line" || {
      echo "non-object cost.jsonl line: $line" >&2
      return 1
    }
  done < "$ledger"
  jq -e 'if (.kind == "execute" and .total == null) then error("missing total") else true end' \
    "$ledger" >/dev/null 2>&1 || {
    echo "an execute row is missing its total" >&2
    return 1
  }
}

# ---------- UAT-001: N concurrent execute writers, both lock paths ----------

@test "UAT-001 (fallback): 8 concurrent execute writers all land (atomic-mkdir path)" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  local ledger="$BATS_TEST_TMPDIR/ledger.jsonl"
  seed_one_execute "$ledger"
  local baseline
  baseline="$(wc -l < "$ledger" | tr -d ' ')"
  [ "$baseline" -ge 1 ]

  race_writers 8 "$ledger" "$BATS_TEST_TMPDIR/go-fallback"
  assert_all_landed "$ledger" "$((baseline + 8))"
}

@test "UAT-001 (flock): 8 concurrent execute writers all land (real flock path)" {
  if ! command -v flock >/dev/null 2>&1; then
    skip "flock not installed on this machine; the atomic-mkdir variant is the load-bearing path here"
  fi
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK
  local ledger="$BATS_TEST_TMPDIR/ledger.jsonl"
  seed_one_execute "$ledger"
  local baseline
  baseline="$(wc -l < "$ledger" | tr -d ' ')"
  [ "$baseline" -ge 1 ]

  race_writers 8 "$ledger" "$BATS_TEST_TMPDIR/go-flock"
  assert_all_landed "$ledger" "$((baseline + 8))"
}

# ---------- UAT-002: two linked worktrees observe ONE main-checkout lock ----------

@test "UAT-002: main + linked worktree serialize on one main-checkout lock; both rows land" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  # pwd -P the tmp base up front so the lib's `cd ... && pwd` yields a path that
  # compares byte-for-byte (macOS /tmp -> /private/tmp symlink otherwise diverges).
  local base
  base="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  local MAIN="$base/main" WT="$base/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  git -C "$MAIN" worktree add -q "$WT" -b "feature/kickoff"

  # Both checkouts resolve the ledger to the SAME main-checkout path (the lock
  # key is dirname of this). A worktree-relative key would diverge here.
  local main_ledger wt_ledger expected_ledger
  main_ledger="$(cd "$MAIN" && bash -c '. "$1"; gaia_resolve_ledger_path ""' _ "$LEDGER_LIB")"
  wt_ledger="$(cd "$WT" && bash -c '. "$1"; gaia_resolve_ledger_path ""' _ "$LEDGER_LIB")"
  expected_ledger="$MAIN/.gaia/local/telemetry/cost.jsonl"
  [ "$main_ledger" = "$expected_ledger" ]
  [ "$wt_ledger" = "$expected_ledger" ]

  # One write from each checkout, NO --ledger override, so resolution is live.
  run bash -c "cd '$MAIN' && bash '$TALLY' \
    --action execute --spec-id SPEC-026 --plan-slug spec-026-cost-lock-folder-delete \
    --out-dir '$MAIN/out' --session-id '$SESSION' --projects-root '$ANCHOR'"
  [ "$status" -eq 0 ]
  run bash -c "cd '$WT' && bash '$TALLY' \
    --action execute --spec-id SPEC-026 --plan-slug spec-026-cost-lock-folder-delete \
    --out-dir '$WT/out' --session-id '$SESSION' --projects-root '$ANCHOR'"
  [ "$status" -eq 0 ]

  # The shared main-checkout cost.jsonl gained BOTH rows ...
  [ -f "$expected_ledger" ]
  [ "$(wc -l < "$expected_ledger" | tr -d ' ')" -eq 2 ]
  # ... and no per-worktree telemetry dir (hence no second lock) was ever created.
  [ ! -e "$WT/.gaia/local/telemetry" ]

  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
}

# ---------- UAT-003: timeout degradation appends without the rewrite ----------

@test "UAT-003: a held lock past the timeout degrades to append-without-rewrite; row still lands, exit 0" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  local tel="$BATS_TEST_TMPDIR/tel"
  local ledger="$tel/ledger.jsonl"
  mkdir -p "$tel"

  # A prior valid row, written before the lock is held.
  seed_one_execute "$ledger"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ]

  # Pin the atomic-mkdir lock artifact directly (freshly created, so it is not
  # stale-reclaimed inside the blocked writer's 1s window). No background process
  # to signal: the hold lasts exactly until the explicit rmdir below.
  mkdir "$tel/specs.lock.d"
  [ -d "$tel/specs.lock.d" ]

  # The blocked writer cannot acquire within 1s; it must degrade to the append.
  run env GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 \
    bash "$TALLY" --action execute --spec-id SPEC-026 --plan-slug spec-026-cost-lock-folder-delete \
    --out-dir "$BATS_TEST_TMPDIR/out-blocked" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$ledger"

  rmdir "$tel/specs.lock.d" 2>/dev/null || true

  # Degraded success: exit 0, the row landed (1 -> 2), ledger stays valid JSON.
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 2 ]
  assert_all_landed "$ledger" 2
  # The just-appended (degraded) row is a real execute row with its total intact.
  [ "$(jq -r 'select(.kind == "execute") | .total' "$ledger" | tail -1)" -eq 11110 ]
}
