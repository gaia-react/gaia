#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/usage-merge.sh, the per-PR cost block printed at
# every `gh pr merge` (run through the real token-rollup-merge.sh hook, which
# is what calls it). Covers SPEC-087 UAT-007, UAT-016, UAT-021 and the merge
# hook's resolution, confirmation, and no-new-host contracts.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/usage-merge.bats
#
# Every test builds a tmp git repo holding copies of the hook and the usage
# scripts at their repo-relative paths, a `gh` stub on PATH that answers
# `pr view` from a per-test JSON file and logs its argv, and a rate table
# copied in as the distributed source (input $2/M, output $10/M, 5m cache write
# 1.25x input, cache read 0.1x input). Spend literals below were added up by
# hand from the seeded segment rows; nothing here calls the flusher's or the
# resolver's own arithmetic to produce an expected value.
#
# MEASUREMENTS (maintainer machine, Apple Silicon macOS, bash 5.3):
#   Synchronous flush, `usage-flush.sh --session <sid> --finished-main
#   --telemetry-dir <empty scratch>`, over the 30 most recent real sessions
#   (main file plus sidecars, cold: no cursors): p50 0.40 s, p90 2.20 s, max
#   5.37 s against the 5 s cap. The two heaviest sessions (1.9 to 2.1 MB main,
#   33 to 37 sidecars) sit at the cap; a session whose cursors are already
#   warm re-flushes in 0.09 to 0.35 s, which is the usual case once the Stop
#   capture hook has run.
#   Rendered block: 488 characters (about 122 tokens) for a spec branch with one
#   initiative root, one per merged PR, plus about 100 characters per marker.
#   Readout budget: `usage.sh pr <N>`, median of 5 (3 for the slowest points
#   before), over synthesized stores at the flusher's measured rate of about
#   8,000 usage.jsonl rows a month (4,191 segments, 625 bindings, 3,155
#   cursors) and 60 merged PRs a month in links.jsonl, in two shapes.
#   Pessimistic: keys drawn from a fixed pool of 660 branches or a random
#   session, 3,000 random sessions. Realistic: about 150 new branch keys and
#   700 new sessions a month, with start bindings closed by cost rows and some
#   inherit segments. Before the batching fix (a subshell per branch name in
#   the key pass, and a scan of every interval, binding, and segment per
#   segment in the resolver):
#     pessimistic 1 month 3.9 s, 6 months 16.9 s, 12 months 51.8 s;
#     realistic 1 month 2.8 s, 6 months 50.7 s, 12 months 182.6 s.
#   After (byte-identical blocks at every point):
#     pessimistic 1 month 0.55 s, 6 months 1.59 s, 12 months 2.88 s;
#     realistic 1 month 0.49 s, 6 months 1.97 s, 12 months 3.91 s.
#   Growth is now linear. The remaining floor at 12 months is two full parses
#   of a 25 MB ledger (the branch-key pass, then the view) plus per-segment
#   epoch and resolution work, so the render is also bounded in the hook by
#   GAIA_USAGE_RENDER_CAP_SECS (default 10).

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state" GAIA_RATES_FEED_DISABLE=1
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECS GAIA_USAGE_MERGE_CAP_SECS GAIA_USAGE_RENDER_CAP_SECS
  export GAIA_LEDGER_LOCK_POLL_SECS=0.1
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  GHSTUB_DIR="$TMP/ghstub"
  mkdir -p "$GHSTUB_DIR" "$TMP/bin"
  export GHSTUB_DIR
  make_stubs
  export PATH="$TMP/bin:$PATH"
  build_repo
}

seed_uat007() {
  {
    seg branch:plan/spec-090-foo s71 2026-09-20T09:00:00Z 100000 10000 | jq -c '.by_model[].cache_write_5m = 100000 | .by_model[].cache_read = 1000000'
    seg branch:debt/200-x s73 2026-09-22T09:00:00Z 300000 30000
    seg branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
  } >"$TD/usage.jsonl"
  printf '%s\n' '{"schema_version":1,"kind":"edge","child":"spec:SPEC-090","parent":"research:topic-a","source":"spec-frontmatter","ts":"2026-10-01T00:00:00Z","session_id":null,"sidechain":false}' >"$TD/links.jsonl"
}

assert_gh_only_pr_view() {
  [ -f "$GHSTUB_DIR/argv.log" ]
  local bad
  bad="$(grep -vc '^pr view' "$GHSTUB_DIR/argv.log" || true)"
  [ "$bad" = 0 ]
  [ ! -e "$GHSTUB_DIR/net.log" ]
}

# ---------- 1. the per-PR block through the hook ----------

@test "gh pr merge 101/102/103 print each branch's golden tokens and dollars, the right initiative line, and one merge row each" {
  seed_uat007
  gh_view 101 101 plan/spec-090-foo MERGED 2026-09-25T00:00:00Z
  gh_view 102 102 debt/200-x MERGED 2026-09-25T01:00:00Z
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z

  run_merge "gh pr merge 101 --squash"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:plan/spec-090-foo"
  has_line "  tokens: 1,210,000 (fresh 100,000, cache write 100,000, cache read 1,000,000, output 10,000)"
  has_line "  est. cost (USD): \$0.75"
  has_line "[initiative research:topic-a to date; initiative totals overlap, never sum them across roots]"
  has_line "  tokens: 1,210,000  est. cost (USD): \$0.75"
  lacks "merge not confirmed"

  run_merge "gh pr merge 102"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:102 branch:debt/200-x"
  has_line "  tokens: 330,000 (fresh 300,000, cache write 0, cache read 0, output 30,000)"
  has_line "  est. cost (USD): \$0.90"
  has_line "[initiative issue:200 to date; initiative totals overlap, never sum them across roots]"
  lacks "research:topic-a"

  run_merge "gh pr merge 103"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:103 branch:fix/foo"
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  has_line "  est. cost (USD): \$1.20"
  lacks "[initiative "

  [ "$(jq -s '[.[] | select(.kind == "merge")] | length' "$TD/links.jsonl")" -eq 3 ]
  jq -e -s '[.[] | select(.kind == "merge")] | .[0].pr == 101 and .[0].key == "branch:plan/spec-090-foo"
    and .[0].merged_at == "2026-09-25T00:00:00Z" and .[0].source == "gh-pr-merge"
    and .[1].key == "branch:debt/200-x" and .[2].key == "branch:fix/foo"' "$TD/links.jsonl"
  assert_gh_only_pr_view
}

# ---------- 2. branch resolution order ----------

@test "gh failing: the pr:<N> edge from creation supplies the branch key; no edge reads unresolved; usage-merge.sh never opens the ledger file itself" {
  seed_uat007
  printf '%s\n' '{"schema_version":1,"kind":"edge","child":"pr:104","parent":"branch:fix/foo","source":"gh-pr-create","ts":"2026-09-24T00:00:00Z","session_id":null,"sidechain":false}' >>"$TD/links.jsonl"
  [ "$(grep -c 'links.jsonl' "$REPO/.gaia/scripts/usage-merge.sh" || true)" = 0 ]

  run_merge "gh pr merge 104"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:104 branch:fix/foo"
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  grep -qF 'merge not confirmed; boundary not recorded (record it: bash .gaia/scripts/usage.sh link --merge 104 --key branch:fix/foo)' <<<"$output"
  [ "$(merge_rows 104)" -eq 0 ]

  run_merge "gh pr merge 105"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:105 (branch unresolved)"
  lacks "tokens:"
}

@test "no operand on worktree-fix+bar with gh failing: the current branch names the block, not confirmed" {
  git -C "$REPO" checkout -q -b worktree-fix+bar
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:? branch:fix/bar"
  grep -qF 'merge not confirmed; boundary not recorded (record it: bash .gaia/scripts/usage.sh link --merge <N> --branch worktree-fix+bar)' <<<"$output"
}

@test "no operand, on the default branch, gh failing: the single unresolved line" {
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  [ "$output" = "[PR cost] unresolved: no PR number or branch" ]
}

@test "a hostile headRefName creates no file and renders a hashed branch key" {
  gh_view 107 107 'x$(touch pwn)' MERGED 2026-09-25T00:00:00Z
  run_merge "gh pr merge 107"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/pwn" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwn" ]
  grep -Eq '^\[PR cost\] pr:107 branch:%[0-9a-f]{16}$' <<<"$output"
  [ "$(jq -s '[.[] | select(.kind == "merge")] | .[0].key | test("^branch:%[0-9a-f]{16}$")' "$TD/links.jsonl")" = true ]
}

# ---------- 3. confirmation: only MERGED writes the boundary ----------

@test "an OPEN PR writes no merge row and names the recovery command; the MERGED retry writes exactly one" {
  seed_uat007
  cp "$TD/links.jsonl" "$TMP/links-before"
  gh_view 105 105 fix/foo OPEN ""
  run_merge "gh pr merge 105 --auto"
  [ "$status" -eq 0 ]
  grep -qF 'merge not confirmed; boundary not recorded (record it: bash .gaia/scripts/usage.sh link --merge 105 --branch fix/foo)' <<<"$output"
  cmp "$TMP/links-before" "$TD/links.jsonl"

  gh_view 105 105 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 105"
  [ "$status" -eq 0 ]
  lacks "merge not confirmed"
  [ "$(merge_rows 105)" -eq 1 ]
}

@test "guards-must-fail: a copy of usage-merge.sh that skips the MERGED check writes a row for an OPEN PR" {
  seed_uat007
  gh_view 105 105 fix/foo OPEN ""
  sed 's/\[ "\$g_state" = MERGED \]/true/' "$REPO/.gaia/scripts/usage-merge.sh" >"$REPO/.gaia/scripts/usage-merge-mutant.sh"
  cmp -s "$REPO/.gaia/scripts/usage-merge.sh" "$REPO/.gaia/scripts/usage-merge-mutant.sh" && return 1
  run_script "$REPO/.gaia/scripts/usage-merge-mutant.sh" "gh pr merge 105 --auto"
  [ "$status" -eq 0 ]
  [ "$(merge_rows 105)" -eq 1 ]
}

# ---------- 4. the cap ----------

seed_unflushed() {
  local t
  t="$PROJ/$(enc "$REPO")/s-un.jsonl"
  {
    jq -nc --arg r "$REPO" '{type:"user",uuid:"u1",timestamp:"2026-10-01T00:00:00.000Z",cwd:$r,sessionId:"s-un",gitBranch:"fix/unfl",message:{role:"user",content:"go"}}'
    jq -nc --arg r "$REPO" '{type:"assistant",uuid:"a1",timestamp:"2026-10-01T00:00:01.000Z",cwd:$r,sessionId:"s-un",gitBranch:"fix/unfl",
      message:{id:"m1",model:"claude-opus-5-5",role:"assistant",usage:{input_tokens:1000,cache_creation_input_tokens:0,cache_read_input_tokens:0,output_tokens:500,cache_creation:{ephemeral_5m_input_tokens:0,ephemeral_1h_input_tokens:0}},content:[{type:"text",text:"ok"}]}}'
  } >"$t"
  touch -t 202001010000 "$t"
  gh_view 106 106 fix/unfl MERGED 2026-10-02T00:00:00Z
}

@test "the cap: a held ledger lock still returns within cap plus 3 s, marks the partial flush and the unconfirmed merge, and writes nothing" {
  seed_unflushed
  export GAIA_USAGE_MERGE_CAP_SECS=1 GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECS=6
  mkdir "$TD/specs.lock.d"
  local t0 t1
  t0="$(date +%s)"
  run_merge "gh pr merge 106" s-un
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -le 4 ]
  has_line "  ! partial: flush incomplete"
  grep -qF '! merge not confirmed; boundary not recorded' <<<"$output"
  [ ! -s "$TD/links.jsonl" ]
  rmdir "$TD/specs.lock.d"
}

@test "guards-must-fail: a copy of usage-merge.sh without the lock-timeout bound overruns cap plus 3 s" {
  seed_unflushed
  export GAIA_USAGE_MERGE_CAP_SECS=1 GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECS=6
  sed 's/GAIA_LEDGER_LOCK_TIMEOUT_SECS="\$(_um_left)" //' "$REPO/.gaia/scripts/usage-merge.sh" >"$REPO/.gaia/scripts/usage-merge-mutant.sh"
  cmp -s "$REPO/.gaia/scripts/usage-merge.sh" "$REPO/.gaia/scripts/usage-merge-mutant.sh" && return 1
  mkdir "$TD/specs.lock.d"
  local t0 t1
  t0="$(date +%s)"
  run_script "$REPO/.gaia/scripts/usage-merge-mutant.sh" "gh pr merge 106" s-un
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -gt 4 ]
  rmdir "$TD/specs.lock.d"
}

@test "the cap, control: a free lock flushes synchronously, so the unflushed spend is in the block with no partial marker" {
  seed_unflushed
  export GAIA_USAGE_MERGE_CAP_SECS=5
  run_merge "gh pr merge 106" s-un
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:106 branch:fix/unfl"
  has_line "  tokens: 1,500 (fresh 1,000, cache write 0, cache read 0, output 500)"
  lacks "partial: flush incomplete"
  lacks "merge not confirmed"
  lacks "unflushed:"
  [ "$(merge_rows 106)" -eq 1 ]
}

@test "a hung gh read is killed at the cap and treated as unavailable" {
  seed_uat007
  printf '30' >"$GHSTUB_DIR/sleep"
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  export GAIA_USAGE_MERGE_CAP_SECS=1
  local t0 t1
  t0="$(date +%s)"
  run_merge "gh pr merge 103"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -le 4 ]
  has_line "[PR cost] pr:103 (branch unresolved)"
  grep -qF '! merge not confirmed' <<<"$output"
  [ "$(merge_rows 103)" -eq 0 ]
}

# ---------- 4b. the render cap ----------

# slow_render <secs>: usage.sh becomes a stand-in whose `pr` readout sleeps
# <secs> before printing; every other subcommand runs the real script.
slow_render() {
  mv "$REPO/.gaia/scripts/usage.sh" "$REPO/.gaia/scripts/usage-real.sh"
  printf '#!/usr/bin/env bash\nif [ "${1-}" = pr ]; then sleep %s; printf "[PR cost] late\\n"; exit 0; fi\nexec bash "${BASH_SOURCE[0]%%/*}/usage-real.sh" "$@"\n' \
    "$1" >"$REPO/.gaia/scripts/usage.sh"
}

# seed_rollup: an active plan on the current branch with one execute record,
# so token-rollup-merge.sh prints its cycle roll-up after the block.
seed_rollup() {
  local plan="$REPO/.gaia/local/plans/my-plan"
  mkdir -p "$plan"
  printf '# Plan\n\n## Source SPEC\n\nDerived from SPEC-042 (/abs/root/.gaia/local/specs/SPEC-042/SPEC.md).\n' >"$plan/README.md"
  printf 'branch: main\nslug: my-plan\nstarted: 2026-07-01T00:00:00Z\n' >"$plan/RUNNING"
  jq -nc '{kind:"execute", spec_id:"SPEC-042", plan_slug:"my-plan", session_id:"sess-a",
    buckets:{fresh_input:300, cache_write:0, cache_read:0, output:0}, total:300, partial:false,
    started_at:"2026-06-01T00:00:00Z", ended_at:"2026-06-01T00:00:00Z", duration_seconds:10,
    duration_available:true, ts:"2026-06-01T00:00:00Z"}' >>"$TD/cost.jsonl"
}

@test "the render cap: a render past the cap is killed, one timed-out line replaces the block, and the roll-up still prints" {
  seed_uat007
  seed_rollup
  slow_render 8
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  export GAIA_USAGE_RENDER_CAP_SECS=1
  local t0 t1
  t0="$(date +%s)"
  run_merge "gh pr merge 103"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -le 4 ]
  has_line "! readout timed out after 1s; rerun: bash .gaia/scripts/usage.sh pr 103"
  [ "$(grep -c 'readout timed out' <<<"$output")" -eq 1 ]
  lacks "[PR cost]"
  has_line "[cycle cost at merge]"
  grep -qF "Cycle cost (SPEC-042)" <<<"$output"
  [ "$(merge_rows 103)" -eq 1 ]
}

@test "the render cap, numberless: the rerun line names the branch the block would have used" {
  git -C "$REPO" checkout -q -b worktree-fix+bar
  slow_render 8
  export GAIA_USAGE_RENDER_CAP_SECS=1
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  [ "$output" = "! readout timed out after 1s; rerun: bash .gaia/scripts/usage.sh pr --branch worktree-fix+bar" ]
}

@test "guards-must-fail: a copy of usage-merge.sh without the render watchdog overruns cap plus 3 s" {
  seed_uat007
  slow_render 8
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  export GAIA_USAGE_RENDER_CAP_SECS=1
  sed '/_um_expired "\$rcap" && break/d' "$REPO/.gaia/scripts/usage-merge.sh" >"$REPO/.gaia/scripts/usage-merge-mutant.sh"
  cmp -s "$REPO/.gaia/scripts/usage-merge.sh" "$REPO/.gaia/scripts/usage-merge-mutant.sh" && return 1
  local t0 t1
  t0="$(date +%s)"
  run_script "$REPO/.gaia/scripts/usage-merge-mutant.sh" "gh pr merge 103"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$((t1 - t0))" -gt 4 ]
  has_line "[PR cost] late"
}

@test "the render cap, control: a render inside the cap prints the block and no timed-out line" {
  seed_uat007
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  export GAIA_USAGE_RENDER_CAP_SECS=5
  run_merge "gh pr merge 103"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:103 branch:fix/foo"
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  lacks "readout timed out"
}

# ---------- 5. a reused branch ----------

@test "two merges from a reused branch write two rows and each block counts only its own window" {
  {
    seg branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
    seg branch:fix/foo s75 2026-09-25T09:00:00Z 100000 10000
  } >"$TD/usage.jsonl"
  gh_view 601 601 fix/foo MERGED 2026-09-24T00:00:00Z
  gh_view 602 602 fix/foo MERGED 2026-09-26T00:00:00Z

  run_merge "gh pr merge 601"
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  run_merge "gh pr merge 602"
  has_line "  tokens: 110,000 (fresh 100,000, cache write 0, cache read 0, output 10,000)"
  has_line "  window: after 2026-09-24T00:00:00Z through 2026-09-26T00:00:00Z"
  [ "$(jq -s '[.[] | select(.kind == "merge")] | length' "$TD/links.jsonl")" -eq 2 ]
}

# ---------- operand scan and seams ----------

@test "the operand scan: number, URL, quoted body text, and the first statement only reach gh as the operand" {
  run_merge 'gh pr merge 110 --squash && gh pr merge 111'
  run_merge 'gh pr merge https://github.com/o/r/pull/108 --auto'
  run_merge 'gh pr merge --body "a b c" --subject x 109'
  run_merge 'gh pr merge ; gh pr merge 112'
  local args
  args="$(sed 's/ --json .*//' "$GHSTUB_DIR/argv.log" | tr '\n' '|')"
  [ "$args" = 'pr view 110|pr view https://github.com/o/r/pull/108|pr view 109|pr view|' ]
}

@test "the test seam: GAIA_USAGE_HOOKS_DISABLE=1 prints nothing and runs nothing" {
  seed_uat007
  gh_view 101 101 plan/spec-090-foo MERGED 2026-09-25T00:00:00Z
  GAIA_USAGE_HOOKS_DISABLE=1 run_merge "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GHSTUB_DIR/argv.log" ]
}

@test "no new network host: across merges the gh stub sees only pr view and curl, wget, and nc are never called" {
  seed_uat007
  gh_view 101 101 plan/spec-090-foo MERGED 2026-09-25T00:00:00Z
  gh_view 105 105 fix/foo OPEN ""
  run_merge "gh pr merge 101"
  run_merge "gh pr merge 105 --auto"
  run_merge "gh pr merge 999"
  assert_gh_only_pr_view
  [ "$(wc -l <"$GHSTUB_DIR/argv.log" | tr -d ' ')" -eq 3 ]
}
