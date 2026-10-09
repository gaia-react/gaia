#!/usr/bin/env bats
#
# Spec attribution from close rows, and the full-cycle Cost line
# (`usage.sh initiative <ref> --line [--json]`), read from usage.jsonl and
# links.jsonl alone. Every figure is a literal added up by hand from the
# fixture rows: opus at $2 per million input and $10 per million output, with
# only fresh input and output set.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-initiative-line.bats
#
# Expected lines carry literal dollar signs, so they are single-quoted on purpose.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  mkdir -p "$MAIN/.claude" "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  # shellcheck disable=SC2016  # the hook commands are written literally
  printf '%s\n' '{"hooks": {' \
    '  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],' \
    '  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]' \
    '}}' >"$MAIN/.claude/settings.json"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS
}

run_usage() { bash "$SCRIPTS/usage.sh" "$@" --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects"; }

# segment <key> <sid> <first_ts> <last_ts> <fresh_input> <output>
segment() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"%s","inherit":false,"first_ts":"%s","last_ts":"%s","messages":1,"agent_type":"main","by_model":{"claude-opus-5-5":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":%s}}}\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
start() {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"%s","source":"transcript"}\n' "$1" "$2" "$3" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
close() {
  printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command"}\n' "$1" "$2" "$3" "$4" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}
edge() {
  printf '{"schema_version":1,"kind":"edge","child":"%s","parent":"%s","source":"link-command","ts":"2026-10-02T08:00:00Z","session_id":null,"sidechain":false}\n' "$1" "$2" >>"$TELEMETRY_DIRECTORY/links.jsonl"
}

# One gaia-spec run: a segment before the start, two inside, one at the close
# instant and one after it. Inside: 202,000 + 303,000 tokens, $1.05.
spec_run_rows() {
  start s1 2026-10-01T10:00:00Z gaia-spec
  segment session:s1 s1 2026-10-01T09:30:00Z 2026-10-01T09:40:00Z 100000 1000
  segment session:s1 s1 2026-10-01T10:05:00Z 2026-10-01T10:30:00Z 200000 2000
  segment session:s1 s1 2026-10-01T10:40:00Z 2026-10-01T10:50:00Z 300000 3000
  [ "${1:-close}" = close ] && close s1 2026-10-01T11:00:00Z spec:SPEC-401 gaia-spec
  segment session:s1 s1 2026-10-01T11:00:00Z 2026-10-01T11:10:00Z 400000 4000
  segment session:s1 s1 2026-10-01T11:30:00Z 2026-10-01T11:40:00Z 500000 5000
}

# A spec with its gaia-spec and gaia-plan runs closed, its execution branch
# linked by an explicit edge, and a PR linked to that branch.
#   spec:SPEC-402         101,000 + 202,000 = 303,000 tokens, $0.63
#   branch:feat/build-x   1,010,000 tokens, $2.10
#   pr:88                 no spend, listed through its explicit edge
# Total 1,313,000 tokens, $2.73; 09:10 to 11:45 is 9300 s.
full_cycle_rows() {
  start s2 2026-10-02T09:00:00Z gaia-spec
  segment session:s2 s2 2026-10-02T09:10:00Z 2026-10-02T09:20:00Z 100000 1000
  close s2 2026-10-02T09:30:00Z spec:SPEC-402 gaia-spec
  start s3 2026-10-02T10:00:00Z gaia-plan
  segment session:s3 s3 2026-10-02T10:10:00Z 2026-10-02T10:20:00Z 200000 2000
  close s3 2026-10-02T10:40:00Z spec:SPEC-402 gaia-plan
  segment branch:feat/build-x s4 2026-10-02T11:00:00Z 2026-10-02T11:45:00Z 1000000 10000
  edge branch:feat/build-x spec:SPEC-402
  edge pr:88 branch:feat/build-x
}

@test "a close row attributes exactly the spend from the start to before the close, with no other store present" {
  spec_run_rows
  run run_usage initiative spec:SPEC-401
  [ "$status" -eq 0 ]
  grep -qxF '  spec:SPEC-401  tokens 505,000  est. $1.05' <<<"$output" || { printf '%s\n' "$output" >&2; return 1; }
  grep -qxF '  total (distinct segments): tokens 505,000  est. $1.05' <<<"$output"
  [ "$(find "$TELEMETRY_DIRECTORY" -type f -name '*.jsonl' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "guard red: without the close row the spec node is absent" {
  spec_run_rows no-close
  run run_usage initiative spec:SPEC-401
  [ "$status" -eq 0 ]
  grep -qF '  spec:SPEC-401  tokens' <<<"$output" && return 1
  grep -qxF '  total (distinct segments): tokens 0  est. $0.00' <<<"$output"
}

@test "--line prints one Cost line with a term per node, in the initiative's node order" {
  local nodes terms
  full_cycle_rows
  run run_usage initiative spec:SPEC-402 --line
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ ^Cost:\ ~[0-9]+\.[0-9]M\ tokens,\ \$[0-9]+\.[0-9]{2},\ ([0-9]+h)?([0-9]+m)?[0-9]+s\ \(.+\ \$[0-9]+\.[0-9]{2}(\ \+\ .+\ \$[0-9]+\.[0-9]{2})*\)$ ]]
  [ "$(grep -o '~' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$output" = 'Cost: ~1.3M tokens, $2.73, 2h35m0s (branch:feat/build-x $2.10 + pr:88 $0.00 + spec:SPEC-402 $0.63)' ]
  run run_usage initiative spec:SPEC-402
  nodes="$(awk '/^  [a-z]+:/ && !/^  total / && !/^  note: / { print $1 }' <<<"$output" | paste -sd ' ' -)"
  terms="$(run_usage initiative spec:SPEC-402 --line | sed -E 's/^[^(]*\((.*)\)$/\1/; s/ \$[0-9]+\.[0-9]{2}//g; s/ \+ / /g')"
  [ "$nodes" = 'branch:feat/build-x pr:88 spec:SPEC-402' ]
  [ "$terms" = "$nodes" ]
}

@test "--line --json exposes the raw figures, its tokens equal the initiative's distinct-segment total, and the line formats those numbers" {
  local figures total_line want_tokens tokens dollars elapsed line
  full_cycle_rows
  figures="$(run_usage initiative spec:SPEC-402 --line --json)"
  [ "$(jq -r 'keys | join(",")' <<<"$figures")" = 'dollars,elapsed_seconds,tokens' ]
  total_line="$(run_usage initiative spec:SPEC-402 | grep '^  total (distinct segments): ')"
  want_tokens="$(sed -E 's/^  total \(distinct segments\): tokens ([0-9,]+) .*/\1/' <<<"$total_line" | tr -d ',')"
  tokens="$(jq -r '.tokens' <<<"$figures")"
  [ "$tokens" = "$want_tokens" ]
  [ "$tokens" = 1313000 ]
  [ "$(jq -r '.elapsed_seconds' <<<"$figures")" = 9300 ]
  dollars="$(LC_ALL=C printf '%.2f' "$(jq -r '.dollars' <<<"$figures")")"
  [ "$dollars" = 2.73 ]
  elapsed="$(jq -r '.elapsed_seconds' <<<"$figures")"
  line="$(run_usage initiative spec:SPEC-402 --line)"
  [ "${line%% (*}" = "Cost: ~$(LC_ALL=C awk -v tokens="$tokens" 'BEGIN { printf "%.1fM", tokens / 1000000 }') tokens, \$$dollars, $((elapsed / 3600))h$((elapsed % 3600 / 60))m$((elapsed % 60))s" ]
}

@test "--line marks an unpriced model as a lower bound" {
  full_cycle_rows
  printf '{"schema_version":1,"kind":"segment","key":"branch:feat/build-x","session_id":"s5","inherit":false,"first_ts":"2026-10-02T11:10:00Z","last_ts":"2026-10-02T11:20:00Z","messages":1,"agent_type":"main","by_model":{"claude-zeta-1":{"fresh_input":10,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":0}}}\n' >>"$TELEMETRY_DIRECTORY/usage.jsonl"
  run run_usage initiative spec:SPEC-402 --line
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *') (partial: lower bound)' ]]
}

@test "--json without --line is a usage error: stderr says so, stdout is empty, and the readout exits 0" {
  full_cycle_rows
  run --separate-stderr run_usage initiative spec:SPEC-402 --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = 'usage initiative: --json needs --line' ]
}
