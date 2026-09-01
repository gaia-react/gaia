#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/lint-guard-rule-shell-coverage.sh -- the
# gate that keeps the guard and diagnostic rules' `paths:` lists from going
# stale as new shell directories appear (issue #1701).
#
# This suite IS the blocking runner: shell-lint.sh invokes the check a second,
# advisory way, and a gate that scans a shell family nobody added yet reports
# clean either way, so a broken predicate is indistinguishable from a healthy
# tree there. Every behavioral test therefore drives the check through its
# <repo_root> parameter against a fixture tree that has been deliberately
# broken one way at a time, the same reasoning check-main-root-derivation.bats
# gives for itself. The real-tree test at the end is what fails a build when an
# actual shell family lands outside both rules.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-guard-rule-shell-coverage.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-guard-rule-shell-coverage.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
}

# make_fixture_repo <name>: a fresh, empty git repo under BATS_TEST_TMPDIR.
# Returns the repo path on stdout.
#
# There is no teardown, deliberately. Every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test, so a cleanup loop here would
# have nothing left to do. The shape worth naming rather than writing: this
# helper is called as `dir="$(make_fixture_repo name)"`, and command
# substitution is a subshell, so a `FIXTURE_REPOS+=("$dir")` inside it could
# never reach a parent-shell array. Such a teardown iterates zero times on every
# test while reading as cleanup that is doing work.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf '%s' "$dir"
}

commit_fixture() {
  local dir="$1"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m fixture
}

# write_rule <dir> <rule-relative-path> <glob>...
write_rule() {
  local dir="$1" rule="$2"
  shift 2
  local glob
  mkdir -p "$dir/$(dirname "$rule")"
  {
    printf -- '---\npaths:\n'
    for glob in "$@"; do
      printf "  - '%s'\n" "$glob"
    done
    printf -- '---\n\n# fixture rule\n'
  } >"$dir/$rule"
}

# write_baseline <dir>: a healthy fixture -- both shipped rules naming the two
# shipped shell roots, the pointer rule naming the maintainer-only one, and one
# tracked script in each of the three. Every "must fail" fixture starts here and
# mutates exactly one thing.
write_baseline() {
  local dir="$1"
  write_rule "$dir" '.claude/rules/guards-must-fail.md' \
    '.gaia/scripts/**/*.sh' '.gaia/statusline/**/*.sh'
  write_rule "$dir" '.claude/rules/partial-cause-reporting.md' \
    '.gaia/scripts/**/*.sh' '.gaia/statusline/**/*.sh'
  write_rule "$dir" '.claude/rules/maintainers/guard-and-diagnostic-surfaces.md' \
    '.gaia/tests/**/*.sh'
  mkdir -p "$dir/.gaia/scripts/nested" "$dir/.gaia/statusline" "$dir/.gaia/tests"
  printf '#!/usr/bin/env bash\n' >"$dir/.gaia/scripts/top.sh"
  printf '#!/usr/bin/env bash\n' >"$dir/.gaia/scripts/nested/deep.sh"
  printf '#!/usr/bin/env bash\n' >"$dir/.gaia/statusline/line.sh"
  printf '#!/usr/bin/env bash\n' >"$dir/.gaia/tests/harness.sh"
}

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "a healthy fixture passes, and '**/' matches both zero and more path segments" {
  local dir
  dir="$(make_fixture_repo healthy)"
  write_baseline "$dir"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a tracked .sh no rule reaches fails, naming the file and both shipped rules" {
  local dir
  dir="$(make_fixture_repo uncovered)"
  write_baseline "$dir"
  mkdir -p "$dir/.specify/extensions/gaia/lib"
  printf '#!/usr/bin/env bash\n' >"$dir/.specify/extensions/gaia/lib/lint.sh"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  case "$output" in
    *".specify/extensions/gaia/lib/lint.sh"*) ;;
    *) return 1 ;;
  esac
  case "$output" in
    *"guards-must-fail.md"*) ;;
    *) return 1 ;;
  esac
  case "$output" in
    *"partial-cause-reporting.md"*) ;;
    *) return 1 ;;
  esac
}

@test "a file reached by only one of the two shipped rules fails, naming just that rule" {
  local dir
  dir="$(make_fixture_repo one_sided)"
  write_baseline "$dir"
  # Drop the statusline glob from the diagnostic rule alone.
  write_rule "$dir" '.claude/rules/partial-cause-reporting.md' '.gaia/scripts/**/*.sh'
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  case "$output" in
    *".gaia/statusline/line.sh"*) ;;
    *) return 1 ;;
  esac
  case "$output" in
    *"partial-cause-reporting.md"*) ;;
    *) return 1 ;;
  esac
  # The guard rule still reaches it, so it must not be blamed.
  case "$output" in
    *"guards-must-fail.md"*) return 1 ;;
    *) ;;
  esac
}

@test "the pointer rule counts as coverage for both shipped rules" {
  local dir
  dir="$(make_fixture_repo pointer_extends_both)"
  write_baseline "$dir"
  commit_fixture "$dir"

  # .gaia/tests/harness.sh is named by the pointer rule alone; the baseline
  # passing is that claim. Removing the pointer's glob must red it under both.
  write_rule "$dir" '.claude/rules/maintainers/guard-and-diagnostic-surfaces.md' \
    '.gaia/cli/src/**/*.ts'
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  case "$output" in
    *".gaia/tests/harness.sh"*) ;;
    *) return 1 ;;
  esac
  case "$output" in
    *"guards-must-fail.md, .claude/rules/partial-cause-reporting.md"*) ;;
    *) return 1 ;;
  esac
}

@test "arming: a rule file whose frontmatter yields no globs exits 2, not 0 or 1" {
  local dir
  dir="$(make_fixture_repo unarmed_rule)"
  write_baseline "$dir"
  printf -- '---\npaths:\n---\n\n# fixture rule\n' \
    >"$dir/.claude/rules/guards-must-fail.md"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  case "$output" in
    *"no paths globs parsed"*) ;;
    *) return 1 ;;
  esac
}

@test "arming: a missing rule file exits 2, naming the file" {
  local dir
  dir="$(make_fixture_repo missing_rule)"
  write_baseline "$dir"
  rm "$dir/.claude/rules/maintainers/guard-and-diagnostic-surfaces.md"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  case "$output" in
    *"rule file not found"*"guard-and-diagnostic-surfaces.md"*) ;;
    *) return 1 ;;
  esac
}

@test "discovery: a tree with no tracked .sh exits 2 rather than reporting clean" {
  local dir
  dir="$(make_fixture_repo no_shell)"
  write_baseline "$dir"
  rm "$dir/.gaia/scripts/top.sh" "$dir/.gaia/scripts/nested/deep.sh" \
    "$dir/.gaia/statusline/line.sh" "$dir/.gaia/tests/harness.sh"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  case "$output" in
    *"discovery found no tracked"*) ;;
    *) return 1 ;;
  esac
}

@test "match region: a glob using unmodeled syntax exits 2, naming the construct" {
  local dir
  dir="$(make_fixture_repo unmodeled_glob)"
  write_baseline "$dir"
  write_rule "$dir" '.claude/rules/guards-must-fail.md' \
    '.gaia/scripts/**/*.sh' '.gaia/statusline/**/*.{sh,bash}'
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  case "$output" in
    *"unmodeled glob syntax"*) ;;
    *) return 1 ;;
  esac
}

@test "match region: '*' does not cross a directory separator" {
  local dir
  dir="$(make_fixture_repo star_is_segment_local)"
  write_baseline "$dir"
  # `.gaia/scripts/*.sh` reaches top.sh but not nested/deep.sh.
  write_rule "$dir" '.claude/rules/guards-must-fail.md' \
    '.gaia/scripts/*.sh' '.gaia/statusline/**/*.sh'
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  case "$output" in
    *".gaia/scripts/nested/deep.sh"*) ;;
    *) return 1 ;;
  esac
  case "$output" in
    *".gaia/scripts/top.sh"*) return 1 ;;
    *) ;;
  esac
}

@test "match region: a bare '**' not followed by '/' exits 2, naming that arm" {
  local dir
  dir="$(make_fixture_repo bare_globstar)"
  write_baseline "$dir"
  write_rule "$dir" '.claude/rules/guards-must-fail.md' \
    '.gaia/**scripts/*.sh' '.gaia/statusline/**/*.sh'
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  # This arm has its own message, distinct from the metacharacter arm above.
  # Asserting the wording is what keeps the two apart: matching only
  # "unmodeled glob syntax" would pass with this branch deleted.
  case "$output" in
    *'"**" not followed by "/"'*) ;;
    *) return 1 ;;
  esac
}

@test "discovery: an extensionless tracked .husky hook is enumerated, not skipped" {
  local dir
  dir="$(make_fixture_repo husky_seen)"
  write_baseline "$dir"
  mkdir -p "$dir/.husky"
  # Hand-written shell with no extension and no shebang, the exact shape
  # .husky/pre-commit takes in the real tree.
  printf 'pnpm lint-staged\n' >"$dir/.husky/pre-commit"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  case "$output" in
    *".husky/pre-commit"*) ;;
    *) return 1 ;;
  esac
}

@test "discovery: a .husky glob in both rules covers the hook" {
  local dir
  dir="$(make_fixture_repo husky_covered)"
  write_baseline "$dir"
  write_rule "$dir" '.claude/rules/guards-must-fail.md' \
    '.gaia/scripts/**/*.sh' '.gaia/statusline/**/*.sh' '.husky/*'
  write_rule "$dir" '.claude/rules/partial-cause-reporting.md' \
    '.gaia/scripts/**/*.sh' '.gaia/statusline/**/*.sh' '.husky/*'
  mkdir -p "$dir/.husky"
  printf 'pnpm lint-staged\n' >"$dir/.husky/pre-commit"
  commit_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "usage: more than one argument exits 2" {
  run bash "$CHECK" "$REPO_ROOT" extra
  [ "$status" -eq 2 ]
  case "$output" in
    *"too many arguments"*) ;;
    *) return 1 ;;
  esac
}

@test "usage: a repo_root that is not a directory exits 2" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  case "$output" in
    *"not a directory"*) ;;
    *) return 1 ;;
  esac
}

@test "real repo: every tracked shell file is reached by both guard and diagnostic rules" {
  run bash "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
