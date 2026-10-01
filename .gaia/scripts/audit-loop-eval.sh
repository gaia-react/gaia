#!/usr/bin/env bash
# shellcheck shell=bash
#
# Audit loop evaluator: the single owner of the loop's defaults, the allowance
# fold, the verdict formulas and the checkpoint recommendation. The PR Merge
# Workflow page and the hooks point here rather than restating any of them.
#
# Dual-mode. Sourced (audit-loop-bound.sh), it defines functions only:
#   gaia_loop_eval_round <main-root> <state-json> <r>   the snapshot for round r
#   gaia_loop_allowed <state-json>                      the allowance
#   gaia_loop_decide <state-json> <r-snapshot-json>     `allow` or `deny <reason>`
#   gaia_loop_knobs_initial                             knobs frozen at round 1
# Run (the main thread), it is a read-only CLI: it never writes a file, never
# takes the state lock, never calls gaia_loop_write_state.
#   audit-loop-eval.sh findings|eval|brief|record-values|state-path|current-round
#                      --root <audited-root> [--round <r>]
# Exit 0 ok, 2 usage or no recorded round, 4 detached HEAD, 5 corrupt state or
# a branch that is not keyable, 6 jq or git missing.
#
# DEFAULTS. Checkpoint round 5, grant 3. The checkpoint sits where the normal
# branch has already finished (the round distribution measured when this was
# written put nearly every branch at or below it), so it interrupts only the
# long tail. A grant of 3 is the smallest that lets both evidence windows
# below see fresh rounds before the next checkpoint.
#
# KNOBS. GAIA_AUDIT_CHECKPOINT_ROUND and GAIA_AUDIT_GRANT_ROUNDS, integers
# 1..99; anything else is ignored with a stderr note. At round 1 the bound hook
# freezes them into `history.knobs`, each capped at its default: a raised value
# is never honoured, because `.claude/settings*.json` `env` is editable by the
# session the bound exists to stop. Afterwards a live checkpoint value may
# only lower the frozen one, and only while no answer is recorded.
#
# ALLOWANCE. base = the frozen checkpoint round (lowered as above). Answers
# fold in order: a grant of n answering the checkpoint at round g sets
# allowed = g + n; an accept answering the checkpoint at round c sets
# allowed = c + 1 and makes that next round the closing round. used = recorded
# rounds, every verdict counted (an unknown round included, so deleting a
# sidecar never buys a round).
#
# DECISION, at a new-tree dispatch after round r = used is evaluated: deny
# `allowance` when used >= allowed; else deny `stalled` or `enriching` when
# that is round r's verdict and no answer exists for a checkpoint at round
# >= r; else allow.
#
# VERDICTS for round r, first match wins:
#   unknown    a dispatched member left no readable findings sidecar for the
#              round; A(r) = null. Missing evidence is never quiet.
#   quiet      A(r) = 0. A stop heuristic only: the merge page's own judgment
#              of what this change authored decides the disposition.
#   enriching  r >= 3, r >= g + 1, A(r-1) non-null, and some entry counted in
#              A(r) has an identity key absent from round r-1's keys and a
#              line inside a new-side hunk of `diff -U0 -M tree_{r-1} tree_r`.
#   stalled    r >= 3, r >= g + 2, A(r-2), A(r-1), A(r) non-null,
#              A(r-1) >= A(r-2) and A(r) >= A(r-1).
#   continue   otherwise.
# g is the round of the checkpoint the latest grant answered (0 when none), so
# a grant always buys one round of fresh evidence before enriching and two
# before stalled. A(r-1) and A(r-2) and round r-1's keys are read from the
# stored snapshots, never recomputed: each snapshot keeps its own merge base.
#
# FINDING SET AND A(r). F(r): for each member of round r, the newest
# `*.<raw_branch_slug>.<member>.findings.json` under <MAIN>/.gaia/local/audit/
# newer than the round's stamp and, when the round's baseline-<r>.json exists,
# not newer than it (a later sidecar is the fixer's era, never evidence). An
# entry is branch-authored when its path is in `diff --name-only -M
# merge_base_r tree_r` and its line is null or 0 or inside a new-side hunk of
# `diff -U0 -M merge_base_r tree_r`; a row with an invalid path or line, or a
# merge base that cannot be computed, counts as authored (fail closed: more
# counted, never fewer). A(r) = authored entries minus identity keys
# (member, finding_class, path, line) disposed accept-residual,
# waive-out-of-scope or file in any dispositions-<k>.json with k < r.
#
# RECOMMENDATION (brief): continue -> grant, unknown -> grant,
# enriching -> accept, quiet -> accept, stalled -> stop. Spend is shown as
# information only and never changes any other field.

_GAIA_LOOP_EVAL_DIR="${BASH_SOURCE[0]%/*}"
[ "$_GAIA_LOOP_EVAL_DIR" = "${BASH_SOURCE[0]}" ] && _GAIA_LOOP_EVAL_DIR="."
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIR/audit-loop-state-lib.sh"

_GAIA_LOOP_CHECKPOINT_DEFAULT=5
_GAIA_LOOP_GRANT_DEFAULT=3
# usage.sh reads every ledger; a slow read must never hold up the checkpoint.
_GAIA_LOOP_SPEND_TIMEOUT=5

# _gaia_loop_live <knob-name>: the live value when set and valid, else rc 1.
_gaia_loop_live() {
  local name="$1" v="" isset=0
  case "$name" in
    GAIA_AUDIT_CHECKPOINT_ROUND) [ "${GAIA_AUDIT_CHECKPOINT_ROUND+x}" = x ] && isset=1 && v="$GAIA_AUDIT_CHECKPOINT_ROUND" ;;
    GAIA_AUDIT_GRANT_ROUNDS) [ "${GAIA_AUDIT_GRANT_ROUNDS+x}" = x ] && isset=1 && v="$GAIA_AUDIT_GRANT_ROUNDS" ;;
  esac
  [ "$isset" -eq 1 ] || return 1
  if gaia_loop_is_uint "$v" && [ "$v" -ge 1 ] && [ "$v" -le 99 ]; then
    printf '%s\n' "$v"
    return 0
  fi
  printf 'audit-loop: ignoring malformed %s=%s (want an integer 1..99)\n' "$name" "$v" >&2
  return 1
}

# gaia_loop_knobs_initial: the knobs a branch freezes at round 1.
gaia_loop_knobs_initial() {
  local cp="$_GAIA_LOOP_CHECKPOINT_DEFAULT" gr="$_GAIA_LOOP_GRANT_DEFAULT" v
  if v="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" && [ "$v" -lt "$cp" ]; then cp="$v"; fi
  if v="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS)" && [ "$v" -lt "$gr" ]; then gr="$v"; fi
  printf '{"checkpoint_round":%s,"grant_rounds":%s}\n' "$cp" "$gr"
}

# gaia_loop_allowed <state-json>: the allowance after folding every answer.
gaia_loop_allowed() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.checkpoint_round // $init.checkpoint_round) as $base
    | .history.checkpoints as $cps
    | if (.allowance.answers | length) == 0 then
        (if $live != null and $live < $base then $live else $base end)
      else
        reduce .allowance.answers[] as $a ($base;
          ([$cps[] | select(.index == $a.checkpoint)] | .[0].at_round) as $g
          | if $g == null then .
            elif $a.kind == "grant" then $g + $a.n
            elif $a.kind == "accept" then $g + 1
            else . end)
      end'
}

# _gaia_loop_grant_rounds <state-json>: the default n the brief prints.
_gaia_loop_grant_rounds() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS 2>/dev/null)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.grant_rounds // $init.grant_rounds) as $b
    | if $live != null and $live < $b then $live else $b end'
}

# gaia_loop_decide <state-json> <r-snapshot-json>: `allow` or `deny <reason>`.
gaia_loop_decide() {
  local state="$1" snap="${2:-null}" used allowed verdict answered
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')" || return 5
  allowed="$(gaia_loop_allowed "$state")" || return 5
  if [ "$used" -ge "$allowed" ]; then
    printf 'deny allowance\n'
    return 0
  fi
  verdict="$(printf '%s' "$snap" | jq -r '.verdict? // empty' 2>/dev/null)" || verdict=""
  case "$verdict" in
    stalled | enriching)
      answered="$(printf '%s' "$state" | jq -r --argjson r "$used" '
        [.history.checkpoints[] | select(.at_round >= $r) | .index] as $ix
        | any(.allowance.answers[]; .checkpoint as $c | any($ix[]; . == $c))')"
      if [ "$answered" != true ]; then
        printf 'deny %s\n' "$verdict"
        return 0
      fi
      ;;
  esac
  printf 'allow\n'
}


# gaia_loop_findings <main-root> <state-json> <r>: F(r) as
# {"round","entries":[...],"missing_members":[...]}.
gaia_loop_findings() {
  local main="$1" state="$2" r="$3" b slug stamp baseline dir m f out newest e
  local entries="[]" missing="[]"
  local -a cands members
  b="$(printf '%s' "$state" | jq -r '.branch')"
  slug="$(printf '%s' "$state" | jq -r --argjson r "$r" '.history.rounds[$r - 1].raw_branch_slug // ""')"
  members=()
  while IFS= read -r m; do members+=("$m"); done < <(printf '%s' "$state" | jq -r --argjson r "$r" '.history.rounds[$r - 1].members[]? | strings')
  stamp="$(gaia_loop_stamp_file "$main" "$b" "$r")"
  baseline="$(gaia_loop_run_dir "$main" "$b")/baseline-$r.json"
  dir="$main/.gaia/local/audit"
  for m in ${members[@]+"${members[@]}"}; do
    newest=""
    # The slug and member are glob text: only the classes gaia_key_slug and
    # the member names emit are let through, anything else is missing evidence.
    if [[ "$slug" =~ ^[A-Za-z0-9_%-]+$ && "$m" =~ ^[A-Za-z0-9_-]+$ ]] && _gaia_loop_keyable "$b" && [ -f "$stamp" ]; then
      cands=()
      if [ -f "$baseline" ]; then
        while IFS= read -r f; do cands+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name "*.$slug.$m.findings.json" -newer "$stamp" ! -newer "$baseline" 2>/dev/null)
      else
        while IFS= read -r f; do cands+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name "*.$slug.$m.findings.json" -newer "$stamp" 2>/dev/null)
      fi
      out=""
      [ "${#cands[@]}" -eq 0 ] || out="$(ls -t -- "${cands[@]}" 2>/dev/null)" || out=""
      newest="${out%%$'\n'*}"
    fi
    e=""
    if [ -n "$newest" ]; then
      e="$(jq -c --arg m "$m" '.findings | if type == "array" then map({member: $m, finding_class, path, line, severity}) else error("no findings") end' <"$newest" 2>/dev/null)" || e=""
    fi
    if [ -n "$e" ]; then
      entries="$(jq -n -c --argjson a "$entries" --argjson b "$e" '$a + $b')"
    else
      missing="$(jq -n -c --argjson a "$missing" --arg m "$m" '$a + [$m]')"
    fi
  done
  jq -n -c --argjson r "$r" --argjson e "$entries" --argjson x "$missing" '{round: $r, entries: $e, missing_members: $x}'
}


# shellcheck disable=SC2016
_GAIA_LOOP_VERDICT_JQ='
def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (startswith("-") | not)
  and ((("/" + . + "/") | contains("/../")) | not) and (contains("\n") | not) and (contains("\u0000") | not);
def valid_line: . == null or (type == "number" and . == floor and . >= 0 and . < 1000000000);
def key: [.member, .finding_class, .path, .line];
def in_hunks($h): .path as $p | .line as $l | any($h[]; .p == $p and .s <= $l and $l <= .e);
def authored:
  if (.path | safe_path | not) or (.line | valid_line | not) or $names == null or $hunks == null then true
  else (.path as $p | any($names[]; . == $p)) and (.line == null or .line == 0 or in_hunks($hunks)) end;
def disposed: key as $k | any($disposed[]; . == $k);
def isnew: key as $k | any(($prevkeys // [])[]; . == $k) | not;
($F.entries | map(select(authored and (disposed | not)))) as $counted
| (if ($F.missing_members | length) > 0 then null else ($counted | length) end) as $A
| ($series + [$A]) as $AS
# Negative indices wrap in jq; the r >= 3 guards below keep them unread.
| $AS[$r - 2] as $A1 | $AS[$r - 3] as $A2
| ($counted | map(select(.line != null and .line > 0 and isnew and in_hunks($ehunks // [])) | key)) as $newrep
| (if $A == null then "unknown"
   elif $A == 0 then "quiet"
   elif $r >= 3 and $r >= $g + 1 and $A1 != null and ($newrep | length) > 0 then "enriching"
   elif $r >= 3 and $r >= $g + 2 and $A2 != null and $A1 != null and $A1 >= $A2 and $A >= $A1 then "stalled"
   else "continue" end) as $v
| {round: $r, merge_base: (if $mb == "" then null else $mb end), keys: ($F.entries | map(key) | unique),
   A: $A, verdict: $v,
   evidence: {members: $members, missing_members: $F.missing_members, new_keys_on_repaired_lines: $newrep, A_series: $AS},
   evaluated_at: $now}
'

# gaia_loop_eval_round <main-root> <state-json> <r>: round r's snapshot.
gaia_loop_eval_round() {
  local main="$1" state="$2" r="$3" ctx tree commit ptree mb="" names="null" hunks="null" ehunks="null" fs disposed
  gaia_loop_is_uint "$r" && [ "$r" -ge 1 ] || return 2
  ctx="$(printf '%s' "$state" | jq -c --argjson r "$r" '
    .history.rounds as $R
    | if $r > ($R | length) then error("no round") else
      ([.allowance.answers[] | select(.kind == "grant")] | last) as $lg
      | {tree: $R[$r - 1].tree, commit: $R[$r - 1].commit, members: ($R[$r - 1].members // []),
         ptree: (if $r >= 2 then $R[$r - 2].tree else "" end),
         prevkeys: (if $r >= 2 then $R[$r - 2].snapshot.keys? else null end),
         series: [$R[0:$r - 1][] | .snapshot.A?],
         g: (if $lg == null then 0 else ([.history.checkpoints[] | select(.index == $lg.checkpoint)] | .[0].at_round // 0) end)}
      end' 2>/dev/null)" || return 2
  tree="$(printf '%s' "$ctx" | jq -r '.tree')"
  commit="$(printf '%s' "$ctx" | jq -r '.commit')"
  ptree="$(printf '%s' "$ctx" | jq -r '.ptree')"
  gaia_loop_is_oid "$tree" && gaia_loop_is_oid "$commit" || return 5
  fs="$(gaia_loop_findings "$main" "$state" "$r")" || return 2
  if mb="$(_gaia_loop_merge_base "$main" "$commit")"; then
    names="$(_gaia_loop_names "$main" "$mb" "$tree" | jq -R -s -c 'split("\n") | map(select(length > 0))')" || names="null"
    hunks="$(_gaia_loop_hunks_json "$main" "$mb" "$tree")"
  else
    mb=""
  fi
  if gaia_loop_is_oid "$ptree"; then
    ehunks="$(_gaia_loop_hunks_json "$main" "$ptree" "$tree")"
  fi
  disposed="$(_gaia_loop_disposed "$main" "$(printf '%s' "$state" | jq -r '.branch')" "$r")"
  jq -n -c --argjson F "$fs" --argjson names "${names:-null}" --argjson hunks "$hunks" \
    --argjson ehunks "$ehunks" --argjson disposed "$disposed" \
    --argjson prevkeys "$(printf '%s' "$ctx" | jq -c '.prevkeys')" \
    --argjson series "$(printf '%s' "$ctx" | jq -c '.series')" \
    --argjson members "$(printf '%s' "$ctx" | jq -c '.members')" \
    --argjson g "$(printf '%s' "$ctx" | jq -r '.g')" --argjson r "$r" \
    --arg mb "$mb" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_GAIA_LOOP_VERDICT_JQ"
}

# _gaia_loop_spend <raw-branch>: usage.sh's text, or `unavailable`. A
# watchdog, not timeout(1), which macOS lacks; `set -m` gives the child its
# own process group so the kill also reaches anything it spawned, which would
# otherwise hold the capture pipe open past the deadline.
_gaia_loop_spend() {
  local out rc=0
  out="$(
    set -m
    bash "$_GAIA_LOOP_EVAL_DIR/usage.sh" pr --branch "$1" </dev/null 2>/dev/null &
    pid=$!
    (sleep "$_GAIA_LOOP_SPEND_TIMEOUT"; kill -TERM -- "-$pid") </dev/null >/dev/null 2>&1 &
    wd=$!
    wait "$pid"
    st=$?
    kill -TERM -- "-$wd" 2>/dev/null
    exit "$st"
  )" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'unavailable'
  else
    printf '%s' "$out"
  fi
}

# _gaia_loop_brief <audited-root> <main-root> <state-json>: the checkpoint
# brief (README C8).
_gaia_loop_brief() {
  local root="$1" main="$2" state="$3" used allowed pending snap fs raw spend per="[]" i s
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  [ "$used" -ge 1 ] || return 2
  allowed="$(gaia_loop_allowed "$state")"
  pending="$(gaia_loop_pending_checkpoint "$state")"
  snap="$(printf '%s' "$state" | jq -c '.history.rounds | last | .snapshot')"
  [ "$snap" = null ] && { snap="$(gaia_loop_eval_round "$main" "$state" "$used")" || return 2; }
  i=1
  while [ "$i" -le "$used" ]; do
    if [ "$i" -eq "$used" ]; then s="$snap"; else s="$(printf '%s' "$state" | jq -c --argjson i "$i" '.history.rounds[$i - 1].snapshot')"; fi
    per="$(printf '%s' "$state" | jq -c --argjson p "$per" --argjson s "$s" --argjson i "$i" \
      '$p + [{round: $i, A: $s.A?, verdict: $s.verdict?, closing: (.history.rounds[$i - 1].closing // false)}]')"
    i=$((i + 1))
  done
  fs="$(gaia_loop_findings "$main" "$state" "$used")"
  raw="$(_gaia_loop_git -C "$root" branch --show-current 2>/dev/null)" || raw=""
  spend="$(_gaia_loop_spend "$raw")"
  jq -n -c --argjson st "$state" --argjson used "$used" --argjson allowed "$allowed" \
    --argjson pending "$([ -n "$pending" ] && echo true || echo false)" --argjson per "$per" \
    --argjson snap "$snap" --argjson fs "$fs" --arg spend "$spend" \
    --arg gl "$(gaia_loop_grant_line "$(_gaia_loop_grant_rounds "$state")")" --arg al "$(gaia_loop_accept_line)" '
    {branch: $st.branch, pr: $st.pr, rounds_run: $used, allowed: $allowed, pending_checkpoint: $pending,
     per_round: $per, verdict: $snap.verdict, evidence: $snap.evidence,
     recommended: ({continue: "grant", unknown: "grant", enriching: "accept", quiet: "accept", stalled: "stop"}
                   | .[$snap.verdict // "unknown"] // "grant"),
     grant_line: $gl, accept_line: $al,
     remaining_by_severity: ($fs.entries | {error: map(select(.severity == "error")) | length,
                                            warning: map(select(.severity == "warning")) | length,
                                            suggestion: map(select(.severity == "suggestion")) | length}),
     spend: $spend, spend_note: "information only"}'
}

_gaia_loop_usage() {
  printf 'usage: audit-loop-eval.sh findings|eval|brief|record-values|state-path|current-round --root <audited-root> [--round <r>]\n' >&2
  return 2
}

_gaia_loop_cli() {
  local sub="${1-}" root="" round="" b main file state rc used
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; root="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; round="$2"; shift 2 ;;
      *) _gaia_loop_usage; return 2 ;;
    esac
  done
  case "$sub" in findings | eval | brief | record-values | state-path | current-round) ;; *) _gaia_loop_usage; return 2 ;; esac
  case "$root" in /*) ;; *) printf 'audit-loop-eval: --root must be an absolute path\n' >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6; }
  command -v git >/dev/null 2>&1 || { printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6; }
  rc=0
  b="$(gaia_loop_key "$root")" || rc=$?
  case "$rc" in
    0) ;;
    4) printf 'audit-loop-eval: detached HEAD at %s has no branch key\n' "$root" >&2; return 4 ;;
    6) printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: the branch at %s is not keyable\n' "$root" >&2; return 5 ;;
  esac
  main="$(gaia_resolve_main_root "$root" 2>/dev/null)" || { printf 'audit-loop-eval: cannot resolve the main checkout of %s\n' "$root" >&2; return 2; }
  file="$(gaia_loop_state_file "$main" "$b")"
  if [ "$sub" = state-path ]; then printf '%s\n' "$file"; return 0; fi
  rc=0
  state="$(gaia_loop_read_state "$file")" || rc=$?
  case "$rc" in
    0) ;;
    1)
      case "$sub" in
        current-round) printf '0\n'; return 0 ;;
        record-values) printf '{"total":0,"members":{},"grants":0}\n'; return 0 ;;
      esac
      printf 'audit-loop-eval: no recorded round for %s\n' "$b" >&2
      return 2
      ;;
    6) printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: corrupt state file %s\n' "$file" >&2; return 5 ;;
  esac
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  case "$sub" in
    current-round) printf '%s\n' "$used"; return 0 ;;
    record-values)
      printf '%s' "$state" | jq -c '{total: (.history.rounds | length),
        members: (reduce .history.rounds[] as $x ({}; reduce ($x.members[]) as $m (.; .[$m] += [$x.tree]))
                  | map_values(unique | length) | to_entries | sort_by(.key) | from_entries),
        grants: ([.allowance.answers[] | select(.kind == "grant")] | length)}'
      return 0
      ;;
    brief) _gaia_loop_brief "$root" "$main" "$state"; return $? ;;
  esac
  [ -n "$round" ] || round="$used"
  if ! gaia_loop_is_uint "$round" || [ "$round" -lt 1 ] || [ "$round" -gt "$used" ]; then
    printf 'audit-loop-eval: no recorded round %s for %s\n' "$round" "$b" >&2
    return 2
  fi
  if [ "$sub" = findings ]; then gaia_loop_findings "$main" "$state" "$round"; return $?; fi
  gaia_loop_eval_round "$main" "$state" "$round"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  _gaia_loop_cli "$@"
  exit $?
fi
