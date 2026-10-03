#!/usr/bin/env bats
# .gaia/scripts/precommit-packages.sh: the plan helper behind .husky/pre-commit.
#
# The helper reads the staged set and prints one record per line. These tests
# drive it directly in a sandbox repo, so each plan is asserted as data. The
# hook that acts on the plan is covered end to end by
# .gaia/tests/hooks/husky-pre-commit.bats.
#
# The registry and descriptors are written literally into the sandbox; the live
# files are never copied. Assertion style per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  HELPER="$REPO_ROOT/.gaia/scripts/precommit-packages.sh"
  [ -f "$HELPER" ] || { echo "missing $HELPER" >&2; return 1; }

  REPO="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/precommit-packages.XXXXXX")" && pwd -P)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$HELPER" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"
  SANDBOX_HELPER="$REPO/.gaia/scripts/precommit-packages.sh"
}

write_descriptor() {
  local directory="$1" name="$2" pre_commit_source="$3"
  mkdir -p "$directory"
  cat > "$directory/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "$name",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": ["app/utils/**"],
    "emergentTests": ["app/components/**/*.test.ts"],
    "selfHealRefuse": ["CLAUDE.md"],
    "preCommitSource": $pre_commit_source,
    "doctorConfigs": ["doctor.config.*", "react-doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": { "sourcePaths": ["app/"], "inventoryPaths": ["app/"], "flowPaths": ["app/"] }
}
JSON
}

use_frontend_package() {
  printf '[{"name":"frontend","path":"frontend"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/frontend" frontend '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

plan() {
  run bash "$SANDBOX_HELPER" "$REPO"
}

# Create and stage files at the given repo-relative paths.
stage_files() {
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    printf '// %s\n' "$path" > "$REPO/$path"
    git -C "$REPO" add -- "$path"
  done
}

# Create, commit, then rename (staged) each `src:dest` pair.
stage_renames() {
  local pair source_path destination_path
  for pair in "$@"; do
    source_path="${pair%%:*}"
    mkdir -p "$REPO/$(dirname "$source_path")"
    # Long enough that one appended line stays a rename above git's similarity
    # threshold, so a content-change rename reads as Rnn rather than D plus A.
    printf '// %s\n' "$source_path" > "$REPO/$source_path"
    seq 1 40 >> "$REPO/$source_path"
    git -C "$REPO" add -- "$source_path"
  done
  git -C "$REPO" commit --quiet -m "seed"
  for pair in "$@"; do
    source_path="${pair%%:*}"
    destination_path="${pair#*:}"
    mkdir -p "$REPO/$(dirname "$destination_path")"
    git -C "$REPO" mv -- "$source_path" "$destination_path"
  done
}

@test "usage: no argument exits 2" {
  run bash "$HELPER"
  [ "$status" -eq 2 ]
}

@test "usage: a root that is not a directory exits 2" {
  run bash "$HELPER" "$REPO/nope"
  [ "$status" -eq 2 ]
}

@test "an empty staged set plans nothing" {
  use_frontend_package
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a frontend change plans the frontend package" {
  use_frontend_package
  stage_files frontend/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tfrontend' ]
}

@test "a path matching no preCommitSource glob plans nothing" {
  use_frontend_package
  stage_files frontend/README.md docs/a.md .claude/rules/a.md
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a root app/ path is not a frontend change when the package is at frontend/" {
  use_frontend_package
  stage_files app/x.tsx
  plan
  [ "$status" -eq 0 ]
  # Not a package change; it is the MIG-013 retired-path record instead.
  grep -qxF -- "$(printf 'retired-add\tapp/x.tsx\tfrontend/app/x.tsx')" <<<"$output"
  [ "$(grep -c '^package' <<<"$output" || true)" -eq 0 ]
}

# Guard can fail: the same staged file under a descriptor that names nothing it
# matches plans nothing, so the descriptor decides.
@test "a descriptor that gates nothing here plans nothing for a frontend path" {
  use_frontend_package
  write_descriptor "$REPO/frontend" frontend '["nomatch/**"]'
  stage_files frontend/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a deletion counts" {
  use_frontend_package
  stage_files frontend/app/x.tsx
  git -C "$REPO" commit --quiet -m "add"
  git -C "$REPO" rm --quiet frontend/app/x.tsx
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tfrontend' ]
}

@test "a spaced and a non-ASCII path count and are not C-quoted into a miss" {
  use_frontend_package
  stage_files "frontend/app/caf"$'\303\251'" x.tsx"
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tfrontend' ]
}

@test "two registered packages plan only the one with a staged source path" {
  printf '[{"name":"frontend","path":"frontend"},{"name":"admin","path":"admin"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/frontend" frontend '["app/**"]'
  write_descriptor "$REPO/admin" admin '["app/**"]'
  stage_files admin/app/y.ts
  plan
  [ "$output" = $'package\tadmin' ]
  stage_files frontend/app/x.ts
  plan
  [ "$(printf '%s\n' "$output" | sort)" = $'package\tadmin\npackage\tfrontend' ]
}

@test "doctor guard: two configs in a package dir are reported with the directory" {
  use_frontend_package
  : > "$REPO/frontend/doctor.config.ts"
  : > "$REPO/frontend/doctor.config.json"
  plan
  [ "$status" -eq 0 ]
  grep -qxF $'doctor\tfrontend' <<<"$output"
  grep -qxF $'doctor-file\tfrontend/doctor.config.json' <<<"$output"
  grep -qxF $'doctor-file\tfrontend/doctor.config.ts' <<<"$output"
}

@test "doctor guard: one config in a package dir reports nothing" {
  use_frontend_package
  : > "$REPO/frontend/doctor.config.ts"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "doctor guard: a stray config at the repo root is not a package config" {
  use_frontend_package
  : > "$REPO/doctor.config.ts"
  : > "$REPO/doctor.config.json"
  plan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unparseable registry exits 1 with the gaia-packages message" {
  use_frontend_package
  printf 'not json {\n' > "$REPO/.gaia/packages.json"
  stage_files frontend/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

@test "a missing descriptor exits 1 with the gaia-packages message" {
  use_frontend_package
  rm "$REPO/frontend/gaia.package.json"
  stage_files frontend/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

@test "a missing registry reader exits 1 rather than allowing" {
  use_frontend_package
  rm "$REPO/.claude/hooks/lib/gaia-packages.sh"
  stage_files frontend/app/x.tsx
  plan
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
}

# --- C13: the migration-rename exemption ---

# A realistic Phase 4 move: whole directories with nested, spaced, and
# non-ASCII files, every root config file, every frontend-only .claude unit,
# and the one renamed pair. Each source is a retired root path; each
# destination is its C6 counterpart.
C6_PAIRS=(
  "app/routes/home.tsx:frontend/app/routes/home.tsx"
  "app/components/Button/index.tsx:frontend/app/components/Button/index.tsx"
  "app/components/Button/tests/index.test.tsx:frontend/app/components/Button/tests/index.test.tsx"
  "app/sessions.server/cookie ü.ts:frontend/app/sessions.server/cookie ü.ts"
  "test/setup.ts:frontend/test/setup.ts"
  "public/favicon.ico:frontend/public/favicon.ico"
  ".storybook/main.ts:frontend/.storybook/main.ts"
  ".playwright/e2e/home.spec.ts:frontend/.playwright/e2e/home.spec.ts"
  "vite.config.ts:frontend/vite.config.ts"
  "vitest.config.ts:frontend/vitest.config.ts"
  "playwright.config.ts:frontend/playwright.config.ts"
  "react-router.config.ts:frontend/react-router.config.ts"
  "stylelint.config.mjs:frontend/stylelint.config.mjs"
  "knip.config.ts:frontend/knip.config.ts"
  "doctor.config.ts:frontend/doctor.config.ts"
  "tsconfig.json:frontend/tsconfig.json"
  "Dockerfile:frontend/Dockerfile"
  ".env.example:frontend/.env.example"
  "eslint.config.mjs:frontend/eslint.config.mjs"
  ".lintstagedrc.json:frontend/.lintstagedrc.json"
  ".dockerignore:frontend/Dockerfile.dockerignore"
  ".claude/skills/a11y-fixes/SKILL.md:frontend/.claude/skills/a11y-fixes/SKILL.md"
  ".claude/skills/eslint-fixes/SKILL.md:frontend/.claude/skills/eslint-fixes/SKILL.md"
  ".claude/skills/gaia-react-perf/SKILL.md:frontend/.claude/skills/gaia-react-perf/SKILL.md"
  ".claude/skills/new-component/SKILL.md:frontend/.claude/skills/new-component/SKILL.md"
  ".claude/skills/new-hook/SKILL.md:frontend/.claude/skills/new-hook/SKILL.md"
  ".claude/skills/new-route/SKILL.md:frontend/.claude/skills/new-route/SKILL.md"
  ".claude/skills/new-service/SKILL.md:frontend/.claude/skills/new-service/SKILL.md"
  ".claude/skills/playwright-cli/SKILL.md:frontend/.claude/skills/playwright-cli/SKILL.md"
  ".claude/skills/playwright-cli/references/a.md:frontend/.claude/skills/playwright-cli/references/a.md"
  ".claude/skills/react-code/SKILL.md:frontend/.claude/skills/react-code/SKILL.md"
  ".claude/skills/skeleton-loaders/SKILL.md:frontend/.claude/skills/skeleton-loaders/SKILL.md"
  ".claude/skills/tailwind/SKILL.md:frontend/.claude/skills/tailwind/SKILL.md"
  ".claude/skills/typescript/SKILL.md:frontend/.claude/skills/typescript/SKILL.md"
  ".claude/rules/accessibility.md:frontend/.claude/rules/accessibility.md"
  ".claude/rules/api-service.md:frontend/.claude/rules/api-service.md"
  ".claude/rules/design-baseline.md:frontend/.claude/rules/design-baseline.md"
  ".claude/rules/i18n.md:frontend/.claude/rules/i18n.md"
  ".claude/rules/playwright.md:frontend/.claude/rules/playwright.md"
  ".claude/rules/react-router-docs.md:frontend/.claude/rules/react-router-docs.md"
  ".claude/rules/routes.md:frontend/.claude/rules/routes.md"
  ".claude/rules/state-pattern.md:frontend/.claude/rules/state-pattern.md"
  ".claude/rules/storybook.md:frontend/.claude/rules/storybook.md"
  ".claude/rules/tailwind.md:frontend/.claude/rules/tailwind.md"
  ".claude/instructions/add-locale.md:frontend/.claude/instructions/add-locale.md"
  ".claude/instructions/remove-i18n.md:frontend/.claude/instructions/remove-i18n.md"
  ".claude/agents/code-audit-frontend/README.md:frontend/.claude/agents/code-audit-frontend/README.md"
  ".claude/agents/code-audit-frontend/cn.md:frontend/.claude/agents/code-audit-frontend/cn.md"
  ".claude/agents/code-audit-frontend/conform.md:frontend/.claude/agents/code-audit-frontend/conform.md"
  ".claude/agents/code-audit-frontend/form-components.md:frontend/.claude/agents/code-audit-frontend/form-components.md"
  ".claude/agents/code-audit-frontend/react-i18next.md:frontend/.claude/agents/code-audit-frontend/react-i18next.md"
)

@test "C13: the whole C6 move set, as renames only, plans exempt with no registry and no descriptor" {
  stage_renames "${C6_PAIRS[@]}"
  # The fixture must really stage every pair as an exact rename, else the
  # exemption is being asserted over a set git did not see as renames.
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq "${#C6_PAIRS[@]}" ]
  [ ! -e "$REPO/.gaia/packages.json" ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" = "exempt" ]
}

# Each negative stages the whole C6 set plus one entry that must not be exempt,
# and asserts the exemption is refused (the plan is not `exempt`). The extra
# pair rides in the same seed commit, so only renames are ever staged.
@test "C13 refusal: an R100 rename inside frontend/ beside the C6 set is not exempt and plans the package" {
  use_frontend_package
  stage_renames "${C6_PAIRS[@]}" "frontend/app/utils/a.ts:frontend/app/utils/b.ts"
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq $((${#C6_PAIRS[@]} + 1)) ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" = $'package\tfrontend' ]
}

@test "C13 refusal: a harness rename outside the C6 units beside the C6 set is not exempt" {
  use_frontend_package
  stage_renames "${C6_PAIRS[@]}" "wiki/a.md:wiki/b.md"
  [ "$(git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100')" -eq $((${#C6_PAIRS[@]} + 1)) ]
  plan
  [ "$status" -eq 0 ]
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a C6 source renamed to a destination that is not its counterpart is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:src/x.tsx"
  plan
  [ "$status" -eq 0 ]
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a source renamed under a different name inside frontend/ is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:frontend/app/y.tsx"
  plan
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a .claude file outside the C6 units is not exempt" {
  use_frontend_package
  stage_renames ".claude/rules/quality-gate.md:frontend/.claude/rules/quality-gate.md"
  plan
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a root config file outside the C6 list is not exempt" {
  use_frontend_package
  stage_renames "package.json:frontend/package.json"
  plan
  [ "$output" != "exempt" ]
}

@test "C13 refusal: the dockerignore pair with a different destination is not exempt" {
  use_frontend_package
  stage_renames ".dockerignore:frontend/.dockerignore"
  plan
  [ "$output" != "exempt" ]
}

@test "C13 refusal: a C6 rename carrying a content change is not exempt" {
  use_frontend_package
  stage_renames "app/x.tsx:frontend/app/x.tsx"
  printf 'a changed line\n' >> "$REPO/frontend/app/x.tsx"
  git -C "$REPO" add frontend/app/x.tsx
  plan
  [ "$output" = $'package\tfrontend' ]
}

@test "C13: an empty staged set is not reported exempt" {
  plan
  [ "$output" != "exempt" ]
}
