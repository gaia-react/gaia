#!/usr/bin/env bats
#
# SPEC-092 UAT-019: the shipped CI path filters select the app's files under
# frontend/ and skip the retired root forms. A filter that still reads root
# `app/` reports a required check green without running anything.
#
#   tests.yml     the ERE in `pattern='...'` (matched with grep -E)
#   chromatic.yml the dorny/paths-filter `code:` globs (picomatch semantics)
#
# The "base" controls are inline copies of the pre-move filters, so the guard
# is proven able to fail without reading git history (this PR is squash-merged).

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TESTS_YML="$REPO_ROOT/.github/workflows/tests.yml"
  CHROMATIC_YML="$REPO_ROOT/.github/workflows/chromatic.yml"
  OLD_TESTS_PATTERN='^(app|test)/|^\.playwright/|^\.storybook/|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|\.npmrc|\.node-version)$|^tsconfig[^/]*\.json$|^(vite|vitest|playwright|eslint|react-router|doctor|knip|prettier|stylelint)\.config\.|^\.github/workflows/tests\.yml$'
  NO_COMPILER_TESTS_PATTERN='^frontend/(app|test)/|^frontend/\.playwright/|^frontend/\.storybook/|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|\.npmrc|\.node-version)$|^frontend/package\.json$|^frontend/tsconfig[^/]*\.json$|^frontend/dev-ports[^/]*\.ts$|^frontend/components\.json$|^frontend/(vite|vitest|playwright|eslint|react-router|doctor|knip|prettier|stylelint)\.config\.|^\.gaia/packages\.json$|^frontend/gaia\.package\.json$|^\.github/workflows/tests\.yml$'
  OLD_CHROMATIC_GLOBS="app/**
.storybook/**
public/**
package.json
pnpm-lock.yaml
tsconfig*.json
vite.config.*
.github/workflows/chromatic.yml
.github/actions/**"
}

tests_pattern() {
  sed -n "s/^[[:space:]]*pattern='\(.*\)'[[:space:]]*$/\1/p" "$TESTS_YML"
}

# The quoted entries of the `code:` list inside the paths-filter `filters:` block.
chromatic_globs() {
  awk '
    /^[[:space:]]+code:[[:space:]]*$/ { in_code = 1; next }
    in_code && /^[[:space:]]*-[[:space:]]*'"'"'/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*'"'"'/, "", line)
      sub(/'"'"'[[:space:]]*$/, "", line)
      print line
      next
    }
    in_code && /^[[:space:]]*#/ { next }
    in_code { in_code = 0 }
  ' "$CHROMATIC_YML"
}

# Prints "select" or "skip" for one path against a newline-separated glob list.
# picomatch (dorny/paths-filter's matcher, dot:true) when a copy sits in a
# node_modules tree; otherwise node:path matchesGlob, which agrees on every
# glob used here.
glob_verdict() {
  local globs="$1" candidate="$2" picomatch_path
  picomatch_path="$(find "$REPO_ROOT/node_modules" "$REPO_ROOT/frontend/node_modules" "$REPO_ROOT/.gaia/cli/node_modules" \
    -path '*/picomatch/index.js' -not -path '*/test/*' 2>/dev/null | head -n 1)"
  GLOBS="$globs" CANDIDATE="$candidate" PICOMATCH="$picomatch_path" node -e '
    const globs = process.env.GLOBS.split("\n").filter(Boolean);
    const candidate = process.env.CANDIDATE;
    let hit;
    if (process.env.PICOMATCH) {
      const picomatch = require(process.env.PICOMATCH);
      hit = globs.some((glob) => picomatch(glob, { dot: true })(candidate));
    } else {
      hit = globs.some((glob) => require("node:path").matchesGlob(candidate, glob));
    }
    process.stdout.write(hit ? "select" : "skip");
  '
}

tests_verdict() {
  if printf '%s\n' "$2" | grep -qE "$1"; then printf 'select'; else printf 'skip'; fi
}

@test "tests.yml: the extracted pattern is non-empty" {
  [ -n "$(tests_pattern)" ]
}

@test "tests.yml: frontend app, e2e, manifest and lockfile changes select" {
  local pattern candidate
  pattern="$(tests_pattern)"
  for candidate in frontend/app/routes/x.tsx frontend/.playwright/a.spec.ts frontend/package.json pnpm-lock.yaml \
    frontend/test/a.test.ts frontend/vite.config.ts frontend/gaia.package.json .gaia/packages.json \
    frontend/dev-ports.ts frontend/dev-ports-vite-plugin.ts frontend/dev-ports-reuse.ts \
    frontend/react-compiler.config.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "tests.yml: harness, wiki and the retired root app/ skip" {
  local pattern candidate
  pattern="$(tests_pattern)"
  for candidate in wiki/a.md .claude/rules/a.md .gaia/scripts/a.sh app/x.tsx .playwright/a.spec.ts test/a.test.ts; do
    [ "$(tests_verdict "$pattern" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "tests.yml: the pre-move pattern skips frontend/app (the guard can fail)" {
  [ "$(tests_verdict "$OLD_TESTS_PATTERN" frontend/app/routes/x.tsx)" = skip ]
}

@test "tests.yml: the pattern without react-compiler skips the compiler config (the guard can fail)" {
  [ "$(tests_verdict "$NO_COMPILER_TESTS_PATTERN" frontend/react-compiler.config.ts)" = skip ]
}

@test "chromatic.yml: extracted globs include the descriptor entries" {
  local globs
  globs="$(chromatic_globs)"
  printf '%s\n' "$globs" | grep -qxF 'frontend/app/**'
  printf '%s\n' "$globs" | grep -qxF 'frontend/gaia.package.json'
  printf '%s\n' "$globs" | grep -qxF '.gaia/packages.json'
  printf '%s\n' "$globs" | grep -qxF '.github/actions/**'
}

@test "chromatic.yml: frontend storybook inputs and the setup action select" {
  local globs candidate
  globs="$(chromatic_globs)"
  for candidate in frontend/app/components/X/index.tsx frontend/public/a.png frontend/vite.config.ts frontend/tsconfig.json \
    frontend/react-compiler.config.ts frontend/.storybook/main.ts frontend/package.json pnpm-workspace.yaml .github/actions/gaia-setup-node/action.yml; do
    [ "$(glob_verdict "$globs" "$candidate")" = select ] || { printf 'did not select: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "chromatic.yml: the globs without react-compiler skip the compiler config (the guard can fail)" {
  local globs
  globs="$(chromatic_globs | grep -vxF 'frontend/react-compiler.config.*')"
  [ "$(glob_verdict "$globs" frontend/react-compiler.config.ts)" = skip ]
}

@test "chromatic.yml: wiki and the retired root app/ skip" {
  local globs candidate
  globs="$(chromatic_globs)"
  for candidate in wiki/a.md app/x.tsx public/a.png .storybook/main.ts; do
    [ "$(glob_verdict "$globs" "$candidate")" = skip ] || { printf 'selected: %s\n' "$candidate" >&2; return 1; }
  done
}

@test "chromatic.yml: the pre-move globs skip frontend/app (the guard can fail)" {
  [ "$(glob_verdict "$OLD_CHROMATIC_GLOBS" frontend/app/components/X/index.tsx)" = skip ]
}

# Every path-bearing key in both workflows resolves under frontend/, or is the
# one root workspace lockfile.
@test "workflows: no bare app/, .playwright/ or storybook-static reference" {
  local offenders
  offenders="$(grep -nE "(path|working-directory|storybookBuildDir|externals):[[:space:]]*['\"]?(\./)?(\.playwright|storybook-static|app)(/|['\"]?[[:space:]]*$)" \
    "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
  # Shell-line uses of the build output and the playwright runner.
  offenders="$(grep -nE "(^|[[:space:]])(-d |-rl '[^']*' )storybook-static|run: pnpm exec (playwright|storybook)" "$TESTS_YML" "$CHROMATIC_YML" || true)"
  [ -z "$offenders" ] || { printf '%s\n' "$offenders" >&2; return 1; }
}

@test "workflows: artifact, build dir and externals resolve under frontend/" {
  grep -qE "^[[:space:]]+path: frontend/\.playwright/output$" "$TESTS_YML"
  grep -qE "storybookBuildDir: 'frontend/storybook-static'" "$CHROMATIC_YML"
  grep -qE "externals: 'frontend/app/styles/tailwind\.css'" "$CHROMATIC_YML"
  grep -qE "pnpm -C frontend exec playwright test" "$TESTS_YML"
  grep -qE "pnpm -C frontend exec storybook build" "$CHROMATIC_YML"
}

@test "workflows: the bare-path assertion can fail (it flags a pre-move value)" {
  local scratch
  scratch="$BATS_TEST_TMPDIR/old.yml"
  printf '          path: .playwright/output\n          storybookBuildDir: '"'"'storybook-static'"'"'\n' > "$scratch"
  run grep -nE "(path|working-directory|storybookBuildDir|externals):[[:space:]]*['\"]?(\./)?(\.playwright|storybook-static|app)(/|['\"]?[[:space:]]*$)" "$scratch"
  [ "$status" -eq 0 ]
}

@test "gaia-setup-node: cache-dependency-path stays the single root lockfile" {
  run grep -nE 'cache-dependency-path:[[:space:]]*frontend/' "$REPO_ROOT/.github/actions/gaia-setup-node/action.yml" "$TESTS_YML" "$CHROMATIC_YML"
  [ "$status" -eq 1 ]
}
