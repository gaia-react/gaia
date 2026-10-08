#!/usr/bin/env bats
#
# The readouts read usage.jsonl and links.jsonl only. A retired cost store left
# in the telemetry directory, holding spec, plan, command and execute rows that
# the pre-change scripts would turn into interval closes and derived edges,
# changes no byte of any readout. The pinned pre-change scripts run over the
# same rows to prove the poison is real: their output moves with it.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-poisoned-ledger.bats

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/usage-memo-env.sh
  . "$BATS_TEST_DIRNAME/helpers/usage-memo-env.sh"
  umemo_setup
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  # The retired store's file name, built from parts so no test file carries it whole.
  POISON="$UM_TELEMETRY_DIRECTORY/cost"".jsonl"
  CAPTURE_DIRECTORY="$BATS_TEST_TMPDIR/cap"
  mkdir -p "$CAPTURE_DIRECTORY"
  ledger_rows
}

# segment <key> <sid> <first_ts>
segment() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"agent_type":"main","by_model":{"claude-opus-5-5":{"fresh_input":100000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":1000}}}\n' "$1" "$2" "$3" "$3"
}

ledger_rows() {
  {
    printf '%s\n' '{"schema_version":1,"kind":"binding","type":"start","session_id":"s1","ts":"2026-10-01T10:00:00Z","workflow":"gaia-spec","source":"transcript"}'
    segment session:s1 s1 2026-10-01T10:05:00Z
    printf '%s\n' '{"schema_version":1,"kind":"binding","type":"close","session_id":"s1","ts":"2026-10-01T11:00:00Z","ref":"spec:SPEC-601","workflow":"gaia-spec","source":"record-command"}'
    printf '%s\n' '{"schema_version":1,"kind":"binding","type":"start","session_id":"s2","ts":"2026-10-01T12:00:00Z","workflow":"gaia-plan","source":"transcript"}'
    segment session:s2 s2 2026-10-01T12:10:00Z
    printf '%s\n' '{"schema_version":1,"kind":"binding","type":"start","session_id":"s3","ts":"2026-10-01T13:00:00Z","workflow":"gaia-debt","source":"transcript"}'
    segment branch:feat/x s3 2026-10-01T13:10:00Z
    segment branch:feat/x s4 2026-10-01T14:00:00Z
  } >"$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  printf '%s\n' \
    '{"schema_version":1,"kind":"edge","child":"pr:70","parent":"branch:feat/x","source":"gh-pr-create","ts":"2026-10-01T14:30:00Z","session_id":null,"sidechain":false}' \
    '{"schema_version":1,"kind":"edge","child":"branch:feat/x","parent":"spec:SPEC-601","source":"link-command","ts":"2026-10-01T14:30:00Z","session_id":null,"sidechain":false}' \
    '{"schema_version":1,"kind":"merge","pr":70,"key":"branch:feat/x","merged_at":"2026-10-02T00:00:00Z","source":"gh-pr-merge","ts":"2026-10-02T00:00:00Z","session_id":null}' \
    >"$UM_TELEMETRY_DIRECTORY/links.jsonl"
}

# Rows the pre-change scripts read: a spec row that would close s1's run under
# another ref, a plan row that would close s2's run and link the branch to a
# plan, a command row that would take s3's branch spend and link the PR, and an
# execute row that would link the branch to another spec.
poison() {
  printf '%s\n' \
    '{"schema_version":1,"kind":"spec","session_id":"s1","ts":"2026-10-01T10:30:00Z","spec_id":"SPEC-699","plan_id":null,"git_branch":"main"}' \
    '{"schema_version":1,"kind":"plan","session_id":"s2","ts":"2026-10-01T12:30:00Z","spec_id":null,"plan_id":"PLAN-060","git_branch":"feat/x"}' \
    '{"schema_version":1,"kind":"command","session_id":"s3","ts":"2026-10-01T13:30:00Z","spec_id":null,"plan_id":null,"command":"gaia-debt","run_id":"gaia-debt-r9","github":{"type":"pr","number":70,"repo":"o/r"},"git_branch":"feat/x"}' \
    '{"schema_version":1,"kind":"execute","session_id":"s4","ts":"2026-10-01T14:10:00Z","spec_id":"SPEC-603","plan_id":null,"git_branch":"feat/x"}' \
    >"$POISON"
}

# capture <tag> <old|new> <args...>: stdout, stderr and status of one readout.
capture() {
  local tag="$1" variant="$2" exit_status=0
  shift 2
  UM_OUTPUT_FILE="$CAPTURE_DIRECTORY/$tag.out" UM_ERROR_FILE="$CAPTURE_DIRECTORY/$tag.err" "u_$variant" "$@" || exit_status=$?
  printf '%s\n' "$exit_status" >"$CAPTURE_DIRECTORY/$tag.rc"
}

same_capture() {
  assert_same "$CAPTURE_DIRECTORY/$1.out" "$CAPTURE_DIRECTORY/$2.out" &&
    assert_same "$CAPTURE_DIRECTORY/$1.err" "$CAPTURE_DIRECTORY/$2.err" &&
    assert_same "$CAPTURE_DIRECTORY/$1.rc" "$CAPTURE_DIRECTORY/$2.rc"
}

@test "every readout prints the same bytes with and without a poisoned retired store" {
  local readout tag seen=0
  local -a readouts=("pr 70" "pr --key branch:feat/x" "initiative spec:SPEC-601" "initiative spec:SPEC-601 --line" "initiative spec:SPEC-601 --line --json" "reconcile")
  for readout in "${readouts[@]}"; do
    tag="r$seen"
    rm -f "$POISON" "$UM_TELEMETRY_DIRECTORY/usage-branch-memo.json"
    # shellcheck disable=SC2086  # the readout's words are split on purpose
    capture "$tag-clean" new $readout
    poison
    rm -f "$UM_TELEMETRY_DIRECTORY/usage-branch-memo.json"
    # shellcheck disable=SC2086
    capture "$tag-poisoned" new $readout
    [ -s "$CAPTURE_DIRECTORY/$tag-clean.out" ] || { printf '%s printed nothing\n' "$readout" >&2; return 1; }
    same_capture "$tag-clean" "$tag-poisoned" || { printf 'readout moved with the poison: %s\n' "$readout" >&2; return 1; }
    seen=$((seen + 1))
  done
  [ "$seen" -eq "${#readouts[@]}" ]
  grep -qF '  spec:SPEC-601  tokens 101,000' "$CAPTURE_DIRECTORY/r2-clean.out"
  grep -q '^Cost: ~' "$CAPTURE_DIRECTORY/r3-clean.out"
}

@test "the poison is real: the pre-change scripts print different per-PR and reconcile figures with it" {
  local readout tag moved=0
  for readout in "pr 70" "reconcile"; do
    tag="${readout%% *}"
    rm -f "$POISON"
    # shellcheck disable=SC2086
    capture "$tag-old-clean" old $readout
    poison
    # shellcheck disable=SC2086
    capture "$tag-old-poisoned" old $readout
    if ! cmp -s "$CAPTURE_DIRECTORY/$tag-old-clean.out" "$CAPTURE_DIRECTORY/$tag-old-poisoned.out"; then moved=$((moved + 1)); fi
  done
  [ "$moved" -eq 2 ]
  grep -qF '[initiative plan:PLAN-060 to date' "$CAPTURE_DIRECTORY/pr-old-poisoned.out"
  grep -qF '[initiative plan:PLAN-060 to date' "$CAPTURE_DIRECTORY/pr-old-clean.out" && return 1
  true
}

@test "usage.sh --help no longer offers a retired-store flag" {
  # Built from parts so the retired flag never appears whole in a usage file.
  local retired_flag="--led""ger"
  run bash "$UM_NEW/.gaia/scripts/usage.sh" --help
  [ "$status" -eq 0 ]
  grep -qF -- '--main-root' <<<"$output"
  grep -qF -- "$retired_flag" <<<"$output" && return 1
  run bash "$UM_NEW/.gaia/scripts/usage.sh" pr 70 "$retired_flag" /dev/null --main-root "$UM_MAIN" --telemetry-dir "$UM_TELEMETRY_DIRECTORY"
  [ "$status" -eq 0 ]
  grep -qF "unknown flag $retired_flag" <<<"$output"
}
