#!/usr/bin/env bash
# GAIA token roll-up reader (SPEC-017).
#
# Reads the durable ledger token-tally.sh (SPEC-013) appends to
# (.gaia/local/telemetry/tokens.jsonl) and renders a full-cycle cost readout
# for one feature: spec / plan / execute token totals and elapsed spans,
# summed across every session the feature took (halted, resumed, worktree-
# split). It reads the ledger ONLY, never a transcript.
#
# Dedup (frozen, see the plan's README.md FC-1): within an action, group
# ledger rows by session_id; a session's winning row is the max-`.total` row
# among its NON-partial rows (a missing `partial` field counts as non-partial
# / final); only when EVERY row for that session is partial does the pool
# fall back to all of the session's rows (and the session is flagged
# partial). Ties break on the latest `.ended_at` (string compare, null ->
# "").
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

log() {
  printf '%s\n' "$*" >&2
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Pinned human duration format, identical to token-tally.sh: <N>h<M>m<S>s,
# dropping any leading zero-valued unit.
human_duration() {
  local total="$1" h m s
  h=$(( total / 3600 ))
  m=$(( (total % 3600) / 60 ))
  s=$(( total % 60 ))
  if (( h > 0 )); then
    printf '%dh%dm%ds' "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf '%dm%ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# Group a non-negative integer with thousands separators for DISPLAY ONLY; the
# stored ledger values and all internal arithmetic stay raw. A non-numeric
# input echoes back unchanged.
commify() {
  local n="$1" out=""
  is_uint "$n" || { printf '%s' "$n"; return 0; }
  while (( ${#n} > 3 )); do
    out=",${n: -3}${out}"
    n="${n:0:${#n}-3}"
  done
  printf '%s%s' "$n" "$out"
}

# ---------- argument parsing (never crash on a bad/missing flag) ----------
FEATURE_KEY=""
LEDGER_OVERRIDE=""
RATE_TABLE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --spec-id|--ledger|--rate-table)
      val="${2:-}"
      case "$key" in
        --spec-id)    FEATURE_KEY="$val" ;;
        --ledger)     LEDGER_OVERRIDE="$val" ;;
        --rate-table) RATE_TABLE_OVERRIDE="$val" ;;
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

# ---------- ledger resolution, same as token-tally.sh's resolve_ledger ----------
# main_root = dirname(absolute(git rev-parse --git-common-dir)), so a run
# inside a linked worktree reads the surviving main ledger, not a worktree
# copy that was never written. --ledger overrides (test seam).
resolve_ledger() {
  if [[ -n "$LEDGER_OVERRIDE" ]]; then
    printf '%s' "$LEDGER_OVERRIDE"
    return 0
  fi
  local common_dir abs main_root
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  [[ -z "$common_dir" ]] && return 1
  case "$common_dir" in
    /*) abs="$common_dir" ;;
    *)  abs="$PWD/$common_dir" ;;
  esac
  main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)"
  [[ -z "$main_root" ]] && return 1
  printf '%s' "$main_root/.gaia/local/telemetry/tokens.jsonl"
}

LEDGER=""
if ledger_path="$(resolve_ledger)" && [[ -n "$ledger_path" ]]; then
  LEDGER="$ledger_path"
else
  log "token-rollup: could not resolve ledger path"
fi

# ---------- rate-table resolution (SPEC-019) ----------
# The rate table is committed (public Claude pricing, shared across
# developers), unlike the ledger which is machine-local. Resolve via
# --show-toplevel (the current checkout, worktree or main -- both carry the
# committed file) rather than --git-common-dir. --rate-table overrides (test
# seam).
resolve_rate_table() {
  if [[ -n "$RATE_TABLE_OVERRIDE" ]]; then
    printf '%s' "$RATE_TABLE_OVERRIDE"
    return 0
  fi
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$toplevel" ]] && return 1
  printf '%s' "$toplevel/.gaia/scripts/token-rates.json"
}

[[ -z "$LEDGER" || ! -f "$LEDGER" ]] && no_records

# ---------- corrupt-line-tolerant parse + feature filter ----------
# A line that is not a well-formed JSON object -- unparseable, or valid JSON
# that is not an object (a bare scalar or array) -- is skipped and bumps `bad`;
# it never aborts the read, and a single bad line never drops the good ones
# (UAT-010). The non-object coercion matters because `try fromjson` only rescues
# parse failures: a bare `42` survives it, then indexing `.spec_id` on a number
# throws and aborts the whole filter, silently dropping every good row.
corrupt=0
parsed="$(jq -R -s --arg fk "$FEATURE_KEY" '
  split("\n") | map(select(length > 0))
  | map(try fromjson catch "__BAD__")
  | map(if type == "object" then . else "__BAD__" end)
  | {
      bad: (map(select(. == "__BAD__")) | length),
      recs: (map(select(. != "__BAD__")) | map(select(.spec_id == $fk)))
    }
' "$LEDGER" 2>/dev/null)"

if [[ -z "$parsed" ]]; then
  log "token-rollup: ledger unreadable: $LEDGER"
  no_records
fi

bad_count="$(jq -r '.bad' <<<"$parsed" 2>/dev/null)"
is_uint "$bad_count" || bad_count=0
(( bad_count > 0 )) && corrupt=1

recs="$(jq -c '.recs' <<<"$parsed" 2>/dev/null)"
[[ -z "$recs" ]] && recs="[]"
recs_count="$(jq -r 'length' <<<"$recs" 2>/dev/null)"
is_uint "$recs_count" || recs_count=0
(( recs_count == 0 )) && no_records

# ---------- dedup + aggregate (frozen algorithm) ----------
summary="$(jq -c '
  def winner_of($pool):
    $pool | map(. + {_ended: (.ended_at // "")}) | sort_by([(.total // 0), ._ended]) | last;

  def dedup_session($sess):
    ($sess | map(select(.partial != true))) as $nonpartial
    | (if ($nonpartial | length) > 0 then $nonpartial else $sess end) as $pool
    | { winner: winner_of($pool), session_partial: (($nonpartial | length) == 0) };

  . as $recs
  | ( ["spec", "plan", "execute"]
      | map(
          . as $action
          | ($recs | map(select(.action == $action))) as $actRecs
          | select(($actRecs | length) > 0)
          | ($actRecs | group_by(.session_id) | map(dedup_session(.))) as $sr
          | {
              action: $action,
              total: ([$sr[].winner.total] | add // 0),
              elapsed: ([$sr[] | (if .winner.duration_available == true then (.winner.duration_seconds // 0) else 0 end)] | add // 0),
              elapsed_available: ([$sr[].winner.duration_available] | any),
              elapsed_partial: ([$sr[].winner.duration_available] | map(. != true) | any),
              session_partial: ([$sr[].session_partial] | any),
              winners: [$sr[].winner]
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
' <<<"$recs" 2>/dev/null)"

if [[ -z "$summary" ]]; then
  log "token-rollup: aggregation failed"
  no_records
fi

actions_len="$(jq -r '.actions | length' <<<"$summary" 2>/dev/null)"
is_uint "$actions_len" || actions_len=0
(( actions_len == 0 )) && no_records

# ---------- dollar pricing (SPEC-019) ----------
# Prices each winning row's by_model breakdown against the rate table:
# cache_read at input*0.1, cache_write_5m at input*1.25, cache_write_1h at
# input*2.0 (see token-rates.json's cache_multipliers). Degrades to a marked
# lower bound or an "unavailable" line on any unreadable table, unknown
# model, missing run-time anchor, or corrupt ledger line -- never guesses,
# never blocks.
rate_table_ok=true
RATE_TABLE=""
if rt_path="$(resolve_rate_table)" && [[ -n "$rt_path" ]]; then
  RATE_TABLE="$rt_path"
else
  log "token-rollup: could not resolve rate table path"
  rate_table_ok=false
fi

rates_json="null"
if [[ "$rate_table_ok" == "true" ]]; then
  rt_contents="$(cat "$RATE_TABLE" 2>/dev/null)"
  if [[ -n "$rt_contents" ]] && jq -e 'type=="object" and has("models")' >/dev/null 2>&1 <<<"$rt_contents"; then
    rates_json="$rt_contents"
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
  cost_summary="$(jq -c --argjson rates "$rates_json" '
    def rate_window($model; $date):
      ($rates.models[$model] // [])
      | map(select(.effective_through == null or ($date != "" and $date <= .effective_through)))
      | first;

    # Prices one winning row. A null/empty ts short-circuits BEFORE window
    # selection (DP-004): the whole row contributes zero and is flagged
    # missing_anchor, never falling through to the sticker window.
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

    .actions as $actions
    | ( $actions | map(
          . as $a
          | ($a.winners | map(select(.by_model != null and (.by_model | length) > 0))) as $attributed_winners
          | ($attributed_winners | map(priced_row(.))) as $priced_rows
          | { action: $a.action, dollars: ($priced_rows | map(.dollars) | add // 0), _rows: $priced_rows }
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
IFS=$'\t' read -r grand_total grand_elapsed grand_elapsed_available grand_elapsed_partial grand_session_partial fresh cwrite cread out < <(
  jq -r '[.grand_total, .grand_elapsed, .grand_elapsed_available, .grand_elapsed_partial, .grand_session_partial,
          .buckets.fresh_input, .buckets.cache_write, .buckets.cache_read, .buckets.output] | @tsv' <<<"$summary"
)
is_uint "$grand_total" || grand_total=0
is_uint "$grand_elapsed" || grand_elapsed=0
is_uint "$fresh" || fresh=0
is_uint "$cwrite" || cwrite=0
is_uint "$cread" || cread=0
is_uint "$out" || out=0

printf 'Cycle cost (%s):\n' "$FEATURE_KEY"

# Totals share one right-aligned column; the grand total is >= every action
# total, so its commified width is the column width for the action + Total lines.
grand_total_c="$(commify "$grand_total")"
tw=${#grand_total_c}

while IFS=$'\t' read -r a_action a_total a_elapsed a_avail; do
  is_uint "$a_total" || a_total=0
  is_uint "$a_elapsed" || a_elapsed=0
  if [[ "$a_avail" == "true" ]]; then
    a_elapsed_str="$(human_duration "$a_elapsed")"
  else
    a_elapsed_str="unavailable"
  fi
  printf '  %-11s%*s   (elapsed %s)\n' "$a_action:" "$tw" "$(commify "$a_total")" "$a_elapsed_str"
done < <(jq -r '.actions[] | [.action, .total, .elapsed, .elapsed_available] | @tsv' <<<"$summary")

if [[ "$grand_elapsed_available" == "true" ]]; then
  total_elapsed_str="$(human_duration "$grand_elapsed")"
else
  total_elapsed_str="unavailable"
fi
printf '  %-11s%*s   (elapsed %s)\n' "Total:" "$tw" "$grand_total_c" "$total_elapsed_str"

# Buckets share their own right-aligned column, widened to the largest of the four.
fresh_c="$(commify "$fresh")"; cwrite_c="$(commify "$cwrite")"
cread_c="$(commify "$cread")"; out_c="$(commify "$out")"
bw=${#fresh_c}
(( ${#cwrite_c} > bw )) && bw=${#cwrite_c}
(( ${#cread_c}  > bw )) && bw=${#cread_c}
(( ${#out_c}    > bw )) && bw=${#out_c}
printf '    %-14s%*s\n' "Fresh input:" "$bw" "$fresh_c"
printf '    %-14s%*s\n' "Cache write:" "$bw" "$cwrite_c"
printf '    %-14s%*s\n' "Cache read:"  "$bw" "$cread_c"
printf '    %-14s%*s\n' "Output:"      "$bw" "$out_c"

if (( corrupt == 1 )) || [[ "$grand_elapsed_partial" == "true" ]] || [[ "$grand_session_partial" == "true" ]]; then
  printf '  (partial: some ledger input was unreadable or lacked timing; figures are a lower bound)\n'
fi

# ---------- dollar cost render (SPEC-019) ----------
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

  grand_dollars_fmt="$(printf '$%.2f' "$cost_grand_dollars" 2>/dev/null)"
  # Literal fallback string, not a command sub.
  # shellcheck disable=SC2016
  [[ -z "$grand_dollars_fmt" ]] && grand_dollars_fmt='$0.00'
  dw=${#grand_dollars_fmt}

  cost_action_labels=()
  cost_action_fmts=()
  while IFS=$'\t' read -r c_action c_dollars; do
    c_fmt="$(printf '$%.2f' "$c_dollars" 2>/dev/null)"
    # shellcheck disable=SC2016
    [[ -z "$c_fmt" ]] && c_fmt='$0.00'
    cost_action_labels+=("$c_action")
    cost_action_fmts+=("$c_fmt")
    (( ${#c_fmt} > dw )) && dw=${#c_fmt}
  done < <(jq -r '.actions[] | [.action, .dollars] | @tsv' <<<"$cost_summary")

  for i in "${!cost_action_labels[@]}"; do
    printf '    %-11s%*s\n' "${cost_action_labels[$i]}:" "$dw" "${cost_action_fmts[$i]}"
  done
  printf '    %-11s%*s\n' "Total:" "$dw" "$grand_dollars_fmt"

  [[ "$cost_pre_attribution_present" == "true" ]] && printf '    (partial lower bound: some records predate per-model attribution)\n'
  [[ "$cost_corrupt_present" == "true" ]] && printf '    (partial lower bound: the ledger had a corrupt record)\n'
  [[ -n "$cost_unpriced_models" ]] && printf '    (lower bound: unpriced model(s) %s)\n' "$cost_unpriced_models"
  [[ "$cost_missing_anchor" == "true" ]] && printf '    (lower bound: a session lacked a run-time anchor)\n'
fi

exit 0
