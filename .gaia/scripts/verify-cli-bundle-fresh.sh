#!/usr/bin/env bash
# verify-cli-bundle-fresh.sh: assert the committed CLI bundles and templates are
# exactly what rebuilding from .gaia/cli/src produces.
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

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cp .gaia/cli/gaia "${work}/gaia-committed"
cp .gaia/cli/gaia-maintainer "${work}/gaia-maintainer-committed"
# bundle:adopter regenerates .gaia/cli/templates/ from src as a side effect
# (rm -rf templates && cp -r src/scaffold/templates ...), decoupled from the
# bundled binary bytes. Snapshot the committed copy before the bundle overwrites
# it so the diff below can see drift.
cp -r .gaia/cli/templates "${work}/templates-committed"

pnpm -C .gaia/cli bundle

if ! cmp -s "${work}/gaia-committed" .gaia/cli/gaia; then
  echo "::error::.gaia/cli/gaia is stale: rebuilding from src (pnpm -C .gaia/cli bundle) produces a different binary. Run the bundle and commit the result." >&2
  exit 1
fi
if ! cmp -s "${work}/gaia-maintainer-committed" .gaia/cli/gaia-maintainer; then
  echo "::error::.gaia/cli/gaia-maintainer is stale: rebuilding from src (pnpm -C .gaia/cli bundle) produces a different binary. Run the bundle and commit the result." >&2
  exit 1
fi
# Template content resolves at runtime via import.meta.url and never enters the
# bundled binary, so the byte-cmp above cannot catch a stale committed template.
# The dogfood drift-guard in cli-tests.yml's Vitest step covers only
# templates/workflows/; component/, hook/, route/, and service/ have no other
# guard in the pull-request lane. Diff the regenerated tree against the snapshot
# taken before the bundle.
if ! diff -rq "${work}/templates-committed" .gaia/cli/templates; then
  echo "::error::.gaia/cli/templates is stale: regenerating from src (pnpm -C .gaia/cli bundle) produces different template files. Run the bundle and commit the result." >&2
  exit 1
fi
