#!/usr/bin/env bats
#
# The Code Audit Team line of the per-PR block (`usage.sh pr ... --auditors`):
# it sums the in-window branch segments whose agent_type is a listed name, and
# a segment with no agent_type stays out of that sum and is only counted, for
# the lower-bound marker. Figures are hand-added literals: opus at $2 per
# million input and $10 per million output, fresh input and output only.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-audit-line.bats
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
  audit_rows
}

run_usage() { bash "$SCRIPTS/usage.sh" "$@" --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects"; }

# segment <agent fields json fragment> <first_ts> <fresh_input> <output>
segment() {
  printf '{"schema_version":1,"kind":"segment","key":"branch:feat/audit","session_id":"s1","inherit":false,"first_ts":"%s","last_ts":"%s",%s"messages":1,"by_model":{"claude-opus-5-5":{"fresh_input":%s,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":%s}}}\n' \
    "$2" "$2" "$1" "$3" "$4" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}

# Main 101,000; the two roster sidecars 202,000 + 303,000 (505,000, $1.05);
# a general-purpose sidecar 404,000; an unknown one 505,000; and 606,000 on a
# segment written before the agent fields existed. 2,121,000 in all.
audit_rows() {
  segment '"agent_type":"main",' 2026-10-01T10:00:00Z 100000 1000
  segment '"agent_type":"code-audit-frontend","agent_id":"a1",' 2026-10-01T10:10:00Z 200000 2000
  segment '"agent_type":"code-audit-maintainer-shell","agent_id":"a2",' 2026-10-01T10:20:00Z 300000 3000
  segment '"agent_type":"general-purpose","agent_id":"a3",' 2026-10-01T10:30:00Z 400000 4000
  segment '"agent_type":"unknown","agent_id":"a4",' 2026-10-01T10:40:00Z 500000 5000
  segment '' 2026-10-01T09:50:00Z 600000 6000
}

@test "the audit line sums exactly the roster sidecars, right after the block's cost line, and the field-less segment is only counted" {
  local cost_line_number
  run run_usage pr --key branch:feat/audit --auditors code-audit-frontend,code-audit-maintainer-shell
  [ "$status" -eq 0 ]
  grep -qxF '  tokens: 2,121,000 (fresh 2,100,000, cache write 0, cache read 0, output 21,000)' <<<"$output" || { printf '%s\n' "$output" >&2; return 1; }
  cost_line_number="$(grep -nxF '  est. cost (USD): $4.41' <<<"$output" | cut -d: -f1)"
  [ -n "$cost_line_number" ]
  [ "${lines[$cost_line_number]}" = '  audit (Code Audit Team): tokens 505,000  est. cost (USD): $1.05' ]
  [ "${lines[$((cost_line_number + 1))]}" = '  ! lower bound: 1 segment(s) predate agent fields' ]
  [ "$(grep -c 'audit (Code Audit Team)' <<<"$output")" -eq 1 ]
}

@test "listing one more name adds only that agent type's spend" {
  run run_usage pr --key branch:feat/audit --auditors code-audit-frontend,code-audit-maintainer-shell,general-purpose
  [ "$status" -eq 0 ]
  grep -qxF '  audit (Code Audit Team): tokens 909,000  est. cost (USD): $1.89' <<<"$output"
}

@test "with every segment carrying agent fields, the lower-bound marker does not print" {
  grep -v '"agent_type"' "$TELEMETRY_DIRECTORY/usage.jsonl" >/dev/null
  grep '"agent_type"' "$TELEMETRY_DIRECTORY/usage.jsonl" >"$BATS_TEST_TMPDIR/fielded"
  cp "$BATS_TEST_TMPDIR/fielded" "$TELEMETRY_DIRECTORY/usage.jsonl"
  run run_usage pr --key branch:feat/audit --auditors code-audit-frontend
  [ "$status" -eq 0 ]
  grep -qxF '  audit (Code Audit Team): tokens 202,000  est. cost (USD): $0.42' <<<"$output"
  grep -qF 'predate agent fields' <<<"$output" && return 1
  true
}

@test "without --auditors neither the audit line nor its marker prints" {
  run run_usage pr --key branch:feat/audit
  [ "$status" -eq 0 ]
  grep -qxF '  est. cost (USD): $4.41' <<<"$output"
  grep -qF 'audit (Code Audit Team)' <<<"$output" && return 1
  grep -qF 'predate agent fields' <<<"$output" && return 1
  true
}

@test "an --auditors value outside the name grammar prints an error, exits 0, and prints no block" {
  local bad_value
  for bad_value in 'bad name' 'Code-Audit' 'a,,b' ',a' '-lead' 'a;b'; do
    run --separate-stderr run_usage pr --key branch:feat/audit --auditors "$bad_value"
    [ "$status" -eq 0 ] || { printf '%s exited %s\n' "$bad_value" "$status" >&2; return 1; }
    [ -z "$output" ] || { printf '%s printed:\n%s\n' "$bad_value" "$output" >&2; return 1; }
    [ "$stderr" = 'usage pr: --auditors takes comma-separated names of lowercase letters, digits and dashes' ]
  done
}
