#!/usr/bin/env bats
#
# Bats suite for the machine-local rate overlay (#1089 Layer 2) added to
# .gaia/scripts/token-pricing-lib.sh.
#
# Why the overlay exists: a newly released model has no rate in the shipped
# .gaia/scripts/token-rates.json until a GAIA release ships one, and in the
# interval every run prices that model's share at zero. The shipped table is
# manifest class `owned`, so a local write into it is either clobbered by the
# next /update-gaia or becomes a conflict patch on every release thereafter.
# .gaia/local/ is gitignored and holds no manifest paths, so an overlay there
# survives every release untouched.
#
# The contract these tests pin, decision by decision:
#
#   - A model key in the overlay replaces that model's WHOLE window array.
#     `rate_window` takes `first` of an array filtered on `effective_through`,
#     so the array's order is load-bearing (an intro window ahead of its
#     open-ended successor). Merging windows WITHIN a model would have to
#     re-derive that order, which is the corruption #1089 Layer 2 names.
#   - The overlay MAY override a model the shipped table already prices. A wrong
#     shipped rate produces the same confidently-wrong figure as a missing one,
#     and the overlay is the operator's only local remedy for either.
#   - `cache_multipliers` is shipped-only. It is a global property of the pricing
#     model that a model launch does not move, and a partial override would null
#     out siblings `priced_row` multiplies by.
#   - An explicit `--rate-table` BYPASSES the overlay. Both consumers document
#     the flag as a test seam, and a fixture table that silently absorbs whatever
#     sits in the developer's .gaia/local is machine-dependent.
#   - A malformed overlay fails toward the SHIPPED table, never toward an empty
#     one, and says so on stderr. The operator wrote that file by hand expecting
#     it to take effect, so a silent ignore is the wrong failure.
#   - `rate_table_id` folds the overlay's bytes in when, and only when, the
#     overlay actually contributed a model. Without that, two rows priced under
#     materially different cards carry the same identity, which is the same class
#     of silent lie the whole issue is about. With no overlay active the recipe
#     is byte-for-byte today's: sha256 of the shipped file's raw bytes.
#
# gaia_apply_rate_overlay assigns to globals instead of printing, so every call
# here is a plain call and never a command substitution: `$(...)` would run it in
# a subshell and the overlay metadata would not survive the return.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_DIR/token-pricing-lib.sh"
  ROLLUP="$SCRIPT_DIR/token-rollup.sh"

  # Tracked and non-optional. A `skip` would green the suite on a rename.
  [ -f "$LIB" ] || { echo "token-pricing-lib.sh not found: $LIB" >&2; return 1; }

  SANDBOX="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.gaia/local"
  SHIPPED="$SANDBOX/.gaia/scripts/token-rates.json"
  OVERLAY="$SANDBOX/.gaia/local/token-rates.local.json"

  # Two models, one of them carrying the two-window intro shape the real table
  # uses for claude-sonnet-5, so the whole-array replacement has an ordered array
  # to be wrong about.
  cat > "$SHIPPED" <<'JSON'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-4-8": [ { "input": 5, "output": 25 } ],
    "claude-intro-9":  [ { "input": 2, "output": 10, "effective_through": "2026-08-31" },
                         { "input": 3, "output": 15 } ]
  }
}
JSON

  # shellcheck source=/dev/null
  . "$LIB"

  # A real repo, because gaia_resolve_rate_overlay derives the overlay path from
  # `git rev-parse --show-toplevel` exactly as gaia_resolve_rate_table does.
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email "gaia-test@example.com"
  git -C "$SANDBOX" config user.name "GAIA Test"
}

# Prices one model's fresh_input through the real jq defs, so every assertion
# below goes through the same arithmetic token-tally.sh and token-rollup.sh use
# rather than re-reading the merged table's shape.
price_fresh() {
  local rates="$1" model="$2" tokens="$3" date="${4:-2026-07-28}"
  jq -rn --argjson rates "$rates" --arg m "$model" --argjson n "$tokens" --arg d "$date" \
    "$GAIA_PRICING_JQ_DEFS"'
      priced_row({ts: ($d + "T00:00:00Z"), by_model: {($m): {fresh_input: $n}}}).dollars
    '
}

load_shipped() {
  gaia_load_rate_table "$SHIPPED"
}

# ---------- 1. the gap the overlay exists to close ----------
@test "a model only the overlay knows is priced instead of silently zeroed" {
  shipped="$(load_shipped)"
  # Without the overlay the model has no window: priced_row zeroes it and names
  # it unpriced. That is the state being repaired, asserted so the fix below is
  # measured against a real gap rather than a assumed one.
  [ "$(price_fresh "$shipped" claude-brand-new-1 1000000)" = "0" ]

  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-brand-new-1 1000000)" = "7" ]
}

@test "the overlay leaves every model it does not name exactly as shipped" {
  shipped="$(load_shipped)"
  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
}

# ---------- 2. override, the settled decision ----------
@test "the overlay overrides a model the shipped table already prices" {
  shipped="$(load_shipped)"
  [ "$(price_fresh "$shipped" claude-opus-4-8 1000000)" = "5" ]

  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-opus-4-8": [ { "input": 11, "output": 55 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "11" ]
}

# ---------- 3. merge granularity: the whole window array, never within ----------
@test "a named model's whole window array is replaced, not merged window-by-window" {
  shipped="$(load_shipped)"
  # Shipped: intro 2 through 2026-08-31, then sticker 3. Both dates asserted so
  # the fixture's own two-window selection is known good before it is replaced.
  [ "$(price_fresh "$shipped" claude-intro-9 1000000 2026-08-15)" = "2" ]
  [ "$(price_fresh "$shipped" claude-intro-9 1000000 2026-09-15)" = "3" ]

  # One unconditional window. If the arrays were merged rather than replaced, the
  # shipped intro window would survive and still win inside its own date.
  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-intro-9": [ { "input": 9, "output": 45 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-intro-9 1000000 2026-08-15)" = "9" ]
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-intro-9 1000000 2026-09-15)" = "9" ]
}

@test "an overlay may itself declare a multi-window model, order intact" {
  shipped="$(load_shipped)"
  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 4, "output": 20, "effective_through": "2026-08-31" },
                                      { "input": 6, "output": 30 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-brand-new-1 1000000 2026-08-15)" = "4" ]
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-brand-new-1 1000000 2026-09-15)" = "6" ]
}

# ---------- 4. cache_multipliers is shipped-only ----------
@test "cache_multipliers in the overlay is ignored, the shipped factors still apply" {
  shipped="$(load_shipped)"
  cat > "$OVERLAY" <<'JSON'
{ "cache_multipliers": { "read": 99, "write_5m": 99, "write_1h": 99 },
  "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""

  # cache_read at the shipped 0.1 multiplier: 1,000,000 * 7 * 0.1 / 1e6 = 0.7.
  # At the overlay's 99 it would be 693.
  got="$(jq -rn --argjson rates "$GAIA_EFFECTIVE_RATES" \
    "$GAIA_PRICING_JQ_DEFS"'
      priced_row({ts: "2026-07-28T00:00:00Z",
                  by_model: {"claude-brand-new-1": {cache_read: 1000000}}}).dollars
    ')"
  [ "$got" = "0.7" ]
}

# ---------- 5. --rate-table bypasses the overlay ----------
@test "an explicit rate-table override takes that table and nothing else" {
  shipped="$(load_shipped)"
  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-opus-4-8": [ { "input": 11, "output": 55 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" "$SHIPPED"
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
  [ -z "$GAIA_RATE_OVERLAY_MODELS" ]
}

# ---------- 6. failure modes all land on the shipped table ----------
@test "a malformed overlay prices from the shipped table and says so on stderr" {
  shipped="$(load_shipped)"
  printf 'this is not json\n' > "$OVERLAY"

  cd "$SANDBOX"
  err="$BATS_TEST_TMPDIR/err.txt"
  gaia_apply_rate_overlay "$shipped" "" 2>"$err"

  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
  [ -z "$GAIA_RATE_OVERLAY_MODELS" ]
  grep -qF -- "token-rates.local.json" "$err"
}

@test "an overlay without a models key prices from the shipped table and says so" {
  shipped="$(load_shipped)"
  printf '{"cache_multipliers":{"read":9}}\n' > "$OVERLAY"

  cd "$SANDBOX"
  err="$BATS_TEST_TMPDIR/err.txt"
  gaia_apply_rate_overlay "$shipped" "" 2>"$err"

  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
  [ -z "$GAIA_RATE_OVERLAY_MODELS" ]
  grep -qF -- "token-rates.local.json" "$err"
}

@test "an empty overlay is never an empty rate table" {
  shipped="$(load_shipped)"
  : > "$OVERLAY"

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
  [ "$(jq -r '.models | keys | length' <<<"$GAIA_EFFECTIVE_RATES")" = "2" ]
}

@test "no overlay file at all is a silent no-op, not a diagnostic" {
  shipped="$(load_shipped)"
  cd "$SANDBOX"
  err="$BATS_TEST_TMPDIR/err.txt"
  gaia_apply_rate_overlay "$shipped" "" 2>"$err"

  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
  [ -z "$GAIA_RATE_OVERLAY_MODELS" ]
  [ ! -s "$err" ]
}

@test "an overlay whose models object is empty contributes nothing and is not active" {
  shipped="$(load_shipped)"
  printf '{"models":{}}\n' > "$OVERLAY"

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  [ -z "$GAIA_RATE_OVERLAY_MODELS" ]
  [ "$(price_fresh "$GAIA_EFFECTIVE_RATES" claude-opus-4-8 1000000)" = "5" ]
}

# ---------- 7. the active-model list, which Layer 3 and the release surface read ----------
@test "the active list names exactly the models the overlay supplied" {
  shipped="$(load_shipped)"
  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ],
              "claude-opus-4-8":    [ { "input": 11, "output": 55 } ] } }
JSON

  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""

  # Sorted so the assertion does not depend on the overlay's key order.
  got="$(printf '%s\n' $GAIA_RATE_OVERLAY_MODELS | sort | tr '\n' ' ')"
  [ "$got" = "claude-brand-new-1 claude-opus-4-8 " ]
  [ "$GAIA_RATE_OVERLAY_PATH" = "$OVERLAY" ]
}

# ---------- 8. rate_table_id honesty ----------
@test "rate_table_id is unchanged by an overlay that is not active" {
  shipped="$(load_shipped)"
  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""

  # The pre-overlay recipe, asserted directly rather than through the helper, so
  # a change to the helper cannot quietly redefine what it is being compared to.
  want="sha256:$(shasum -a 256 < "$SHIPPED" | cut -c1-16)"
  [ "$(gaia_rate_table_id "$SHIPPED")" = "$want" ]
}

@test "rate_table_id changes once the overlay actually prices a model" {
  shipped="$(load_shipped)"
  cd "$SANDBOX"
  gaia_apply_rate_overlay "$shipped" ""
  bare="$(gaia_rate_table_id "$SHIPPED")"

  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ] } }
JSON
  gaia_apply_rate_overlay "$shipped" ""
  overlaid="$(gaia_rate_table_id "$SHIPPED")"

  [ "$bare" != "$overlaid" ]
  case "$overlaid" in sha256:*) : ;; *) echo "bad shape: $overlaid" >&2; return 1 ;; esac
}

@test "editing the overlay moves rate_table_id, so two cards never share an identity" {
  shipped="$(load_shipped)"
  cd "$SANDBOX"

  printf '{"models":{"claude-brand-new-1":[{"input":7,"output":35}]}}\n' > "$OVERLAY"
  gaia_apply_rate_overlay "$shipped" ""
  first="$(gaia_rate_table_id "$SHIPPED")"

  printf '{"models":{"claude-brand-new-1":[{"input":8,"output":40}]}}\n' > "$OVERLAY"
  gaia_apply_rate_overlay "$shipped" ""
  second="$(gaia_rate_table_id "$SHIPPED")"

  [ "$first" != "$second" ]
}

# ---------- 9. end to end, through a real consumer ----------
@test "token-rollup prices a model only the overlay knows" {
  [ -f "$ROLLUP" ] || { echo "token-rollup.sh not found: $ROLLUP" >&2; return 1; }

  ledger="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$ledger")"
  jq -c -n '{schema_version:1, kind:"execute", spec_id:"SPEC-900", session_id:"s1",
             by_model:{"claude-brand-new-1":{fresh_input:1000000}},
             total:1000000, ts:"2026-07-28T07:28:15Z", final:true}' > "$ledger"

  cat > "$OVERLAY" <<'JSON'
{ "models": { "claude-brand-new-1": [ { "input": 7, "output": 35 } ] } }
JSON

  # No --rate-table: the resolver must find the sandbox's shipped table AND its
  # overlay from cwd, which is the whole path an operator actually runs.
  cd "$SANDBOX"
  run bash "$ROLLUP" --spec-id SPEC-900 --ledger "$ledger"
  [ "$status" -eq 0 ]
  grep -qF -- '$7.00' <<<"$output"
  grep -qF -- "unpriced model(s)" <<<"$output" && return 1
  true
}
