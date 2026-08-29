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
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABS="$REPO_ROOT/.husky/pre-commit"

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

# Assertion style: .claude/rules/bats-assertions.md.
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


@test "a change matching no lintable directory skips the gate" {
  stage_and_run "docs/notes.md"
  assert_gate_skipped
}

# --- every hook arm's directory is reachable by lint-staged ---
#
# The arms above and .lintstagedrc.json's globs are the two halves of one
# contract: an arm decides the gate runs, a glob decides lint-staged has
# anything to hand ESLint. An arm no glob covers is the silent half of the
# failure mode the header describes: the hook prints "running lint-staged",
# lint-staged matches zero files and exits 0, and the commit lands with ESLint
# skipped for that whole directory while typecheck and Vitest still report.
#
# The arm set is derived from the hook rather than restated here, and the count
# of directories the derivation yields is checked against the number of arm
# assignments, so an arm whose spelling drifts stops the guard rather than
# quietly shrinking it.
#
# What this covers and what it does not. The reverse direction, a glob whose
# directory no arm names, is pinned by the per-directory @tests above rather
# than derived; deriving it too is tracked as #1628.

# Every directory the hook's change-detection arms grep for, one per line.
arm_dirs() {
  sed -n "s/^HAS_[A-Z0-9_]*_CHANGED=.*| grep '\\([^']*\\)'.*/\\1/p" "$HOOK_ABS"
}

# Every arm assignment, counted by a pattern deliberately wider than the two
# derivations read. A count taken with the same pattern as the extraction agrees
# with it on every name the pattern cannot spell, so the two readings would
# confirm each other's blind spot instead of exposing it; this one over-counts
# rather than under-counts, so an arm neither derivation can read reds the guard.
arm_assignment_count() {
  grep -c '^HAS_[A-Za-z0-9_]*=' "$HOOK_ABS"
}

# The lint-staged glob keys whose task chain actually invokes ESLint. Reading
# the keys alone would accept a chain that runs only prettier or stylelint,
# which is the very outcome the arm is supposed to prevent; two such chains
# already live in this config.
eslint_globs() {
  jq -r 'to_entries[]
         | select(any(.value[]?; type == "string" and startswith("eslint")))
         | .key' "$REPO_ROOT/.lintstagedrc.json"
}

# Whether one glob key hands ESLint the files under directory $1.
#
# This asks for the literal shape `<dir>/**/<rest>`, in the key itself or in one
# alternative of its leading brace group, rather than matching a probe path
# against the key. Matching would need lint-staged's own matcher: bash's [[ ]]
# lets `*` cross a `/` where picomatch does not, so `app/*.{ts,tsx}` would
# satisfy a probe while leaving app/routes/home.tsx unlinted, which is exactly
# the miss this guard exists to catch. Demanding the recursive shape is the
# narrower question, and it fails closed: a key written some other way reds the
# guard rather than passing it.
glob_covers_dir() {
  local dir="$1" glob="$2" head alt
  case "$glob" in
    *"/**/"*) head="${glob%%/\*\*/*}" ;;
    *) return 1 ;;
  esac
  case "$head" in
    "{"*"}")
      head="${head#\{}"; head="${head%\}}"
      while IFS= read -r alt; do
        [ "$alt/" = "$dir" ] && return 0
      done <<<"$(printf '%s' "$head" | tr ',' '\n')"
      return 1
      ;;
    *) [ "$head/" = "$dir" ] && return 0; return 1 ;;
  esac
}

@test "every pre-commit arm directory is covered by an ESLint lint-staged glob" {
  local dirs globs derived assignments dir glob covered
  dirs=$(arm_dirs)
  derived=$(printf '%s\n' "$dirs" | grep -c . || true)
  assignments=$(arm_assignment_count)
  [ "$derived" -gt 0 ]
  [ "$derived" -eq "$assignments" ]

  # Captured rather than piped, so a jq that is absent or cannot parse the
  # config reports itself instead of emptying the loop below and blaming the
  # first arm for an uncovered directory.
  globs=$(eslint_globs) || {
    printf 'could not read .lintstagedrc.json (is jq installed?)\n' >&2
    return 1
  }
  [ -n "$globs" ] || {
    printf '.lintstagedrc.json declares no glob whose chain invokes eslint\n' >&2
    return 1
  }

  while IFS= read -r dir; do
    covered=0
    while IFS= read -r glob; do
      if glob_covers_dir "$dir" "$glob"; then covered=1; fi
    done <<<"$globs"
    if [ "$covered" -ne 1 ]; then
      printf 'hook arm %s has no ESLint .lintstagedrc.json glob\n' "$dir" >&2
      return 1
    fi
  done <<<"$dirs"
}

# An arm assignment that never reaches the OR guard is dead: the directory looks
# armed at the top of the hook and decides nothing. The assignment names are
# derived from the same lines the guard above reads, so an arm added without a
# term reds here instead of passing both checks.
@test "every pre-commit arm assignment is read by the change-detection guard" {
  local names name guard
  names=$(sed -n 's/^\(HAS_[A-Z0-9_]*_CHANGED\)=.*/\1/p' "$HOOK_ABS")
  [ -n "$names" ]
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq "$(arm_assignment_count)" ]
  guard=$(grep -n '^if \[ -n "\$HAS_' "$HOOK_ABS")
  [ -n "$guard" ]
  while IFS= read -r name; do
    if ! grep -qF -- "\$$name" <<<"$guard"; then
      printf 'arm %s is assigned but never read by the guard\n' "$name" >&2
      return 1
    fi
  done <<<"$names"
}
