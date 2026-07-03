#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-tally-git-op.sh (UAT-001/UAT-002/UAT-009)
# and its shared resolver lib .claude/hooks/lib/gaia-active-plan.sh.
#
# Every test runs the hook with cwd = a tmp git repo, never the real repo
# root: token-tally.sh's ledger resolution walks up from cwd via
# `git rev-parse --git-common-dir`, so running from the real repo would
# append test rows to the real .gaia/local/telemetry/tokens.jsonl. Each tmp
# repo gets its own copy of the built lib + the real token-tally.sh at their
# repo-relative paths (build_repo below), matching what a real checkout has.
#
# Session `fixturesession0001` against the anchor fixture
# (.gaia/scripts/tests/fixtures/token-tally/projects) is the same
# hand-computed oracle token-tally.bats uses: total 11110.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/token-tally-git-op.sh"
  LIB_SRC="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"
  TALLY_SRC="$REPO_ROOT/.gaia/scripts/token-tally.sh"
  ANCHOR="$REPO_ROOT/.gaia/scripts/tests/fixtures/token-tally/projects"
  SESSION="fixturesession0001"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${WT:-}" ] && [ -d "$WT" ] && rm -rf "$WT"
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
  return 0
}

# Scaffolds a tmp git repo with the built lib + the real token-tally.sh
# copied in at their repo-relative paths, preserving the executable bit.
# Sets $REPO.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$LIB_SRC" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$TALLY_SRC" "$REPO/.gaia/scripts/token-tally.sh"
  chmod +x "$REPO/.gaia/scripts/token-tally.sh"
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

run_hook() {
  # run_hook <command> [projects_root]
  local cmd="$1" proot="${2:-$ANCHOR}"
  local input
  input=$("$HELPERS/mock-hook-input.sh" pre-tool-use "$SESSION" Bash "$cmd")
  run env GAIA_TALLY_PROJECTS_ROOT="$proot" bash -c "echo '$input' | '$HOOK_ABS'"
}

# ---------- 1. Git commit with active plan folder -> keyed execute record (UAT-001) ----------
@test "git commit with active plan folder records a keyed execute record" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  LEDGER="$REPO/.gaia/local/telemetry/tokens.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.action' "$LEDGER")" = "execute" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-013" ]
  [ "$(jq -r '.plan_slug' "$LEDGER")" = "my-plan" ]
  [ "$(jq -r '.total' "$LEDGER")" -eq 11110 ]
  [ "$(jq -r '.partial' "$LEDGER")" = "false" ]
  [ "$(jq -r '.session_id' "$LEDGER")" = "$SESSION" ]
}

# ---------- 2. git push also records ----------
@test "git push also records an execute row" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git push"
  [ "$status" -eq 0 ]

  LEDGER="$REPO/.gaia/local/telemetry/tokens.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.action' "$LEDGER")" = "execute" ]
}

# ---------- 3. Negative gate: no plan folder -> no record (UAT-002) ----------
@test "no plan folder at all: no record written" {
  build_repo
  cd "$REPO"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

# ---------- 4. Negative gate: plan folder exists but branch does not match ----------
@test "plan folder exists but no RUNNING matches the branch: no record" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/other-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-099/SPEC.md"
  write_running "$plan_dir" "some-other-branch" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

# ---------- 5. Non-git command / git status: no record, no transcript parse ----------
@test "non-git command: no record" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "ls -la"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

@test "git status: no record (commit/push-only matching)" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git status"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

# ---------- 6. Feature-key resolution matches step 4.8 ----------
@test "feature key resolves via basename(dirname(SPEC path))" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$REPO/.gaia/local/telemetry/tokens.jsonl")" = "SPEC-042" ]
}

@test "spec-less plan README: feature key falls back to the plan slug" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/spec-less-slug"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$REPO/.gaia/local/telemetry/tokens.jsonl")" = "spec-less-slug" ]
}

# ---------- 7. Disambiguation by latest started ----------
@test "two matching plan folders disambiguate on the latest started timestamp" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"

  old_dir="$REPO/.gaia/local/plans/old-plan"
  write_readme_with_spec "$old_dir" "/abs/root/.gaia/local/specs/SPEC-001/SPEC.md"
  write_running "$old_dir" "$branch" "2026-07-01T00:00:00Z"

  new_dir="$REPO/.gaia/local/plans/new-plan"
  write_readme_with_spec "$new_dir" "/abs/root/.gaia/local/specs/SPEC-002/SPEC.md"
  write_running "$new_dir" "$branch" "2026-07-02T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  LEDGER="$REPO/.gaia/local/telemetry/tokens.jsonl"
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-002" ]
  [ "$(jq -r '.plan_slug' "$LEDGER")" = "new-plan" ]
}

# ---------- 8. Heredoc / commit-message false-match guard ----------
@test "git commit mentioned inside a quoted string is not matched" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook 'echo "remember to git commit later"'
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

@test "git commit mentioned in heredoc body prose is not matched" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  heredoc_cmd=$'cat <<EOF\nPlease remember to git commit your work.\nEOF'
  run_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/tokens.jsonl" ]
}

# ---------- 9. Never blocks: degraded projects-root still appends a partial record ----------
@test "nonexistent projects root: exit 0, partial record still appended" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x" "$REPO/no-such-projects-root"
  [ "$status" -eq 0 ]
  LEDGER="$REPO/.gaia/local/telemetry/tokens.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.partial' "$LEDGER")" = "true" ]
}

# ---------- 10. Worktree write-through lands in the main-checkout ledger (UAT-009) ----------
@test "worktree run writes the ledger to the main checkout, not the worktree" {
  MAIN="$(mktemp -d -t gaia-hook-test-XXXXXX)"
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" commit -q --allow-empty -m "init"

  WT="$(dirname "$MAIN")/gaia-hook-wt-$$"
  git -C "$MAIN" worktree add -q "$WT" -b feature/kickoff

  # The hook resolves repo-relative paths from its own cwd, so the worktree
  # (where it fires) needs the same scaffolding the main checkout would have.
  mkdir -p "$WT/.claude/hooks/lib" "$WT/.gaia/scripts"
  cp "$LIB_SRC" "$WT/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$WT/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$TALLY_SRC" "$WT/.gaia/scripts/token-tally.sh"
  chmod +x "$WT/.gaia/scripts/token-tally.sh"

  plan_dir="$WT/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "feature/kickoff" "2026-07-01T00:00:00Z"

  input=$("$HELPERS/mock-hook-input.sh" pre-tool-use "$SESSION" Bash "git commit -m x")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "cd '$WT' && echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  MAIN_LEDGER="$MAIN/.gaia/local/telemetry/tokens.jsonl"
  [ -f "$MAIN_LEDGER" ]
  [ "$(jq -r '.spec_id' "$MAIN_LEDGER")" = "SPEC-013" ]
  [ "$(jq -r '.total' "$MAIN_LEDGER")" -eq 11110 ]
  [ ! -f "$WT/.gaia/local/telemetry/tokens.jsonl" ]

  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  [ -f "$MAIN_LEDGER" ]
}
