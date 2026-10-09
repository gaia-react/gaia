#!/usr/bin/env bats
# .gaia/scripts/cli-autobundle.sh: rebuilds and stages the committed CLI bundles
# when a commit stages CLI source.
#
# Each test builds a sandbox git repo with a fake `.gaia/cli/` and a stub `pnpm`
# on PATH whose `bundle` writes deterministic new bundle content. The real
# esbuild and the real pnpm never run. Assertion style per
# .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/cli-autobundle.sh"
  [ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; return 1; }

  REPO="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/autobundle.XXXXXX")" && pwd -P)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  mkdir -p "$REPO/.gaia/cli/src" "$REPO/.gaia/cli/node_modules/.bin"
  echo '{}' > "$REPO/.gaia/cli/package.json"
  echo '{}' > "$REPO/.gaia/cli/tsconfig.json"
  echo 'export const a = 1;' > "$REPO/.gaia/cli/src/a.ts"
  echo 'export const b = 1;' > "$REPO/.gaia/cli/src/b.ts"
  echo 'old adopter bundle' > "$REPO/.gaia/cli/gaia"
  echo 'old maintainer bundle' > "$REPO/.gaia/cli/gaia-maintainer"
  echo '# readme' > "$REPO/README.md"
  : > "$REPO/.gaia/cli/node_modules/.bin/esbuild"
  chmod +x "$REPO/.gaia/cli/node_modules/.bin/esbuild"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m init

  # Stub pnpm: `pnpm -C <dir> bundle` rewrites both bundles, or fails when
  # STUB_PNPM_FAIL is set.
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/usr/bin/env bash
dir=""
if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
if [ "$1" != "bundle" ]; then echo "stub pnpm: unexpected $*" >&2; exit 9; fi
if [ -n "${STUB_PNPM_FAIL:-}" ]; then echo "stub bundle exploded" >&2; exit 1; fi
echo 'new adopter bundle' > "$dir/gaia"
echo 'new maintainer bundle' > "$dir/gaia-maintainer"
STUB
  chmod +x "$STUB_BIN/pnpm"
  PATH="$STUB_BIN:$PATH"
  export PATH
}

staged() {
  git -C "$REPO" diff --cached --name-only -z | tr '\0' '\n'
}

@test "no trigger path staged: silent exit 0, bundles not staged" {
  echo 'more' >> "$REPO/README.md"
  git -C "$REPO" add README.md
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(staged)" = "README.md" ]
}

@test "a staged src change rebuilds and stages both bundles only" {
  echo 'export const a = 2;' > "$REPO/.gaia/cli/src/a.ts"
  git -C "$REPO" add .gaia/cli/src/a.ts
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebuilt"* ]]
  [ "$(staged)" = $'.gaia/cli/gaia\n.gaia/cli/gaia-maintainer\n.gaia/cli/src/a.ts' ]
  [ "$(git -C "$REPO" show :.gaia/cli/gaia)" = "new adopter bundle" ]
}

@test "a staged deletion under src triggers" {
  git -C "$REPO" rm --quiet .gaia/cli/src/b.ts
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$(staged)" == *".gaia/cli/gaia-maintainer"* ]]
}

@test "a staged .gaia/cli/package.json change triggers" {
  echo '{"a":1}' > "$REPO/.gaia/cli/package.json"
  git -C "$REPO" add .gaia/cli/package.json
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$(staged)" == *".gaia/cli/gaia"$'\n'* ]]
}

@test "a staged root pnpm-lock.yaml change alone triggers" {
  echo 'lockfileVersion: 9' > "$REPO/pnpm-lock.yaml"
  git -C "$REPO" add pnpm-lock.yaml
  git -C "$REPO" commit --quiet -m "add root lockfile"
  echo 'lockfileVersion: 10' > "$REPO/pnpm-lock.yaml"
  git -C "$REPO" add pnpm-lock.yaml
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(staged)" = $'.gaia/cli/gaia\n.gaia/cli/gaia-maintainer\npnpm-lock.yaml' ]
}

@test "a staged .gaia/cli/tsconfig.json change triggers" {
  echo '{"a":1}' > "$REPO/.gaia/cli/tsconfig.json"
  git -C "$REPO" add .gaia/cli/tsconfig.json
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$(staged)" == *".gaia/cli/gaia-maintainer"* ]]
}

@test "unstaged src modification beside a staged one refuses and stages nothing more" {
  echo 'export const a = 2;' > "$REPO/.gaia/cli/src/a.ts"
  git -C "$REPO" add .gaia/cli/src/a.ts
  echo 'export const b = 2;' > "$REPO/.gaia/cli/src/b.ts"
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *".gaia/cli/src/b.ts"* ]]
  [ "$(staged)" = ".gaia/cli/src/a.ts" ]
}

@test "untracked file under src beside a staged change refuses" {
  echo 'export const a = 2;' > "$REPO/.gaia/cli/src/a.ts"
  git -C "$REPO" add .gaia/cli/src/a.ts
  echo 'export const c = 1;' > "$REPO/.gaia/cli/src/c.ts"
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *".gaia/cli/src/c.ts"* ]]
  [ "$(staged)" = ".gaia/cli/src/a.ts" ]
}

@test "missing esbuild install warns and continues without staging bundles" {
  rm "$REPO/.gaia/cli/node_modules/.bin/esbuild"
  echo 'export const a = 2;' > "$REPO/.gaia/cli/src/a.ts"
  git -C "$REPO" add .gaia/cli/src/a.ts
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm install --frozen-lockfile"* ]]
  [[ "$output" == *"pnpm -C .gaia/cli bundle"* ]]
  [ "$(staged)" = ".gaia/cli/src/a.ts" ]
}

@test "a failing bundle exits 1 with the build error and stages no bundle" {
  echo 'export const a = 2;' > "$REPO/.gaia/cli/src/a.ts"
  git -C "$REPO" add .gaia/cli/src/a.ts
  STUB_PNPM_FAIL=1 run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stub bundle exploded"* ]]
  [ "$(staged)" = ".gaia/cli/src/a.ts" ]
}

@test "adopter-shaped tree with no .gaia/cli/src and nothing staged exits 0 silently" {
  rm -rf "$REPO/.gaia/cli/src"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "drop src"
  run bash "$SCRIPT" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "usage error exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$REPO" extra
  [ "$status" -eq 2 ]
}
