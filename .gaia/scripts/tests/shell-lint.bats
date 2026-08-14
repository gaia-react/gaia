#!/usr/bin/env bats
# Tests for .gaia/tests/shell-lint.sh: assert the deterministic local shell gate
# folds the hook array-guard (.gaia/scripts/lint-hook-array-guard.sh) into its
# run, so every shell-lint caller enforces the bash-3.2 empty-array-abort class
# locally, not only the Audit CI Tests job. The detector's own
# correctness is covered by lint-hook-array-guard.bats; this suite covers the
# wiring.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no shellcheck)
# and stays fast: the only real work left is the array-guard scanning the real
# .claude/hooks tree, which lint-hook-array-guard.bats already asserts clean.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GATE="$REPO_ROOT/.gaia/tests/shell-lint.sh"
  # A clean, pinned-version shellcheck stub lets the gate clear both shellcheck
  # passes and reach the array-guard pass without a real shellcheck binary. Its
  # `version:` tracks SHELLCHECK_PIN in shell-lint.sh; a stale stub after a pin
  # bump only makes the gate emit a non-fatal version-drift WARN (stderr, no
  # exit-status change), so this suite still passes -- keep them in sync anyway.
  STUB_DIR="$(mktemp -d -t shell-lint-stub-XXXXXX)"
  cat > "$STUB_DIR/shellcheck" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
# Record one line per invocation when a log path is set, so a test can assert
# which files a pass linted and with which dialect. Unset by default, so the
# stub stays a pure always-clean fake for every other test.
if [ -n "${SHELLCHECK_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SHELLCHECK_LOG"
fi
# Report a finding for exactly one named file, so a test can place a failure in
# a chosen worker's chunk. Quoted inside the pattern, so a path is matched
# literally rather than as a glob. Unset by default.
if [ -n "${SHELLCHECK_FAIL_ON:-}" ]; then
  case " $* " in
    *" $SHELLCHECK_FAIL_ON "*)
      printf 'In %s line 1:\nSC9999 (error): stub finding\n' "$SHELLCHECK_FAIL_ON"
      exit 1
      ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUB_DIR/shellcheck"
}

teardown() {
  [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  return 0
}

# The gate runs the hook array-guard as one of its passes and reports it.

@test "shell-lint folds in the hook array-guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # Grep the guard's OWN stderr proof line, not shell-lint's header echo: this
  # string is printed by lint-hook-array-guard.sh itself, so it appears only if
  # the guard actually ran, catching a future edit that drops the invocation but
  # leaves the header.
  grep -qF -- "lint-hook-array-guard: clean" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output"
}

# The same wiring assertion for the diff-quoting guard. Its own correctness is
# covered by lint-diff-name-only-quoting.bats; this covers only that the gate
# still invokes it, which is the class the sibling assertion above exists for.

@test "shell-lint folds in the diff-quoting guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-diff-name-only-quoting: clean" <<<"$output"
}

# The same wiring assertion for the workflow run-interpolation guard. Its own
# correctness is covered by lint-workflow-run-interpolation.bats; this covers
# only that the gate still invokes it.

@test "shell-lint folds in the workflow run-interpolation guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-workflow-run-interpolation: clean" <<<"$output"
}

# The husky hooks are extensionless, so they match neither the *.sh nor the
# *.bats discovery glob and need a pass of their own. Husky runs them as
# `sh -e`, so that pass pins the dialect: shellcheck takes one dialect per
# invocation, which is why this cannot fold into the *.sh pass.

@test "shell-lint lints the tracked husky hooks as sh" {
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_LOG="$STUB_DIR/argv.log" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qE -- '(^| )-s sh( |$).*\.husky/pre-commit' "$STUB_DIR/argv.log"
}

# The *.sh and *.bats passes split their file list across concurrent shellcheck
# workers, one buffered log each. Two ways that aggregation goes green over a
# real finding, and one test for each end of the list: collecting the status of
# only the last worker (what a bare `wait` returns), and collecting the status of
# only the first. The gate discovers files in `git ls-files` order and slices
# that list contiguously, so the first tracked path is always in the first
# worker's chunk and the last is always in the last worker's. On a single-core
# host both tests still assert the finding fails the gate, just without
# distinguishing the two workers.

@test "shell-lint fails closed on a finding in the FIRST worker's chunk" {
  first_sh="$(git -C "$REPO_ROOT" ls-files '*.sh' | head -n 1)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$first_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  # The failing worker's buffered log has to replay too, or the gate reds
  # without ever naming what is broken.
  grep -qF -- "In $first_sh line 1:" <<<"$output"
}

@test "shell-lint fails closed on a finding in the LAST worker's chunk" {
  last_sh="$(git -C "$REPO_ROOT" ls-files '*.sh' | tail -n 1)"
  [ -n "$last_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$last_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "In $last_sh line 1:" <<<"$output"
}
