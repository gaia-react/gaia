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

# ---------- argument parsing (never crash on a bad/missing flag) ----------
FEATURE_KEY=""
LEDGER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --spec-id|--ledger)
      val="${2:-}"
      case "$key" in
        --spec-id) FEATURE_KEY="$val" ;;
        --ledger)  LEDGER_OVERRIDE="$val" ;;
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

[[ -z "$LEDGER" || ! -f "$LEDGER" ]] && no_records

# ---------- corrupt-line-tolerant parse + feature filter ----------
# A line that fails to parse as JSON is skipped and bumps `bad`; it never
# aborts the read, and a single bad line never drops the good ones (UAT-010).
corrupt=0
parsed="$(jq -R -s --arg fk "$FEATURE_KEY" '
  split("\n") | map(select(length > 0))
  | map(try fromjson catch "__BAD__")
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

while IFS=$'\t' read -r a_action a_total a_elapsed a_avail; do
  is_uint "$a_total" || a_total=0
  is_uint "$a_elapsed" || a_elapsed=0
  if [[ "$a_avail" == "true" ]]; then
    a_elapsed_str="$(human_duration "$a_elapsed")"
  else
    a_elapsed_str="unavailable"
  fi
  printf '  %-11s%8d   (elapsed %s)\n' "$a_action:" "$a_total" "$a_elapsed_str"
done < <(jq -r '.actions[] | [.action, .total, .elapsed, .elapsed_available] | @tsv' <<<"$summary")

if [[ "$grand_elapsed_available" == "true" ]]; then
  total_elapsed_str="$(human_duration "$grand_elapsed")"
else
  total_elapsed_str="unavailable"
fi
printf '  %-11s%8d   (elapsed %s)\n' "Total:" "$grand_total" "$total_elapsed_str"
printf '    Fresh input:  %s\n' "$fresh"
printf '    Cache write:  %s\n' "$cwrite"
printf '    Cache read:   %s\n' "$cread"
printf '    Output:       %s\n' "$out"

if (( corrupt == 1 )) || [[ "$grand_elapsed_partial" == "true" ]] || [[ "$grand_session_partial" == "true" ]]; then
  printf '  (partial: some ledger input was unreadable or lacked timing; figures are a lower bound)\n'
fi

exit 0
