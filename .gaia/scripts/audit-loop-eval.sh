#!/usr/bin/env bash
# shellcheck shell=bash
#
# Audit loop evaluator: the single owner of the loop's round-count defaults,
# the allowance fold, the verdict and rubric-signal formulas, the gate
# decisions and the checkpoint recommendation. The PR Merge Workflow page and
# the hooks point here rather than restating any of them. The context line,
# the statusline bands and K (rounds per unit) are owned by
# context-checkpoint-lib.sh, sourced here. The signal block and the decision
# functions are implemented in audit-loop-signals-lib.sh, also sourced here;
# their formulas are the ones below.
#
# Dual-mode. Sourced (audit-loop-bound.sh), it defines functions only:
#   gaia_loop_eval_round <main-root> <state-json> <r>   the snapshot for round r
#   gaia_loop_findings <main-root> <state-json> <r>     F(r)
#   gaia_loop_allowed <state-json>                      the round-count allowance
#   gaia_loop_decide <state-json> <r-snapshot-json>     `allow` or `deny <reason>`
#   gaia_loop_decide_unit, gaia_loop_decide_member      see DECISION
#   gaia_loop_knobs_initial                             knobs frozen at round 1
#   gaia_loop_context_config_initial <main-root>        line config frozen at round 1
#   gaia_loop_context_config_effective <main-root> <state-json>
# Run (the main thread), it is a read-only CLI: it never writes a file, never
# takes the state lock, never calls gaia_loop_write_state.
#   audit-loop-eval.sh findings|eval|brief|record-values|state-path|current-round
#                      |next-unit|unit-window|pinned-question
#                      --root <audited-root> [--round <r>]
# Exit 0 ok, 2 usage or no recorded round (unit-window: no unit;
# pinned-question: no pending pinned question), 4 detached HEAD, 5 corrupt
# state, an unreadable vetoes.json, or a branch that is not keyable, 6 jq or
# git missing.
#
# DEFAULTS. Checkpoint round 6, grant 3, hard cap 10. The round-count
# checkpoint decides only when no fresh context reading exists; the context
# line is the primary gate. 6 is unit-aligned (two units of 3), and in the
# round distribution measured when this was written 6.7% of branches needed
# more than 5 rounds and 1.8% more than 6, so it interrupts only the long tail;
# the signals below catch non-convergence earlier. A grant of 3 is the
# smallest that lets both evidence windows below see fresh rounds before the
# next checkpoint. The cap: a dispatch that would start round 11 is denied
# whatever was granted.
#
# KNOBS. GAIA_AUDIT_CHECKPOINT_ROUND and GAIA_AUDIT_GRANT_ROUNDS remain, as
# lower-only knobs for the round-count fallback only, integers 1..99; anything
# else is ignored with a stderr note. At round 1 the bound hook freezes them
# into `history.knobs`, each capped at its default: a raised value is never
# honoured, because `.claude/settings*.json` `env` is editable by the session
# the bound exists to stop. Afterwards a live checkpoint value may only lower
# the frozen one, and only while no answer is recorded. A branch frozen at the
# old checkpoint 5 keeps 5. The context line has its own lower-only override
# in context-checkpoint-lib.sh; its config values (never a token count) are
# frozen into `history.context_config` as the per-field min of the lib
# defaults and the override, and the effective config is the per-field min of
# that frozen value and the live override, so a lowering applies live and a
# raise never does. A branch with no frozen config reads the initial one.
#
# ALLOWANCE. base = the frozen checkpoint round (lowered as above). Answers
# fold in order: a grant of n answering the checkpoint at round g sets
# allowed = g + n; an accept answering the checkpoint at round c sets
# allowed = c + 1 and makes that next round the closing round. used = recorded
# rounds, every verdict counted (an unknown round included, so deleting a
# sidecar never buys a round). The fold is uncapped (a grant of 10 at round 5
# folds to 15): the hard cap is a decision rule, applied below.
#
# DECISION. No decision function reads a file: the bound hook passes the
# context reading (exactly what gaia_ctx_read printed) and the effective line
# config. s = used + 1; k = K; <elig> is the snapshot's accept_eligible (false
# with no snapshot). The order of the steps is the security property.
#   gaia_loop_decide (a new-tree dispatch outside the unit protocol): deny
#   `cap` when used >= 10; deny `allowance` when used >= allowed; else deny
#   `stalled` or `enriching` when that is round r = used's verdict and no
#   answer exists for a checkpoint at round >= r; else allow.
#   gaia_loop_decide_unit, first match wins:
#     1. used >= 10: `deny cap <elig> true`.
#     2. a denying signal on the snapshot, none of whose checkpoints at round
#        >= used is answered: `deny rubric:<signal> <elig> false`, the first in
#        SIGNALS order.
#     3. the latest checkpoint is answered and its index is greater than the
#        latest unit's after_checkpoint (or no unit exists): a grant gives
#        `allow grant s min(s+k-1, 10)`, an accept `allow accept s s`. An
#        answer admits one unit; the next unit dispatch evaluates every
#        trigger afresh.
#     4. a `fresh <tokens> <window>` reading: tokens >= the line computed
#        against that reading's own window denies `context <elig> false`;
#        else `allow context s min(s+k-1, 10)`.
#     5. any other reading: the fallback fold, `deny fallback <elig> false`
#        when used >= allowed, else `allow fallback s min(s+k-1, 10, allowed)`.
#   gaia_loop_decide_member, in a unit: used >= 10 denies `cap` first; then
#   the latest unit's through_round must reach s, else `deny window`; then a
#   denying signal unanswered denies as in step 2; else `allow`. Inline (no
#   unit, nesting unavailable): gaia_loop_decide_unit with k = 1.
#   A window can start off a 3-round boundary after a unit stops early;
#   nothing here assumes alignment.
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
# SIGNALS for round r, each independent, in this order:
#   cap           r >= 10.
#   quiet         the verdict is quiet. The one signal that never denies: the
#                 loop ends on its own.
#   enriching     the verdict is enriching.
#   stalled       the verdict is stalled.
#   nitpicky      r >= 6, and A(r) and A(r-1) are both non-empty with every
#                 entry of each severity suggestion.
#   reintroduced  r >= 3, A(r), A(r-1), A(r-2) non-null, and either a key of
#                 A(r-2) is absent from A(r-1) and back in A(r), or some
#                 (member, finding_class, path) is in all three with its line
#                 set disjoint between consecutive rounds (it moved each round).
#   small-tail    r >= 6, 1 <= A(r) <= 2, no A(r) entry is severity error,
#                 A(r-1) non-null and A(r) >= A(r-1) (no progress last round).
# gaia:maintainer-only:start
#   waiver-drift  maintainer repo only (<main>/.claude/rules/maintainers/
#                 harness-triage-threshold.md exists), r >= 2, and in each of
#                 rounds r and r-1 at least half of F's entries (raw_count > 0)
#                 are disposed waive-out-of-scope with basis triage-threshold
#                 in that round's own dispositions file (waived_count).
# gaia:maintainer-only:end
# accept_eligible: some signal holds, no A(r) entry is severity error or
# security true, the verdict is not unknown, and no stored snapshot a signal
# reads is legacy. accept_reasons: exactly the signals that hold. Severity is
# the sidecar vocabulary: error (Critical), warning (Important), suggestion
# (Suggestion). An entry's security reads true unless the sidecar holds the
# boolean false (absent or non-boolean reads true); cross_remit is true only
# when the sidecar holds true. A(r-1), A(r-2) and their counted_keys,
# raw_count and waived_count come from the stored snapshots, never
# recomputed. A stored snapshot without counted_keys predates the signals:
# nitpicky, reintroduced, small-tail and waiver-drift stay off where they need
# it, and accept_eligible is false.
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
# waive-out-of-scope or file in any dispositions-<k>.json with k < r, except
# a key listed in <RUN_FOLDER>/vetoes.json with effective_from_round <= r,
# which stays counted whatever was disposed. An absent vetoes.json vetoes
# nothing; an unreadable one fails the evaluation, since dropping a veto
# would count fewer findings.
#
# RECOMMENDATION (brief): continue -> grant, unknown -> grant,
# enriching -> accept, quiet -> accept, stalled -> stop; at a pending
# checkpoint whose trigger is context, grant unless a denying signal holds.
# Spend is shown as information only and never changes any other field.

_GAIA_LOOP_EVAL_DIR="${BASH_SOURCE[0]%/*}"
[ "$_GAIA_LOOP_EVAL_DIR" = "${BASH_SOURCE[0]}" ] && _GAIA_LOOP_EVAL_DIR="."
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIR/audit-loop-state-lib.sh"
# A missing sibling must fail the source: the bound hook reads a failed source
# as a lib-load deny, while a silent miss would leave the gate functions
# undefined.
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIR/context-checkpoint-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIR/audit-loop-signals-lib.sh" || return 6 2>/dev/null || exit 6

_GAIA_LOOP_CHECKPOINT_DEFAULT=6
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
  if [ "$used" -ge "$_GAIA_LOOP_HARD_CAP" ]; then
    printf 'deny cap\n'
    return 0
  fi
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

# gaia_loop_context_config_initial <main-root>: the line config a branch
# freezes, as {"ask_tokens","ask_window_pct"}.
gaia_loop_context_config_initial() {
  local tokens pct
  read -r tokens pct <<<"$(gaia_ctx_override "$1")"
  tokens="$(_gaia_loop_min "$tokens" "$GAIA_CTX_ASK_TOKENS_DEFAULT")"
  pct="$(_gaia_loop_min "$pct" "$GAIA_CTX_ASK_WINDOW_PCT_DEFAULT")"
  printf '{"ask_tokens":%s,"ask_window_pct":%s}\n' "$tokens" "$pct"
}

# gaia_loop_context_config_effective <main-root> <state-json>: prints
# `<ask_tokens> <ask_window_pct>`; rc 5 when the state cannot be read.
gaia_loop_context_config_effective() {
  local init frozen live_tokens live_pct tokens pct int='^[1-9][0-9]{0,11} [1-9][0-9]{0,11}$'
  init="$(gaia_loop_context_config_initial "$1")"
  frozen="$(printf '%s' "$2" | jq -r --argjson i "$init" '
    def pos: type == "number" and . == floor and . >= 1;
    (.history.context_config | if type == "object" then . else {} end) as $c
    | "\(if ($c.ask_tokens | pos) then $c.ask_tokens else $i.ask_tokens end) \(if ($c.ask_window_pct | pos) then $c.ask_window_pct else $i.ask_window_pct end)"' 2>/dev/null)" || return 5
  [[ $frozen =~ $int ]] || return 5
  read -r tokens pct <<<"$frozen"
  read -r live_tokens live_pct <<<"$(gaia_ctx_override "$1")"
  printf '%s %s\n' "$(_gaia_loop_min "$tokens" "$live_tokens")" "$(_gaia_loop_min "$pct" "$live_pct")"
}

# jq defs shared by the finding set and the snapshot. $names and $hunks are
# round r's changed paths and new-side hunks against its merge base, null when
# the merge base cannot be computed.
# shellcheck disable=SC2016
_GAIA_LOOP_AUTHORED_JQ='
def safe_path: type == "string" and length > 0 and (startswith("/") | not) and (startswith("-") | not)
  and ((("/" + . + "/") | contains("/../")) | not) and (contains("\n") | not) and (contains("\u0000") | not);
def valid_line: . == null or (type == "number" and . == floor and . >= 0 and . < 1000000000);
def key: [.member, .finding_class, .path, .line];
def in_hunks($h): .path as $p | .line as $l | any($h[]; .p == $p and .s <= $l and $l <= .e);
def authored($names; $hunks):
  if (.path | safe_path | not) or (.line | valid_line | not) or $names == null or $hunks == null then true
  else (.path as $p | any($names[]; . == $p)) and (.line == null or .line == 0 or in_hunks($hunks)) end;
'

# _gaia_loop_authorship <main-root> <state-json> <r>: round r's
# {"mb","names","hunks"}; mb is "" and the rest null without a merge base.
_gaia_loop_authorship() {
  local main="$1" r="$3" tree commit mb names=null hunks=null
  tree="$(printf '%s' "$2" | jq -r --argjson r "$r" '.history.rounds[$r - 1].tree // ""' 2>/dev/null)" || tree=""
  commit="$(printf '%s' "$2" | jq -r --argjson r "$r" '.history.rounds[$r - 1].commit // ""' 2>/dev/null)" || commit=""
  if gaia_loop_is_oid "$tree" && mb="$(_gaia_loop_merge_base "$main" "$commit")"; then
    names="$(_gaia_loop_names "$main" "$mb" "$tree" | jq -R -s -c 'split("\n") | map(select(length > 0))')" || names="null"
    hunks="$(_gaia_loop_hunks_json "$main" "$mb" "$tree")"
  else
    mb=""
  fi
  jq -n -c --arg mb "$mb" --argjson names "${names:-null}" --argjson hunks "${hunks:-null}" \
    '{mb: $mb, names: $names, hunks: $hunks}'
}

# _gaia_loop_annotate <F-json> <authorship-json>: F with `authored` on every entry.
_gaia_loop_annotate() {
  jq -n -c --argjson F "$1" --argjson au "$2" "$_GAIA_LOOP_AUTHORED_JQ"'
    $F | .entries |= map(. + {authored: authored($au.names; $au.hunks)})'
}

# _gaia_loop_vetoed <main-root> <B> <r>: identity keys vetoed for round r
# (effective_from_round <= r). rc 1 on an unreadable or malformed file.
_gaia_loop_vetoed() {
  local f out
  f="$(gaia_loop_run_dir "$1" "$2")/vetoes.json"
  [ -e "$f" ] || { printf '[]\n'; return 0; }
  out="$(jq -c -s --argjson r "$3" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then [.[0].keys[] | select(.effective_from_round <= $r) | [.member, .finding_class, .path, .line]]
    else error("malformed vetoes.json") end' <"$f" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _gaia_loop_waived_keys <main-root> <B> <r>: identity keys round r's own
# dispositions file waives on the triage threshold. Unreadable reads as none.
_gaia_loop_waived_keys() {
  local f out
  f="$(gaia_loop_run_dir "$1" "$2")/dispositions-$3.json"
  [ -f "$f" ] || { printf '[]\n'; return 0; }
  out="$(jq -c '[.entries[] | select(.disposition == "waive-out-of-scope" and .basis == "triage-threshold")
    | [.member, .finding_class, .path, .line]]' <"$f" 2>/dev/null)" || out=""
  [ -n "$out" ] && printf '%s\n' "$out" || printf '[]\n'
}

# _gaia_loop_raw_findings <main-root> <state-json> <r>: F(r) before authorship.
_gaia_loop_raw_findings() {
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
      # Never `.security // true`: `//` treats false as absent, so every
      # security:false finding would read true.
      e="$(jq -c --arg m "$m" '.findings | if type == "array" then map({member: $m, finding_class, path, line, severity,
        security: (if (.security | type) == "boolean" then .security else true end),
        cross_remit: (.cross_remit == true)}) else error("no findings") end' <"$newest" 2>/dev/null)" || e=""
    fi
    if [ -n "$e" ]; then
      entries="$(jq -n -c --argjson a "$entries" --argjson b "$e" '$a + $b')"
    else
      missing="$(jq -n -c --argjson a "$missing" --arg m "$m" '$a + [$m]')"
    fi
  done
  jq -n -c --argjson r "$r" --argjson e "$entries" --argjson x "$missing" '{round: $r, entries: $e, missing_members: $x}'
}

# gaia_loop_findings <main-root> <state-json> <r>: F(r) as
# {"round","entries":[...],"missing_members":[...]}, each entry
# {member, finding_class, path, line, severity, security, cross_remit, authored}.
gaia_loop_findings() {
  local fs au
  fs="$(_gaia_loop_raw_findings "$1" "$2" "$3")" || return 2
  au="$(_gaia_loop_authorship "$1" "$2" "$3")" || return 2
  _gaia_loop_annotate "$fs" "$au"
}

# shellcheck disable=SC2016
_GAIA_LOOP_VERDICT_JQ='
def disposed: key as $k | any($disposed[]; . == $k);
def isnew: key as $k | any(($prevkeys // [])[]; . == $k) | not;
($F.entries | map(select(.authored and (disposed | not)))) as $counted
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
'"$_GAIA_LOOP_SIGNALS_JQ"'
| {round: $r, merge_base: (if $mb == "" then null else $mb end), keys: ($F.entries | map(key) | unique),
   A: $A, verdict: $v,
   counted_keys: $ck, raw_count: $raw, waived_count: $waived,
   signals: $sig, accept_eligible: $elig, accept_reasons: $reasons,
   evidence: {members: $members, missing_members: $F.missing_members, new_keys_on_repaired_lines: $newrep, A_series: $AS},
   evaluated_at: $now}
'

# gaia_loop_eval_round <main-root> <state-json> <r>: round r's snapshot.
# rc 2 no such round, 5 a bad round record or an unreadable vetoes.json.
gaia_loop_eval_round() {
  local main="$1" state="$2" r="$3" b ctx tree commit ptree au ehunks="null" fs disposed vetoed waived maint=false
  gaia_loop_is_uint "$r" && [ "$r" -ge 1 ] || return 2
  ctx="$(printf '%s' "$state" | jq -c --argjson r "$r" '
    .history.rounds as $R
    | if $r > ($R | length) then error("no round") else
      ([.allowance.answers[] | select(.kind == "grant")] | last) as $lg
      | {tree: $R[$r - 1].tree, commit: $R[$r - 1].commit, members: ($R[$r - 1].members // []),
         ptree: (if $r >= 2 then $R[$r - 2].tree else "" end),
         prevkeys: (if $r >= 2 then $R[$r - 2].snapshot.keys? else null end),
         p1: (if $r >= 2 then $R[$r - 2].snapshot else null end),
         p2: (if $r >= 3 then $R[$r - 3].snapshot else null end),
         series: [$R[0:$r - 1][] | .snapshot.A?],
         g: (if $lg == null then 0 else ([.history.checkpoints[] | select(.index == $lg.checkpoint)] | .[0].at_round // 0) end)}
      end' 2>/dev/null)" || return 2
  tree="$(printf '%s' "$ctx" | jq -r '.tree')"
  commit="$(printf '%s' "$ctx" | jq -r '.commit')"
  ptree="$(printf '%s' "$ctx" | jq -r '.ptree')"
  gaia_loop_is_oid "$tree" && gaia_loop_is_oid "$commit" || return 5
  b="$(printf '%s' "$state" | jq -r '.branch')"
  vetoed="$(_gaia_loop_vetoed "$main" "$b" "$r")" || return 5
  fs="$(_gaia_loop_raw_findings "$main" "$state" "$r")" || return 2
  au="$(_gaia_loop_authorship "$main" "$state" "$r")" || return 2
  fs="$(_gaia_loop_annotate "$fs" "$au")" || return 2
  if gaia_loop_is_oid "$ptree"; then
    ehunks="$(_gaia_loop_hunks_json "$main" "$ptree" "$tree")"
  fi
  disposed="$(_gaia_loop_disposed "$main" "$b" "$r" | jq -c --argjson v "$vetoed" 'map(select(. as $k | any($v[]; . == $k) | not))')" || return 5
  waived="$(_gaia_loop_waived_keys "$main" "$b" "$r")"
  # gaia:maintainer-only:start
  [ -f "$main/.claude/rules/maintainers/harness-triage-threshold.md" ] && maint=true
  # gaia:maintainer-only:end
  jq -n -c --argjson F "$fs" --argjson ehunks "$ehunks" --argjson disposed "$disposed" \
    --argjson prevkeys "$(printf '%s' "$ctx" | jq -c '.prevkeys')" \
    --argjson series "$(printf '%s' "$ctx" | jq -c '.series')" \
    --argjson members "$(printf '%s' "$ctx" | jq -c '.members')" \
    --argjson p1 "$(printf '%s' "$ctx" | jq -c '.p1')" --argjson p2 "$(printf '%s' "$ctx" | jq -c '.p2')" \
    --argjson waivedkeys "$waived" --argjson maint "$maint" \
    --argjson g "$(printf '%s' "$ctx" | jq -r '.g')" --argjson r "$r" \
    --arg mb "$(printf '%s' "$au" | jq -r '.mb')" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$_GAIA_LOOP_AUTHORED_JQ $_GAIA_LOOP_VERDICT_JQ"
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
    --argjson pc "${pending:-null}" --argjson cap "$_GAIA_LOOP_HARD_CAP" \
    --argjson snap "$snap" --argjson fs "$fs" --arg spend "$spend" \
    --arg rec "$(gaia_loop_recommended "$(printf '%s' "${pending:-null}" | jq -r '.trigger // empty')" "$snap")" \
    --arg gl "$(gaia_loop_grant_line "$(_gaia_loop_grant_rounds "$state")")" --arg al "$(gaia_loop_accept_line)" '
    {branch: $st.branch, pr: $st.pr, rounds_run: $used, allowed: $allowed, pending_checkpoint: $pending,
     per_round: $per, verdict: $snap.verdict, evidence: $snap.evidence,
     signals: ($snap.signals // null), accept_eligible: ($snap.accept_eligible == true),
     accept_reasons: ($snap.accept_reasons // []), rounds_cap: $cap,
     recommended: $rec,
     grant_line: $gl, accept_line: $al,
     remaining_by_severity: ($fs.entries | {error: map(select(.severity == "error")) | length,
                                            warning: map(select(.severity == "warning")) | length,
                                            suggestion: map(select(.severity == "suggestion")) | length}),
     spend: $spend, spend_note: "information only"}'
}

_gaia_loop_usage() {
  printf 'usage: audit-loop-eval.sh findings|eval|brief|record-values|state-path|current-round|next-unit|unit-window|pinned-question --root <audited-root> [--round <r>]\n' >&2
  return 2
}

_gaia_loop_cli() {
  local sub="${1-}" root="" round="" b main file state rc used out
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; root="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; round="$2"; shift 2 ;;
      *) _gaia_loop_usage; return 2 ;;
    esac
  done
  case "$sub" in
    findings | eval | brief | record-values | state-path | current-round | next-unit | unit-window | pinned-question) ;;
    *) _gaia_loop_usage; return 2 ;;
  esac
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
        next-unit) printf '1 1\n'; return 0 ;;
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
    next-unit)
      printf '%s' "$state" | jq -r '"\(((.history.units // []) | length) + 1) \((.history.rounds | length) + 1)"'
      return 0
      ;;
    unit-window)
      out="$(printf '%s' "$state" | jq -r '(.history.units // []) | last
        | if . == null then empty else "\(.unit) \(.start_round) \(.through_round)" end')"
      [ -n "$out" ] || { printf 'audit-loop-eval: no unit recorded for %s\n' "$b" >&2; return 2; }
      printf '%s\n' "$out"
      return 0
      ;;
    pinned-question)
      out="$(gaia_loop_pending_checkpoint "$state" | jq -c 'select(.question != null) | .question')"
      [ -n "$out" ] || { printf 'audit-loop-eval: no pending pinned question for %s\n' "$b" >&2; return 2; }
      printf '%s\n' "$out"
      return 0
      ;;
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
