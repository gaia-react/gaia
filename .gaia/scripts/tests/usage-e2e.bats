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
# mock-hook-input.sh is not used: it has no SessionStart event and hardcodes
# /tmp/transcript.jsonl. Hook payloads are built with jq and point their
# transcript_path into the fixture projects root.

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=fixtures/usage/e2e/helpers.sh
  . "$BATS_TEST_DIRNAME/fixtures/usage/e2e/helpers.sh"
  # shellcheck source=../../tests/helpers/path.sh
  . "$E2E_SOURCE_ROOT/.gaia/tests/helpers/path.sh"
  build_repo
}

teardown() {
  pkill -f "$TEMPORARY_DIRECTORY/.*usage-flush" 2>/dev/null || true
}

# ---------- UAT-003 ----------

@test "UAT-003: a main-checkout session and a worktree session on debt/123-slug, flushed by Stop and read by the merge hook, total both and report 2 sessions" {
  seed_debt
  fire usage-capture.sh "$(hook_payload Stop s-m "$TRANSCRIPT_PATH_MAIN")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  fire usage-capture.sh "$(hook_payload Stop s-w "$TRANSCRIPT_PATH_WORKTREE")"
  [ "$status" -eq 0 ]
  quiesce 2
  assert_totals "$DEBT_TOTALS"

  gh_view 101 101 debt/123-slug MERGED 2026-10-02T00:00:00Z
  fire pr-merge-cost.sh "$(merge_payload 'gh pr merge 101 --squash' s-m "$TRANSCRIPT_PATH_MAIN")"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:debt/123-slug"
  has_line "  tokens: 7,812 (fresh 7, cache write 770, cache read 7,000, output 35)"
  grep -Eq '^  sessions: 2  span: 2026-10-01\.\.2026-10-01  coverage start: 2026-10-01$' <<<"$output"
  lacks "merge not confirmed"
}

# ---------- UAT-010 (full) ----------

@test "UAT-010: two Stop flushes, a SessionStart sweep, a link, and a declare released on one barrier: every line parses, golden totals, single link and declare rows, quiescent cursors" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  local worktree_a worktree_b transcript_path_a transcript_path_b transcript_path_c release_file="$TEMPORARY_DIRECTORY/go" pids=() line ledger_file
  worktree_a="$(make_worktree fix+a fix/a)"
  worktree_b="$(make_worktree fix+b fix/b)"
  transcript_path_a="$(transcript_path_for_session s-a "$worktree_a")"
  transcript_path_b="$(transcript_path_for_session s-b "$worktree_b")"
  transcript_path_c="$(transcript_path_for_session s-c)"
  write_assistant_message "$transcript_path_a" s-a "$worktree_a" worktree-fix+a a1 2026-10-01T09:00:01.000Z 1 1
  write_assistant_message "$transcript_path_a" s-a "$worktree_a" worktree-fix+a a2 2026-10-01T09:00:02.000Z 2 2
  write_assistant_message "$transcript_path_a" s-a "$worktree_a" worktree-fix+a a3 2026-10-01T09:00:03.000Z 3 3
  write_assistant_message "$transcript_path_b" s-b "$worktree_b" worktree-fix+b b1 2026-10-01T09:10:01.000Z 4 4
  write_assistant_message "$transcript_path_b" s-b "$worktree_b" worktree-fix+b b2 2026-10-01T09:10:02.000Z 5 5
  write_assistant_message "$transcript_path_c" s-c "$REPO" fix/c c1 2026-10-01T09:20:01.000Z 1 10
  touch -t 202001010000 "$transcript_path_a" "$transcript_path_b" "$transcript_path_c"
  mkdir -p "$TELEMETRY_DIRECTORY"
  local stop_payload_a stop_payload_b session_start_payload
  stop_payload_a="$(hook_payload Stop s-a "$transcript_path_a")"
  stop_payload_b="$(hook_payload Stop s-b "$transcript_path_b")"
  session_start_payload="$(hook_payload SessionStart s-start "$transcript_path_c")"
  # Each contender waits on the same file, so all five start together. The
  # redirects bind to the subshell so bats' own pipes are released at once.
  ( until [ -e "$release_file" ]; do :; done; cd "$REPO" && printf %s "$stop_payload_a" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$release_file" ]; do :; done; cd "$REPO" && printf %s "$stop_payload_b" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$release_file" ]; do :; done; cd "$REPO" && printf %s "$session_start_payload" | bash "$REPO/.claude/hooks/usage-capture.sh" ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$release_file" ]; do :; done; run_usage link spec:SPEC-001 research:x ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  ( until [ -e "$release_file" ]; do :; done; run_usage declare research:x --session s-decl ) >/dev/null 2>&1 3>&- &
  pids+=("$!")
  : >"$release_file"
  wait "${pids[@]}"
  quiesce 3

  for ledger_file in usage.jsonl links.jsonl; do
    while IFS= read -r line || [ -n "$line" ]; do
      jq -e . >/dev/null 2>&1 <<<"$line" || { echo "torn line in $ledger_file: $line" >&2; return 1; }
    done <"$TELEMETRY_DIRECTORY/$ledger_file"
  done
  assert_totals '{
    "branch:fix/a":{"claude-opus-5-5":{"cache_read":6000,"cache_write_1h":600,"cache_write_5m":60,"fresh_input":6,"output":6}},
    "branch:fix/b":{"claude-opus-5-5":{"cache_read":9000,"cache_write_1h":900,"cache_write_5m":90,"fresh_input":9,"output":9}},
    "branch:fix/c":{"claude-opus-5-5":{"cache_read":1000,"cache_write_1h":100,"cache_write_5m":10,"fresh_input":1,"output":10}}}'
  [ "$(jq -s '[.[] | select(.kind == "edge" and .child == "spec:SPEC-001" and .parent == "research:x")] | length' "$TELEMETRY_DIRECTORY/links.jsonl")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.kind == "binding" and .type == "declare" and .ref == "research:x" and .session_id == "s-decl")] | length' "$TELEMETRY_DIRECTORY/usage.jsonl")" -eq 1 ]
}

# ---------- UAT-013 ----------

# snapshot: the telemetry tree's names and content checksums.
snapshot() {
  find "$TELEMETRY_DIRECTORY" | sort
  local ledger_file
  find "$TELEMETRY_DIRECTORY" -type f | sort | while IFS= read -r ledger_file; do cksum <"$ledger_file"; done
}

@test "UAT-013: with jq absent every hook and every usage.sh subcommand (derived from the files) exits 0, prints only the inactive line where one is owed, and leaves telemetry untouched" {
  seed_debt
  flush_session s-m
  flush_session s-w
  run_usage link spec:SPEC-001 research:x >/dev/null
  local subcommand_names events nojq merge_hook_payload create_hook_payload subcommand args
  subcommand_names="$(derive_subcommands "$REPO/.gaia/scripts/usage.sh" | tr '\n' ' ')"
  [ "$subcommand_names" = "declare initiative lineage link pr pr-branch reconcile record represented unlink " ]
  events="$(jq -r '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | test("usage-capture\\.sh"))) | .key] | sort | join(" ")' "$REPO/.claude/settings.json")"
  [ "$events" = "SessionStart Stop" ]
  grep -q 'pr-merge-cost\.sh' "$REPO/.claude/settings.json"
  grep -q 'capture-gh-artifact\.sh' "$REPO/.claude/settings.json"

  nojq="$(path_shim_without jq)"
  [ -z "$(PATH="$nojq" command -v jq)" ]
  merge_hook_payload="$(merge_payload 'gh pr merge 101' s-m "$TRANSCRIPT_PATH_MAIN")"
  create_hook_payload="$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"gh pr create --title x"},tool_response:{stdout:"https://github.com/o/r/pull/9\n",stderr:""},session_id:"s-m"}')"
  : >"$TEMPORARY_DIRECTORY/ref"
  sleep 1
  snapshot >"$TEMPORARY_DIRECTORY/snap-before"

  for hook_event_name in Stop SessionStart; do
    run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(hook_payload "$hook_event_name" s-m "$TRANSCRIPT_PATH_MAIN")" "$REPO/.claude/hooks/usage-capture.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$merge_hook_payload" "$REPO/.claude/hooks/pr-merge-cost.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "usage tracking inactive: jq not found" ]
  run env PATH="$nojq" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$create_hook_payload" "$REPO/.claude/hooks/capture-gh-artifact.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for subcommand in $subcommand_names; do
    args="$(subcommand_arguments "$subcommand")"
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run --separate-stderr env PATH="$nojq" bash "$REPO/.gaia/scripts/usage.sh" $args
    case "$subcommand" in
      # The gates cannot answer without jq, so they refuse with 2 rather than
      # reporting nothing owed.
      record | represented)
        [ "$status" -eq 2 ] || { echo "usage.sh $subcommand exited $status without jq" >&2; return 1; }
        [ -z "$output" ] ;;
      *)
        [ "$status" -eq 0 ]
        [ "$output" = "usage tracking inactive: jq not found" ] ;;
    esac
  done
  sleep 1
  ! pgrep -f "$TEMPORARY_DIRECTORY/.*usage-flush" >/dev/null 2>&1 || return 1
  snapshot >"$TEMPORARY_DIRECTORY/snap-after"
  cmp "$TEMPORARY_DIRECTORY/snap-before" "$TEMPORARY_DIRECTORY/snap-after"
  [ -z "$(find "$TELEMETRY_DIRECTORY" -newer "$TEMPORARY_DIRECTORY/ref")" ]
}

@test "guards-must-fail (UAT-013): the derived subcommand set goes short when a dispatch arm is dropped, and subcommand_arguments refuses an unknown name" {
  local mutant_script="$TEMPORARY_DIRECTORY/usage-mutant.sh" full short
  sed '/^  unlink) /d' "$REPO/.gaia/scripts/usage.sh" >"$mutant_script"
  if cmp -s "$mutant_script" "$REPO/.gaia/scripts/usage.sh"; then echo "mutation did not apply" >&2; return 1; fi
  full="$(derive_subcommands "$REPO/.gaia/scripts/usage.sh" | tr '\n' ' ')"
  short="$(derive_subcommands "$mutant_script" | tr '\n' ' ')"
  [ "$full" = "declare initiative lineage link pr pr-branch reconcile record represented unlink " ]
  [ "$short" != "$full" ]
  run subcommand_arguments brand-new-subcommand
  [ "$status" -ne 0 ]
}

@test "guards-must-fail (UAT-013): the snapshot check goes red when a command writes one byte into the ledger" {
  seed_debt
  flush_session s-m
  : >"$TEMPORARY_DIRECTORY/ref"
  sleep 1
  snapshot >"$TEMPORARY_DIRECTORY/snap-before"
  printf '\n' >>"$TELEMETRY_DIRECTORY/usage.jsonl"
  snapshot >"$TEMPORARY_DIRECTORY/snap-after"
  run cmp -s "$TEMPORARY_DIRECTORY/snap-before" "$TEMPORARY_DIRECTORY/snap-after"
  [ "$status" -ne 0 ]
  [ -n "$(find "$TELEMETRY_DIRECTORY" -newer "$TEMPORARY_DIRECTORY/ref")" ]
}

# ---------- UAT-026 ----------

@test "UAT-026: a PR merged by the CLI leaves spend under its branch key, no merge row, and no block; the link command then makes its figure readable" {
  local transcript_path
  transcript_path="$(transcript_path_for_session s-cli)"
  write_assistant_message "$transcript_path" s-cli "$REPO" docs/wiki-chain w1 2026-10-01T09:00:01.000Z 3 7
  fire usage-capture.sh "$(hook_payload Stop s-cli "$transcript_path")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  quiesce 1
  assert_totals '{"branch:docs/wiki-chain":{"claude-opus-5-5":{"cache_read":3000,"cache_write_1h":300,"cache_write_5m":30,"fresh_input":3,"output":7}}}'
  [ ! -e "$TELEMETRY_DIRECTORY/links.jsonl" ]

  run run_usage link --merge 88 --branch docs/wiki-chain --merged-at 2026-10-02T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "merge" and .pr == 88 and .key == "branch:docs/wiki-chain")] | length' "$TELEMETRY_DIRECTORY/links.jsonl")" -eq 1 ]
  run run_usage pr 88
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
  flush_session s-m
  flush_session s-w
  git -C "$REPO" checkout -q -b feat/e2e
  gh_view 101 101 debt/123-slug MERGED 2026-10-02T00:00:00Z
  local subcommand args
  mkdir -p "$REPO/.gaia/local/specs/SPEC-009"
  printf -- '---\nspec_id: SPEC-009\nlineage: [research:topic-a]\n---\n' >"$REPO/.gaia/local/specs/SPEC-009/SPEC.md"
  fire usage-capture.sh "$(hook_payload Stop s-m "$TRANSCRIPT_PATH_MAIN")"
  fire usage-capture.sh "$(hook_payload SessionStart s-m "$TRANSCRIPT_PATH_MAIN")"
  fire pr-merge-cost.sh "$(merge_payload 'gh pr merge 101' s-m "$TRANSCRIPT_PATH_MAIN")"
  has_line "[PR cost] pr:101 branch:debt/123-slug"
  fire capture-gh-artifact.sh "$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"gh pr create --title x"},tool_response:{stdout:"https://github.com/o/r/pull/9\n",stderr:""},session_id:"s-m"}')"
  [ "$status" -eq 0 ]
  for subcommand in $(derive_subcommands "$REPO/.gaia/scripts/usage.sh"); do
    args="$(subcommand_arguments "$subcommand")"
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run run_usage $args
    [ "$status" -eq "$(subcommand_expected_status "$subcommand")" ] || { echo "usage.sh $subcommand exited $status: $output" >&2; return 1; }
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
  local transcript_path
  transcript_path="$(transcript_path_for_session s-ci)"
  write_assistant_message "$transcript_path" s-ci "$REPO" fix/ci c1 2026-10-01T09:00:01.000Z 1 1
  GITHUB_ACTIONS=true fire usage-capture.sh "$(hook_payload Stop s-ci "$transcript_path")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  GITHUB_ACTIONS=true fire usage-capture.sh "$(hook_payload SessionStart s-ci "$transcript_path")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 1
  [ ! -e "$REPO/.gaia/local/telemetry" ]
  fire usage-capture.sh "$(hook_payload Stop s-ci "$transcript_path")"
  quiesce 1
  [ -s "$TELEMETRY_DIRECTORY/usage.jsonl" ]
}
