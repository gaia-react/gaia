# shellcheck shell=bash
# GAIA shared dollar-pricing lib (SPEC-019 arithmetic, single-sourced).
# Sourced by token-rollup.sh and token-tally.sh. Defines the rate-table
# resolution/load helpers and the rate_window / priced_row jq definitions.
# No side effects at source time; defines functions + one jq-defs variable.

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
              . as $e
              | rate_window($e.key; $date) as $w
              | { model: $e.key, w: $w, b: $e.value }
            )
          ) as $priced
          | {
              dollars: ( $priced | map(
                  if .w == null then 0
                  else
                    ( (.b.fresh_input // 0) * .w.input
                    + (.b.cache_write_5m // 0) * .w.input * $rates.cache_multipliers.write_5m
                    + (.b.cache_write_1h // 0) * .w.input * $rates.cache_multipliers.write_1h
                    + (.b.cache_read // 0) * .w.input * $rates.cache_multipliers.read
                    + (.b.output // 0) * .w.output
                    ) / 1000000
                  end
                ) | add // 0 ),
              missing_anchor: false,
              unpriced: ( $priced | map(select(.w == null) | .model) )
            }
        end;
JQDEFS
)"

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
