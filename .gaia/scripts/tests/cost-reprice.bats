#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/cost-reprice.sh -- the one-off that re-prices
# already-written cost.jsonl rows under the current rate table.
#
# Context (#1088): a model absent from the rate table prices every one of its
# buckets at zero and still returns a well-formed row, so rows written while a
# key was missing carry a `dollars` that is confidently wrong. Each row stores
# its raw per-model `by_model` buckets plus its own `ts`, so the correction is a
# pure function of data already on disk -- no transcript re-derivation.
#
# Unlike cost-backfill.sh (append-only, never touches an existing row), this
# script REWRITES rows in a gitignored, unversioned file. The tests below pin
# the properties that makes safe: rows it does not change stay BYTE-identical,
# no row is ever dropped, a malformed line survives, a backup is written, and a
# second run is a no-op.
#
# Four of them pin failure modes rather than features, each one a way the rewrite
# could destroy data it was asked to correct:
#   - the whole read-modify-write sits inside the cost mutex, so a concurrent
#     tally append cannot be dropped by a rewrite that only emits what an
#     unlocked classify pass saw (asserted through a held lock: no report line
#     and no backup, since both once ran before the lock was taken);
#   - a row whose ts cannot anchor a rate window passes through untouched rather
#     than having priced_row's missing_anchor zero stored over a real figure;
#   - a same-second second run cannot clobber the first run's backup;
#   - a dangling --ledger / --rate-table exits instead of spinning forever, and a
#     positional the script cannot honor is refused rather than parsed and
#     dropped.
#
# Rates fixtures REUSED, never re-derived here:
#   fixtures/token-cost-e2e/rates.json          opus 500/2500, sonnet 300/1500
#   fixtures/token-tally-price/rates-missing-sonnet.json   opus only
#   fixtures/token-tally-price/rates-intro.json  intro window dated 2099-12-31
#
# Against the multimodel by_model seeded below (hand-computed in
# token-tally.bats, quoted in token-tally-price.bats's header):
#   opus:    (300*500 + 40*500*1.25 + 360*500*2.0 + 3000*500*0.1 + 30*2500)/1e6 = 0.76
#   sonnet:  (30*300  + 10*300*1.25 + 20*300*2.0  + 3000*300*0.1 + 3*1500) /1e6 = 0.11925
#   full table -> 0.87925;  missing-sonnet table -> 0.76;  intro (2x) -> 1.7585
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/cost-reprice.sh"
  FIX_E2E="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-cost-e2e" && pwd)"
  FIX_PRICE="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally-price" && pwd)"

  [ -f "$SCRIPT" ] || skip "cost-reprice.sh not found"

  RATES_FULL="$FIX_E2E/rates.json"
  RATES_MISSING_SONNET="$FIX_PRICE/rates-missing-sonnet.json"
  RATES_INTRO="$FIX_PRICE/rates-intro.json"

  # No `git init` here: every case passes --ledger and --rate-table explicitly,
  # and both resolvers short-circuit on an override without consulting git. The
  # script takes no <repo_root> positional to make a sandbox repo relevant to.
  SANDBOX="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

# The by_model both seeded rows carry.
BY_MODEL='{"claude-opus-4-8":{"fresh_input":300,"cache_write_5m":40,"cache_write_1h":360,"cache_read":3000,"output":30},"claude-sonnet-4-6":{"fresh_input":30,"cache_write_5m":10,"cache_write_1h":20,"cache_read":3000,"output":3}}'

# seed_row <dollars> <ts> [extra-json]
seed_row() {
  jq -c -n --argjson bm "$BY_MODEL" --argjson d "$1" --arg ts "$2" \
    '{schema_version:1, kind:"execute", session_id:"s1", by_model:$bm,
      dollars:$d, rate_table_id:"sha256:stale00000000000", ts:$ts, final:true}' \
    >> "$LEDGER"
}

run_reprice() {
  bash "$SCRIPT" --ledger "$LEDGER" --rate-table "${1:-$RATES_FULL}" "${@:2}"
}

# Portable stand-in for `timeout`, which stock macOS does not ship (a BSD/GNU
# divergence .claude/rules/bats-assertions.md calls out). Sets `status` and
# `output` the way bats' own `run` does, and reports 124 when the deadline hits so
# a command that never returns fails its test instead of hanging the whole suite.
run_deadline() {
  local secs="$1"; shift
  local out="$BATS_TEST_TMPDIR/deadline.out" pid i=0
  : > "$out"
  "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$((secs * 10))" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      status=124
      output="$(cat "$out")"
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if wait "$pid"; then status=0; else status=$?; fi
  output="$(cat "$out")"
  return 0
}

@test "re-prices a row whose model was missing from the table when it was written" {
  seed_row 0.76 2026-07-28T07:28:15Z
  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.dollars' "$LEDGER")" = "0.87925" ]
  # rate_table_id follows the value, so the pair never disagrees about which
  # table produced the figure.
  [ "$(jq -r '.rate_table_id' "$LEDGER")" != "sha256:stale00000000000" ]
}

@test "a row that already prices correctly is left byte-identical" {
  seed_row 0.87925 2026-07-28T07:28:15Z
  before="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(cat "$LEDGER")" = "$before" ]
}

@test "a second run changes nothing (idempotent)" {
  seed_row 0.76 2026-07-28T07:28:15Z
  run_reprice "$RATES_FULL"
  after_first="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(cat "$LEDGER")" = "$after_first" ]
  grep -qF -- '0 row' <<<"$output"
}

@test "a malformed line survives byte-unchanged and no row is dropped" {
  seed_row 0.76 2026-07-28T07:28:15Z
  printf '%s\n' 'not json {{{' >> "$LEDGER"
  seed_row 0.76 2026-07-28T07:28:15Z

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 3 ]
  [ "$(sed -n '2p' "$LEDGER")" = 'not json {{{' ]
  [ "$(sed -n '1p' "$LEDGER" | jq -r '.dollars')" = "0.87925" ]
  [ "$(sed -n '3p' "$LEDGER" | jq -r '.dollars')" = "0.87925" ]
}

@test "a row with no by_model attribution is left byte-identical" {
  jq -c -n '{schema_version:1, kind:"execute", session_id:"legacy",
             dollars:null, ts:"2026-07-28T07:28:15Z"}' >> "$LEDGER"
  before="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(cat "$LEDGER")" = "$before" ]
}

@test "--dry-run reports the change but writes nothing" {
  seed_row 0.76 2026-07-28T07:28:15Z
  before="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL" --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$LEDGER")" = "$before" ]
  grep -qF -- '0.87925' <<<"$output"
}

@test "the pre-rewrite ledger is backed up before any row changes" {
  seed_row 0.76 2026-07-28T07:28:15Z
  before="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]

  # Exactly one backup, holding the pre-rewrite bytes. The count is asserted,
  # not just the presence: "at least one" would also pass if the script wrote a
  # spurious second copy.
  [ "$(find "$(dirname "$LEDGER")" -name 'cost.jsonl.bak.*' | wc -l | tr -d ' ')" -eq 1 ]
  bak="$(find "$(dirname "$LEDGER")" -name 'cost.jsonl.bak.*' | head -n 1)"
  [ -n "$bak" ]
  [ "$(cat "$bak")" = "$before" ]
}

@test "a second backup in the same second does not clobber the first" {
  # The stamp has second granularity, so two quick runs collide on the path. The
  # first run's copy is the only pre-image of the original ledger; losing it to
  # an overwrite would leave no undo for the very rows the first run rewrote.
  seed_row 0.76 2026-07-28T07:28:15Z
  original="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]

  # Re-dirty the ledger so the second run has something to change (and so it
  # takes a backup at all), then run again immediately.
  : > "$LEDGER"
  seed_row 0.76 2026-07-28T07:28:15Z
  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]

  # Two runs, two distinct backups, and the first still holds the first pre-image.
  [ "$(find "$(dirname "$LEDGER")" -name 'cost.jsonl.bak.*' | wc -l | tr -d ' ')" -eq 2 ]
  matches="$(grep -lF -- "$original" "$(dirname "$LEDGER")"/cost.jsonl.bak.* | wc -l | tr -d ' ')"
  [ "$matches" -ge 1 ]
}

@test "a row whose ts cannot anchor a rate window is left byte-identical" {
  # priced_row short-circuits an empty/null ts to {dollars: 0, missing_anchor:
  # true}, which is an "unknown", not a recomputed zero. The row clears the
  # candidate gate (object, by_model, numeric dollars), so without an explicit
  # missing_anchor check the rewrite would store that 0 over a real figure and
  # report it as a legitimate re-price.
  jq -c -n --argjson bm "$BY_MODEL" \
    '{schema_version:1, kind:"execute", session_id:"anchorless", by_model:$bm,
      dollars:0.87925, rate_table_id:"sha256:stale00000000000", ts:null}' \
    >> "$LEDGER"
  before="$(cat "$LEDGER")"

  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(cat "$LEDGER")" = "$before" ]
  grep -qF -- '0 row' <<<"$output"
}

@test "a dangling --ledger exits non-zero instead of spinning forever" {
  # `shift 2` with one argument left fails silently under `set -uo pipefail`
  # (there is no `set -e`), so an unguarded loop re-tests the same $1 forever:
  # a mute infinite loop at 100% CPU from a typo. The deadline IS the assertion --
  # it fails this test rather than hanging the suite if the guard regresses.
  run_deadline 10 bash "$SCRIPT" --ledger
  [ "$status" -ne 124 ]
  [ "$status" -ne 0 ]
  grep -qF -- 'needs a path' <<<"$output"
}

@test "a dangling --rate-table exits non-zero instead of spinning forever" {
  run_deadline 10 bash "$SCRIPT" --ledger "$LEDGER" --rate-table
  [ "$status" -ne 124 ]
  [ "$status" -ne 0 ]
  grep -qF -- 'needs a path' <<<"$output"
}

@test "an unexpected positional is refused, never parsed and ignored" {
  # Both resolvers answer from the process CWD, so a <repo_root> cannot be
  # honored. Accepting one silently reprices THIS checkout while reporting
  # success for the one that was named.
  seed_row 0.76 2026-07-28T07:28:15Z
  before="$(cat "$LEDGER")"

  run bash "$SCRIPT" "$SANDBOX" --ledger "$LEDGER" --rate-table "$RATES_FULL"
  [ "$status" -ne 0 ]
  [ "$(cat "$LEDGER")" = "$before" ]
  grep -qF -- 'unexpected argument' <<<"$output"
}

@test "an empty ledger is a success with nothing to do, not a failure" {
  # setup() leaves the ledger existing and empty. Exit 0: the header promises
  # non-zero means a real failure, and a fresh checkout is not one.
  run run_reprice "$RATES_FULL"
  [ "$status" -eq 0 ]
  grep -qF -- 'empty' <<<"$output"
}

@test "a held lock stops the run before it reads or backs up anything" {
  # The whole read-modify-write belongs inside the mutex. Classify, the report,
  # and the backup all ran BEFORE the lock at one point, which meant a tally
  # appending mid-run was dropped by a rewrite that only emitted the lines
  # classify saw -- and the backup taken before that window did not hold the
  # lost row either. With the lock held from outside, a correctly-scoped run
  # produces no report line and no backup at all.
  seed_row 0.76 2026-07-28T07:28:15Z
  before="$(cat "$LEDGER")"

  # Force the portable mkdir primitive and pre-create its lock dir, so the run
  # cannot acquire. A high stale threshold keeps it from being reclaimed.
  mkdir -p "$(dirname "$LEDGER")/specs.lock.d"

  run env GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 \
      GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 \
      GAIA_LEDGER_LOCK_STALE_SECS=9999 \
      bash "$SCRIPT" --ledger "$LEDGER" --rate-table "$RATES_FULL"
  [ "$status" -ne 0 ]

  [ "$(cat "$LEDGER")" = "$before" ]
  [ "$(find "$(dirname "$LEDGER")" -name 'cost.jsonl.bak.*' | wc -l | tr -d ' ')" -eq 0 ]
  # `->` appears only in a per-row report line ("$before -> $after"), so it is the
  # substring that proves classify ran. Matching on "reprice:" would not: the
  # lock-timeout message itself contains "cost-reprice:".
  grep -qF -- '->' <<<"$output" && return 1
  grep -qF -- 'lock timed out' <<<"$output"
}

@test "each row re-prices against its OWN ts, not wall-clock now" {
  # rates-intro.json's intro window runs through 2099-12-31, so it wins for any
  # row date -- proving the window comes from the row rather than the clock, and
  # that re-pricing after an intro window closes still uses the historical rate.
  seed_row 0 2026-07-28T07:28:15Z
  run run_reprice "$RATES_INTRO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dollars' "$LEDGER")" = "1.7585" ]
}

@test "a still-unpriced model is named on the row it could not fully price" {
  seed_row 0 2026-07-28T07:28:15Z
  run run_reprice "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.dollars' "$LEDGER")" = "0.76" ]
  [ "$(jq -r '.unpriced | join(",")' "$LEDGER")" = "claude-sonnet-4-6" ]
}
