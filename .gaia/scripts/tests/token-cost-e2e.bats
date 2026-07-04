#!/usr/bin/env bats
#
# End-to-end integration oracle for SPEC-019 (Phase 2 of the dollar-cost plan).
# Phase 1 built the write half (token-tally.sh emits FC-1's by_model) and the
# read half (token-rollup.sh consumes it + prices it) independently against the
# frozen contract in README.md. Each half's own bats suite tests it in
# isolation against hand-authored fixtures. This suite is the ONE test that
# actually chains the REAL token-tally.sh into the REAL token-rollup.sh, so a
# field-name/bucket-name/nesting drift between the two halves fails loudly
# here instead of surfacing later as a silent "unavailable" degrade.
#
# Assertion style note: this suite deliberately avoids bash's `[[ ... ]]` for
# substring/prefix checks. On macOS's system `/bin/bash` (3.2, the default
# `bash` bats-core resolves to on this class of machine), a failing `[[ ... ]]`
# inside a bats @test body does NOT fail the test -- verified directly: a bare
# `[[ "$output" == *'absent'* ]]` for a pattern that is NOT present still
# reports "ok". `[ ... ]`, `grep`, and an explicit `return 1` all fail
# correctly in the same environment, so this file uses only those.
#
# Fixtures:
#   fixtures/token-tally/multimodel/projects (session fixturemultimodel0001,
#     REUSED from task-write-attribution's suite) -- claude-opus-4-8 and
#     claude-sonnet-4-6 with distinct non-zero buckets, a real
#     ephemeral_5m/ephemeral_1h split, and a <synthetic> zero-usage line.
#     Hand-computed by_model (see token-tally.bats for the full derivation):
#       claude-opus-4-8:   fresh=300 cache_write_5m=40  cache_write_1h=360 cache_read=3000 output=30
#       claude-sonnet-4-6: fresh=30  cache_write_5m=10  cache_write_1h=20  cache_read=3000 output=3
#     aggregate buckets: fresh=330 cwrite=430 cread=6000 output=33 total=6793
#     elapsed: earliest usage-bearing line 10:00:01.000Z, latest 10:01:30.000Z
#       (the all-zero <synthetic> line still carries a timestamp) -> 89s -> 1m29s
#
#   fixtures/token-cost-e2e/rates.json (AUTHORED for this suite, not the
#     token-price.bats fixture table). Rates are deliberately larger than the
#     committed/token-price rates so each model's own contribution clears the
#     cent boundary: at this fixture's tiny token counts, the real seed rates
#     (5/25, 3/15) price opus at $0.0076 and sonnet at $0.0011925, and BOTH the
#     combined total and the opus-only total round to the same $0.01 -- a
#     dropped-model schema drift would pass unnoticed. These rates keep the
#     three figures distinguishable at 2-decimal precision:
#       opus:    (300*500 + 40*500*1.25 + 360*500*2.0 + 3000*500*0.1 + 30*2500) / 1e6 = 0.76
#       sonnet:  (30*300  + 10*300*1.25 + 20*300*2.0  + 3000*300*0.1 + 3*1500)  / 1e6 = 0.11925 -> $0.12
#       combined = 0.87925 -> $0.88 (equal to neither model alone)
#     Verified once against the real chain (not just hand math) per the Phase 1
#     lesson that a silently-guarded jq pipeline can mask a wrong answer. Also
#     verified this suite actually catches a drift: renaming the writer's
#     cache_write_1h key (simulating a field-name mismatch between the two
#     halves) drops the reader's total to $0.51, which trips the regression
#     traps below.

# ---------- bash-3.2-safe assertion helpers (see note above) ----------
assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

assert_prefix() {
  case "$output" in
    "$1"*) : ;;
    *) echo "expected output to start with:" >&2; printf '%s\n' "$1" >&2; return 1 ;;
  esac
}

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TALLY="$SCRIPT_DIR/token-tally.sh"
  ROLLUP="$SCRIPT_DIR/token-rollup.sh"
  FIX_TALLY="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"
  FIX_E2E="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-cost-e2e" && pwd)"

  MULTIMODEL="$FIX_TALLY/multimodel/projects"
  RATES="$FIX_E2E/rates.json"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

@test "e2e: real token-tally.sh -> real token-rollup.sh chain agrees on FC-1 and prices a multi-model session" {
  # Step 1: write half. Produce a real ledger row against an ISOLATED ledger
  # (never the machine's real .gaia/local/telemetry/tokens.jsonl).
  run bash "$TALLY" --action execute --spec-id SPEC-E2E --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # Schema round-trip: the row the writer emitted actually carries by_model
  # with both model keys (read directly off the ledger, not re-derived).
  [ "$(jq -r '.by_model | keys | join(",")' "$LEDGER")" = "claude-opus-4-8,claude-sonnet-4-6" ]
  [ "$(jq -r '.total' "$LEDGER")" -eq 6793 ]

  # Step 2: read half. Price the real ledger row with the real reader against
  # the hermetic fixture rate table (never the committed token-rates.json).
  run bash "$ROLLUP" --spec-id SPEC-E2E --ledger "$LEDGER" --rate-table "$RATES"
  [ "$status" -eq 0 ]

  # Token lines (per-action totals, buckets, elapsed) render unchanged, as an
  # exact prefix, ahead of the dollar block.
  expected_prefix=$'Cycle cost (SPEC-E2E):\n  execute:   6,793   (elapsed 1m29s)\n  Total:     6,793   (elapsed 1m29s)\n    Fresh input:    330\n    Cache write:    430\n    Cache read:   6,000\n    Output:          33\n'
  assert_prefix "$expected_prefix"

  # The dollar block must NOT have fallen to either "unavailable" degrade form
  # -- either one would mean the reader failed to see the writer's by_model,
  # i.e. schema drift between the two halves (exactly what this suite exists
  # to catch).
  refute_contains 'unavailable (rate table unreadable)'
  refute_contains 'unavailable (records predate per-model attribution)'

  # Concrete, hand-computed dollar figure: the per-model sum, not either
  # model alone (regression traps for a dropped-model / mis-keyed bucket).
  assert_contains '    execute:   $0.88'
  assert_contains '    Total:     $0.88'
  refute_contains '$0.76'
  refute_contains '$0.12'
}
