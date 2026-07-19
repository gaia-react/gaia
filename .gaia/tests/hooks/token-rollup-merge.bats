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
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/token-rollup-merge.sh"
  LIB_SRC="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"
  ROLLUP_SRC="$REPO_ROOT/.gaia/scripts/token-rollup.sh"
  LIB_PRICING_SRC="$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  LIB_LEDGER_SRC="$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh"

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
  cp "$LIB_SRC" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$ROLLUP_SRC" "$REPO/.gaia/scripts/token-rollup.sh"
  chmod +x "$REPO/.gaia/scripts/token-rollup.sh"
  cp "$LIB_PRICING_SRC" "$REPO/.gaia/scripts/token-pricing-lib.sh"
  cp "$LIB_LEDGER_SRC" "$REPO/.gaia/scripts/ledger-path-lib.sh"
}

write_running() {
  # write_running <plan_dir> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_dir> <spec_path>
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

# write_record <action> <spec_id> <session_id> <total> <ts> [<ended_at>]
write_record() {
  local action="$1" spec_id="$2" sid="$3" total="$4" ts="$5"
  local ended="${6:-$ts}"
  mkdir -p "$(dirname "$(ledger_path)")"
  jq -nc --arg kind "$action" --arg spec_id "$spec_id" --arg sid "$sid" \
    --argjson total "$total" --arg ts "$ts" --arg ended "$ended" \
    '{kind:$kind, spec_id:$spec_id, plan_slug:"my-plan", session_id:$sid,
      buckets:{fresh_input:$total, cache_write:0, cache_read:0, output:0},
      total:$total, partial:false, started_at:$ended, ended_at:$ended,
      duration_seconds:10, duration_available:true, ts:$ts}' >> "$(ledger_path)"
}

run_hook() {
  # run_hook <command>
  local cmd="$1" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$cmd")
  run bash -c "echo '$input' | '$HOOK_ABS'"
}

# ---------- 1. Renders spec+plan+execute+Total at merge (UAT-006) ----------
@test "renders the roll-up at merge with spec+plan+execute" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

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

# ---------- 1b. Colocated spec-plan layout resolves the merge readout key ----------
# Spec-derived plans colocate at specs/<SPEC-ID>/plan[-N] rather than
# plans/<slug>. The merge-readout hook's PRIMARY path resolves the feature key
# from the active plan folder via the shared resolver, whose union globs cover
# the colocated location. This proves the readout keys off the colocated plan
# folder itself (not the ledger fallback) and renders the full cycle.
@test "colocated spec plan (specs/<id>/plan) resolves the merge readout key" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/specs/SPEC-042/plan"
  write_readme_with_spec "$plan_dir" ".gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

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

# ---------- 2. Spec-less plan omits the spec line (UAT-007) ----------
@test "spec-less plan omits the spec line" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/spec-less-plan"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

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

# ---------- 4. Fallback picks the most-recent execute feature ----------
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

# ---------- 5. Primary resolver wins over a newer unrelated execute row ----------
@test "active plan folder wins over a newer unrelated feature's execute row" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

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
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  heredoc_cmd=$'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  run_hook "$heredoc_cmd"
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

# ---------- 9. Renders regardless of the merge subprocess's own exit ----------
@test "renders even when tool_response reports a failed merge" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  input=$(jq -n --arg sid "S1" --arg cmd "gh pr merge 7 --squash" \
    '{session_id:$sid, transcript_path:"/tmp/t.jsonl", cwd:".", hook_event_name:"PostToolUse",
      tool_name:"Bash", tool_input:{command:$cmd},
      tool_response:{stdout:"", stderr:"merge failed", exit_code:1, interrupted:false}}')
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
}
