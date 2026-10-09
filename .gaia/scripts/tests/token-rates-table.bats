#!/usr/bin/env bats
#
# Bats suite for the SHIPPED rate table, .gaia/scripts/token-rates.json.
#
# Every other pricing suite drives the arithmetic through AUTHORED fixture
# tables, so none of them notices when
# the shipped table is missing a row for a model GAIA actually runs. That gap
# is the whole of #1088: an absent key makes `rate_window` yield null,
# `priced_row` maps a null window to 0, and the row still returns well-formed,
# so a run priced at zero is indistinguishable from a run that cost nothing.
#
# This suite asserts coverage of the shipped table itself. A model added to the
# fleet gets a row here at the same time it gets a row in the table.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. Uses `jq -e`
# (own exit code) for every non-final JSON assertion.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TABLE="$SCRIPT_DIRECTORY/token-rates.json"
  PRICING_LIBRARY="$SCRIPT_DIRECTORY/token-pricing-lib.sh"

  # Both files are tracked and non-optional, and this suite is release-excluded
  # so it only ever runs where they exist. A `skip` here would green the shipped
  # table's ONLY coverage on a future rename instead of reddening it.
  [ -f "$TABLE" ] || { echo "shipped rate table not found: $TABLE" >&2; return 1; }
  [ -f "$PRICING_LIBRARY" ] || { echo "pricing lib not found: $PRICING_LIBRARY" >&2; return 1; }
  # shellcheck source=.gaia/scripts/token-pricing-lib.sh
  . "$PRICING_LIBRARY"
}

# rate_for <model> <date> -> "<input> <output>" via the REAL rate_window, so a
# row whose window is nested wrongly fails here exactly as it would in a
# readout, rather than passing a shallow has-key check.
#
# It does NOT catch a string-typed rate: jq renders "\(.input)" identically for
# `5` and `"5"`, so every equality assertion below passes either way. The rate
# types are asserted directly in their own test instead. That gap matters because
# a quoted rate does not degrade one model, it makes `priced_row` yield null for
# every run against the table, which reads as `cost unavailable` everywhere.
rate_for() {
  jq -r --arg model "$1" --arg date "$2" --slurpfile table "$TABLE" \
    '$table[0] as $rates | '"$GAIA_PRICING_JQ_DEFS"'
     rate_window($model; $date) | if . == null then "NULL" else "\(.input) \(.output)" end' \
    <<<'null' 2>/dev/null
}

@test "shipped table: the fleet's live model keys all resolve to a rate window" {
  # Every model key that has appeared in a real ledger. An absent row here is
  # the #1088 failure: silently priced at zero.
  for model in claude-opus-5-5 claude-opus-5 claude-opus-4-8 claude-sonnet-5-5 claude-sonnet-5 \
           claude-fable-5-1 claude-haiku-4-5-20251001; do
    got="$(rate_for "$model" 2026-07-30)"
    [ "$got" != "NULL" ] || { echo "no rate window for $model" >&2; return 1; }
  done
}

@test "shipped table: claude-opus-5 prices at 5/25 with one unconditional window" {
  [ "$(rate_for claude-opus-5 2026-07-30)" = "5 25" ]

  # Opus 5's 1M context carries no long-context premium, so a single window with
  # no effective_through is correct: the same rate must resolve at any date.
  [ "$(rate_for claude-opus-5 2020-01-01)" = "5 25" ]
  [ "$(jq -r '.models["claude-opus-5"] | length' "$TABLE")" -eq 1 ]

  jq -e '.models["claude-opus-5"][0] | has("effective_through") | not' "$TABLE" >/dev/null
}

@test "shipped table: claude-opus-5-5 prices at 4/20 with one unconditional window" {
  [ "$(rate_for claude-opus-5-5 2026-09-29)" = "4 20" ]
  [ "$(rate_for claude-opus-5-5 2020-01-01)" = "4 20" ]
  [ "$(jq -r '.models["claude-opus-5-5"] | length' "$TABLE")" -eq 1 ]
}

@test "shipped table: claude-mythos-5 prices at 10/50, the fable-5 tier" {
  [ "$(rate_for claude-mythos-5 2026-07-30)" = "10 50" ]
  [ "$(rate_for claude-mythos-5 2026-07-30)" = "$(rate_for claude-fable-5 2026-07-30)" ]
}

@test "shipped table: claude-sonnet-5 prices at 2/10 with one unconditional window" {
  # Launched at 2/10 as intro pricing through 2026-08-31; the scheduled rise to
  # 3/15 was cancelled and 2/10 became the standard price, so a dated second
  # window would overcharge every run after that date.
  [ "$(rate_for claude-sonnet-5 2026-07-30)" = "2 10" ]
  [ "$(rate_for claude-sonnet-5 2026-09-01)" = "2 10" ]
  [ "$(jq -r '.models["claude-sonnet-5"] | length' "$TABLE")" -eq 1 ]
}

@test "shipped table: claude-sonnet-5-5 prices at 2/10 with one unconditional window" {
  [ "$(rate_for claude-sonnet-5-5 2026-09-30)" = "2 10" ]
  [ "$(rate_for claude-sonnet-5-5 2020-01-01)" = "2 10" ]
  [ "$(jq -r '.models["claude-sonnet-5-5"] | length' "$TABLE")" -eq 1 ]
}

@test "shipped table: claude-fable-5-1 and claude-mythos-5-1 price at 10/50" {
  [ "$(rate_for claude-fable-5-1 2026-09-30)" = "10 50" ]
  [ "$(rate_for claude-mythos-5-1 2026-09-30)" = "10 50" ]
}

# price_cache_read <model> <tokens> -> dollars for a cache_read-only row, through
# the REAL priced_row, so a per-window cache-read multiplier the lib ignores
# fails here rather than passing a has-key check on the table.
price_cache_read() {
  jq -r --arg model "$1" --argjson token_count "$2" --slurpfile table "$TABLE" \
    '$table[0] as $rates | '"$GAIA_PRICING_JQ_DEFS"'
     priced_row({ts: "2026-09-30T00:00:00Z", by_model: {($model): {cache_read: $token_count}}}) | .dollars' \
    <<<'null' 2>/dev/null
}

@test "shipped table: cache reads use the per-window multiplier where the price card sets one" {
  # 1M cache-read tokens. The published card prices these cache hits below the
  # global 0.1x: Opus 5.5 at 0.05x of $4, Fable 5.1 and Mythos 5.1 at 0.025x of $10.
  [ "$(price_cache_read claude-opus-5-5 1000000)" = "0.2" ]
  [ "$(price_cache_read claude-fable-5-1 1000000)" = "0.25" ]
  [ "$(price_cache_read claude-mythos-5-1 1000000)" = "0.25" ]
}

@test "shipped table: cache reads fall back to the global multiplier without an override" {
  # Sonnet 5.5 and Fable 5 carry no override: 0.1x of $2 and of $10.
  [ "$(price_cache_read claude-sonnet-5-5 1000000)" = "0.2" ]
  [ "$(price_cache_read claude-fable-5 1000000)" = "1" ]
}

@test "shipped table: the model key set is exactly this, and every window array is non-empty" {
  # As a SET, not a roll call: the per-model tests name only some keys, so
  # deleting any of the others passed every test. Adding a model to the table
  # now fails here until it is acknowledged, which is the point of a suite whose
  # job is guarding the shipped table.
  jq -e '.models | keys == [
           "claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5",
           "claude-haiku-4-5-20251001", "claude-mythos-5", "claude-mythos-5-1",
           "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
           "claude-opus-5", "claude-opus-5-5", "claude-sonnet-4-6",
           "claude-sonnet-5", "claude-sonnet-5-5"
         ]' "$TABLE" >/dev/null

  # A window array emptied to [] makes rate_window yield null, which prices that
  # model at zero: the #1088 failure with the key still present. The type test
  # below iterates `.value[]`, so an empty array is vacuously true there.
  jq -e '.models | to_entries
         | all(.value | type == "array" and length > 0)' "$TABLE" >/dev/null
}

@test "shipped table: every rate is numeric, not a quoted number" {
  # The one malformation rate_for is blind to, and the most damaging: a quoted
  # rate makes every arithmetic branch in priced_row fail, so the table prices
  # NOTHING and every surface reports `cost unavailable`. The table is
  # hand-edited, which is exactly how a stray quote gets in.
  jq -e '.models | to_entries
         | all(.value[] | (.input | type) == "number" and (.output | type) == "number")' \
    "$TABLE" >/dev/null

  # The optional per-window cache-read override fails the same way: quoted, it
  # makes priced_row null for every row priced under that window.
  jq -e '.models | to_entries
         | all(.value[] | (has("cache_read_multiplier") | not)
                          or (.cache_read_multiplier | type) == "number")' \
    "$TABLE" >/dev/null
}

@test "shipped table: cache multipliers are the documented read/write factors" {
  jq -e '.cache_multipliers
         | .read == 0.1 and .write_5m == 1.25 and .write_1h == 2.0' "$TABLE" >/dev/null
}
