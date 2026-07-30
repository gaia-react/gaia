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

  SANDBOX="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  git -C "$SANDBOX" init --quiet
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
  bash "$SCRIPT" "$SANDBOX" --ledger "$LEDGER" --rate-table "${1:-$RATES_FULL}" "${@:2}"
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

  # Exactly one backup, holding the pre-rewrite bytes.
  bak="$(find "$(dirname "$LEDGER")" -name 'cost.jsonl.bak.*' | head -n 1)"
  [ -n "$bak" ]
  [ "$(cat "$bak")" = "$before" ]
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
