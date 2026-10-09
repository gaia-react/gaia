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
  MEMBER=code-audit-frontend
  alf_fill f.txt 12 feature
  alf_commit "feature"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  SNAPSHOT_DIRECTORY="$ALF_ROOT/.gaia/local/protected/audit-loop/$ALF_NORMALIZED_BRANCH.d"
  mkdir -p "$RUN_FOLDER"
  # f.txt:1 authored Critical, :2 security Suggestion, :3 Important,
  # base.txt:3 Critical outside the branch diff, :4 cross-remit Important,
  # :5 no security field, :6 Suggestion; base.txt:5 security Suggestion,
  # base.txt:6 Important and base.txt:7 Important with no security field, all
  # outside the branch diff.
  FINDINGS_JSON='[
    {"path":"f.txt","line":1,"finding_class":"c/crit","severity":"error","security":false},
    {"path":"f.txt","line":2,"finding_class":"c/sec","severity":"suggestion","security":true},
    {"path":"f.txt","line":3,"finding_class":"c/imp","severity":"warning","security":false},
    {"path":"base.txt","line":3,"finding_class":"c/oos","severity":"error","security":false},
    {"path":"f.txt","line":4,"finding_class":"c/xr","severity":"warning","security":false,"cross_remit":true},
    {"path":"f.txt","line":5,"finding_class":"c/nosec","severity":"warning"},
    {"path":"f.txt","line":6,"finding_class":"c/sug","severity":"suggestion","security":false},
    {"path":"base.txt","line":5,"finding_class":"c/oossec","severity":"suggestion","security":true},
    {"path":"base.txt","line":6,"finding_class":"c/oosimp","severity":"warning","security":false},
    {"path":"base.txt","line":7,"finding_class":"c/oosnosec","severity":"warning"}
  ]'
  open_round 1 "$FINDINGS_JSON"
  # A gh stub logging each call with the GH_REPO it saw. The repository
  # resolution answers owner/repo; the visibility read answers $GH_VISIBILITY,
  # failing when that is unset or empty and printing nothing for __empty__.
  GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s GH_REPO=%s\n' "$*" "${GH_REPO-unset}" >>"$GH_CALLS"
case "$*" in *nameWithOwner*) printf 'owner/repo\n'; exit 0 ;; esac
case "${GH_VISIBILITY-}" in '') exit 1 ;; __empty__) exit 0 ;; esac
printf '%s\n' "$GH_VISIBILITY"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export GH_CALLS
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GH_VISIBILITY=PUBLIC
}

# open_round <round> <findings-json>: record round r on HEAD with its stamp,
# baseline and sidecar (a later round overwrites the same sidecar path).
open_round() {
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp "$1" $((10 * $1))
  alf_baseline "$1" $((10 * $1 + 5))
  alf_sidecar "$MEMBER" "$2" $((10 * $1 + 1))
}

# disposition_entry <path> <line> <class> <disposition> [reason] [basis]: one entry.
disposition_entry() {
  jq -n -c --arg path "$1" --argjson line "$2" --arg finding_class "$3" --arg disposition "$4" --arg reason "${5-because}" --arg basis "${6-}" \
    '{member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line, disposition: $disposition, reason: $reason}
     + (if $basis == "" then {} else {basis: $basis} end)'
}

# write_dispositions <r> <entries-array-json> [enforcement-json]: write dispositions-<r>.json.
write_dispositions() {
  jq -n -c --argjson round "$1" --argjson entries "$2" --argjson enforcement_paths "${3-[]}" \
    '{schema: 1, round: $round, entries: $entries, enforcement_paths_allowed: $enforcement_paths}' >"$RUN_FOLDER/dispositions-$1.json"
}

# fill <findings-json> <entries-json> [jq-filter]: the entries plus a fix entry
# for every finding they leave out, of any authorship, narrowed by the optional
# filter, so a green fixture disposes every finding it does not name.
fill() {
  jq -n -c --argjson findings "$1" --argjson entries "$2" "
    \$entries + [\$findings[] | ${3:-.}
      | select([.finding_class, .path, .line] as \$key | any(\$entries[]; [.finding_class, .path, .line] == \$key) | not)
      | {member: \"code-audit-frontend\", finding_class, path, line, disposition: \"fix\", reason: \"\"}]"
}

# key_json <class> <path> <line>: the compact key json a violation line carries.
key_json() {
  printf '{"member":"code-audit-frontend","finding_class":"%s","path":"%s","line":%s}' "$1" "$2" "$3"
}

# run_check <round> [flags...]: the live check.
run_check() {
  local round="$1"
  shift
  run bash "$SCRIPT" check --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round "$round" "$@"
}

# run_check_all [flags...]
run_check_all() {
  run bash "$SCRIPT" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" "$@"
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
  jq -n -c --argjson effective_from_round "$1" --arg finding_class "$2" --arg path "$3" --argjson line "$4" \
    '{version: 1, keys: [{member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line, vetoed_at: "t", unit: 1, effective_from_round: $effective_from_round}]}' \
    >"$RUN_FOLDER/vetoes.json"
}

@test "critical: a branch-authored Critical as accept-residual fails critical-not-fix" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit accept-residual)]")"
  run_check 1
  red critical-not-fix "$(key_json c/crit f.txt 1)"
}

@test "critical: a branch-authored Critical as waive-out-of-scope fails critical-not-fix" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit waive-out-of-scope because triage-threshold)]")"
  run_check 1
  red critical-not-fix "$(key_json c/crit f.txt 1)"
}

@test "critical: a branch-authored Critical as file fails critical-not-fix" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit file)]")"
  run_check 1
  red critical-not-fix "$(key_json c/crit f.txt 1)"
}

@test "critical: relabelling the Critical as warning inside the dispositions entry still fails" {
  local entry
  entry="$(disposition_entry f.txt 1 c/crit waive-out-of-scope because triage-threshold | jq -c '. + {severity: "warning", security: false}')"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$entry]")"
  run_check 1
  red critical-not-fix "$(key_json c/crit f.txt 1)"
}

@test "security: a security:true Suggestion waived fails security-not-fix" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 2 c/sec waive-out-of-scope because triage-threshold)]")"
  run_check 1
  red security-not-fix "$(key_json c/sec f.txt 2)"
}

@test "security: a finding with no security field reads true and fails security-not-fix" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 5 c/nosec waive-out-of-scope because triage-threshold)]")"
  run_check 1
  red security-not-fix "$(key_json c/nosec f.txt 5)"
}

@test "reason: an empty and a whitespace-only reason each fail empty-reason" {
  local reason
  for reason in "" "   "; do
    write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope "$reason" triage-threshold)]")"
    run_check 1
    red empty-reason "$(key_json c/imp f.txt 3)" || return 1
  done
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "")]")"
  run_check 1
  red empty-reason "$(key_json c/imp f.txt 3)"
}

@test "enforcement: a non-empty enforcement_paths_allowed fails enforcement-paths-set" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")" '["x"]'
  run_check 1
  red enforcement-paths-set '["x"]'
}

@test "basis: a waive-out-of-scope with no basis fails missing-basis" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because)]")"
  run_check 1
  red missing-basis "$(key_json c/imp f.txt 3)"
}

@test "basis: cross-remit basis on a finding not flagged cross_remit fails" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because cross-remit)]")"
  run_check 1
  red cross-remit-basis-mismatch "$(key_json c/imp f.txt 3)"
}

@test "control: an out-of-scope Critical filed with a reason passes on a confirmed PRIVATE repo" {
  GH_VISIBILITY=PRIVATE
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos file "filed upstream")]")"
  run_check 1
  green
}

@test "security divert: an out-of-scope Critical filed on a PUBLIC repo fails security-file-not-private" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos file "filed upstream")]")"
  run_check 1
  red security-file-not-private "$(key_json c/oos base.txt 3)"
}

@test "security divert: an out-of-scope security:true Suggestion filed fails on INTERNAL and on a failed probe" {
  local visibility
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 5 c/oossec file "filed upstream")]")"
  for visibility in INTERNAL ''; do
    GH_VISIBILITY="$visibility"
    run_check 1
    red security-file-not-private "$(key_json c/oossec base.txt 5)" || return 1
  done
}

@test "security divert: an out-of-scope non-security Important filed on a PUBLIC repo passes without probing" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file "filed upstream")]")"
  run_check 1
  green || return 1
  [ ! -e "$GH_CALLS" ] || { echo "probed: $(cat "$GH_CALLS")"; return 1; }
}

@test "control: a branch-authored security:false Suggestion waived on the triage threshold passes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]")"
  run_check 1
  green
}

@test "control: a cross_remit Important waived with basis cross-remit passes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 4 c/xr waive-out-of-scope "other member's remit" cross-remit)]")"
  run_check 1
  green
}

@test "control: every finding disposed fix passes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit fix),$(disposition_entry f.txt 2 c/sec fix),$(disposition_entry base.txt 3 c/oos fix)]")"
  run_check 1
  green
}

@test "unknown-key: an entry for a key no member reported fails" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 9 c/ghost fix)]")"
  run_check 1
  red unknown-key "$(key_json c/ghost f.txt 9)"
}

@test "undisposed: an omitted branch-authored Critical fails" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.line != 1)')"
  run_check 1
  red undisposed "$(key_json c/crit f.txt 1)"
}

@test "undisposed: an omitted branch-authored security finding fails" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.line != 2)')"
  run_check 1
  red undisposed "$(key_json c/sec f.txt 2)"
}

@test "undisposed: an omitted key vetoed for the round fails, though no member re-reported it" {
  vetoes 1 c/gone f.txt 9
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  red undisposed "$(key_json c/gone f.txt 9)"
}

@test "undisposed: every branch-authored finding and vetoed key disposed fails with the out-of-branch Critical left out" {
  vetoes 1 c/gone f.txt 9
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later),$(disposition_entry f.txt 9 c/gone fix)]" 'select(.path != "base.txt" or .line != 3)')"
  run_check 1
  red undisposed "$(key_json c/oos base.txt 3)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later),$(disposition_entry f.txt 9 c/gone fix)]")"
  run_check 1
  green
}

@test "vetoes: bind forward only, a synthetic fix passes, check-all stays green (UAT-006)" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green
  vetoes 2 c/imp f.txt 3
  # a veto never re-grades the earlier round
  run_check 1
  green
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual because)]")"
  run_check 2
  red vetoed-not-fix "$(key_json c/imp f.txt 3)" || return 1
  write_dispositions 2 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 2
  green || return 1
  # no member re-reported the key in round 2: a synthetic fix entry passes
  alf_sidecar "$MEMBER" "$(jq -c '[.[] | select(.line == 6)]' <<<"$FINDINGS_JSON")" 22
  write_dispositions 2 "$(fill "$(jq -c '[.[] | select(.line == 6)]' <<<"$FINDINGS_JSON")" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 2
  green || return 1
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green
}

@test "snapshots: check-all re-grades round 1 from its snapshot after the sidecar is overwritten (CG-003)" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  [ -f "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" ] || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green
}

@test "snapshots: the same sequence without a snapshot fails round 1 unknown-key" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  run_check_all
  red unknown-key "$(key_json c/imp f.txt 3)"
}

# tree_state: every file under the run folder and the state directory with its
# digest, so a read that wrote anything differs from the one before it.
tree_state() {
  find "$RUN_FOLDER" "$SNAPSHOT_DIRECTORY" -type f 2>/dev/null | sort | while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(shasum -a 256 <"$file")"
  done
}

@test "snapshots: check-all with no --snapshot-dir reads the default directory's snapshot, so round 1 passes after its sidecar is overwritten, and writes nothing" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/later fix)]"
  before="$(tree_state)"
  run_check_all
  green || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ] || { printf 'a read-only check-all wrote:\n%s\n---\n%s\n' "$before" "$after" >&2; return 1; }
  [ ! -e "$SNAPSHOT_DIRECTORY/dispositions-2.checked.json" ]
}

@test "snapshots: check-all with no --snapshot-dir still fails unknown-key when the default directory holds no snapshot for the round" {
  local before
  mkdir -p "$SNAPSHOT_DIRECTORY"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/later fix)]"
  before="$(tree_state)"
  run_check_all
  red unknown-key "$(key_json c/imp f.txt 3)" || return 1
  [ "$before" = "$(tree_state)" ]
}

@test "snapshots: check with no --snapshot-dir re-grades a round from its existing snapshot and flags an edit, writing nothing" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  run_check 1
  green || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope "a different reason" triage-threshold)]")"
  before="$(tree_state)"
  run_check 1
  red edited-after-check '{"round":1}' || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ]
}

@test "snapshots: editing the dispositions file after its snapshot fails edited-after-check" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope "a different reason" triage-threshold)]")"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red edited-after-check '{"round":1}' || return 1
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red edited-after-check '{"round":1}'
}

@test "check-all: exits 1 when any one of three files fails and 0 when all pass" {
  local round
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  for round in 2 3; do
    open_round "$round" "$FINDINGS_JSON"
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
    run_check "$round" --snapshot-dir "$SNAPSHOT_DIRECTORY"
    green || return 1
  done
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  for round in 1 2 3; do
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit accept-residual)]")"
    run_check_all
    [ "$status" -eq 1 ] || { echo "round $round: status $status"; return 1; }
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  done
}

@test "check-all: an empty run folder exits 0" {
  run_check_all
  green
}

@test "no snapshot flag: check and check-all write nothing anywhere" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  before="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  run_check 1
  green || return 1
  run_check_all
  green || return 1
  after="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  [ -n "$before" ] || return 1
  [ "$before" = "$after" ]
}

@test "exit 3: a corrupt state file (the evaluator fails) is not a pass" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  printf 'not json' >"$ALF_STATE"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run_check_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 3: an unparseable vetoes.json is not a pass" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  printf 'not json' >"$RUN_FOLDER/vetoes.json"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run_check_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 3: an unparseable dispositions file is not a pass" {
  printf 'not json' >"$RUN_FOLDER/dispositions-1.json"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 2: no subcommand and a missing round are usage errors" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ] || return 1
  run_check ""
  [ "$status" -eq 2 ]
}

@test "waiver-table: header and one row per non-fix entry, severity from the sidecar" {
  local entry rows
  entry="$(disposition_entry f.txt 1 c/crit waive-out-of-scope "pipe | here" triage-threshold | jq -c '. + {severity: "warning"}')"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$entry,$(disposition_entry f.txt 3 c/imp fix),$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
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
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit fix),$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"error","security":false}]'
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  green || return 1
  grep -F -- 'f.txt:6 c/sug' <<<"$output" | grep -qF -- '| suggestion | false |' || { echo "$output"; return 1; }
}

@test "pr-sections: three headings, keyed entries parse as residue keys, vetoed key drops out (directive 7)" {
  local key_regex='<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->'
  local line
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "closing round left it"),$(disposition_entry f.txt 4 c/xr waive-out-of-scope "other remit" cross-remit),$(disposition_entry f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]")"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Out-of-scope machinery findings (recorded, not filed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Waived below triage threshold (not filed)' <<<"$output" || { echo "$output"; return 1; }
  line="$(grep -F -- 'f.txt:3' <<<"$output")"
  [[ "$line" =~ $key_regex ]] || { echo "$line"; return 1; }
  [ "${BASH_REMATCH[1]}" = "v1 class=c/imp path=f.txt line=3" ] || return 1
  line="$(grep -F -- 'f.txt:4' <<<"$output")"
  [[ "$line" =~ $key_regex ]] || { echo "$line"; return 1; }
  line="$(grep -F -- 'f.txt:6' <<<"$output")"
  [ "$line" = '- f.txt:6 c/sug: below threshold' ] || { echo "$line"; return 1; }
  vetoes 1 c/imp f.txt 3
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qF -- 'Accepted residuals' <<<"$output" && return 1
  grep -qF -- 'f.txt:3' <<<"$output" && return 1
  grep -qF -- 'Out-of-scope machinery findings' <<<"$output"
}

@test "pr-sections: a veto effective from a later round leaves the earlier round's residual" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "closing round left it")]")"
  vetoes 2 c/imp f.txt 3
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output"
}

@test "pr-sections: nothing to record prints nothing" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  [ -z "$output" ]
}

@test "red state: a copy reading severity from the dispositions entry passes the relabelled Critical" {
  local mutant_directory="$BATS_TEST_TMPDIR/mutant" script_name entry
  mkdir -p "$mutant_directory"
  for script_name in audit-dispositions-check.sh audit-loop-eval.sh audit-loop-state-lib.sh audit-loop-signals-lib.sh context-checkpoint-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh; do
    cp "$SCRIPTS/$script_name" "$mutant_directory/$script_name"
  done
  # shellcheck disable=SC2016
  sed 's/\$lookup_entry\.severity/$entry.severity/g' "$SCRIPTS/audit-dispositions-check.sh" >"$mutant_directory/audit-dispositions-check.sh"
  ! cmp -s "$SCRIPTS/audit-dispositions-check.sh" "$mutant_directory/audit-dispositions-check.sh" || { echo "mutation did not apply"; return 1; }
  entry="$(disposition_entry f.txt 1 c/crit waive-out-of-scope because triage-threshold | jq -c '. + {severity: "warning"}')"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$entry]")"
  run bash "$mutant_directory/audit-dispositions-check.sh" check --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 0 ] || { echo "mutant status $status: $output"; return 1; }
  run_check 1
  red critical-not-fix "$(key_json c/crit f.txt 1)"
}

@test "cost: check-all over nine snapshotted rounds never calls the evaluator and is fast (DP-017)" {
  local round shim="$BATS_TEST_TMPDIR/shim" start_milliseconds end_milliseconds count
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  round=2
  while [ "$round" -le 9 ]; do
    open_round "$round" "$FINDINGS_JSON"
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold),$(disposition_entry f.txt 1 c/crit fix)]")"
    run_check "$round" --snapshot-dir "$SNAPSHOT_DIRECTORY"
    green || return 1
    round=$((round + 1))
  done
  count="$(find "$SNAPSHOT_DIRECTORY" -name 'dispositions-*.checked.json' | wc -l | tr -d ' ')"
  [ "$count" -eq 9 ] || { echo "snapshots: $count"; return 1; }
  mkdir -p "$shim"
  cp "$SCRIPT" "$shim/audit-dispositions-check.sh"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s/calls"\nexit 9\n' "$BATS_TEST_TMPDIR" >"$shim/audit-loop-eval.sh"
  start_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  run bash "$shim/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$SNAPSHOT_DIRECTORY"
  end_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  green || return 1
  [ ! -e "$BATS_TEST_TMPDIR/calls" ] || { echo "evaluator was called"; return 1; }
  echo "check-all over 9 snapshots: $((end_milliseconds - start_milliseconds)) ms" >&3
  [ $((end_milliseconds - start_milliseconds)) -lt 2000 ]
}

@test "red state: the shimmed evaluator is actually reached when no snapshot exists" {
  local shim="$BATS_TEST_TMPDIR/shim"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  mkdir -p "$shim"
  cp "$SCRIPT" "$shim/audit-dispositions-check.sh"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s/calls"\nexit 9\n' "$BATS_TEST_TMPDIR" >"$shim/audit-loop-eval.sh"
  run bash "$shim/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$SNAPSHOT_DIRECTORY"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  [ -e "$BATS_TEST_TMPDIR/calls" ]
}

# --- every finding disposed, divert, visibility, outcomes, triage, PR sections ---

SHELL_MEMBER=code-audit-maintainer-shell
TRIAGE_ENTRY='{"path":".claude/hooks/h.sh","line":1,"finding_class":"c/tri","severity":"warning","security":false,"triage":true,"triage_reason":"below threshold"}'

# member_key_json <member> <class> <path> <line>
member_key_json() {
  printf '{"member":"%s","finding_class":"%s","path":"%s","line":%s}' "$1" "$2" "$3" "$4"
}

# write_roster: a roster giving f.txt and base.txt to the frontend default and
# .claude/hooks/**/*.sh to the maintainer shell member.
write_roster() {
  cat >"$ALF_ROOT/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "f.txt"
      - "base.txt"
    default: true
  - name: code-audit-maintainer-shell
    globs:
      - ".claude/hooks/**/*.sh"
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**/*.ts"
YAML
}

# with_maintainer <entries-json> [minutes]: the roster, the maintainer shell
# member added to round 1, and its sidecar in round 1's window.
with_maintainer() {
  write_roster
  alf_state_edit '.history.rounds[0].members |= ((. + ["code-audit-maintainer-shell"]) | unique)'
  alf_sidecar "$SHELL_MEMBER" "$1" "${2:-11}"
}

# outcome_line <class> <path> <line> <disposition> <outcome>: one filing outcome.
outcome_line() {
  jq -n -c --arg finding_class "$1" --arg path "$2" --argjson line "$3" --arg disposition "$4" --arg outcome "$5" \
    '{key: {member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line},
      disposition: $disposition, outcome: $outcome, issue: null, record: null}'
}

run_outcomes() {
  run bash "$SCRIPT" check-outcomes --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round "$1"
}

run_sections() {
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

@test "UAT-002: an out-of-branch finding with no entry and no triage mark fails undisposed; an entry clears it" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  run_check 1
  red undisposed "$(key_json c/oosimp base.txt 6)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp accept-residual "left for later")]")"
  run_check 1
  green
}

@test "UAT-003a: an out-of-branch Critical, security:true or security-absent finding filed on a non-PRIVATE repo fails security-file-not-private, not empty-reason" {
  local line_number finding_class
  for line_number in 3 5 7; do
    finding_class="$(jq -r --argjson line "$line_number" '.[] | select(.path == "base.txt" and .line == $line) | .finding_class' <<<"$FINDINGS_JSON")"
    write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt "$line_number" "$finding_class" file "filed upstream")]")"
    run_check 1
    red security-file-not-private "$(key_json "$finding_class" base.txt "$line_number")" || return 1
    grep -qF -- 'violation: empty-reason' <<<"$output" && { echo "empty-reason fired: $output"; return 1; }
  done
  true
}

@test "UAT-003b: divert with a reason on each out-of-branch security-class finding passes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos divert "security class"),$(disposition_entry base.txt 5 c/oossec divert "security class"),$(disposition_entry base.txt 7 c/oosnosec divert "no security flag")]")"
  run_check 1
  green
}

@test "UAT-003c: divert with an empty reason fails empty-reason" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos divert "")]")"
  run_check 1
  red empty-reason "$(key_json c/oos base.txt 3)"
}

@test "UAT-003d: divert on a branch-authored security finding fails divert-not-allowed" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 2 c/sec divert "security class")]")"
  run_check 1
  red divert-not-allowed "$(key_json c/sec f.txt 2)"
}

@test "UAT-003e: divert on an out-of-branch security:false warning fails divert-not-allowed" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp divert "not security")]")"
  run_check 1
  red divert-not-allowed "$(key_json c/oosimp base.txt 6)"
}

@test "visibility: only an exact PRIVATE answer for the repository resolved once lets the file pass; the environment and a cache change nothing" {
  local visibility
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos file "filed upstream")]")"
  export GH_REPO=someone/private GAIA_REPO_VISIBILITY=PRIVATE REPO_VISIBILITY=PRIVATE VISIBILITY=PRIVATE
  printf 'PRIVATE\n' >"$ALF_ROOT/.gaia/local/repo-visibility"
  printf '{"visibility":"PRIVATE"}\n' >"$ALF_ROOT/.gaia/local/audit/visibility.json"
  for visibility in '' __empty__ PUBLIC INTERNAL private 'PRIVATE '; do
    GH_VISIBILITY="$visibility"
    run_check 1
    red security-file-not-private "$(key_json c/oos base.txt 3)" || { echo "visibility '$visibility'"; return 1; }
  done
  GH_VISIBILITY=PRIVATE
  run_check 1
  green || return 1
  grep -qxF -- 'repo view owner/repo --json visibility --jq .visibility GH_REPO=unset' "$GH_CALLS" || { cat "$GH_CALLS"; return 1; }
  grep -F -- 'GH_REPO=someone/private' "$GH_CALLS" && return 1
  true
}

@test "UAT-037: check-outcomes passes filed and diverted, fails a missing line or failed, passes absent and transient" {
  local outcome_file="$RUN_FOLDER/filing-outcomes-1.jsonl" outcome
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream),$(disposition_entry base.txt 3 c/oos divert "security class")]")"
  printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file filed)" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
  run_outcomes 1
  green || return 1
  outcome_line c/oos base.txt 3 divert diverted >"$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  outcome_line c/oosimp base.txt 6 file filed >"$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oos base.txt 3)" || return 1
  printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file failed)" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
  run_outcomes 1
  red outcome-failed "$(key_json c/oosimp base.txt 6)" || return 1
  for outcome in absent transient; do
    printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file "$outcome")" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
    run_outcomes 1
    green || { echo "outcome $outcome"; return 1; }
  done
  rm -f "$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  printf 'not json\n' >"$outcome_file"
  run_outcomes 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "UAT-037: check-all reconciles a live round's outcomes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  run_check_all
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  outcome_line c/oosimp base.txt 6 file filed >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_check_all
  green
}

@test "UAT-023: a maintainer triage mark on its own harness path, security:false and warning, needs no entry and renders one waived line" {
  local line_count
  with_maintainer "[$TRIAGE_ENTRY]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  green || return 1
  run_sections
  green || return 1
  grep -qxF -- '## Waived below triage threshold (not filed)' <<<"$output" || { echo "$output"; return 1; }
  line_count="$(grep -cxF -- '- .claude/hooks/h.sh:1 c/tri: below threshold' <<<"$output")"
  [ "$line_count" -eq 1 ] || { echo "$output"; return 1; }
}

@test "UAT-023: a triage mark with severity error, security true, security absent, off its member's globs, or with no roster is ignored" {
  local mutation
  for mutation in '.severity = "error"' '.security = true' 'del(.security)' '.path = "f.txt" | .line = 9'; do
    with_maintainer "[$(jq -c "$mutation" <<<"$TRIAGE_ENTRY")]"
    write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
    run_check 1
    red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri "$(jq -r "$mutation | .path" <<<"$TRIAGE_ENTRY")" "$(jq -r "$mutation | .line" <<<"$TRIAGE_ENTRY")")" || { echo "mutation $mutation"; return 1; }
    run_sections
    grep -qF -- 'c/tri' <<<"$output" && { echo "rendered under $mutation: $output"; return 1; }
  done
  with_maintainer "[$TRIAGE_ENTRY]"
  rm -f "$ALF_ROOT/.gaia/audit-ci.yml"
  run_check 1
  red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri .claude/hooks/h.sh 1)"
}

@test "UAT-023: a code-audit-frontend triage mark is ignored" {
  local with_mark
  write_roster
  with_mark="$(jq -c '. + [{"path":"f.txt","line":8,"finding_class":"c/fronttri","severity":"suggestion","security":false,"triage":true,"triage_reason":"below threshold"}]' <<<"$FINDINGS_JSON")"
  alf_sidecar "$MEMBER" "$with_mark" 11
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  red undisposed "$(key_json c/fronttri f.txt 8)"
}

# secret_token: a secret-shaped token, assembled at run time so the suite's
# own text never holds one.
secret_token() { printf '%s_%s' ghp "$(printf '%036d' 0)"; }

@test "UAT-023: a secret-shaped triage or waiver reason renders the withheld line, never the reason" {
  local token
  token="$(secret_token)"
  with_maintainer "[$(jq -c --arg reason "token $token leaked" '.triage_reason = $reason' <<<"$TRIAGE_ENTRY")]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp waive-out-of-scope "see $token" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qxF -- '- 2 waived finding(s) withheld: reason failed the secret screen' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- "$token" <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- 'c/tri' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- 'c/oosimp' <<<"$output" && { echo "$output"; return 1; }
  true
}

@test "UAT-023: a waive line for a security:true finding does not render" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 5 c/oossec waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oossec' <<<"$output" && { echo "$output"; return 1; }
  true
}

@test "UAT-023: a waive line for a finding with no security field does not render" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 7 c/oosnosec waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oosnosec' <<<"$output" && { echo "$output"; return 1; }
  true
}

@test "UAT-023: a waive line for a severity error finding does not render" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oos' <<<"$output" && { echo "$output"; return 1; }
  true
}

@test "UAT-023: a waive line for a security:false warning with a clean reason renders exactly once" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  [ "$(grep -cxF -- '- base.txt:6 c/oosimp: below threshold' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "divert: pr-sections and waiver-table print the count and nothing that names the finding" {
  local field
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos divert "the token sits in the debug log")]")"
  run_sections
  green || return 1
  grep -qxF -- 'Diverted security findings: 1 (local records under .gaia/local/audit/security/)' <<<"$output" || { echo "$output"; return 1; }
  for field in c/oos base.txt 'the token sits' code-audit-frontend; do
    grep -qF -- "$field" <<<"$output" && { echo "leaked $field: $output"; return 1; }
  done
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  green || return 1
  grep -qxF -- 'Diverted security findings: 1 (local records under .gaia/local/audit/security/)' <<<"$output" || { echo "$output"; return 1; }
  for field in c/oos 'the token sits'; do
    grep -qF -- "$field" <<<"$output" && { echo "leaked $field: $output"; return 1; }
  done
  true
}

@test "UAT-005: an absent outcome renders one not-filed line naming the key; a filed one renders none" {
  local expected='- code-audit-frontend base.txt:6 (c/oosimp): not filed, no issue backend'
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file absent >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_sections
  green || return 1
  grep -qxF -- '## Not filed (no issue backend)' <<<"$output" || { echo "$output"; return 1; }
  [ "$(grep -cxF -- "$expected" <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  outcome_line c/oosimp base.txt 6 file filed >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_sections
  green || return 1
  grep -qF -- 'Not filed' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- "$expected" <<<"$output" && return 1
  true
}

@test "UAT-005: retry files render one pending count line; an empty or absent retry folder renders none; transient never blocks" {
  local pending='- 2 finding(s) pending: the issue backend was unreachable; retried next round'
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file transient >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  mkdir -p "$RUN_FOLDER/filing-retry"
  printf '{}\n' >"$RUN_FOLDER/filing-retry/aaaa.json"
  printf '{}\n' >"$RUN_FOLDER/filing-retry/bbbb.json"
  run_sections
  green || return 1
  grep -qxF -- '## Not filed (no issue backend)' <<<"$output" || { echo "$output"; return 1; }
  [ "$(grep -cxF -- "$pending" <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  run_check_all
  green || return 1
  run_outcomes 1
  green || return 1
  rm -f "$RUN_FOLDER/filing-retry/"*.json
  run_sections
  grep -qF -- 'pending' <<<"$output" && { echo "$output"; return 1; }
  rmdir "$RUN_FOLDER/filing-retry"
  run_sections
  grep -qF -- 'pending' <<<"$output" && { echo "$output"; return 1; }
  run_check_all
  green || return 1
  run_outcomes 1
  green
}

@test "pr-sections: without --root it is a usage error" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run bash "$SCRIPT" pr-sections --run-folder "$RUN_FOLDER"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
}

@test "forward-only: a version-1 snapshot re-grades an undisposed out-of-branch finding clean; live, or as version 2, it fails undisposed" {
  local lookup sha snapshot_file="$SNAPSHOT_DIRECTORY/dispositions-1.checked.json"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.path == "f.txt")')"
  run_check 1
  red undisposed "$(key_json c/oos base.txt 3)" || return 1
  lookup="$(bash "$SCRIPTS/audit-loop-eval.sh" findings --root "$ALF_ROOT" --round 1 | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored})')"
  sha="$(shasum -a 256 <"$RUN_FOLDER/dispositions-1.json" | cut -d' ' -f1)"
  mkdir -p "$SNAPSHOT_DIRECTORY"
  jq -n -c --arg sha "$sha" --argjson lookup "$lookup" '{version: 1, round: 1, dispositions_sha256: $sha, lookup: $lookup}' >"$snapshot_file"
  run_check_all
  green || return 1
  run_check 1
  green || return 1
  jq -c '.version = 2' "$snapshot_file" >"$snapshot_file.new" && mv "$snapshot_file.new" "$snapshot_file"
  run_check_all
  red undisposed "$(key_json c/oos base.txt 3)"
}

@test "snapshot projection: check-all honors an earlier round's triage mark from its version-2 snapshot after the sidecar loses it" {
  with_maintainer "[$TRIAGE_ENTRY]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  jq -e '.version == 2 and any(.lookup[]; .finding_class == "c/tri" and .triage == true and .triage_reason == "below threshold")' \
    "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" >/dev/null || { cat "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json"; return 1; }
  alf_sidecar "$SHELL_MEMBER" "[$(jq -c 'del(.triage, .triage_reason)' <<<"$TRIAGE_ENTRY")]" 12
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"suggestion","security":false}]'
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/later fix)]"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  mv "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" "$BATS_TEST_TMPDIR/kept.json"
  run_check_all
  red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri .claude/hooks/h.sh 1)"
}

@test "carry-forward: a key disposed file in round 1, filed or transient, is not undisposed when round 2 re-reports it with no entry" {
  local outcome
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  for outcome in filed transient; do
    outcome_line c/oosimp base.txt 6 file "$outcome" >"$RUN_FOLDER/filing-outcomes-1.jsonl"
    run_check 2
    green || { echo "outcome $outcome"; return 1; }
    run_check_all
    green || { echo "outcome $outcome"; return 1; }
  done
}

@test "carry-forward: a key disposed fix in round 1 is still undisposed when round 2 re-reports it with no entry" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  run_check 2
  red undisposed "$(key_json c/oosimp base.txt 6)"
}
