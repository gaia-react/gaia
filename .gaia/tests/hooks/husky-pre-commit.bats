#!/usr/bin/env bats

# Tests for .husky/pre-commit.
#
# The hook decides whether a staged change is lint-worthy and runs the Quality
# Gate floor (pnpm typecheck / lint-staged / test:lint-staged) only when it is.
# The decision is descriptor-driven: .gaia/scripts/precommit-packages.sh reads
# the package registry and each descriptor's `preCommitSource` globs and tells
# the POSIX hook which package directories have a counted staged path. A
# directory that .lintstagedrc.json covers but the descriptor never names is the
# live failure mode: a commit scoped to that directory alone matches nothing,
# the skip branch fires, and the change lands unlinted and untypechecked.
#
# Husky runs the hook as `sh -e <hook>` (.husky/_/h), so these tests do too.
#
# `pnpm` is stubbed onto PATH as a recorder, so the tests assert on which gate
# steps the hook invoked, and in which package directory, rather than on their
# real output. The suite needs no node_modules and stays fast.
#
# The "path ." fixtures write a literal registry and descriptor into the sandbox
# (the transitional layout) and never copy the live files, so the suite states
# what it asserts and stays green once the live registry points at `frontend`.
# The one test that reads the live descriptor says so.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.husky/pre-commit"

  # Physical path: the hook takes its root from `git rev-parse --show-toplevel`,
  # which resolves symlinks (macOS /var is a link to /private/var).
  REPO=$(cd "$(mktemp -d -t husky-pre-commit-XXXXXX)" && pwd -P)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # The hook finds its helper and the registry reader under the repo root it
  # runs in, so the sandbox carries copies of both (the code under test).
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"

  # Every stub invocation appends its argv and succeeds, so the hook runs to
  # completion under `sh -e` and each test reads back which steps fired.
  PNPM_LOG="$REPO/pnpm.log"
  STUB_BIN="$REPO/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
  : > "$PNPM_LOG"
}

# A descriptor with every required key; $1 is the destination directory, $2 the
# `preCommitSource` array as JSON.
write_descriptor() {
  local directory="$1" pre_commit_source="$2"
  mkdir -p "$directory"
  cat > "$directory/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "frontend",
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

# The transitional layout: the frontend package lives at the repo root.
use_root_package() {
  mkdir -p "$REPO/.gaia"
  printf '[{"name":"frontend","path":"."}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO" '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

# The 2.0.0 layout: the frontend package lives at frontend/.
use_frontend_package() {
  mkdir -p "$REPO/.gaia"
  printf '[{"name":"frontend","path":"frontend"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/frontend" '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

run_hook() {
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Stage one file at a repo-relative path, then run the hook from the repo root
# the way husky does.
stage_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Commit one file, then stage its deletion and run the hook. A deletion-only
# commit is the arm-agnostic case: it matches an arm only when that arm's
# --diff-filter carries `D`.
stage_deletion_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit --quiet -m "add $path"
  git -C "$REPO" rm --quiet "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Assertion style: .claude/rules/bats-assertions.md.
# $1 is the package directory the gate must run in (default: the repo root).
assert_gate_ran() {
  local package_path="${1:-$REPO}"
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"
  grep -qxF -- "-C $package_path typecheck" "$PNPM_LOG"
  grep -qxF -- "-C $package_path exec lint-staged" "$PNPM_LOG"
  grep -qxF -- "-C $package_path test:lint-staged" "$PNPM_LOG"
}

assert_gate_skipped() {
  [ "$status" -eq 0 ]
  grep -qF -- "skipping lint-staged" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

# --- a change in a lintable directory runs the gate ---

@test "app/ change runs the gate" {
  use_root_package
  stage_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ change runs the gate" {
  use_root_package
  stage_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ change runs the gate" {
  use_root_package
  stage_and_run ".storybook/preview.ts"
  assert_gate_ran
}

# .lintstagedrc.json lints {.storybook,.playwright}/**/*.{ts,tsx}, so the
# .playwright half needs an arm of its own; without one that entry is
# unreachable for an e2e-spec-only commit, the most common .playwright shape.
@test ".playwright/ change runs the gate" {
  use_root_package
  stage_and_run ".playwright/e2e/home.spec.ts"
  assert_gate_ran
}

# --- a deletion in a lintable directory runs the gate ---
#
# Deleting a shared helper, fixture, or spec breaks the types of every file that
# imported it, which is exactly what the skipped `pnpm typecheck` would catch.
# All four arms therefore carry `D`; these tests pin that agreement so a future
# edit cannot narrow one arm back without a failure.

@test "app/ deletion runs the gate" {
  use_root_package
  stage_deletion_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ deletion runs the gate" {
  use_root_package
  stage_deletion_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ deletion runs the gate" {
  use_root_package
  stage_deletion_and_run ".storybook/preview.ts"
  assert_gate_ran
}

@test ".playwright/ deletion runs the gate" {
  use_root_package
  stage_deletion_and_run ".playwright/e2e/home.spec.ts"
  assert_gate_ran
}


@test "a change matching no lintable directory skips the gate" {
  use_root_package
  stage_and_run "docs/notes.md"
  assert_gate_skipped
}

# --- every gated directory is reachable by lint-staged ---
#
# The descriptor's `preCommitSource` globs and the package's .lintstagedrc.json
# are the two halves of one contract: a descriptor glob decides the gate runs, a
# lint-staged glob decides lint-staged has anything to hand ESLint. A glob no
# lint-staged key covers is the silent half of the failure mode the header
# describes: the hook prints "running lint-staged", lint-staged matches zero
# files and exits 0, and the commit lands with ESLint skipped for that whole
# directory while typecheck and Vitest still report.
#
# Both directions are derived and checked, one guard each: this one asks whether
# every gated directory reaches a glob, the one below it whether every glob
# reaches a gated directory. These two read the LIVE registry, descriptor, and
# lint-staged config; everything else in this file reads a sandbox.

# The live frontend package directory, from the committed registry. When the
# move has landed the config sits under it; between the rename-only commit and
# the registry flip the registry still says `.`, so fall back to frontend/.
live_package_directory() {
  local registered
  registered=$(jq -r '.[] | select(.name == "frontend") | .path' "$REPO_ROOT/.gaia/packages.json") || return 1
  [ -n "$registered" ] || return 1
  printf '%s\n' "$registered"
}

live_lintstaged_file() {
  local directory candidate
  directory=$(live_package_directory) || return 1
  for candidate in "$REPO_ROOT/$directory/.lintstagedrc.json" "$REPO_ROOT/frontend/.lintstagedrc.json"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

live_descriptor_file() {
  local directory
  directory=$(live_package_directory) || return 1
  printf '%s\n' "$REPO_ROOT/$directory/gaia.package.json"
}

# Every directory the descriptor's `preCommitSource` globs gate, one per line.
arm_directories() {
  jq -r '.globs.preCommitSource[]' "$(live_descriptor_file)" | sed -n 's#^\(.*/\)\*\*$#\1#p'
}

# Every `preCommitSource` entry, counted by a pattern deliberately wider than
# the derivation above reads. A count taken with the same pattern as the
# extraction agrees with it on every spelling the pattern cannot read, so the
# two readings would confirm each other's blind spot; this one over-counts, so
# a glob the derivation cannot read reds the guard.
arm_assignment_count() {
  jq -r '.globs.preCommitSource | length' "$(live_descriptor_file)"
}

# The lint-staged glob keys whose task chain actually invokes ESLint. Reading
# the keys alone would accept a chain that runs only prettier or stylelint,
# which is the very outcome the arm is supposed to prevent, and chains of that
# shape already live in this config.
eslint_globs() {
  jq -r 'to_entries[]
         | select(any(.value[]?; type == "string" and startswith("eslint")))
         | .key' "$(live_lintstaged_file)"
}

# The glob keys whose chain mentions ESLint anywhere, counted by a pattern
# deliberately wider than the derivation above reads, for the same reason
# arm_assignment_count is wider than arm_directories. A count taken with the same
# `startswith` test would agree with the derivation on every chain that spelling
# cannot reach (`pnpm exec eslint`, a path-qualified binary), confirming its
# blind spot instead of exposing it. This one over-counts, so a key the
# derivation silently drops reds the guard rather than leaving its directory
# unchecked.
#
# `tostring` rather than `.value[]?` is what keeps it wider on both axes.
# lint-staged accepts a bare string chain as well as an array, and `.value[]?`
# yields nothing for a string, so the derivation's own iteration silently drops
# `"scripts/**/*.ts": "eslint --fix"`. A count that iterated the same way would
# drop it too and agree, which is this control's failure mode rather than its
# job. `tostring` reads a string value, an array value, and any nesting.
eslint_glob_mentions() {
  jq -r '[to_entries[] | select(.value | tostring | test("eslint"))]
         | length' "$(live_lintstaged_file)"
}

# Every directory one glob key hands ESLint files under, one per line, and
# nothing at all for a key of any other shape.
#
# This reads the literal shape `<dir>/**/<rest>`, in the key itself or in each
# alternative of its leading brace group, rather than matching a probe path
# against the key. Matching would need lint-staged's own matcher: bash's [[ ]]
# lets `*` cross a `/` where picomatch does not, so `app/*.{ts,tsx}` would
# satisfy a probe while leaving app/routes/home.tsx unlinted, which is exactly
# the miss these guards exist to catch. Demanding the recursive shape is the
# narrower question, and it fails closed in both directions: a key written some
# other way yields no directory, which reds the arm-to-glob guard on the arm it
# should have covered and reds the glob-to-arm guard on the key itself.
glob_head_directories() {
  local glob="$1" head alt
  # A second recursive segment yields nothing, because the cut below takes the
  # head at the FIRST `/**/`: `app/**/routes/**/*.ts` would reduce to a bare
  # `app/` and green the `app/` arm while the key hands ESLint only
  # app/<any>/routes/<any>/*.ts, leaving app/other.ts unlinted. That reduction
  # carries no glob metacharacter, so the alternative validation below cannot
  # reach it; the shape has to be refused before the cut.
  #
  # Refusing the shape rather than cutting at the LAST `/**/` instead: a lazy
  # `${glob%/\*\*/*}` cut looks equivalent and reds `app/**/**/*.ts`, whose
  # doubled globstar is the same directory as one and is legitimately `app/`.
  case "$glob" in
    *"/**/"*"/**/"*) return 0 ;;
    *"/**/"*) head="${glob%%/\*\*/*}" ;;
    *) return 0 ;;
  esac
  case "$head" in
    "{"*"}")
      head="${head#\{}"; head="${head%\}}"
      head=$(printf '%s' "$head" | tr ',' '\n')
      ;;
  esac
  # Validate every alternative before emitting any, so a head this reader cannot
  # expand yields nothing rather than something. A brace group that is not the
  # whole head (`app/{routes,components}`) is the case that makes the difference:
  # emitting it literally would leave the shape check satisfied and send the
  # guard's operator to add a hook arm named after an unexpanded glob, when the
  # repair is to rewrite the key.
  #
  # A slash is not that case and must not join it. A plain nested head
  # (`app/routes`, from `app/routes/**/*.ts`) is fully readable, and rejecting it
  # yielded no directory, which reds the glob-to-arm guard on a legitimate key
  # while telling its operator the key had no recursive head to rewrite toward.
  while IFS= read -r alt; do
    case "$alt" in
      "" | *[{}]*) return 0 ;;
    esac
  done <<<"$head"
  while IFS= read -r alt; do
    printf '%s/\n' "$alt"
  done <<<"$head"
}

# Whether one glob key hands ESLint the files under directory $1.
#
# Exact, where arm_names_directory below is a substring relation, and the asymmetry is
# the contract rather than an oversight. This direction asks whether an arm's
# whole directory reaches ESLint, and a nested head covers only part of it:
# `app/routes/**/*.ts` leaves app/other.ts unlinted while the `app/` arm still
# fires, which is the miss this direction exists to catch. Loosening it to a
# substring would green exactly that case.
#
# The other spelling of that miss, a key carrying a second recursive segment,
# never reaches this check at all: glob_head_directories refuses the shape and yields
# nothing, so the key reds both directions instead of satisfying either.
glob_covers_directory() {
  local directory="$1" glob="$2"
  glob_head_directories "$glob" | grep -qxF -- "$directory"
}

# Whether some hook arm's grep reaches every file under directory $1, given the
# newline-separated arm directories in $2.
#
# Substring, because the arms are unanchored greps (.husky/pre-commit documents
# the lack of anchoring as deliberate). Every path under a directory carries that
# directory as a prefix, so an arm whose pattern is a substring of the directory
# is a substring of every path beneath it: the `app/` arm reaches all of
# `app/routes/`. Demanding an exact name here would red a nested glob key the
# hook already covers.
arm_names_directory() {
  local directory="$1" arm
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    case "$directory" in
      *"$arm"*) return 0 ;;
    esac
  done <<<"$2"
  return 1
}

@test "every pre-commit arm directory is covered by an ESLint lint-staged glob" {
  local directories globs derived assignments directory glob covered
  directories=$(arm_directories)
  derived=$(printf '%s\n' "$directories" | grep -c . || true)
  assignments=$(arm_assignment_count)
  [ "$derived" -gt 0 ]
  [ "$derived" -eq "$assignments" ]

  # Captured rather than piped, so a jq that is absent or cannot parse the
  # config reports itself instead of emptying the loop below and blaming the
  # first arm for an uncovered directory.
  globs=$(eslint_globs) || {
    printf 'could not read .lintstagedrc.json (is jq installed?)\n' >&2
    return 1
  }
  [ -n "$globs" ] || {
    printf '.lintstagedrc.json declares no glob whose chain invokes eslint\n' >&2
    return 1
  }

  while IFS= read -r directory; do
    covered=0
    while IFS= read -r glob; do
      if glob_covers_directory "$directory" "$glob"; then covered=1; fi
    done <<<"$globs"
    if [ "$covered" -ne 1 ]; then
      printf 'hook arm %s has no ESLint .lintstagedrc.json glob\n' "$directory" >&2
      return 1
    fi
  done <<<"$directories"
}

# --- every ESLint lint-staged glob's directory is named by a hook arm ---
#
# The other half of the same contract, and the direction the header calls the
# live failure mode: a glob whose directory no arm greps for means a commit
# scoped to that directory alone matches nothing, the else branch fires, and the
# change lands unlinted *and* untypechecked. That is strictly worse than the
# uncovered-arm case the guard above catches, which still runs typecheck and
# Vitest.
#
# The glob set is derived from .lintstagedrc.json rather than restated here, and
# a key whose chain mentions ESLint in a spelling the derivation cannot read is
# counted separately, so a config entry added with no arm reds here instead of
# shipping behind a guard that never saw it.
@test "every ESLint lint-staged glob directory is named by a pre-commit arm" {
  local directories globs derived mentions glob glob_directories directory
  directories=$(arm_directories)
  [ -n "$directories" ]

  # Captured rather than piped, for the reason the guard above gives: a jq that
  # is absent or cannot parse the config must report itself rather than empty
  # the loop below into a vacuous pass.
  globs=$(eslint_globs) || {
    printf 'could not read .lintstagedrc.json (is jq installed?)\n' >&2
    return 1
  }
  [ -n "$globs" ] || {
    printf '.lintstagedrc.json declares no glob whose chain invokes eslint\n' >&2
    return 1
  }
  derived=$(printf '%s\n' "$globs" | grep -c .)
  mentions=$(eslint_glob_mentions)
  [ "$derived" -eq "$mentions" ]

  while IFS= read -r glob; do
    glob_directories=$(glob_head_directories "$glob")
    [ -n "$glob_directories" ] || {
      printf 'eslint glob %s does not reduce to a plain recursive <dir>/**/ head, so no directory can be checked against the arms\n' "$glob" >&2
      return 1
    }
    while IFS= read -r directory; do
      if ! arm_names_directory "$directory" "$directories"; then
        printf 'ESLint .lintstagedrc.json glob %s covers %s, which no pre-commit arm reaches\n' "$glob" "$directory" >&2
        return 1
      fi
    done <<<"$glob_directories"
  done <<<"$globs"
}

# --- the head reader and the arm relation the guards above are built on ---
#
# Both guards above reduce a glob key to directories and compare those against
# the arms, so a head shape the reader mis-reads, or an arm relation that does
# not model the greps, is a false red or a silent pass on both. The live
# .lintstagedrc.json exercises only the head shapes it happens to use, and a
# shape it does not carry is exactly where the reader has been wrong, so these
# drive the helpers directly, one case per shape rather than one representative.

# `app/**/**/*.ts` is the one case that reds if the cut below the reader's
# second-recursive-segment refusal is swapped to a lazy `${glob%/\*\*/*}`. A
# doubled globstar is the same directory as one, so its head is `app`, and the
# lazy cut yields `app/**` instead. It is what keeps that refusal from looking
# like an interchangeable spelling of the lazy cut.
@test "glob_head_directories reduces each head shape it can expand to that head's directories" {
  local glob expect got
  while IFS='|' read -r glob expect; do
    [ -n "$glob" ] || continue
    got=$(glob_head_directories "$glob" | tr '\n' ' ')
    if [ "${got% }" != "$expect" ]; then
      printf 'glob_head_directories %s yielded "%s", expected "%s"\n' "$glob" "${got% }" "$expect" >&2
      return 1
    fi
  done <<'CASES'
app/**/*.{ts,tsx}|app/
app/routes/**/*.ts|app/routes/
{.storybook,.playwright,test}/**/*.{ts,tsx}|.storybook/ .playwright/ test/
{app/routes,test}/**/*.ts|app/routes/ test/
app/**/**/*.ts|app/
CASES
}

# `app}/**/*.ts` and `/**/*.ts` read as malformed noise and are not. The first
# is a head carrying a closing brace with no opening one, and it is the only
# case that reds if the metacharacter class narrows to `*{*`; the second is a
# head that reduces to empty, and it is the only case that reds if the
# empty-alternative arm is dropped. Pruning either as junk retires a reject
# arm's only cover.
#
# `app/**/routes/**/*.ts` is the opposite kind of case: well-formed, and legible
# enough that the reader would happily cut it to `app/`. It is refused because
# that reduction would be wrong rather than unreadable, and it is the only case
# that reds if the second-recursive-segment arm is dropped.
@test "glob_head_directories yields nothing for a head shape it cannot expand" {
  local glob got
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    got=$(glob_head_directories "$glob")
    if [ -n "$got" ]; then
      printf 'glob_head_directories %s yielded "%s", expected nothing\n' "$glob" "$got" >&2
      return 1
    fi
  done <<'CASES'
app/{routes,components}/**/*.ts
{app,{test,mocks}}/**/*.ts
app}/**/*.ts
/**/*.ts
app/*.{ts,tsx}
**/*.ts
app/**/routes/**/*.ts
CASES
}

@test "arm_names_directory reads the arms as the unanchored substring greps they are" {
  local arms
  arms=$(printf '%s\n' 'app/' 'test/')
  arm_names_directory 'app/' "$arms" || return 1
  arm_names_directory 'app/routes/' "$arms" || return 1
  arm_names_directory 'test/mocks/' "$arms" || return 1
  arm_names_directory '.storybook/' "$arms" && return 1
  true
}

# A descriptor glob the hook never acts on is dead: the directory looks gated in
# the descriptor and decides nothing. For each directory the LIVE descriptor
# gates, the real hook, given a sandbox carrying the live registry and
# descriptor, runs the gate in the package directory for a file staged there.
@test "every live preCommitSource directory runs the gate through the hook" {
  local directories directory package_directory prefix package_path
  directories=$(arm_directories)
  [ -n "$directories" ]
  package_directory=$(live_package_directory)
  mkdir -p "$REPO/.gaia"
  cp "$REPO_ROOT/.gaia/packages.json" "$REPO/.gaia/packages.json"
  mkdir -p "$REPO/$package_directory"
  cp "$(live_descriptor_file)" "$REPO/$package_directory/gaia.package.json"
  if [ "$package_directory" = . ]; then
    prefix=''
    package_path="$REPO"
  else
    prefix="$package_directory/"
    package_path="$REPO/$package_directory"
  fi
  while IFS= read -r directory; do
    : > "$PNPM_LOG"
    git -C "$REPO" reset --quiet
    mkdir -p "$REPO/$prefix$directory"
    echo "// content" > "$REPO/${prefix}${directory}probe.ts"
    git -C "$REPO" add "${prefix}${directory}probe.ts"
    run_hook
    if ! { [ "$status" -eq 0 ] && grep -qxF -- "-C $package_path exec lint-staged" "$PNPM_LOG"; }; then
      printf 'staging %s%sprobe.ts did not run the gate in %s\n' "$prefix" "$directory" "$package_path" >&2
      return 1
    fi
  done <<<"$directories"
}

# --- package-aware behavior (SPEC-092 couplings, C5 and C13) ---

assert_gate_not_invoked() {
  [ "$status" -eq 0 ]
  [ ! -s "$PNPM_LOG" ]
}

@test "frontend/ package: staging frontend/app/x.tsx runs the gate in frontend/" {
  use_frontend_package
  stage_and_run "frontend/app/x.tsx"
  assert_gate_ran "$REPO/frontend"
}

# The guard can fail: with a descriptor that gates nothing the staged file
# matches, a frontend commit skips. Proves the descriptor decides, rather than
# an unanchored substring of the path.
@test "frontend/ package: a descriptor whose preCommitSource names nothing here skips the gate" {
  use_frontend_package
  write_descriptor "$REPO/frontend" '["nomatch/**"]'
  stage_and_run "frontend/app/x.tsx"
  assert_gate_skipped
}

# The RED on today's tree: the unmodified hook text, run against the same
# frontend-layout fixture, never runs the gate in frontend/.
@test "today's hook text does not run the frontend/ gate" {
  use_frontend_package
  # The pre-frontend/ hook shape, inlined: the gate runs at the repo root, never
  # `pnpm -C <repo>/frontend`.
  cat >"$REPO/old-pre-commit" <<'OLD_HOOK'
HAS_APP_CHANGED=$(git diff --cached --name-only -z --diff-filter=ACDM | tr '\0' '\n' | grep 'app/' || true)
HAS_TEST_CHANGED=$(git diff --cached --name-only -z --diff-filter=ACDM | tr '\0' '\n' | grep 'test/' || true)
if [ -n "$HAS_APP_CHANGED" ] || [ -n "$HAS_TEST_CHANGED" ]
then
	pnpm typecheck
	pnpm exec lint-staged
	pnpm test:lint-staged
fi
OLD_HOOK
  mkdir -p "$REPO/frontend/app"
  echo "// content" > "$REPO/frontend/app/x.tsx"
  git -C "$REPO" add frontend/app/x.tsx
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$REPO/old-pre-commit"
  [ "$status" -eq 0 ]
  ! grep -qxF -- "-C $REPO/frontend exec lint-staged" "$PNPM_LOG"
}

@test "frontend/ package: a root app/x.tsx is refused and runs no gate step" {
  use_frontend_package
  stage_and_run "app/x.tsx"
  [ "$status" -ne 0 ]
  grep -qF -- "app/x.tsx -> frontend/app/x.tsx" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

@test "a harness-only staged set skips the gate" {
  use_frontend_package
  mkdir -p "$REPO/wiki" "$REPO/.claude/rules"
  echo a > "$REPO/wiki/a.md"
  echo a > "$REPO/.claude/rules/a.md"
  git -C "$REPO" add wiki/a.md .claude/rules/a.md
  run_hook
  assert_gate_skipped
}

@test "built-in default: with no registry, frontend/app/x.tsx runs the gate in frontend/" {
  rm -f "$REPO/.gaia/packages.json"
  stage_and_run "frontend/app/x.tsx"
  assert_gate_ran "$REPO/frontend"
}

# --- C13: the migration-rename exemption ---

# Commit the retired root paths, then stage their renames the way the Phase 4
# move does, so the staged set carries real R100 entries.
commit_root_frontend_files() {
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    echo "// $path" > "$REPO/$path"
    # Long enough that one appended line stays a rename above git's similarity
    # threshold, so the content-change refusal drives a real Rnn entry.
    seq 1 40 >> "$REPO/$path"
    git -C "$REPO" add "$path"
  done
  git -C "$REPO" commit --quiet -m "seed root frontend files"
}

stage_rename() {
  mkdir -p "$REPO/$(dirname "$2")"
  git -C "$REPO" mv "$1" "$2"
}

@test "C13: a staged set of only C6 renames skips the gate, even with the descriptor missing" {
  commit_root_frontend_files app/x.tsx .dockerignore test/setup.ts public/favicon.ico .storybook/main.ts .playwright/a.spec.ts vite.config.ts .claude/skills/tailwind/SKILL.md .claude/rules/i18n.md .claude/agents/code-audit-frontend/cn.md
  stage_rename app/x.tsx frontend/app/x.tsx
  stage_rename .dockerignore frontend/Dockerfile.dockerignore
  stage_rename test/setup.ts frontend/test/setup.ts
  stage_rename public/favicon.ico frontend/public/favicon.ico
  stage_rename .storybook/main.ts frontend/.storybook/main.ts
  stage_rename .playwright/a.spec.ts frontend/.playwright/a.spec.ts
  stage_rename vite.config.ts frontend/vite.config.ts
  stage_rename .claude/skills/tailwind/SKILL.md frontend/.claude/skills/tailwind/SKILL.md
  stage_rename .claude/rules/i18n.md frontend/.claude/rules/i18n.md
  stage_rename .claude/agents/code-audit-frontend/cn.md frontend/.claude/agents/code-audit-frontend/cn.md
  # No registry and no descriptor anywhere: the exemption runs before the load.
  rm -rf "$REPO/.gaia/packages.json" "$REPO/gaia.package.json" "$REPO/frontend/gaia.package.json"
  git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100' | grep -qx 10
  run_hook
  assert_gate_skipped
}

@test "C13 refusal: an R100 rename inside frontend/ runs the full gate" {
  use_frontend_package
  commit_root_frontend_files frontend/app/utils/a.ts
  stage_rename frontend/app/utils/a.ts frontend/app/utils/b.ts
  git -C "$REPO" diff --cached --name-status -M100% | grep -q '^R100'
  run_hook
  assert_gate_ran "$REPO/frontend"
}

@test "C13 refusal: a rename to a destination that is not the C6 counterpart runs the full gate" {
  use_root_package
  commit_root_frontend_files app/x.tsx
  stage_rename app/x.tsx src/x.tsx
  git -C "$REPO" diff --cached --name-status -M100% | grep -q '^R100'
  run_hook
  assert_gate_ran "$REPO"
}

@test "C13 refusal: a C6 rename with one changed line runs the full gate" {
  use_frontend_package
  commit_root_frontend_files app/x.tsx
  stage_rename app/x.tsx frontend/app/x.tsx
  printf 'a changed line\n' >> "$REPO/frontend/app/x.tsx"
  git -C "$REPO" add frontend/app/x.tsx
  run_hook
  assert_gate_ran "$REPO/frontend"
}

@test "C13 refusal: one non-exempt entry beside C6 renames runs the full gate" {
  use_frontend_package
  commit_root_frontend_files app/x.tsx
  stage_rename app/x.tsx frontend/app/x.tsx
  mkdir -p "$REPO/frontend/app"
  echo "// new" > "$REPO/frontend/app/new.tsx"
  git -C "$REPO" add frontend/app/new.tsx
  run_hook
  assert_gate_ran "$REPO/frontend"
}

# --- doctor guard, one config per package directory ---

@test "doctor guard: two configs under frontend/ fail the commit naming frontend" {
  use_frontend_package
  mkdir -p "$REPO/frontend"
  : > "$REPO/frontend/doctor.config.ts"
  : > "$REPO/frontend/doctor.config.json"
  stage_and_run "docs/notes.md"
  [ "$status" -eq 1 ]
  grep -qF -- "Multiple react-doctor configs found in frontend" <<<"$output"
  grep -qF -- "frontend/doctor.config.json" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

@test "doctor guard: one config under frontend/ passes" {
  use_frontend_package
  : > "$REPO/frontend/doctor.config.ts"
  stage_and_run "docs/notes.md"
  assert_gate_skipped
}

# --- fail closed on a descriptor failure (UAT-018) ---

@test "an unparseable registry fails the commit with the gaia-packages message" {
  use_frontend_package
  printf 'not json {\n' > "$REPO/.gaia/packages.json"
  stage_and_run "frontend/app/x.tsx"
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

@test "a missing descriptor fails the commit with the gaia-packages message" {
  use_frontend_package
  rm "$REPO/frontend/gaia.package.json"
  stage_and_run "frontend/app/x.tsx"
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-packages: " <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}
