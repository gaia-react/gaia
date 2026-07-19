#!/usr/bin/env bats
# Tests for .gaia/tests/shell-lint.sh: assert the deterministic local shell gate
# folds the hook array-guard (.gaia/scripts/lint-hook-array-guard.sh) into its
# run, so every shell-lint caller enforces the bash-3.2 empty-array-abort class
# locally, not only the bats (.github/audit) CI job. The detector's own
# correctness is covered by lint-hook-array-guard.bats; this suite covers the
# wiring.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no shellcheck)
# and stays fast: the only real work left is the array-guard scanning the real
# .claude/hooks tree, which lint-hook-array-guard.bats already asserts clean.
#
# Assertion style (.claude/rules/bats-assertions.md): grep -qF / [ ], never a
# bare [[ ]] as a non-final line.

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
exit 0
STUB
  chmod +x "$STUB_DIR/shellcheck"
}

teardown() {
  [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  return 0
}

# ---------------------------------------------------------------------------
# The gate runs the hook array-guard as one of its passes and reports it.
# ---------------------------------------------------------------------------

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
