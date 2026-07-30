#!/usr/bin/env bats
#
# Bats suite for the SHIPPED rate table, .gaia/scripts/token-rates.json.
#
# Every other pricing suite (token-price.bats, token-tally-price.bats) drives
# the arithmetic through AUTHORED fixture tables, so none of them notices when
# the shipped table is missing a row for a model GAIA actually runs. That gap
# is the whole of #1088: an absent key makes `rate_window` yield null,
# `priced_row` maps a null window to 0, and the row still returns well-formed,
# so a run priced at zero is indistinguishable from a run that cost nothing.
#
# This suite asserts coverage of the shipped table itself. A model added to the
# fleet gets a row here at the same time it gets a row in the table.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md -- `[ ... ]`
# and `jq -e` (own exit code) for every non-final assertion, never a bare
# `[[ ... ]]`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TABLE="$SCRIPT_DIR/token-rates.json"
  PRICING_LIB="$SCRIPT_DIR/token-pricing-lib.sh"

  [ -f "$TABLE" ] || skip "shipped rate table not found: $TABLE"
  # shellcheck source=.gaia/scripts/token-pricing-lib.sh
  . "$PRICING_LIB"
}

# rate_for <model> <date> -> "<input> <output>" via the REAL rate_window, so a
# row that exists but is malformed (wrong nesting, string rates) fails here
# exactly as it would in token-tally.sh, rather than passing a shallow has-key
# check.
rate_for() {
  jq -r --arg m "$1" --arg d "$2" --slurpfile t "$TABLE" \
    '$t[0] as $rates | '"$GAIA_PRICING_JQ_DEFS"'
     rate_window($m; $d) | if . == null then "NULL" else "\(.input) \(.output)" end' \
    <<<'null' 2>/dev/null
}

@test "shipped table: the fleet's live model keys all resolve to a rate window" {
  # Every model key that has appeared in a real ledger. An absent row here is
  # the #1088 failure: silently priced at zero.
  for m in claude-opus-5 claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001; do
    got="$(rate_for "$m" 2026-07-30)"
    [ "$got" != "NULL" ] || { echo "no rate window for $m" >&2; return 1; }
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

@test "shipped table: claude-mythos-5 prices at 10/50, the fable-5 tier" {
  [ "$(rate_for claude-mythos-5 2026-07-30)" = "10 50" ]
  [ "$(rate_for claude-mythos-5 2026-07-30)" = "$(rate_for claude-fable-5 2026-07-30)" ]
}

@test "shipped table: claude-sonnet-5 keeps its two-window intro pricing" {
  # Verified against two Sonnet-5-only ledger records; #1088 must not disturb it.
  [ "$(rate_for claude-sonnet-5 2026-07-30)" = "2 10" ]
  [ "$(rate_for claude-sonnet-5 2026-09-01)" = "3 15" ]
}

@test "shipped table: cache multipliers are the documented read/write factors" {
  jq -e '.cache_multipliers
         | .read == 0.1 and .write_5m == 1.25 and .write_1h == 2.0' "$TABLE" >/dev/null
}
