#!/usr/bin/env bats
# SC2016 is intentional file-wide: the fixture writers below are single-quoted
# precisely so that the backticks and dollar signs in the fixture markdown reach
# the file as literal text, which is what makes them fixtures of the real
# spellings rather than of what this shell would expand them to.
# shellcheck disable=SC2016
#
# Conformance suite for .gaia/scripts/lint-wiki-cached-version.sh -- the gate
# that keeps a hand-kept `version:` out of wiki frontmatter.
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second,
# advisory way, but a gate run against a tree that already carries no such field
# reports clean whether its predicate works or not, so a broken predicate is
# indistinguishable from a clean surface there. Every test therefore drives the
# check through its <repo_root> parameter against a fixture tree shaped one way
# at a time.
#
# NO REAL-TREE TEST, deliberately, and the reason is worth stating because the
# sibling lint-hook-wiki-inventory.bats carries one. That suite's real-tree test
# earns its place by being the only CI runner that reds when a live entry is
# dropped. Here the live surface is already covered: shell-lint.sh's `**/*.md`
# paths filter arms this check on every pull request that touches a wiki page,
# which is precisely the change that could reintroduce the field. A real-tree
# assertion here would add a second copy of that coverage and nothing else.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-wiki-cached-version.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-wiki-cached-version.sh"
}

# make_fixture <name>: a fresh fixture root under BATS_TEST_TMPDIR.
#
# A real git repository, because the check discovers over `git ls-files` so an
# untracked draft under wiki/ is not graded. `track_fixture` below is what puts
# a written page into that set.
#
# There is no teardown, deliberately: every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test.
make_fixture() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/wiki/dependencies"
  git -C "$dir" init -q
  git -C "$dir" config user.email fixture@example.invalid
  git -C "$dir" config user.name fixture
  printf '%s' "$dir"
}

track_fixture() {
  git -C "$1" add -A
}

# write_page <dir> <relative-path> <frontmatter-line>...
#
# A page with a leading `---` fence carrying the given lines, then a body.
write_page() {
  local dir="$1" rel="$2"
  shift 2
  local line
  {
    printf -- '---\n'
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '---\n\n# A fixture page\n\nBody prose.\n'
  } >"$dir/$rel"
}

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "a tree whose wiki pages carry no version field passes" {
  local dir
  dir="$(make_fixture healthy)"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'status: active' 'package: alpha'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "a version field in frontmatter fails, naming the page and the line" {
  local dir
  dir="$(make_fixture cached)"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'status: active' 'version: 1.2.3'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'wiki/dependencies/Alpha.md:4' <<<"$output"
  grep -qF -- 'version: 1.2.3' <<<"$output"
}

@test "every offending page is reported, not just the first" {
  local dir
  dir="$(make_fixture cached_many)"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'version: 1.0.0'
  write_page "$dir" wiki/dependencies/Beta.md 'type: dependency' 'version: 2.0.0'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'Alpha.md' <<<"$output"
  grep -qF -- 'Beta.md' <<<"$output"
}

@test "the word in body prose is not a hit, only the frontmatter field is" {
  local dir
  dir="$(make_fixture body_prose)"
  {
    printf -- '---\ntype: dependency\nstatus: active\n---\n\n'
    printf '# Alpha\n\nversion: whatever a reader writes in prose stays prose.\n\n'
    printf '```yaml\nversion: 9.9.9\n```\n'
  } >"$dir/wiki/dependencies/Alpha.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a page with no frontmatter fence at all is not a hit" {
  local dir
  dir="$(make_fixture no_frontmatter)"
  printf '# Alpha\n\nversion: 1.0.0\n' >"$dir/wiki/dependencies/Alpha.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a space before the colon does not evade the check" {
  local dir
  dir="$(make_fixture spaced_colon)"
  # YAML accepts `version : 1.2.3`, so a fixed-string test for `version:` reads
  # this page as clean while the forbidden cache is standing on it. The evasion
  # needs no intent to reach the tree: it is a legal spelling an editor or a
  # formatter can produce.
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'version : 1.2.3'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'Alpha.md' <<<"$output"
}

@test "a field whose name merely ends in version is not a hit" {
  local dir
  dir="$(make_fixture suffix_field)"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'node_version: 24'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an untracked page is not graded" {
  local dir
  dir="$(make_fixture untracked)"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency' 'status: active'
  track_fixture "$dir"
  write_page "$dir" wiki/dependencies/Draft.md 'type: dependency' 'version: 0.0.1'

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a tree with no wiki directory exits 2 rather than reporting clean" {
  local dir="$BATS_TEST_TMPDIR/no_wiki"
  mkdir -p "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'wiki directory not found' <<<"$output"
}

# Three conditions reach the empty-discovery arm and the repair differs for each,
# so each gets its own test rather than one standing for the set.

@test "empty discovery, cause 1: a wiki directory holding no tracked markdown" {
  local dir
  dir="$(make_fixture empty_wiki)"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'discovery listed no tracked markdown' <<<"$output"
  grep -qF -- 'holds no tracked page' <<<"$output"
}

@test "empty discovery, cause 2: a root that is not a git repository" {
  local dir="$BATS_TEST_TMPDIR/not_a_repo"
  mkdir -p "$dir/wiki/dependencies"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a usable git repository' <<<"$output"
  # The listing command states which, which is why its stderr is not suppressed.
  grep -qE -- 'not a git repository|fatal' <<<"$output"
}

@test "empty discovery, cause 3: a root below its repository toplevel" {
  local dir
  dir="$(make_fixture below_toplevel)"
  mkdir -p "$dir/sub/wiki"
  write_page "$dir" wiki/dependencies/Alpha.md 'type: dependency'
  track_fixture "$dir"
  # The silent one, and the reason the git-diagnostic heuristic alone is not
  # enough: the listing is scoped to the directory it is given, so it exits 0
  # and prints nothing at all. Without its own arm the operator is sent to
  # inspect a wiki tree that is fine.
  run bash "$CHECK" "$dir/sub"
  [ "$status" -eq 2 ]
  grep -qF -- 'sits below its repository toplevel' <<<"$output"
  grep -qF -- 'holds no tracked page' <<<"$output" && return 1
  true
}

@test "a root argument that is not a directory exits 2" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a directory' <<<"$output"
}

@test "more than one argument exits 2 with usage" {
  run bash "$CHECK" a b
  [ "$status" -eq 2 ]
  grep -qF -- 'usage:' <<<"$output"
}
