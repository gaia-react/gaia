#!/usr/bin/env bats
#
# Pins the PR-time half of the CLI bundle-freshness gate: cli-tests.yml runs
# verify-cli-bundle-fresh.sh, so a pull request that edits .gaia/cli/src
# without rebuilding the committed bundles fails before merge rather than at
# the release tag.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  FRESHNESS_STEP='run: bash .gaia/scripts/verify-cli-bundle-fresh.sh'
}

@test "the PR-time bundle-freshness step is wired into cli-tests" {
  grep -qF -- "$FRESHNESS_STEP" "$WORKFLOW"
}

@test "the freshness-step check flags a workflow copy without it" {
  local scratch="$BATS_TEST_TMPDIR/cli-tests.yml"
  grep -vF -- "$FRESHNESS_STEP" "$WORKFLOW" >"$scratch" || true
  run grep -qF -- "$FRESHNESS_STEP" "$scratch"
  [ "$status" -ne 0 ]
}
