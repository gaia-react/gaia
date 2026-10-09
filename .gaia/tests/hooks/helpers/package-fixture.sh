#!/usr/bin/env bash
# Shared fixture writers for the RED-gate suites that read the package registry
# and descriptor (SPEC-092): red-verify-commit-check, red-verify-e2e,
# capture-red-observations and worthiness-presence-check.
#
# Every writer emits LITERAL JSON. A "today's layout" fixture must never copy the
# live `.gaia/packages.json` or `gaia.package.json`: those change when the
# registry flips from path `.` to path `frontend`, and a fixture that tracked
# them would silently stop proving the layout it is named for.
#
# Source it from `setup()`, never `setup_file()`, for the reason run-hook.sh
# beside it gives: bats runs `setup_file` in a separate process, so a function
# defined there is invisible to test bodies.

# write_package_registry <root> <registry-json>
write_package_registry() {
  mkdir -p "$1/.gaia"
  printf '%s\n' "$2" >"$1/.gaia/packages.json"
}

# write_package_descriptor <root> <package-dir> [unit-json] [strict-json] [emergent-json]
#
# Writes `<root>/<package-dir>/gaia.package.json` (the package dir `.` writes
# `<root>/gaia.package.json`) with the C2 values for every key the guards here
# read. The three optional arguments override the globs a case needs to move: the
# unit-test globs, the strict-candidate globs, and the emergent-test globs, each
# a JSON array of package-relative globs.
write_package_descriptor() {
  local root="$1" package_dir="$2"
  local unit="${3:-[\"app/**/*.test.ts\",\"app/**/*.test.tsx\"]}"
  local strict="${4:-[\"app/utils/**\",\"app/services/**\",\"app/hooks/**\",\"app/components/**/*.ts\"]}"
  local emergent="${5:-[\"app/components/**/*.test.ts\",\"app/components/**/*.test.tsx\",\".playwright/**/*.spec.ts\",\".playwright/**/*.spec.tsx\",\".playwright/**/*.test.ts\",\".playwright/**/*.test.tsx\"]}"
  local target="$root/$package_dir/gaia.package.json"
  if [ "$package_dir" = . ]; then
    target="$root/gaia.package.json"
  fi
  mkdir -p "$(dirname "$target")"
  jq -n --argjson unit "$unit" --argjson strict "$strict" --argjson emergent "$emergent" '{
    schemaVersion: 1,
    name: "frontend",
    globs: {
      tddUnitTests: $unit,
      tddStrictCandidates: $strict,
      emergentTests: $emergent,
      preCommitSource: ["app/**", "test/**", ".storybook/**", ".playwright/**"],
      doctorConfigs: ["doctor.config.*", "react-doctor.config.*"],
      dependencyManifests: ["package.json"]
    },
    wiki: {
      sourcePaths: ["app/"],
      inventoryPaths: ["app/components/", "app/hooks/", "app/pages/", "app/services/"],
      flowPaths: ["app/middleware/", "app/routes.ts", "app/i18n.ts", "app/sessions.server/"]
    }
  }' >"$target"
}

# write_packages_today <root>
# The transitional layout: the app at the repo root (registry path `.`), with the
# default descriptor beside the registry.
write_packages_today() {
  write_package_registry "$1" '[{"name":"frontend","path":"."}]'
  write_package_descriptor "$1" .
}

# write_packages_moved <root> [unit-json] [strict-json] [emergent-json]
# The 2.0.0 layout: the app at `frontend/` (registry path `frontend`).
write_packages_moved() {
  local root="$1"
  shift
  write_package_registry "$root" '[{"name":"frontend","path":"frontend"}]'
  write_package_descriptor "$root" frontend "$@"
}
