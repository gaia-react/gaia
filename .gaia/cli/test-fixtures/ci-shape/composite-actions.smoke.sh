#!/usr/bin/env bash
# Opt-in shell smoke test for the slice 2 composite actions.
#
# Runs:
#   - actionlint on the two action.yml files (note: actionlint v1.7
#     does not natively lint composite actions in isolation; we wrap
#     them in a synthetic workflow that uses each action so actionlint
#     can validate the inputs/outputs surface).
#   - shellcheck on every .sh helper under
#     .github/actions/gaia-ci-merge-and-watch/lib/.
#
# Usage: GAIA_CI_SHAPE_E2E=1 bash .gaia/cli/test-fixtures/ci-shape/composite-actions.smoke.sh
#
# Skipped silently when GAIA_CI_SHAPE_E2E is unset; the default
# `pnpm test --run` should not depend on these tools being installed.

set -euo pipefail

if [[ "${GAIA_CI_SHAPE_E2E:-}" != "1" ]]; then
  echo "ci-shape smoke skipped (set GAIA_CI_SHAPE_E2E=1 to run)"
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
ACTION_MAW="${REPO_ROOT}/.github/actions/gaia-ci-merge-and-watch/action.yml"
ACTION_SPS="${REPO_ROOT}/.github/actions/gaia-ci-stale-pr-skip/action.yml"
LIB_DIR="${REPO_ROOT}/.github/actions/gaia-ci-merge-and-watch/lib"

if ! command -v actionlint >/dev/null 2>&1; then
  echo "actionlint not installed; install via brew install actionlint"
  exit 1
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed; install via brew install shellcheck"
  exit 1
fi

# actionlint does not lint composite actions directly. We wrap each one
# in a synthetic workflow that consumes it so actionlint can validate
# the steps' YAML and bash-step expressions.
TMP_WORKFLOW="$(mktemp -d)/smoke-workflows"
mkdir -p "$TMP_WORKFLOW/.github/workflows"
cat >"$TMP_WORKFLOW/.github/workflows/smoke-merge-watch.yml" <<'YAML'
name: smoke-merge-watch
on: workflow_dispatch
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/gaia-ci-merge-and-watch
        with:
          pr-number: '1'
          label: gaia-ci
          gh-token: ${{ secrets.GITHUB_TOKEN }}
YAML

cat >"$TMP_WORKFLOW/.github/workflows/smoke-stale-skip.yml" <<'YAML'
name: smoke-stale-skip
on: workflow_dispatch
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/gaia-ci-stale-pr-skip
        with:
          label: gaia-ci
          gh-token: ${{ secrets.GITHUB_TOKEN }}
YAML

# Symlink the actions into the temp tree so `uses: ./...` resolves.
ln -s "${REPO_ROOT}/.github/actions" "$TMP_WORKFLOW/.github/actions"

(
  cd "$TMP_WORKFLOW"
  actionlint .github/workflows/smoke-merge-watch.yml .github/workflows/smoke-stale-skip.yml
)

# shellcheck the library scripts.
shellcheck "${LIB_DIR}"/*.sh

# Ensure the action.yml files exist and have the expected top-level
# keys. (actionlint can't validate composite-action surfaces directly;
# this is a minimal sanity check.)
for action in "$ACTION_MAW" "$ACTION_SPS"; do
  if ! grep -q '^name:' "$action"; then
    echo "missing name in $action" >&2
    exit 1
  fi
  if ! grep -q '^runs:' "$action"; then
    echo "missing runs in $action" >&2
    exit 1
  fi
  if ! grep -q "using: 'composite'" "$action"; then
    echo "$action is not a composite action" >&2
    exit 1
  fi
done

echo "ci-shape smoke OK"
