#!/usr/bin/env bats

# Tests for .husky/pre-commit.
#
# The hook decides whether a staged change is lint-worthy and runs the Quality
# Gate floor (pnpm typecheck / lint-staged / test:lint-staged) only when it is.
# That decision is a set of `git diff --cached` greps, one arm per lintable
# directory, OR-ed into a single guard. A directory that .lintstagedrc.json
# covers but no arm names is the live failure mode: a commit scoped to that
# directory alone matches nothing, the else branch fires, and the change lands
# unlinted and untypechecked.
#
# Husky runs the hook as `sh -e <hook>` (.husky/_/h), so these tests do too.
# The `|| true` tail on each grep is load-bearing under -e, and running the
# hook any other way would not exercise it.
#
# `pnpm` is stubbed onto PATH as a recorder, so the tests assert on which gate
# steps the hook invoked rather than on their real output. The suite needs no
# node_modules and stays fast.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.husky" && pwd)/pre-commit

  REPO=$(mktemp -d -t husky-pre-commit-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # Every stub invocation appends its argv and succeeds, so the hook runs to
  # completion under `sh -e` and each test reads back which steps fired.
  PNPM_LOG="$REPO/pnpm.log"
  STUB_BIN="$REPO/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
  : > "$PNPM_LOG"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Stage one file at a repo-relative path, then run the hook from the repo root
# the way husky does.
stage_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABS"
}

# Commit one file, then stage its deletion and run the hook. A deletion-only
# commit is the arm-agnostic case: it matches an arm only when that arm's
# --diff-filter carries `D`.
stage_deletion_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit --quiet -m "add $path"
  git -C "$REPO" rm --quiet "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABS"
}

# Substring assertions use grep, not `[[ ]]`: a false bare `[[ ]]` that is not
# the test's last command does not fail the test on bash 3.2, which is what a
# stock macOS bats resolves to. See .claude/rules/bats-assertions.md.
assert_gate_ran() {
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"
  grep -qx 'typecheck' "$PNPM_LOG"
  grep -qx 'exec lint-staged' "$PNPM_LOG"
  grep -qx 'test:lint-staged' "$PNPM_LOG"
}

assert_gate_skipped() {
  [ "$status" -eq 0 ]
  grep -qF -- "skipping lint-staged" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

# --- a change in a lintable directory runs the gate ---

@test "app/ change runs the gate" {
  stage_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ change runs the gate" {
  stage_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ change runs the gate" {
  stage_and_run ".storybook/preview.ts"
  assert_gate_ran
}

# .lintstagedrc.json lints {.storybook,.playwright}/**/*.{ts,tsx}, so the
# .playwright half needs an arm of its own; without one that entry is
# unreachable for an e2e-spec-only commit, the most common .playwright shape.
@test ".playwright/ change runs the gate" {
  stage_and_run ".playwright/e2e/home.spec.ts"
  assert_gate_ran
}

# --- a deletion in a lintable directory runs the gate ---
#
# Deleting a shared helper, fixture, or spec breaks the types of every file that
# imported it, which is exactly what the skipped `pnpm typecheck` would catch.
# All four arms therefore carry `D`; these tests pin that agreement so a future
# edit cannot narrow one arm back without a failure.

@test "app/ deletion runs the gate" {
  stage_deletion_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ deletion runs the gate" {
  stage_deletion_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ deletion runs the gate" {
  stage_deletion_and_run ".storybook/preview.ts"
  assert_gate_ran
}

@test ".playwright/ deletion runs the gate" {
  stage_deletion_and_run ".playwright/e2e/home.spec.ts"
  assert_gate_ran
}

# --- a change outside every lintable directory skips the gate ---

@test "a change matching no lintable directory skips the gate" {
  stage_and_run "docs/notes.md"
  assert_gate_skipped
}
