#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/cost-unpriced-scan.sh, the deterministic detection
# half of the rate-overlay auto-heal (#1089 Layer 4).
#
# The property that matters most here is what the scan does NOT do: it never
# invents a rate. Pricing is unavailable from the Models API and a tier heuristic
# would be actively wrong, so the scan reports names and leaves the number to a
# human-gated Fixer that can source it. Everything below pins the report.
#
# The second property is that detection is RECOMPUTED, never read off the row's
# stored `unpriced` field. That field records what the table was missing when the
# row was written, so trusting it would keep naming a model whose rate has since
# landed and would miss a row written before the field existed.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/cost-unpriced-scan.sh"
  FIX_E2E="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-cost-e2e" && pwd)"
  FIX_PRICE="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally-price" && pwd)"

  [ -f "$SCRIPT" ] || { echo "cost-unpriced-scan.sh not found: $SCRIPT" >&2; return 1; }

  RATES_FULL="$FIX_E2E/rates.json"                       # opus 500/2500, sonnet 300/1500
  RATES_MISSING_SONNET="$FIX_PRICE/rates-missing-sonnet.json"

  SANDBOX="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

BY_MODEL='{"claude-opus-4-8":{"fresh_input":300,"output":30},"claude-sonnet-4-6":{"fresh_input":30,"output":3}}'

# seed_row <ts> [by_model-json] [stored-unpriced-json]
seed_row() {
  jq -c -n --argjson bm "${2:-$BY_MODEL}" --arg ts "$1" --argjson up "${3:-[]}" \
    '{schema_version:1, kind:"execute", session_id:"s1", by_model:$bm,
      dollars:0.76, ts:$ts, final:true}
     | if ($up | length) > 0 then .unpriced = $up else . end' \
    >> "$LEDGER"
}

scan() {
  bash "$SCRIPT" --ledger "$LEDGER" --rate-table "${1:-$RATES_FULL}"
}

@test "a fully priced ledger reports nothing unpriced" {
  seed_row 2026-07-28T07:28:15Z
  run scan "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "0" ]
}

@test "a model with no rate window is named" {
  seed_row 2026-07-28T07:28:15Z
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | join(",")' <<<"$output")" = "claude-sonnet-4-6" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "1" ]
}

@test "the same model across many rows is named once, and the rows are counted" {
  seed_row 2026-07-28T07:28:15Z
  seed_row 2026-07-29T07:28:15Z
  seed_row 2026-07-30T07:28:15Z
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "3" ]
}

@test "detection is recomputed, so a stored unpriced name that now prices is not reported" {
  # The row claims claude-sonnet-4-6 was unpriced when it was written, and under
  # today's table it prices. Reading the stored field would keep nagging about a
  # model the operator already fixed, which is how a self-heal check becomes
  # noise that gets ignored.
  seed_row 2026-07-28T07:28:15Z "$BY_MODEL" '["claude-sonnet-4-6"]'
  run scan "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
}

@test "detection is recomputed, so a row predating the unpriced field is still caught" {
  # No stored `unpriced` at all, which is every row written before the field
  # existed.
  seed_row 2026-07-28T07:28:15Z
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | join(",")' <<<"$output")" = "claude-sonnet-4-6" ]
}

@test "a row that cannot anchor a rate window is not reported as unpriced" {
  # priced_row calls it missing_anchor with a dollars of 0. That is an unknown,
  # not a missing rate, and no overlay entry would fix it. Reporting it would
  # send the operator to write a rate that changes nothing.
  #
  # Seeded directly rather than through seed_row: `--arg ts null` writes the
  # STRING "null", which anchors a window fine and tests nothing. JSON null is
  # the shape priced_row short-circuits on.
  jq -c -n --argjson bm "$BY_MODEL" \
    '{schema_version:1, kind:"execute", session_id:"s1", by_model:$bm,
      dollars:0.76, ts:null, final:true}' >> "$LEDGER"
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "0" ]
}

@test "a row with no attribution is skipped rather than counted" {
  jq -c -n '{schema_version:1, kind:"execute", session_id:"legacy", total:1000,
             ts:"2026-07-28T07:28:15Z", final:true}' >> "$LEDGER"
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
}

@test "a malformed line is skipped and the rest of the ledger still scans" {
  printf 'this is not json\n' >> "$LEDGER"
  seed_row 2026-07-28T07:28:15Z
  run scan "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | join(",")' <<<"$output")" = "claude-sonnet-4-6" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "1" ]
}

@test "an empty ledger is a clean report, not a failure" {
  run scan "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.rows_affected' <<<"$output")" = "0" ]
}

@test "two unpriced models are both named, sorted" {
  seed_row 2026-07-28T07:28:15Z \
    '{"claude-zeta-9":{"fresh_input":10},"claude-alpha-1":{"fresh_input":10}}'
  run scan "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | join(",")' <<<"$output")" = "claude-alpha-1,claude-zeta-9" ]
}

@test "the report says where a rate would be written" {
  seed_row 2026-07-28T07:28:15Z
  cd "$SANDBOX"
  git init -q .
  run bash "$SCRIPT" --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.overlay_path' <<<"$output")" = "$SANDBOX/.gaia/local/token-rates.local.json" ]
}

@test "a model the overlay already prices is neither unpriced nor silent about it" {
  seed_row 2026-07-28T07:28:15Z
  cd "$SANDBOX"
  git init -q .
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$RATES_MISSING_SONNET" "$SANDBOX/.gaia/scripts/token-rates.json"
  cat > "$SANDBOX/.gaia/local/token-rates.local.json" <<'JSON'
{ "models": { "claude-sonnet-4-6": [ { "input": 300, "output": 1500 } ] } }
JSON

  # No --rate-table, so the overlay applies: the scan must answer about the card
  # in force, or it keeps reporting a model the operator already fixed.
  run bash "$SCRIPT" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unpriced | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.overlay_active | join(",")' <<<"$output")" = "claude-sonnet-4-6" ]
}

@test "no overlay in force reports an empty active list, never a phantom entry" {
  seed_row 2026-07-28T07:28:15Z
  run scan "$RATES_FULL"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.overlay_active | length' <<<"$output")" = "0" ]
}

@test "a dangling --ledger exits non-zero instead of spinning forever" {
  run bash "$SCRIPT" --ledger
  [ "$status" -ne 0 ]
  grep -qF -- "needs a path" <<<"$output"
}

@test "an unexpected positional is refused, never parsed and ignored" {
  run bash "$SCRIPT" "$SANDBOX"
  [ "$status" -ne 0 ]
  grep -qF -- "unexpected argument" <<<"$output"
}

@test "an unreadable rate table is a scan failure, not an empty all-clear" {
  seed_row 2026-07-28T07:28:15Z
  run bash "$SCRIPT" --ledger "$LEDGER" --rate-table "$SANDBOX/nope.json"
  [ "$status" -ne 0 ]
  # An all-clear here would read as "nothing is unpriced" for a run that priced
  # nothing at all, which is the false-negative shape this whole area exists to
  # remove.
  grep -qF -- '"unpriced"' <<<"$output" && return 1
  true
}
