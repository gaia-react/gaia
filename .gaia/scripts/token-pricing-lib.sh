# shellcheck shell=bash
# GAIA shared dollar-pricing lib (single-sourced).
# Sourced by token-rollup.sh and token-tally.sh. Defines the rate-table
# resolution/load helpers and the rate_window / priced_row jq definitions.
# No side effects at source time; defines functions + one jq-defs variable.
# Also sources token-rates-local-lib.sh and token-rates-feed-lib.sh from its own
# directory, silently when either is absent (a partial update).

_gaia_pricing_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_gaia_pricing_directory/token-rates-local-lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$_gaia_pricing_directory/token-rates-feed-lib.sh" 2>/dev/null || true
unset _gaia_pricing_directory

# shellcheck disable=SC2034 # consumed by sourcing scripts (token-rollup.sh, token-tally.sh)
GAIA_PRICING_JQ_DEFS="$(cat <<'JQDEFS'
    def rate_window($model; $date):
      ($rates.models[$model] // [])
      | map(select(.effective_through == null or ($date != "" and $date <= .effective_through)))
      | first;

    # Prices one winning row. A null/empty ts short-circuits BEFORE window
    # selection: the whole row contributes zero and is flagged missing_anchor,
    # never falling through to the sticker window.
    def priced_row($row):
      ($row.ts // "")[0:10] as $date
      | ($row.by_model // {} | to_entries | map(select(.key | test("^claude-")))) as $entries
      | if $date == "" then
          { dollars: 0, missing_anchor: true, unpriced: [] }
        else
          ( $entries | map(
              . as $model_entry
              | rate_window($model_entry.key; $date) as $window
              | { model: $model_entry.key, window: $window, token_buckets: $model_entry.value }
            )
          ) as $priced
          | {
              dollars: ( $priced | map(
                  if .window == null then 0
                  else
                    ( (.token_buckets.fresh_input // 0) * .window.input
                    + (.token_buckets.cache_write_5m // 0) * .window.input * $rates.cache_multipliers.write_5m
                    + (.token_buckets.cache_write_1h // 0) * .window.input * $rates.cache_multipliers.write_1h
                    + (.token_buckets.cache_read // 0) * .window.input * (.window.cache_read_multiplier // $rates.cache_multipliers.read)
                    + (.token_buckets.output // 0) * .window.output
                    ) / 1000000
                  end
                ) | add // 0 ),
              missing_anchor: false,
              unpriced: ( $priced | map(select(.window == null) | .model) )
            }
        end;
JQDEFS
)"

# Partial-update fallback only: used when gaia_rates_prepare is undefined (the
# new libs are absent). It resolves via git rev-parse --show-toplevel because it
# predates the local table; it is not the primary resolution path.
gaia_resolve_rate_table() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$toplevel" ]] && return 1
  printf '%s' "$toplevel/.gaia/scripts/token-rates.json"
}

gaia_load_rate_table() {
  local path="${1:-}"
  local contents
  contents="$(cat "$path" 2>/dev/null)"
  if [[ -n "$contents" ]] && jq -e 'type=="object" and has("models")' >/dev/null 2>&1 <<<"$contents"; then
    printf '%s' "$contents"
    return 0
  fi
  return 1
}

gaia_hash16() {
  local digest
  if digest="$(shasum -a 256 2>/dev/null)"; then :;
  elif digest="$(sha256sum 2>/dev/null)"; then :;
  else return 1; fi
  digest="${digest%% *}"
  [[ -z "$digest" ]] && return 1
  printf '%s' "${digest:0:16}"
}

# The identity of the card a row was priced under, as `sha256:<16-hex>`: sha256
# over the raw bytes of the table that priced, truncated to 16 hex characters.
gaia_rate_table_id() {
  local path="$1" table_hash
  [[ -f "$path" ]] || return 1
  table_hash="$(gaia_hash16 <"$path")" || return 1
  [[ -z "$table_hash" ]] && return 1
  printf 'sha256:%s' "$table_hash"
}
