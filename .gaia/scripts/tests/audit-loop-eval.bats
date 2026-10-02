#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-loop-eval.sh: the finding set, A(r), the
# verdicts and their grant windows, the allowance fold and the deny decision,
# the checkpoint brief, the PR-body record values, and the read-only CLI.
#
# Every verdict fixture is built from real commits and real findings
# sidecars (.gaia/tests/helpers/audit-loop-fixture.sh); no A value is ever
# injected, except where a case mutates a stored snapshot to prove it is read
# rather than recomputed.
#
# AUDIT_LOOP_SCRIPTS_DIRECTORY points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-eval.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  # brief reads spend through usage.sh, which reaches the pricing path.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  alf_init
  alf_branch feat/loop
  MEMBER=code-audit-frontend
}

# evaluate_round <r>: round r's snapshot through the sourced function (what the hook runs).
evaluate_round() {
  gaia_loop_evaluate_round "$ALF_ROOT" "$(cat "$ALF_STATE")" "$1"
}

# read_json <json> <filter>: one jq read.
read_json() {
  printf '%s' "$1" | jq -r "$2"
}

# plus <entries-json> <path> <line-json>: append one entry.
plus() {
  jq -n -c --argjson entries "$1" --arg path "$2" --argjson line "$3" '$entries + [{path: $path, line: $line, finding_class: "rule/x"}]'
}

# next_round <r> <entries-json>: commit the working tree as round r.
next_round() {
  alf_commit "round $1"
  alf_round "$1" "$MEMBER" "$2"
}

# cli_copy: the scripts in a scratch dir beside a stub usage.sh whose
# behaviour STUB_USAGE_MODE (ok, fail, hang) picks. Sets CLI.
cli_copy() {
  local script_file
  CLI="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$CLI"
  for script_file in audit-loop-eval.sh audit-loop-state-lib.sh audit-loop-signals-lib.sh context-checkpoint-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh; do
    cp "$SCRIPTS/$script_file" "$CLI/$script_file"
  done
  cat >"$CLI/usage.sh" <<'EOF'
case "${STUB_USAGE_MODE:-ok}" in
  ok) printf 'spend for %s: 1.23 USD\n' "$3" ;;
  fail) exit 1 ;;
  hang) sleep 30; printf 'late\n' ;;
esac
EOF
}

# sequence_case <verdict> <decision> <A...>: build the A sequence and check the
# last round's verdict and the hook's decision on it.
sequence_case() {
  local want="$1" decision="$2" snapshot argument_count
  shift 2
  alf_sequence "$@"
  argument_count=$#
  snapshot="$(evaluate_round "$argument_count")"
  [ "$(read_json "$snapshot" '.A')" = "${!argument_count}" ] || { echo "A was $(read_json "$snapshot" '.A'), want ${!argument_count}"; return 1; }
  [ "$(read_json "$snapshot" '.verdict')" = "$want" ] || { echo "verdict $(read_json "$snapshot" '.verdict'), want $want"; return 1; }
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = "$decision" ]
}

@test "UAT-006: A 5,5,5 is stalled and denies" {
  sequence_case stalled "deny stalled" 5 5 5
}

@test "UAT-006: A 5,6,7 is stalled and denies" {
  sequence_case stalled "deny stalled" 5 6 7
}

@test "UAT-006: A 5,4,4 continues and allows" {
  sequence_case continue allow 5 4 4
}

@test "UAT-006: A 5,5,4 continues and allows" {
  sequence_case continue allow 5 5 4
}

@test "UAT-006: A 5,5 continues and allows" {
  sequence_case continue allow 5 5
}

@test "directive 8: A 3,2,1,1,1 continues at round 4 and stalls at round 5" {
  local snapshot
  alf_sequence 3 2 1 1 1
  [ "$(jq -r '.history.rounds[3].snapshot.verdict' "$ALF_STATE")" = continue ]
  snapshot="$(evaluate_round 5)"
  [ "$(read_json "$snapshot" '.verdict')" = stalled ]
  [ "$(read_json "$snapshot" '.evidence.A_series | map(tostring) | join(",")')" = "3,2,1,1,1" ]
}

@test "UAT-007 (i): a new key on a repaired line at round 3 is enriching and named" {
  local snapshot
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = enriching ]
  [ "$(read_json "$snapshot" '.evidence.new_keys_on_repaired_lines | tojson')" = '[["code-audit-frontend","rule/x","f.txt",8]]' ]
}

@test "UAT-007 (ii): a persisting key on a repaired line while A falls continues" {
  alf_sequence 6 5
  alf_set_line f.txt 2 repaired
  next_round 3 "$(alf_entries f.txt 1 3)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
}

@test "UAT-007 (iii): a new key on an unchanged line of a repaired path continues" {
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 10)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
}

@test "UAT-007 (iv): the enriching shape at round 2 continues" {
  alf_sequence 6
  alf_set_line f.txt 8 repaired
  next_round 2 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(read_json "$(evaluate_round 2)" '.verdict')" = continue ]
}

@test "directive 8: a deletion-only hunk never makes enriching" {
  local snapshot
  alf_sequence 6 5
  awk 'NR != 12' "$ALF_ROOT/f.txt" >"$ALF_ROOT/f.tmp" && mv "$ALF_ROOT/f.tmp" "$ALF_ROOT/f.txt"
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 11)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "directive 8: a pure rename never makes enriching" {
  local snapshot
  alf_sequence 6 5
  alf_git mv other.txt renamed.txt
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" renamed.txt 1)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "directive 8: a null line never makes enriching" {
  local snapshot
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt null)"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "COV-017: the enriching shape after a round with missing evidence continues" {
  local snapshot
  alf_sequence 6
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_store_snapshot 1
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 2 20
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(jq -r '.history.rounds[1].snapshot.verdict' "$ALF_STATE")" = unknown ]
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "COV-003: a sidecar written after the round's baseline is never evidence" {
  local snapshot
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 3)" 11
  alf_baseline 1 15
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 7)" 16 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  snapshot="$(evaluate_round 1)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  rm "$ALF_ROOT"/.gaia/local/audit/aaaa*.findings.json
  snapshot="$(evaluate_round 1)"
  [ "$(read_json "$snapshot" '.verdict')" = unknown ]
  [ "$(read_json "$snapshot" '.A')" = null ]
}

@test "grant window: enriching is off at the granted round and back on the round after" {
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = enriching ]
  alf_add_checkpoint 3 enriching
  alf_add_answer 1 grant 3
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  alf_set_line f.txt 9 repaired
  next_round 4 "$(plus "$(plus "$(alf_entries f.txt 1 2)" f.txt 8)" f.txt 9)"
  [ "$(read_json "$(evaluate_round 4)" '.verdict')" = enriching ]
}

@test "grant window: stalled is off the round after a grant and back on the round after that" {
  alf_sequence 5 5 5
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = stalled ]
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 grant 3
  [ "$(read_json "$(evaluate_round 3)" '.verdict')" = continue ]
  alf_set_line other.txt 4 "round 4"
  next_round 4 "$(alf_entries f.txt 1 5)"
  [ "$(read_json "$(evaluate_round 4)" '.verdict')" = continue ]
  alf_set_line other.txt 5 "round 5"
  next_round 5 "$(alf_entries f.txt 1 5)"
  [ "$(read_json "$(evaluate_round 5)" '.verdict')" = stalled ]
}

@test "UAT-008: only non-authored or disposed entries is quiet with a non-empty set; a null line on a changed path is not" {
  local rows snapshot
  alf_fill f.txt 12 feature
  alf_set_line base.txt 5 "branch edit"
  alf_set_line other.txt 1 "round 1"
  next_round 1 "$(alf_entries f.txt 1 2)"
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual"}]'
  rows='[{"path":"base.txt","line":15,"finding_class":"rule/x"},
         {"path":"untouched.txt","line":3,"finding_class":"rule/x"},
         {"path":"untouched.txt","line":null,"finding_class":"rule/x"},
         {"path":"f.txt","line":1,"finding_class":"rule/x"}]'
  alf_set_line other.txt 2 "round 2"
  next_round 2 "$rows"
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.A')" = 0 ]
  [ "$(read_json "$snapshot" '.keys | length')" -gt 0 ]
  [ "$(read_json "$snapshot" '.verdict')" = quiet ]
  alf_sidecar "$MEMBER" "$(plus "$rows" f.txt null)" 22
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.A')" = 1 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "UAT-018: re-reported residuals never stall a converging branch" {
  local fresh
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  next_round 1 "$(alf_entries f.txt 1 6)"
  alf_dispositions 1 "$(jq -n -c '[range(1;7) | {member: "code-audit-frontend", finding_class: "rule/x", path: "f.txt", line: .,
    disposition: (if . <= 2 then "accept-residual" else "fix" end)}]')"
  alf_set_line other.txt 2 "round 2"
  next_round 2 "$(plus "$(alf_entries f.txt 1 2)" f.txt 7)"
  alf_set_line other.txt 3 "round 3"
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 8)"
  alf_set_line other.txt 4 "round 4"
  next_round 4 '[]'
  alf_store_snapshot 4
  fresh="$(jq -r '[.history.rounds[1:][] | .snapshot.verdict] | join(",")' "$ALF_STATE")"
  [ "$fresh" = "continue,continue,quiet" ]
}

@test "UAT-021b: a missing, stale or unparseable member sidecar is unknown, still bounded by the allowance" {
  local variant snapshot two='["code-audit-frontend","code-audit-maintainer-shell"]'
  local shell_sidecar="$ALF_ROOT/.gaia/local/audit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.$ALF_SLUG.code-audit-maintainer-shell.findings.json"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "$two"
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 2)" 11
  for variant in missing stale unparseable; do
    rm -f "$shell_sidecar"
    case "$variant" in
      stale) alf_sidecar code-audit-maintainer-shell '[]' 5 ;;
      unparseable) printf 'not json' >"$shell_sidecar" && touch -t "$(alf_time 12)" "$shell_sidecar" ;;
    esac
    snapshot="$(evaluate_round 1)"
    [ "$(read_json "$snapshot" '.verdict')" = unknown ] || { echo "$variant gave $(read_json "$snapshot" '.verdict')"; return 1; }
    [ "$(read_json "$snapshot" '.A')" = null ] || return 1
    [ "$(read_json "$snapshot" '.evidence.missing_members | tojson')" = '["code-audit-maintainer-shell"]' ] || return 1
  done
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = allow ]
  alf_state_edit '.history.knobs.checkpoint_round = 1'
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snapshot")" = "deny allowance" ]
}

@test "UAT-030: each round keeps its own merge base; stored A is read, never recomputed" {
  local snapshot earlier_merge_base
  alf_sequence 5 5
  earlier_merge_base="$(jq -r '.history.rounds[0].snapshot.merge_base' "$ALF_STATE")"
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(plus "$(alf_entries f.txt 1 5)" base.txt 18)" 31
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.merge_base')" = "$(alf_git rev-parse origin/main)" ]
  [ "$(read_json "$snapshot" '.merge_base')" != "$earlier_merge_base" ]
  [ "$(jq -r '.history.rounds[1].snapshot.merge_base' "$ALF_STATE")" = "$earlier_merge_base" ]
  [ "$(read_json "$snapshot" '.A')" = 5 ]
  [ "$(read_json "$snapshot" '.verdict')" = stalled ]
  alf_state_edit '.history.rounds[1].snapshot.A = 6'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
  [ "$(jq -r '[.history.rounds[].tree] | unique | length' "$ALF_STATE")" = 3 ]
}

@test "directive 10: a new key on an upstream-merged line is not authored, so never enriching" {
  local snapshot
  alf_sequence 6 5
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(plus "$(alf_entries f.txt 1 3)" base.txt 18)" 31
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 3 ]
  [ "$(read_json "$snapshot" '.verdict')" = continue ]
}

@test "UAT-031: invalid rows count as authored; row text never reaches git argv; nothing written outside" {
  local row snapshot stub log real_git before after sidecar_time=40
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp 1 10
  for row in '{"path":"-rf","line":1}' '{"path":"a/../b","line":1}' '{"path":"f.txt","line":"x"}' '{"path":"f.txt","line":-1}'; do
    sidecar_time=$((sidecar_time + 1))
    alf_sidecar "$MEMBER" "[$row]" "$sidecar_time"
    [ "$(read_json "$(evaluate_round 1)" '.A')" = 1 ] || { echo "not counted: $row"; return 1; }
  done
  stub="$BATS_TEST_TMPDIR/stub"
  log="$stub/git.log"
  real_git="$(command -v git)"
  mkdir -p "$stub"
  : >"$log"
  printf '#!/bin/sh\nfor argument in "$@"; do printf "%%s\\n" "$argument"; done >>"%s"\nprintf "%%s\\n" "--END--" >>"%s"\nexec "%s" "$@"\n' "$log" "$log" "$real_git" >"$stub/git"
  chmod +x "$stub/git"
  alf_sidecar "$MEMBER" '[{"path":"-rf","line":1},{"path":"a/../b","line":null},{"path":"f.txt","line":"x"},{"path":"f.txt","line":-1}]' 50
  before="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  snapshot="$(PATH="$stub:$PATH" evaluate_round 1)"
  after="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  [ "$(read_json "$snapshot" '.A')" = 4 ]
  [ "$before" = "$after" ]
  [ -e "$PWD/-rf" ] && return 1
  [ -e "$ALF_ROOT/-rf" ] && return 1
  # Every diff invocation ends its revisions with `--`; no row path is argv.
  awk '/^--END--$/ { if (in_diff && !seen_double_dash) bad = 1; in_diff = 0; seen_double_dash = 0; record_count++; next }
       $0 == "diff" { in_diff = 1 } $0 == "--" { seen_double_dash = 1 }
       $0 == "-rf" || $0 == "a/../b" { bad = 1 }
       END { exit (bad || record_count == 0) }' "$log"
  [ "$(grep -c '^diff$' "$log")" -ge 2 ]
}

@test "UAT-019: every CLI subcommand leaves the state file byte-identical and takes no lock" {
  local state_copy subcommand
  cli_copy
  alf_sequence 4 3
  alf_store_snapshot 2
  state_copy="$(snapshot_file "$ALF_STATE")"
  for subcommand in findings eval brief record-values state-path current-round; do
    run "$CLI/audit-loop-eval.sh" "$subcommand" --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || { echo "$subcommand exited $status: $output"; return 1; }
    assert_files_identical "$state_copy" "$ALF_STATE" || { echo "$subcommand changed the state"; return 1; }
    [ -e "$ALF_STATE.lock" ] && { echo "$subcommand took the lock"; return 1; }
  done
  run "$CLI/audit-loop-eval.sh" state-path --root "$ALF_ROOT"
  [ "$output" = "$ALF_STATE" ]
}

@test "allowance fold: defaults, then a grant at round 5" {
  local state
  alf_sequence 2
  state="$(cat "$ALF_STATE")"
  [ "$(gaia_loop_allowed "$state")" = 5 ]
  alf_add_checkpoint 5 allowance
  alf_add_answer 1 grant 2
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = 7 ]
}

@test "allowance fold: an accept allows one closing round" {
  alf_sequence 4 4 4
  alf_add_checkpoint 3 stalled
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = false ]
  alf_add_answer 1 accept
  [ "$(gaia_loop_allowed "$(cat "$ALF_STATE")")" = 4 ]
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = true ]
}

@test "UAT-022: a live checkpoint knob only lowers the frozen one; a malformed one is ignored" {
  local state knob_value
  alf_sequence 2
  state="$(cat "$ALF_STATE")"
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_allowed "$state")" = 5 ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=4 gaia_loop_allowed "$state")" = 4 ]
  for knob_value in 0 -1 abc ''; do
    [ "$(GAIA_AUDIT_CHECKPOINT_ROUND="$knob_value" gaia_loop_allowed "$state" 2>/dev/null)" = 5 ] || { echo "'$knob_value' moved it"; return 1; }
  done
  run --separate-stderr env GAIA_AUDIT_CHECKPOINT_ROUND=abc bash -c '. "$1"; gaia_loop_allowed "$2"' _ "$SCRIPTS/audit-loop-eval.sh" "$state"
  [ "$output" = 5 ]
  case "$stderr" in *GAIA_AUDIT_CHECKPOINT_ROUND*) ;; *) return 1 ;; esac
}

@test "knobs: frozen at round 1, capped at the defaults" {
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=2 GAIA_AUDIT_GRANT_ROUNDS=1 gaia_loop_knobs_initial)" = '{"checkpoint_round":2,"grant_rounds":1}' ]
  [ "$(gaia_loop_knobs_initial)" = '{"checkpoint_round":6,"grant_rounds":3}' ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_knobs_initial | jq -r '.checkpoint_round')" = 6 ]
  [ "$(GAIA_AUDIT_GRANT_ROUNDS=7 gaia_loop_knobs_initial | jq -r '.grant_rounds')" = 3 ]
}

# brief_check <recommended> <pending> <error> <warning> <suggestion>: run the
# CLI brief and check the fields every verdict shares.
brief_check() {
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "brief exited $status: $output"; return 1; }
  BRIEF="$output"
  [ "$(read_json "$BRIEF" '.recommended')" = "$1" ] || { echo "recommended $(read_json "$BRIEF" '.recommended')"; return 1; }
  [ "$(read_json "$BRIEF" '.pending_checkpoint')" = "$2" ] || return 1
  [ "$(read_json "$BRIEF" '.grant_line')" = "$(gaia_loop_grant_line 3)" ] || return 1
  [ "$(read_json "$BRIEF" '.accept_line')" = "$(gaia_loop_accept_line)" ] || return 1
  [ "$(read_json "$BRIEF" '.remaining_by_severity | "\(.error),\(.warning),\(.suggestion)"')" = "$3,$4,$5" ] || { echo "severity $(read_json "$BRIEF" '.remaining_by_severity')"; return 1; }
  [ "$(read_json "$BRIEF" '.spend')" = "spend for feat/loop: 1.23 USD" ] || { echo "spend $(read_json "$BRIEF" '.spend')"; return 1; }
  [ "$(read_json "$BRIEF" '.spend_note')" = "information only" ]
}

@test "brief: continue at an allowance checkpoint recommends grant" {
  cli_copy
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  brief_check grant true 0 2 0
  [ "$(read_json "$BRIEF" '.verdict')" = continue ]
  [ "$(read_json "$BRIEF" '.rounds_run')" = 5 ]
  [ "$(read_json "$BRIEF" '.allowed')" = 5 ]
  [ "$(read_json "$BRIEF" '[.per_round[].A] | map(tostring) | join(",")')" = "6,5,4,3,2" ]
}

@test "brief: quiet recommends accept" {
  cli_copy
  alf_fill f.txt 12 feature
  next_round 1 '[{"path":"untouched.txt","line":1,"severity":"error"},{"path":"untouched.txt","line":2,"severity":"suggestion"},{"path":"untouched.txt","line":3,"severity":"suggestion"}]'
  brief_check accept false 1 0 2
  [ "$(read_json "$BRIEF" '.verdict')" = quiet ]
}

@test "brief: stalled recommends stop" {
  cli_copy
  alf_sequence 5 5 5
  alf_add_checkpoint 3 stalled
  brief_check stop true 0 5 0
  [ "$(read_json "$BRIEF" '.verdict')" = stalled ]
}

@test "brief: enriching recommends accept" {
  cli_copy
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  brief_check accept false 0 4 0
  [ "$(read_json "$BRIEF" '.verdict')" = enriching ]
}

@test "brief: unknown recommends grant; a failing or hanging usage.sh only blanks spend" {
  local base mode
  cli_copy
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_stamp 1 10
  alf_sidecar "$MEMBER" "$(alf_entries f.txt 1 2)" 11
  brief_check grant false 0 2 0
  [ "$(read_json "$BRIEF" '.verdict')" = unknown ]
  base="$(read_json "$BRIEF" 'del(.spend, .evidence) | tojson')"
  for mode in fail hang; do
    STUB_USAGE_MODE="$mode" run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || return 1
    [ "$(read_json "$output" '.spend')" = unavailable ] || { echo "$mode spend: $(read_json "$output" '.spend')"; return 1; }
    [ "$(read_json "$output" 'del(.spend, .evidence) | tojson')" = "$base" ] || { echo "$mode changed another field"; return 1; }
  done
}

@test "pending checkpoint and closing round follow the answers; current-round counts history" {
  local state
  cli_copy
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 0 ]
  alf_sequence 4 4 4
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 3 ]
  [ -z "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" ]
  alf_add_checkpoint 3 stalled
  state="$(cat "$ALF_STATE")"
  [ "$(read_json "$(gaia_loop_pending_checkpoint "$state")" '.index')" = 1 ]
  [ "$(gaia_loop_next_closing "$state")" = false ]
  alf_add_answer 1 accept
  state="$(cat "$ALF_STATE")"
  [ -z "$(gaia_loop_pending_checkpoint "$state")" ]
  [ "$(gaia_loop_next_closing "$state")" = true ]
  alf_set_line other.txt 4 "round 4"
  alf_commit "round 4"
  alf_add_round "[\"$MEMBER\"]" true
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = false ]
  alf_add_checkpoint 4 allowance
  [ "$(read_json "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" '.index')" = 2 ]
}

@test "record-values: rounds, distinct trees per member, and grants" {
  cli_copy
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_add_round '["code-audit-frontend"]'
  alf_set_line other.txt 3 "round 3"
  alf_commit "round 3"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_add_checkpoint 3 allowance
  alf_add_answer 1 grant 2
  run "$CLI/audit-loop-eval.sh" record-values --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":3,"members":{"code-audit-frontend":3,"code-audit-maintainer-shell":2},"grants":1}' ]
}

@test "exit codes: detached is 4, corrupt state is 5, missing jq is 6, each with one diagnostic line" {
  cli_copy
  alf_sequence 2
  printf '{"schema":1,' >"$ALF_STATE"
  run --separate-stderr "$CLI/audit-loop-eval.sh" eval --root "$ALF_ROOT"
  [ "$status" -eq 5 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *corrupt*) ;; *) return 1 ;; esac
  PATH="$(path_shim_without jq)" run --separate-stderr "$CLI/audit-loop-eval.sh" eval --root "$ALF_ROOT"
  [ "$status" -eq 6 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *jq*) ;; *) return 1 ;; esac
  alf_git checkout -q --detach
  run --separate-stderr "$CLI/audit-loop-eval.sh" eval --root "$ALF_ROOT"
  [ "$status" -eq 4 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  case "$stderr" in *detached*) ;; *) return 1 ;; esac
}

# --- rubric signals, accept eligibility, gate decisions ----------------------

# K comes from the shared lib, so a change of K needs no edit here.
UNIT_ROUNDS() { printf '%s\n' "$GAIA_CONTEXT_UNIT_ROUNDS"; }

LOW="fresh 100000 1000000"
HIGH="fresh 400000 1000000"

# non_security_entries <entries-json> [severity]: the entries with security false and a severity.
non_security_entries() {
  jq -c --arg severity "${2:-warning}" 'map(. + {security: false, severity: $severity})' <<<"$1"
}

# rounds_sequence <entries-json>...: one round per argument on branch-added f.txt;
# every round's commit touches only other.txt, so no entry sits on a repaired line.
rounds_sequence() {
  local round=1 entries
  alf_fill f.txt 12 feature
  for entries in "$@"; do
    alf_set_line other.txt "$round" "round $round"
    alf_commit "round $round" || return 1
    alf_round "$round" "$MEMBER" "$entries" || return 1
    round=$((round + 1))
  done
}

# authored_count_sequence <severity> <A...>: rounds_sequence whose round r holds f.txt lines 1..A_r.
authored_count_sequence() {
  local severity="$1" authored_count
  local -a rows=()
  shift
  for authored_count in "$@"; do rows+=("$(non_security_entries "$(alf_entries f.txt 1 "$authored_count")" "$severity")"); done
  rounds_sequence "${rows[@]}"
}

# maintainer: make the fixture a maintainer repo (the triage rule present),
# kept out of every round commit.
maintainer() {
  mkdir -p "$ALF_ROOT/.claude/rules/maintainers"
  : >"$ALF_ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  printf '.claude/\n' >>"$ALF_ROOT/.git/info/exclude"
}

# only_signal <r> <signal> <decision>: round r raises exactly <signal>, is
# accept-eligible, and the unit decision on a fresh low reading is <decision>.
only_signal() {
  local snapshot decision
  snapshot="$(evaluate_round "$1")" || { echo "eval of round $1 failed"; return 1; }
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = "[\"$2\"]" ] ||
    { echo "reasons $(read_json "$snapshot" '.accept_reasons | tojson'), verdict $(read_json "$snapshot" '.verdict')"; return 1; }
  [ "$(read_json "$snapshot" '.accept_eligible')" = true ] || { echo "not eligible"; return 1; }
  [ "$(read_json "$snapshot" '[.signals | to_entries[] | select(.value) | .key] | tojson')" = "[\"$2\"]" ] || return 1
  decision="$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)"
  [ "$decision" = "$3" ] || { echo "decision '$decision', want '$3'"; return 1; }
}

# make_state <used> [jq-filter]: a synthetic state with <used> rounds and knobs 6/3.
make_state() {
  jq -n -c --argjson used "$1" '{schema: 1, key: "branch:feat/loop", branch: "feat/loop", pr: null,
    created_at: "2026-01-01T00:00:00Z",
    history: {rounds: [range(0; $used) | {round: (. + 1), tree: ("a" * 40), commit: ("b" * 40),
                raw_branch_slug: "feat-loop", dispatched_at: "2026-01-01T00:00:00Z", members: [], closing: false,
                snapshot: null}],
              checkpoints: [], knobs: {checkpoint_round: 6, grant_rounds: 3}},
    allowance: {answers: []}}' | jq -c "${2:-.}"
}

# unit_entry <unit> <start> <through> <after_checkpoint>: a units[] element.
unit_entry() {
  jq -n -c --argjson unit "$1" --argjson start_round "$2" --argjson through_round "$3" --argjson after_checkpoint "$4" --argjson unit_rounds "$(UNIT_ROUNDS)" \
    '{unit: $unit, start_round: $start_round, k: $unit_rounds, through_round: $through_round, admitted_on: "context", after_checkpoint: $after_checkpoint,
      recorded_at: "2026-01-01T00:00:00Z", session_id: "s1"}'
}

# checkpoint_entry <index> <at_round> <trigger>: a checkpoints[] element.
checkpoint_entry() {
  jq -n -c --argjson index "$1" --argjson at_round "$2" --arg trigger "$3" '{index: $index, at_round: $at_round, reason: $trigger, trigger: $trigger,
    recorded_at: "2026-01-01T00:00:00Z", session_id: "s1", audited_root: "/x"}'
}

# override_file: the per-machine line override of the fixture's main checkout.
override_file() {
  printf '%s/.gaia/local/%s\n' "$ALF_ROOT" checkpoint-override.json
}

@test "signal cap: round 10 of a converging branch raises only cap; the unit dispatch is denied cap" {
  maintainer
  authored_count_sequence warning 10 9 8 7 6 5 4 3 2 1
  only_signal 10 cap "deny cap true true"
}

@test "signal quiet: an empty A raises only quiet, which never denies" {
  maintainer
  rounds_sequence '[]'
  only_signal 1 quiet "allow context 2 $((2 + $(UNIT_ROUNDS) - 1))"
}

@test "signal enriching: a new key on a repaired line raises only enriching and denies" {
  maintainer
  authored_count_sequence warning 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(non_security_entries "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)")"
  only_signal 3 enriching "deny rubric:enriching true false"
}

@test "signal stalled: A 5,5,5 raises only stalled and denies" {
  maintainer
  authored_count_sequence warning 5 5 5
  only_signal 3 stalled "deny rubric:stalled true false"
}

@test "signal nitpicky: two all-Suggestion rounds at round 6 raise only nitpicky and deny" {
  maintainer
  authored_count_sequence suggestion 8 7 6 5 4 3
  only_signal 6 nitpicky "deny rubric:nitpicky true false"
}

@test "signal nitpicky needs both rounds: a Suggestion-only round after a warning round raises nothing" {
  local snapshot
  maintainer
  authored_count_sequence warning 8 7 6 5 4
  alf_set_line other.txt 6 "round 6"
  next_round 6 "$(non_security_entries "$(alf_entries f.txt 1 3)" suggestion)"
  snapshot="$(evaluate_round 6)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
}

@test "signal reintroduced: a key that vanished and came back raises only reintroduced and denies" {
  maintainer
  authored_count_sequence warning 3 2 3
  only_signal 3 reintroduced "deny rubric:reintroduced true false"
}

@test "signal reintroduced: a finding whose line moves three rounds running raises only reintroduced" {
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" suggestion)" "$(non_security_entries "$(alf_entries f.txt 4 5)" suggestion)" \
    "$(non_security_entries "$(alf_entries f.txt 6 6)" suggestion)"
  only_signal 3 reintroduced "deny rubric:reintroduced true false"
}

@test "signal small-tail: two findings with no progress at round 6 raise only small-tail and deny" {
  maintainer
  authored_count_sequence warning 6 5 4 3 2 2
  only_signal 6 small-tail "deny rubric:small-tail true false"
}

# drift_fixture: two rounds, each with half its four findings waived on the
# triage threshold in that round's own dispositions file.
drift_fixture() {
  local waive='[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":3,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"below threshold"},
                {"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":4,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"below threshold"}]'
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")"
  alf_dispositions 1 "$waive"
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_round 2 "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")"
  alf_dispositions 2 "$waive"
}

@test "signal waiver-drift: half of each of two rounds waived on the triage threshold raises only waiver-drift and denies" {
  local snapshot
  maintainer
  drift_fixture
  only_signal 2 waiver-drift "deny rubric:waiver-drift true false"
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '"\(.raw_count) \(.waived_count) \(.A)"')" = "4 2 2" ]
}

@test "red: waiver-drift is never raised outside a maintainer repo" {
  local snapshot
  drift_fixture
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.signals["waiver-drift"]')" = false ]
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
}

@test "red: no signal is not accept-eligible and the unit dispatch is allowed" {
  local snapshot
  maintainer
  authored_count_sequence warning 5 4
  snapshot="$(evaluate_round 2)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '[]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)" = "allow context 3 $((3 + $(UNIT_ROUNDS) - 1))" ]
}

@test "red: an unknown verdict with a signal holding is not accept-eligible" {
  local snapshot
  maintainer
  drift_fixture
  alf_store_snapshot 2
  alf_set_line other.txt 3 "round 3"
  alf_commit "round 3"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_stamp 3 30
  alf_sidecar "$MEMBER" "$(non_security_entries "$(alf_entries f.txt 1 4)")" 31
  alf_dispositions 3 "$(jq -c '.entries' "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/dispositions-2.json")"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = unknown ]
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["waiver-drift"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
}

@test "red: a security:true Suggestion in A(r) makes a signalling round ineligible" {
  local snapshot
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" suggestion)" "$(non_security_entries "$(alf_entries f.txt 4 5)" suggestion)" \
    '[{"path":"f.txt","line":6,"finding_class":"rule/x","severity":"suggestion","security":true}]'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["reintroduced"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" "$snapshot" "$LOW" 300000 50)" = "deny rubric:reintroduced false false" ]
}

@test "red: a Critical in A(r) makes a signalling round ineligible" {
  local snapshot
  maintainer
  authored_count_sequence warning 5 5
  alf_set_line other.txt 3 "round 3"
  next_round 3 "$(jq -c '.[0].severity = "error"' <<<"$(non_security_entries "$(alf_entries f.txt 1 5)")")"
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.accept_reasons | tojson')" = '["stalled"]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
}

@test "security normalization: absent reads true, false stays false, a non-boolean reads true; cross_remit only on true" {
  local findings
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" '[{"path":"f.txt","line":1},
    {"path":"f.txt","line":2,"security":false,"cross_remit":true},
    {"path":"f.txt","line":3,"security":"no","cross_remit":"yes"},
    {"path":"untouched.txt","line":4,"security":true}]'
  findings="$(gaia_loop_findings "$ALF_ROOT" "$(cat "$ALF_STATE")" 1)"
  [ "$(read_json "$findings" '[.entries[] | .security] | tojson')" = '[true,false,true,true]' ]
  [ "$(read_json "$findings" '[.entries[] | .cross_remit] | tojson')" = '[false,true,false,false]' ]
  [ "$(read_json "$findings" '[.entries[] | .authored] | tojson')" = '[true,true,true,false]' ]
  [ "$(read_json "$findings" '.entries[0] | keys | join(",")')" = "authored,cross_remit,finding_class,line,member,path,security,severity" ]
}

@test "security normalization: a round whose only A(r) entry is a security:false Suggestion stays eligible" {
  local snapshot
  maintainer
  rounds_sequence "$(non_security_entries "$(alf_entries f.txt 1 3)" suggestion)" "$(non_security_entries "$(alf_entries f.txt 4 5)" suggestion)" \
    '[{"path":"f.txt","line":6,"finding_class":"rule/x","severity":"suggestion","security":false}]'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.A')" = 1 ]
  [ "$(read_json "$snapshot" '.counted_keys[0].security')" = false ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = true ]
}

@test "red twin: the alternative-operator spelling turns security:false into true" {
  local copy="$BATS_TEST_TMPDIR/twin" twin_output
  mkdir -p "$copy"
  cp "$SCRIPTS"/*.sh "$copy"/
  grep -qF '(if (.security | type) == "boolean" then .security else true end)' "$copy/audit-loop-eval.sh"
  sed -i.bak 's/(if (.security | type) == "boolean" then .security else true end)/(.security \/\/ true)/' "$copy/audit-loop-eval.sh"
  grep -qF '(.security // true)' "$copy/audit-loop-eval.sh"
  alf_fill f.txt 12 feature
  alf_set_line other.txt 1 "round 1"
  alf_commit "round 1"
  alf_round 1 "$MEMBER" '[{"path":"f.txt","line":2,"security":false}]'
  twin_output="$(bash -c '. "$1/audit-loop-eval.sh"; gaia_loop_findings "$2" "$(cat "$3")" 1' _ "$copy" "$ALF_ROOT" "$ALF_STATE")"
  [ "$(read_json "$twin_output" '.entries[0].security')" = true ]
  [ "$(read_json "$(gaia_loop_findings "$ALF_ROOT" "$(cat "$ALF_STATE")" 1)" '.entries[0].security')" = false ]
}

@test "decision: 6 rounds used, a fresh reading below the line and no signal admit a unit past the fallback checkpoint" {
  local state
  state="$(make_state 6)"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow context 7 $((6 + $(UNIT_ROUNDS)))" ]
  # red: the round-count decision on the same state denies.
  [ "$(gaia_loop_decide "$state" null)" = "deny allowance" ]
}

@test "decision: a missing, stale, future or unparseable reading falls back to the round count" {
  local reading
  for reading in missing stale future unparseable "fresh abc 1" "fresh 0100 1000000" ""; do
    [ "$(gaia_loop_decide_unit "$(make_state 5)" null "$reading" 300000 50)" = "allow fallback 6 6" ] ||
      { echo "5 used, '$reading': $(gaia_loop_decide_unit "$(make_state 5)" null "$reading" 300000 50)"; return 1; }
    [ "$(gaia_loop_decide_unit "$(make_state 6)" null "$reading" 300000 50)" = "deny fallback false false" ] ||
      { echo "6 used, '$reading'"; return 1; }
  done
}

@test "decision: over the line denies context; an answer to the latest checkpoint admits exactly one unit" {
  local state unit_rounds checkpoint
  unit_rounds="$(UNIT_ROUNDS)"
  checkpoint="$(checkpoint_entry 1 3 context)"
  state="$(make_state 3)"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
  state="$(make_state 3 ".history.checkpoints = [$checkpoint] | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: $unit_rounds, source: \"ask\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "allow grant 4 $((3 + unit_rounds))" ]
  state="$(jq -c --argjson unit "$(unit_entry 1 4 $((3 + unit_rounds)) 1)" '.history.units = [$unit]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
  state="$(make_state 3 ".history.checkpoints = [$checkpoint] | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "allow accept 4 4" ]
}

@test "decision: an accept admits its closing round even on a fresh reading below the line" {
  local state
  state="$(make_state 3 ".history.checkpoints = [$(checkpoint_entry 1 3 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow accept 4 4" ]
  [ "$(gaia_loop_decide_member "$state" null false "$LOW" 300000 50)" = "allow accept 4 4" ]
}

@test "red: once the accepted closing round is recorded, a fresh reading below the line admits nothing" {
  local state
  state="$(make_state 4 ".history.checkpoints = [$(checkpoint_entry 1 3 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"accept\", at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 4 4 1)]")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "deny fallback false false" ]
  [ "$(gaia_loop_decide_member "$state" null false "$LOW" 300000 50)" = "deny fallback false false" ]
  # The checkpoint that deny records stays unanswered, and the spent accept
  # still denies on the next dispatch.
  state="$(jq -c --argjson checkpoint "$(checkpoint_entry 2 4 fallback)" '.history.checkpoints += [$checkpoint]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "deny fallback false false" ]
  # A grant answering that checkpoint admits again.
  state="$(jq -c '.allowance.answers += [{checkpoint: 2, kind: "grant", n: 3, at: "x", session_id: "s1"}]' <<<"$state")"
  [ "$(gaia_loop_decide_unit "$state" null "$LOW" 300000 50)" = "allow grant 5 $((4 + $(UNIT_ROUNDS)))" ]
}

@test "red: a grant answering an older checkpoint, not the latest, admits nothing" {
  local state
  state="$(make_state 3 ".history.checkpoints = [$(checkpoint_entry 1 2 context), $(checkpoint_entry 2 3 context)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: 3, at: \"x\", session_id: \"s1\"}]")"
  [ "$(gaia_loop_decide_unit "$state" null "$HIGH" 300000 50)" = "deny context false false" ]
}

@test "decision: the effective line config is the frozen value lowered by the live override" {
  local settings state effective
  settings="$(override_file)"
  mkdir -p "${settings%/*}"
  state="$(make_state 3 '.history.context_config = {ask_tokens: 300000, ask_window_pct: 50}')"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":600000,"ask_window_pct":50}}\n' >"$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "300000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 350000 1000000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 290000 1000000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  printf '{"version":1,"context_checkpoint":{"ask_tokens":250000,"ask_window_pct":50}}\n' >"$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "250000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 260000 1000000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 240000 1000000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  rm "$settings"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$(gaia_loop_decide_unit "$state" null "fresh 120000 200000" $effective)" = "deny context false false" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 90000 200000" $effective)" = "allow context 4 $((3 + $(UNIT_ROUNDS)))" ]
  state="$(make_state 3 '.history.context_config = {ask_tokens: 250000, ask_window_pct: 50}')"
  effective="$(gaia_loop_context_config_effective "$ALF_ROOT" "$state")"
  [ "$effective" = "250000 50" ]
  [ "$(gaia_loop_decide_unit "$state" null "fresh 260000 1000000" $effective)" = "deny context false false" ]
}

@test "decision: at 10 rounds every path denies cap, though the fold itself stays uncapped" {
  local state reading
  state="$(make_state 10 ".history.checkpoints = [$(checkpoint_entry 1 10 fallback)]
    | .allowance.answers = [{checkpoint: 1, kind: \"grant\", n: 3, at: \"x\", session_id: \"s1\"}]
    | .history.units = [$(unit_entry 1 8 10 0)]")"
  [ "$(gaia_loop_allowed "$state")" = 13 ]
  for reading in "$LOW" "$HIGH" missing; do
    [ "$(gaia_loop_decide_unit "$state" null "$reading" 300000 50)" = "deny cap false true" ] || { echo "unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null true "$reading" 300000 50)" = "deny cap false true" ] || { echo "member in-unit, $reading"; return 1; }
    [ "$(gaia_loop_decide_member "$state" null false "$reading" 300000 50)" = "deny cap false true" ] || { echo "member inline, $reading"; return 1; }
  done
  [ "$(gaia_loop_decide "$state" null)" = "deny cap" ]
}

@test "decision: a member in a unit is allowed only inside the unit's window" {
  local unit_rounds used state
  unit_rounds="$(UNIT_ROUNDS)"
  used=6
  while [ "$used" -le $((6 + unit_rounds)) ]; do
    state="$(make_state "$used" ".history.units = [$(unit_entry 1 7 $((6 + unit_rounds)) 0)]")"
    if [ "$used" -lt $((6 + unit_rounds)) ]; then
      [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = allow ] || { echo "used $used"; return 1; }
    else
      [ "$(gaia_loop_decide_member "$state" null true "$LOW" 300000 50)" = "deny window false false" ] || { echo "used $used"; return 1; }
    fi
    used=$((used + 1))
  done
  [ "$(gaia_loop_decide_member "$(make_state 6)" null true "$LOW" 300000 50)" = "deny window false false" ]
  state="$(make_state 7 ".history.units = [$(unit_entry 1 7 $((6 + unit_rounds)) 0)]")"
  [ "$(gaia_loop_decide_member "$state" '{"round":7,"verdict":"continue","signals":{"stalled":true}}' true "$LOW" 300000 50)" = "deny rubric:stalled false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 5)" null false "$HIGH" 300000 50)" = "deny context false false" ]
  [ "$(gaia_loop_decide_member "$(make_state 5)" null false missing 300000 50)" = "allow fallback 6 6" ]
}

@test "vetoes: a vetoed key re-enters A from its effective round, whatever was disposed" {
  local vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json" key
  authored_count_sequence warning 3 3 3
  alf_dispositions 1 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"waive-out-of-scope","basis":"triage-threshold","reason":"r"}]'
  key='{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"vetoed_at":"x","unit":1'
  [ "$(read_json "$(evaluate_round 1)" '.A')" = 3 ]
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 2 ]
  printf '{"version":1,"keys":[%s,"effective_from_round":3}]}\n' "$key" >"$vetoes"
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 2 ]
  [ "$(read_json "$(evaluate_round 3)" '.A')" = 3 ]
  printf '{"version":1,"keys":[%s,"effective_from_round":2}]}\n' "$key" >"$vetoes"
  [ "$(read_json "$(evaluate_round 1)" '.A')" = 3 ]
  [ "$(read_json "$(evaluate_round 2)" '.A')" = 3 ]
  # red: without the veto the waiver holds again.
  printf '{"version":1,"keys":[]}\n' >"$vetoes"
  [ "$(read_json "$(evaluate_round 3)" '.A')" = 2 ]
}

@test "red: an unreadable or malformed vetoes.json fails the evaluation" {
  local vetoes="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json" body
  authored_count_sequence warning 3 3
  mkdir -p "${vetoes%/*}"
  for body in 'not json' '{"version":1,"keys":[]} {"version":1,"keys":[]}' '{"version":2,"keys":[]}' \
    '{"version":1,"keys":[{"member":"m","finding_class":"c","path":"p","line":1}]}'; do
    printf '%s\n' "$body" >"$vetoes"
    run evaluate_round 2
    [ "$status" -ne 0 ] || { echo "accepted: $body"; return 1; }
  done
  rm "$vetoes"
  run evaluate_round 2
  [ "$status" -eq 0 ]
}

@test "legacy: a frozen checkpoint of 5 keeps 5; no frozen line config reads min(default, override)" {
  local settings
  settings="$(override_file)"
  [ "$(gaia_loop_allowed "$(make_state 2 '.history.knobs.checkpoint_round = 5')")" = 5 ]
  [ "$(gaia_loop_allowed "$(make_state 2)")" = 6 ]
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3)")" = "300000 50" ]
  mkdir -p "${settings%/*}"
  printf '{"version":1,"context_checkpoint":{"ask_tokens":250000,"ask_window_pct":40}}\n' >"$settings"
  [ "$(gaia_loop_context_config_effective "$ALF_ROOT" "$(make_state 3)")" = "250000 40" ]
  [ "$(gaia_loop_context_config_initial "$ALF_ROOT")" = '{"ask_tokens":250000,"ask_window_pct":40}' ]
}

@test "legacy: a stored snapshot without counted_keys turns the history signals off and eligibility false" {
  local snapshot
  maintainer
  authored_count_sequence warning 6 5 4 3 2 2
  [ "$(read_json "$(evaluate_round 6)" '.signals["small-tail"]')" = true ]
  alf_state_edit 'del(.history.rounds[4].snapshot.counted_keys)'
  snapshot="$(evaluate_round 6)"
  [ "$(read_json "$snapshot" '[.signals["small-tail"], .signals.nitpicky, .signals.reintroduced, .signals["waiver-drift"]] | tojson')" = '[false,false,false,false]' ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
}

@test "legacy: a legacy round r-2 turns reintroduced off; waiver-drift needs a new round r-1" {
  local snapshot
  maintainer
  authored_count_sequence warning 3 2 3
  alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.signals.reintroduced')" = false ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/origin.git"
  alf_init
  alf_branch feat/loop
  maintainer
  drift_fixture
  alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
  [ "$(read_json "$(evaluate_round 2)" '.signals["waiver-drift"]')" = false ]
}

@test "legacy: the enriching verdict still reads the stored keys of round r-1" {
  local snapshot
  authored_count_sequence warning 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(non_security_entries "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)")"
  alf_state_edit 'del(.history.rounds[1].snapshot.counted_keys)'
  snapshot="$(evaluate_round 3)"
  [ "$(read_json "$snapshot" '.verdict')" = enriching ]
  [ "$(read_json "$snapshot" '.signals.enriching')" = true ]
  [ "$(read_json "$snapshot" '.accept_eligible')" = false ]
  # a legacy snapshot with no signals still denies on its verdict.
  [ "$(gaia_loop_decide_unit "$(cat "$ALF_STATE")" '{"round":3,"verdict":"enriching"}' "$LOW" 300000 50)" = "deny rubric:enriching false false" ]
}

@test "CLI: next-unit, unit-window and pinned-question" {
  local question='{"questions":[{"question":"q","header":"Audit loop","multiSelect":false,"options":[{"label":"Stop and file the remainder","description":"d"},{"label":"Accept the remainder","description":"d"}]}]}'
  cli_copy
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_sequence 4 3
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$output" = "1 3" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_state_edit '.history.units = [$unit]' --argjson unit "$(unit_entry 1 3 $((2 + $(UNIT_ROUNDS))) 0)"
  run "$CLI/audit-loop-eval.sh" next-unit --root "$ALF_ROOT"
  [ "$output" = "2 3" ]
  run "$CLI/audit-loop-eval.sh" unit-window --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1 3 $((2 + $(UNIT_ROUNDS)))" ]
  alf_add_checkpoint 2 context
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
  alf_state_edit '.history.checkpoints[-1].question = $question' --argjson question "$question"
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -c . <<<"$question")" ]
  alf_add_answer 1 accept
  run "$CLI/audit-loop-eval.sh" pinned-question --root "$ALF_ROOT"
  [ "$status" -eq 2 ]
}

@test "CLI: the unit subcommands leave the state byte-identical and take no lock" {
  local state_copy subcommand
  cli_copy
  alf_sequence 4 3
  alf_state_edit '.history.units = [$unit]' --argjson unit "$(unit_entry 1 3 4 0)"
  state_copy="$(snapshot_file "$ALF_STATE")"
  for subcommand in next-unit unit-window pinned-question; do
    run "$CLI/audit-loop-eval.sh" "$subcommand" --root "$ALF_ROOT"
    assert_files_identical "$state_copy" "$ALF_STATE" || { echo "$subcommand changed the state"; return 1; }
    [ -e "$ALF_STATE.lock" ] && { echo "$subcommand took the lock"; return 1; }
  done
  true
}

@test "brief: reports the signals and the cap; a context checkpoint recommends grant unless a denying signal holds" {
  cli_copy
  rounds_sequence '[]'
  alf_add_checkpoint 1 context
  alf_state_edit '.history.checkpoints[-1].trigger = "context"'
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(read_json "$output" '.verdict')" = quiet ]
  [ "$(read_json "$output" '.recommended')" = grant ]
  [ "$(read_json "$output" '.rounds_cap')" = 10 ]
  [ "$(read_json "$output" '.accept_eligible')" = true ]
  [ "$(read_json "$output" '.accept_reasons | tojson')" = '["quiet"]' ]
  [ "$(read_json "$output" '.signals.quiet')" = true ]
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/origin.git"
  alf_init
  alf_branch feat/loop
  cli_copy
  authored_count_sequence warning 5 5 5
  alf_add_checkpoint 3 context
  alf_state_edit '.history.checkpoints[-1].trigger = "context"'
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$(read_json "$output" '.verdict')" = stalled ]
  [ "$(read_json "$output" '.recommended')" = stop ]
}
