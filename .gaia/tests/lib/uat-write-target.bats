#!/usr/bin/env bats
#
# .gaia/scripts/spec/uat-write.sh: where the rendered Playwright specs
# land. The target is the package named `frontend` (the registry, or the
# built-in default `frontend/`), and the JSON `spec_dir` reports the
# repo-relative directory the specs were written to.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/uat-write.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/.gaia"
  SPEC="$WORK/SPEC.md"
  cat > "$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor on the home page
    when: they click the sign in link
    then: the sign in page opens
---
# Fixture SPEC
EOF
}

# write_literal_descriptor <path> <name>: a minimal valid descriptor, written
# literally so a fixture never copies the live file.
write_literal_descriptor() {
  cat > "$1" <<JSON
{
  "schemaVersion": 1,
  "name": "$2",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": ["app/utils/**"],
    "emergentTests": ["app/**/*.test.tsx"],
    "selfHealRefuse": ["test/**"],
    "preCommitSource": ["app/**"],
    "doctorConfigs": ["doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": {"sourcePaths": ["app/"], "inventoryPaths": [], "flowPaths": []}
}
JSON
}

run_uat_write() {
  run bash -c "cd '$WORK' && bash '$SCRIPT' '$SPEC'"
}

@test "built-in default: specs render under frontend/.playwright/e2e and nothing under the root .playwright" {
  run_uat_write
  [ "$status" -eq 0 ]
  [ -f "$WORK/frontend/.playwright/e2e/spec-901/uat-001.spec.ts" ] || return 1
  [ ! -e "$WORK/.playwright" ] || return 1
  grep -qF -- '"spec_dir":"frontend/.playwright/e2e/spec-901"' <<<"$output" || return 1
  grep -qF -- '"path":"frontend/.playwright/e2e/spec-901/uat-001.spec.ts"' <<<"$output"
}

@test "a literal path-dot registry renders under the root .playwright as before" {
  printf '[{"name":"frontend","path":"."}]\n' > "$WORK/.gaia/packages.json"
  write_literal_descriptor "$WORK/gaia.package.json" frontend

  run_uat_write
  [ "$status" -eq 0 ]
  [ -f "$WORK/.playwright/e2e/spec-901/uat-001.spec.ts" ] || return 1
  [ ! -e "$WORK/frontend" ] || return 1
  grep -qF -- '"spec_dir":".playwright/e2e/spec-901"' <<<"$output"
}

@test "the package named frontend decides the target, not a hardcoded directory" {
  mkdir -p "$WORK/apps/site"
  printf '[{"name":"frontend","path":"apps/site"}]\n' > "$WORK/.gaia/packages.json"
  write_literal_descriptor "$WORK/apps/site/gaia.package.json" frontend

  run_uat_write
  [ "$status" -eq 0 ]
  [ -f "$WORK/apps/site/.playwright/e2e/spec-901/uat-001.spec.ts" ] || return 1
  [ ! -e "$WORK/frontend" ] || return 1
  grep -qF -- '"spec_dir":"apps/site/.playwright/e2e/spec-901"' <<<"$output"
}

@test "a malformed registry exits non-zero with the gaia-packages message and writes nothing" {
  printf 'not json' > "$WORK/.gaia/packages.json"

  run_uat_write
  [ "$status" -ne 0 ]
  grep -qF -- "gaia-packages: .gaia/packages.json is malformed" <<<"$output" || return 1
  [ ! -e "$WORK/frontend" ] || return 1
  [ ! -e "$WORK/.playwright" ] || return 1
  [ ! -e "$WORK/.gaia/local" ]
}

@test "a registry with a missing descriptor exits non-zero and writes nothing" {
  printf '[{"name":"frontend","path":"frontend"}]\n' > "$WORK/.gaia/packages.json"

  run_uat_write
  [ "$status" -ne 0 ]
  grep -qF -- "gaia-packages: frontend/gaia.package.json is missing" <<<"$output" || return 1
  [ ! -e "$WORK/frontend" ] || return 1
  [ ! -e "$WORK/.gaia/local" ]
}

@test "a registry that registers no package named frontend exits non-zero and writes nothing" {
  mkdir -p "$WORK/apps/other"
  printf '[{"name":"other","path":"apps/other"}]\n' > "$WORK/.gaia/packages.json"
  write_literal_descriptor "$WORK/apps/other/gaia.package.json" other

  run_uat_write
  [ "$status" -ne 0 ]
  grep -qF -- "registers no package named frontend" <<<"$output" || return 1
  [ ! -e "$WORK/apps/other/.playwright" ] || return 1
  [ ! -e "$WORK/.playwright" ] || return 1
  [ ! -e "$WORK/.gaia/local" ]
}

@test "an orphaned spec in the package target is deleted, and a stale root copy is left alone" {
  mkdir -p "$WORK/frontend/.playwright/e2e/spec-901" "$WORK/.playwright/e2e/spec-901"
  echo orphan > "$WORK/frontend/.playwright/e2e/spec-901/uat-009.spec.ts"
  echo stale > "$WORK/.playwright/e2e/spec-901/uat-009.spec.ts"

  run_uat_write
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/frontend/.playwright/e2e/spec-901/uat-009.spec.ts" ] || return 1
  [ -f "$WORK/.playwright/e2e/spec-901/uat-009.spec.ts" ]
}

@test "a copy of the renderer with no package library beside it exits non-zero and writes nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/bare/.gaia/scripts" "$BATS_TEST_TMPDIR/bare/.gaia/templates"
  cp -R "$REPO_ROOT_REAL/.gaia/scripts/spec" "$BATS_TEST_TMPDIR/bare/.gaia/scripts/spec"
  cp -R "$REPO_ROOT_REAL/.gaia/templates/spec" "$BATS_TEST_TMPDIR/bare/.gaia/templates/spec"

  run bash -c "cd '$WORK' && bash '$BATS_TEST_TMPDIR/bare/.gaia/scripts/spec/uat-write.sh' '$SPEC'"
  [ "$status" -ne 0 ]
  grep -qF -- "package library missing" <<<"$output" || return 1
  [ ! -e "$WORK/frontend" ] || return 1
  [ ! -e "$WORK/.playwright" ]
}
