#!/usr/bin/env bats
#
# Bats suite for the dollar-pricing addition to .gaia/scripts/token-rollup.sh
# (SPEC-019). Every ledger fixture under fixtures/token-price/ is a
# HAND-AUTHORED oracle: expected dollar figures are computed by hand in the
# comments below, never by running the reader first. Every test injects the
# hermetic fixtures/token-price/rates.json via --rate-table so nothing here
# asserts against the live committed .gaia/scripts/token-rates.json (that
# smoke case lives in token-rollup.bats, DP-003).
#
# Fixture inventory + hand-computed oracles:
#
#   rates.json (fixture rate table)
#     claude-opus-4-8:   input 5,  output 25 (no effective_through -- sticker)
#     claude-sonnet-4-6: input 3,  output 15
#     claude-test-intro: input 2 through 2026-08-31 (intro), then input 3 (sticker)
#     cache_multipliers: read 0.1, write_5m 1.25, write_1h 2.0
#
#   cache-ttl.jsonl (SPEC-301, UAT-004: per-TTL cache-write pricing)
#     One execute row, claude-opus-4-8: fresh_input=200,000, cache_write_5m=160,000,
#     cache_write_1h=100,000, cache_read=2,000,000, output=40,000.
#     fresh_input:    200,000 * 5              / 1e6 = $1.00
#     cache_write_5m: 160,000 * 5*1.25 (=6.25)  / 1e6 = $1.00
#     cache_write_1h: 100,000 * 5*2.0  (=10)    / 1e6 = $1.00
#     cache_read:   2,000,000 * 5*0.1  (=0.5)   / 1e6 = $1.00
#     output:          40,000 * 25              / 1e6 = $1.00
#     Total = $5.00 -- a wrong multiplier on any one bucket changes this total,
#     so the single hand-computed sum proves all four rates are applied correctly.
#
#   multi-model.jsonl (SPEC-302, UAT-003: multi-model divergence)
#     One spec row, two models: claude-opus-4-8 fresh_input=3,000,000 ($15.00),
#     claude-sonnet-4-6 fresh_input=1,000,000 ($3.00). Per-model sum = $18.00.
#     A blended single-rate bug (aggregate 4,000,000 tokens priced at either
#     model's own rate) would give $20.00 (opus) or $12.00 (sonnet) -- both
#     asserted absent as regression traps.
#
#   multi-action.jsonl (SPEC-303, UAT-008 Total + grand_dollars, COV-002)
#     spec (opus fresh_input=200,000 -> $1.00), plan (400,000 -> $2.00),
#     execute (600,000 -> $3.00). Total = $6.00, the only case exercising the
#     grand_dollars sum-across-actions path.
#
#   intro-boundary.jsonl (SPEC-304, UAT-007: effective-dated selection +
#   missing anchor)
#     Three execute-action sessions, all claude-test-intro fresh_input=1,000,000:
#       ts=2026-08-15 (inside the intro window)  -> input 2 -> $2.00
#       ts=2026-09-15 (past the intro window)    -> input 3 -> $3.00
#       ts=null (no run-time anchor)              -> unpriced, $0, missing_anchor
#     Total = $5.00 + the missing-anchor marker.
#
#   unknown-model.jsonl (SPEC-305, UAT-005: unknown model + non-claude key)
#     One spec row with by_model = { claude-ghost-9 (unknown claude model,
#     fresh_input=500,000), <synthetic> (non-claude key, fresh_input=999,999) }.
#     claude-ghost-9 is absent from the rate table -> contributes $0, named in
#     the unpriced-model marker. <synthetic> fails the ^claude- test -> silently
#     ignored (no price, no marker). Total = $0.00.
#
#   pre-attribution-only.jsonl (SPEC-306, UAT-006: all rows model-less)
#     spec (total=1000) + execute (total=2000), neither carries by_model ->
#     "unavailable (records predate per-model attribution)"; token lines
#     (spec/execute/Total) still render their real totals.
#
#   mixed-provenance.jsonl (SPEC-307, UAT-010 + UAT-002, COV-003)
#     Two execute-action sessions for the same feature: a legacy row
#     (total=1,234,567, no by_model) and an attributed row (claude-opus-4-8
#     fresh_input=400,000 -> $2.00). Token total = 1,234,567 + 400,000 =
#     1,634,567 (commified "1,634,567") -- proves the legacy row's aggregate
#     is untouched. Dollar total = $2.00 (only the attributed portion), marked
#     partial lower bound (some records predate attribution).
#
#   corrupt-with-price.jsonl (SPEC-308, UAT-009 arm 2 + SC8, COV-001)
#     One priceable execute row (claude-opus-4-8 fresh_input=200,000 -> $1.00)
#     plus one plain-text unparseable line. The priced figure still renders
#     ($1.00) but is marked a partial lower bound for the corrupt record; the
#     token block's own "(partial: ...)" marker also still renders.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-rollup.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-price" && pwd)"
  FIX_ROLLUP="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-rollup" && pwd)"
  RATES="$FIX/rates.json"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- 1. UAT-004: per-TTL cache-write pricing ----------
@test "cache-ttl: per-TTL cache-write and cache-read multipliers all price correctly" {
  run bash "$SCRIPT" --spec-id SPEC-301 --ledger "$FIX/cache-ttl.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'execute:   $5.00'* ]]
  [[ "$output" == *'Total:     $5.00'* ]]
}

# ---------- 2. UAT-003: multi-model divergence, never a blended rate ----------
@test "multi-model: per-model sum, not a blended rate across models" {
  run bash "$SCRIPT" --spec-id SPEC-302 --ledger "$FIX/multi-model.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'spec:      $18.00'* ]]
  [[ "$output" == *'Total:     $18.00'* ]]
  [[ "$output" != *'$20.00'* ]]
  [[ "$output" != *'$12.00'* ]]
}

# ---------- 3. UAT-008 Total + grand_dollars, COV-002 ----------
@test "multi-action: spec/plan/execute all priced, Total equals the cross-action sum" {
  run bash "$SCRIPT" --spec-id SPEC-303 --ledger "$FIX/multi-action.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'spec:      $1.00'* ]]
  [[ "$output" == *'plan:      $2.00'* ]]
  [[ "$output" == *'execute:   $3.00'* ]]
  [[ "$output" == *'Total:     $6.00'* ]]
}

# ---------- 4. UAT-007: effective-dated selection + missing-anchor short-circuit ----------
@test "intro-boundary: intro vs sticker rate selection, null ts is a lower bound not a guess" {
  run bash "$SCRIPT" --spec-id SPEC-304 --ledger "$FIX/intro-boundary.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'execute:   $5.00'* ]]
  [[ "$output" == *'Total:     $5.00'* ]]
  [[ "$output" == *'(lower bound: a session lacked a run-time anchor)'* ]]
  [[ "$output" != *'unpriced model'* ]]
}

# ---------- 5. UAT-005: unknown claude model + stray non-claude key ----------
@test "unknown-model: unpriced claude model is named and zeroed; non-claude key is silently ignored" {
  run bash "$SCRIPT" --spec-id SPEC-305 --ledger "$FIX/unknown-model.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'spec:      $0.00'* ]]
  [[ "$output" == *'Total:     $0.00'* ]]
  [[ "$output" == *'(lower bound: unpriced model(s) claude-ghost-9)'* ]]
  [[ "$output" != *'synthetic'* ]]
}

# ---------- 6. UAT-006: pre-attribution only ----------
@test "pre-attribution-only: unavailable (records predate attribution), token lines unaffected" {
  run bash "$SCRIPT" --spec-id SPEC-306 --ledger "$FIX/pre-attribution-only.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Est. cost (USD): unavailable (records predate per-model attribution)'* ]]
  [[ "$output" == *'spec:      1,000   (elapsed 1m0s)'* ]]
  [[ "$output" == *'execute:   2,000   (elapsed 1m30s)'* ]]
  [[ "$output" == *'Total:     3,000   (elapsed 2m30s)'* ]]
}

# ---------- 7. UAT-010 + UAT-002, COV-003: mixed provenance ----------
@test "mixed-provenance: attributed portion priced, legacy row's token total is byte-unchanged" {
  run bash "$SCRIPT" --spec-id SPEC-307 --ledger "$FIX/mixed-provenance.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  # Legacy row's aggregate token total is unchanged by the by_model addition.
  [[ "$output" == *'execute:   1,634,567   (elapsed 20m0s)'* ]]
  [[ "$output" == *'Total:     1,634,567   (elapsed 20m0s)'* ]]
  # Only the attributed session's tokens are priced.
  [[ "$output" == *'execute:   $2.00'* ]]
  [[ "$output" == *'Total:     $2.00'* ]]
  [[ "$output" == *'(partial lower bound: some records predate per-model attribution)'* ]]
  [[ "$output" != *'unpriced model'* ]]
  [[ "$output" != *'run-time anchor'* ]]
  [[ "$output" != *'unreadable, corrupt, or lacked timing'* ]]
}

# ---------- 8. UAT-009 arm 1: rate table unreadable ----------
@test "rate table unreadable: dollar figure degrades to unavailable, token lines still render, exit 0" {
  run bash "$SCRIPT" --spec-id SPEC-301 --ledger "$FIX/cache-ttl.jsonl" --rate-table "$FIX/does-not-exist.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Est. cost (USD): unavailable (rate table unreadable)'* ]]
  [[ "$output" == *'execute:   2,500,000   (elapsed 5m0s)'* ]]
}

# ---------- 9. UAT-009 arm 2 + SC8, COV-001: corrupt ledger line alongside priceable rows ----------
@test "corrupt ledger: priceable rows still price, marked a partial lower bound, token partial marker intact" {
  run bash "$SCRIPT" --spec-id SPEC-308 --ledger "$FIX/corrupt-with-price.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  [[ "$output" == *'execute:   200,000   (elapsed 5m0s)'* ]]
  [[ "$output" == *'(partial: some ledger input was unreadable or lacked timing; figures are a lower bound)'* ]]
  [[ "$output" == *'execute:   $1.00'* ]]
  [[ "$output" == *'Total:     $1.00'* ]]
  [[ "$output" == *'(partial lower bound: some ledger input was unreadable, corrupt, or lacked timing)'* ]]
}

# ---------- 10. UAT-008, DP-002: byte-unchanged token render, exact prefix ----------
@test "byte-unchanged (clean fixture): existing token output is an exact prefix of the new output" {
  run bash "$SCRIPT" --spec-id SPEC-220 --ledger "$FIX_ROLLUP/full-cycle.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  expected_prefix=$'Cycle cost (SPEC-220):\n  spec:       37,000   (elapsed 10m0s)\n  plan:       38,300   (elapsed 11m40s)\n  execute:    39,600   (elapsed 13m20s)\n  Total:     114,900   (elapsed 35m0s)\n    Fresh input:   3,300\n    Cache write:   6,300\n    Cache read:   93,000\n    Output:       12,300\n'
  [[ "$output" == "$expected_prefix"* ]]
  [[ "$output" == *'Est. cost (USD)'* ]]
}

@test "byte-unchanged (partial fixture): dollar block appends AFTER the trailing token partial marker" {
  run bash "$SCRIPT" --spec-id SPEC-230 --ledger "$FIX_ROLLUP/corrupt.jsonl" --rate-table "$RATES"
  [ "$status" -eq 0 ]
  expected_prefix=$'Cycle cost (SPEC-230):\n  spec:       5,000   (elapsed 1m0s)\n  plan:       6,000   (elapsed 1m30s)\n  Total:     11,000   (elapsed 2m30s)\n    Fresh input:  1,100\n    Cache write:  2,200\n    Cache read:   6,600\n    Output:       1,100\n  (partial: some ledger input was unreadable or lacked timing; figures are a lower bound)\n'
  [[ "$output" == "$expected_prefix"* ]]
  [[ "$output" == *'Est. cost (USD)'* ]]
}
