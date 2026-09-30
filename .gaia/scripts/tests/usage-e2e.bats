#!/usr/bin/env bats
#
# End-to-end UATs and contract checks for the usage ledger (SPEC-087): the real
# hooks, flusher, resolver, and readouts over a tmp repo, where the component
# suites each prove one piece. Chains driven from transcript fixtures live in
# usage-e2e-chains.bats; both source fixtures/usage/e2e/helpers.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-e2e.bats
#
# The "cost.jsonl files unchanged" half of SPEC success criterion 7 is a
# merge-base diff, which a shallow CI checkout cannot run, so it is a Phase 4
# gate step rather than a case here. The token-tally, token-rollup, and
# cost-lock suites are run beside this one as that criterion's other half.
#
# mock-hook-input.sh is not used: it has no SessionStart event and hardcodes
# /tmp/transcript.jsonl. Hook payloads are built with jq and point their
# transcript_path into the fixture projects root.

bats_require_minimum_version 1.5.0

setup() {
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  # shellcheck source=fixtures/usage/e2e/helpers.sh
  . "$BATS_TEST_DIRNAME/fixtures/usage/e2e/helpers.sh"
  # shellcheck source=../../tests/helpers/path.sh
  . "$E2E_SRC/.gaia/tests/helpers/path.sh"
  build_repo
}

teardown() {
  pkill -f "$TMP/.*usage-flush" 2>/dev/null || true
}

# ---------- UAT-003 ----------

@test "UAT-003: a main-checkout session and a worktree session on debt/123-slug, flushed by Stop and read by the merge hook, total both and report 2 sessions" {
  seed_debt
  fire usage-capture.sh "$(hook_payload Stop s-m "$TP_M")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  fire usage-capture.sh "$(hook_payload Stop s-w "$TP_W")"
  [ "$status" -eq 0 ]
  quiesce 2
  assert_totals "$DEBT_TOTALS"

  gh_view 101 101 debt/123-slug MERGED 2026-10-02T00:00:00Z
  fire token-rollup-merge.sh "$(merge_payload 'gh pr merge 101 --squash' s-m "$TP_M")"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:debt/123-slug"
  has_line "  tokens: 7,812 (fresh 7, cache write 770, cache read 7,000, output 35)"
  grep -Eq '^  sessions: 2  span: 2026-10-01\.\.2026-10-01  coverage start: 2026-10-01$' <<<"$output"
  lacks "merge not confirmed"
}

# ---------- UAT-010 (full) ----------

@test "UAT-010: two Stop flushes, a SessionStart sweep, a link, and a declare released on one barrier: every line parses, golden totals, single link and declare rows, quiescent cursors" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  local wa wb tpa tpb tpc go="$TMP/go" pids=() line f
  wa="$(mk_worktree fix+a fix/a)"
  wb="$(mk_worktree fix+b fix/b)"
  tpa="$(tpath s-a "$wa")"
  tpb="$(tpath s-b "$wb")"
  tpc="$(tpath s-c)"
  asst "$tpa" s-a "$wa" worktree-fix+a a1 2026-10-01T09:00:01.000Z 1 1
  asst "$tpa" s-a "$wa" worktree-fix+a a2 2026-10-01T09:00:02.000Z 2 2
  asst "$tpa" s-a "$wa" worktree-fix+a a3 2026-10-01T09:00:03.000Z 3 3
  asst "$tpb" s-b "$wb" worktree-fix+b b1 2026-10-01T09:10:01.000Z 4 4
  asst "$tpb" s-b "$wb" worktree-fix+b b2 2026-10-01T09:10:02.000Z 5 5
  asst "$tpc" s-c "$REPO" fix/c c1 2026-10-01T09:20:01.000Z 1 10
  touch -t 202001010000 "$tpa" "$tpb" "$tpc"
  mkdir -p "$TD"
  local pa pb ps
  pa="$(hook_payload Stop s-a "$tpa")"
  pb="$(hook_payload Stop s-b "$tpb")"
  ps="$(hook_payload SessionStart s-start "$tpc")"
  # Each contender waits on the same file, so all five start together. The
  # redirects bind to the subshell so bats' own pipes are released at once.
  ( until [ -e "$go" ]; do :; done; cd "$REPO" && printf %s "$pa" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$go" ]; do :; done; cd "$REPO" && printf %s "$pb" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$go" ]; do :; done; cd "$REPO" && printf %s "$ps" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$go" ]; do :; done; u link spec:SPEC-001 research:x ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$go" ]; do :; done; u declare research:x --session s-decl ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  : >"$go"
  wait "${pids[@]}"
  quiesce 3

  for f in usage.jsonl links.jsonl; do
    while IFS= read -r line || [ -n "$line" ]; do
      jq -e . >/dev/null 2>&1 <<<"$line" || { echo "torn line in $f: $line" >&2; return 1; }
    done <"$TD/$f"
  done
  assert_totals '{
    "branch:fix/a":{"claude-opus-5-5":{"cache_read":6000,"cache_write_1h":600,"cache_write_5m":60,"fresh_input":6,"output":6}},
    "branch:fix/b":{"claude-opus-5-5":{"cache_read":9000,"cache_write_1h":900,"cache_write_5m":90,"fresh_input":9,"output":9}},
    "branch:fix/c":{"claude-opus-5-5":{"cache_read":1000,"cache_write_1h":100,"cache_write_5m":10,"fresh_input":1,"output":10}}}'
  [ "$(jq -s '[.[] | select(.kind == "edge" and .child == "spec:SPEC-001" and .parent == "research:x")] | length' "$TD/links.jsonl")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.kind == "binding" and .type == "declare" and .ref == "research:x" and .session_id == "s-decl")] | length' "$TD/usage.jsonl")" -eq 1 ]
}

# ---------- UAT-013 ----------

# snapshot: the telemetry tree's names and content checksums.
snapshot() {
  find "$TD" | sort
  local f
  find "$TD" -type f | sort | while IFS= read -r f; do cksum <"$f"; done
}

@test "UAT-013: with jq absent every hook and every usage.sh subcommand (derived from the files) exits 0, prints only the inactive line where one is owed, and leaves telemetry untouched" {
  seed_debt
  flush1 s-m
  flush1 s-w
  u link spec:SPEC-001 research:x >/dev/null
  local subs events nojq pmerge pcreate s args
  subs="$(derive_subs "$REPO/.gaia/scripts/usage.sh" | tr '\n' ' ')"
  [ "$subs" = "declare initiative lineage link pr pr-branch reconcile unlink " ]
  events="$(jq -r '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | test("usage-capture\\.sh"))) | .key] | sort | join(" ")' "$REPO/.claude/settings.json")"
  [ "$events" = "SessionStart Stop" ]
  grep -q 'token-rollup-merge\.sh' "$REPO/.claude/settings.json"
  grep -q 'capture-gh-artifact\.sh' "$REPO/.claude/settings.json"

  nojq="$(path_shim_without jq)"
  [ -z "$(PATH="$nojq" command -v jq)" ]
  pmerge="$(merge_payload 'gh pr merge 101' s-m "$TP_M")"
  pcreate="$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"gh pr create --title x"},tool_response:{stdout:"https://github.com/o/r/pull/9\n",stderr:""},session_id:"s-m"}')"
  : >"$TMP/ref"
  sleep 1
  snapshot >"$TMP/snap-before"

  for s in Stop SessionStart; do
    run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(hook_payload "$s" s-m "$TP_M")" "$REPO/.claude/hooks/usage-capture.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$pmerge" "$REPO/.claude/hooks/token-rollup-merge.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "usage tracking inactive: jq not found" ]
  run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$pcreate" "$REPO/.claude/hooks/capture-gh-artifact.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for s in $subs; do
    args="$(sub_args "$s")"
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run env PATH="$nojq" bash "$REPO/.gaia/scripts/usage.sh" $args
    [ "$status" -eq 0 ]
    [ "$output" = "usage tracking inactive: jq not found" ]
  done
  sleep 1
  ! pgrep -f "$TMP/.*usage-flush" >/dev/null 2>&1 || return 1
  snapshot >"$TMP/snap-after"
  cmp "$TMP/snap-before" "$TMP/snap-after"
  [ -z "$(find "$TD" -newer "$TMP/ref")" ]
}

@test "guards-must-fail (UAT-013): the derived subcommand set goes short when a dispatch arm is dropped, and sub_args refuses an unknown name" {
  local m="$TMP/usage-mutant.sh" full short
  sed '/^  unlink) /d' "$REPO/.gaia/scripts/usage.sh" >"$m"
  if cmp -s "$m" "$REPO/.gaia/scripts/usage.sh"; then echo "mutation did not apply" >&2; return 1; fi
  full="$(derive_subs "$REPO/.gaia/scripts/usage.sh" | tr '\n' ' ')"
  short="$(derive_subs "$m" | tr '\n' ' ')"
  [ "$full" = "declare initiative lineage link pr pr-branch reconcile unlink " ]
  [ "$short" != "$full" ]
  run sub_args brand-new-subcommand
  [ "$status" -ne 0 ]
}

@test "guards-must-fail (UAT-013): the snapshot check goes red when a command writes one byte into the ledger" {
  seed_debt
  flush1 s-m
  : >"$TMP/ref"
  sleep 1
  snapshot >"$TMP/snap-before"
  printf '\n' >>"$TD/usage.jsonl"
  snapshot >"$TMP/snap-after"
  run cmp -s "$TMP/snap-before" "$TMP/snap-after"
  [ "$status" -ne 0 ]
  [ -n "$(find "$TD" -newer "$TMP/ref")" ]
}

# ---------- UAT-026 ----------

@test "UAT-026: a PR merged by the CLI leaves spend under its branch key, no merge row, and no block; the link command then makes its figure readable" {
  local tp
  tp="$(tpath s-cli)"
  asst "$tp" s-cli "$REPO" docs/wiki-chain w1 2026-10-01T09:00:01.000Z 3 7
  fire usage-capture.sh "$(hook_payload Stop s-cli "$tp")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  quiesce 1
  assert_totals '{"branch:docs/wiki-chain":{"claude-opus-5-5":{"cache_read":3000,"cache_write_1h":300,"cache_write_5m":30,"fresh_input":3,"output":7}}}'
  [ ! -e "$TD/links.jsonl" ]

  run u link --merge 88 --branch docs/wiki-chain --merged-at 2026-10-02T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "merge" and .pr == 88 and .key == "branch:docs/wiki-chain")] | length' "$TD/links.jsonl")" -eq 1 ]
  run u pr 88
  has_line "[PR cost] pr:88 branch:docs/wiki-chain"
  has_line "  tokens: 3,340 (fresh 3, cache write 330, cache read 3,000, output 7)"
}

# ---------- UAT-027 ----------

# net_clean: the stub log holds nothing but `gh pr view` reads and none of the
# fixture's token counts, model id, or segment keys.
net_clean() {
  [ ! -e "$STUBLOG" ] && return 0
  if grep -qv '^gh pr view ' "$STUBLOG"; then grep -v '^gh pr view ' "$STUBLOG" >&2; return 1; fi
  if grep -qE 'claude-opus|branch:|session:|research:|\b(7812|7000|770|3348|4464)\b' "$STUBLOG"; then cat "$STUBLOG" >&2; return 1; fi
  return 0
}

@test "UAT-027: every hook and every usage.sh subcommand over a populated fixture makes no network call beyond the one gh pr view read per merge" {
  # The single permitted call is `gh pr view` from the merge hook: the host
  # `gh` already uses, and the only confirmation that a merge happened (AUDIT
  # SEC-003). curl, wget, and nc are stubs that log any call.
  seed_debt
  flush1 s-m
  flush1 s-w
  git -C "$REPO" checkout -q -b feat/e2e
  gh_view 101 101 debt/123-slug MERGED 2026-10-02T00:00:00Z
  local s args
  mkdir -p "$REPO/.gaia/local/specs/SPEC-009"
  printf -- '---\nspec_id: SPEC-009\nlineage: [research:topic-a]\n---\n' >"$REPO/.gaia/local/specs/SPEC-009/SPEC.md"
  fire usage-capture.sh "$(hook_payload Stop s-m "$TP_M")"
  fire usage-capture.sh "$(hook_payload SessionStart s-m "$TP_M")"
  fire token-rollup-merge.sh "$(merge_payload 'gh pr merge 101' s-m "$TP_M")"
  has_line "[PR cost] pr:101 branch:debt/123-slug"
  fire capture-gh-artifact.sh "$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"gh pr create --title x"},tool_response:{stdout:"https://github.com/o/r/pull/9\n",stderr:""},session_id:"s-m"}')"
  [ "$status" -eq 0 ]
  for s in $(derive_subs "$REPO/.gaia/scripts/usage.sh"); do
    args="$(sub_args "$s")"
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run u $args
    [ "$status" -eq 0 ] || { echo "usage.sh $s exited $status: $output" >&2; return 1; }
  done
  quiesce 2
  [ -f "$STUBLOG" ]
  grep -q '^gh pr view ' "$STUBLOG"
  net_clean
}

@test "guards-must-fail (UAT-027): net_clean goes red on a curl call and on a token count in the log" {
  printf 'curl https://example.com\n' >"$STUBLOG"
  run net_clean
  [ "$status" -ne 0 ]
  printf 'gh pr view 7812 --json x\n' >"$STUBLOG"
  run net_clean
  [ "$status" -ne 0 ]
}

# ---------- UAT-028 ----------

@test "UAT-028: GITHUB_ACTIONS set, Stop and SessionStart exit 0 and create no telemetry directory; the unset control does" {
  local tp
  tp="$(tpath s-ci)"
  asst "$tp" s-ci "$REPO" fix/ci c1 2026-10-01T09:00:01.000Z 1 1
  GITHUB_ACTIONS=true fire usage-capture.sh "$(hook_payload Stop s-ci "$tp")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  GITHUB_ACTIONS=true fire usage-capture.sh "$(hook_payload SessionStart s-ci "$tp")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 1
  [ ! -e "$REPO/.gaia/local/telemetry" ]
  fire usage-capture.sh "$(hook_payload Stop s-ci "$tp")"
  quiesce 1
  [ -s "$TD/usage.jsonl" ]
}
