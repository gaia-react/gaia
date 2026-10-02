#!/usr/bin/env bats
#
# Read-time resolution for the usage ledger (SPEC-087): bindings, closed
# workflow intervals, inherit segments, the lineage edge set, merge windows,
# and the per-PR / initiative / reconcile figures `usage.sh` prints.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-resolve.bats
#
# Figures are compared with the hand-computed literals in
# fixtures/usage/resolve/golden.json, never with anything usage.sh computes.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  USAGE="$SCRIPTS/usage.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/resolve"
  GOLD="$FIXTURES_DIRECTORY/golden.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  make_repo "$MAIN" main
  register_hooks "$MAIN"
  mkdir -p "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT
  RATES="$FIXTURES_DIRECTORY/rates-a.json"
}

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

register_hooks() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
}

run_usage() { bash "$USAGE" "$@" --main-root "$MAIN" --rate-table "$RATES" --projects-root "$TEMPORARY_DIRECTORY/projects"; }

load_fixture() {
  local ledger_file
  for ledger_file in usage.jsonl links.jsonl cost.jsonl; do
    if [ -f "$FIXTURES_DIRECTORY/$1/$ledger_file" ]; then cp "$FIXTURES_DIRECTORY/$1/$ledger_file" "$TELEMETRY_DIRECTORY/$ledger_file"; fi
  done
}

# gold <scenario> <key> <field>
gold() { jq -er --arg scenario "$1" --arg scenario_key "$2" --arg field "$3" '.[$scenario][$scenario_key][$field]' "$GOLD"; }

# has_line <exact line>: fails the test when $output lacks it.
has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }

# is_prefix <before> <after>: <before>'s bytes open <after>. BSD cmp -n reports
# EOF on a file exactly n bytes long, so the prefix is cut with head -c instead.
is_prefix() { head -c "$(wc -c <"$1" | tr -d ' ')" "$2" | cmp -s - "$1"; }

total_line() { printf '  total (distinct segments): tokens %s  est. %s' "$(gold "$1" "$2" tokens)" "$(gold "$1" "$2" usd)"; }

@test "UAT-004: spend before the topic-b write resolves to topic-a, after it to topic-b, none unattributed; ledger untouched" {
  load_fixture research
  cp "$TELEMETRY_DIRECTORY/usage.jsonl" "$TEMPORARY_DIRECTORY/before"
  run run_usage initiative research:topic-a-2026-10-01
  [ "$status" -eq 0 ]
  has_line "$(total_line research research:topic-a-2026-10-01)"
  run run_usage initiative research:topic-b-2026-10-01
  has_line "$(total_line research research:topic-b-2026-10-01)"
  run run_usage reconcile
  has_line "  unattributed: tokens 0  est. \$0.00"
  has_line "  all segments: tokens $(gold research all tokens)  est. $(gold research all usd)"
  cmp "$TEMPORARY_DIRECTORY/before" "$TELEMETRY_DIRECTORY/usage.jsonl"
}

@test "UAT-005: a discussion-only session is all unattributed; attributed plus unattributed equals all" {
  load_fixture discussion
  run run_usage reconcile
  [ "$status" -eq 0 ]
  has_line "  attributed:   tokens 0  est. \$0.00"
  has_line "  unattributed: tokens $(gold discussion all tokens)  est. $(gold discussion all usd)"
  has_line "  all segments: tokens $(gold discussion all tokens)  est. $(gold discussion all usd)"
}

@test "UAT-006: an unclosed gaia-spec start binds nothing; once the spec row lands, [T0,T1] resolves to the SPEC" {
  load_fixture spec-interval
  cp "$TELEMETRY_DIRECTORY/usage.jsonl" "$TEMPORARY_DIRECTORY/before"
  run run_usage reconcile
  has_line "  unattributed: tokens $(gold spec-interval before_unattributed tokens)  est. $(gold spec-interval before_unattributed usd)"
  run run_usage initiative spec:SPEC-123
  has_line "  total (distinct segments): tokens 0  est. \$0.00"
  cat "$FIXTURES_DIRECTORY/spec-interval/spec-row.jsonl" >>"$TELEMETRY_DIRECTORY/cost.jsonl"
  run run_usage initiative spec:SPEC-123
  has_line "$(total_line spec-interval spec:SPEC-123)"
  run run_usage reconcile
  has_line "  unattributed: tokens $(gold spec-interval after_unattributed tokens)  est. $(gold spec-interval after_unattributed usd)"
  cmp "$TEMPORARY_DIRECTORY/before" "$TELEMETRY_DIRECTORY/usage.jsonl"
}

@test "UAT-017: a command interval on a feature branch leaves the PR figure; plan spend stays on the branch" {
  load_fixture command
  run run_usage pr --branch fix/other
  [ "$status" -eq 0 ]
  has_line "  tokens: $(gold command pr_fix_other tokens) (fresh 500,000, cache write 0, cache read 0, output 50,000)"
  has_line "  est. cost (USD): $(gold command pr_fix_other usd)"
  run run_usage initiative command:gaia-debt-20261001T110000Z-a1b2
  has_line "$(total_line command command:gaia-debt-20261001T110000Z-a1b2)"
}

@test "UAT-018: declare wins the same-instant tie; closed intervals take their span; later spend returns to topic-z" {
  load_fixture ordered
  local reference
  for reference in research:x research:topic-y research:topic-z plan:PLAN-022 spec:SPEC-091 \
    command:gaia-debt-20261001T143000Z-c3d4; do
    run run_usage initiative "$reference"
    [ "$status" -eq 0 ]
    has_line "$(total_line ordered "$reference")"
  done
  run run_usage reconcile
  has_line "  unattributed: tokens $(gold ordered unattributed tokens)  est. $(gold ordered unattributed usd)"
}

@test "UAT-008: a diamond counts each segment once; a shared PR appears in full under both roots; overlap note prints" {
  load_fixture diamond
  run run_usage initiative research:a
  has_line "$(total_line diamond research:a)"
  has_line "  note: initiative totals overlap; never sum them across roots"
  run run_usage initiative research:b
  has_line "$(total_line diamond research:b)"
  run run_usage initiative branch:feat/shared
  [ "$(grep -c '^\[initiative ' <<<"$output")" -eq 2 ]
  has_line "[initiative research:a]  coverage start: 2026-10-01"
  has_line "[initiative research:b]  coverage start: 2026-10-01"
  [ "$(grep -cxF -- "  branch:feat/shared  tokens $(gold diamond branch:feat/shared tokens)  est. $(gold diamond branch:feat/shared usd)  (explicit link)" <<<"$output")" -eq 2 ]
  [ "$(grep -cxF -- "  note: initiative totals overlap; never sum them across roots" <<<"$output")" -eq 2 ]
}

@test "UAT-009: linking an old branch pulls its past spend into the root; usage.jsonl untouched, links.jsonl only grows" {
  load_fixture prs
  printf '%s\n' '{"schema_version":1,"kind":"segment","key":"branch:feat/thing","session_id":"s09","inherit":false,"first_ts":"2026-09-10T09:00:00Z","last_ts":"2026-09-10T09:30:00Z","messages":4,"by_model":{"claude-opus-5-5":{"fresh_input":500000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":50000}}}' >>"$TELEMETRY_DIRECTORY/usage.jsonl"
  cp "$TELEMETRY_DIRECTORY/usage.jsonl" "$TEMPORARY_DIRECTORY/u-before"
  cp "$TELEMETRY_DIRECTORY/links.jsonl" "$TEMPORARY_DIRECTORY/l-before"
  run run_usage initiative research:topic-a-2026-10-01
  has_line "  total (distinct segments): tokens $(gold prs 501 tokens)  est. $(gold prs 501 usd_a)"
  run run_usage link branch:feat/thing research:topic-a-2026-10-01
  [ "$status" -eq 0 ]
  run run_usage initiative research:topic-a-2026-10-01
  # 1,430,000 (prs PR 501) + 550,000 (the unit-5 feat/thing segment) = 1,980,000; $1.35 + $1.50
  has_line "  total (distinct segments): tokens 1,980,000  est. \$2.85"
  has_line "  branch:feat/thing  tokens 550,000  est. \$1.50  (explicit link)"
  cmp "$TEMPORARY_DIRECTORY/u-before" "$TELEMETRY_DIRECTORY/usage.jsonl"
  is_prefix "$TEMPORARY_DIRECTORY/l-before" "$TELEMETRY_DIRECTORY/links.jsonl"
  [ "$(wc -c <"$TELEMETRY_DIRECTORY/links.jsonl")" -gt "$(wc -c <"$TEMPORARY_DIRECTORY/l-before")" ]
}

@test "UAT-022: unlink removes an explicit edge's spend from the root; a tombstone also kills a derived edge" {
  load_fixture prs
  printf '%s\n' '{"schema_version":1,"kind":"segment","key":"branch:feat/thing","session_id":"s22","inherit":false,"first_ts":"2026-09-10T09:00:00Z","last_ts":"2026-09-10T09:30:00Z","messages":4,"by_model":{"claude-opus-5-5":{"fresh_input":500000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":50000}}}' >>"$TELEMETRY_DIRECTORY/usage.jsonl"
  run run_usage link branch:feat/thing research:topic-a-2026-10-01
  run run_usage initiative research:topic-a-2026-10-01
  has_line "  branch:feat/thing  tokens 550,000  est. \$1.50  (explicit link)"
  cp "$TELEMETRY_DIRECTORY/links.jsonl" "$TEMPORARY_DIRECTORY/l-before"
  run run_usage unlink branch:feat/thing research:topic-a-2026-10-01
  [ "$status" -eq 0 ]
  run run_usage initiative research:topic-a-2026-10-01
  grep -qF 'branch:feat/thing' <<<"$output" && return 1
  has_line "  total (distinct segments): tokens $(gold prs 501 tokens)  est. $(gold prs 501 usd_a)"
  is_prefix "$TEMPORARY_DIRECTORY/l-before" "$TELEMETRY_DIRECTORY/links.jsonl"
  run run_usage initiative issue:200
  has_line "  branch:debt/200-x  tokens $(gold prs 502 tokens)  est. $(gold prs 502 usd_a)"
  run run_usage unlink branch:debt/200-x issue:200
  [ "$status" -eq 0 ]
  run run_usage initiative issue:200
  grep -qF 'branch:debt/200-x' <<<"$output" && return 1
  has_line "  total (distinct segments): tokens 0  est. \$0.00"
}

@test "UAT-023: lineage edges outlive the SPEC file; the root still includes the SPEC's and its branch's spend" {
  load_fixture lineage
  mkdir -p "$TEMPORARY_DIRECTORY/spec"
  printf '%s\n' '---' 'spec_id: SPEC-090' 'type: feature' 'lineage: [research:topic-a-2026-10-01]' 'intent: |' '  x' '---' '# body' >"$TEMPORARY_DIRECTORY/spec/SPEC.md"
  run run_usage lineage "$TEMPORARY_DIRECTORY/spec/SPEC.md"
  [ "$status" -eq 0 ]
  jq -e -s 'length == 1 and .[0].kind == "edge" and .[0].child == "spec:SPEC-090"
    and .[0].parent == "research:topic-a-2026-10-01" and .[0].source == "spec-frontmatter"' "$TELEMETRY_DIRECTORY/links.jsonl"
  rm -rf "$TEMPORARY_DIRECTORY/spec"
  run run_usage initiative research:topic-a-2026-10-01
  has_line "$(total_line lineage research:topic-a-2026-10-01)"
}

@test "UAT-023: block-form lineage writes each valid entry, skips an invalid one, and never repeats a live pair" {
  mkdir -p "$TEMPORARY_DIRECTORY/spec"
  printf '%s\n' '---' 'spec_id: SPEC-091' 'lineage:' '  - research:r1' '  - "issue:12"' '  - not-a-ref' 'intent: x' '---' >"$TEMPORARY_DIRECTORY/spec/SPEC.md"
  run run_usage lineage "$TEMPORARY_DIRECTORY/spec/SPEC.md"
  [ "$status" -eq 0 ]
  [ "$(jq -sc '[.[] | [.child, .parent]]' "$TELEMETRY_DIRECTORY/links.jsonl")" = '[["spec:SPEC-091","research:r1"],["spec:SPEC-091","issue:12"]]' ]
  run run_usage lineage "$TEMPORARY_DIRECTORY/spec/SPEC.md"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TELEMETRY_DIRECTORY/links.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "UAT-021: each merge's window holds only the spend since the previous merge of the same key" {
  load_fixture window
  run run_usage pr 602
  has_line "[PR cost] pr:602 branch:fix/foo"
  has_line "  tokens: $(gold window 602 tokens) (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  has_line "  est. cost (USD): $(gold window 602 usd)"
  has_line "  window: after 2026-10-05T00:00:00Z through 2026-10-10T00:00:00Z"
  run run_usage pr 601
  has_line "  tokens: $(gold window 601 tokens) (fresh 300,000, cache write 0, cache read 0, output 30,000)"
  has_line "  est. cost (USD): $(gold window 601 usd)"
  has_line "  window: after start of record through 2026-10-05T00:00:00Z"
}

@test "UAT-007: per-PR blocks equal golden; roots print for the SPEC and debt branches only; a rate swap reprices" {
  load_fixture prs
  cp "$TELEMETRY_DIRECTORY/usage.jsonl" "$TEMPORARY_DIRECTORY/before"
  run run_usage pr 501
  has_line "[PR cost] pr:501 branch:plan/spec-090-foo"
  has_line "  tokens: $(gold prs 501 tokens) (fresh $(gold prs 501 fresh), cache write $(gold prs 501 cw), cache read $(gold prs 501 cr), output $(gold prs 501 out))"
  has_line "  est. cost (USD): $(gold prs 501 usd_a)"
  has_line "  sessions: 2  span: 2026-09-20..2026-09-21  coverage start: 2026-09-20"
  has_line "  ! lower bound: branch spend may predate coverage start"
  has_line "[initiative research:topic-a-2026-10-01 to date; initiative totals overlap, never sum them across roots]"
  has_line "  tokens: $(gold prs 501 tokens)  est. cost (USD): $(gold prs 501 usd_a)"
  [ "$(grep -c '^\[initiative ' <<<"$output")" -eq 1 ]
  run run_usage pr 502
  has_line "  tokens: $(gold prs 502 tokens) (fresh 300,000, cache write 0, cache read 0, output 30,000)"
  has_line "[initiative issue:200 to date; initiative totals overlap, never sum them across roots]"
  has_line "  tokens: $(gold prs 502 tokens)  est. cost (USD): $(gold prs 502 usd_a)"
  run run_usage pr 503
  has_line "  tokens: $(gold prs 503 tokens) (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  has_line "  est. cost (USD): $(gold prs 503 usd_a)"
  grep -q '^\[initiative ' <<<"$output" && return 1
  grep -qF 'lower bound' <<<"$output" && return 1
  RATES="$FIXTURES_DIRECTORY/rates-b.json"
  run run_usage pr 501
  has_line "  est. cost (USD): $(gold prs 501 usd_b)"
  cmp "$TEMPORARY_DIRECTORY/before" "$TELEMETRY_DIRECTORY/usage.jsonl"
}

@test "UAT-024 / RT-012: master and HEAD spend resolves through bindings; an inherit segment takes the prior main key" {
  rm -rf "$MAIN"
  make_repo "$MAIN" master
  git -C "$MAIN" update-ref refs/remotes/origin/master HEAD
  git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  register_hooks "$MAIN"
  mkdir -p "$TELEMETRY_DIRECTORY"
  load_fixture inherit
  run run_usage pr --branch feat/agent
  has_line "  tokens: $(gold inherit branch:feat/agent tokens) (fresh 600,000, cache write 0, cache read 0, output 60,000)"
  has_line "  est. cost (USD): $(gold inherit branch:feat/agent usd)"
  run run_usage initiative research:r24
  has_line "$(total_line inherit research:r24)"
  run run_usage reconcile
  has_line "  unattributed: tokens 0  est. \$0.00"
  run run_usage link --pr 7 --branch master
  [ "$status" -eq 0 ]
  [ ! -e "$TELEMETRY_DIRECTORY/links.jsonl" ]
}

@test "SEC-009: a link row records its session and sidechain flag; the readout marks the node it reaches" {
  load_fixture diamond
  : >"$TELEMETRY_DIRECTORY/links.jsonl"
  CLAUDE_CODE_SESSION_ID=sess-env run run_usage link branch:feat/p1 research:c
  CLAUDE_CODE_SESSION_ID=sess-env run run_usage link branch:feat/p2 research:c --session sess-flag --sidechain
  [ "$(jq -sc '[.[] | [.session_id, .sidechain]]' "$TELEMETRY_DIRECTORY/links.jsonl")" = '[["sess-env",false],["sess-flag",true]]' ]
  run run_usage initiative research:c
  has_line "  branch:feat/p1  tokens 440,000  est. \$1.20  (explicit link)"
  has_line "  branch:feat/p2  tokens 550,000  est. \$1.50  (explicit link)"
}

# edges: the live edge set for the telemetry stores, one "child parent" per line.
edges() {
  touch "$TELEMETRY_DIRECTORY/usage.jsonl" "$TELEMETRY_DIRECTORY/links.jsonl" "$TELEMETRY_DIRECTORY/cost.jsonl"
  # shellcheck disable=SC2016
  bash -c 'source "$1/usage-lib.sh" && source "$1/usage-resolve-lib.sh" || exit 9
    keys_json="$(gaia_usage_keys_json "$2" "$3/usage.jsonl" "$3/links.jsonl" "$3/cost.jsonl")" || exit 8
    jq -nr --rawfile links_store "$3/links.jsonl" --rawfile cost_store "$3/cost.jsonl" --argjson keys "$keys_json" \
      "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"" usage_edges(usage_rows(\$links_store); usage_rows(\$cost_store); \$keys)[] | \"\(.child) \(.parent)\""' \
    _ "$SCRIPTS" "$MAIN" "$TELEMETRY_DIRECTORY"
}

@test "derived edges: branch names, plan/execute rows off the default branch, command PRs; never the plans ledger" {
  local branch_name
  for branch_name in plan/spec-090-foo spec-084-x fix/2149-y debt/41-42-batch plan/plan-7-z; do
    printf '{"schema_version":1,"kind":"segment","key":"branch:%s","session_id":"d","inherit":false,"first_ts":"2026-10-01T00:00:00Z","last_ts":"2026-10-01T00:00:00Z","messages":1,"by_model":{}}\n' "$branch_name" >>"$TELEMETRY_DIRECTORY/usage.jsonl"
  done
  printf '%s\n' \
    '{"schema_version":1,"kind":"plan","session_id":"d","ts":"2026-10-01T00:00:00Z","spec_id":"SPEC-091","plan_id":null,"git_branch":"feat/x"}' \
    '{"schema_version":1,"kind":"execute","session_id":"d","ts":"2026-10-01T00:00:00Z","spec_id":null,"plan_id":"PLAN-092","git_branch":"worktree-feat+y"}' \
    '{"schema_version":1,"kind":"plan","session_id":"d","ts":"2026-10-01T00:00:00Z","spec_id":"SPEC-093","plan_id":null,"git_branch":"main"}' \
    '{"schema_version":1,"kind":"command","session_id":"d","ts":"2026-10-01T00:00:00Z","spec_id":null,"plan_id":null,"command":"gaia-debt","run_id":"gaia-debt-r1","github":{"type":"pr","number":77,"repo":"o/r"}}' \
    >"$TELEMETRY_DIRECTORY/cost.jsonl"
  mkdir -p "$MAIN/.gaia/local/plans"
  printf '%s\n' '{"plans":[{"plan_id":"PLAN-777","branch":"feat/x","spec_id":"SPEC-778"}]}' >"$MAIN/.gaia/local/plans/ledger.json"
  run edges
  [ "$status" -eq 0 ]
  has_line "branch:plan/spec-090-foo spec:SPEC-090"
  has_line "branch:spec-084-x spec:SPEC-084"
  has_line "branch:fix/2149-y issue:2149"
  has_line "branch:debt/41-42-batch issue:41"
  has_line "branch:debt/41-42-batch issue:42"
  has_line "branch:plan/plan-7-z plan:PLAN-007"
  has_line "branch:feat/x spec:SPEC-091"
  has_line "branch:feat/y plan:PLAN-092"
  has_line "pr:77 command:gaia-debt-r1"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 9 ]
  grep -qE 'spec:SPEC-90( |$)' <<<"$output" && return 1
  grep -qE 'SPEC-093|PLAN-777|SPEC-778' <<<"$output" && return 1
  true
}

# derive <branch-ref>...: gaia_usage_derive_map over the refs, run from a clean
# shell, keys sorted so the literal below compares byte for byte.
derive() {
  # shellcheck disable=SC2016
  bash -c 'source "$1/usage-lib.sh" && source "$1/usage-resolve-lib.sh" || exit 9
    shift; gaia_usage_derive_map "$@" | jq -cS .' _ "$SCRIPTS" "$@"
}

@test "derived edges in one batch: each branch gets only its own parents, whatever came before it" {
  run derive branch:debt/41-42-batch branch:debt/7-x branch:fix/foo branch:plan/spec-7 branch:feat/x \
    branch:spec-9-y branch:chore/12-z branch:plan/plan-5-q branch:debt/8 'branch:%0123456789abcdef' session:s
  [ "$status" -eq 0 ]
  [ "$output" = '{"branch:chore/12-z":["issue:12"],"branch:debt/41-42-batch":["issue:41","issue:42"],"branch:debt/7-x":["issue:7"],"branch:debt/8":["issue:8"],"branch:plan/plan-5-q":["plan:PLAN-005"],"branch:plan/spec-7":["spec:SPEC-007"],"branch:spec-9-y":["spec:SPEC-009"]}' ]
}
