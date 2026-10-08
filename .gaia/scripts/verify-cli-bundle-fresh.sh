#!/usr/bin/env bash
# verify-cli-bundle-fresh.sh: assert the committed CLI bundles are exactly
# what rebuilding from .gaia/cli/src produces.
#
# The committed .gaia/cli/gaia and .gaia/cli/gaia-maintainer bundles are what
# the runtime and the release tarball actually execute, so a commit that edits
# .gaia/cli/src/** without rebuilding them carries a stale binary. Rebuilding is
# deterministic (esbuild), so a fresh bundle that differs from the committed one
# means the commit is stale; the bundle is idempotent and fast.
#
# One script with two callers, rather than a copy of the same step in each. A
# comment asking a human to hold two copies in lockstep is not an enforcement
# mechanism, and the two lanes are far enough apart that a gap in one surfaces
# only when the other is the last thing standing between a defect and a publish:
#
#   * .github/workflows/cli-tests.yml -- the PR-time gate. A required check, so
#     what it misses merges.
#   * .github/workflows/release.yml   -- the tag-push gate, the last check
#     before a tarball publishes.
#
# Both callers are maintainer-only and release-excluded, and so is this script:
# it rebuilds from .gaia/cli/src, which an adopter clone does not have.
#
# Run from the repository root. Reads the tree, writes only inside its own temp
# directory and whatever `pnpm bundle` regenerates in place.
set -euo pipefail

work_directory="$(mktemp -d)"
trap 'rm -rf "${work_directory}"' EXIT

cp .gaia/cli/gaia "${work_directory}/gaia-committed"
cp .gaia/cli/gaia-maintainer "${work_directory}/gaia-maintainer-committed"

pnpm -C .gaia/cli bundle

if ! cmp -s "${work_directory}/gaia-committed" .gaia/cli/gaia; then
  echo "::error::.gaia/cli/gaia is stale: rebuilding from src (pnpm -C .gaia/cli bundle) produces a different binary. Run the bundle and commit the result." >&2
  exit 1
fi
if ! cmp -s "${work_directory}/gaia-maintainer-committed" .gaia/cli/gaia-maintainer; then
  echo "::error::.gaia/cli/gaia-maintainer is stale: rebuilding from src (pnpm -C .gaia/cli bundle) produces a different binary. Run the bundle and commit the result." >&2
  exit 1
fi
