#!/usr/bin/env bats
# Release configuration that has to follow the 2.0.0 frontend/ move
# (SPEC-092 contracts C1, C8, C10).
#
#   M1-M3  the manifest classifier: no key at a retired root frontend path,
#          frontend/ keys present, and the generated and adopter-owned files
#          absent from the manifest.
#   X1-X2  .gaia/release-exclude and .gaia/release-scrub.yml name no retired
#          root frontend path; X1 also drives a fixture that does and asserts
#          the check reports it.
#   S1     the scrub strips maintainer-only keys from both package.json files.
#   L1-L2  the CHANGELOG [Unreleased] Breaking entry leads with the routing
#          line and carries no U+2014.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  MAINTAINER_CLI="$REPO_ROOT/.gaia/cli/gaia-maintainer"
  ROUTING_LINE='On GAIA 1.6.1? Choose Abort, then paste the prompt from https://gaiareact.com/migrate into a fresh session.'
  # Paths that moved under frontend/ in 2.0.0. The root halves of the split
  # files (package.json, prettier.config.mjs, .prettierignore, .gitignore,
  # lockfile, workspace file) legitimately stay at the root and are not here.
  RETIRED_ROOT_PATTERN='^(app|test|public)(/|$)|^\.playwright(/|$)|^\.storybook(/|$)|^(tsconfig\.json|vite\.config\.ts|vitest\.config\.ts|playwright\.config\.ts|eslint\.config\.mjs|knip\.config\.ts|stylelint\.config\.mjs|react-router\.config\.ts|doctor\.config\.ts|Dockerfile|\.lintstagedrc\.json|\.dockerignore|\.env\.example)$'
}

# Retired root frontend paths named by a release-exclude body on stdin: the
# non-comment lines that match the retired pattern.
retired_lines_in_exclude() {
  grep -v '^[[:space:]]*#' | grep -E -- "$RETIRED_ROOT_PATTERN" || true
}

# Retired root frontend paths named as a quoted path in a release-scrub body on
# stdin (`- "app/..."` or `paths:` style entries).
retired_paths_in_scrub() {
  sed -n 's/^[[:space:]]*-[[:space:]]*"\([^"]*\)".*$/\1/p' | grep -E -- "$RETIRED_ROOT_PATTERN" || true
}

manifest_keys() {
  "$MAINTAINER_CLI" release manifest --stdout --allow-undecided | jq -r '.files | keys[]'
}

@test "M1: the manifest lists no key at a retired root frontend path and lists frontend/app/root.tsx" {
  keys="$(manifest_keys)"
  [ -n "$keys" ]
  retired="$(printf '%s\n' "$keys" | grep -E -- "$RETIRED_ROOT_PATTERN" || true)"
  [ -z "$retired" ]
  printf '%s\n' "$keys" | grep -qxF 'frontend/app/root.tsx'
}

@test "M2: the generated settings and the package registry are not in the manifest; the descriptor and overlay are" {
  keys="$(manifest_keys)"
  printf '%s\n' "$keys" | grep -qxF 'frontend/.claude/settings.json' && return 1
  printf '%s\n' "$keys" | grep -qxF '.gaia/packages.json' && return 1
  printf '%s\n' "$keys" | grep -qxF 'frontend/gaia.package.json'
  printf '%s\n' "$keys" | grep -qxF 'frontend/.claude/settings.overlay.json'
  printf '%s\n' "$keys" | grep -qxF 'frontend/package.json'
}

@test "M3: the retired-path pattern flags a root app path (the check can fail)" {
  printf 'app/root.tsx\n' | grep -qE -- "$RETIRED_ROOT_PATTERN"
  printf 'Dockerfile\n' | grep -qE -- "$RETIRED_ROOT_PATTERN"
  printf 'frontend/app/root.tsx\n' | grep -qE -- "$RETIRED_ROOT_PATTERN" && return 1
  printf 'prettier.config.mjs\n' | grep -qE -- "$RETIRED_ROOT_PATTERN" && return 1
  true
}

@test "X1: release-exclude names no retired root frontend path, and a fixture that does is reported" {
  [ -z "$(retired_lines_in_exclude < "$REPO_ROOT/.gaia/release-exclude")" ]
  # The canary line is the one that was keyed at the root before the move.
  grep -qxF 'frontend/.playwright/e2e/react-perf-smoke.spec.ts' "$REPO_ROOT/.gaia/release-exclude"
  fixture="$BATS_TEST_TMPDIR/exclude-old"
  printf '# comment\n.playwright/e2e/react-perf-smoke.spec.ts\n' > "$fixture"
  [ "$(retired_lines_in_exclude < "$fixture")" = '.playwright/e2e/react-perf-smoke.spec.ts' ]
}

@test "X2: release-scrub names no retired root frontend path, and a fixture that does is reported" {
  [ -z "$(retired_paths_in_scrub < "$REPO_ROOT/.gaia/release-scrub.yml")" ]
  fixture="$BATS_TEST_TMPDIR/scrub-old"
  printf '    paths:\n      - "app/routes/x.tsx"\n' > "$fixture"
  [ "$(retired_paths_in_scrub < "$fixture")" = 'app/routes/x.tsx' ]
}

@test "S1: the maintainer-only package.json keys are stripped from both shipped package.json files" {
  staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging/frontend" "$staging/.gaia"
  printf '{"name":"x","bin":{"gaia":"./g"},"scripts":{"test:forensics":"a","test:sandbox":"b","dev":"c"}}\n' > "$staging/package.json"
  printf '{"name":"frontend","bin":{"x":"./x"},"scripts":{"test:forensics":"a","dev":"c"}}\n' > "$staging/frontend/package.json"
  # Only the package.json json-strip transform: keep the first transform block
  # that names package.json by writing a minimal config of our own with the
  # keys the real config lists.
  config="$BATS_TEST_TMPDIR/scrub.yml"
  keys="$(awk '/^  - type: json-strip$/{f=1} f&&/^    keys:/{k=1;next} k&&/^      - /{print;next} k&&!/^      - /{exit}' "$REPO_ROOT/.gaia/release-scrub.yml")"
  paths="$(awk '/^  - type: json-strip$/{f=1} f&&/^    paths:/{p=1;next} p&&/^      - /{print;next} p&&!/^      - /{exit}' "$REPO_ROOT/.gaia/release-scrub.yml")"
  printf '%s\n' "$paths" | grep -qF '"package.json"'
  printf '%s\n' "$paths" | grep -qF '"frontend/package.json"'
  printf '%s\n' "$keys" | grep -qF '"bin"'
  printf 'transforms:\n  - type: json-strip\n    paths:\n%s\n    keys:\n%s\n' "$paths" "$keys" > "$config"
  run "$MAINTAINER_CLI" release scrub "$staging" --config "$config"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.bin // "absent"' "$staging/package.json")" = absent ]
  [ "$(jq -r '.scripts["test:forensics"] // "absent"' "$staging/package.json")" = absent ]
  [ "$(jq -r '.bin // "absent"' "$staging/frontend/package.json")" = absent ]
  [ "$(jq -r '.scripts["test:forensics"] // "absent"' "$staging/frontend/package.json")" = absent ]
  [ "$(jq -r '.scripts.dev' "$staging/frontend/package.json")" = c ]
}

# The `## [Unreleased]` body of CHANGELOG.md, up to the next `## [` heading.
unreleased_body() {
  awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f{print}' "$1"
}

@test "L1: the Unreleased Breaking entry leads with the routing line" {
  body="$(unreleased_body "$REPO_ROOT/CHANGELOG.md")"
  first_after_heading="$(printf '%s\n' "$body" | awk '/^### Breaking$/{f=1;next} f&&NF{print;exit}')"
  [ "$first_after_heading" = "$ROUTING_LINE" ]
}

@test "L2: the Unreleased section carries no em dash, and the check sees one when present" {
  dash="$(printf '\342\200\224')"
  body="$(unreleased_body "$REPO_ROOT/CHANGELOG.md")"
  printf '%s\n' "$body" | grep -qF -- "$dash" && return 1
  printf 'a %s b\n' "$dash" | grep -qF -- "$dash"
}
