#!/usr/bin/env bash
# GAIA token roll-up reader.
#
# Reads the durable ledger token-tally.sh appends to
# (.gaia/local/telemetry/cost.jsonl) and renders a full-cycle cost readout
# for one feature: spec / plan / execute token totals and elapsed spans,
# summed across every session the feature took (halted, resumed, worktree-
# split). It reads the ledger ONLY, never a transcript.
#
# Dedup (frozen algorithm): within a kind, group ledger
# rows by session_id.
#   - execute: the winning row is the one with `final: true`; if a session
#     carries none or several `final` rows (a degraded ledger), fall back to
#     the row with the maximum `seq` among its NON-partial rows. Ties break
#     on the latest `.ended_at` (string compare, null -> "").
#   - spec/plan: a single row per session, so the existing max-`.total`
#     selection among non-partial rows still applies (a missing `partial`
#     field counts as non-partial / final); only when EVERY row for that
#     session is partial does the pool fall back to all of the session's
#     rows (and the session is flagged partial).
#
# Grand elapsed is the SUM of every winning row's own duration_seconds (each
# session's own first-to-last-billed-turn span); it deliberately excludes
# idle gaps between sessions, so it is NOT max(ended_at) - min(started_at)
# across all rows.
#
# CLI:
#   bash .gaia/scripts/token-rollup.sh --spec-id <feature-key> [--ledger <path>]
#
# Behavior:
#   - Exit code is ALWAYS 0. stdout carries ONLY the roll-up block; all
#     diagnostics go to stderr. No number is ever fabricated; unreadable or
#     partial input degrades to a lower-bound figure with a trailing marker
#     line instead of aborting or guessing.
#
# DO NOT add `set -e`; every step degrades to a partial/empty readout rather
# than aborting.

# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ledger-path-lib.sh" 2>/dev/null || true
# Sourced here as well: ledger-path-lib loads it only inside a $(...) subshell,
# so without this the resolver is undefined in this shell and the single
# resolution below would silently come back empty.
# shellcheck source=.gaia/scripts/main-root-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/main-root-lib.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" >&2
}

is_unsigned_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Pinned human duration format, identical to token-tally.sh: <N>h<M>m<S>s,
# dropping any leading zero-valued unit.
human_duration() {
  local total="$1" hours minutes seconds
  hours=$(( total / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))
  if (( hours > 0 )); then
    printf '%dh%dm%ds' "$hours" "$minutes" "$seconds"
  elif (( minutes > 0 )); then
    printf '%dm%ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

# Group a non-negative integer with thousands separators for DISPLAY ONLY; the
# stored ledger values and all internal arithmetic stay raw. A non-numeric
# input echoes back unchanged.
commify() {
  local digits="$1" grouped_digits=""
  is_unsigned_integer "$digits" || { printf '%s' "$digits"; return 0; }
  while (( ${#digits} > 3 )); do
    grouped_digits=",${digits: -3}${grouped_digits}"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s' "$digits" "$grouped_digits"
}

# ---------- argument parsing (never crash on a bad/missing flag) ----------
FEATURE_KEY=""
LEDGER_OVERRIDE=""
RATE_TABLE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --spec-id|--ledger|--rate-table)
      flag_value="${2:-}"
      case "$key" in
        --spec-id)    FEATURE_KEY="$flag_value" ;;
        --ledger)     LEDGER_OVERRIDE="$flag_value" ;;
        --rate-table) RATE_TABLE_OVERRIDE="$flag_value" ;;
      esac
      # `shift 2` fails (and does NOT shift) when a flag is the final arg with
      # no value, which would spin this loop forever; fall back to a single shift.
      shift 2 2>/dev/null || shift
      ;;
    *)
      log "token-rollup: ignoring unknown argument: $key"
      shift
      ;;
  esac
done

[[ -z "$FEATURE_KEY" ]] && log "token-rollup: missing --spec-id"

no_records() {
  printf 'Cycle cost (%s): no ledger records found.\n' "$FEATURE_KEY"
  exit 0
}

# ---------- ledger resolution (shared with token-tally.sh) ----------
# main_root = dirname(absolute(git rev-parse --git-common-dir)), so a run
# inside a linked worktree reads the surviving main ledger, not a worktree
# copy that was never written. --ledger overrides (test seam).
resolve_ledger() {
  gaia_resolve_ledger_path "$LEDGER_OVERRIDE" "$ROLLUP_MAIN_ROOT"
}

# Resolved once and handed to both the ledger path and the rate table.
ROLLUP_MAIN_ROOT=""
if declare -F gaia_resolve_main_root >/dev/null 2>&1; then
  ROLLUP_MAIN_ROOT="$(gaia_resolve_main_root 2>/dev/null)" || ROLLUP_MAIN_ROOT=""
fi

LEDGER=""
if ledger_path="$(resolve_ledger)" && [[ -n "$ledger_path" ]]; then
  LEDGER="$ledger_path"
else
  log "token-rollup: could not resolve ledger path"
fi

[[ -z "$LEDGER" || ! -f "$LEDGER" ]] && no_records

# ---------- corrupt-line-tolerant parse + feature filter ----------
# A line that is not a well-formed JSON object -- unparseable, or valid JSON
# that is not an object (a bare scalar or array) -- is skipped and bumps `bad`;
# it never aborts the read, and a single bad line never drops the good ones.
# The non-object coercion matters because `try fromjson` only rescues parse
# failures: a bare `42` survives it, then indexing `.spec_id` on a number
# throws and aborts the whole filter, silently dropping every good row.
corrupt=0
parsed="$(jq -R -s --arg feature_key "$FEATURE_KEY" '
  split("\n") | map(select(length > 0))
  | map(try fromjson catch "__BAD__")
  | map(if type == "object" then . else "__BAD__" end)
  | {
      bad: (map(select(. == "__BAD__")) | length),
      recs: (map(select(. != "__BAD__")) | map(select(.spec_id == $feature_key or .plan_id == $feature_key)))
    }
' "$LEDGER" 2>/dev/null)"

if [[ -z "$parsed" ]]; then
  log "token-rollup: ledger unreadable: $LEDGER"
  no_records
fi

bad_count="$(jq -r '.bad' <<<"$parsed" 2>/dev/null)"
is_unsigned_integer "$bad_count" || bad_count=0
(( bad_count > 0 )) && corrupt=1

records="$(jq -c '.recs' <<<"$parsed" 2>/dev/null)"
[[ -z "$records" ]] && records="[]"
record_count="$(jq -r 'length' <<<"$records" 2>/dev/null)"
is_unsigned_integer "$record_count" || record_count=0
(( record_count == 0 )) && no_records

# ---------- dedup + aggregate (frozen algorithm) ----------
summary="$(jq -c '
  # spec/plan: one row per session; the winner is the max-`.total` row among
  # non-partial rows (tie on latest `.ended_at`), falling back to the whole
  # session pool only when every row is partial.
  def winner_of_general($pool):
    $pool | map(. + {_ended: (.ended_at // "")}) | sort_by([(.total // 0), ._ended]) | last;

  def dedup_session_general($session_rows):
    ($session_rows | map(select(.partial != true))) as $nonpartial
    | (if ($nonpartial | length) > 0 then $nonpartial else $session_rows end) as $pool
    | { winner: winner_of_general($pool), session_partial: (($nonpartial | length) == 0) };

  # execute: one cumulative row per commit. The winner is the row with
  # `final: true`; a degraded ledger (none or several `final` rows) falls
  # back to the max-`seq` row (tie on latest `.ended_at`), NOT max-`total`.
  def winner_of_execute($pool):
    ($pool | map(select(.final == true))) as $finals
    | if ($finals | length) == 1 then $finals[0]
      else ($pool | map(. + {_ended: (.ended_at // "")}) | sort_by([(.seq // 0), ._ended]) | last)
      end;

  def dedup_session_execute($session_rows):
    ($session_rows | map(select(.partial != true))) as $nonpartial
    | (if ($nonpartial | length) > 0 then $nonpartial else $session_rows end) as $pool
    | { winner: winner_of_execute($pool), session_partial: (($nonpartial | length) == 0) };

  . as $records
  | ( ["spec", "plan", "execute"]
      | map(
          . as $action
          | ($records | map(select(.kind == $action))) as $action_records
          | select(($action_records | length) > 0)
          | ($action_records | group_by(.session_id)
             | map(if $action == "execute" then dedup_session_execute(.) else dedup_session_general(.) end)) as $session_results
          | {
              action: $action,
              total: ([$session_results[].winner.total] | add // 0),
              elapsed: ([$session_results[] | (if .winner.duration_available == true then (.winner.duration_seconds // 0) else 0 end)] | add // 0),
              elapsed_available: ([$session_results[].winner.duration_available] | any),
              elapsed_partial: ([$session_results[].winner.duration_available] | map(. != true) | any),
              session_partial: ([$session_results[].session_partial] | any),
              winners: [$session_results[].winner]
            }
        )
    ) as $actions
  | {
      actions: $actions,
      grand_total: ($actions | map(.total) | add // 0),
      grand_elapsed: ($actions | map(.elapsed) | add // 0),
      grand_elapsed_available: ($actions | map(.elapsed_available) | any),
      grand_elapsed_partial: ($actions | map(.elapsed_partial) | any),
      grand_session_partial: ($actions | map(.session_partial) | any),
      buckets: {
        fresh_input: ($actions | map(.winners[].buckets.fresh_input) | add // 0),
        cache_write: ($actions | map(.winners[].buckets.cache_write) | add // 0),
        cache_read:  ($actions | map(.winners[].buckets.cache_read)  | add // 0),
        output:      ($actions | map(.winners[].buckets.output)      | add // 0)
      }
    }
' <<<"$records" 2>/dev/null)"

if [[ -z "$summary" ]]; then
  log "token-rollup: aggregation failed"
  no_records
fi

actions_length="$(jq -r '.actions | length' <<<"$summary" 2>/dev/null)"
is_unsigned_integer "$actions_length" || actions_length=0
(( actions_length == 0 )) && no_records

# ---------- dollar pricing ----------
# Prices each winning row's by_model breakdown against the rate table:
# each cache bucket at input times its multiplier from token-rates.json
# (cache_multipliers, or a rate window's own cache_read_multiplier where the
# price card discounts cache reads per model). Degrades to a marked
# lower bound or an "unavailable" line on any unreadable table, unknown
# model, missing run-time anchor, or corrupt ledger line -- never guesses,
# never blocks.
#
# Prices from the machine-local rate table, like token-tally.sh: seeded from the
# main checkout's distributed table (never a linked worktree's copy), synced to
# later corrections, and healed once from the public table when a winner's model
# is missing from it. --rate-table prices from that file instead, with no seed,
# sync, or heal. Resolution + load are shared with token-tally.sh via
# token-pricing-lib.sh (sourced above).
rate_table_ok=true
RATE_TABLE=""
if declare -F gaia_rates_prepare >/dev/null 2>&1; then
  # Called in this shell, not in $(...): it sets GAIA_RATES_TABLE and keeps
  # per-process state a subshell would discard.
  if gaia_rates_prepare "$RATE_TABLE_OVERRIDE" "$ROLLUP_MAIN_ROOT"; then
    RATE_TABLE="$GAIA_RATES_TABLE"
  fi
else
  # A partial update can leave the local-table lib absent.
  RATE_TABLE="$(gaia_resolve_rate_table "$RATE_TABLE_OVERRIDE")" || RATE_TABLE=""
fi
if [[ -z "$RATE_TABLE" ]]; then
  log "token-rollup: could not resolve rate table path"
  rate_table_ok=false
fi

rates_json="null"
if [[ "$rate_table_ok" == "true" ]]; then
  if rate_table_contents="$(gaia_load_rate_table "$RATE_TABLE")"; then
    rates_json="$rate_table_contents"
    # Heal with every model any winner priced; status 0 means the local table
    # was rewritten, so reload before pricing.
    if declare -F gaia_rates_heal >/dev/null 2>&1 \
      && gaia_rates_heal "$(jq -c '[.actions[].winners[] | (.by_model // {}) | keys[]] | unique' <<<"$summary" 2>/dev/null)"; then
      RATE_TABLE="$GAIA_RATES_TABLE"
      if healed_contents="$(gaia_load_rate_table "$RATE_TABLE")"; then
        rates_json="$healed_contents"
      fi
    fi
  else
    log "token-rollup: rate table unreadable: $RATE_TABLE"
    rate_table_ok=false
  fi
fi

cost_attributed_present=false
cost_pre_attribution_present=false
cost_missing_anchor=false
cost_unpriced_models=""
cost_grand_dollars="0"
cost_summary=""

if [[ "$rate_table_ok" == "true" ]]; then
  cost_summary="$(jq -c --argjson rates "$rates_json" "$GAIA_PRICING_JQ_DEFS"'
    .actions as $actions
    | ( $actions | map(
          . as $action_summary
          | ($action_summary.winners | map(select(.by_model != null and (.by_model | length) > 0))) as $attributed_winners
          | ($attributed_winners | map(priced_row(.))) as $priced_rows
          | { action: $action_summary.action, dollars: ($priced_rows | map(.dollars) | add // 0), _rows: $priced_rows }
        )
      ) as $cost_actions
    | {
        actions: ( $cost_actions | map({action, dollars}) ),
        grand_dollars: ( $cost_actions | map(.dollars) | add // 0 ),
        attributed_present: ( $actions | map(.winners[] | (.by_model != null and (.by_model | length) > 0)) | any ),
        pre_attribution_present: ( $actions | map(.winners[] | (.by_model == null or (.by_model | length) == 0)) | any ),
        missing_anchor: ( $cost_actions | map(._rows[].missing_anchor) | any ),
        unpriced_models: ( $cost_actions | map(._rows[].unpriced) | flatten | unique )
      }
  ' <<<"$summary" 2>/dev/null)"

  if [[ -z "$cost_summary" ]]; then
    log "token-rollup: dollar pricing computation failed"
  fi
fi

if [[ -n "$cost_summary" ]]; then
  IFS=$'\t' read -r cost_grand_dollars cost_attributed_present cost_pre_attribution_present cost_missing_anchor cost_unpriced_models < <(
    jq -r '[.grand_dollars, .attributed_present, .pre_attribution_present, .missing_anchor, (.unpriced_models | join(", "))] | @tsv' <<<"$cost_summary"
  )
fi

# ---------- render (stdout = payload only) ----------
IFS=$'\t' read -r grand_total grand_elapsed grand_elapsed_available grand_elapsed_partial grand_session_partial fresh_input cache_write cache_read output < <(
  jq -r '[.grand_total, .grand_elapsed, .grand_elapsed_available, .grand_elapsed_partial, .grand_session_partial,
          .buckets.fresh_input, .buckets.cache_write, .buckets.cache_read, .buckets.output] | @tsv' <<<"$summary"
)
is_unsigned_integer "$grand_total" || grand_total=0
is_unsigned_integer "$grand_elapsed" || grand_elapsed=0
is_unsigned_integer "$fresh_input" || fresh_input=0
is_unsigned_integer "$cache_write" || cache_write=0
is_unsigned_integer "$cache_read" || cache_read=0
is_unsigned_integer "$output" || output=0

printf 'Cycle cost (%s):\n' "$FEATURE_KEY"

# Totals share one right-aligned column; the grand total is >= every action
# total, so its commified width is the column width for the action + Total lines.
grand_total_commified="$(commify "$grand_total")"
total_width=${#grand_total_commified}

while IFS=$'\t' read -r action_name action_total action_elapsed action_elapsed_available; do
  is_unsigned_integer "$action_total" || action_total=0
  is_unsigned_integer "$action_elapsed" || action_elapsed=0
  if [[ "$action_elapsed_available" == "true" ]]; then
    action_elapsed_display="$(human_duration "$action_elapsed")"
  else
    action_elapsed_display="unavailable"
  fi
  printf '  %-11s%*s   (elapsed %s)\n' "$action_name:" "$total_width" "$(commify "$action_total")" "$action_elapsed_display"
done < <(jq -r '.actions[] | [.action, .total, .elapsed, .elapsed_available] | @tsv' <<<"$summary")

if [[ "$grand_elapsed_available" == "true" ]]; then
  total_elapsed_display="$(human_duration "$grand_elapsed")"
else
  total_elapsed_display="unavailable"
fi
printf '  %-11s%*s   (elapsed %s)\n' "Total:" "$total_width" "$grand_total_commified" "$total_elapsed_display"

# Buckets share their own right-aligned column, widened to the largest of the four.
fresh_input_commified="$(commify "$fresh_input")"; cache_write_commified="$(commify "$cache_write")"
cache_read_commified="$(commify "$cache_read")"; output_commified="$(commify "$output")"
bucket_width=${#fresh_input_commified}
(( ${#cache_write_commified} > bucket_width )) && bucket_width=${#cache_write_commified}
(( ${#cache_read_commified}  > bucket_width )) && bucket_width=${#cache_read_commified}
(( ${#output_commified}    > bucket_width )) && bucket_width=${#output_commified}
printf '    %-14s%*s\n' "Fresh input:" "$bucket_width" "$fresh_input_commified"
printf '    %-14s%*s\n' "Cache write:" "$bucket_width" "$cache_write_commified"
printf '    %-14s%*s\n' "Cache read:"  "$bucket_width" "$cache_read_commified"
printf '    %-14s%*s\n' "Output:"      "$bucket_width" "$output_commified"

if (( corrupt == 1 )) || [[ "$grand_elapsed_partial" == "true" ]] || [[ "$grand_session_partial" == "true" ]]; then
  printf '  (partial: some ledger input was unreadable or lacked timing; figures are a lower bound)\n'
fi

# ---------- dollar cost render ----------
# Additive: appended after EVERYTHING the token block prints above,
# including its own trailing "(partial: ...)" marker, so the existing
# output stays an exact prefix.
cost_corrupt_present=false
if (( corrupt == 1 )) || [[ "$grand_elapsed_partial" == "true" ]] || [[ "$grand_session_partial" == "true" ]]; then
  cost_corrupt_present=true
fi

if [[ "$rate_table_ok" != "true" ]]; then
  printf '  Est. cost (USD): unavailable (rate table unreadable)\n'
elif [[ "$cost_attributed_present" != "true" ]]; then
  printf '  Est. cost (USD): unavailable (records predate per-model attribution)\n'
else
  printf '  Est. cost (USD):\n'

  grand_dollars_formatted="$(printf '$%.2f' "$cost_grand_dollars" 2>/dev/null)"
  # Literal fallback string, not a command sub.
  # shellcheck disable=SC2016
  [[ -z "$grand_dollars_formatted" ]] && grand_dollars_formatted='$0.00'
  dollars_width=${#grand_dollars_formatted}

  cost_action_labels=()
  cost_action_dollars_formatted=()
  while IFS=$'\t' read -r action_label action_dollars; do
    action_dollars_formatted="$(printf '$%.2f' "$action_dollars" 2>/dev/null)"
    # shellcheck disable=SC2016
    [[ -z "$action_dollars_formatted" ]] && action_dollars_formatted='$0.00'
    cost_action_labels+=("$action_label")
    cost_action_dollars_formatted+=("$action_dollars_formatted")
    (( ${#action_dollars_formatted} > dollars_width )) && dollars_width=${#action_dollars_formatted}
  done < <(jq -r '.actions[] | [.action, .dollars] | @tsv' <<<"$cost_summary")

  for i in "${!cost_action_labels[@]}"; do
    printf '    %-11s%*s\n' "${cost_action_labels[$i]}:" "$dollars_width" "${cost_action_dollars_formatted[$i]}"
  done
  printf '    %-11s%*s\n' "Total:" "$dollars_width" "$grand_dollars_formatted"

  [[ "$cost_pre_attribution_present" == "true" ]] && printf '    (partial lower bound: some records predate per-model attribution)\n'
  [[ "$cost_corrupt_present" == "true" ]] && printf '    (partial lower bound: some ledger input was unreadable, corrupt, or lacked timing)\n'
  # Model names come from transcripts: same allowlist as _usage_safe (usage-render-lib.sh).
  [[ -n "$cost_unpriced_models" ]] && printf '    (lower bound: unpriced model(s) %s)\n' "${cost_unpriced_models//[^A-Za-z0-9._:%@+\/ ,-]/?}"
  [[ "$cost_missing_anchor" == "true" ]] && printf '    (lower bound: a session lacked a run-time anchor)\n'
fi

exit 0
