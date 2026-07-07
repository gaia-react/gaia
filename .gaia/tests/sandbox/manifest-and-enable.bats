#!/usr/bin/env bats
# UAT-013: no committed file carries a raw sandbox.enabled; the real enable
# only lands in the gitignored .claude/settings.local.json at runtime.
# .gaia/manifest.json is release-generated; this feature never touches it.

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

@test "UAT-013: .gaia/manifest.json was not touched by this feature's diff vs main" {
  cd "$REPO_ROOT"
  local base changed
  base=$(git merge-base HEAD main)
  changed=$(git diff --name-only "$base" HEAD)

  printf '%s\n' "$changed" | grep -qF '.gaia/manifest.json' && return 1
  return 0
}
