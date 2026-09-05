#!/usr/bin/env bash
# Shared dependency gate for the node-dependent RED suites under
# .gaia/tests/hooks: red-ledger-lib, capture-red-observations,
# red-verify-commit-check, red-verify-e2e and worthiness-presence-check.
#
# They all drive .gaia/scripts/red-ledger/extract-test-signals.mjs and
# .gaia/scripts/classifier/classify-determinism.mjs, each of which resolves
# `typescript` through createRequire against the repo root's node_modules. With
# that absent the suites cannot answer at all.
#
# Source it from `setup()`, never `setup_file()`, for the reason run-hook.sh
# beside it gives: bats runs setup_file in a separate process, so a function
# defined there is invisible to test bodies -- including the gate's own
# self-test, which calls this function directly.
#
#   setup() {
#     REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
#     . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
#     require_node_typescript "$REPO_ROOT"
#   }
#
# WHY THE CI BRANCH FAILS RATHER THAN SKIPPING, which is the whole point of
# this file. Each of the suites above previously spelled the gate inline as
#
#   [ -d "$ROOT/node_modules/typescript" ] || skip "typescript not installed ..."
#
# and bats reports a skip as `ok ... # skip`. The bats shards install no Node
# dependencies, so every one of them reported green on every PR while
# asserting nothing, and a stale cardinal inside one of them survived every
# run of the check that exists to catch it -- found only by a human running
# the suite locally. That is gaia-react/gaia#1748.
#
# So the CI branch returns non-zero, matching the YAML-parser gate in
# .gaia/scripts/tests/retrigger-reachability.bats, whose comment states the
# same argument for the same reason: on CI the dependency is a precondition
# rather than a maybe, because the job that runs the suite installs it. Off CI
# the skip stands -- a checkout that has not run `pnpm install` is not the
# environment this gate is making a claim about.
#
# That gate's name is deliberately not spelled out above. W10 in
# .gaia/tests/lib/audit-ci-shards.bats derives the apt step's leg list by
# grepping each shard's suites AND their helper directories for the literal
# names of the zsh/YAML gates, over-inclusively and on purpose. This file sits
# in the helper directory every hooks suite shares, so spelling that name here
# puts an apt install on hooks-1 -- a leg drawing neither package -- to satisfy
# a comment. The pointer above says which gate without tripping the scan.
#
# The complement is .github/workflows/audit-ci-tests.yml's
# "Setup Node for the node-dependent RED suites" step, gated to the exchange
# group holding them. Dropping either half without the other reds those
# legs, which is the intended direction: the failure this file exists to
# prevent is a green one.
#
# `skip` and the bats-provided environment are resolved at runtime by the suite
# sourcing this, not by this file; it is a `.sh` held to the strictest
# shell-lint severity floor (see .gaia/tests/shell-lint.sh) rather than a
# `.bats`, so the linter cannot see them.

# require_node_typescript <repo-root>
#
# Returns 0 when the dependency is present. On a CI runner without it, returns
# non-zero after naming the install step, which fails the calling setup() and
# reds the leg. Anywhere else, skips.
require_node_typescript() {
  local root="$1"

  if [ -d "$root/node_modules/typescript" ]; then
    return 0
  fi

  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # No `::error::` prefix: bats prints a test's stderr prefixed with `# `,
    # and Actions parses a workflow command only at column 0, so the
    # annotation that spelling promises would never render. The `return 1` is
    # what gates.
    echo "typescript is not installed under $root on a CI runner; this node-dependent RED suite would skip to green. Check the 'Setup Node for the node-dependent RED suites' step in .github/workflows/audit-ci-tests.yml." >&2
    return 1
  fi

  skip "typescript not installed (node-dependent RED suite)"
}
