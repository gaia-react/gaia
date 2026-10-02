#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-dispositions-check.sh: the dispositions rules
# graded from the findings sidecars, frozen snapshots, forward-only vetoes,
# the waiver table and the PR-body sections.
#
# Fixtures are real: a repo with a branch-added file, a seeded branch state, a
# stamp and baseline per round, and findings sidecars with controlled mtimes
# (.gaia/tests/helpers/audit-loop-fixture.sh). Dispositions files sit in the
# branch's run folder.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-dispositions-check.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/disp
  M=code-audit-frontend
  alf_fill f.txt 12 feature
  alf_commit "feature"
  RF="$ALF_ROOT/.gaia/local/runs/$ALF_B"
  SNAP="$ALF_ROOT/.gaia/local/audit-loop/$ALF_B.d"
  mkdir -p "$RF"
  # f.txt:1 authored Critical, :2 security Suggestion, :3 Important,
  # base.txt:3 Critical outside the branch diff, :4 cross-remit Important,
  # :5 no security field, :6 Suggestion.
  FIND='[
    {"path":"f.txt","line":1,"finding_class":"c/crit","severity":"error","security":false},
    {"path":"f.txt","line":2,"finding_class":"c/sec","severity":"suggestion","security":true},
    {"path":"f.txt","line":3,"finding_class":"c/imp","severity":"warning","security":false},
    {"path":"base.txt","line":3,"finding_class":"c/oos","severity":"error","security":false},
    {"path":"f.txt","line":4,"finding_class":"c/xr","severity":"warning","security":false,"cross_remit":true},
    {"path":"f.txt","line":5,"finding_class":"c/nosec","severity":"warning"},
    {"path":"f.txt","line":6,"finding_class":"c/sug","severity":"suggestion","security":false}
  ]'
  open_round 1 "$FIND"
}

# open_round <r> <findings-json>: record round r on HEAD with its stamp,
# baseline and sidecar (a later round overwrites the same sidecar path).
open_round() {
  alf_add_round "[\"$M\"]"
  alf_stamp "$1" $((10 * $1))
  alf_baseline "$1" $((10 * $1 + 5))
  alf_sidecar "$M" "$2" $((10 * $1 + 1))
}

# ent <path> <line> <class> <disposition> [reason] [basis]: one entry.
ent() {
  jq -n -c --arg p "$1" --argjson l "$2" --arg c "$3" --arg d "$4" --arg r "${5-because}" --arg b "${6-}" \
    '{member: "code-audit-frontend", finding_class: $c, path: $p, line: $l, disposition: $d, reason: $r}
     + (if $b == "" then {} else {basis: $b} end)'
}

# wd <r> <entries-array-json> [enforcement-json]: write dispositions-<r>.json.
wd() {
  jq -n -c --argjson r "$1" --argjson e "$2" --argjson p "${3-[]}" \
    '{schema: 1, round: $r, entries: $e, enforcement_paths_allowed: $p}' >"$RF/dispositions-$1.json"
}

# kj <class> <path> <line>: the compact key json a violation line carries.
kj() {
  printf '{"member":"code-audit-frontend","finding_class":"%s","path":"%s","line":%s}' "$1" "$2" "$3"
}

# chk <round> [flags...]: the live check.
chk() {
  local r="$1"
  shift
  run bash "$SCRIPT" check --root "$ALF_ROOT" --run-folder "$RF" --round "$r" "$@"
}

# chk_all [flags...]
chk_all() {
  run bash "$SCRIPT" check-all --root "$ALF_ROOT" --run-folder "$RF" "$@"
}

# red <token> <key-json>: the last run exited 1 with exactly that line.
red() {
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  grep -qxF -- "violation: $1 $2" <<<"$output" || { echo "missing violation: $1 $2 in: $output"; return 1; }
}

# green: the last run exited 0.
green() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

# vetoes <effective_from_round> <class> <path> <line>
vetoes() {
  jq -n -c --argjson e "$1" --arg c "$2" --arg p "$3" --argjson l "$4" \
    '{version: 1, keys: [{member: "code-audit-frontend", finding_class: $c, path: $p, line: $l, vetoed_at: "t", unit: 1, effective_from_round: $e}]}' \
    >"$RF/vetoes.json"
}

@test "critical: a branch-authored Critical as accept-residual fails critical-not-fix" {
  wd 1 "[$(ent f.txt 1 c/crit accept-residual)]"
  chk 1
  red critical-not-fix "$(kj c/crit f.txt 1)"
}

@test "critical: a branch-authored Critical as waive-out-of-scope fails critical-not-fix" {
  wd 1 "[$(ent f.txt 1 c/crit waive-out-of-scope because triage-threshold)]"
  chk 1
  red critical-not-fix "$(kj c/crit f.txt 1)"
}

@test "critical: a branch-authored Critical as file fails critical-not-fix" {
  wd 1 "[$(ent f.txt 1 c/crit file)]"
  chk 1
  red critical-not-fix "$(kj c/crit f.txt 1)"
}

@test "critical: relabelling the Critical as warning inside the dispositions entry still fails" {
  local e
  e="$(ent f.txt 1 c/crit waive-out-of-scope because triage-threshold | jq -c '. + {severity: "warning", security: false}')"
  wd 1 "[$e]"
  chk 1
  red critical-not-fix "$(kj c/crit f.txt 1)"
}

@test "security: a security:true Suggestion waived fails security-not-fix" {
  wd 1 "[$(ent f.txt 2 c/sec waive-out-of-scope because triage-threshold)]"
  chk 1
  red security-not-fix "$(kj c/sec f.txt 2)"
}

@test "security: a finding with no security field reads true and fails security-not-fix" {
  wd 1 "[$(ent f.txt 5 c/nosec waive-out-of-scope because triage-threshold)]"
  chk 1
  red security-not-fix "$(kj c/nosec f.txt 5)"
}

@test "reason: an empty and a whitespace-only reason each fail empty-reason" {
  local r
  for r in "" "   "; do
    wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope "$r" triage-threshold)]"
    chk 1
    red empty-reason "$(kj c/imp f.txt 3)" || return 1
  done
  wd 1 "[$(ent f.txt 3 c/imp accept-residual "")]"
  chk 1
  red empty-reason "$(kj c/imp f.txt 3)"
}

@test "enforcement: a non-empty enforcement_paths_allowed fails enforcement-paths-set" {
  wd 1 "[$(ent f.txt 3 c/imp fix)]" '["x"]'
  chk 1
  red enforcement-paths-set '["x"]'
}

@test "basis: a waive-out-of-scope with no basis fails missing-basis" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because)]"
  chk 1
  red missing-basis "$(kj c/imp f.txt 3)"
}

@test "basis: cross-remit basis on a finding not flagged cross_remit fails" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because cross-remit)]"
  chk 1
  red cross-remit-basis-mismatch "$(kj c/imp f.txt 3)"
}

@test "control: an out-of-scope Critical filed with a reason passes" {
  wd 1 "[$(ent base.txt 3 c/oos file "filed upstream")]"
  chk 1
  green
}

@test "control: a branch-authored security:false Suggestion waived on the triage threshold passes" {
  wd 1 "[$(ent f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]"
  chk 1
  green
}

@test "control: a cross_remit Important waived with basis cross-remit passes" {
  wd 1 "[$(ent f.txt 4 c/xr waive-out-of-scope "other member's remit" cross-remit)]"
  chk 1
  green
}

@test "control: every finding disposed fix passes" {
  wd 1 "[$(ent f.txt 1 c/crit fix),$(ent f.txt 2 c/sec fix),$(ent base.txt 3 c/oos fix)]"
  chk 1
  green
}

@test "unknown-key: an entry for a key no member reported fails" {
  wd 1 "[$(ent f.txt 9 c/ghost fix)]"
  chk 1
  red unknown-key "$(kj c/ghost f.txt 9)"
}

@test "vetoes: bind forward only, a synthetic fix passes, check-all stays green (UAT-006)" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1 --snapshot-dir "$SNAP"
  green
  vetoes 2 c/imp f.txt 3
  # a veto never re-grades the earlier round
  chk 1
  green
  open_round 2 "$FIND"
  wd 2 "[$(ent f.txt 3 c/imp accept-residual because)]"
  chk 2
  red vetoed-not-fix "$(kj c/imp f.txt 3)" || return 1
  wd 2 "[$(ent f.txt 3 c/imp fix)]"
  chk 2
  green || return 1
  # no member re-reported the key in round 2: a synthetic fix entry passes
  alf_sidecar "$M" "$(jq -c '[.[] | select(.line == 6)]' <<<"$FIND")" 22
  chk 2
  green || return 1
  chk_all --snapshot-dir "$SNAP"
  green
}

@test "snapshots: check-all re-grades round 1 from its snapshot after the sidecar is overwritten (CG-003)" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  [ -f "$SNAP/dispositions-1.checked.json" ] || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  chk_all --snapshot-dir "$SNAP"
  green
}

@test "snapshots: the same sequence without a snapshot fails round 1 unknown-key" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  chk_all
  red unknown-key "$(kj c/imp f.txt 3)"
}

# tree_state: every file under the run folder and the state directory with its
# digest, so a read that wrote anything differs from the one before it.
tree_state() {
  find "$RF" "$SNAP" -type f 2>/dev/null | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(shasum -a 256 <"$f")"
  done
}

@test "snapshots: check-all with no --snapshot-dir reads the default directory's snapshot, so round 1 passes after its sidecar is overwritten, and writes nothing" {
  local before after
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  wd 2 "[$(ent f.txt 7 c/later fix)]"
  before="$(tree_state)"
  chk_all
  green || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ] || { printf 'a read-only check-all wrote:\n%s\n---\n%s\n' "$before" "$after" >&2; return 1; }
  [ ! -e "$SNAP/dispositions-2.checked.json" ]
}

@test "snapshots: check-all with no --snapshot-dir still fails unknown-key when the default directory holds no snapshot for the round" {
  local before
  mkdir -p "$SNAP"
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  wd 2 "[$(ent f.txt 7 c/later fix)]"
  before="$(tree_state)"
  chk_all
  red unknown-key "$(kj c/imp f.txt 3)" || return 1
  [ "$before" = "$(tree_state)" ]
}

@test "snapshots: check with no --snapshot-dir re-grades a round from its existing snapshot and flags an edit, writing nothing" {
  local before after
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  chk 1
  green || return 1
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope "a different reason" triage-threshold)]"
  before="$(tree_state)"
  chk 1
  red edited-after-check '{"round":1}' || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ]
}

@test "snapshots: editing the dispositions file after its snapshot fails edited-after-check" {
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  wd 1 "[$(ent f.txt 3 c/imp waive-out-of-scope "a different reason" triage-threshold)]"
  chk_all --snapshot-dir "$SNAP"
  red edited-after-check '{"round":1}' || return 1
  chk 1 --snapshot-dir "$SNAP"
  red edited-after-check '{"round":1}'
}

@test "check-all: exits 1 when any one of three files fails and 0 when all pass" {
  local r
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  for r in 2 3; do
    open_round "$r" "$FIND"
    wd "$r" "[$(ent f.txt 3 c/imp fix)]"
    chk "$r" --snapshot-dir "$SNAP"
    green || return 1
  done
  chk_all --snapshot-dir "$SNAP"
  green || return 1
  for r in 1 2 3; do
    wd "$r" "[$(ent f.txt 1 c/crit accept-residual)]"
    chk_all
    [ "$status" -eq 1 ] || { echo "round $r: status $status"; return 1; }
    wd "$r" "[$(ent f.txt 3 c/imp fix)]"
  done
}

@test "check-all: an empty run folder exits 0" {
  chk_all
  green
}

@test "no snapshot flag: check and check-all write nothing anywhere" {
  local before after
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  before="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  chk 1
  green || return 1
  chk_all
  green || return 1
  after="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  [ -n "$before" ] || return 1
  [ "$before" = "$after" ]
}

@test "exit 3: a corrupt state file (the evaluator fails) is not a pass" {
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  printf 'not json' >"$ALF_STATE"
  chk 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  chk_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 3: an unparseable vetoes.json is not a pass" {
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  printf 'not json' >"$RF/vetoes.json"
  chk 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  chk_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 3: an unparseable dispositions file is not a pass" {
  printf 'not json' >"$RF/dispositions-1.json"
  chk 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 2: no subcommand and a missing round are usage errors" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ] || return 1
  chk ""
  [ "$status" -eq 2 ]
}

@test "waiver-table: header and one row per non-fix entry, severity from the sidecar" {
  local e rows
  e="$(ent f.txt 1 c/crit waive-out-of-scope "pipe | here" triage-threshold | jq -c '. + {severity: "warning"}')"
  wd 1 "[$e,$(ent f.txt 3 c/imp fix),$(ent f.txt 6 c/sug accept-residual later)]"
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RF" --rounds 1-1
  green || return 1
  head -n 1 <<<"$output" | grep -qF -- 'key | member | severity | security | disposition | reason' || return 1
  rows="$(wc -l <<<"$output" | tr -d ' ')"
  [ "$rows" -eq 4 ] || { echo "$output"; return 1; }
  grep -F -- 'f.txt:1 c/crit' <<<"$output" | grep -qF -- '| error | false |' || { echo "$output"; return 1; }
  grep -qF -- 'pipe \| here' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- 'f.txt:3 c/imp' <<<"$output" && return 1
  grep -F -- 'f.txt:6 c/sug' <<<"$output" | grep -qF -- '| suggestion | false | code-audit-frontend' && return 1
  true
}

@test "waiver-table: reads the frozen snapshot once the sidecar is gone" {
  wd 1 "[$(ent f.txt 1 c/crit fix),$(ent f.txt 6 c/sug accept-residual later)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"error","security":false}]'
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RF" --rounds 1-1
  green || return 1
  grep -F -- 'f.txt:6 c/sug' <<<"$output" | grep -qF -- '| suggestion | false |' || { echo "$output"; return 1; }
}

@test "pr-sections: three headings, keyed entries parse as residue keys, vetoed key drops out (directive 7)" {
  local key_re='<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->'
  local line
  wd 1 "[$(ent f.txt 3 c/imp accept-residual "closing round left it"),$(ent f.txt 4 c/xr waive-out-of-scope "other remit" cross-remit),$(ent f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RF"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Out-of-scope machinery findings (recorded, not filed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Waived below triage threshold (not filed)' <<<"$output" || { echo "$output"; return 1; }
  line="$(grep -F -- 'f.txt:3' <<<"$output")"
  [[ "$line" =~ $key_re ]] || { echo "$line"; return 1; }
  [ "${BASH_REMATCH[1]}" = "v1 class=c/imp path=f.txt line=3" ] || return 1
  line="$(grep -F -- 'f.txt:4' <<<"$output")"
  [[ "$line" =~ $key_re ]] || { echo "$line"; return 1; }
  line="$(grep -F -- 'f.txt:6' <<<"$output")"
  [ "$line" = '- f.txt:6 c/sug: below threshold' ] || { echo "$line"; return 1; }
  vetoes 1 c/imp f.txt 3
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RF"
  green || return 1
  grep -qF -- 'Accepted residuals' <<<"$output" && return 1
  grep -qF -- 'f.txt:3' <<<"$output" && return 1
  grep -qF -- 'Out-of-scope machinery findings' <<<"$output"
}

@test "pr-sections: a veto effective from a later round leaves the earlier round's residual" {
  wd 1 "[$(ent f.txt 3 c/imp accept-residual "closing round left it")]"
  vetoes 2 c/imp f.txt 3
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RF"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output"
}

@test "pr-sections: nothing to record prints nothing" {
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RF"
  green || return 1
  [ -z "$output" ]
}

@test "red state: a copy reading severity from the dispositions entry passes the relabelled Critical" {
  local mut="$BATS_TEST_TMPDIR/mutant" f e
  mkdir -p "$mut"
  for f in audit-dispositions-check.sh audit-loop-eval.sh audit-loop-state-lib.sh audit-loop-signals-lib.sh context-checkpoint-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh; do
    cp "$SCRIPTS/$f" "$mut/$f"
  done
  # shellcheck disable=SC2016
  sed 's/\$l\.severity/$e.severity/g' "$SCRIPTS/audit-dispositions-check.sh" >"$mut/audit-dispositions-check.sh"
  ! cmp -s "$SCRIPTS/audit-dispositions-check.sh" "$mut/audit-dispositions-check.sh" || { echo "mutation did not apply"; return 1; }
  e="$(ent f.txt 1 c/crit waive-out-of-scope because triage-threshold | jq -c '. + {severity: "warning"}')"
  wd 1 "[$e]"
  run bash "$mut/audit-dispositions-check.sh" check --root "$ALF_ROOT" --run-folder "$RF" --round 1
  [ "$status" -eq 0 ] || { echo "mutant status $status: $output"; return 1; }
  chk 1
  red critical-not-fix "$(kj c/crit f.txt 1)"
}

@test "cost: check-all over nine snapshotted rounds never calls the evaluator and is fast (DP-017)" {
  local r shim="$BATS_TEST_TMPDIR/shim" t0 t1 count
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  chk 1 --snapshot-dir "$SNAP"
  green || return 1
  r=2
  while [ "$r" -le 9 ]; do
    open_round "$r" "$FIND"
    wd "$r" "[$(ent f.txt 3 c/imp waive-out-of-scope because triage-threshold),$(ent f.txt 1 c/crit fix)]"
    chk "$r" --snapshot-dir "$SNAP"
    green || return 1
    r=$((r + 1))
  done
  count="$(find "$SNAP" -name 'dispositions-*.checked.json' | wc -l | tr -d ' ')"
  [ "$count" -eq 9 ] || { echo "snapshots: $count"; return 1; }
  mkdir -p "$shim"
  cp "$SCRIPT" "$shim/audit-dispositions-check.sh"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s/calls"\nexit 9\n' "$BATS_TEST_TMPDIR" >"$shim/audit-loop-eval.sh"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  run bash "$shim/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RF" --snapshot-dir "$SNAP"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  green || return 1
  [ ! -e "$BATS_TEST_TMPDIR/calls" ] || { echo "evaluator was called"; return 1; }
  echo "check-all over 9 snapshots: $((t1 - t0)) ms" >&3
  [ $((t1 - t0)) -lt 2000 ]
}

@test "red state: the shimmed evaluator is actually reached when no snapshot exists" {
  local shim="$BATS_TEST_TMPDIR/shim"
  wd 1 "[$(ent f.txt 3 c/imp fix)]"
  mkdir -p "$shim"
  cp "$SCRIPT" "$shim/audit-dispositions-check.sh"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s/calls"\nexit 9\n' "$BATS_TEST_TMPDIR" >"$shim/audit-loop-eval.sh"
  run bash "$shim/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RF" --snapshot-dir "$SNAP"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  [ -e "$BATS_TEST_TMPDIR/calls" ]
}
