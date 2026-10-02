# shellcheck shell=bash
#
# Rubric signals and gate decisions for the audit loop, sourced by
# audit-loop-eval.sh only. The formulas, their order and every default are
# stated once, in audit-loop-eval.sh's header (SIGNALS, DECISION); this file
# is their implementation and restates none of them.
#
# Needs audit-loop-state-lib.sh, context-checkpoint-lib.sh and
# audit-loop-eval.sh's gaia_loop_allowed already defined. Defines functions
# and one jq fragment; runs nothing at source time. Bash 3.2 compatible.
#
# The decision functions read no file: the bound hook reads the context
# reading and computes the effective line config, then passes both in, so the
# decisions are pure functions of their arguments and testable without a
# repository.

_GAIA_LOOP_HARD_CAP=10

# The signal block of the snapshot program. It runs inside
# audit-loop-eval.sh's verdict program, after $counted, $authored_count, $previous_authored_count, $second_previous_authored_count, $verdict and
# $round are bound, and reads $previous_snapshot and $second_previous_snapshot (the stored snapshots of rounds r-1 and
# r-2), $is_maintainer_repo and $waivedkeys. A legacy stored snapshot is one without
# counted_keys: it predates the signals, so its keys, raw_count and
# waived_count are unknown, never zero.
# shellcheck disable=SC2016
_GAIA_LOOP_SIGNALS_JQ='
| def has_counted_keys: type == "object" and (.counted_keys | type) == "array";
def identity_key: [.member, .finding_class, .path, .line];
def triple_lines($triple; $keys): [$keys[] | select(.[0:3] == $triple) | .[3]];
def disjoint($left_lines; $right_lines): all($left_lines[]; . as $line | any($right_lines[]; . == $line) | not);
($counted | map({member, finding_class, path, line, severity, security})) as $counted_summaries
| ($findings.entries | length) as $raw
| ([$findings.entries[] | identity_key as $entry_key | select(any($waivedkeys[]; . == $entry_key))] | length) as $waived
| ($round >= 2 and ($previous_snapshot | has_counted_keys | not)) as $previous_is_legacy
| ($round >= 3 and ($second_previous_snapshot | has_counted_keys | not)) as $second_previous_is_legacy
| ($counted_summaries | map(identity_key)) as $round_counted_keys
| (if $previous_snapshot | has_counted_keys then $previous_snapshot.counted_keys | map(identity_key) else [] end) as $previous_round_counted_keys
| (if $second_previous_snapshot | has_counted_keys then $second_previous_snapshot.counted_keys | map(identity_key) else [] end) as $second_previous_round_counted_keys
| ($authored_count != null and $authored_count >= 1 and all($counted_summaries[]; .severity == "suggestion")) as $round_suggestions_only
| ($previous_authored_count != null and $previous_authored_count >= 1 and ($previous_snapshot | has_counted_keys) and all($previous_snapshot.counted_keys[]; .severity == "suggestion")) as $previous_round_suggestions_only
| (any($second_previous_round_counted_keys[]; . as $entry_key | (any($previous_round_counted_keys[]; . == $entry_key) | not) and any($round_counted_keys[]; . == $entry_key))) as $returned
| (any(($round_counted_keys | map(.[0:3]) | unique)[]; . as $triple
     | triple_lines($triple; $round_counted_keys) as $round_lines | triple_lines($triple; $previous_round_counted_keys) as $previous_round_lines | triple_lines($triple; $second_previous_round_counted_keys) as $second_previous_round_lines
     | ($previous_round_lines | length) > 0 and ($second_previous_round_lines | length) > 0 and disjoint($round_lines; $previous_round_lines) and disjoint($previous_round_lines; $second_previous_round_lines))) as $moved
| {cap: ($round >= 10),
   quiet: ($verdict == "quiet"),
   enriching: ($verdict == "enriching"),
   stalled: ($verdict == "stalled"),
   nitpicky: (($previous_is_legacy | not) and $round >= 6 and $round_suggestions_only and $previous_round_suggestions_only),
   reintroduced: (($previous_is_legacy | not) and ($second_previous_is_legacy | not) and $round >= 3 and $authored_count != null and $previous_authored_count != null and $second_previous_authored_count != null
                  and ($returned or $moved)),
   "small-tail": (($previous_is_legacy | not) and $round >= 6 and $authored_count != null and $authored_count >= 1 and $authored_count <= 2
                  and all($counted_summaries[]; .severity != "error") and $previous_authored_count != null and $authored_count >= $previous_authored_count),
   "waiver-drift": (($previous_is_legacy | not) and $is_maintainer_repo and $round >= 2 and $raw > 0 and $waived * 2 >= $raw
                    and ($previous_snapshot.raw_count | type) == "number" and $previous_snapshot.raw_count > 0
                    and ($previous_snapshot.waived_count | type) == "number" and $previous_snapshot.waived_count * 2 >= $previous_snapshot.raw_count)} as $signals
| ([("cap", "quiet", "enriching", "stalled", "nitpicky", "reintroduced", "small-tail", "waiver-drift")
    | select($signals[.] == true)]) as $reasons
| (($reasons | length) > 0 and $verdict != "unknown" and ($previous_is_legacy | not) and ($second_previous_is_legacy | not)
   and all($counted_summaries[]; .severity != "error" and .security != true)) as $eligible
'

# _gaia_loop_snapshot_eligible <snapshot-json>: `true` only when the snapshot says so.
_gaia_loop_snapshot_eligible() {
  local eligibility
  eligibility="$(printf '%s' "${1:-null}" | jq -r 'if type == "object" and .accept_eligible == true then "true" else "false" end' 2>/dev/null)" || eligibility=false
  [ "$eligibility" = true ] && printf 'true\n' || printf 'false\n'
}

# _gaia_loop_denying_signal <state-json> <snapshot-json> <used>: the first denying
# signal on the snapshot that no checkpoint at round >= used has answered, or
# nothing. A snapshot without `signals` (legacy) denies on its verdict alone.
# rc 5 when the state cannot be read.
_gaia_loop_denying_signal() {
  printf '%s' "$1" | jq -r --argjson snapshot "${2:-null}" --argjson used "$3" '
    ($snapshot | if type == "object" then . else {} end) as $snapshot
    | (if ($snapshot.signals | type) == "object" then $snapshot.signals
       else {enriching: ($snapshot.verdict == "enriching"), stalled: ($snapshot.verdict == "stalled")} end) as $signals
    | [("enriching", "stalled", "nitpicky", "reintroduced", "small-tail", "waiver-drift") | select($signals[.] == true)] as $denying
    | [.history.checkpoints[] | select(.at_round >= $used) | .index] as $indexes
    | if ($denying | length) > 0 and (any(.allowance.answers[]; .checkpoint as $checkpoint | any($indexes[]; . == $checkpoint)) | not)
      then $denying[0] else empty end' 2>/dev/null || return 5
}

# _gaia_loop_minimum <a> <b>...: the smallest integer argument.
_gaia_loop_minimum() {
  local minimum="$1"
  shift
  while [ $# -gt 0 ]; do
    [ "$1" -lt "$minimum" ] && minimum="$1"
    shift
  done
  printf '%s\n' "$minimum"
}

# _gaia_loop_used <state-json>: rounds used, rc 5 when unreadable.
_gaia_loop_used() {
  local used
  used="$(printf '%s' "$1" | jq -r '.history.rounds | length' 2>/dev/null)" || return 5
  gaia_loop_is_uint "$used" || return 5
  printf '%s\n' "$used"
}

# _gaia_loop_decide_unit_with_unit_rounds <state> <snapshot> <reading> <ask_tokens> <ask_window_pct> <unit_rounds>
_gaia_loop_decide_unit_with_unit_rounds() {
  local state="$1" snapshot="${2:-null}" reading="$3" tokens="$4" percent="$5" unit_rounds="$6"
  local integer_pattern='^[0-9]{1,12}$' fresh='^fresh (0|[1-9][0-9]{0,11}) (0|[1-9][0-9]{0,11})$'
  local used eligible denying_signal start_round answer spent line allowed reading_tokens reading_window
  [[ $tokens =~ $integer_pattern && $percent =~ $integer_pattern && $unit_rounds =~ $integer_pattern ]] && [ "$unit_rounds" -ge 1 ] || return 2
  used="$(_gaia_loop_used "$state")" || return 5
  eligible="$(_gaia_loop_snapshot_eligible "$snapshot")"
  start_round=$((used + 1))
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap %s true\n' "$eligible"
    return 0
  fi
  denying_signal="$(_gaia_loop_denying_signal "$state" "$snapshot" "$used")" || return 5
  if [ -n "$denying_signal" ]; then
    printf 'deny rubric:%s %s false\n' "$denying_signal" "$eligible"
    return 0
  fi
  # Grant admission comes before the line check: it is how a human lets a unit
  # run while the reading is over the line. Only the LATEST checkpoint counts,
  # and only once: after_checkpoint is the checkpoint count when the last unit
  # was admitted, so a unit admitted on this answer has consumed it.
  answer="$(printf '%s' "$state" | jq -r '
    (.history.checkpoints | last) as $latest_checkpoint
    | ((.history.units // []) | last) as $latest_unit
    | if $latest_checkpoint == null then empty
      else ([.allowance.answers[] | select(.checkpoint == $latest_checkpoint.index)] | last) as $latest_answer
      | if $latest_answer != null and ($latest_unit == null or $latest_unit.after_checkpoint < $latest_checkpoint.index) then $latest_answer.kind else empty end
      end' 2>/dev/null)" || return 5
  case "$answer" in
    grant)
      printf 'allow grant %s %s\n' "$start_round" "$(_gaia_loop_minimum $((start_round + unit_rounds - 1)) "$_GAIA_LOOP_HARD_CAP")"
      return 0
      ;;
    accept)
      printf 'allow accept %s %s\n' "$start_round" "$start_round"
      return 0
      ;;
  esac
  # The inverse of gaia_loop_next_closing: the accepted closing round is
  # already recorded.
  spent="$(printf '%s' "$state" | jq -r '
    (.allowance.answers | last) as $last_answer
    | if $last_answer == null or $last_answer.kind != "accept" then false
      else ([.history.checkpoints[] | select(.index == $last_answer.checkpoint)] | .[0].at_round) as $at_round
      | ($at_round != null and (.history.rounds | length) > $at_round)
      end' 2>/dev/null)" || return 5
  if [ "$spent" = true ]; then
    printf 'deny fallback %s false\n' "$eligible"
    return 0
  fi
  if [[ $reading =~ $fresh ]]; then
    reading_tokens="${BASH_REMATCH[1]}"
    reading_window="${BASH_REMATCH[2]}"
    line="$(gaia_context_line "$reading_window" "$tokens" "$percent")" || return 2
    if [ "$reading_tokens" -ge "$line" ]; then
      printf 'deny context %s false\n' "$eligible"
    else
      printf 'allow context %s %s\n' "$start_round" "$(_gaia_loop_minimum $((start_round + unit_rounds - 1)) "$_GAIA_LOOP_HARD_CAP")"
    fi
    return 0
  fi
  allowed="$(gaia_loop_allowed "$state")" || return 5
  gaia_loop_is_uint "$allowed" || return 5
  if [ "$used" -ge "$allowed" ]; then
    printf 'deny fallback %s false\n' "$eligible"
  else
    printf 'allow fallback %s %s\n' "$start_round" "$(_gaia_loop_minimum $((start_round + unit_rounds - 1)) "$_GAIA_LOOP_HARD_CAP" "$allowed")"
  fi
}

# gaia_loop_decide_unit <state-json> <snapshot-json> <reading-line> <ask_tokens> <ask_window_pct>:
# `allow <admitted_on> <start_round> <through_round>` or
# `deny <trigger> <accept_eligible> <cap>`. rc 2 bad arguments, 5 unreadable state.
gaia_loop_decide_unit() {
  _gaia_loop_decide_unit_with_unit_rounds "$1" "$2" "$3" "$4" "$5" "$GAIA_CONTEXT_UNIT_ROUNDS"
}

# gaia_loop_decide_member <state-json> <snapshot-json> <in-unit:true|false> <reading-line> <ask_tokens> <ask_window_pct>:
# in a unit, `allow` or `deny <trigger> <accept_eligible> <cap>`; inline, what
# gaia_loop_decide_unit prints with k = 1.
gaia_loop_decide_member() {
  local state="$1" snapshot="${2:-null}" used eligible through denying_signal
  case "$3" in
    false) _gaia_loop_decide_unit_with_unit_rounds "$state" "$snapshot" "$4" "$5" "$6" 1; return $? ;;
    true) ;;
    *) return 2 ;;
  esac
  used="$(_gaia_loop_used "$state")" || return 5
  eligible="$(_gaia_loop_snapshot_eligible "$snapshot")"
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap %s true\n' "$eligible"
    return 0
  fi
  through="$(printf '%s' "$state" | jq -r '((.history.units // []) | last | .through_round?) // empty' 2>/dev/null)" || return 5
  if ! gaia_loop_is_uint "$through" || [ "$through" -lt $((used + 1)) ]; then
    printf 'deny window %s false\n' "$eligible"
    return 0
  fi
  denying_signal="$(_gaia_loop_denying_signal "$state" "$snapshot" "$used")" || return 5
  if [ -n "$denying_signal" ]; then
    printf 'deny rubric:%s %s false\n' "$denying_signal" "$eligible"
    return 0
  fi
  printf 'allow\n'
}
