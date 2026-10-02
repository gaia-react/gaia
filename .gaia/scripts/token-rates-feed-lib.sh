# shellcheck shell=bash
# GAIA rate-table heal: fetch the public distributed table once when the local
# table lacks a model the run priced.
#
# gaia_rates_heal <models_json> runs only in local mode (gaia_rates_prepare),
# and only when a `claude-*` id in <models_json> is absent from the local table.
# It makes at most one request per process, bounded (2 s connect, 4 s total,
# 256 KiB), then adds each valid row for an absent model, marked "source":
# "feed", to the local table and the base beside it. Returns 0 when it rewrote
# the local table (the caller reloads and reprices), 1 otherwise. Never exits,
# writes nothing to stdout, changes no shell option; call it in the caller's own
# shell, not inside $(...), because it keeps per-process state.
#
# What a request discloses: the caller's IP, curl's default User-Agent, and the
# time. It says that a lookup missed, never which model: the URL carries no
# query string and there are no custom headers.
#
# GAIA_RATES_FEED_DISABLE=1 (exactly 1) turns every request off.
# GAIA_RATES_FEED_URL overrides the URL; only https:// and file:// are accepted.
#
# The path inside GAIA_RATES_FEED_DEFAULT_URL is a public contract: it must name
# a file tracked on main, and a test fails when the two drift apart. Moving the
# distributed table without moving the constant strands every adopter's heal.
#
# Feed content is untrusted. It reaches jq only through --slurpfile/--argjson,
# and a model key is checked against ^claude-[a-z0-9.-]+$ before any use,
# including in messages.
#
# Backoff and bounds. One failed fetch backs off for an hour (failed_at in the
# feed state file) so a machine without network pays the 4 s ceiling once an
# hour, not once per hook run. A model the feed does not price is remembered for
# an hour (not_found) so a preview id absent from GAIA's table does not refetch
# on every run.
#
# Portability: macOS bash 3.2 and BSD tools as well as Linux GNU: epoch
# integers from $(date +%s), temp files in the target's own directory, wc -c
# for the size cap.

GAIA_RATES_FEED_DEFAULT_URL='https://raw.githubusercontent.com/gaia-react/gaia/main/.gaia/scripts/token-rates.json'
GAIA_RATES_FEED_STATE_NAME='token-rates.feed-state.json'
GAIA_RATES_FEED_BODY_PREFIX='.token-rates.feed-body.tmp'
GAIA_RATES_FEED_BACKOFF_SECONDS=3600
GAIA_RATES_FEED_MAXIMUM_BYTES=262144

_GAIA_RATES_FEED_TRIED=0
_GAIA_RATES_FEED_WARNED=0

# One `token-pricing:` feed line per process, whichever path prints it.
_gaia_rates_feed_warn() {
  if [[ "$_GAIA_RATES_FEED_WARNED" == "1" ]]; then
    return 0
  fi
  _GAIA_RATES_FEED_WARNED=1
  printf 'token-pricing: %s\n' "$1" >&2
}

# Prints the feed state as compact JSON, normalised; an unreadable file is the
# empty state.
_gaia_rates_feed_state() {
  local path="$1" normalized_state=""
  if [[ -s "$path" ]]; then
    normalized_state="$(jq -c '
      if type == "object" then
        { failed_at: (if (.failed_at | type) == "number" then .failed_at else null end),
          not_found: (if (.not_found | type) == "object"
                      then (.not_found | with_entries(select(.value | type == "number")))
                      else {} end) }
      else empty end' "$path" 2>/dev/null)" || normalized_state=""
  fi
  [[ -n "$normalized_state" ]] || normalized_state='{"failed_at":null,"not_found":{}}'
  printf '%s' "$normalized_state"
}

# Record a failed fetch: failed_at = now, keep the fresh not_found entries.
_gaia_rates_feed_record_failure() {
  local state_file="$1" state="$2" now="$3" message="$4" updated_state
  updated_state="$(jq -c --argjson now "$now" --argjson backoff_seconds "$GAIA_RATES_FEED_BACKOFF_SECONDS" '
    .failed_at = $now
    | .not_found |= with_entries(select(($now - .value) >= 0 and ($now - .value) < $backoff_seconds))' \
    <<<"$state" 2>/dev/null)" || updated_state=""
  [[ -n "$updated_state" ]] && _gaia_rates_write_json "$state_file" "$updated_state" >/dev/null 2>&1
  _gaia_rates_feed_warn "$message"
  return 0
}

# Prints the feed's candidate rows that pass validation, marked, as one object
# keyed by model. Row validation lives in this jq program only.
# shellcheck disable=SC2016 # a jq program: the $ names are jq variables
_GAIA_RATES_FEED_JQ_VALID='
  def valid_row($today):
    type == "array" and length > 0
    and all(.[];
      type == "object"
      and ((keys - ["input", "output", "effective_through", "cache_read_multiplier"]) | length) == 0
      and (.input | type) == "number" and (.output | type) == "number"
      and (.input | isinfinite | not) and (.output | isinfinite | not)
      and .input >= 0 and .output >= 0
      and ((has("cache_read_multiplier") | not)
           or ((.cache_read_multiplier | type) == "number"
               and (.cache_read_multiplier | isinfinite | not)
               and .cache_read_multiplier >= 0 and .cache_read_multiplier <= 1))
      and ((has("effective_through") | not)
           or ((.effective_through | type) == "string"
               and (.effective_through | test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z"))))
    )
    and any(.[]; (has("effective_through") | not) or .effective_through >= $today);
  def valid_feed_rows($today):
    (.models // {})
    | with_entries(select((.key | test("\\Aclaude-[a-z0-9.-]+\\z")) and (.value | valid_row($today))))
    | map_values(map(. + {source: "feed"}));
'

# Feed fetch and apply. Args: <body_tmp> <url> <protocol> <absent_json> <state_json> <now>.
_gaia_rates_feed_run() {
  local body="$1" url="$2" protocol="$3" absent="$4" state="$5" now="$6"
  local table="$GAIA_RATES_TABLE" directory="$GAIA_RATES_DIRECTORY"
  local base="$directory/$GAIA_RATES_BASE_NAME" state_file="$directory/$GAIA_RATES_FEED_STATE_NAME"
  local size today plan base_json new_state changed exit_status=1

  if ! curl -q -fsS --proto "=$protocol" --connect-timeout 2 --max-time 4 \
    --max-filesize "$GAIA_RATES_FEED_MAXIMUM_BYTES" "$url" >"$body" 2>/dev/null; then
    _gaia_rates_feed_record_failure "$state_file" "$state" "$now" \
      "rates feed unavailable; pricing from the local table (retry in 1 h)"
    return 1
  fi
  size="$(wc -c <"$body" 2>/dev/null)" || size=0
  if [[ $((size + 0)) -gt $GAIA_RATES_FEED_MAXIMUM_BYTES ]] \
    || ! jq -e -s 'length == 1 and (.[0] | type == "object" and (.models | type) == "object")' \
      "$body" >/dev/null 2>&1; then
    _gaia_rates_feed_record_failure "$state_file" "$state" "$now" \
      "rates feed response rejected; pricing from the local table (retry in 1 h)"
    return 1
  fi

  today="$(date -u +%Y-%m-%d)"
  base_json='{"models":{}}'
  if _gaia_rates_table_readable "$base"; then
    base_json="$(jq -c . "$base" 2>/dev/null)" || base_json='{"models":{}}'
  fi
  plan="$(jq -n -c --slurpfile feed "$body" --slurpfile local_table "$table" \
    --argjson base "$base_json" --argjson absent "$absent" --arg today "$today" \
    "$_GAIA_RATES_FEED_JQ_VALID"'
    ($feed[0] | valid_feed_rows($today)) as $valid
    | $local_table[0] as $local_document
    | ($absent | map(select($valid[.] != null))) as $add
    | ($absent - $add) as $not_found_models
    | [ ($local_document.models // {}) | to_entries[]
        | select((.value | type) == "array" and (.value | length) > 0
                 and (.value | all(.[]; type == "object" and .source == "feed"))
                 and ($base.models[.key]? != null) and .value == $base.models[.key]
                 and $valid[.key] != null and $valid[.key] != .value)
        | .key ] as $refresh
    | ($add + $refresh) as $changes
    | ($changes | map({key: ., value: $valid[.]}) | from_entries) as $rows
    | { changed: ($changes | length > 0),
        add: $add,
        notfound: $not_found_models,
        local: ($local_document | .models = ((.models // {}) + $rows)),
        base: ($base | .models = ((.models // {}) + $rows)) }' 2>/dev/null)" || plan=""
  if [[ -z "$plan" ]]; then
    _gaia_rates_feed_record_failure "$state_file" "$state" "$now" \
      "rates feed response rejected; pricing from the local table (retry in 1 h)"
    return 1
  fi

  new_state="$(jq -n -c --argjson state "$state" --argjson plan "$plan" --argjson now "$now" \
    --argjson backoff_seconds "$GAIA_RATES_FEED_BACKOFF_SECONDS" '
    { failed_at: null,
      not_found: (($state.not_found
                   | with_entries(select(($now - .value) >= 0 and ($now - .value) < $backoff_seconds
                                         and ((.key as $model_key | $plan.add | index($model_key)) == null))))
                  + ($plan.notfound | map({key: ., value: $now}) | from_entries)) }' 2>/dev/null)" || new_state=""

  changed="$(jq -r '.changed' <<<"$plan" 2>/dev/null)"
  if [[ "$changed" == "true" ]]; then
    if _gaia_rates_write_json "$table" "$(jq -c '.local' <<<"$plan")" >/dev/null 2>&1; then
      exit_status=0
      _gaia_rates_write_json "$base" "$(jq -c '.base' <<<"$plan")" >/dev/null 2>&1 || true
    else
      _gaia_rates_feed_record_failure "$state_file" "$state" "$now" \
        "rates feed row could not be written; pricing from the local table (retry in 1 h)"
      return 1
    fi
  fi
  [[ -n "$new_state" ]] && _gaia_rates_write_json "$state_file" "$new_state" >/dev/null 2>&1
  return "$exit_status"
}

# gaia_rates_heal <models_json>: heal absent claude-* models from the feed.
gaia_rates_heal() {
  local models_json="${1:-[]}" table directory absent state_file state now url protocol scheme temporary_file exit_status

  # 1. Only the machine-local table is ever written.
  [[ "${GAIA_RATES_MODE:-}" == "local" ]] || return 1
  table="${GAIA_RATES_TABLE:-}"
  directory="${GAIA_RATES_DIRECTORY:-}"
  [[ -n "$table" && -f "$table" && -n "$directory" && -d "$directory" ]] || return 1
  declare -F _gaia_rates_write_json >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # 2. A present row (even an expired one) is not absent.
  absent="$(jq -n -c --argjson ids "$models_json" --slurpfile local_table "$table" '
    [ $ids[] | strings | select(test("\\Aclaude-[a-z0-9.-]+\\z"))
      | select(. as $model | ((($local_table[0].models // {}) | has($model)) | not)) ] | unique' 2>/dev/null)" || return 1
  [[ -n "$absent" && "$absent" != "[]" ]] || return 1

  # 3. Opt-out: exactly 1.
  [[ "${GAIA_RATES_FEED_DISABLE:-}" == "1" ]] && return 1

  # 4. One attempt per process.
  [[ "$_GAIA_RATES_FEED_TRIED" == "1" ]] && return 1

  # 5. Scheme.
  url="${GAIA_RATES_FEED_URL:-$GAIA_RATES_FEED_DEFAULT_URL}"
  case "$url" in
    https://*) protocol="https" ;;
    file://*) protocol="file" ;;
    *)
      _GAIA_RATES_FEED_TRIED=1
      scheme="$(printf '%s' "${url%%:*}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9+.-' | cut -c1-32)"
      [[ "$url" == *:* ]] || scheme="none"
      _gaia_rates_feed_warn "rates feed URL scheme '$scheme' not accepted; only https and file are"
      return 1
      ;;
  esac

  # 6. No curl.
  if ! command -v curl >/dev/null 2>&1; then
    _GAIA_RATES_FEED_TRIED=1
    _gaia_rates_feed_warn "curl not found; rates feed skipped"
    return 1
  fi

  now="$(date +%s)"
  state_file="$directory/$GAIA_RATES_FEED_STATE_NAME"
  state="$(_gaia_rates_feed_state "$state_file")"

  # 7. Backoff after a failure, 8. every absent model recently unpriced by the feed.
  if jq -e -n --argjson state "$state" --argjson now "$now" --argjson backoff_seconds "$GAIA_RATES_FEED_BACKOFF_SECONDS" \
    '$state.failed_at != null and ($now - $state.failed_at) >= 0 and ($now - $state.failed_at) < $backoff_seconds' >/dev/null 2>&1; then
    return 1
  fi
  if jq -e -n --argjson state "$state" --argjson now "$now" --argjson backoff_seconds "$GAIA_RATES_FEED_BACKOFF_SECONDS" \
    --argjson absent_models "$absent" '
    $absent_models | all(.[]; . as $model | ($state.not_found[$model]) as $not_found_at
                  | $not_found_at != null and ($now - $not_found_at) >= 0 and ($now - $not_found_at) < $backoff_seconds)' >/dev/null 2>&1; then
    return 1
  fi

  # 9. Fetch.
  _GAIA_RATES_FEED_TRIED=1
  temporary_file="$(mktemp "$directory/$GAIA_RATES_FEED_BODY_PREFIX.XXXXXX" 2>/dev/null)" || return 1
  _gaia_rates_feed_run "$temporary_file" "$url" "$protocol" "$absent" "$state" "$now"
  exit_status=$?
  rm -f "$temporary_file" 2>/dev/null
  return "$exit_status"
}
