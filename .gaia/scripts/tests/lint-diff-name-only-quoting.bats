#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-diff-name-only-quoting.sh: the static gate that
# flags an executed `git diff --name-only` which omits `-z`, so git's default
# `core.quotePath` cannot C-quote a path the caller then parses.
#
# Two jobs, the same pair the sibling array-guard suite carries: prove the
# detector fires on a known-bad fixture in each scanned file type (shell, husky
# hook, workflow YAML) and stays quiet on every legitimate shape (a `-z` call,
# a comment, a markdown code span, a string constant, an untracked file), and
# assert the real scanned tree is clean so a regression fails CI.
#
# One test is load-bearing beyond coverage. `#1229`'s Suggested fix makes it
# binding that the guard red against a historical site in its PRE-FIX form, or
# it asserts nothing about the class it was written for; "reds against the
# pre-fix worthiness-presence-check.sh derivation" is that test.
#
# Assertion style (.claude/rules/bats-assertions.md): grep -qF / [ ] / an
# explicit `return 1`, never a bare [[ ]] as a non-final line, and never a
# `!`-negated absence assertion off the final line.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. That is also
# what pins the untracked-file test below: an untracked script is not scanned.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-diff-name-only-quoting.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo: an initialized git repo in $TMP with no files yet.
fixture_repo() {
  TMP="$(mktemp -d -t diff-quoting-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_file <relpath> <body>: write <body> to $TMP/<relpath> and track it.
# Call fixture_repo first.
fixture_file() {
  mkdir -p "$TMP/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/$1"
  git -C "$TMP" add -f -- "$1"
}

# run_linter: run the gate from the fixture root, where its cwd-relative
# `git ls-files` resolves.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER'"
}

# ---------------------------------------------------------------------------
# 1. The real scanned tree is clean (regression gate)
# ---------------------------------------------------------------------------

@test "the real scanned tree (shell + husky + workflow YAML) passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. The detector fires, once per scanned file type
# ---------------------------------------------------------------------------

@test "flags an unquoted diff --name-only in a shell script" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
  grep -qF -- "-z" <<<"$output"
}

@test "flags an unquoted diff --name-only in a husky hook" {
  fixture_repo
  fixture_file .husky/pre-commit $'#!/usr/bin/env sh\nchanged=$(git diff --name-only HEAD~1...HEAD)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".husky/pre-commit:2" <<<"$output"
}

@test "flags an unquoted diff --name-only in a workflow YAML run block" {
  fixture_repo
  fixture_file .github/workflows/ci.yml $'jobs:\n  a:\n    steps:\n      - run: |\n          changed=$(git diff --name-only "${BASE}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/ci.yml:5" <<<"$output"
}

# The binding test. `#1229`'s Suggested fix: whichever guard lands must be shown
# to red against at least one of the four historical sites in its pre-fix form.
# This is .claude/hooks/worthiness-presence-check.sh:169 as it stood before
# PR #1227 fixed it.
@test "reds against the pre-fix worthiness-presence-check.sh derivation" {
  fixture_repo
  fixture_file .claude/hooks/worthiness-presence-check.sh \
    $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/worthiness-presence-check.sh:2" <<<"$output"
}

@test "flags every unquoted call on a line, not only the first" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\na=$(git diff --name-only "$X") ; b=$(git diff --name-only "$Y")'
  run_linter
  [ "$status" -eq 1 ]
  [ "$(grep -cF -- "probe.sh:2" <<<"$output")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 3. Legitimate shapes are NOT flagged
# ---------------------------------------------------------------------------

@test "a call carrying -z passes" {
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nchanged="$(git diff --name-only -z "${base}...HEAD" 2>/dev/null | tr \'\\0\' \'\\n\' || true)"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a git -C form is recognized as an invocation and still checked" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only -z "${base}...HEAD" | tr \'\\0\' \'\\n\')"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a git -C form missing -z is flagged" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only "${base}...HEAD")"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

@test "a full-line comment is skipped" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\n# changed=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 0 ]
}

# The false positive that would otherwise fire on
# .github/workflows/code-review-audit.yml:486, where an agent prompt names the
# command inside a markdown code span.
@test "a call inside a markdown code span is prose, not an invocation" {
  fixture_repo
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          echo "1. Run `git diff --name-only origin/main...HEAD` first."'
  run_linter
  [ "$status" -eq 0 ]
}

# The false positive that would otherwise fire on
# .gaia/scripts/check-audit-base-derivation.sh:278, where the call is the VALUE
# of a fixed-string variable rather than an invocation.
@test "a string constant that is not a git invocation is skipped" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nGAIA_AUDIT_DIFF_CALL=\'diff --name-only\''
  run_linter
  [ "$status" -eq 0 ]
}

# `-z` must sit immediately after the call. Unanchored, a pathspec carrying the
# token would vouch for a call that still quotes -- the same discrimination
# assertion 4 in check-audit-base-derivation.sh makes, and for the same reason.
@test "a -z appearing later in the call does not vouch for it" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" -- "docs/a -z b.md")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

@test "an untracked script is not scanned" {
  fixture_repo
  mkdir -p "$TMP"
  printf '%s\n' $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")' > "$TMP/untracked.sh"
  run_linter
  [ "$status" -eq 0 ]
}

# The scan surface stops at shell, husky hooks and workflow YAML. The bats
# suites are deliberately outside it: check-audit-base-derivation.bats carries
# five intentionally-unquoted agent-prose fixtures for assertion 4, and five
# sibling suites run an unquoted `diff --name-only` under `core.quotePath=true`
# as the positive control proving the hazard is real. A scanner reading raw
# lines cannot tell those from an executed call, and "fixing" them would delete
# the evidence the class exists.
@test "a bats suite is outside the scan surface" {
  fixture_repo
  fixture_file probe.bats $'@test "x" {\n  quoted="$(git diff --name-only "${base}...HEAD")"\n}'
  run_linter
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. Reporting contract
# ---------------------------------------------------------------------------

@test "a clean tree reports clean and exits 0" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\necho hello'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "the report names the fix idiom" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "tr " <<<"$output"
}
