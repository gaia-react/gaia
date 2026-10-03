#!/usr/bin/env bats
# AUDIT_SELFHEAL_REFUSE_ERE, the one self-heal refusal set
# (.claude/hooks/lib/audit-selfheal-paths.sh): root arms plus the package arms
# read from the descriptor's selfHealRefuse globs (SPEC-092 couplings 3 and 5,
# UAT-005, UAT-018).
#
# Every case builds its own fixture root in $BATS_TEST_TMPDIR with the two
# libraries copied in (the lib resolves its repo root from its own location, so
# a copy under a temp root reads that root's registry and never the live one).
# Registries and descriptors are written literally here, never copied from the
# live files (DP-005). Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  FIXTURE="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FIXTURE/.claude/hooks/lib" "$FIXTURE/.gaia"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-selfheal-paths.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$FIXTURE/.claude/hooks/lib/"
}

# write_descriptor <dir>: a literal, valid descriptor at <dir>/gaia.package.json.
write_descriptor() {
  mkdir -p "$1"
  cat >"$1/gaia.package.json" <<'JSON'
{
  "schemaVersion": 1,
  "name": "frontend",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": ["app/utils/**"],
    "emergentTests": [".playwright/**/*.spec.ts"],
    "selfHealRefuse": [".claude/**", "CLAUDE.md", "gaia.package.json", "test/**", ".playwright/**", ".storybook/**", "app/**/tests/**", "app/**/*.test.ts", "app/**/*.test.tsx", "app/**/*.stories.tsx", "package.json", "tsconfig*.json", "*.config.ts", "*.config.mts", "*.config.mjs", "*.config.cjs", "*.config.js", "Dockerfile", "Dockerfile.dockerignore", ".*"],
    "preCommitSource": ["app/**"],
    "doctorConfigs": ["doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": {
    "sourcePaths": ["app/"],
    "inventoryPaths": ["app/components/"],
    "flowPaths": ["app/routes.ts"]
  }
}
JSON
}

# load_ere: source the fixture's copy of the lib in this shell.
load_ere() {
  # shellcheck source=/dev/null
  . "$FIXTURE/.claude/hooks/lib/audit-selfheal-paths.sh"
}

# refused <path>: succeed when the ERE matches the path.
refused() {
  printf '%s\n' "$1" | grep -qE "$AUDIT_SELFHEAL_REFUSE_ERE"
}

@test "built-in default: every package and root path in the refusal set matches" {
  write_descriptor "$FIXTURE/frontend"
  load_ere
  local path missed=''
  for path in \
    frontend/app/components/X/tests/X.test.tsx frontend/app/foo.test.ts \
    frontend/app/X.stories.tsx frontend/test/a.ts frontend/.playwright/a.spec.ts \
    frontend/.storybook/main.ts frontend/vite.config.ts frontend/package.json \
    frontend/tsconfig.json frontend/.npmrc frontend/.env.example \
    frontend/.claude/rules/x.md frontend/.claude/settings.json frontend/CLAUDE.md \
    frontend/gaia.package.json .gaia/packages.json package.json pnpm-lock.yaml \
    pnpm-workspace.yaml prettier.config.mjs .npmrc frontend/.lintstagedrc.json \
    frontend/Dockerfile frontend/Dockerfile.dockerignore; do
    refused "$path" || missed="$missed $path"
  done
  [ -z "$missed" ]
}

@test "built-in default: app source a member repairs is not refused (over-refusal negatives)" {
  write_descriptor "$FIXTURE/frontend"
  load_ere
  run refused "frontend/app/routes/home.tsx"
  [ "$status" -eq 1 ]
  run refused "frontend/app/utils/x.ts"
  [ "$status" -eq 1 ]
}

@test "built-in default: retired root app and test paths are no longer refused as package paths" {
  write_descriptor "$FIXTURE/frontend"
  load_ere
  run refused "app/foo.test.ts"
  [ "$status" -eq 1 ]
  run refused "test/a.ts"
  [ "$status" -eq 1 ]
  run refused ".lintstagedrc.json"
  [ "$status" -eq 1 ]
  run refused "Dockerfile"
  [ "$status" -eq 1 ]
  [ -z "$AUDIT_SELFHEAL_PACKAGES_ERROR" ]
}

@test "literal path-dot registry and descriptor: today's root app and test paths are refused" {
  printf '%s\n' '[{"name":"frontend","path":"."}]' >"$FIXTURE/.gaia/packages.json"
  write_descriptor "$FIXTURE"
  load_ere
  refused "app/foo.test.ts"
  refused "test/a.ts"
  refused "app/X.stories.tsx"
  run refused "app/routes/home.tsx"
  [ "$status" -eq 1 ]
  [ -z "$AUDIT_SELFHEAL_PACKAGES_ERROR" ]
}

@test "unparseable registry: the ERE refuses every path and the error is set" {
  printf '%s\n' '{not json' >"$FIXTURE/.gaia/packages.json"
  write_descriptor "$FIXTURE/frontend"
  load_ere
  refused "frontend/app/routes/home.tsx"
  refused "anything/at/all.txt"
  case "$AUDIT_SELFHEAL_PACKAGES_ERROR" in
    gaia-packages:*) ;;
    *) printf 'bad error: %s\n' "$AUDIT_SELFHEAL_PACKAGES_ERROR" >&2; return 1 ;;
  esac
}

@test "missing descriptor: the ERE refuses every path and the error is set" {
  # a registered package whose descriptor file is absent
  printf '%s\n' '[{"name":"frontend","path":"frontend"}]' >"$FIXTURE/.gaia/packages.json"
  mkdir -p "$FIXTURE/frontend"
  load_ere
  refused "frontend/app/routes/home.tsx"
  case "$AUDIT_SELFHEAL_PACKAGES_ERROR" in
    gaia-packages:*) ;;
    *) printf 'bad error: %s\n' "$AUDIT_SELFHEAL_PACKAGES_ERROR" >&2; return 1 ;;
  esac
}

@test "invalid descriptor: the ERE refuses every path and the error is set" {
  printf '%s\n' '[{"name":"frontend","path":"frontend"}]' >"$FIXTURE/.gaia/packages.json"
  mkdir -p "$FIXTURE/frontend"
  printf '%s\n' '{"schemaVersion":2}' >"$FIXTURE/frontend/gaia.package.json"
  load_ere
  refused "frontend/app/routes/home.tsx"
  [ -n "$AUDIT_SELFHEAL_PACKAGES_ERROR" ]
}

@test "the real repo: the committed registry and descriptor load with no error" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-selfheal-paths.sh"
  [ -z "$AUDIT_SELFHEAL_PACKAGES_ERROR" ]
  refused ".gaia/packages.json"
  refused "package.json"
}
