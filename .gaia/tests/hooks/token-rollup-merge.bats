#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-rollup-merge.sh (UAT-006/007/010, directive 5).
#
# Every test runs the hook with cwd = a tmp git repo, never the real repo
# root: the hook sources gaia-active-plan.sh and shells out to
# token-rollup.sh via repo-relative paths, and the reader resolves the ledger
# via `git rev-parse --git-common-dir`. Running from the real repo would read
# the live .gaia/local/telemetry/cost.jsonl. Each tmp repo gets its own copy
# of the built libs + the real token-rollup.sh at their repo-relative paths
# (build_repo below), matching what a real checkout has.

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  # This suite runs the REAL hook, so its usage-merge.sh would run in every
  # armed case. The seam keeps each pre-existing case exactly as it was; the
  # cases that test the usage block unset it.
  export GAIA_USAGE_HOOKS_DISABLE=1
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.claude/hooks/token-rollup-merge.sh"
  LIBRARY_SOURCE="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"
  ROLLUP_SOURCE="$REPO_ROOT/.gaia/scripts/token-rollup.sh"
  LIBRARY_PRICING_SOURCE="$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  LIBRARY_RATES_LOCAL_SOURCE="$REPO_ROOT/.gaia/scripts/token-rates-local-lib.sh"
  LIBRARY_RATES_FEED_SOURCE="$REPO_ROOT/.gaia/scripts/token-rates-feed-lib.sh"
  LIBRARY_LEDGER_SOURCE="$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh"
  LIBRARY_MAIN_ROOT_SOURCE="$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  VERB_ARMING_SOURCE="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  VERB_ARMING_WALK_SOURCE="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  REPO_SCOPE_SOURCE="$REPO_ROOT/.claude/hooks/lib/repo-scope.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Scaffolds a tmp git repo with the built libs + the real token-rollup.sh
# copied in at their repo-relative paths, preserving the executable bit.
# Sets $REPO.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$LIBRARY_SOURCE" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$ROLLUP_SOURCE" "$REPO/.gaia/scripts/token-rollup.sh"
  chmod +x "$REPO/.gaia/scripts/token-rollup.sh"
  cp "$LIBRARY_PRICING_SOURCE" "$REPO/.gaia/scripts/token-pricing-lib.sh"
  cp "$LIBRARY_RATES_LOCAL_SOURCE" "$REPO/.gaia/scripts/token-rates-local-lib.sh"
  cp "$LIBRARY_RATES_FEED_SOURCE" "$REPO/.gaia/scripts/token-rates-feed-lib.sh"
  cp "$LIBRARY_LEDGER_SOURCE" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$LIBRARY_MAIN_ROOT_SOURCE" "$REPO/.gaia/scripts/main-root-lib.sh"
  cp "$VERB_ARMING_SOURCE" "$REPO/.claude/hooks/lib/verb-arming.sh"
  cp "$VERB_ARMING_WALK_SOURCE" "$REPO/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_SCOPE_SOURCE" "$REPO/.claude/hooks/lib/repo-scope.sh"
}

write_running() {
  # write_running <plan_directory> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_directory> <spec_path>
  mkdir -p "$1"
  {
    printf '# Plan\n\n'
    printf '## Source SPEC\n\n'
    printf 'Derived from %s (%s).\n' "$(basename "$(dirname "$2")")" "$2"
  } > "$1/README.md"
}

write_readme_spec_less() {
  mkdir -p "$1"
  printf '# Plan\n\nNo source spec here.\n' > "$1/README.md"
}

ledger_path() {
  printf '%s/.gaia/local/telemetry/cost.jsonl' "$REPO"
}

# write_record <action> <spec_id> <session_id> <total> <timestamp> [<ended_at>]
write_record() {
  local action="$1" spec_id="$2" session_id="$3" total="$4" timestamp="$5"
  local ended="${6:-$timestamp}"
  mkdir -p "$(dirname "$(ledger_path)")"
  jq -nc --arg kind "$action" --arg spec_id "$spec_id" --arg session_id "$session_id" \
    --argjson total "$total" --arg timestamp "$timestamp" --arg ended "$ended" \
    '{kind:$kind, spec_id:$spec_id, plan_slug:"my-plan", session_id:$session_id,
      buckets:{fresh_input:$total, cache_write:0, cache_read:0, output:0},
      total:$total, partial:false, started_at:$ended, ended_at:$ended,
      duration_seconds:10, duration_available:true, ts:$timestamp}' >> "$(ledger_path)"
}

run_hook() {
  # run_hook <command>
  local command="$1" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$command")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
}

# ---------- 1. Renders spec+plan+execute+Total at merge (UAT-006) ----------
@test "renders the roll-up at merge with spec+plan+execute" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"spec:"* ]]
  [[ "$output" == *"plan:"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"Total:"* ]]
  [[ "$output" == *"600"* ]]
  # SPEC-019: this synthetic repo carries no committed token-rates.json (see
  # build_repo above), so --show-toplevel resolves to a rate table that
  # doesn't exist here and rate_table_ok=false wins FC-4 precedence -- the
  # dollar block renders "unavailable (rate table unreadable)", not "records
  # predate per-model attribution" (unreachable in this scaffold). Assert only
  # the header substring: marker-agnostic, robust to either degrade form.
  [[ "$output" == *"Est. cost (USD):"* ]]
}

# Spec-derived plans colocate at specs/<SPEC-ID>/plan[-N] rather than
# plans/<slug>. The merge-readout hook's PRIMARY path resolves the feature key
# from the active plan folder via the shared resolver, whose union globs cover
# the colocated location. This proves the readout keys off the colocated plan
# folder itself (not the ledger fallback) and renders the full cycle.
@test "colocated spec plan (specs/<id>/plan) resolves the merge readout key" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/specs/SPEC-042/plan"
  write_readme_with_spec "$plan_directory" ".gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  # Resolved via the colocated active plan folder, NOT the ledger fallback.
  [[ "$output" != *"resolved from the ledger"* ]]
  [[ "$output" == *"600"* ]]
}

# UAT-007
@test "spec-less plan omits the spec line" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/spec-less-plan"
  write_readme_spec_less "$plan_directory"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  write_record plan spec-less-plan sess-plan 150 "2026-06-02T00:00:00Z"
  write_record execute spec-less-plan sess-exec 250 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" != *"spec:"* ]]
  [[ "$output" == *"plan:"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"Total:"* ]]
  [[ "$output" == *"400"* ]]
}

# ---------- 3. Fresh session, no plan folder -> ledger fallback (directive 5) ----------
@test "fresh session with no active plan folder falls back to the ledger and labels itself" {
  build_repo
  cd "$REPO"
  # No plan folder at all: this is the fresh-top-level-session case.
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved from the ledger"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"300"* ]]
}

@test "fallback picks the execute record with the latest ts" {
  build_repo
  cd "$REPO"
  write_record execute SPEC-001 sess-a 100 "2026-06-01T00:00:00Z"
  write_record execute SPEC-002 sess-b 200 "2026-06-05T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-002)"* ]]
  [[ "$output" != *"Cycle cost (SPEC-001)"* ]]
}

@test "active plan folder wins over a newer unrelated feature's execute row" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"

  # SPEC-042's own (older) execute record.
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"
  # A globally newer execute row for an unrelated, interleaved feature.
  write_record execute SPEC-999 sess-b 999 "2026-06-09T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" != *"Cycle cost (SPEC-999)"* ]]
  [[ "$output" != *"resolved from the ledger"* ]]
}

# ---------- 6. Non-merge command: silent ----------
@test "non-merge git command: silent" {
  build_repo
  cd "$REPO"
  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr view is not a merge: silent" {
  build_repo
  cd "$REPO"
  run_hook "gh pr view 7"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 7. Corrupt / missing ledger never blocks (UAT-010) ----------
@test "corrupt ledger line does not block; the good execute record still renders" {
  build_repo
  cd "$REPO"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"
  echo 'not-json-garbage' >> "$(ledger_path)"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"execute:"* ]]
}

@test "no active plan folder and no ledger at all: exit 0, empty stdout" {
  build_repo
  cd "$REPO"
  # No plan folder, no ledger file: nothing to resolve a feature key from.
  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 8. Heredoc / quoted-string false-match guard ----------
@test "gh pr merge mentioned only inside heredoc body prose: not matched" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  heredoc_command=$'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  run_hook "$heredoc_command"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr merge mentioned inside a quoted string: not matched" {
  build_repo
  cd "$REPO"
  run_hook 'echo "remember to gh pr merge later"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- Shared arming decision: readout / no readout / readout ----------
#
# UAT-010's `then` says the positive control renders "and the other two emit
# none", the other two being the heredoc-body payload and the past-bound
# payload. UAT-005 requires the past-bound call to arm and deny (for the
# deny-capable siblings) or, here, to arm and render, because the SPEC's own
# identity-above-bound rule says the view past GAIA_VERB_ARM_MAXIMUM_CHARACTERS is the
# identity and the raw match stands. UAT-005 and the identity rule win;
# UAT-010's "other two" clause is superseded as to the past-bound half only.
# See plan/README.md, "Where UAT-010 and UAT-005 conflict, and which wins".
@test "seeded positive control renders, the heredoc-body payload does not, and the past-bound payload renders again" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  # 1. Positive control: renders.
  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "[cycle cost at merge]" <<<"$output" || return 1

  # 2. Heredoc-body payload (cat-to-file, proven data): no readout.
  heredoc_command=$'cat > /tmp/notes.txt <<EOF\ngh pr merge 7\nEOF'
  run_hook "$heredoc_command"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # 3. The same heredoc-body payload padded past the arming bound: renders
  # again. The walker abstains above GAIA_VERB_ARM_MAXIMUM_CHARACTERS, so the raw
  # match stands unmasked.
  local pad over_limit_command
  pad=$(printf 'x%.0s' $(seq 1 16400))
  over_limit_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge 7\nEOF'
  [ "${#over_limit_command}" -gt 16384 ] || return 1
  run_hook "$over_limit_command"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

@test "a quoted verb in the first command renders (tokenizer arm; red before this change)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook 'gh pr "merge" 7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

@test "a multi-statement command still renders (no regression)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "echo start && gh pr merge 7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

# ---------- 9. Renders regardless of the merge subprocess's own exit ----------
@test "renders even when tool_response reports a failed merge" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  input=$(jq -n --arg session_id "S1" --arg command "gh pr merge 7 --squash" \
    '{session_id:$session_id, transcript_path:"/tmp/t.jsonl", cwd:".", hook_event_name:"PostToolUse",
      tool_name:"Bash", tool_input:{command:$command},
      tool_response:{stdout:"", stderr:"merge failed", exit_code:1, interrupted:false}}')
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

# ---------- 10. The per-PR usage block and the jq-absent marker ----------

@test "the per-PR block prints first and the cycle roll-up follows it" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  branch="$(git branch --show-current)"
  plan_directory="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_directory" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_directory" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"
  mkdir -p "$BATS_TEST_TMPDIR/ghbin"
  cat >"$BATS_TEST_TMPDIR/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '{"number":7,"headRefName":"fix/co","state":"MERGED","mergedAt":"2026-07-02T00:00:00Z"}\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/ghbin/gh"
  PATH="$BATS_TEST_TMPDIR/ghbin:$PATH" run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  pr_line="$(grep -n '^\[PR cost\] pr:7 branch:fix/co$' <<<"$output" | head -1 | cut -d: -f1)"
  rollup_line="$(grep -n '^\[cycle cost at merge\]$' <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$pr_line" ]
  [ -n "$rollup_line" ]
  [ "$pr_line" -lt "$rollup_line" ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
}

# run_nojq <hook> <command>: the hook under a PATH that carries cat and grep
# and no jq.
run_nojq() {
  local directory="$BATS_TEST_TMPDIR/nojq-bin" input
  mkdir -p "$directory"
  ln -sf "$(command -v cat)" "$directory/cat"
  ln -sf "$(command -v grep)" "$directory/grep"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$2")
  run bash -c 'printf %s "$1" | PATH="$2" /bin/bash "$3"' _ "$input" "$directory" "$1"
}

@test "jq absent: an armed merge prints the inactive marker and exits 0; a non-merge prints nothing" {
  run_nojq "$HOOK_ABSOLUTE_PATH" "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ "$output" = "usage tracking inactive: jq not found" ]
  run_nojq "$HOOK_ABSOLUTE_PATH" "gh pr view 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guards-must-fail: a copy of the hook without the raw-grep branch stays silent for the same merge payload" {
  local mutant="$BATS_TEST_TMPDIR/rollup-noraw.sh"
  sed 's/^  if grep -Eq .*<<<"$payload"; then$/  if false; then/' "$HOOK_ABSOLUTE_PATH" >"$mutant"
  cmp -s "$HOOK_ABSOLUTE_PATH" "$mutant" && return 1
  run_nojq "$mutant" "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
