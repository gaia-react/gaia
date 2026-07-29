#!/usr/bin/env bats
# UAT-013: no committed file carries a raw sandbox.enabled; the real enable
# only lands in the gitignored .claude/settings.local.json at runtime.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

@test "UAT-013: no committed .json/.md/.yml/.yaml file carries a raw sandbox.enabled: true" {
  cd "$REPO_ROOT"
  # A raw `git grep sandbox\.enabled` also matches TS source/test files that
  # legitimately reference the property (e.g. `expect(written.sandbox.enabled)`)
  # and the two generated CLI binaries. Scoping to committed config/doc file
  # types excludes that source-level noise and pins the precise, honest form:
  # no config surface carries a real top-level enable.
  git grep -nF 'sandbox.enabled: true' -- '*.json' '*.md' '*.yml' '*.yaml' && return 1
  git grep -nE '"sandbox":[[:space:]]*\{' -- '*.json' '*.md' '*.yml' '*.yaml' && return 1
  return 0
}

# A second test here asserted that the diff vs main never touched
# .gaia/manifest.json. It is deliberately gone rather than repaired. It held on
# the one feature branch that introduced it and nowhere since: the manifest is
# release-generated and ordinary feature work regenerates it, so the assertion
# is false as a repo-wide invariant. It also contradicted the Distribution
# Audit (PR) required check, which instructs the author to commit exactly the
# regenerated manifest it forbade. The durable half of that intent already has
# an owner in that workflow; the test above keeps the half this file is for.
