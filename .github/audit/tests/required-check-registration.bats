#!/usr/bin/env bats

# Regression guard for the GAIA-Audit required-check registration in the
# setup recipes (.claude/commands/gaia-init.md and setup-gaia-ci.md).
#
# The merge gate keys on the GAIA-Audit COMMIT STATUS, not the
# code-review-audit JOB NAME. The audit job reaches a green terminal step on
# every path (including a local-mode stand-down where no audit ran), so
# registering the job name as the required check would let an unaudited PR
# merge through the github.com button. Both setup recipes must register the
# GAIA-Audit status context and must NOT register the bare code-review-audit
# job name as the required-status-checks context.
#
# The recipes are prose, so the testable surface is the literal registration
# command string. These greps assert the GAIA-Audit context is present and the
# bare `contexts[]=code-review-audit` registration is gone.
#
# This suite lives under .github/audit/tests/ because that is the directory
# the CI bats runner (audit-ci-tests.yml, check name "bats (.github/audit)")
# executes.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GAIA_INIT="$REPO_ROOT/.claude/commands/gaia-init.md"
  SETUP_CI="$REPO_ROOT/.claude/commands/setup-gaia-ci.md"
  [ -f "$GAIA_INIT" ] || skip "gaia-init.md not found"
  [ -f "$SETUP_CI" ] || skip "setup-gaia-ci.md not found"
}

# -----------------------------------------------------------------------------
# gaia-init recipe registers the GAIA-Audit status, not the job name.
# -----------------------------------------------------------------------------

@test "gaia-init registers GAIA-Audit (not the job name) as the required check" {
  run grep -F "contexts[]=GAIA-Audit" "$GAIA_INIT"
  [ "$status" -eq 0 ]
}

@test "gaia-init no longer registers the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia-ci recipe registers the GAIA-Audit status, not the job name.
# -----------------------------------------------------------------------------

@test "setup-gaia-ci registers GAIA-Audit as the required check" {
  run grep -F "contexts[]=GAIA-Audit" "$SETUP_CI"
  [ "$status" -eq 0 ]
}

@test "setup-gaia-ci no longer registers the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$SETUP_CI"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# The registration command targets the required_status_checks branch-protection
# endpoint (PUT), not some unrelated GAIA-Audit mention.
# -----------------------------------------------------------------------------

@test "gaia-init registration targets the required_status_checks endpoint" {
  run grep -F "branches/main/protection/required_status_checks" "$GAIA_INIT"
  [ "$status" -eq 0 ]
}

@test "setup-gaia-ci registration targets the required_status_checks endpoint" {
  run grep -F "protection/required_status_checks" "$SETUP_CI"
  [ "$status" -eq 0 ]
}
