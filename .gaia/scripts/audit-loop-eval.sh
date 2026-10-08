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
#   gaia_loop_evaluate_round <main-root> <state-json> <r>   the snapshot for round r
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
# unit-window prints `<unit> <start_round> <through_round> <closing>` for the
# latest unit; closing is `true` when an accept admitted it, so its one round
# is the closing round and audit-loop-unit runs no fixer in it.
# record-values adds an optional `light` object of per-member light review
# counts, read from the branch's light-review ledger; it is left out when the
# ledger is absent, unreadable or empty, and `total` never includes it.
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
# next checkpoint. The cap: a unit admitted below round 10 ends at round 10,
# and past it every unit needs a human answer to the checkpoint the cap pins,
# whatever the context line or the fold says.
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
# context reading (exactly what gaia_context_read printed) and the effective line
# config. s = used + 1; k = K; <eligible> is the snapshot's accept_eligible (false
# with no snapshot). The order of the steps is the security property.
#   gaia_loop_decide (a new-tree dispatch outside the unit protocol): deny
#   `cap` when used >= 10; deny `allowance` when used >= allowed; else deny
#   `stalled` or `enriching` when that is round r = used's verdict and no
#   answer exists for a checkpoint at round >= r; else allow.
#   gaia_loop_decide_unit, first match wins:
#     1. used >= 10: the latest checkpoint's unconsumed answer (as in step 3)
#        admits one unit, a grant `allow grant s s+k-1` and an accept `allow
#        accept s s`; with none, `deny cap <eligible> true`.
#     2. a denying signal on the snapshot, none of whose checkpoints at round
#        >= used is answered: `deny rubric:<signal> <eligible> false`, the first in
#        SIGNALS order.
#     3. the latest checkpoint is answered and its index is greater than the
#        latest unit's after_checkpoint (or no unit exists): a grant gives
#        `allow grant s min(s+k-1, 10)`, an accept `allow accept s s`. An
#        answer admits one unit; the next unit dispatch evaluates every
#        trigger afresh.
#     4. the latest answer is an accept and a round is recorded after the
#        checkpoint it answers (its closing round is spent): `deny fallback
#        <eligible> false`, whatever the reading. An accept never re-arms the loop.
#     5. a `fresh <tokens> <window>` reading: tokens >= the line computed
#        against that reading's own window denies `context <eligible> false`;
#        else `allow context s min(s+k-1, 10)`.
#     6. any other reading: the fallback fold, `deny fallback <eligible> false`
#        when used >= allowed, else `allow fallback s min(s+k-1, 10, allowed)`.
#   gaia_loop_decide_member, in a unit: used >= 10 denies `cap` first unless
#   the latest unit runs past round 10 (an answer admitted it there); then
#   the latest unit's through_round must reach s, else `deny window`; then a
#   denying signal unanswered denies as in step 2; else `allow`. A member
#   dispatched outside a unit is judged by gaia_loop_decide_unit with k = 1, a
#   fail-safe bound on a stray direct dispatch, not a supported way to run
#   the loop.
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
#              A(r-2) >= 1, A(r-1) >= A(r-2) and A(r) >= A(r-1). A quiet
#              round resets the window: a series that sits at zero and then
#              reports one finding (0, 0, 1) is convergence, not a stall.
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
# waive-out-of-scope, file or divert in any dispositions-<k>.json with k < r, except
# a key listed in <RUN_FOLDER>/vetoes.json with effective_from_round <= r,
# which stays counted whatever was disposed. An absent vetoes.json vetoes
# nothing; an unreadable one fails the evaluation, since dropping a veto
# would count fewer findings.
#
# RECOMMENDATION (brief): continue -> grant, unknown -> grant,
# enriching -> accept, quiet -> accept, stalled -> stop, except that a stalled
# round where small-tail holds and the snapshot is accept_eligible -> accept
# (what remains is a tail the evaluator already judges acceptable, and stop
# would leave the PR open over it); at a pending checkpoint whose trigger is
# context, grant unless a denying signal holds.
# Spend is shown as information only and never changes any other field.

_GAIA_LOOP_EVAL_DIRECTORY="${BASH_SOURCE[0]%/*}"
[ "$_GAIA_LOOP_EVAL_DIRECTORY" = "${BASH_SOURCE[0]}" ] && _GAIA_LOOP_EVAL_DIRECTORY="."
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-state-lib.sh"
# A missing sibling must fail the source: the bound hook reads a failed source
# as a lib-load deny, while a silent miss would leave the gate functions
# undefined.
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/context-checkpoint-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-signals-lib.sh" || return 6 2>/dev/null || exit 6

_GAIA_LOOP_CHECKPOINT_DEFAULT=6
_GAIA_LOOP_GRANT_DEFAULT=3
# usage.sh reads every ledger; a slow read must never hold up the checkpoint.
_GAIA_LOOP_SPEND_TIMEOUT=5

# _gaia_loop_live <knob-name>: the live value when set and valid, else rc 1.
_gaia_loop_live() {
  local name="$1" value="" isset=0
  case "$name" in
    GAIA_AUDIT_CHECKPOINT_ROUND) [ "${GAIA_AUDIT_CHECKPOINT_ROUND+x}" = x ] && isset=1 && value="$GAIA_AUDIT_CHECKPOINT_ROUND" ;;
    GAIA_AUDIT_GRANT_ROUNDS) [ "${GAIA_AUDIT_GRANT_ROUNDS+x}" = x ] && isset=1 && value="$GAIA_AUDIT_GRANT_ROUNDS" ;;
  esac
  [ "$isset" -eq 1 ] || return 1
  if gaia_loop_is_uint "$value" && [ "$value" -ge 1 ] && [ "$value" -le 99 ]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf 'audit-loop: ignoring malformed %s=%s (want an integer 1..99)\n' "$name" "$value" >&2
  return 1
}

# gaia_loop_knobs_initial: the knobs a branch freezes at round 1.
gaia_loop_knobs_initial() {
  local checkpoint_round="$_GAIA_LOOP_CHECKPOINT_DEFAULT" grant_rounds="$_GAIA_LOOP_GRANT_DEFAULT" value
  if value="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" && [ "$value" -lt "$checkpoint_round" ]; then checkpoint_round="$value"; fi
  if value="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS)" && [ "$value" -lt "$grant_rounds" ]; then grant_rounds="$value"; fi
  printf '{"checkpoint_round":%s,"grant_rounds":%s}\n' "$checkpoint_round" "$grant_rounds"
}

# gaia_loop_allowed <state-json>: the allowance after folding every answer.
gaia_loop_allowed() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_CHECKPOINT_ROUND)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.checkpoint_round // $init.checkpoint_round) as $base
    | .history.checkpoints as $checkpoints
    | if (.allowance.answers | length) == 0 then
        (if $live != null and $live < $base then $live else $base end)
      else
        reduce .allowance.answers[] as $answer ($base;
          ([$checkpoints[] | select(.index == $answer.checkpoint)] | .[0].at_round) as $answered_round
          | if $answered_round == null then .
            elif $answer.kind == "grant" then $answered_round + $answer.n
            elif $answer.kind == "accept" then $answered_round + 1
            else . end)
      end'
}

# _gaia_loop_grant_rounds <state-json>: the default n the brief prints.
_gaia_loop_grant_rounds() {
  local init live
  init="$(gaia_loop_knobs_initial 2>/dev/null)"
  live="$(_gaia_loop_live GAIA_AUDIT_GRANT_ROUNDS 2>/dev/null)" || live=null
  printf '%s' "$1" | jq -r --argjson init "$init" --argjson live "$live" '
    (.history.knobs.grant_rounds // $init.grant_rounds) as $base
    | if $live != null and $live < $base then $live else $base end'
}

# gaia_loop_decide <state-json> <r-snapshot-json>: `allow` or `deny <reason>`.
gaia_loop_decide() {
  local state="$1" snapshot="${2:-null}" used allowed verdict answered
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
  verdict="$(printf '%s' "$snapshot" | jq -r '.verdict? // empty' 2>/dev/null)" || verdict=""
  case "$verdict" in
    stalled | enriching)
      answered="$(printf '%s' "$state" | jq -r --argjson round "$used" '
        [.history.checkpoints[] | select(.at_round >= $round) | .index] as $indexes
        | any(.allowance.answers[]; .checkpoint as $checkpoint | any($indexes[]; . == $checkpoint))')"
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
  local tokens percent
  read -r tokens percent <<<"$(gaia_context_override "$1")"
  tokens="$(_gaia_loop_minimum "$tokens" "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT")"
  percent="$(_gaia_loop_minimum "$percent" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT")"
  printf '{"ask_tokens":%s,"ask_window_pct":%s}\n' "$tokens" "$percent"
}

# gaia_loop_context_config_effective <main-root> <state-json>: prints
# `<ask_tokens> <ask_window_pct>`; rc 5 when the state cannot be read.
gaia_loop_context_config_effective() {
  local init frozen live_tokens live_percent tokens percent integer_pattern='^[1-9][0-9]{0,11} [1-9][0-9]{0,11}$'
  init="$(gaia_loop_context_config_initial "$1")"
  frozen="$(printf '%s' "$2" | jq -r --argjson initial "$init" '
    def positive_integer: type == "number" and . == floor and . >= 1;
    (.history.context_config | if type == "object" then . else {} end) as $config
    | "\(if ($config.ask_tokens | positive_integer) then $config.ask_tokens else $initial.ask_tokens end) \(if ($config.ask_window_pct | positive_integer) then $config.ask_window_pct else $initial.ask_window_pct end)"' 2>/dev/null)" || return 5
  [[ $frozen =~ $integer_pattern ]] || return 5
  read -r tokens percent <<<"$frozen"
  read -r live_tokens live_percent <<<"$(gaia_context_override "$1")"
  printf '%s %s\n' "$(_gaia_loop_minimum "$tokens" "$live_tokens")" "$(_gaia_loop_minimum "$percent" "$live_percent")"
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
def in_hunks($hunks): .path as $entry_path | .line as $entry_line | any($hunks[]; .p == $entry_path and .s <= $entry_line and $entry_line <= .e);
def authored($names; $hunks):
  if (.path | safe_path | not) or (.line | valid_line | not) or $names == null or $hunks == null then true
  else (.path as $entry_path | any($names[]; . == $entry_path)) and (.line == null or .line == 0 or in_hunks($hunks)) end;
'

# _gaia_loop_authorship <main-root> <state-json> <r>: round r's
# {"mb","names","hunks"}; mb is "" and the rest null without a merge base.
_gaia_loop_authorship() {
  local main="$1" round="$3" tree commit merge_base names=null hunks=null
  tree="$(printf '%s' "$2" | jq -r --argjson round "$round" '.history.rounds[$round - 1].tree // ""' 2>/dev/null)" || tree=""
  commit="$(printf '%s' "$2" | jq -r --argjson round "$round" '.history.rounds[$round - 1].commit // ""' 2>/dev/null)" || commit=""
  if gaia_loop_is_oid "$tree" && merge_base="$(_gaia_loop_merge_base "$main" "$commit")"; then
    names="$(_gaia_loop_names "$main" "$merge_base" "$tree" | jq -R -s -c 'split("\n") | map(select(length > 0))')" || names="null"
    hunks="$(_gaia_loop_hunks_json "$main" "$merge_base" "$tree")"
  else
    merge_base=""
  fi
  jq -n -c --arg merge_base "$merge_base" --argjson names "${names:-null}" --argjson hunks "${hunks:-null}" \
    '{mb: $merge_base, names: $names, hunks: $hunks}'
}

# _gaia_loop_annotate <F-json> <authorship-json>: F with `authored` on every entry.
_gaia_loop_annotate() {
  jq -n -c --argjson findings "$1" --argjson authorship "$2" "$_GAIA_LOOP_AUTHORED_JQ"'
    $findings | .entries |= map(. + {authored: authored($authorship.names; $authorship.hunks)})'
}

# _gaia_loop_vetoed <main-root> <B> <r>: identity keys vetoed for round r
# (effective_from_round <= r). rc 1 on an unreadable or malformed file.
_gaia_loop_vetoed() {
  local vetoes_file vetoed_keys
  vetoes_file="$(gaia_loop_run_directory "$1" "$2")/vetoes.json"
  [ -e "$vetoes_file" ] || { printf '[]\n'; return 0; }
  vetoed_keys="$(jq -c -s --argjson round "$3" '
    if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
        and all(.keys[]; type == "object" and (.effective_from_round | type == "number" and . == floor)))
    then [.[0].keys[] | select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line]]
    else error("malformed vetoes.json") end' <"$vetoes_file" 2>/dev/null)" || return 1
  [ -n "$vetoed_keys" ] || return 1
  printf '%s\n' "$vetoed_keys"
}

# _gaia_loop_waived_keys <main-root> <B> <r>: identity keys round r's own
# dispositions file waives on the triage threshold. Unreadable reads as none.
_gaia_loop_waived_keys() {
  local dispositions_file waived_keys
  dispositions_file="$(gaia_loop_run_directory "$1" "$2")/dispositions-$3.json"
  [ -f "$dispositions_file" ] || { printf '[]\n'; return 0; }
  waived_keys="$(jq -c '[.entries[] | select(.disposition == "waive-out-of-scope" and .basis == "triage-threshold")
    | [.member, .finding_class, .path, .line]]' <"$dispositions_file" 2>/dev/null)" || waived_keys=""
  [ -n "$waived_keys" ] && printf '%s\n' "$waived_keys" || printf '[]\n'
}

# _gaia_loop_raw_findings <main-root> <state-json> <r>: F(r) before authorship.
_gaia_loop_raw_findings() {
  local main="$1" state="$2" round="$3" branch_key slug stamp baseline audit_directory member candidate_file sorted_candidates newest member_entries
  local entries="[]" missing="[]"
  local -a candidates members
  branch_key="$(printf '%s' "$state" | jq -r '.branch')"
  slug="$(printf '%s' "$state" | jq -r --argjson round "$round" '.history.rounds[$round - 1].raw_branch_slug // ""')"
  members=()
  while IFS= read -r member; do members+=("$member"); done < <(printf '%s' "$state" | jq -r --argjson round "$round" '.history.rounds[$round - 1].members[]? | strings')
  stamp="$(gaia_loop_stamp_file "$main" "$branch_key" "$round")"
  baseline="$(gaia_loop_run_directory "$main" "$branch_key")/baseline-$round.json"
  audit_directory="$main/.gaia/local/audit"
  for member in ${members[@]+"${members[@]}"}; do
    newest=""
    # The slug and member are glob text: only the classes gaia_key_slug and
    # the member names emit are let through, anything else is missing evidence.
    if [[ "$slug" =~ ^[A-Za-z0-9_%-]+$ && "$member" =~ ^[A-Za-z0-9_-]+$ ]] && _gaia_loop_keyable "$branch_key" && [ -f "$stamp" ]; then
      candidates=()
      if [ -f "$baseline" ]; then
        while IFS= read -r candidate_file; do candidates+=("$candidate_file"); done < <(find "$audit_directory" -maxdepth 1 -type f -name "*.$slug.$member.findings.json" -newer "$stamp" ! -newer "$baseline" 2>/dev/null)
      else
        while IFS= read -r candidate_file; do candidates+=("$candidate_file"); done < <(find "$audit_directory" -maxdepth 1 -type f -name "*.$slug.$member.findings.json" -newer "$stamp" 2>/dev/null)
      fi
      sorted_candidates=""
      [ "${#candidates[@]}" -eq 0 ] || sorted_candidates="$(ls -t -- "${candidates[@]}" 2>/dev/null)" || sorted_candidates=""
      newest="${sorted_candidates%%$'\n'*}"
    fi
    member_entries=""
    if [ -n "$newest" ]; then
      # Never `.security // true`: `//` treats false as absent, so every
      # security:false finding would read true.
      member_entries="$(jq -c --arg member "$member" '.findings | if type == "array" then map({member: $member, finding_class, path, line, severity,
        security: (if (.security | type) == "boolean" then .security else true end),
        cross_remit: (.cross_remit == true)}
        + (if .triage == true then {triage: true, triage_reason: (if (.triage_reason | type) == "string" then .triage_reason else "" end)} else {} end))
        else error("no findings") end' <"$newest" 2>/dev/null)" || member_entries=""
    fi
    if [ -n "$member_entries" ]; then
      entries="$(jq -n -c --argjson existing "$entries" --argjson additional "$member_entries" '$existing + $additional')"
    else
      missing="$(jq -n -c --argjson existing "$missing" --arg member "$member" '$existing + [$member]')"
    fi
  done
  jq -n -c --argjson round "$round" --argjson entries "$entries" --argjson missing_members "$missing" '{round: $round, entries: $entries, missing_members: $missing_members}'
}

# gaia_loop_findings <main-root> <state-json> <r>: F(r) as
# {"round","entries":[...],"missing_members":[...]}, each entry
# {member, finding_class, path, line, severity, security, cross_remit, authored},
# plus triage and triage_reason on an entry whose sidecar marks it triage:true
# (the dispositions check decides whether the mark is honored).
gaia_loop_findings() {
  local findings authorship
  findings="$(_gaia_loop_raw_findings "$1" "$2" "$3")" || return 2
  authorship="$(_gaia_loop_authorship "$1" "$2" "$3")" || return 2
  _gaia_loop_annotate "$findings" "$authorship"
}

# shellcheck disable=SC2016
_GAIA_LOOP_VERDICT_JQ='
def disposed: key as $entry_key | any($disposed[]; . == $entry_key);
def isnew: key as $entry_key | any(($previous_keys // [])[]; . == $entry_key) | not;
($findings.entries | map(select(.authored and (disposed | not)))) as $counted
| (if ($findings.missing_members | length) > 0 then null else ($counted | length) end) as $authored_count
| ($series + [$authored_count]) as $authored_series
# Negative indices wrap in jq; the r >= 3 guards below keep them unread.
| $authored_series[$round - 2] as $previous_authored_count | $authored_series[$round - 3] as $second_previous_authored_count
| ($counted | map(select(.line != null and .line > 0 and isnew and in_hunks($enriching_hunks // [])) | key)) as $new_keys_on_repaired_lines
| (if $authored_count == null then "unknown"
   elif $authored_count == 0 then "quiet"
   elif $round >= 3 and $round >= $granted_round + 1 and $previous_authored_count != null and ($new_keys_on_repaired_lines | length) > 0 then "enriching"
   elif $round >= 3 and $round >= $granted_round + 2 and $second_previous_authored_count != null and $second_previous_authored_count >= 1 and $previous_authored_count != null and $previous_authored_count >= $second_previous_authored_count and $authored_count >= $previous_authored_count then "stalled"
   else "continue" end) as $verdict
'"$_GAIA_LOOP_SIGNALS_JQ"'
| {round: $round, merge_base: (if $merge_base == "" then null else $merge_base end), keys: ($findings.entries | map(key) | unique),
   A: $authored_count, verdict: $verdict,
   counted_keys: $counted_summaries, raw_count: $raw, waived_count: $waived,
   signals: $signals, accept_eligible: $eligible, accept_reasons: $reasons,
   evidence: {members: $members, missing_members: $findings.missing_members, new_keys_on_repaired_lines: $new_keys_on_repaired_lines, A_series: $authored_series},
   evaluated_at: $now}
'

# gaia_loop_evaluate_round <main-root> <state-json> <r>: round r's snapshot.
# rc 2 no such round, 5 a bad round record or an unreadable vetoes.json.
gaia_loop_evaluate_round() {
  local main="$1" state="$2" round="$3" branch_key round_context tree commit previous_tree authorship enriching_hunks="null" findings disposed vetoed waived is_maintainer_repo=false
  gaia_loop_is_uint "$round" && [ "$round" -ge 1 ] || return 2
  round_context="$(printf '%s' "$state" | jq -c --argjson round "$round" '
    .history.rounds as $rounds
    | if $round > ($rounds | length) then error("no round") else
      ([.allowance.answers[] | select(.kind == "grant")] | last) as $latest_grant
      | {tree: $rounds[$round - 1].tree, commit: $rounds[$round - 1].commit, members: ($rounds[$round - 1].members // []),
         previous_tree: (if $round >= 2 then $rounds[$round - 2].tree else "" end),
         previous_keys: (if $round >= 2 then $rounds[$round - 2].snapshot.keys? else null end),
         previous_snapshot: (if $round >= 2 then $rounds[$round - 2].snapshot else null end),
         second_previous_snapshot: (if $round >= 3 then $rounds[$round - 3].snapshot else null end),
         series: [$rounds[0:$round - 1][] | .snapshot.A?],
         granted_round: (if $latest_grant == null then 0 else ([.history.checkpoints[] | select(.index == $latest_grant.checkpoint)] | .[0].at_round // 0) end)}
      end' 2>/dev/null)" || return 2
  tree="$(printf '%s' "$round_context" | jq -r '.tree')"
  commit="$(printf '%s' "$round_context" | jq -r '.commit')"
  previous_tree="$(printf '%s' "$round_context" | jq -r '.previous_tree')"
  gaia_loop_is_oid "$tree" && gaia_loop_is_oid "$commit" || return 5
  branch_key="$(printf '%s' "$state" | jq -r '.branch')"
  vetoed="$(_gaia_loop_vetoed "$main" "$branch_key" "$round")" || return 5
  findings="$(_gaia_loop_raw_findings "$main" "$state" "$round")" || return 2
  authorship="$(_gaia_loop_authorship "$main" "$state" "$round")" || return 2
  findings="$(_gaia_loop_annotate "$findings" "$authorship")" || return 2
  if gaia_loop_is_oid "$previous_tree"; then
    enriching_hunks="$(_gaia_loop_hunks_json "$main" "$previous_tree" "$tree")"
  fi
  disposed="$(_gaia_loop_disposed "$main" "$branch_key" "$round" | jq -c --argjson vetoed_keys "$vetoed" 'map(select(. as $entry_key | any($vetoed_keys[]; . == $entry_key) | not))')" || return 5
  waived="$(_gaia_loop_waived_keys "$main" "$branch_key" "$round")"
  # gaia:maintainer-only:start
  [ -f "$main/.claude/rules/maintainers/harness-triage-threshold.md" ] && is_maintainer_repo=true
  # gaia:maintainer-only:end
  jq -n -c --argjson findings "$findings" --argjson enriching_hunks "$enriching_hunks" --argjson disposed "$disposed" \
    --argjson previous_keys "$(printf '%s' "$round_context" | jq -c '.previous_keys')" \
    --argjson series "$(printf '%s' "$round_context" | jq -c '.series')" \
    --argjson members "$(printf '%s' "$round_context" | jq -c '.members')" \
    --argjson previous_snapshot "$(printf '%s' "$round_context" | jq -c '.previous_snapshot')" --argjson second_previous_snapshot "$(printf '%s' "$round_context" | jq -c '.second_previous_snapshot')" \
    --argjson waivedkeys "$waived" --argjson is_maintainer_repo "$is_maintainer_repo" \
    --argjson granted_round "$(printf '%s' "$round_context" | jq -r '.granted_round')" --argjson round "$round" \
    --arg merge_base "$(printf '%s' "$authorship" | jq -r '.mb')" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$_GAIA_LOOP_AUTHORED_JQ $_GAIA_LOOP_VERDICT_JQ"
}

# _gaia_loop_spend <raw-branch>: usage.sh's text, or `unavailable`. A
# watchdog, not timeout(1), which macOS lacks; `set -m` gives the child its
# own process group so the kill also reaches anything it spawned, which would
# otherwise hold the capture pipe open past the deadline.
_gaia_loop_spend() {
  local usage_output exit_status=0
  usage_output="$(
    set -m
    bash "$_GAIA_LOOP_EVAL_DIRECTORY/usage.sh" pr --branch "$1" </dev/null 2>/dev/null &
    pid=$!
    (sleep "$_GAIA_LOOP_SPEND_TIMEOUT"; kill -TERM -- "-$pid") </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!
    wait "$pid"
    child_status=$?
    kill -TERM -- "-$watchdog_pid" 2>/dev/null
    exit "$child_status"
  )" 2>/dev/null || exit_status=$?
  if [ "$exit_status" -ne 0 ] || [ -z "$usage_output" ]; then
    printf 'unavailable'
  else
    printf '%s' "$usage_output"
  fi
}

# _gaia_loop_brief <audited-root> <main-root> <state-json>: the checkpoint
# brief.
_gaia_loop_brief() {
  local root="$1" main="$2" state="$3" used allowed pending snapshot findings raw spend per_round="[]" i round_snapshot
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  [ "$used" -ge 1 ] || return 2
  allowed="$(gaia_loop_allowed "$state")"
  pending="$(gaia_loop_pending_checkpoint "$state")"
  snapshot="$(printf '%s' "$state" | jq -c '.history.rounds | last | .snapshot')"
  [ "$snapshot" = null ] && { snapshot="$(gaia_loop_evaluate_round "$main" "$state" "$used")" || return 2; }
  i=1
  while [ "$i" -le "$used" ]; do
    if [ "$i" -eq "$used" ]; then round_snapshot="$snapshot"; else round_snapshot="$(printf '%s' "$state" | jq -c --argjson i "$i" '.history.rounds[$i - 1].snapshot')"; fi
    per_round="$(printf '%s' "$state" | jq -c --argjson accumulated_rounds "$per_round" --argjson round_snapshot "$round_snapshot" --argjson i "$i" \
      '$accumulated_rounds + [{round: $i, A: $round_snapshot.A?, verdict: $round_snapshot.verdict?, closing: (.history.rounds[$i - 1].closing // false)}]')"
    i=$((i + 1))
  done
  findings="$(gaia_loop_findings "$main" "$state" "$used")"
  raw="$(_gaia_loop_git -C "$root" branch --show-current 2>/dev/null)" || raw=""
  spend="$(_gaia_loop_spend "$raw")"
  jq -n -c --argjson state "$state" --argjson used "$used" --argjson allowed "$allowed" \
    --argjson pending "$([ -n "$pending" ] && echo true || echo false)" --argjson per_round "$per_round" \
    --argjson pending_checkpoint "${pending:-null}" --argjson cap "$_GAIA_LOOP_HARD_CAP" \
    --argjson snapshot "$snapshot" --argjson findings "$findings" --arg spend "$spend" \
    --arg recommended "$(gaia_loop_recommended "$(printf '%s' "${pending:-null}" | jq -r '.trigger // empty')" "$snapshot")" \
    --arg grant_line "$(gaia_loop_grant_line "$(_gaia_loop_grant_rounds "$state")")" --arg accept_line "$(gaia_loop_accept_line)" '
    {branch: $state.branch, pr: $state.pr, rounds_run: $used, allowed: $allowed, pending_checkpoint: $pending,
     per_round: $per_round, verdict: $snapshot.verdict, evidence: $snapshot.evidence,
     signals: ($snapshot.signals // null), accept_eligible: ($snapshot.accept_eligible == true),
     accept_reasons: ($snapshot.accept_reasons // []), rounds_cap: $cap,
     recommended: $recommended,
     grant_line: $grant_line, accept_line: $accept_line,
     remaining_by_severity: ($findings.entries | {error: map(select(.severity == "error")) | length,
                                            warning: map(select(.severity == "warning")) | length,
                                            suggestion: map(select(.severity == "suggestion")) | length}),
     spend: $spend, spend_note: "information only"}'
}

_gaia_loop_usage() {
  printf 'usage: audit-loop-eval.sh findings|eval|brief|record-values|state-path|current-round|next-unit|unit-window|pinned-question --root <audited-root> [--round <r>]\n' >&2
  return 2
}

_gaia_loop_cli() {
  local subcommand="${1-}" root="" round="" branch_key main file state exit_status used subcommand_output light_ledger light_counts
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; root="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; round="$2"; shift 2 ;;
      *) _gaia_loop_usage; return 2 ;;
    esac
  done
  case "$subcommand" in
    findings | eval | brief | record-values | state-path | current-round | next-unit | unit-window | pinned-question) ;;
    *) _gaia_loop_usage; return 2 ;;
  esac
  case "$root" in /*) ;; *) printf 'audit-loop-eval: --root must be an absolute path\n' >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6; }
  command -v git >/dev/null 2>&1 || { printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6; }
  exit_status=0
  branch_key="$(gaia_loop_key "$root")" || exit_status=$?
  case "$exit_status" in
    0) ;;
    4) printf 'audit-loop-eval: detached HEAD at %s has no branch key\n' "$root" >&2; return 4 ;;
    6) printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: the branch at %s is not keyable\n' "$root" >&2; return 5 ;;
  esac
  main="$(gaia_resolve_main_root "$root" 2>/dev/null)" || { printf 'audit-loop-eval: cannot resolve the main checkout of %s\n' "$root" >&2; return 2; }
  file="$(gaia_loop_state_file "$main" "$branch_key")"
  if [ "$subcommand" = state-path ]; then printf '%s\n' "$file"; return 0; fi
  exit_status=0
  state="$(gaia_loop_read_state "$file")" || exit_status=$?
  case "$exit_status" in
    0) ;;
    1)
      case "$subcommand" in
        current-round) printf '0\n'; return 0 ;;
        next-unit) printf '1 1\n'; return 0 ;;
        # No `light` key here by design: a light review needs an earlier full
        # clearance, and every full clearance in a unit comes from a member
        # round the bound hook recorded, which creates the state file.
        record-values) printf '{"total":0,"members":{},"grants":0}\n'; return 0 ;;
      esac
      printf 'audit-loop-eval: no recorded round for %s\n' "$branch_key" >&2
      return 2
      ;;
    6) printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: corrupt state file %s\n' "$file" >&2; return 5 ;;
  esac
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  case "$subcommand" in
    current-round) printf '%s\n' "$used"; return 0 ;;
    next-unit)
      printf '%s' "$state" | jq -r '"\(((.history.units // []) | length) + 1) \((.history.rounds | length) + 1)"'
      return 0
      ;;
    unit-window)
      subcommand_output="$(printf '%s' "$state" | jq -r '(.history.units // []) | last
        | if . == null then empty else "\(.unit) \(.start_round) \(.through_round) \(.admitted_on == "accept")" end')"
      [ -n "$subcommand_output" ] || { printf 'audit-loop-eval: no unit recorded for %s\n' "$branch_key" >&2; return 2; }
      printf '%s\n' "$subcommand_output"
      return 0
      ;;
    pinned-question)
      subcommand_output="$(gaia_loop_pending_checkpoint "$state" | jq -c 'select(.question != null) | .question')"
      [ -n "$subcommand_output" ] || { printf 'audit-loop-eval: no pending pinned question for %s\n' "$branch_key" >&2; return 2; }
      printf '%s\n' "$subcommand_output"
      return 0
      ;;
    record-values)
      subcommand_output="$(printf '%s' "$state" | jq -c '{total: (.history.rounds | length),
        members: (reduce .history.rounds[] as $round_entry ({}; reduce ($round_entry.members[]) as $member (.; .[$member] += [$round_entry.tree]))
                  | map_values(unique | length) | to_entries | sort_by(.key) | from_entries),
        grants: ([.allowance.answers[] | select(.kind == "grant")] | length)}')" || return 1
      # Light reviews are counted from their own ledger and never enter
      # `total`; an absent or unreadable ledger leaves the key out.
      light_ledger="$root/.gaia/local/audit/light/$(gaia_branch_slug "$root" 2>/dev/null).reviews.jsonl"
      light_counts=''
      if [ -f "$light_ledger" ] && [ -r "$light_ledger" ]; then
        light_counts="$(jq -cs 'map(select(type == "object" and (.member | type) == "string") | .member)
          | reduce .[] as $member ({}; .[$member] += 1) | to_entries | sort_by(.key) | from_entries' "$light_ledger" 2>/dev/null)" || light_counts=''
      fi
      if [ -n "$light_counts" ] && [ "$light_counts" != '{}' ]; then
        printf '%s' "$subcommand_output" | jq -c --argjson light "$light_counts" '. + {light: $light}'
      else
        printf '%s\n' "$subcommand_output"
      fi
      return 0
      ;;
    brief) _gaia_loop_brief "$root" "$main" "$state"; return $? ;;
  esac
  [ -n "$round" ] || round="$used"
  if ! gaia_loop_is_uint "$round" || [ "$round" -lt 1 ] || [ "$round" -gt "$used" ]; then
    printf 'audit-loop-eval: no recorded round %s for %s\n' "$round" "$branch_key" >&2
    return 2
  fi
  if [ "$subcommand" = findings ]; then gaia_loop_findings "$main" "$state" "$round"; return $?; fi
  gaia_loop_evaluate_round "$main" "$state" "$round"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  _gaia_loop_cli "$@"
  exit $?
fi
