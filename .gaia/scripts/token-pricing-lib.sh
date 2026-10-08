# shellcheck shell=bash
# GAIA shared dollar-pricing lib (single-sourced).
# Sourced by usage.sh, token-rollup.sh and token-tally.sh. Defines the
# rate_window / priced_row jq definitions and the rate-table helpers. No side
# effects at source time; defines functions + one jq-defs variable.
#
# gaia_rates_load is the usage readout path. It reads the distributed
# token-rates.json (beside this file) and overlays the optional
# <main>/.gaia/local/telemetry/token-rates.override.json row by row: each
# override .models[<id>] replaces that model's distributed row. It opens no
# network connection and writes nothing.
#
# gaia_resolve_rate_table, gaia_hash16 and gaia_rate_table_id serve the tally
# scripts (token-tally.sh, token-rollup.sh), which call them. This file also
# sources token-rates-local-lib.sh and token-rates-feed-lib.sh from its own
# directory for those scripts, silently when either is absent.

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

# gaia_rates_override_status <main_root>: prints `none` (no override file),
# `applied` (valid JSON whose .models is an object) or `unparseable`.
gaia_rates_override_status() {
  local override_file="${1:-}/.gaia/local/telemetry/token-rates.override.json"
  if [[ -z "${1:-}" || ! -f "$override_file" ]]; then
    printf 'none'
  elif jq -e 'type=="object" and (.models|type)=="object"' "$override_file" >/dev/null 2>&1; then
    printf 'applied'
  else
    printf 'unparseable'
  fi
}

# gaia_rates_load <main_root> [<table_path>]: sets GAIA_RATES_JSON to the
# distributed table with the override overlaid, or null when the distributed
# table is unreadable, and GAIA_RATES_OVERRIDE_STATUS to none|applied|unparseable.
# Always returns 0. Call it in the caller's shell, not in $(...), which would
# discard the variables.
# shellcheck disable=SC2034 # both variables are read by the caller
gaia_rates_load() {
  local main_root="${1:-}" table_path="${2:-}" distributed merged
  GAIA_RATES_JSON=null
  GAIA_RATES_OVERRIDE_STATUS=none
  if [[ -z "$table_path" ]]; then
    table_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token-rates.json"
  fi
  distributed="$(gaia_load_rate_table "$table_path")" || return 0
  GAIA_RATES_JSON="$distributed"
  GAIA_RATES_OVERRIDE_STATUS="$(gaia_rates_override_status "$main_root")"
  [[ "$GAIA_RATES_OVERRIDE_STATUS" == applied ]] || return 0
  if merged="$(jq -c --slurpfile override "$main_root/.gaia/local/telemetry/token-rates.override.json" \
    '.models = (.models + $override[0].models)' <<<"$distributed" 2>/dev/null)" && [[ -n "$merged" ]]; then
    GAIA_RATES_JSON="$merged"
  else
    GAIA_RATES_OVERRIDE_STATUS=unparseable
  fi
  return 0
}
