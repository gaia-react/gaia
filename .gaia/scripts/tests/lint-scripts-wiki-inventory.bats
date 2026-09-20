#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/lint-scripts-wiki-inventory.sh -- the
# gate that keeps wiki/concepts/GAIA Scripts.md's index from going stale as
# scripts land in .gaia/scripts/ (gaia-react/gaia#2175).
#
# This suite IS the blocking runner. shell-lint.sh invokes the check a second,
# advisory way, but a gate run against a tree whose index is already complete
# reports clean whether its predicate works or not, so a broken predicate is
# indistinguishable from a healthy page there. Every behavioral test therefore
# drives the check through its <repo_root> parameter against a fixture tree
# broken one way at a time, the same reasoning lint-hook-wiki-inventory.bats
# gives for itself. The real-tree test at the end is what fails a build when an
# actual script lands off the page.
#
# The fixtures are real git repositories, because one of the check's two
# subject sources is the git index and the discovery case this suite has to
# exercise hardest -- a script on disk that nothing tracks yet -- is only
# expressible where tracked and untracked are different states.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-scripts-wiki-inventory.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-scripts-wiki-inventory.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  INVENTORY_REL="wiki/concepts/GAIA Scripts.md"
  SCRIPTS_REL=".gaia/scripts"
}

# make_fixture <name>: a fresh git repo under BATS_TEST_TMPDIR carrying an
# empty .gaia/scripts/ and a wiki/concepts/ to write the page into.
#
# There is no teardown, deliberately: every fixture lives under
# BATS_TEST_TMPDIR, which bats removes per test.
make_fixture() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/$SCRIPTS_REL" "$dir/wiki/concepts"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  printf '%s' "$dir"
}

# write_script <dir> <relpath-under-.gaia/scripts> [content]
write_script() {
  local dir="$1" rel="$2"
  mkdir -p "$dir/$SCRIPTS_REL/$(dirname "$rel")"
  printf '#!/usr/bin/env bash\n' >"$dir/$SCRIPTS_REL/$rel"
}

# stage <dir>: put the working tree into the index.
#
# A stage rather than a commit: the check reads `git ls-files`, which is the
# index, so a commit would add a step this suite never observes the effect of.
stage() {
  git -C "$1" add -A
}

# write_inventory <dir> <mention>...
#
# A minimal page carrying one row per mention, in the shape the real rows use.
write_inventory() {
  local dir="$1"
  shift
  local mention
  {
    printf '# GAIA Scripts\n\n## The index\n\n'
    printf '| Script | Ships | Invoker | What it is |\n|---|---|---|---|\n'
    for mention in "$@"; do
      printf -- '| `%s` | yes | by hand | a fixture row. |\n' "$mention"
    done
  } >"$dir/$INVENTORY_REL"
}

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "a fixture whose page mentions every tracked root file passes" {
  local dir
  dir="$(make_fixture healthy)"
  write_script "$dir" alpha.sh
  write_script "$dir" beta.sh
  stage "$dir"
  write_inventory "$dir" alpha.sh beta.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "a tracked root file the page never mentions fails, naming it and not its inventoried sibling" {
  local dir
  dir="$(make_fixture omitted)"
  write_script "$dir" alpha.sh
  write_script "$dir" beta.sh
  stage "$dir"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'beta.sh' <<<"$output"
  # alpha.sh is inventoried, so it must not be blamed. The findings block is
  # the only place a basename is printed, so alpha.sh appearing at all is the
  # bad case.
  grep -qF -- 'alpha.sh' <<<"$output" && return 1
  grep -qF -- "$INVENTORY_REL" <<<"$output"
}

@test "every omitted root file is reported, not just the first" {
  local dir
  dir="$(make_fixture omitted_many)"
  write_script "$dir" alpha.sh
  write_script "$dir" beta.sh
  write_script "$dir" gamma.sh
  stage "$dir"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'beta.sh' <<<"$output"
  grep -qF -- 'gamma.sh' <<<"$output"
}

@test "a root file mentioned under a path prefix counts as inventoried" {
  local dir
  dir="$(make_fixture prefixed_mention)"
  write_script "$dir" alpha.sh
  stage "$dir"
  {
    printf '# GAIA Scripts\n\n## The index\n\n'
    printf -- '- `.gaia/scripts/alpha.sh`: named with its directory.\n'
  } >"$dir/$INVENTORY_REL"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# The tracked half of the subject set, on its own.
#
# The on-disk source is scoped to `.sh`, so a tracked root file that is not
# shell reaches the subject set through the index read alone. The rate card the
# cost ledger prices against is exactly that shape in the real tree, which is
# why the union carries a source the `*.sh` glob duplicates for every other
# file.

@test "a tracked root file that is not shell is a subject, and reds when the page omits it" {
  local dir
  dir="$(make_fixture tracked_non_shell)"
  write_script "$dir" alpha.sh
  printf '{}\n' >"$dir/$SCRIPTS_REL/rates.json"
  stage "$dir"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'rates.json' <<<"$output"
}

@test "a tracked root file that is not shell counts as inventoried when the page names it" {
  local dir
  dir="$(make_fixture tracked_non_shell_ok)"
  write_script "$dir" alpha.sh
  printf '{}\n' >"$dir/$SCRIPTS_REL/rates.json"
  stage "$dir"
  write_inventory "$dir" alpha.sh rates.json

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# The on-disk half of the subject set, on its own.
#
# This is the discovery-stage case `.claude/rules/guards-must-fail.md` names
# first, and the reason the subject set is not the git index alone: a new
# script and its sibling suite are both untracked at the moment their author
# runs the check to see whether the tree is clean, so a tracked-only subject
# set reports clean over precisely the files most likely to red.

@test "an untracked .sh at the root that the page never mentions fails, naming it" {
  local dir
  dir="$(make_fixture untracked_omitted)"
  write_script "$dir" alpha.sh
  stage "$dir"
  write_script "$dir" brand-new.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'brand-new.sh' <<<"$output"
}

@test "an untracked .sh at the root counts as inventoried when the page names it" {
  local dir
  dir="$(make_fixture untracked_ok)"
  write_script "$dir" alpha.sh
  stage "$dir"
  write_script "$dir" brand-new.sh
  write_inventory "$dir" alpha.sh brand-new.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an untracked root file that is not shell is not a subject, so the page need not mention it" {
  local dir
  dir="$(make_fixture untracked_non_shell)"
  write_script "$dir" alpha.sh
  stage "$dir"
  printf 'noise\n' >"$dir/$SCRIPTS_REL/.DS_Store"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# The root, and only the root. Both sources stop at one level, and each is
# driven on its own below: a subdirectory file that is tracked, and one that is
# only on disk. The page describes the subdirectories as directories and does
# not index their contents, so either becoming a subject would red on a tree
# that is correct.

@test "a tracked file in a subdirectory is not a subject" {
  local dir
  dir="$(make_fixture nested_tracked)"
  write_script "$dir" alpha.sh
  write_script "$dir" lib/shared.sh
  stage "$dir"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an untracked .sh in a subdirectory is not a subject" {
  local dir
  dir="$(make_fixture nested_untracked)"
  write_script "$dir" alpha.sh
  stage "$dir"
  write_script "$dir" lib/shared.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "neither source yielding a root file exits 2 rather than reporting the page complete" {
  local dir
  dir="$(make_fixture no_scripts)"
  stage "$dir"
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'discovery found no root file' <<<"$output"
  # The set is a union, so reaching this branch means BOTH sources came back
  # empty, and the message says both rather than naming whichever one the
  # reader happened to break, per .claude/rules/partial-cause-reporting.md.
  grep -qF -- 'git tracks nothing at the root of' <<<"$output"
  grep -qF -- 'holds no .sh' <<<"$output"
}

@test "an index that cannot be read exits 2 rather than comparing the on-disk half alone" {
  local dir="$BATS_TEST_TMPDIR/bad_index"
  # An empty .git directory: git refuses at this path and stops the upward
  # walk, so the failure is the fixture's own rather than the ambient tree's.
  mkdir -p "$dir/$SCRIPTS_REL" "$dir/wiki/concepts" "$dir/.git"
  write_script "$dir" alpha.sh
  write_inventory "$dir" alpha.sh

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'could not read the git index' <<<"$output"
  # The empty-set arm's message would be false here -- the directory holds a
  # script -- so it must not be the one that fired. The needle is that arm's
  # own opening line, the part of its message no other arm prints.
  grep -qF -- 'discovery found no root file' <<<"$output" && return 1
  true
}

@test "a missing inventory page exits 2 rather than blaming every root file" {
  local dir
  dir="$(make_fixture no_page)"
  write_script "$dir" alpha.sh
  write_script "$dir" beta.sh
  stage "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'inventory page not found' <<<"$output"
}

@test "an empty inventory page exits 2, distinguishably from a missing one" {
  local dir
  dir="$(make_fixture empty_page)"
  write_script "$dir" alpha.sh
  stage "$dir"
  : >"$dir/$INVENTORY_REL"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'inventory page is empty' <<<"$output"
  grep -qF -- 'inventory page not found' <<<"$output" && return 1
  true
}

@test "a missing scripts directory exits 2 rather than reporting the page complete" {
  local dir
  dir="$(make_fixture no_scripts_dir)"
  write_inventory "$dir" alpha.sh
  # Both halves carry `:?` so an empty expansion aborts rather than handing
  # `rm -rf` a path that walks up toward the filesystem root (SC2115).
  rm -rf "${dir:?}/${SCRIPTS_REL:?}"
  stage "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'scripts directory not found' <<<"$output"
}

@test "a <repo_root> that is not a directory exits 2" {
  run bash "$CHECK" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  grep -qF -- 'not a directory' <<<"$output"
}

@test "more than one argument is a usage error" {
  run bash "$CHECK" "$REPO_ROOT" extra
  [ "$status" -eq 2 ]
  grep -qF -- 'too many arguments' <<<"$output"
}

@test "the real tree passes: every root file of .gaia/scripts/ is on the page" {
  run bash "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
