#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` expansions and the quoted handler literals reach the fixture file as
# literal text. The unexpanded handler IS the thing under test, so letting the
# shell expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-collapsed-signal-trap.sh: the static gate that
# flags a single `trap` arm binding EXIT together with INT or TERM, the shape
# that makes a script uninterruptible because bash resumes at the point of
# interruption once the handler returns.
#
# Three jobs. Prove the detector fires on the class, in every spelling bash
# accepts for the three signals; prove it stays quiet on each legitimate shape,
# which for this gate is the load-bearing half, because the repair the gate's own
# hint text advertises is three trap calls of its own and a naive detector reds
# on all three; and assert the real scanned tree is clean so a regression fails
# CI.
#
# Two tests are load-bearing beyond coverage. "reds against the historical
# with-ledger-lock shape" carries the exact line gaia-react/gaia#1717 was filed
# against, so the gate is proven to reach the instance it was written for rather
# than a tidied stand-in. And "quiet on the three-arm repair" carries the exact
# shape the gate prints as its fix hint, so a gate that reds on its own advice
# cannot ship.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-collapsed-signal-trap.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo_bare: an initialized git repo in $TMP with no files yet and no
# seeded surface. Point a test that needs an empty scan set here.
fixture_repo_bare() {
  TMP="$(mktemp -d -t collapsed-trap-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_repo: fixture_repo_bare with one benign tracked file on each of the
# guard's two independently-discovered surfaces. Both hard-error when their own
# discovery comes back empty, so an ordinary fixture needs both already in place
# to reach this guard's class detection at all; seeding only one leaves every
# test on the other surface failing on the empty-set error rather than on the
# class. The shell seed is `seed.sh` rather than `check.sh` so fixture_script
# below can overwrite the latter without emptying the surface.
fixture_repo() {
  fixture_repo_bare
  fixture_file seed.sh 'true'
  fixture_file seed.bats '@test "seed" { true; }'
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so the body reaches the file
# as the characters the gate is meant to read. Call fixture_repo first.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_script <body>: the common case, a tracked shell script.
fixture_script() {
  fixture_file check.sh "$1"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the class fires -------------------------------------------------------

@test "reds against the historical with-ledger-lock shape" {
  fixture_repo
  fixture_script "  trap '_with_ledger_lock_release' EXIT INT TERM"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
  grep -qF -- "binds EXIT together with INT or TERM" <<<"$output"
}

@test "flags EXIT paired with INT alone" {
  fixture_repo
  fixture_script 'trap cleanup EXIT INT'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags EXIT paired with TERM alone, in either order" {
  fixture_repo
  fixture_script 'trap cleanup TERM EXIT'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags the SIG-prefixed spelling" {
  fixture_repo
  fixture_script 'trap "cleanup" EXIT SIGINT SIGTERM'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags the numeric spelling, where 0 is EXIT and 2 is INT" {
  fixture_repo
  fixture_script 'trap "cleanup" 0 2 15'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags the lowercase spelling bash also accepts" {
  fixture_repo
  fixture_script 'trap cleanup exit int term'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags an empty handler, the deliberate-ignore form of the same shape" {
  fixture_repo
  fixture_script 'trap "" EXIT INT TERM'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags an indented arm inside a function body" {
  fixture_repo
  fixture_script 'f() {
  trap "release" EXIT INT TERM
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:2:" <<<"$output"
}

@test "flags an arm following a statement separator" {
  fixture_repo
  fixture_script 'mkdir -p "$d" && trap cleanup EXIT INT'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags an arm whose handler literal mentions a signal name of its own" {
  fixture_repo
  fixture_script 'trap "echo INT >&2; rmdir \"$d\"" EXIT INT TERM'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
}

@test "flags an arm inside a workflow run: block, which no *.sh glob reaches" {
  fixture_repo
  fixture_file .github/workflows/ci.yml 'jobs:
  build:
    steps:
      - run: |
          trap cleanup EXIT INT TERM'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/ci.yml:5:" <<<"$output"
}

@test "flags an arm in an adopter workflow template, one distribution hop out" {
  fixture_repo
  fixture_file .gaia/cli/src/automation/templates/workflows/ci.yml.tmpl '      - run: trap cleanup EXIT TERM'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "templates/workflows/ci.yml.tmpl:1:" <<<"$output"
}

@test "flags an arm in a composite action, which the workflow glob misses" {
  fixture_repo
  fixture_file .github/actions/probe/action.yml 'runs:
  steps:
    - run: trap cleanup EXIT INT'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/actions/probe/action.yml:3:" <<<"$output"
}

@test "flags an arm in an extensionless husky hook" {
  fixture_repo
  fixture_file .husky/pre-commit 'trap cleanup EXIT INT'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".husky/pre-commit:1:" <<<"$output"
}

@test "flags an executed arm in a bats suite, outside any fixture region" {
  fixture_repo
  fixture_file probe.bats '@test "t" {
  trap cleanup EXIT INT TERM
  true
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.bats:2:" <<<"$output"
}

# --- the legitimate shapes stay quiet --------------------------------------

@test "quiet on the three-arm repair the gate itself advertises" {
  fixture_repo
  fixture_script 'trap "rm -f -- $tmp" EXIT
trap "exit 130" INT
trap "exit 143" TERM'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a lone EXIT arm" {
  fixture_repo
  fixture_script 'trap "rm -rf $work" EXIT'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a lone INT and TERM pair, which shares no EXIT arm" {
  fixture_repo
  fixture_script 'trap cleanup INT TERM'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on an ERR arm, which is not this class" {
  fixture_repo
  fixture_script 'trap "exit 0" ERR'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on trap - SIGSPEC, which restores the default disposition" {
  fixture_repo
  fixture_script 'trap - EXIT INT TERM'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on trap -p, a query that installs nothing" {
  fixture_repo
  fixture_script 'saved="$(trap -p EXIT)"
printf %s "$saved"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a full-line comment showing the collapsed shape" {
  fixture_repo
  fixture_script '# trap cleanup EXIT INT TERM is the shape this gate forbids
true'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a grep pattern naming the class, which is data not a call" {
  fixture_repo
  fixture_script 'grep -qE "^[[:space:]]*trap .* EXIT INT TERM$" "$f"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a longer identifier that merely contains the command name" {
  fixture_repo
  fixture_script 'strap_cleanup EXIT INT TERM
trapdoor EXIT INT'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a fixture literal in a bats suite, per the shared discriminator" {
  fixture_repo
  fixture_file probe.bats 'fixture_script "trap cleanup EXIT INT TERM"
@test "t" { true; }'
  run_linter
  [ "$status" -eq 0 ]
}

# --- discovery is armed, not merely correct --------------------------------

@test "an empty scan set is a hard error, never a clean tree" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output" || return 1
  # Names the sets this gate asked for, not the phrase every empty-surface
  # message carries: the bats error below carries it too, and would other-
  # wise green this test over a scan discovery that reported clean over
  # nothing.
  grep -qF -- "the scan surface (shell husky workflows)" <<<"$output"
}

@test "a tree with tracked shell but no bats suite is a hard error" {
  fixture_repo_bare
  fixture_script 'true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "no tracked bats suites matched" <<<"$output"
}

@test "an untracked file carrying the class is not scanned" {
  fixture_repo
  printf '%s\n' 'trap cleanup EXIT INT TERM' > "$TMP/untracked.sh"
  run_linter
  [ "$status" -eq 0 ]
}

# --- the real tree ---------------------------------------------------------

@test "the real scanned tree passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
