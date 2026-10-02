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
# audit-loop-eval.sh's verdict program, after $counted, $A, $A1, $A2, $v and
# $r are bound, and reads $p1 and $p2 (the stored snapshots of rounds r-1 and
# r-2), $maint and $waivedkeys. A legacy stored snapshot is one without
# counted_keys: it predates the signals, so its keys, raw_count and
# waived_count are unknown, never zero.
# shellcheck disable=SC2016
_GAIA_LOOP_SIGNALS_JQ='
| def ck: type == "object" and (.counted_keys | type) == "array";
def kk: [.member, .finding_class, .path, .line];
def triple_lines($t; $ks): [$ks[] | select(.[0:3] == $t) | .[3]];
def disjoint($a; $b): all($a[]; . as $x | any($b[]; . == $x) | not);
($counted | map({member, finding_class, path, line, severity, security})) as $ck
| ($F.entries | length) as $raw
| ([$F.entries[] | kk as $k | select(any($waivedkeys[]; . == $k))] | length) as $waived
| ($r >= 2 and ($p1 | ck | not)) as $legacy1
| ($r >= 3 and ($p2 | ck | not)) as $legacy2
| ($ck | map(kk)) as $K0
| (if $p1 | ck then $p1.counted_keys | map(kk) else [] end) as $K1
| (if $p2 | ck then $p2.counted_keys | map(kk) else [] end) as $K2
| ($A != null and $A >= 1 and all($ck[]; .severity == "suggestion")) as $nit0
| ($A1 != null and $A1 >= 1 and ($p1 | ck) and all($p1.counted_keys[]; .severity == "suggestion")) as $nit1
| (any($K2[]; . as $k | (any($K1[]; . == $k) | not) and any($K0[]; . == $k))) as $back
| (any(($K0 | map(.[0:3]) | unique)[]; . as $t
     | triple_lines($t; $K0) as $l0 | triple_lines($t; $K1) as $l1 | triple_lines($t; $K2) as $l2
     | ($l1 | length) > 0 and ($l2 | length) > 0 and disjoint($l0; $l1) and disjoint($l1; $l2))) as $moved
| {cap: ($r >= 10),
   quiet: ($v == "quiet"),
   enriching: ($v == "enriching"),
   stalled: ($v == "stalled"),
   nitpicky: (($legacy1 | not) and $r >= 6 and $nit0 and $nit1),
   reintroduced: (($legacy1 | not) and ($legacy2 | not) and $r >= 3 and $A != null and $A1 != null and $A2 != null
                  and ($back or $moved)),
   "small-tail": (($legacy1 | not) and $r >= 6 and $A != null and $A >= 1 and $A <= 2
                  and all($ck[]; .severity != "error") and $A1 != null and $A >= $A1),
   "waiver-drift": (($legacy1 | not) and $maint and $r >= 2 and $raw > 0 and $waived * 2 >= $raw
                    and ($p1.raw_count | type) == "number" and $p1.raw_count > 0
                    and ($p1.waived_count | type) == "number" and $p1.waived_count * 2 >= $p1.raw_count)} as $sig
| ([("cap", "quiet", "enriching", "stalled", "nitpicky", "reintroduced", "small-tail", "waiver-drift")
    | select($sig[.] == true)]) as $reasons
| (($reasons | length) > 0 and $v != "unknown" and ($legacy1 | not) and ($legacy2 | not)
   and all($ck[]; .severity != "error" and .security != true)) as $elig
'

# _gaia_loop_snap_elig <snap-json>: `true` only when the snapshot says so.
_gaia_loop_snap_elig() {
  local out
  out="$(printf '%s' "${1:-null}" | jq -r 'if type == "object" and .accept_eligible == true then "true" else "false" end' 2>/dev/null)" || out=false
  [ "$out" = true ] && printf 'true\n' || printf 'false\n'
}

# _gaia_loop_denying_signal <state-json> <snap-json> <used>: the first denying
# signal on the snapshot that no checkpoint at round >= used has answered, or
# nothing. A snapshot without `signals` (legacy) denies on its verdict alone.
# rc 5 when the state cannot be read.
_gaia_loop_denying_signal() {
  printf '%s' "$1" | jq -r --argjson s "${2:-null}" --argjson u "$3" '
    ($s | if type == "object" then . else {} end) as $s
    | (if ($s.signals | type) == "object" then $s.signals
       else {enriching: ($s.verdict == "enriching"), stalled: ($s.verdict == "stalled")} end) as $g
    | [("enriching", "stalled", "nitpicky", "reintroduced", "small-tail", "waiver-drift") | select($g[.] == true)] as $d
    | [.history.checkpoints[] | select(.at_round >= $u) | .index] as $ix
    | if ($d | length) > 0 and (any(.allowance.answers[]; .checkpoint as $c | any($ix[]; . == $c)) | not)
      then $d[0] else empty end' 2>/dev/null || return 5
}

# _gaia_loop_min <a> <b>...: the smallest integer argument.
_gaia_loop_min() {
  local m="$1"
  shift
  while [ $# -gt 0 ]; do
    [ "$1" -lt "$m" ] && m="$1"
    shift
  done
  printf '%s\n' "$m"
}

# _gaia_loop_used <state-json>: rounds used, rc 5 when unreadable.
_gaia_loop_used() {
  local used
  used="$(printf '%s' "$1" | jq -r '.history.rounds | length' 2>/dev/null)" || return 5
  gaia_loop_is_uint "$used" || return 5
  printf '%s\n' "$used"
}

# _gaia_loop_decide_unit_k <state> <snap> <reading> <ask_tokens> <ask_window_pct> <k>
_gaia_loop_decide_unit_k() {
  local state="$1" snap="${2:-null}" reading="$3" tokens="$4" pct="$5" k="$6"
  local int='^[0-9]{1,12}$' fresh='^fresh (0|[1-9][0-9]{0,11}) (0|[1-9][0-9]{0,11})$'
  local used elig sig s answer spent line allowed reading_tokens reading_window
  [[ $tokens =~ $int && $pct =~ $int && $k =~ $int ]] && [ "$k" -ge 1 ] || return 2
  used="$(_gaia_loop_used "$state")" || return 5
  elig="$(_gaia_loop_snap_elig "$snap")"
  s=$((used + 1))
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap %s true\n' "$elig"
    return 0
  fi
  sig="$(_gaia_loop_denying_signal "$state" "$snap" "$used")" || return 5
  if [ -n "$sig" ]; then
    printf 'deny rubric:%s %s false\n' "$sig" "$elig"
    return 0
  fi
  # Grant admission comes before the line check: it is how a human lets a unit
  # run while the reading is over the line. Only the LATEST checkpoint counts,
  # and only once: after_checkpoint is the checkpoint count when the last unit
  # was admitted, so a unit admitted on this answer has consumed it.
  answer="$(printf '%s' "$state" | jq -r '
    (.history.checkpoints | last) as $c
    | ((.history.units // []) | last) as $u
    | if $c == null then empty
      else ([.allowance.answers[] | select(.checkpoint == $c.index)] | last) as $a
      | if $a != null and ($u == null or $u.after_checkpoint < $c.index) then $a.kind else empty end
      end' 2>/dev/null)" || return 5
  case "$answer" in
    grant)
      printf 'allow grant %s %s\n' "$s" "$(_gaia_loop_min $((s + k - 1)) "$_GAIA_LOOP_HARD_CAP")"
      return 0
      ;;
    accept)
      printf 'allow accept %s %s\n' "$s" "$s"
      return 0
      ;;
  esac
  # The inverse of gaia_loop_next_closing: the accepted closing round is
  # already recorded.
  spent="$(printf '%s' "$state" | jq -r '
    (.allowance.answers | last) as $a
    | if $a == null or $a.kind != "accept" then false
      else ([.history.checkpoints[] | select(.index == $a.checkpoint)] | .[0].at_round) as $c
      | ($c != null and (.history.rounds | length) > $c)
      end' 2>/dev/null)" || return 5
  if [ "$spent" = true ]; then
    printf 'deny fallback %s false\n' "$elig"
    return 0
  fi
  if [[ $reading =~ $fresh ]]; then
    reading_tokens="${BASH_REMATCH[1]}"
    reading_window="${BASH_REMATCH[2]}"
    line="$(gaia_ctx_line "$reading_window" "$tokens" "$pct")" || return 2
    if [ "$reading_tokens" -ge "$line" ]; then
      printf 'deny context %s false\n' "$elig"
    else
      printf 'allow context %s %s\n' "$s" "$(_gaia_loop_min $((s + k - 1)) "$_GAIA_LOOP_HARD_CAP")"
    fi
    return 0
  fi
  allowed="$(gaia_loop_allowed "$state")" || return 5
  gaia_loop_is_uint "$allowed" || return 5
  if [ "$used" -ge "$allowed" ]; then
    printf 'deny fallback %s false\n' "$elig"
  else
    printf 'allow fallback %s %s\n' "$s" "$(_gaia_loop_min $((s + k - 1)) "$_GAIA_LOOP_HARD_CAP" "$allowed")"
  fi
}

# gaia_loop_decide_unit <state-json> <snap-json> <reading-line> <ask_tokens> <ask_window_pct>:
# `allow <admitted_on> <start_round> <through_round>` or
# `deny <trigger> <accept_eligible> <cap>`. rc 2 bad arguments, 5 unreadable state.
gaia_loop_decide_unit() {
  _gaia_loop_decide_unit_k "$1" "$2" "$3" "$4" "$5" "$GAIA_CTX_UNIT_ROUNDS"
}

# gaia_loop_decide_member <state-json> <snap-json> <in-unit:true|false> <reading-line> <ask_tokens> <ask_window_pct>:
# in a unit, `allow` or `deny <trigger> <accept_eligible> <cap>`; inline, what
# gaia_loop_decide_unit prints with k = 1.
gaia_loop_decide_member() {
  local state="$1" snap="${2:-null}" used elig through sig
  case "$3" in
    false) _gaia_loop_decide_unit_k "$state" "$snap" "$4" "$5" "$6" 1; return $? ;;
    true) ;;
    *) return 2 ;;
  esac
  used="$(_gaia_loop_used "$state")" || return 5
  elig="$(_gaia_loop_snap_elig "$snap")"
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap %s true\n' "$elig"
    return 0
  fi
  through="$(printf '%s' "$state" | jq -r '((.history.units // []) | last | .through_round?) // empty' 2>/dev/null)" || return 5
  if ! gaia_loop_is_uint "$through" || [ "$through" -lt $((used + 1)) ]; then
    printf 'deny window %s false\n' "$elig"
    return 0
  fi
  sig="$(_gaia_loop_denying_signal "$state" "$snap" "$used")" || return 5
  if [ -n "$sig" ]; then
    printf 'deny rubric:%s %s false\n' "$sig" "$elig"
    return 0
  fi
  printf 'allow\n'
}
