#!/usr/bin/env bats
# Concurrency + behavior tests for the SPEC ledger lib (Contracts C2, C3).
#
# The N-parallel test is robust against flake by design: every background
# `next` job blocks until a shared start-flag file exists, then all race at
# once. A passing run with no contention proves nothing; the barrier forces
# genuine overlap, so the UNLOCKED read-modify-write would fail this test
# (two jobs read the same highest_num, allocate a duplicate id, and the
# second `mv` clobbers the first appended row → fewer than N rows and/or a
# duplicate id). The lock is what makes it green.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ALLOC=".specify/extensions/gaia/lib/spec-allocator.sh"
  LEDGER_UPDATE=".specify/extensions/gaia/lib/ledger-update.sh"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Launch N barrier-gated `next` jobs, then release the barrier and wait.
# Writes each job's stdout to "$REPO/out.<i>". $LOCK_ENV is prepended to each
# job so a caller can force the mkdir fallback.
_run_parallel_next() {
  local n="$1"
  local i
  rm -f "$REPO"/out.* "$REPO/start.flag"
  for i in $(seq 1 "$n"); do
    bash -c '
      repo="$1"; alloc="$2"; idx="$3"
      until [ -f "$repo/start.flag" ]; do :; done
      '"${LOCK_ENV:-}"' bash "$repo/$alloc" next "$repo" > "$repo/out.$idx" 2>/dev/null
    ' _ "$REPO" "$ALLOC" "$i" &
  done
  # Release the barrier; all jobs were spinning on this file's existence.
  touch "$REPO/start.flag"
  wait
}

# --- Test 8: N-parallel next → N distinct ids, zero lost rows -----------------

@test "8a: N-parallel next (real flock if present); N distinct ids, N rows, no dupes" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  cd "$REPO"
  N=10
  LOCK_ENV="" _run_parallel_next "$N"

  printed="$(cat "$REPO"/out.* | sort)"
  distinct="$(printf '%s\n' "$printed" | sort -u)"
  [ "$(printf '%s\n' "$printed" | grep -c '^SPEC-[0-9]\{3\}$')" -eq "$N" ]
  [ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" -eq "$N" ]

  rows="$(jq -r '.specs[].id' "$REPO/.gaia/local/specs/ledger.json")"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq "$N" ]
  # No duplicate ids in the ledger.
  [ "$(printf '%s\n' "$rows" | sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
  # Every printed id appears in the ledger.
  while IFS= read -r id; do
    printf '%s\n' "$rows" | grep -qx "$id"
  done <<< "$distinct"
}

@test "8b: N-parallel next (forced mkdir fallback); N distinct ids, N rows, no dupes" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  cd "$REPO"
  N=10
  LOCK_ENV="GAIA_LEDGER_LOCK_FORCE_FALLBACK=1" _run_parallel_next "$N"

  printed="$(cat "$REPO"/out.* | sort)"
  distinct="$(printf '%s\n' "$printed" | sort -u)"
  [ "$(printf '%s\n' "$printed" | grep -c '^SPEC-[0-9]\{3\}$')" -eq "$N" ]
  [ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" -eq "$N" ]

  rows="$(jq -r '.specs[].id' "$REPO/.gaia/local/specs/ledger.json")"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq "$N" ]
  [ "$(printf '%s\n' "$rows" | sort | uniq -d | wc -l | tr -d ' ')" -eq 0 ]
  while IFS= read -r id; do
    printf '%s\n' "$rows" | grep -qx "$id"
  done <<< "$distinct"
}

# --- Test 9: stale-lock recovery in `next` -----------------------------------

@test "9: stale-lock recovery in next; reclaims stale dir, allocates next id" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  cd "$REPO"
  mkdir -p "$REPO/.gaia/specs.lock.d"
  sleep 2  # age past GAIA_LEDGER_LOCK_STALE_SECS=1
  run bash -c "GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_STALE_SECS=1 bash '$REPO/$ALLOC' next '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-002" ]
  [ "$(jq -r '[.specs[].id] | length' "$REPO/.gaia/local/specs/ledger.json")" -eq 2 ]
}

# --- Test 10–12: in_progress contract ----------------------------------------

@test "10: in_progress surfaces a draft ledger row (defect-2 regression)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-007)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-007" ]
}

@test "11: in_progress no fallback; folder file without a ledger row is not surfaced" {
  # The SPEC-file frontmatter fallback is intentionally gone: in_progress
  # sources the ledger only. A foldered SPEC.md with no ledger row must NOT be
  # surfaced as in-flight, otherwise finalized work re-flags as resumable
  # forever (the defect-2 staleness this design removes; see test 10).
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-folder SPEC-013)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "12: in_progress none; empty ledger, no files" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

# --- Test 13: read-only modes take no lock -----------------------------------

@test "13: highest and in_progress create no lock file or dir" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  cd "$REPO"
  run bash -c "bash '$REPO/$ALLOC' highest '$REPO'"
  [ "$status" -eq 0 ]
  run bash -c "bash '$REPO/$ALLOC' in_progress '$REPO'"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.gaia/specs.lock" ]
  [ ! -e "$REPO/.gaia/specs.lock.d" ]
}

# --- Test 14: exit-code preservation -----------------------------------------

@test "14a: non-git dir; next exits 3" {
  # Build a tmp repo via the helper (so the scripts + sibling source resolve),
  # then strip .git so require_git fails. REPO is set so teardown cleans up.
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  rm -rf "$REPO/.git"
  run bash -c "bash '$REPO/$ALLOC' next '$REPO'"
  [ "$status" -eq 3 ]
}

@test "14b: forced jq failure; next exits 4 (exit code propagates THROUGH the lock)" {
  # This is the load-bearing negative assertion for the Phase-2 swallowed-rc
  # bug: append_ledger_row returns 4 on jq failure; with_ledger_lock must
  # pass that 4 through unchanged, and `next` must exit 4 (NOT 0). A failing
  # `jq` is forced by shadowing it with a stub early on PATH.
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  cd "$REPO"
  realjq="$(command -v jq)"
  stubdir="$REPO/stubbin"
  mkdir -p "$stubdir"
  cat > "$stubdir/jq" <<EOF
#!/usr/bin/env bash
# Fail only the write (--arg id ... '.specs += ...'); pass read-side jq
# (highest_num's '.specs[].id') through to the real jq so the script reaches
# the append critical section and the write jq is the one that fails.
for a in "\$@"; do
  case "\$a" in
    *".specs += "*) exit 1 ;;
  esac
done
exec "$realjq" "\$@"
EOF
  chmod +x "$stubdir/jq"
  run bash -c "PATH='$stubdir:$PATH' bash '$REPO/$ALLOC' next '$REPO'"
  [ "$status" -eq 4 ]
  # Ledger left unchanged; no row appended on the failed write.
  [ "$(jq -r '[.specs[].id] | length' "$REPO/.gaia/local/specs/ledger.json")" -eq 0 ]
}

@test "14c: lock timeout; next exits 4, ledger unchanged (75 maps to 4)" {
  # Hold the lock with a slow background job, then a real `next` with a tiny
  # timeout cannot acquire it. The helper returns 75; `next` maps that to
  # exit 4 (ledger-write-class failure) per Contract C2. Asserts the timeout
  # path propagates THROUGH the lock as a non-zero exit, not a swallowed 0.
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  cd "$REPO"
  before="$(jq -r '[.specs[].id] | length' "$REPO/.gaia/local/specs/ledger.json")"
  run bash -c "
    export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
    . '$REPO/.specify/extensions/gaia/lib/with-ledger-lock.sh'
    ( with_ledger_lock '$REPO/.gaia' sleep 4 ) &
    holder=\$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ -d '$REPO/.gaia/specs.lock.d' ] && break
      sleep 0.1
    done
    GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 bash '$REPO/$ALLOC' next '$REPO'
    rc=\$?
    wait \"\$holder\" 2>/dev/null || true
    exit \"\$rc\"
  "
  [ "$status" -eq 4 ]
  after="$(jq -r '[.specs[].id] | length' "$REPO/.gaia/local/specs/ledger.json")"
  [ "$before" -eq "$after" ]
}

@test "14d: ledger-update invalid patch JSON exits 5 (propagates THROUGH the lock)" {
  # Companion negative assertion for Contract C3: a bad patch makes
  # apply_patch return 5; with_ledger_lock must pass 5 through and
  # ledger-update.sh must exit 5 (NOT 0, and NOT the 4 reserved for lock
  # timeout / missing ledger).
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  cd "$REPO"
  run bash -c "bash '$REPO/$LEDGER_UPDATE' '$REPO' SPEC-001 'not-json'"
  [ "$status" -eq 5 ]
}

# --- Test 15: ledger-update racing next (Contract C3 cross-script) ------------

@test "15: ledger-update racing N-parallel next; ledger valid, no row lost" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --seed-draft SPEC-001)"
  cd "$REPO"
  N=8
  rm -f "$REPO"/out.* "$REPO/start.flag"

  # N barrier-gated allocator jobs.
  for i in $(seq 1 "$N"); do
    bash -c '
      repo="$1"; alloc="$2"; idx="$3"
      until [ -f "$repo/start.flag" ]; do :; done
      GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/$alloc" next "$repo" > "$repo/out.$idx" 2>/dev/null
    ' _ "$REPO" "$ALLOC" "$i" &
  done
  # One barrier-gated step-8-style flip of the seeded draft row.
  bash -c '
    repo="$1"; lu="$2"
    until [ -f "$repo/start.flag" ]; do :; done
    GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/$lu" "$repo" SPEC-001 "{\"status\":\"in-progress\"}" 2>/dev/null
  ' _ "$REPO" "$LEDGER_UPDATE" &

  touch "$REPO/start.flag"
  wait

  # Ledger is still valid JSON.
  run jq -e . "$REPO/.gaia/local/specs/ledger.json"
  [ "$status" -eq 0 ]
  # Seeded row flipped to in-progress.
  [ "$(jq -r '.specs[] | select(.id=="SPEC-001") | .status' "$REPO/.gaia/local/specs/ledger.json")" = "in-progress" ]
  # SPEC-001 + N freshly allocated rows, all present, no row lost.
  total="$(jq -r '[.specs[].id] | length' "$REPO/.gaia/local/specs/ledger.json")"
  [ "$total" -eq "$((N + 1))" ]
  # No duplicate ids.
  dupes="$(jq -r '.specs[].id' "$REPO/.gaia/local/specs/ledger.json" | sort | uniq -d | wc -l | tr -d ' ')"
  [ "$dupes" -eq 0 ]
}
