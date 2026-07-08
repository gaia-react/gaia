#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-tally-git-op.sh and its shared resolver
# lib .claude/hooks/lib/gaia-active-plan.sh.
#
# Every test runs the hook with cwd = a tmp git repo, never the real repo
# root: token-tally.sh's ledger resolution walks up from cwd via
# `git rev-parse --git-common-dir`, so running from the real repo would
# append test rows to the real .gaia/local/telemetry/cost.jsonl. Each tmp
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
  LIB_PRICING_SRC="$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  LIB_LEDGER_PATH_SRC="$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh"
  LIB_AUDIT_WINDOW_SRC="$REPO_ROOT/.gaia/scripts/audit-window-lib.sh"
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
  cp "$LIB_PRICING_SRC" "$REPO/.gaia/scripts/token-pricing-lib.sh"
  cp "$LIB_LEDGER_PATH_SRC" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$LIB_AUDIT_WINDOW_SRC" "$REPO/.gaia/scripts/audit-window-lib.sh"
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

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.kind' "$LEDGER")" = "execute" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-013" ]
  [ "$(jq -r '.plan_id' "$LEDGER")" = "null" ]
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

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.kind' "$LEDGER")" = "execute" ]
}

# ---------- 2b. Colocated spec-plan layout: specs/<SPEC-ID>/plan[-N] ----------
# Spec-derived plans no longer live under plans/<slug>; they colocate inside
# their SPEC folder at specs/<SPEC-ID>/plan[-N]. The hook's cheap has_plan gate
# and the shared resolver both scan the union of the three RUNNING globs. These
# cases prove the colocated location is keyed and tallied exactly like a
# spec-less plan: the feature key still resolves to the SPEC id, cost.json lands
# inside the colocated plan dir, and the plan_slug degrades to the folder
# basename (`plan` / `plan-2`) with no effect on the spec-keyed ledger row.
@test "colocated spec plan (specs/<id>/plan) records a spec-keyed execute record" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/specs/SPEC-021/plan"
  # README Source SPEC points at the sibling SPEC.md, as a real colocated plan does.
  write_readme_with_spec "$plan_dir" ".gaia/local/specs/SPEC-021/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.kind' "$LEDGER")" = "execute" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-021" ]
  [ "$(jq -r '.plan_slug' "$LEDGER")" = "plan" ]
  [ "$(jq -r '.total' "$LEDGER")" -eq 11110 ]
  [ "$(jq -r '.partial' "$LEDGER")" = "false" ]
  # cost.json lands inside the colocated plan dir, not under plans/.
  [ -f "$plan_dir/cost.json" ]
}

@test "colocated re-planned folder (specs/<id>/plan-2) is discovered and keyed" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/specs/SPEC-021/plan-2"
  write_readme_with_spec "$plan_dir" ".gaia/local/specs/SPEC-021/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-021" ]
  [ "$(jq -r '.plan_slug' "$LEDGER")" = "plan-2" ]
}

# ---------- 3. Negative gate: no plan folder -> no record (UAT-002) ----------
@test "no plan folder at all: no record written" {
  build_repo
  cd "$REPO"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "git status: no record (commit/push-only matching)" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git status"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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
  [ "$(jq -r '.spec_id' "$REPO/.gaia/local/telemetry/cost.jsonl")" = "SPEC-042" ]
}

@test "spec-less plan (PLAN-NNN dir, no SPEC) routes to --plan-id" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/PLAN-003"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ "$(jq -r '.plan_id' "$LEDGER")" = "PLAN-003" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "null" ]
}

# ---------- 6b. Unclassifiable key: degrades to a partial row, never a mistyped plan_id ----------
@test "unclassifiable feature key (bare 'plan' basename): partial row, both ids null" {
  build_repo
  cd "$REPO"
  # A colocated plan dir named `plan` whose README has no parseable Source SPEC
  # section: resolve_feature_key's fallback returns the bare basename `plan`,
  # matching neither the SPEC- nor PLAN- prefix.
  plan_dir="$REPO/.gaia/local/specs/SPEC-099/plan"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.partial' "$LEDGER")" = "true" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "null" ]
  [ "$(jq -r '.plan_id' "$LEDGER")" = "null" ]
}

# ---------- 6c. Empty id_flag survives stock /bin/bash (bash 3.2 empty-array guard) ----------
# Same unclassifiable-key path as 6b (id_flag=() empty), but pinned to stock
# /bin/bash. On macOS's /bin/bash 3.2.57 a bare "${id_flag[@]}" over an empty
# array aborts with `unbound variable` under `set -u`, killing the hook at exit 1
# before token-tally runs, so the whole tally is silently dropped; bash 4.4+
# never trips it. The rest of this suite runs under env bash (Homebrew bash 5),
# blind to the entire class, so only a run pinned to /bin/bash reproduces the
# regression. On a bash-5 /bin/bash (Linux CI) this simply passes; on a stock Mac
# it is the real gate. The hook is invoked as `/bin/bash <hook>` so its
# `#!/usr/bin/env bash` shebang (which would pick up bash 5) is bypassed.
@test "unclassifiable key under stock /bin/bash: empty id_flag does not abort the hook" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/specs/SPEC-099/plan"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  input=$("$HELPERS/mock-hook-input.sh" pre-tool-use "$SESSION" Bash "git commit -m x")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "echo '$input' | /bin/bash '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.partial' "$LEDGER")" = "true" ]
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
  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
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
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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
  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.partial' "$LEDGER")" = "true" ]
}

# ---------- 10. Worktree run: the plan folder lives ONLY in the main checkout ----------
# create-worktree.sh symlinks only shared state (cache/shared, audit, telemetry,
# setup-state.json, mentorship.json) into a linked worktree; it does NOT symlink
# .gaia/local/specs or .gaia/local/plans. So the RUNNING sentinel exists only in
# the main checkout and is invisible from a cwd-relative glob run in the worktree.
# The hook must anchor its plan search to the main checkout, or a plan executed in
# a worktree (the common /gaia-plan + orchestration path) records ZERO execute
# cost. Both the ledger and cost.json land in the surviving main checkout.
@test "worktree run: main-checkout plan folder is discovered; execute row lands in the main ledger" {
  MAIN="$(mktemp -d -t gaia-hook-test-XXXXXX)"
  MAIN="$(cd "$MAIN" && pwd -P)"   # normalize /var -> /private/var so path compares hold
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" commit -q --allow-empty -m "init"

  WT="$(dirname "$MAIN")/gaia-hook-wt-$$"
  git -C "$MAIN" worktree add -q "$WT" -b feature/kickoff

  # The hook resolves .claude/hooks/lib + .gaia/scripts repo-relative from its
  # own cwd (the worktree), so the worktree needs that scaffolding. It does NOT
  # get the plan folder: that lives only in the main checkout below.
  mkdir -p "$WT/.claude/hooks/lib" "$WT/.gaia/scripts"
  cp "$LIB_SRC" "$WT/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$WT/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$TALLY_SRC" "$WT/.gaia/scripts/token-tally.sh"
  chmod +x "$WT/.gaia/scripts/token-tally.sh"
  cp "$LIB_PRICING_SRC" "$WT/.gaia/scripts/token-pricing-lib.sh"
  cp "$LIB_LEDGER_PATH_SRC" "$WT/.gaia/scripts/ledger-path-lib.sh"

  # The plan folder + RUNNING sentinel live ONLY in the main checkout, keyed to
  # the worktree's branch (which is what a real worktree plan run looks like).
  plan_dir="$MAIN/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "feature/kickoff" "2026-07-01T00:00:00Z"

  input=$("$HELPERS/mock-hook-input.sh" pre-tool-use "$SESSION" Bash "git commit -m x")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "cd '$WT' && echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]

  MAIN_LEDGER="$MAIN/.gaia/local/telemetry/cost.jsonl"
  [ -f "$MAIN_LEDGER" ]
  [ "$(jq -r '.kind' "$MAIN_LEDGER")" = "execute" ]
  [ "$(jq -r '.spec_id' "$MAIN_LEDGER")" = "SPEC-013" ]
  [ "$(jq -r '.total' "$MAIN_LEDGER")" -eq 11110 ]
  # cost.json lands in the surviving main-checkout plan folder, not the worktree.
  [ -f "$plan_dir/cost.json" ]
  [ ! -f "$WT/.gaia/local/telemetry/cost.jsonl" ]

  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  [ -f "$MAIN_LEDGER" ]
}

# ---------- 11. Direct resolver unit: anchors to the main checkout from a worktree ----------
# Unit test of the shared resolver in isolation: sourced and called from a
# worktree cwd, with the RUNNING sentinel present only in the main checkout, it
# must return the absolute main-checkout plan dir. RED before the anchor fix (the
# cwd-relative glob finds nothing in the worktree and returns empty).
@test "resolve_active_plan_dir returns the main-checkout plan dir from a worktree cwd" {
  MAIN="$(mktemp -d -t gaia-hook-test-XXXXXX)"
  MAIN="$(cd "$MAIN" && pwd -P)"   # normalize /var -> /private/var so path compares hold
  git -C "$MAIN" init -q --initial-branch=main
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" commit -q --allow-empty -m "init"

  WT="$(dirname "$MAIN")/gaia-hook-wt-$$"
  git -C "$MAIN" worktree add -q "$WT" -b feature/kickoff

  # Colocated plan folder in the MAIN checkout only.
  plan_dir="$MAIN/.gaia/local/specs/SPEC-013/plan"
  write_readme_with_spec "$plan_dir" ".gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "feature/kickoff" "2026-07-01T00:00:00Z"

  run bash -c "cd '$WT' && . '$LIB_SRC' && resolve_active_plan_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$plan_dir" ]

  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
}
