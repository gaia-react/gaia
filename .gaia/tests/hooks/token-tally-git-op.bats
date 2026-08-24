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
  LIB_MAIN_ROOT_SRC="$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  LIB_AUDIT_WINDOW_SRC="$REPO_ROOT/.gaia/scripts/audit-window-lib.sh"
  VERB_ARMING_SRC="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  VERB_ARMING_WALK_SRC="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  REPO_SCOPE_SRC="$REPO_ROOT/.claude/hooks/lib/repo-scope.sh"
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
  cp "$LIB_MAIN_ROOT_SRC" "$REPO/.gaia/scripts/main-root-lib.sh"
  cp "$LIB_AUDIT_WINDOW_SRC" "$REPO/.gaia/scripts/audit-window-lib.sh"
  cp "$VERB_ARMING_SRC" "$REPO/.claude/hooks/lib/verb-arming.sh"
  cp "$VERB_ARMING_WALK_SRC" "$REPO/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_SCOPE_SRC" "$REPO/.claude/hooks/lib/repo-scope.sh"
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

# UAT-001
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

# ---------- 2a. git -C <path> form (shell-cwd.md mandated form, issue #770) ----------
@test "git -C <path> commit records an execute record (shell-cwd.md mandated form)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git -C /abs/worktree commit -m x"
  [ "$status" -eq 0 ]

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.kind' "$LEDGER")" = "execute" ]
  [ "$(jq -r '.spec_id' "$LEDGER")" = "SPEC-013" ]
}

@test "git -C <path> push also records" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git -C /abs/worktree push"
  [ "$status" -eq 0 ]

  LEDGER="$REPO/.gaia/local/telemetry/cost.jsonl"
  [ -f "$LEDGER" ]
  [ "$(jq -r '.kind' "$LEDGER")" = "execute" ]
}

@test "git -C <path> status: no record (commit/push-only matching preserved)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook "git -C /abs/worktree status"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "git -C \"<path>\" commit (quoted path) records an execute record" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  run_hook 'git -C "/abs/worktree" commit -m x'
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

# ---------- 8b. Shared arming decision (data proof, bound, tokenizer) ----------

@test "a real git commit heredoc body (cat-to-file) is proven data: no record" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\ngit commit -m x\nEOF'
  run_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]

  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "the same heredoc-body payload padded past the arming bound does record" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  local pad heredoc_cmd
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngit commit -m x\nEOF'
  [ "${#heredoc_cmd}" -gt 16384 ] || return 1

  run_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "a quoted verb in the first command records (tokenizer arm; red before this change)" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook 'git "commit" -m x'
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "a multi-statement command still records (no regression)" {
  build_repo
  cd "$REPO"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"

  run_hook "echo start && git commit -m x"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
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

# The fixture's worktree is deliberately never linked, so it has no .gaia/local of
# its own at all. The RUNNING sentinel therefore exists only in the main checkout
# and is invisible to a cwd-relative glob run in the worktree.
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
  cp "$LIB_MAIN_ROOT_SRC" "$WT/.gaia/scripts/main-root-lib.sh"

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

# ---------- 10. The never-blocks contract when a shared lib is unusable ----------
# These run a COPY of the hook staged inside the tmp repo, so the lib directory
# it resolves off BASH_SOURCE, and the .gaia/scripts beside it, are ones the
# test controls. Running $HOOK_ABS would always resolve the real checkout's
# libs, where neither the absent nor the unparseable case can be expressed.
#
# Two ways a lib goes unusable, and the hook must survive both: it is gone, and
# it is present but does not parse (an unresolved merge conflict, a truncated
# write). Under `set -e` a failed `.` aborts the shell ahead of the hook's ERR
# trap in both cases, at different cost: a file bash cannot open exits 1, an
# advisory that loses the tally row and lets the commit through, while one it
# cannot parse exits 2, the deny code, refusing the very commit that would
# repair the lib.
#
# The controls are what give the absent and unparseable cases teeth: their
# three assertions (exit 0, no output, no ledger row) are equally satisfied by
# a hook that does nothing at all, so each interpreter gets a control proving
# the same staging records normally.
stage_hook_repo() {
  build_repo
  STAGED_HOOK="$REPO/.claude/hooks/token-tally-git-op.sh"
  cp "$HOOK_ABS" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

run_staged_hook() {
  # run_staged_hook <command> [interpreter]
  local input interp="${2:-}"
  input=$("$HELPERS/mock-hook-input.sh" pre-tool-use "$SESSION" Bash "$1")
  run env GAIA_TALLY_PROJECTS_ROOT="$ANCHOR" bash -c "echo '$input' | $interp '$STAGED_HOOK'"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

# Scaffolds the staged repo with an active plan folder keyed to its branch, the
# state every case below shares. Sets $plan_dir.
stage_with_plan() {
  stage_hook_repo
  cd "$REPO" || return 1
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-013/SPEC.md"
  write_running "$plan_dir" "$(git branch --show-current)" "2026-07-01T00:00:00Z"
}

@test "staged hook, every lib usable: records (control)" {
  stage_with_plan

  run_staged_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.kind' "$REPO/.gaia/local/telemetry/cost.jsonl")" = "execute" ]
}

# The stock-/bin/bash control. Without it the two /bin/bash-pinned cases below
# would stay green if the hook stopped recording entirely under 3.2, which is
# exactly the class the empty-array case above exists to catch.
@test "staged hook under stock /bin/bash, every lib usable: records (control)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_with_plan

  run_staged_hook "git commit -m x" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.kind' "$REPO/.gaia/local/telemetry/cost.jsonl")" = "execute" ]
}

@test "staged hook in a checkout lacking gaia-active-plan.sh: exit 0, no output, no record" {
  stage_with_plan
  rm -f "$REPO/.claude/hooks/lib/gaia-active-plan.sh"

  run_staged_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

# Pinned to stock /bin/bash: on 3.2.57 the shell abandons on the failed source
# before a trailing `||` arm on that line runs, where 5.x reaches it, so only a
# /bin/bash run reproduces this half of the class on a stock Mac. On a bash-5
# /bin/bash (Linux CI) it passes either way, the same honest caveat the
# empty-array case above carries.
@test "staged hook in a checkout lacking main-root-lib.sh under stock /bin/bash: exit 0, no output, no record" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_with_plan
  rm -f "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "git commit -m x" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

# Pinned to stock /bin/bash for the same reason the absent case above is, and
# it is the pin rather than the failure mode that decides: the form this load
# replaced already survived an unparseable lib on bash 5 (its `|| exit 0` arm
# runs there), so only 3.2 tells the parse check apart from it. On a bash-5
# /bin/bash this passes either way. The gaia-active-plan sibling below needs no
# pin, because the form IT replaced carried no arm at all and dies on both.
@test "staged hook whose main-root-lib.sh holds conflict markers, under stock /bin/bash: exit 0, no output, no record" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_with_plan
  write_conflicted_lib "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "git commit -m x" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

@test "staged hook whose gaia-active-plan.sh holds conflict markers: exit 0, no output, no record" {
  stage_with_plan
  write_conflicted_lib "$REPO/.claude/hooks/lib/gaia-active-plan.sh"

  run_staged_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

# The pre-gate verb-arming load takes `|| true` rather than a parse check, so
# only the bash-5 half of the unparseable case is closed. Unpinned on purpose:
# the bare source it replaced dies on both shells, so this reds on Linux CI.
# The 3.2 half stays open by decision, not by oversight, and no test here
# asserts otherwise; the hook's own load comment names it.
@test "staged hook whose verb-arming.sh holds conflict markers: exit 0, no output, no record" {
  stage_with_plan
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  run_staged_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$REPO/.gaia/local/telemetry/cost.jsonl" ]
}

# ---------- 11. The tally invocation resolves off BASH_SOURCE, not the cwd ----------
# Every gate ahead of the invocation is cwd-independent (gaia_resolve_main_root
# is git-based, resolve_active_plan_dir anchors off BASH_SOURCE), so a hook run
# whose cwd is a repo SUBDIRECTORY reaches it with every gate satisfied. A
# cwd-relative `bash .gaia/scripts/token-tally.sh` finds nothing there, and the
# trailing `|| true` on the invocation discards the status, so the execute row
# is lost with no diagnostic. `.claude/rules/shell-cwd.md` records that a `cd`
# in a Bash tool call persists for the rest of the session, which is how a
# non-root hook cwd arises in practice. Every other case in this file runs with
# cwd = the tmp repo root, where a relative and an absolute path agree.
@test "staged hook run from a repo subdirectory: records (tally path is cwd-independent)" {
  stage_with_plan
  mkdir -p "$REPO/app/components"
  cd "$REPO/app/components" || return 1

  run_staged_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.kind' "$REPO/.gaia/local/telemetry/cost.jsonl")" = "execute" ]
}
