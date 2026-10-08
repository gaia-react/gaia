#!/usr/bin/env bats
#
# `usage.sh record`: closes a /gaia-spec, /gaia-plan or maintenance-command run
# and prints its Cost line. Each case drives the real flusher over a transcript
# written under a temporary projects tree, with the main checkout, telemetry
# directory and projects root all pinned under $BATS_TEST_TMPDIR. Figures are
# hand-added literals: opus at $2 per million input and $10 per million output,
# with only fresh input and output set.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-record.bats
#
# Expected lines carry literal dollar signs, so they are single-quoted on purpose.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  SIDECAR_META="$BATS_TEST_DIRNAME/fixtures/usage/record/sidecar-meta.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TEL="$MAIN/.gaia/local/telemetry"
  PROJECTS="$TEMPORARY_DIRECTORY/projects"
  mkdir -p "$MAIN/.claude" "$TEL"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  # Registered capture hooks are what makes the initiative readout list its nodes.
  printf '%s\n' '{"hooks": {' \
    '  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],' \
    '  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]' \
    '}}' >"$MAIN/.claude/settings.json"
  ENCODED_MAIN="$(printf '%s' "$MAIN" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$PROJECTS/$ENCODED_MAIN"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  unset GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  unset GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS GAIA_LEDGER_LOCK_FORCE_FALLBACK
  SID=sess-1
  export CLAUDE_CODE_SESSION_ID="$SID"
  USAGE_SCRIPT="$SCRIPTS/usage.sh"
}

# ---------- helpers ----------

record() { bash "$USAGE_SCRIPT" record "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }
usage() { bash "$USAGE_SCRIPT" "$@" --main-root "$MAIN" --projects-root "$PROJECTS" --rate-table "$RATES"; }
flush_now() {
  bash "$SCRIPTS/usage-flush.sh" --session "$SID" --finished-main --all-sidecars-finished \
    --main-root "$MAIN" --telemetry-dir "$TEL" --projects-root "$PROJECTS"
}

main_file() { printf '%s/%s/%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "$SID"; }
sidecar_file() { printf '%s/%s/%s/subagents/agent-%s.jsonl' "$PROJECTS" "$ENCODED_MAIN" "$SID" "$1"; }

# stamp <hh:mm[:ss] | iso>: a UTC stamp on a fixed day well before now; a full stamp passes through.
stamp() { case "$1" in 20*) printf '%s' "$1" ;; ??:??) printf '2026-10-01T%s:00Z' "$1" ;; *) printf '2026-10-01T%sZ' "$1" ;; esac; }

# emit_usage <file> <id> <hh:mm> <fresh input> <output>
emit_usage() {
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s},"content":[{"type":"text","text":"ok"}]}}\n' \
    "$2" "$(stamp "$3")" "$MAIN" "$SID" "$2" "$4" "$5" >>"$1"
}
# emit_start <file> <id> <hh:mm> <workflow>: the transcript line a Skill call writes.
emit_start() {
  printf '{"type":"assistant","uuid":"u-%s","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"t-%s","name":"Skill","input":{"skill":"%s"}}]}}\n' \
    "$2" "$(stamp "$3")" "$MAIN" "$SID" "$2" "$2" "$4" >>"$1"
}
main_usage() { emit_usage "$(main_file)" "$@"; }
main_start() { emit_start "$(main_file)" "$@"; }
sidecar_usage() {
  local agent="$1"
  shift
  mkdir -p "$(dirname "$(sidecar_file "$agent")")"
  cp "$SIDECAR_META" "$(dirname "$(sidecar_file "$agent")")/agent-$agent.meta.json"
  emit_usage "$(sidecar_file "$agent")" "$@"
}

ledger() { printf '%s/usage.jsonl' "$TEL"; }
close_count() {
  [ -f "$(ledger)" ] || { printf 0; return 0; }
  jq -s '[.[] | select(.kind == "binding" and .type == "close")] | length' "$(ledger)"
}
# after_last_close <seconds>: a stamp that many seconds after the newest close
# row, for a second run of one workflow, whose start must follow the first close.
after_last_close() {
  jq -rs --argjson offset "$1" '[.[] | select(.kind == "binding" and .type == "close")] | last | .ts | fromdateiso8601 + $offset | todate' "$(ledger)"
}
last_stdout_line() { printf '%s' "${lines[$((${#lines[@]} - 1))]}"; }
initiative_tokens() { usage initiative "$1" --line --json | jq -r '.tokens'; }

# One gaia-spec run in sess-1: a message before the start; after it 101,000 in
# the main file, 50,000 in a sidecar and, written after the first flush, 202,000
# more in the main file and 303,000 in the sidecar. Inside the run: 656,000
# tokens, $1.36.
spec_run_fixture() {
  SID="$1"
  export CLAUDE_CODE_SESSION_ID="$SID"
  mkdir -p "$(dirname "$(main_file)")"
  main_usage m0 10:00 7000 70
  main_start s1 10:01 gaia-spec
  main_usage m1 10:02 100000 1000
  sidecar_usage a0 x0 10:01:30 50000 0
  flush_now
  main_usage m2 10:03 200000 2000
  sidecar_usage a0 x1 10:04 300000 3000
}

# scratch_scripts <dir>: a copy of the scripts the record path loads, mutable
# without touching the checkout. No node_modules or other real directory is linked.
scratch_scripts() {
  local scratch="$1" file
  mkdir -p "$scratch/spec"
  for file in "$SCRIPTS"/usage*.sh "$SCRIPTS"/token-*.sh "$SCRIPTS"/token-rates.json "$SCRIPTS"/branch-name-lib.sh \
    "$SCRIPTS"/main-root-lib.sh "$SCRIPTS"/ledger-path-lib.sh; do
    [ -f "$file" ] && cp "$file" "$scratch/"
  done
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
}

# ---------- close, flush, Cost line ----------

@test "record flushes the session whole, appends one close after the new segments, and prints the Cost line last" {
  local main_path sidecar_path close_ts
  spec_run_fixture sess-1
  main_path="$(main_file)"
  sidecar_path="$(sidecar_file a0)"
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$(last_stdout_line)" =~ ^Cost:\ ~0\.7M\ tokens,\ \$1\.36,\ [0-9hms]+$ ]]
  # Every byte of the main file and the sidecar is behind its cursor.
  [ "$(jq --arg path "$main_path" '.files[$path].offset' "$TEL/usage-cursors.json")" -eq "$(wc -c <"$main_path" | tr -d ' ')" ]
  [ "$(jq --arg path "$sidecar_path" '.files[$path].offset' "$TEL/usage-cursors.json")" -eq "$(wc -c <"$sidecar_path" | tr -d ' ')" ]
  [ "$(close_count)" -eq 1 ]
  tail -n 1 "$(ledger)" | jq -e --arg sid sess-1 '.kind == "binding" and .type == "close" and .ref == "spec:SPEC-901" and .workflow == "gaia-spec"
    and .session_id == $sid and .source == "record-command" and (has("start_ts") | not)' >/dev/null
  close_ts="$(tail -n 1 "$(ledger)" | jq -r '.ts')"
  jq -s -e --arg close_ts "$close_ts" '[.[] | select(.kind == "segment" and (.first_ts == "2026-10-01T10:03:00Z" or .first_ts == "2026-10-01T10:04:00Z"))]
    | length == 2 and all(.first_ts < $close_ts)' "$(ledger)" >/dev/null
  # No second cost store is written.
  local retired_store="cost"".jsonl" retired_sidecar="cost"".json"
  [ -z "$(find "$MAIN" -name "$retired_store" -o -name "$retired_sidecar" 2>/dev/null)" ]
}

@test "record --json prints the same raw tokens the full-cycle initiative line reports" {
  local record_tokens
  spec_run_fixture sess-1
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' <<<"$(last_stdout_line)")" = '["dollars","elapsed_seconds","tokens"]' ]
  record_tokens="$(jq -r '.tokens' <<<"$(last_stdout_line)")"
  [ "$record_tokens" -eq 656000 ]
  [ "$(initiative_tokens spec:SPEC-901)" -eq "$record_tokens" ]
  [ "$(LC_ALL=C printf '%.2f' "$(jq -r '.dollars' <<<"$(last_stdout_line)")")" = 1.36 ]
}

@test "a plan recorded with no spec, its branch and a PR linked, lists the three nodes and their distinct total" {
  mkdir -p "$(dirname "$(main_file)")"
  main_usage m0 10:00 7000 70
  main_start p1 10:01 gaia-plan
  main_usage m1 10:02 100000 1000
  run record plan:PLAN-902 --workflow gaia-plan
  [ "$status" -eq 0 ]
  run usage link branch:feature/plan-work plan:PLAN-902
  [ "$status" -eq 0 ]
  run usage link pr:12 branch:feature/plan-work
  [ "$status" -eq 0 ]
  printf '{"schema_version":1,"kind":"segment","key":"branch:feature/plan-work","session_id":"s9","inherit":false,"first_ts":"2026-10-02T09:00:00Z","last_ts":"2026-10-02T09:00:00Z","messages":1,"agent_type":"main","by_model":{"claude-opus-5-5":{"fresh_input":10000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}}}\n' >>"$(ledger)"
  printf '{"schema_version":1,"kind":"segment","key":"pr:12","session_id":"s9","inherit":false,"first_ts":"2026-10-02T09:10:00Z","last_ts":"2026-10-02T09:10:00Z","messages":1,"agent_type":"main","by_model":{"claude-opus-5-5":{"fresh_input":5000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}}}\n' >>"$(ledger)"
  run usage initiative plan:PLAN-902
  [ "$status" -eq 0 ]
  [[ "$output" == *"  plan:PLAN-902  tokens 101,000  est. \$0.21"* ]]
  [[ "$output" == *"  branch:feature/plan-work  tokens 10,000  est. \$0.02"* ]]
  [[ "$output" == *"  pr:12  tokens 5,000  est. \$0.01"* ]]
  [[ "$output" == *"total (distinct segments): tokens 116,000  est. \$0.24"* ]]
}

@test "two runs of one command in a session get distinct refs, and --pr and --issue link the run" {
  local first_ref second_ref
  mkdir -p "$(dirname "$(main_file)")"
  main_start f1 10:00 gaia-fitness
  main_usage m1 10:10 4000 0
  run record command:gaia-fitness --workflow gaia-fitness
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" =~ ^Cost:\ ~0\.0M\ tokens,\ \$0\.01,\ [0-9hms]+$ ]]
  main_start f2 "$(after_last_close 1)" gaia-fitness
  main_usage m2 "$(after_last_close 2)" 6000 0
  sleep 3
  run record command:gaia-fitness --workflow gaia-fitness --pr 77 --issue 55
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" =~ ^Cost: ]]
  first_ref="$(jq -rs '[.[] | select(.kind == "binding" and .type == "close")][0].ref' "$(ledger)")"
  second_ref="$(jq -rs '[.[] | select(.kind == "binding" and .type == "close")][1].ref' "$(ledger)")"
  [[ "$first_ref" =~ ^command:gaia-fitness-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$ ]]
  [[ "$second_ref" =~ ^command:gaia-fitness-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$ ]]
  [ "$first_ref" != "$second_ref" ]
  jq -s -e --arg ref "$second_ref" '[.[] | select(.kind == "edge" and .parent == $ref)] | map(.child) | sort == ["issue:55", "pr:77"]' "$TEL/links.jsonl" >/dev/null
  jq -s -e '[.[] | select(.kind == "edge")] | all(.source == "link-command")' "$TEL/links.jsonl" >/dev/null
  run usage initiative pr:77
  [ "$status" -eq 0 ]
  [[ "$output" == *"$second_ref"* ]]
}

# ---------- refusals ----------

@test "no unclaimed start: exit 1, no close row, one stderr line naming the reason and the recovery command" {
  mkdir -p "$(dirname "$(main_file)")"
  main_usage m1 10:10 1000 0
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"no unclaimed gaia-spec start in this session"* ]]
  [[ "$stderr" == *"usage.sh record spec:SPEC-901 --workflow gaia-spec --start <iso>"* ]]
  [ "$(close_count)" -eq 0 ]
}

@test "recording the same run twice: the second is refused as already recorded and writes nothing" {
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"already recorded"* ]]
  [ "$(close_count)" -eq 1 ]
}

@test "usage errors and an empty session each write no close row and print one stderr line" {
  local case_arguments
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run --separate-stderr env CLAUDE_CODE_SESSION_ID= bash "$USAGE_SCRIPT" record spec:SPEC-901 --workflow gaia-spec --main-root "$MAIN" --projects-root "$PROJECTS"
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"session"* ]]
  [ "$(close_count)" -eq 0 ]
  for case_arguments in "spec:bad --workflow gaia-spec" "spec:SPEC-901 --workflow gaia-spec --bogus" "spec:SPEC-901 --workflow gaia-spec --pr 5" \
    "spec:SPEC-901 --workflow gaia-spec --issue 5" "spec:SPEC-901" "spec:SPEC-901 --workflow gaia-fitness" "spec:SPEC-901 --workflow nonsense" \
    "plan:PLAN-901 --workflow gaia-spec" "command:gaia-fitness --workflow gaia-audit" "command:gaia-spec --workflow gaia-spec" \
    "command:gaia-fitness --workflow gaia-fitness --pr 0" "spec:SPEC-901 --workflow gaia-spec --start not-a-time" \
    "spec:SPEC-901 --workflow gaia-spec --start 2999-01-01T00:00:00Z" "spec:SPEC-901 --workflow gaia-spec --line"; do
    # shellcheck disable=SC2086  # the case string is word-split into arguments on purpose
    run --separate-stderr record $case_arguments
    [ "$status" -eq 2 ] || { printf 'case: %s status %s\n' "$case_arguments" "$status" >&2; return 1; }
    [ "${#stderr_lines[@]}" -eq 1 ] || { printf 'case: %s stderr: %s\n' "$case_arguments" "$stderr" >&2; return 1; }
    [ -z "$output" ]
  done
  [ "$(close_count)" -eq 0 ]
}

@test "jq absent from PATH: record exits 2 with one stderr line and writes nothing" {
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  run --separate-stderr env PATH=/var/empty "$BASH" "$USAGE_SCRIPT" record spec:SPEC-901 --workflow gaia-spec --main-root "$MAIN"
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"jq"* ]]
  [ -z "$output" ]
  run --separate-stderr env PATH=/var/empty "$BASH" "$USAGE_SCRIPT" represented spec:SPEC-901 --workflow gaia-spec --main-root "$MAIN"
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$(ledger)" ]
}

@test "an unreadable ledger is a usage error that writes nothing" {
  mkdir -p "$(ledger)"
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"cannot be read"* ]]
}

@test "ledger lock held past the timeout: exit 1 with the stated stderr line, and nothing is written" {
  local holder_pid i=0 before
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"sess-1","ts":"2026-10-01T10:00:00Z","workflow":"gaia-spec","source":"transcript"}\n' >"$(ledger)"
  before="$(cksum <"$(ledger)")"
  bash -c '. "$1/spec/with-ledger-lock.sh"; with_ledger_lock "$2" bash -c "touch \"\$1\"; sleep 8" _ "$3"' _ "$SCRIPTS" "$TEL" "$BATS_TEST_TMPDIR/lock-held" \
    >/dev/null 2>&1 3>&- &
  holder_pid=$!
  while [ ! -e "$BATS_TEST_TMPDIR/lock-held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$BATS_TEST_TMPDIR/lock-held" ]
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  kill "$holder_pid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == "usage record: ledger lock timed out; nothing was written, rerun: bash .gaia/scripts/usage.sh record spec:SPEC-901 --workflow gaia-spec" ]]
  [ "$(cksum <"$(ledger)")" = "$before" ]
}

# ---------- pairing ----------

@test "an abandoned start is superseded: the close pairs with the newest start, and a second record is refused" {
  local mutated="$TEMPORARY_DIRECTORY/mutated"
  mkdir -p "$(dirname "$(main_file)")"
  main_start a1 10:00 gaia-spec
  main_usage ma 10:10 1000 0
  main_start b1 11:00 gaia-spec
  main_usage mb 11:10 2000 0
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 2000 ]
  [ "$(initiative_tokens spec:SPEC-901)" -eq 2000 ]
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"already recorded"* ]]
  [ "$(close_count)" -eq 1 ]
  # The rule can fail: an earliest-unclaimed pairing in a scratch copy of the
  # resolve library pairs the same close with the abandoned start and counts both.
  rm -rf "$TEL" && mkdir -p "$TEL"
  scratch_scripts "$mutated"
  sed -i.bak 's/select(\._t <= \$close\._t)\] | last)/select(._t <= $close._t)] | first)/' "$mutated/usage-resolve-lib.sh"
  if cmp -s "$SCRIPTS/usage-resolve-lib.sh" "$mutated/usage-resolve-lib.sh"; then return 1; fi
  USAGE_SCRIPT="$mutated/usage.sh"
  flush_now
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 3000 ]
}

@test "--start recovers a start detection missed, and a repeat is refused as already recorded" {
  mkdir -p "$(dirname "$(main_file)")"
  main_usage m0 10:00 1000 0
  flush_now
  main_usage m1 10:10 2000 0
  main_usage m2 10:20 3000 0
  run record spec:SPEC-901 --workflow gaia-spec --start "$(stamp 10:05)" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 5000 ]
  [ "$(jq -r '.elapsed_seconds' <<<"$(last_stdout_line)")" -gt 0 ]
  jq -s -e '[.[] | select(.kind == "binding" and (.type == "start" or .type == "close"))]
    | length == 2 and .[0].type == "start" and .[0].ts == "2026-10-01T10:05:00Z" and .[0].source == "record-command"
      and .[1].type == "close" and .[1].start_ts == "2026-10-01T10:05:00Z" and .[1].ref == "spec:SPEC-901"' "$(ledger)" >/dev/null
  run --separate-stderr record spec:SPEC-901 --workflow gaia-spec --start "$(stamp 10:05)"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"already recorded"* ]]
  [ "$(close_count)" -eq 1 ]
}

@test "two runs of one workflow in a session each report only their own segments" {
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 1000 ]
  main_start s2 "$(after_last_close 1)" gaia-spec
  main_usage m2 "$(after_last_close 2)" 2000 0
  sleep 3
  run record spec:SPEC-902 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 2000 ]
  [ "$(initiative_tokens spec:SPEC-901)" -eq 1000 ]
  [ "$(initiative_tokens spec:SPEC-902)" -eq 2000 ]
}

@test "a plan run recorded under a spec reports its own interval; the initiative line carries the whole cycle" {
  local plan_line
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  main_start p1 12:00 gaia-plan
  main_usage m2 12:10 4000 0
  run record spec:SPEC-901 --workflow gaia-plan --json
  [ "$status" -eq 0 ]
  plan_line="$(last_stdout_line)"
  [ "$(jq -r '.tokens' <<<"$plan_line")" -eq 4000 ]
  [ "$(initiative_tokens spec:SPEC-901)" -eq 5000 ]
  [ "$(close_count)" -eq 2 ]
  run usage initiative spec:SPEC-901 --line
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" == "Cost: ~0.0M tokens, "* ]]
}

@test "a recovery inside a live run leaves the live run's start unclaimed and its interval intact" {
  mkdir -p "$(dirname "$(main_file)")"
  main_usage ma 09:30 500 0
  main_start s1 10:00 gaia-spec
  main_usage mb 10:10 1000 0
  run record spec:SPEC-902 --workflow gaia-spec --start "$(stamp 09:00)"
  [ "$status" -eq 0 ]
  run record spec:SPEC-901 --workflow gaia-spec --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tokens' <<<"$(last_stdout_line)")" -eq 1000 ]
  [ "$(initiative_tokens spec:SPEC-901)" -eq 1000 ]
  [ "$(initiative_tokens spec:SPEC-902)" -eq 500 ]
}

# ---------- the flush and the close ----------

@test "a message written after the close is not attributed to the closed interval on the next flush" {
  local close_ts late_ts
  mkdir -p "$(dirname "$(main_file)")"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  run record spec:SPEC-901 --workflow gaia-spec
  [ "$status" -eq 0 ]
  close_ts="$(tail -n 1 "$(ledger)" | jq -r '.ts')"
  late_ts="$(jq -rn --arg close_ts "$close_ts" '($close_ts | fromdateiso8601 + 60) | todate')"
  printf '{"type":"assistant","uuid":"u-late","timestamp":"%s","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"late","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":9000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"ok"}]}}\n' \
    "$late_ts" "$MAIN" "$SID" >>"$(main_file)"
  flush_now
  jq -s -e --arg late_ts "$late_ts" '[.[] | select(.kind == "segment" and .first_ts == $late_ts)] | length == 1' "$(ledger)" >/dev/null
  [ "$(initiative_tokens spec:SPEC-901)" -eq 1000 ]
}

# partial_scenario: a fresh telemetry directory holding the committed start and
# one message, a pre-close message and a message stamped far in the future in
# the transcript, and a flusher held at its barrier past the cap of a record run.
# Returns once the held flusher has committed.
partial_scenario() {
  local barrier="$BATS_TEST_TMPDIR/barrier" i=0
  rm -rf "${TEL:?}" "$barrier" "${PROJECTS:?}/${ENCODED_MAIN:?}"
  mkdir -p "$TEL" "$PROJECTS/$ENCODED_MAIN"
  main_start s1 10:00 gaia-spec
  main_usage m1 10:10 1000 0
  flush_now
  main_usage m2 10:20 2000 0
  printf '{"type":"assistant","uuid":"u-late","timestamp":"2099-01-01T00:00:00Z","cwd":"%s","sessionId":"%s","gitBranch":"main","message":{"id":"late","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":9000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"ok"}]}}\n' \
    "$MAIN" "$SID" >>"$(main_file)"
  GAIA_USAGE_TEST_BARRIER="$barrier" GAIA_USAGE_MERGE_CAP_SECONDS=1 run record spec:SPEC-901 --workflow gaia-spec
  touch "$barrier"
  while ! jq -s -e '[.[] | select(.kind == "segment" and (.last_ts | startswith("2099")))] | length > 0' "$(ledger)" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 100 ]
}

straddling_segments() {
  local close_ts
  close_ts="$(jq -rs '[.[] | select(.kind == "binding" and .type == "close")][0].ts' "$(ledger)")"
  jq -s --arg close_ts "$close_ts" '[.[] | select(.kind == "segment" and .first_ts < $close_ts and .last_ts >= $close_ts)] | length' "$(ledger)"
}

@test "a flusher that outlasts the cap leaves the close written once and the line marked partial; its late commit splits at the close" {
  partial_scenario
  [ "$status" -eq 0 ]
  [[ "$(last_stdout_line)" =~ ^Cost:.*\ \(partial:\ flush\ incomplete\)$ ]]
  [ "$(close_count)" -eq 1 ]
  [ "$(straddling_segments)" -eq 0 ]
}

@test "the commit-time close re-check is what keeps a late flusher from straddling the close" {
  local mutated="$TEMPORARY_DIRECTORY/mutated-flusher"
  scratch_scripts "$mutated"
  sed -i.bak 's/^_uf_closes_changed() {$/_uf_closes_changed() { return 1/' "$mutated/usage-flush.sh"
  if cmp -s "$SCRIPTS/usage-flush.sh" "$mutated/usage-flush.sh"; then return 1; fi
  USAGE_SCRIPT="$mutated/usage.sh"
  partial_scenario
  [ "$status" -eq 0 ]
  [ "$(straddling_segments)" -ge 1 ]
}

# ---------- loading ----------

@test "usage-record-lib.sh loads at top level: without it initiative and record both fail naming it" {
  local scratch="$TEMPORARY_DIRECTORY/no-record-lib"
  scratch_scripts "$scratch"
  rm "$scratch/usage-record-lib.sh"
  run --separate-stderr bash "$scratch/usage.sh" initiative spec:SPEC-001 --main-root "$MAIN"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"usage-record-lib.sh"* ]]
  run --separate-stderr bash "$scratch/usage.sh" record spec:SPEC-001 --workflow gaia-spec --main-root "$MAIN"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"usage-record-lib.sh"* ]]
}

@test "usage-record-lib.sh holds no second attribution or pricing path" {
  run grep -nE 'priced_row|rate_window|GAIA_PRICING_JQ_DEFS|usage_resolve_t|first_ts' "$SCRIPTS/usage-record-lib.sh"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
