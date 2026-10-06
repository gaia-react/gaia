#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-light-telemetry.sh, the maintainer-only
# evidence log for light-review routing: the append subcommands (route,
# outcome, member-result), their adopter gate and never-block contract, and the
# tally that reduces the log.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-light-telemetry.sh"
  WRITER="$REPO_ROOT/.gaia/scripts/audit-write-clearance.sh"
  DIGEST_SCRIPT="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  [ -f "$SCRIPT" ] || skip "audit-light-telemetry.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  MEMBER="code-audit-frontend"
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.gaia" "$ROOT/.claude/rules/maintainers"
  printf '1.6.1\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" init --quiet --initial-branch=feat/light-telemetry
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  echo "# readme" > "$ROOT/README.md"
  seed_audit_roster "$ROOT"
  git -C "$ROOT" add .gaia/audit-ci.yml .gaia/VERSION README.md
  git -C "$ROOT" commit --quiet -m "init"

  MAINTAINER_RULE="$ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  TELEMETRY_DIRECTORY="$ROOT/.gaia/local/telemetry"
  LOG="$TELEMETRY_DIRECTORY/audit-light-routing.jsonl"
  AUDIT_DIRECTORY="$ROOT/.gaia/local/audit"
  LIGHT_DIRECTORY="$AUDIT_DIRECTORY/light"
  mkdir -p "$LIGHT_DIRECTORY"

  TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  DIGEST="$(bash "$DIGEST_SCRIPT" --root "$ROOT" --member "$MEMBER")"
  . "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"
  SLUG="$(gaia_branch_slug "$ROOT")"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

enable_maintainer_repo() {
  printf '# maintainer rule\n' > "$MAINTAINER_RULE"
}

# write_route_record <path> <route> <reason> <post-ranges-json>
write_route_record() {
  local path="$1" route="$2" reason="$3" post_ranges="$4"
  jq -n -c --arg member "$MEMBER" --arg digest "$DIGEST" --arg tree "$TREE" \
    --arg route "$route" --arg reason "$reason" --argjson post_ranges "$post_ranges" '
    {schema: 1, member: $member, digest: $digest, tree: $tree, head_sha: "abc",
     route: $route, reason: $reason, anchor_sha: "feedface", anchor_tree: "cafe",
     cap: 50, lines: 12,
     files: [{path: "frontend/app/x.tsx", added: 3, deleted: 2, post_ranges: $post_ranges},
             {path: "frontend/app/y.tsx", added: 1, deleted: 1, post_ranges: [[1, 2]]}],
     hard_full_rule: null, routed_at: "2026-01-01T00:00:00Z"}' > "$path"
}

write_light_route_record() {
  write_route_record "$LIGHT_DIRECTORY/$DIGEST.$MEMBER.route.json" light light-eligible "${1:-[[10,14]]}"
}

# write_sidecar <findings-json> : a full-round findings sidecar for this branch
write_sidecar() {
  printf '{"schema":1,"member":"%s","findings":%s}\n' "$MEMBER" "$1" \
    > "$AUDIT_DIRECTORY/deadbeef.$SLUG.$MEMBER.findings.json"
}

run_route() {
  bash "$SCRIPT" route --root "$ROOT" --record "$LIGHT_DIRECTORY/$DIGEST.$MEMBER.route.json"
}

run_outcome() {
  bash "$SCRIPT" outcome --root "$ROOT" --member "$MEMBER" --digest "$DIGEST" --tree "$TREE" "$@"
}

run_member_result() {
  bash "$SCRIPT" member-result --root "$ROOT" --member "$MEMBER"
}

tally_value() {
  bash "$SCRIPT" tally --root "$ROOT" "${@:2}" | awk -F': ' -v key="$1" '$1 == key { print $2 }'
}

# ---------------------------------------------------------------------------
# route
# ---------------------------------------------------------------------------

@test "route appends one event carrying every routing field" {
  enable_maintainer_repo
  write_light_route_record
  run run_route
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
  event="$(cat "$LOG")"
  [ "$(jq -r '.event' <<<"$event")" = "route" ]
  [ "$(jq -r '.branch' <<<"$event")" = "$SLUG" ]
  [ "$(jq -r '.member' <<<"$event")" = "$MEMBER" ]
  [ "$(jq -r '.digest' <<<"$event")" = "$DIGEST" ]
  [ "$(jq -r '.tree' <<<"$event")" = "$TREE" ]
  [ "$(jq -r '.route' <<<"$event")" = "light" ]
  [ "$(jq -r '.reason' <<<"$event")" = "light-eligible" ]
  [ "$(jq -r '.lines' <<<"$event")" = "12" ]
  [ "$(jq -r '.files' <<<"$event")" = "2" ]
  [ "$(jq -r '.hard_full_rule' <<<"$event")" = "null" ]
  [ "$(jq -r '.cap' <<<"$event")" = "50" ]
  [ "$(jq -r '.anchor_sha' <<<"$event")" = "feedface" ]
  [ "$(jq -c '.ranges' <<<"$event")" = '[{"path":"frontend/app/x.tsx","post_ranges":[[10,14]]},{"path":"frontend/app/y.tsx","post_ranges":[[1,2]]}]' ]
  [ -n "$(jq -r '.at' <<<"$event")" ]
}

@test "route with an unparseable record exits 0 and writes nothing" {
  enable_maintainer_repo
  printf 'not json' > "$LIGHT_DIRECTORY/$DIGEST.$MEMBER.route.json"
  run run_route
  [ "$status" -eq 0 ]
  [ -e "$LOG" ] && return 1
  true
}

# ---------------------------------------------------------------------------
# outcome
# ---------------------------------------------------------------------------

@test "outcome copies route, reason, lines and file count from the route record" {
  enable_maintainer_repo
  write_light_route_record
  run run_outcome --verdict clear --tokens 123456 --duration-ms 9000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  event="$(cat "$LOG")"
  [ "$(jq -r '.event' <<<"$event")" = "light_outcome" ]
  [ "$(jq -r '.route' <<<"$event")" = "light" ]
  [ "$(jq -r '.reason' <<<"$event")" = "light-eligible" ]
  [ "$(jq -r '.lines' <<<"$event")" = "12" ]
  [ "$(jq -r '.files' <<<"$event")" = "2" ]
  [ "$(jq -r '.verdict' <<<"$event")" = "clear" ]
  [ "$(jq -r '.tokens' <<<"$event")" = "123456" ]
  [ "$(jq -r '.duration_ms' <<<"$event")" = "9000" ]
  [ "$(jq -r '.digest' <<<"$event")" = "$DIGEST" ]
  [ "$(jq -r '.tree' <<<"$event")" = "$TREE" ]
}

@test "outcome with no route record at the digest still appends, with the four copied fields null" {
  enable_maintainer_repo
  run run_outcome --verdict escalate
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
  event="$(cat "$LOG")"
  [ "$(jq -r '.route' <<<"$event")" = "null" ]
  [ "$(jq -r '.reason' <<<"$event")" = "null" ]
  [ "$(jq -r '.lines' <<<"$event")" = "null" ]
  [ "$(jq -r '.files' <<<"$event")" = "null" ]
  [ "$(jq -r '.tokens' <<<"$event")" = "null" ]
  [ "$(jq -r '.duration_ms' <<<"$event")" = "null" ]
  [ "$(jq -r '.verdict' <<<"$event")" = "escalate" ]
}

@test "outcome with an unparseable route record still appends, with the four copied fields null" {
  enable_maintainer_repo
  printf 'not json' > "$LIGHT_DIRECTORY/$DIGEST.$MEMBER.route.json"
  run run_outcome --verdict failed
  [ "$status" -eq 0 ]
  event="$(cat "$LOG")"
  [ "$(jq -r '.route' <<<"$event")" = "null" ]
  [ "$(jq -r '.files' <<<"$event")" = "null" ]
  [ "$(jq -r '.verdict' <<<"$event")" = "failed" ]
}

@test "outcome names a member that could climb out of the light directory: no record is read" {
  enable_maintainer_repo
  write_light_route_record
  run bash "$SCRIPT" outcome --root "$ROOT" --member "../audit/light/../$MEMBER" --digest "$DIGEST" --tree "$TREE" --verdict clear
  [ "$status" -eq 0 ]
  event="$(cat "$LOG")"
  [ "$(jq -r '.route' <<<"$event")" = "null" ]
}

@test "outcome refuses an unknown verdict: exit 0, nothing written" {
  enable_maintainer_repo
  run run_outcome --verdict maybe
  [ "$status" -eq 0 ]
  [ -e "$LOG" ] && return 1
  true
}

# ---------------------------------------------------------------------------
# member-result and the escalation follow-up
# ---------------------------------------------------------------------------

@test "member-result after an escalate with a refusal and two findings appends the result and a refused follow-up, and tally reports precision 1.00" {
  enable_maintainer_repo
  write_light_route_record
  run_route
  run_outcome --verdict escalate
  bash "$WRITER" --root "$ROOT" --member "$MEMBER" --provenance refused >/dev/null
  write_sidecar '[{"path":"frontend/app/x.tsx","line":12,"title":"a"},{"path":"frontend/app/y.tsx","line":1,"title":"b"}]'
  # A newer light sidecar must never be the one read.
  sleep 1
  printf '{"schema":1,"member":"%s","review":"light","findings":[1,2,3,4,5]}\n' "$MEMBER" \
    > "$AUDIT_DIRECTORY/deadbeef.$SLUG.$MEMBER.light.findings.json"
  run run_member_result
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  result_event="$(jq -c 'select(.event == "member_result")' "$LOG")"
  [ "$(jq -r '.result' <<<"$result_event")" = "refused" ]
  [ "$(jq -r '.findings' <<<"$result_event")" = "2" ]
  [ "$(jq -c '.locations' <<<"$result_event")" = '[{"path":"frontend/app/x.tsx","line":12},{"path":"frontend/app/y.tsx","line":1}]' ]
  [ "$(jq -r '.digest' <<<"$result_event")" = "$DIGEST" ]
  followup_event="$(jq -c 'select(.event == "escalation_followup")' "$LOG")"
  [ "$(jq -r '.result' <<<"$followup_event")" = "refused" ]
  [ "$(jq -r '.findings' <<<"$followup_event")" = "2" ]
  [ "$(jq -r '.route_digest' <<<"$followup_event")" = "$DIGEST" ]
  [ "$(tally_value escalation_precision)" = "1.00" ]
}

@test "member-result reports cleared for an earned marker and pending for none" {
  enable_maintainer_repo
  run_member_result
  [ "$(jq -r '.result' "$LOG")" = "pending" ]
  [ "$(jq -r '.findings' "$LOG")" = "0" ]
  bash "$WRITER" --root "$ROOT" --member "$MEMBER" --provenance earned --scope-digest "$DIGEST" >/dev/null
  run_member_result
  [ "$(tail -n 1 "$LOG" | jq -r '.result')" = "cleared" ]
}

@test "member-result writes no follow-up when the light outcome was clear" {
  enable_maintainer_repo
  write_light_route_record
  run_route
  run_outcome --verdict clear
  run_member_result
  [ "$(jq -r 'select(.event == "member_result") | .event' "$LOG")" = "member_result" ]
  followups="$(jq -r 'select(.event == "escalation_followup") | .event' "$LOG")"
  [ -z "$followups" ]
}

@test "member-result writes no follow-up when the newest route on this tree was full" {
  enable_maintainer_repo
  write_route_record "$LIGHT_DIRECTORY/$DIGEST.$MEMBER.route.json" full over-cap '[]'
  run_route
  run_outcome --verdict escalate
  run_member_result
  followups="$(jq -r 'select(.event == "escalation_followup") | .event' "$LOG")"
  [ -z "$followups" ]
}

# ---------------------------------------------------------------------------
# adopter gate and never-block
# ---------------------------------------------------------------------------

@test "without the maintainer rule file every append subcommand records nothing and creates no directory; with it the same calls write" {
  write_light_route_record
  run run_route
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run run_outcome --verdict clear
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run run_member_result
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -e "$LOG" ] && return 1
  [ -e "$TELEMETRY_DIRECTORY" ] && return 1
  # Positive control: the gate is the only thing that stopped the writes.
  enable_maintainer_repo
  run_route
  run_outcome --verdict clear
  run_member_result
  [ "$(wc -l < "$LOG" | tr -d ' ')" -ge 3 ]
}

@test "an unwritable telemetry directory: each append subcommand exits 0 with empty stdout and writes nothing; writable, the same calls write" {
  [ "$(id -u)" != "0" ] || skip "root ignores directory permissions"
  enable_maintainer_repo
  write_light_route_record
  mkdir -p "$TELEMETRY_DIRECTORY"
  chmod 0555 "$TELEMETRY_DIRECTORY"
  route_stdout="$(run_route 2>/dev/null)"; route_status=$?
  outcome_stdout="$(run_outcome --verdict clear 2>/dev/null)"; outcome_status=$?
  member_result_stdout="$(run_member_result 2>/dev/null)"; member_result_status=$?
  [ "$route_status" -eq 0 ]
  [ "$outcome_status" -eq 0 ]
  [ "$member_result_status" -eq 0 ]
  [ -z "$route_stdout" ]
  [ -z "$outcome_stdout" ]
  [ -z "$member_result_stdout" ]
  [ -e "$LOG" ] && return 1
  chmod 0755 "$TELEMETRY_DIRECTORY"
  run_route
  [ -s "$LOG" ]
}

# ---------------------------------------------------------------------------
# tally
# ---------------------------------------------------------------------------

@test "tally on an absent log exits 0 with zero counts and n/a ratios" {
  run bash "$SCRIPT" tally --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qxF 'rotations: 0' <<<"$output"
  grep -qxF 'light_routes: 0' <<<"$output"
  grep -qxF 'engagement_rate: n/a' <<<"$output"
  grep -qxF 'escalations: 0' <<<"$output"
  grep -qxF 'escalation_rate: n/a' <<<"$output"
  grep -qxF 'escalation_precision: n/a' <<<"$output"
  grep -qxF 'light_misses: 0' <<<"$output"
  grep -qxF 'light_median_tokens: n/a' <<<"$output"
  grep -qxF 'baseline_tokens: 3300000' <<<"$output"
  grep -qxF 'light_vs_baseline: n/a' <<<"$output"
}

@test "tally rejects a non-numeric baseline with exit 2" {
  run bash "$SCRIPT" tally --root "$ROOT" --baseline-tokens many
  [ "$status" -eq 2 ]
}

# write_route_events <reason> <count> : <count> route events with that reason
write_route_events() {
  local reason="$1" count="$2" index route="full"
  [ "$reason" = "light-eligible" ] && route="light"
  mkdir -p "$TELEMETRY_DIRECTORY"
  index=0
  while [ "$index" -lt "$count" ]; do
    jq -n -c --arg reason "$reason" --arg route "$route" \
      '{event: "route", branch: "b", member: "m", digest: "d", tree: "t", route: $route, reason: $reason}' >> "$LOG"
    index=$((index + 1))
  done
}

@test "engagement rate divides by post-clearance rotations only, and a scratch copy dividing by every route event fails the same fixture" {
  write_route_events light-eligible 2
  write_route_events over-cap 1
  write_route_events no-full-clearance 3
  write_route_events not-opted-in 2
  write_route_events no-version 1
  [ "$(tally_value rotations)" = "9" ]
  [ "$(tally_value light_routes)" = "2" ]
  [ "$(tally_value engagement_rate)" = "0.67" ]

  scratch="$BATS_TEST_TMPDIR/scratch-scripts"
  mkdir -p "$scratch"
  cp "$SCRIPT" "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$scratch/"
  sed 's/select((\.reason \/\/ "") | excluded_reason | not)/select(true)/' "$SCRIPT" > "$scratch/audit-light-telemetry.sh"
  cmp -s "$SCRIPT" "$scratch/audit-light-telemetry.sh" && return 1
  broken_rate="$(bash "$scratch/audit-light-telemetry.sh" tally --root "$ROOT" | awk -F': ' '$1 == "engagement_rate" { print $2 }')"
  [ "$broken_rate" = "0.22" ]
  [ "$broken_rate" != "$(tally_value engagement_rate)" ]
}

@test "tally reports escalation rate, median tokens and the baseline ratio, and skips a torn line" {
  mkdir -p "$TELEMETRY_DIRECTORY"
  for tokens in 100 200 300 400; do
    jq -n -c --argjson tokens "$tokens" '{event: "light_outcome", branch: "b", member: "m", digest: "d", verdict: "clear", tokens: $tokens}' >> "$LOG"
  done
  jq -n -c '{event: "light_outcome", branch: "b", member: "m", digest: "d", verdict: "escalate", tokens: null}' >> "$LOG"
  printf '{"event":"light_outcome","torn\n' >> "$LOG"
  [ "$(tally_value escalations)" = "1" ]
  [ "$(tally_value escalation_rate)" = "0.20" ]
  [ "$(tally_value light_median_tokens)" = "250" ]
  [ "$(tally_value light_vs_baseline --baseline-tokens 1000)" = "0.25" ]
}

# prepare_light_miss <finding-path> <finding-line>: a clear light review whose
# route covered frontend/app/x.tsx lines 10-14, then a full member result with
# one finding at the given location.
prepare_light_miss() {
  enable_maintainer_repo
  write_light_route_record '[[10,14]]'
  run_route
  run_outcome --verdict clear
  write_sidecar "[{\"path\":\"$1\",\"line\":$2,\"title\":\"t\"}]"
  run_member_result
}

@test "a full-member finding inside a range an earlier light clear covered is a light miss" {
  prepare_light_miss frontend/app/x.tsx 12
  [ "$(tally_value light_misses)" = "1" ]
}

@test "a finding outside the covered ranges is not a light miss" {
  prepare_light_miss frontend/app/x.tsx 40
  [ "$(tally_value light_misses)" = "0" ]
}

@test "a finding on a path the light review did not cover is not a light miss" {
  prepare_light_miss frontend/app/other.tsx 12
  [ "$(tally_value light_misses)" = "0" ]
}

@test "a finding before the light clear is not a light miss" {
  enable_maintainer_repo
  write_light_route_record '[[10,14]]'
  run_route
  write_sidecar '[{"path":"frontend/app/x.tsx","line":12,"title":"t"}]'
  run_member_result
  run_outcome --verdict clear
  [ "$(tally_value light_misses)" = "0" ]
}
