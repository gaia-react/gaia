#!/usr/bin/env bats

# Tests for .husky/pre-commit.
#
# The hook decides whether a staged change is lint-worthy and runs the Quality
# Gate floor (pnpm typecheck / lint-staged / test:lint-staged) only when it is.
# That decision is a set of `git diff --cached` greps, one arm per lintable
# directory, OR-ed into a single guard. A directory that .lintstagedrc.json
# covers but no arm names is the live failure mode: a commit scoped to that
# directory alone matches nothing, the else branch fires, and the change lands
# unlinted and untypechecked.
#
# Husky runs the hook as `sh -e <hook>` (.husky/_/h), so these tests do too.
# The `|| true` tail on each grep is load-bearing under -e, and running the
# hook any other way would not exercise it.
#
# `pnpm` is stubbed onto PATH as a recorder, so the tests assert on which gate
# steps the hook invoked rather than on their real output. The suite needs no
# node_modules and stays fast.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABS="$REPO_ROOT/.husky/pre-commit"

  REPO=$(mktemp -d -t husky-pre-commit-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

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

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Stage one file at a repo-relative path, then run the hook from the repo root
# the way husky does.
stage_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABS"
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
    sh -c 'cd "$1" && sh -e "$2"' _ "$REPO" "$HOOK_ABS"
}

# Assertion style: .claude/rules/bats-assertions.md.
assert_gate_ran() {
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"
  grep -qx 'typecheck' "$PNPM_LOG"
  grep -qx 'exec lint-staged' "$PNPM_LOG"
  grep -qx 'test:lint-staged' "$PNPM_LOG"
}

assert_gate_skipped() {
  [ "$status" -eq 0 ]
  grep -qF -- "skipping lint-staged" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

# --- a change in a lintable directory runs the gate ---

@test "app/ change runs the gate" {
  stage_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ change runs the gate" {
  stage_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ change runs the gate" {
  stage_and_run ".storybook/preview.ts"
  assert_gate_ran
}

# .lintstagedrc.json lints {.storybook,.playwright}/**/*.{ts,tsx}, so the
# .playwright half needs an arm of its own; without one that entry is
# unreachable for an e2e-spec-only commit, the most common .playwright shape.
@test ".playwright/ change runs the gate" {
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
  stage_deletion_and_run "app/routes/home.tsx"
  assert_gate_ran
}

@test "test/ deletion runs the gate" {
  stage_deletion_and_run "test/setup.ts"
  assert_gate_ran
}

@test ".storybook/ deletion runs the gate" {
  stage_deletion_and_run ".storybook/preview.ts"
  assert_gate_ran
}

@test ".playwright/ deletion runs the gate" {
  stage_deletion_and_run ".playwright/e2e/home.spec.ts"
  assert_gate_ran
}


@test "a change matching no lintable directory skips the gate" {
  stage_and_run "docs/notes.md"
  assert_gate_skipped
}

# --- every hook arm's directory is reachable by lint-staged ---
#
# The arms above and .lintstagedrc.json's globs are the two halves of one
# contract: an arm decides the gate runs, a glob decides lint-staged has
# anything to hand ESLint. An arm no glob covers is the silent half of the
# failure mode the header describes: the hook prints "running lint-staged",
# lint-staged matches zero files and exits 0, and the commit lands with ESLint
# skipped for that whole directory while typecheck and Vitest still report.
#
# The arm set is derived from the hook rather than restated here, and the count
# of directories the derivation yields is checked against the number of arm
# assignments, so an arm whose spelling drifts stops the guard rather than
# quietly shrinking it.
#
# Both directions of the contract are derived, one guard each: this one asks
# whether every arm reaches a glob, the one below it whether every glob reaches
# an arm. The per-directory @tests above still pin each of those directories by
# name, which is a different claim, that the hook really runs end to end for
# each of them, not that the two files agree.

# Every directory the hook's change-detection arms grep for, one per line.
arm_dirs() {
  sed -n "s/^HAS_[A-Z0-9_]*_CHANGED=.*| grep '\\([^']*\\)'.*/\\1/p" "$HOOK_ABS"
}

# Every arm assignment, counted by a pattern deliberately wider than the two
# derivations read. A count taken with the same pattern as the extraction agrees
# with it on every name the pattern cannot spell, so the two readings would
# confirm each other's blind spot instead of exposing it; this one over-counts
# rather than under-counts, so an arm neither derivation can read reds the guard.
arm_assignment_count() {
  grep -c '^HAS_[A-Za-z0-9_]*=' "$HOOK_ABS"
}

# The lint-staged glob keys whose task chain actually invokes ESLint. Reading
# the keys alone would accept a chain that runs only prettier or stylelint,
# which is the very outcome the arm is supposed to prevent, and chains of that
# shape already live in this config.
eslint_globs() {
  jq -r 'to_entries[]
         | select(any(.value[]?; type == "string" and startswith("eslint")))
         | .key' "$REPO_ROOT/.lintstagedrc.json"
}

# The glob keys whose chain mentions ESLint anywhere, counted by a pattern
# deliberately wider than the derivation above reads, for the same reason
# arm_assignment_count is wider than arm_dirs. A count taken with the same
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
         | length' "$REPO_ROOT/.lintstagedrc.json"
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
glob_head_dirs() {
  local glob="$1" head alt
  case "$glob" in
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
# Exact, where arm_names_dir below is a substring relation, and the asymmetry is
# the contract rather than an oversight. This direction asks whether an arm's
# whole directory reaches ESLint, and a nested head covers only part of it:
# `app/routes/**/*.ts` leaves app/other.ts unlinted while the `app/` arm still
# fires, which is the miss this direction exists to catch. Loosening it to a
# substring would green exactly that case.
glob_covers_dir() {
  local dir="$1" glob="$2"
  glob_head_dirs "$glob" | grep -qxF -- "$dir"
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
arm_names_dir() {
  local dir="$1" arm
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    case "$dir" in
      *"$arm"*) return 0 ;;
    esac
  done <<<"$2"
  return 1
}

@test "every pre-commit arm directory is covered by an ESLint lint-staged glob" {
  local dirs globs derived assignments dir glob covered
  dirs=$(arm_dirs)
  derived=$(printf '%s\n' "$dirs" | grep -c . || true)
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

  while IFS= read -r dir; do
    covered=0
    while IFS= read -r glob; do
      if glob_covers_dir "$dir" "$glob"; then covered=1; fi
    done <<<"$globs"
    if [ "$covered" -ne 1 ]; then
      printf 'hook arm %s has no ESLint .lintstagedrc.json glob\n' "$dir" >&2
      return 1
    fi
  done <<<"$dirs"
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
  local dirs globs derived mentions glob glob_dirs dir
  dirs=$(arm_dirs)
  [ -n "$dirs" ]

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
    glob_dirs=$(glob_head_dirs "$glob")
    [ -n "$glob_dirs" ] || {
      printf 'eslint glob %s does not reduce to a plain recursive <dir>/**/ head, so no directory can be checked against the arms\n' "$glob" >&2
      return 1
    }
    while IFS= read -r dir; do
      if ! arm_names_dir "$dir" "$dirs"; then
        printf 'ESLint .lintstagedrc.json glob %s covers %s, which no pre-commit arm reaches\n' "$glob" "$dir" >&2
        return 1
      fi
    done <<<"$glob_dirs"
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

@test "glob_head_dirs reduces each head shape it can expand to that head's directories" {
  local glob expect got
  while IFS='|' read -r glob expect; do
    [ -n "$glob" ] || continue
    got=$(glob_head_dirs "$glob" | tr '\n' ' ')
    if [ "${got% }" != "$expect" ]; then
      printf 'glob_head_dirs %s yielded "%s", expected "%s"\n' "$glob" "${got% }" "$expect" >&2
      return 1
    fi
  done <<'CASES'
app/**/*.{ts,tsx}|app/
app/routes/**/*.ts|app/routes/
{.storybook,.playwright,test}/**/*.{ts,tsx}|.storybook/ .playwright/ test/
{app/routes,test}/**/*.ts|app/routes/ test/
CASES
}

@test "glob_head_dirs yields nothing for a head shape it cannot expand" {
  local glob got
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    got=$(glob_head_dirs "$glob")
    if [ -n "$got" ]; then
      printf 'glob_head_dirs %s yielded "%s", expected nothing\n' "$glob" "$got" >&2
      return 1
    fi
  done <<'CASES'
app/{routes,components}/**/*.ts
{app,{test,mocks}}/**/*.ts
app/*.{ts,tsx}
**/*.ts
CASES
}

@test "arm_names_dir reads the arms as the unanchored substring greps they are" {
  local arms
  arms=$(printf '%s\n' 'app/' 'test/')
  arm_names_dir 'app/' "$arms" || return 1
  arm_names_dir 'app/routes/' "$arms" || return 1
  arm_names_dir 'test/mocks/' "$arms" || return 1
  arm_names_dir '.storybook/' "$arms" && return 1
  true
}

# An arm assignment that never reaches the OR guard is dead: the directory looks
# armed at the top of the hook and decides nothing. The assignment names are
# derived from the same lines the guard above reads, so an arm added without a
# term reds here instead of passing both checks.
@test "every pre-commit arm assignment is read by the change-detection guard" {
  local names name guard
  names=$(sed -n 's/^\(HAS_[A-Z0-9_]*_CHANGED\)=.*/\1/p' "$HOOK_ABS")
  [ -n "$names" ]
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq "$(arm_assignment_count)" ]
  # shellcheck disable=SC2016 # $ is literal in the BRE, not an expansion.
  guard=$(grep -n '^if \[ -n "\$HAS_' "$HOOK_ABS")
  [ -n "$guard" ]
  while IFS= read -r name; do
    # The closing quote terminates the match. Grepping the bare name would let
    # a longer arm whose name merely starts with this one supply the matching
    # substring, greening the check for an arm that is assigned and never read.
    if ! grep -qF -- "\"\$$name\"" <<<"$guard"; then
      printf 'arm %s is assigned but never read by the guard\n' "$name" >&2
      return 1
    fi
  done <<<"$names"
}
