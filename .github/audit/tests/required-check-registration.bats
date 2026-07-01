#!/usr/bin/env bats

# Regression guard for the GAIA-Audit required-check registration across the
# setup recipes (.claude/commands/gaia-init.md and setup-gaia.md).
#
# The merge gate keys on the GAIA-Audit COMMIT STATUS, not the
# code-review-audit JOB NAME. The audit job reaches a green terminal step on
# every path (including a local-mode stand-down where no audit ran), so
# registering the job name as the required check would let an unaudited PR
# merge through the github.com button.
#
# Division of responsibility between the two recipes:
#   - setup-gaia.md REGISTERS the check: it owns the literal
#     `required_status_checks` PUT with `contexts[]=GAIA-Audit`, run after the
#     first push once CI is being wired up.
#   - gaia-init.md DELEGATES that registration to /setup-gaia rather than
#     inlining the command; it touches nothing on GitHub and must NOT carry
#     the PUT itself.
# Neither recipe may register the bare code-review-audit job name.
#
# The recipes are prose, so the testable surface is the literal command
# strings (setup-gaia) and the delegation references (gaia-init).
#
# This suite lives under .github/audit/tests/ because that is the directory
# the CI bats runner (audit-ci-tests.yml, check name "bats (.github/audit)")
# executes.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GAIA_INIT="$REPO_ROOT/.claude/commands/gaia-init.md"
  SETUP_CI="$REPO_ROOT/.claude/commands/setup-gaia.md"
  [ -f "$GAIA_INIT" ] || skip "gaia-init.md not found"
  [ -f "$SETUP_CI" ] || skip "setup-gaia.md not found"
}

# -----------------------------------------------------------------------------
# gaia-init recipe delegates registration to /setup-gaia and inlines no
# registration command of its own.
# -----------------------------------------------------------------------------

@test "gaia-init delegates GAIA-Audit required-check registration to /setup-gaia" {
  run grep -F "/setup-gaia" "$GAIA_INIT"
  [ "$status" -eq 0 ]
  run grep -E "registers? the .GAIA-Audit. required check" "$GAIA_INIT"
  [ "$status" -eq 0 ]
}

@test "gaia-init does not inline the required_status_checks registration command" {
  run grep -F "protection/required_status_checks" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

@test "gaia-init does not register the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia recipe registers the GAIA-Audit status, not the job name, via
# the required_status_checks branch-protection endpoint.
# -----------------------------------------------------------------------------

@test "setup-gaia registers GAIA-Audit as the required check" {
  run grep -F "contexts[]=GAIA-Audit" "$SETUP_CI"
  [ "$status" -eq 0 ]
}

@test "setup-gaia registration targets the required_status_checks endpoint" {
  run grep -F "protection/required_status_checks" "$SETUP_CI"
  [ "$status" -eq 0 ]
}

@test "setup-gaia does not register the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$SETUP_CI"
  [ "$status" -ne 0 ]
}
