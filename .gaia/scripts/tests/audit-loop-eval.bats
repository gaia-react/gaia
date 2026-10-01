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
# AUDIT_LOOP_SCRIPTS_DIR points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-eval.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIR:-$REPO_ROOT/.gaia/scripts}"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS
  # brief reads spend through usage.sh, which reaches the pricing path.
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
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
  M=code-audit-frontend
}

# ev <r>: round r's snapshot through the sourced function (what the hook runs).
ev() {
  gaia_loop_eval_round "$ALF_ROOT" "$(cat "$ALF_STATE")" "$1"
}

# jf <json> <filter>: one jq read.
jf() {
  printf '%s' "$1" | jq -r "$2"
}

# plus <entries-json> <path> <line-json>: append one entry.
plus() {
  jq -n -c --argjson a "$1" --arg p "$2" --argjson l "$3" '$a + [{path: $p, line: $l, finding_class: "rule/x"}]'
}

# next_round <r> <entries-json>: commit the working tree as round r.
next_round() {
  alf_commit "round $1"
  alf_round "$1" "$M" "$2"
}

# cli_copy: the scripts in a scratch dir beside a stub usage.sh whose
# behaviour STUB_USAGE_MODE (ok, fail, hang) picks. Sets CLI.
cli_copy() {
  local f
  CLI="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$CLI"
  for f in audit-loop-eval.sh audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh; do
    cp "$SCRIPTS/$f" "$CLI/$f"
  done
  cat >"$CLI/usage.sh" <<'EOF'
case "${STUB_USAGE_MODE:-ok}" in
  ok) printf 'spend for %s: 1.23 USD\n' "$3" ;;
  fail) exit 1 ;;
  hang) sleep 30; printf 'late\n' ;;
esac
EOF
}

# seq_case <verdict> <decision> <A...>: build the A sequence and check the
# last round's verdict and the hook's decision on it.
seq_case() {
  local want="$1" decision="$2" snap n
  shift 2
  alf_sequence "$@"
  n=$#
  snap="$(ev "$n")"
  [ "$(jf "$snap" '.A')" = "${!n}" ] || { echo "A was $(jf "$snap" '.A'), want ${!n}"; return 1; }
  [ "$(jf "$snap" '.verdict')" = "$want" ] || { echo "verdict $(jf "$snap" '.verdict'), want $want"; return 1; }
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snap")" = "$decision" ]
}

@test "UAT-006: A 5,5,5 is stalled and denies" {
  seq_case stalled "deny stalled" 5 5 5
}

@test "UAT-006: A 5,6,7 is stalled and denies" {
  seq_case stalled "deny stalled" 5 6 7
}

@test "UAT-006: A 5,4,4 continues and allows" {
  seq_case continue allow 5 4 4
}

@test "UAT-006: A 5,5,4 continues and allows" {
  seq_case continue allow 5 5 4
}

@test "UAT-006: A 5,5 continues and allows" {
  seq_case continue allow 5 5
}

@test "directive 8: A 3,2,1,1,1 continues at round 4 and stalls at round 5" {
  local snap
  alf_sequence 3 2 1 1 1
  [ "$(jq -r '.history.rounds[3].snapshot.verdict' "$ALF_STATE")" = continue ]
  snap="$(ev 5)"
  [ "$(jf "$snap" '.verdict')" = stalled ]
  [ "$(jf "$snap" '.evidence.A_series | map(tostring) | join(",")')" = "3,2,1,1,1" ]
}

@test "UAT-007 (i): a new key on a repaired line at round 3 is enriching and named" {
  local snap
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  snap="$(ev 3)"
  [ "$(jf "$snap" '.verdict')" = enriching ]
  [ "$(jf "$snap" '.evidence.new_keys_on_repaired_lines | tojson')" = '[["code-audit-frontend","rule/x","f.txt",8]]' ]
}

@test "UAT-007 (ii): a persisting key on a repaired line while A falls continues" {
  alf_sequence 6 5
  alf_set_line f.txt 2 repaired
  next_round 3 "$(alf_entries f.txt 1 3)"
  [ "$(jf "$(ev 3)" '.verdict')" = continue ]
}

@test "UAT-007 (iii): a new key on an unchanged line of a repaired path continues" {
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 10)"
  [ "$(jf "$(ev 3)" '.verdict')" = continue ]
}

@test "UAT-007 (iv): the enriching shape at round 2 continues" {
  alf_sequence 6
  alf_set_line f.txt 8 repaired
  next_round 2 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(jf "$(ev 2)" '.verdict')" = continue ]
}

@test "directive 8: a deletion-only hunk never makes enriching" {
  local snap
  alf_sequence 6 5
  awk 'NR != 12' "$ALF_ROOT/f.txt" >"$ALF_ROOT/f.tmp" && mv "$ALF_ROOT/f.tmp" "$ALF_ROOT/f.txt"
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt 11)"
  snap="$(ev 3)"
  [ "$(jf "$snap" '.A')" = 3 ]
  [ "$(jf "$snap" '.verdict')" = continue ]
}

@test "directive 8: a pure rename never makes enriching" {
  local snap
  alf_sequence 6 5
  alf_git mv other.txt renamed.txt
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" renamed.txt 1)"
  snap="$(ev 3)"
  [ "$(jf "$snap" '.A')" = 3 ]
  [ "$(jf "$snap" '.verdict')" = continue ]
}

@test "directive 8: a null line never makes enriching" {
  local snap
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 2)" f.txt null)"
  snap="$(ev 3)"
  [ "$(jf "$snap" '.A')" = 3 ]
  [ "$(jf "$snap" '.verdict')" = continue ]
}

@test "COV-017: the enriching shape after a round with missing evidence continues" {
  local snap
  alf_sequence 6
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2"
  alf_store_snapshot 1
  alf_add_round "[\"$M\"]"
  alf_stamp 2 20
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(jq -r '.history.rounds[1].snapshot.verdict' "$ALF_STATE")" = unknown ]
  snap="$(ev 3)"
  [ "$(jf "$snap" '.verdict')" = continue ]
}

@test "COV-003: a sidecar written after the round's baseline is never evidence" {
  local snap
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$M\"]"
  alf_stamp 1 10
  alf_sidecar "$M" "$(alf_entries f.txt 1 3)" 11
  alf_baseline 1 15
  alf_sidecar "$M" "$(alf_entries f.txt 1 7)" 16 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  snap="$(ev 1)"
  [ "$(jf "$snap" '.A')" = 3 ]
  rm "$ALF_ROOT"/.gaia/local/audit/aaaa*.findings.json
  snap="$(ev 1)"
  [ "$(jf "$snap" '.verdict')" = unknown ]
  [ "$(jf "$snap" '.A')" = null ]
}

@test "grant window: enriching is off at the granted round and back on the round after" {
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  [ "$(jf "$(ev 3)" '.verdict')" = enriching ]
  alf_add_checkpoint 3 enriching
  alf_add_answer 1 grant 3
  [ "$(jf "$(ev 3)" '.verdict')" = continue ]
  alf_set_line f.txt 9 repaired
  next_round 4 "$(plus "$(plus "$(alf_entries f.txt 1 2)" f.txt 8)" f.txt 9)"
  [ "$(jf "$(ev 4)" '.verdict')" = enriching ]
}

@test "grant window: stalled is off the round after a grant and back on the round after that" {
  alf_sequence 5 5 5
  [ "$(jf "$(ev 3)" '.verdict')" = stalled ]
  alf_add_checkpoint 3 stalled
  alf_add_answer 1 grant 3
  [ "$(jf "$(ev 3)" '.verdict')" = continue ]
  alf_set_line other.txt 4 "round 4"
  next_round 4 "$(alf_entries f.txt 1 5)"
  [ "$(jf "$(ev 4)" '.verdict')" = continue ]
  alf_set_line other.txt 5 "round 5"
  next_round 5 "$(alf_entries f.txt 1 5)"
  [ "$(jf "$(ev 5)" '.verdict')" = stalled ]
}

@test "UAT-008: only non-authored or disposed entries is quiet with a non-empty set; a null line on a changed path is not" {
  local rows snap
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
  snap="$(ev 2)"
  [ "$(jf "$snap" '.A')" = 0 ]
  [ "$(jf "$snap" '.keys | length')" -gt 0 ]
  [ "$(jf "$snap" '.verdict')" = quiet ]
  alf_sidecar "$M" "$(plus "$rows" f.txt null)" 22
  snap="$(ev 2)"
  [ "$(jf "$snap" '.A')" = 1 ]
  [ "$(jf "$snap" '.verdict')" = continue ]
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
  local variant snap two='["code-audit-frontend","code-audit-maintainer-shell"]'
  local shell="$ALF_ROOT/.gaia/local/audit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.$ALF_SLUG.code-audit-maintainer-shell.findings.json"
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "$two"
  alf_stamp 1 10
  alf_sidecar "$M" "$(alf_entries f.txt 1 2)" 11
  for variant in missing stale unparseable; do
    rm -f "$shell"
    case "$variant" in
      stale) alf_sidecar code-audit-maintainer-shell '[]' 5 ;;
      unparseable) printf 'not json' >"$shell" && touch -t "$(alf_time 12)" "$shell" ;;
    esac
    snap="$(ev 1)"
    [ "$(jf "$snap" '.verdict')" = unknown ] || { echo "$variant gave $(jf "$snap" '.verdict')"; return 1; }
    [ "$(jf "$snap" '.A')" = null ] || return 1
    [ "$(jf "$snap" '.evidence.missing_members | tojson')" = '["code-audit-maintainer-shell"]' ] || return 1
  done
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snap")" = allow ]
  alf_state_edit '.history.knobs.checkpoint_round = 1'
  [ "$(gaia_loop_decide "$(cat "$ALF_STATE")" "$snap")" = "deny allowance" ]
}

@test "UAT-030: each round keeps its own merge base; stored A is read, never recomputed" {
  local snap mb2
  alf_sequence 5 5
  mb2="$(jq -r '.history.rounds[0].snapshot.merge_base' "$ALF_STATE")"
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$M\"]"
  alf_stamp 3 30
  alf_sidecar "$M" "$(plus "$(alf_entries f.txt 1 5)" base.txt 18)" 31
  snap="$(ev 3)"
  [ "$(jf "$snap" '.merge_base')" = "$(alf_git rev-parse origin/main)" ]
  [ "$(jf "$snap" '.merge_base')" != "$mb2" ]
  [ "$(jq -r '.history.rounds[1].snapshot.merge_base' "$ALF_STATE")" = "$mb2" ]
  [ "$(jf "$snap" '.A')" = 5 ]
  [ "$(jf "$snap" '.verdict')" = stalled ]
  alf_state_edit '.history.rounds[1].snapshot.A = 6'
  snap="$(ev 3)"
  [ "$(jf "$snap" '.verdict')" = continue ]
  [ "$(jq -r '[.history.rounds[].tree] | unique | length' "$ALF_STATE")" = 3 ]
}

@test "directive 10: a new key on an upstream-merged line is not authored, so never enriching" {
  local snap
  alf_sequence 6 5
  alf_upstream_change base.txt 18 "upstream edit"
  alf_store_snapshot 2
  alf_add_round "[\"$M\"]"
  alf_stamp 3 30
  alf_sidecar "$M" "$(plus "$(alf_entries f.txt 1 3)" base.txt 18)" 31
  snap="$(ev 3)"
  [ "$(jf "$snap" '.A')" = 3 ]
  [ "$(jf "$snap" '.verdict')" = continue ]
}

@test "UAT-031: invalid rows count as authored; row text never reaches git argv; nothing written outside" {
  local row snap stub log real before after t=40
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round "[\"$M\"]"
  alf_stamp 1 10
  for row in '{"path":"-rf","line":1}' '{"path":"a/../b","line":1}' '{"path":"f.txt","line":"x"}' '{"path":"f.txt","line":-1}'; do
    t=$((t + 1))
    alf_sidecar "$M" "[$row]" "$t"
    [ "$(jf "$(ev 1)" '.A')" = 1 ] || { echo "not counted: $row"; return 1; }
  done
  stub="$BATS_TEST_TMPDIR/stub"
  log="$stub/git.log"
  real="$(command -v git)"
  mkdir -p "$stub"
  : >"$log"
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >>"%s"\nprintf "%%s\\n" "--END--" >>"%s"\nexec "%s" "$@"\n' "$log" "$log" "$real" >"$stub/git"
  chmod +x "$stub/git"
  alf_sidecar "$M" '[{"path":"-rf","line":1},{"path":"a/../b","line":null},{"path":"f.txt","line":"x"},{"path":"f.txt","line":-1}]' 50
  before="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  snap="$(PATH="$stub:$PATH" ev 1)"
  after="$(find "$BATS_TEST_TMPDIR" "$ALF_ROOT/.gaia/local" ! -name git.log | LC_ALL=C sort)"
  [ "$(jf "$snap" '.A')" = 4 ]
  [ "$before" = "$after" ]
  [ -e "$PWD/-rf" ] && return 1
  [ -e "$ALF_ROOT/-rf" ] && return 1
  # Every diff invocation ends its revisions with `--`; no row path is argv.
  awk '/^--END--$/ { if (isdiff && !dd) bad = 1; isdiff = 0; dd = 0; n++; next }
       $0 == "diff" { isdiff = 1 } $0 == "--" { dd = 1 }
       $0 == "-rf" || $0 == "a/../b" { bad = 1 }
       END { exit (bad || n == 0) }' "$log"
  [ "$(grep -c '^diff$' "$log")" -ge 2 ]
}

@test "UAT-019: every CLI subcommand leaves the state file byte-identical and takes no lock" {
  local snap sub
  cli_copy
  alf_sequence 4 3
  alf_store_snapshot 2
  snap="$(snapshot_file "$ALF_STATE")"
  for sub in findings eval brief record-values state-path current-round; do
    run "$CLI/audit-loop-eval.sh" "$sub" --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || { echo "$sub exited $status: $output"; return 1; }
    assert_files_identical "$snap" "$ALF_STATE" || { echo "$sub changed the state"; return 1; }
    [ -e "$ALF_STATE.lock" ] && { echo "$sub took the lock"; return 1; }
  done
  run "$CLI/audit-loop-eval.sh" state-path --root "$ALF_ROOT"
  [ "$output" = "$ALF_STATE" ]
}

@test "allowance fold: defaults, then a grant at round 5" {
  local st
  alf_sequence 2
  st="$(cat "$ALF_STATE")"
  [ "$(gaia_loop_allowed "$st")" = 5 ]
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
  local st v
  alf_sequence 2
  st="$(cat "$ALF_STATE")"
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_allowed "$st")" = 5 ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=4 gaia_loop_allowed "$st")" = 4 ]
  for v in 0 -1 abc ''; do
    [ "$(GAIA_AUDIT_CHECKPOINT_ROUND="$v" gaia_loop_allowed "$st" 2>/dev/null)" = 5 ] || { echo "'$v' moved it"; return 1; }
  done
  run --separate-stderr env GAIA_AUDIT_CHECKPOINT_ROUND=abc bash -c '. "$1"; gaia_loop_allowed "$2"' _ "$SCRIPTS/audit-loop-eval.sh" "$st"
  [ "$output" = 5 ]
  case "$stderr" in *GAIA_AUDIT_CHECKPOINT_ROUND*) ;; *) return 1 ;; esac
}

@test "knobs: frozen at round 1, capped at the defaults" {
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=2 GAIA_AUDIT_GRANT_ROUNDS=1 gaia_loop_knobs_initial)" = '{"checkpoint_round":2,"grant_rounds":1}' ]
  [ "$(gaia_loop_knobs_initial)" = '{"checkpoint_round":5,"grant_rounds":3}' ]
  [ "$(GAIA_AUDIT_CHECKPOINT_ROUND=9 gaia_loop_knobs_initial | jq -r '.checkpoint_round')" = 5 ]
  [ "$(GAIA_AUDIT_GRANT_ROUNDS=7 gaia_loop_knobs_initial | jq -r '.grant_rounds')" = 3 ]
}

# brief_check <recommended> <pending> <error> <warning> <suggestion>: run the
# CLI brief and check the fields every verdict shares.
brief_check() {
  run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
  [ "$status" -eq 0 ] || { echo "brief exited $status: $output"; return 1; }
  BRIEF="$output"
  [ "$(jf "$BRIEF" '.recommended')" = "$1" ] || { echo "recommended $(jf "$BRIEF" '.recommended')"; return 1; }
  [ "$(jf "$BRIEF" '.pending_checkpoint')" = "$2" ] || return 1
  [ "$(jf "$BRIEF" '.grant_line')" = "$(gaia_loop_grant_line 3)" ] || return 1
  [ "$(jf "$BRIEF" '.accept_line')" = "$(gaia_loop_accept_line)" ] || return 1
  [ "$(jf "$BRIEF" '.remaining_by_severity | "\(.error),\(.warning),\(.suggestion)"')" = "$3,$4,$5" ] || { echo "severity $(jf "$BRIEF" '.remaining_by_severity')"; return 1; }
  [ "$(jf "$BRIEF" '.spend')" = "spend for feat/loop: 1.23 USD" ] || { echo "spend $(jf "$BRIEF" '.spend')"; return 1; }
  [ "$(jf "$BRIEF" '.spend_note')" = "information only" ]
}

@test "brief: continue at an allowance checkpoint recommends grant" {
  cli_copy
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  brief_check grant true 0 2 0
  [ "$(jf "$BRIEF" '.verdict')" = continue ]
  [ "$(jf "$BRIEF" '.rounds_run')" = 5 ]
  [ "$(jf "$BRIEF" '.allowed')" = 5 ]
  [ "$(jf "$BRIEF" '[.per_round[].A] | map(tostring) | join(",")')" = "6,5,4,3,2" ]
}

@test "brief: quiet recommends accept" {
  cli_copy
  alf_fill f.txt 12 feature
  next_round 1 '[{"path":"untouched.txt","line":1,"severity":"error"},{"path":"untouched.txt","line":2,"severity":"suggestion"},{"path":"untouched.txt","line":3,"severity":"suggestion"}]'
  brief_check accept false 1 0 2
  [ "$(jf "$BRIEF" '.verdict')" = quiet ]
}

@test "brief: stalled recommends stop" {
  cli_copy
  alf_sequence 5 5 5
  alf_add_checkpoint 3 stalled
  brief_check stop true 0 5 0
  [ "$(jf "$BRIEF" '.verdict')" = stalled ]
}

@test "brief: enriching recommends accept" {
  cli_copy
  alf_sequence 6 5
  alf_set_line f.txt 8 repaired
  next_round 3 "$(plus "$(alf_entries f.txt 1 3)" f.txt 8)"
  brief_check accept false 0 4 0
  [ "$(jf "$BRIEF" '.verdict')" = enriching ]
}

@test "brief: unknown recommends grant; a failing or hanging usage.sh only blanks spend" {
  local base mode
  cli_copy
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  alf_add_round '["code-audit-frontend","code-audit-maintainer-shell"]'
  alf_stamp 1 10
  alf_sidecar "$M" "$(alf_entries f.txt 1 2)" 11
  brief_check grant false 0 2 0
  [ "$(jf "$BRIEF" '.verdict')" = unknown ]
  base="$(jf "$BRIEF" 'del(.spend, .evidence) | tojson')"
  for mode in fail hang; do
    STUB_USAGE_MODE="$mode" run "$CLI/audit-loop-eval.sh" brief --root "$ALF_ROOT"
    [ "$status" -eq 0 ] || return 1
    [ "$(jf "$output" '.spend')" = unavailable ] || { echo "$mode spend: $(jf "$output" '.spend')"; return 1; }
    [ "$(jf "$output" 'del(.spend, .evidence) | tojson')" = "$base" ] || { echo "$mode changed another field"; return 1; }
  done
}

@test "pending checkpoint and closing round follow the answers; current-round counts history" {
  local st
  cli_copy
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 0 ]
  alf_sequence 4 4 4
  run "$CLI/audit-loop-eval.sh" current-round --root "$ALF_ROOT"
  [ "$output" = 3 ]
  [ -z "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" ]
  alf_add_checkpoint 3 stalled
  st="$(cat "$ALF_STATE")"
  [ "$(jf "$(gaia_loop_pending_checkpoint "$st")" '.index')" = 1 ]
  [ "$(gaia_loop_next_closing "$st")" = false ]
  alf_add_answer 1 accept
  st="$(cat "$ALF_STATE")"
  [ -z "$(gaia_loop_pending_checkpoint "$st")" ]
  [ "$(gaia_loop_next_closing "$st")" = true ]
  alf_set_line other.txt 4 "round 4"
  alf_commit "round 4"
  alf_add_round "[\"$M\"]" true
  [ "$(gaia_loop_next_closing "$(cat "$ALF_STATE")")" = false ]
  alf_add_checkpoint 4 allowance
  [ "$(jf "$(gaia_loop_pending_checkpoint "$(cat "$ALF_STATE")")" '.index')" = 2 ]
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
