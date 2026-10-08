#!/usr/bin/env bats
#
# `usage.sh represented`: the archive gate's question, whether a run's close
# row is on the ledger. It reads close rows alone and prints nothing on stdout.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-represented.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # The telemetry directory sits outside any repository, and the cwd is a
  # different directory, so the flags are what point the command at it.
  TEL="$TEMPORARY_DIRECTORY/elsewhere/telemetry"
  WORKING_DIRECTORY="$TEMPORARY_DIRECTORY/cwd"
  mkdir -p "$TEL" "$WORKING_DIRECTORY"
  unset CLAUDE_CODE_SESSION_ID GITHUB_ACTIONS
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
}

represented() { (cd "$WORKING_DIRECTORY" && bash "$USAGE_SCRIPT" represented "$@" --main-root "$TEMPORARY_DIRECTORY/elsewhere" --telemetry-dir "$TEL"); }

close() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"s1","ts":"2026-10-01T11:00:00Z","ref":"%s","workflow":"%s","source":"record-command"}\n' "$1" "$2" >>"$TEL/usage.jsonl"
}

@test "exit 0 when a close with that ref and workflow is on the ledger, 1 when none is, and nothing on stdout" {
  close spec:SPEC-901 gaia-spec
  run --separate-stderr represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run represented spec:SPEC-902 --workflow gaia-spec
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "only the other workflow's close is not a match" {
  close spec:SPEC-901 gaia-plan
  run represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 1 ]
  run represented spec:SPEC-901 --workflow gaia-plan
  [ "$status" -eq 0 ]
}

@test "a command ref matches the run ref written under its prefix, and a longer slug does not" {
  close command:gaia-fitness-20261001T110000Z-a1b2 gaia-fitness
  run represented command:gaia-fitness --workflow gaia-fitness
  [ "$status" -eq 0 ]
  run represented command:gaia-fit --workflow gaia-fitness
  [ "$status" -eq 1 ]
  run represented command:gaia-fitness-20261001T110000Z-a1b2 --workflow gaia-fitness
  [ "$status" -eq 0 ]
}

@test "a start row alone, or a torn line, never counts as a close" {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"s1","ts":"2026-10-01T10:00:00Z","workflow":"gaia-spec","source":"transcript"}\n' >>"$TEL/usage.jsonl"
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"s1","ts":"2026-10-0' >>"$TEL/usage.jsonl"
  run represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 1 ]
}

@test "usage errors and an unreadable ledger exit 2 with one stderr line and nothing on stdout" {
  local case_arguments
  close spec:SPEC-901 gaia-spec
  for case_arguments in "spec:SPEC-901" "spec:bad --workflow gaia-spec" "--workflow gaia-spec" "spec:SPEC-901 --workflow Bad_Name" \
    "spec:SPEC-901 --workflow gaia-spec --pr 4" "spec:SPEC-901 --workflow gaia-spec --json" "spec:SPEC-901 --workflow gaia-spec --bogus"; do
    # shellcheck disable=SC2086  # the case string is word-split into arguments on purpose
    run --separate-stderr represented $case_arguments
    [ "$status" -eq 2 ] || { printf 'case: %s status %s\n' "$case_arguments" "$status" >&2; return 1; }
    [ "${#stderr_lines[@]}" -eq 1 ] || { printf 'case: %s stderr: %s\n' "$case_arguments" "$stderr" >&2; return 1; }
    [ -z "$output" ]
  done
  rm "$TEL/usage.jsonl"
  run --separate-stderr represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"missing"* ]]
  # A directory in the ledger's place exists and cannot be read as a file.
  mkdir "$TEL/usage.jsonl"
  run --separate-stderr represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"cannot be read"* ]]
}

# ---------- the expensive paths stay unentered ----------

# traced_scripts <dir>: a copy of the scripts whose memo, keys and branch-map
# entry points write a sentinel and exit 99 when called.
traced_scripts() {
  local scratch="$1" file
  mkdir -p "$scratch/spec"
  for file in "$SCRIPTS"/usage*.sh "$SCRIPTS"/token-*.sh "$SCRIPTS"/token-rates.json "$SCRIPTS"/branch-name-lib.sh \
    "$SCRIPTS"/main-root-lib.sh "$SCRIPTS"/ledger-path-lib.sh; do
    [ -f "$file" ] && cp "$file" "$scratch/"
  done
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
  # shellcheck disable=SC2016  # the appended definitions expand at call time
  {
    printf '\ngaia_usage_memo_readout() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
    printf 'gaia_usage_memo_view() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
    printf 'gaia_usage_memo_warm() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
    printf 'gaia_usage_memo_load() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
  } >>"$scratch/usage-memo-lib.sh"
  # shellcheck disable=SC2016
  {
    printf '\ngaia_usage_keys_json() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
    printf 'gaia_usage_derive_map() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n'
  } >>"$scratch/usage-resolve-lib.sh"
  # shellcheck disable=SC2016
  printf '\ngaia_usage_branch_map() { : >"$GAIA_TEST_SENTINEL"; exit 99; }\n' >>"$scratch/usage-lib.sh"
}

@test "represented answers without entering the memo, keys or branch-map paths" {
  local scratch="$TEMPORARY_DIRECTORY/traced"
  traced_scripts "$scratch"
  export GAIA_TEST_SENTINEL="$TEMPORARY_DIRECTORY/sentinel"
  USAGE_SCRIPT="$scratch/usage.sh"
  close spec:SPEC-901 gaia-spec
  run represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  run represented spec:SPEC-902 --workflow gaia-spec
  [ "$status" -eq 1 ]
  [ ! -e "$GAIA_TEST_SENTINEL" ]
}

@test "the call trace can fail: a represented that reads the keys writes the sentinel" {
  local scratch="$TEMPORARY_DIRECTORY/traced-mutated"
  traced_scripts "$scratch"
  export GAIA_TEST_SENTINEL="$TEMPORARY_DIRECTORY/sentinel"
  USAGE_SCRIPT="$scratch/usage.sh"
  sed -i.bak 's/^  \[ -f "\$usage_file" \] || { _error "the usage ledger is missing"; return 2; }$/&\n  gaia_usage_keys_json "$MAIN_ROOT" "$usage_file" \/dev\/null >\/dev\/null/' "$scratch/usage-record-lib.sh"
  if cmp -s "$SCRIPTS/usage-record-lib.sh" "$scratch/usage-record-lib.sh"; then return 1; fi
  close spec:SPEC-901 gaia-spec
  run represented spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 99 ]
  [ -e "$GAIA_TEST_SENTINEL" ]
}
