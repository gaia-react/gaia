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

# The machine-local rate overlay. The shipped table is manifest class `owned`,
# so a local write into it is either overwritten by the next /update-gaia or
# becomes a conflict patch on every release thereafter. .gaia/local/ is
# gitignored and holds no manifest paths, so an overlay there survives a release
# untouched. It must never be registered in .gaia/manifest.json.
gaia_resolve_rate_overlay() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$toplevel" ]] && return 1
  printf '%s' "$toplevel/.gaia/local/token-rates.local.json"
}

# gaia_apply_rate_overlay <shipped_table_json> <rate_table_override>
#
# ASSIGNS TO GLOBALS, it does not print. A command substitution would run it in
# a subshell and the overlay metadata below would not survive the return, so
# every caller invokes it bare:
#
#   GAIA_EFFECTIVE_RATES      the table to price with; the shipped one verbatim
#                             whenever the overlay does not apply
#   GAIA_RATE_OVERLAY_PATH    the overlay file, only when it contributed
#   GAIA_RATE_OVERLAY_MODELS  space-separated model keys it supplied, else empty.
#                             Non-empty is the single "an overlay is active" test
#                             every other surface reads.
#
# Never fails the caller and never yields an empty table: every degrade lands on
# the shipped table, which is the one property #1089 Layer 2 states outright.
gaia_apply_rate_overlay() {
  local shipped="$1" override="${2:-}"
  local overlay_path overlay keys merged

  GAIA_EFFECTIVE_RATES="$shipped"
  GAIA_RATE_OVERLAY_PATH=""
  GAIA_RATE_OVERLAY_MODELS=""

  # An explicit --rate-table is a deliberate run against a named table, and both
  # consumers document it as a test seam. A fixture table that silently absorbs
  # whatever sits in the developer's .gaia/local is machine-dependent, so the
  # flag takes that table and nothing else.
  [[ -n "$override" ]] && return 0

  overlay_path="$(gaia_resolve_rate_overlay)" || return 0
  # Absent is the ordinary case and says nothing on stderr. Present-but-broken is
  # not: the operator hand-wrote that file expecting it to take effect, so a
  # silent ignore would strand them re-editing a file that is already being
  # skipped.
  [[ -f "$overlay_path" ]] || return 0

  if ! overlay="$(gaia_load_rate_table "$overlay_path")"; then
    printf 'token-rates: local overlay unreadable or malformed; pricing from the shipped table alone: %s\n' \
      "$overlay_path" >&2
    return 0
  fi

  # `gaia_load_rate_table` only asserts `has("models")`, so an overlay whose
  # `models` is a string, or whose model value is not a window array, gets past
  # it. Both shapes have to be REFUSED here rather than merged:
  #   - a non-object `models` raises inside jq, and swallowing that with
  #     `|| true` would drop the overlay down the same silent path an empty one
  #     takes, contradicting what this function promises two comments up.
  #   - a model whose value is not an array merges cleanly and is then announced
  #     as active while pricing nothing, which is a confidently-wrong figure
  #     wearing an "overlay is working" label.
  # One shape check covers both, and it runs before the merge so a refusal costs
  # nothing.
  if ! jq -e '(.models | type) == "object"
              and ([.models[] | type] | all(. == "array"))' >/dev/null 2>&1 <<<"$overlay"; then
    printf 'token-rates: local overlay is malformed (models must be an object of window arrays); pricing from the shipped table alone: %s\n' \
      "$overlay_path" >&2
    return 0
  fi

  keys="$(jq -r '.models | keys_unsorted | join(" ")' <<<"$overlay" 2>/dev/null || true)"
  [[ -z "$keys" ]] && return 0

  # A model key replaces that model's WHOLE window array. rate_window takes
  # `first` of an array filtered on effective_through, so the array's order is
  # load-bearing (an intro window ahead of its open-ended successor) and merging
  # windows within a model would have to re-derive it. cache_multipliers is
  # deliberately not merged: it is a global property of the pricing model that a
  # model launch does not move, and a partial override would null out siblings
  # priced_row multiplies by.
  merged="$(jq -c --argjson o "$overlay" '.models = ((.models // {}) + $o.models)' <<<"$shipped" 2>/dev/null || true)"
  if [[ -z "$merged" ]]; then
    printf 'token-rates: could not merge the local overlay; pricing from the shipped table alone: %s\n' \
      "$overlay_path" >&2
    return 0
  fi

  GAIA_EFFECTIVE_RATES="$merged"
  GAIA_RATE_OVERLAY_PATH="$overlay_path"
  GAIA_RATE_OVERLAY_MODELS="$keys"
  return 0
}

gaia_hash16() {
  local out
  if out="$(shasum -a 256 2>/dev/null)"; then :;
  elif out="$(sha256sum 2>/dev/null)"; then :;
  else return 1; fi
  out="${out%% *}"
  [[ -z "$out" ]] && return 1
  printf '%s' "${out:0:16}"
}

# The identity of the card a row was priced under, as `sha256:<16-hex>`.
#
# With no overlay active this is byte-for-byte the historical recipe, sha256 over
# the shipped file's raw bytes, so an id minted today still compares against one
# minted before the overlay existed. When the overlay DID contribute a model, its
# bytes fold in: without that, a row priced under shipped+overlay would claim the
# identity of the shipped table alone, and two rows priced under materially
# different cards would be indistinguishable. That is the same class of silent
# lie the overlay exists to remove, so the id has to move with the card.
gaia_rate_table_id() {
  local path="$1" h
  [[ -f "$path" ]] || return 1
  if [[ -n "${GAIA_RATE_OVERLAY_MODELS:-}" && -n "${GAIA_RATE_OVERLAY_PATH:-}" && -f "${GAIA_RATE_OVERLAY_PATH}" ]]; then
    h="$(cat "$path" "$GAIA_RATE_OVERLAY_PATH" | gaia_hash16)" || return 1
  else
    h="$(gaia_hash16 <"$path")" || return 1
  fi
  [[ -z "$h" ]] && return 1
  printf 'sha256:%s' "$h"
}
