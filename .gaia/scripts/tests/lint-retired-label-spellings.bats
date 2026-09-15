#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/lint-retired-label-spellings.sh -- the
# gate that keeps a label spelling the registry has retired out of tracked
# source.
#
# This suite IS the blocking runner for the predicate. The check is also a
# member of .gaia/tests/whole-tree-invariants.sh, but it runs there against a
# tree that carries no retired spelling and so reports clean whether its
# predicate works or not: a broken predicate is indistinguishable from a clean
# surface. Every test below therefore drives the check through its <repo_root>
# parameter against a fixture tree shaped one way at a time.
#
# One real-tree test is kept, and it asserts the thing a fixture cannot: that
# the live registry actually records a retired spelling, so the gate is armed
# rather than scanning an empty term set.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/lint-retired-label-spellings.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  CHECK="$SCRIPT_DIR/lint-retired-label-spellings.sh"
}

# make_fixture <name>: a fresh fixture repository under BATS_TEST_TMPDIR.
#
# A real git repository, because the check discovers over `git grep`, so an
# untracked file is not graded. `track_fixture` is what puts a written file
# into that set. No teardown: bats removes BATS_TEST_TMPDIR per test.
make_fixture() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/.gaia/scripts" "$dir/wiki"
  git -C "$dir" init -q
  git -C "$dir" config user.email fixture@example.invalid
  git -C "$dir" config user.name fixture
  printf '%s' "$dir"
}

track_fixture() {
  git -C "$1" add -A
}

# write_registry <dir> <json>: the fixture's .gaia/labels.json.
write_registry() {
  printf '%s\n' "$2" >"$1/.gaia/labels.json"
}

# A registry with one rename recorded: `old-claim` became `new-claim`.
RENAMED_ONE='{
  "labels": [
    {"name": "new-claim", "renamedFrom": ["old-claim"]},
    {"name": "keeper", "renamedFrom": []}
  ]
}'

@test "structural: the check is executable" {
  [ -x "$CHECK" ]
}

@test "a tree carrying no retired spelling passes" {
  local dir
  dir="$(make_fixture healthy)"
  write_registry "$dir" "$RENAMED_ONE"
  printf 'gh issue list --label new-claim\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}

@test "a retired spelling in tracked source fails, naming the file, the line, and the new name" {
  local dir
  dir="$(make_fixture carrier)"
  write_registry "$dir" "$RENAMED_ONE"
  printf '# header\ngh issue list --label old-claim\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- '.gaia/scripts/reader.sh:2' <<<"$output"
  grep -qF -- 'old-claim' <<<"$output"
  grep -qF -- 'new-claim' <<<"$output"
}

@test "a retired spelling in prose is a hit too, not only one in a gh invocation" {
  local dir
  dir="$(make_fixture prose)"
  write_registry "$dir" "$RENAMED_ONE"
  printf 'The drain strips the old-claim label when the run stops.\n' >"$dir/wiki/Notes.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'wiki/Notes.md:1' <<<"$output"
}

@test "every carrier is reported, not just the first" {
  local dir
  dir="$(make_fixture many)"
  write_registry "$dir" "$RENAMED_ONE"
  printf 'gh issue edit 1 --add-label old-claim\n' >"$dir/.gaia/scripts/alpha.sh"
  printf 'gh issue edit 2 --add-label old-claim\n' >"$dir/.gaia/scripts/beta.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'alpha.sh' <<<"$output"
  grep -qF -- 'beta.sh' <<<"$output"
}

# The historical and test surfaces, one test per pathspec: the repair differs
# for each, and a single test standing for the set would not notice one arm
# dropping out. That is a claim about coverage, so it is stated only because
# every entry in `EXCLUDED_PATHSPECS` has a test below that reds when its own
# entry is deleted. Two pairs need care and get separate fixtures for it: a
# `*.test.ts` under a `__tests__/` directory satisfies both pathspecs, so the
# `__tests__/` fixture uses a file no extension rule reaches, and
# `.gaia/tests/` and `.gaia/scripts/tests/` are distinct prefixes rather than
# one.

@test "the CHANGELOG is exempt: its old entries name the old spelling correctly" {
  local dir
  dir="$(make_fixture changelog)"
  write_registry "$dir" "$RENAMED_ONE"
  printf -- '- rename old-claim to new-claim. **Action required:** migrate.\n' >"$dir/CHANGELOG.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the wiki log is exempt: it records what was true at the time" {
  local dir
  dir="$(make_fixture wikilog)"
  write_registry "$dir" "$RENAMED_ONE"
  printf -- '- 2026-01-01 abc1234 WORTHY - old-claim label added\n' >"$dir/wiki/log.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the registry itself is exempt: renamedFrom IS the record of the retirement" {
  local dir
  dir="$(make_fixture registry_self)"
  write_registry "$dir" "$RENAMED_ONE"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the wiki's rolling cache is exempt: it is regenerated, not migrated" {
  local dir
  dir="$(make_fixture wikihot)"
  write_registry "$dir" "$RENAMED_ONE"
  printf -- '- last session drained an old-claim issue\n' >"$dir/wiki/hot.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the wiki's audit surface is exempt: it records prior audits verbatim" {
  local dir
  dir="$(make_fixture wikimeta)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/wiki/meta"
  printf -- '- the old-claim label was audited on 2026-01-01\n' >"$dir/wiki/meta/audit.md"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the generated bundles are exempt: their literals are the sources' literals" {
  local dir
  dir="$(make_fixture bundles)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/cli"
  printf 'gh issue list --label old-claim\n' >"$dir/.gaia/cli/gaia"
  printf 'gh issue list --label old-claim\n' >"$dir/.gaia/cli/gaia-maintainer"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a .bats suite is exempt: the rename's own migration test drives the old spelling" {
  local dir
  dir="$(make_fixture bats_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  printf '@test "renames old-claim" { true; }\n' >"$dir/.gaia/scripts/sample.bats"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a .test.ts file is exempt for the same reason" {
  local dir
  dir="$(make_fixture testts_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/cli/src/labels"
  printf "expect(plan).toEqual(['label', 'edit', 'old-claim', '--name', 'new-claim']);\n" \
    >"$dir/.gaia/cli/src/labels/sync.test.ts"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a __tests__ file no extension rule reaches is exempt on its own pathspec" {
  local dir
  dir="$(make_fixture tests_dir_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/cli/src/labels/__tests__"
  # Deliberately not a .test.ts: a fixture that were one would stay green with
  # the __tests__ pathspec deleted, which is the shape this test exists to red.
  printf "export const LEGACY = 'old-claim';\n" \
    >"$dir/.gaia/cli/src/labels/__tests__/fixtures.ts"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the framework bats tree is exempt by directory, not by extension" {
  local dir
  dir="$(make_fixture gaia_tests_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/tests/helpers"
  printf "readonly CLAIM=old-claim\n" >"$dir/.gaia/tests/helpers/claim.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the script-suite tree is exempt on its own pathspec, distinct from the one above" {
  local dir
  dir="$(make_fixture scripts_tests_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/scripts/tests/helpers"
  printf "readonly CLAIM=old-claim\n" >"$dir/.gaia/scripts/tests/helpers/claim.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "an untracked carrier is not graded" {
  local dir
  dir="$(make_fixture untracked)"
  write_registry "$dir" "$RENAMED_ONE"
  track_fixture "$dir"
  printf 'gh issue list --label old-claim\n' >"$dir/.gaia/scripts/draft.sh"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

# The boundary arm. A rename can leave the old spelling as a prefix or a suffix
# of the new one, and a fixed-string scan would then flag every live carrier and
# leave the gate un-greenable. Both directions get a fixture, because they are
# two different guards: the prefix case is the awk right-boundary test and the
# suffix case is the left one, and a suite driving only one leaves the other
# free to be deleted.

@test "a live name that merely contains the retired spelling is not a hit" {
  local dir
  dir="$(make_fixture boundary)"
  write_registry "$dir" '{
    "labels": [
      {"name": "in-progress-now", "renamedFrom": ["in-progress"]}
    ]
  }'
  printf 'gh issue edit 1 --add-label in-progress-now\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a live name that merely ends with the retired spelling is not a hit" {
  local dir
  dir="$(make_fixture boundary_suffix)"
  write_registry "$dir" '{
    "labels": [
      {"name": "now-in-progress", "renamedFrom": ["in-progress"]}
    ]
  }'
  printf 'gh issue edit 1 --add-label now-in-progress\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "the retired spelling standing alone is still a hit under the same registry" {
  local dir
  dir="$(make_fixture boundary_hit)"
  write_registry "$dir" '{
    "labels": [
      {"name": "in-progress-now", "renamedFrom": ["in-progress"]}
    ]
  }'
  printf 'gh issue edit 1 --add-label in-progress\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'reader.sh:1' <<<"$output"
}

# The namespace-prefix arm: unarmed on the real tree today, because every
# retired spelling's prefix is still live, so only a fixture reaches it.

@test "a retired namespace prefix is a hit even where no full spelling remains" {
  local dir
  dir="$(make_fixture retired_prefix)"
  write_registry "$dir" '{
    "labels": [
      {"name": "sev:critical", "renamedFrom": ["priority:critical"]}
    ]
  }'
  printf "const PREFIXES = ['priority:'];\n" >"$dir/.gaia/scripts/registry.ts"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'registry.ts:1' <<<"$output"
  grep -qF -- 'priority:' <<<"$output"
}

@test "a prefix a live entry still carries is never scanned" {
  local dir
  dir="$(make_fixture live_prefix)"
  write_registry "$dir" '{
    "labels": [
      {"name": "debt:spec-pending", "renamedFrom": []},
      {"name": "in-progress", "renamedFrom": ["debt:in-progress"]}
    ]
  }'
  printf "const PREFIXES = ['debt:'];\n" >"$dir/.gaia/scripts/registry.ts"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
}

@test "a retired spelling carrying a backslash still reaches the awk pass" {
  local dir
  dir="$(make_fixture backslash)"
  # `awk -v term=...` escape-processes its value, so a backslash-bearing
  # spelling would reach awk shorter than it left the registry: git grep -F
  # still returns the carrier, the awk pass then matches nothing, and the run
  # reports clean. That is the fail-open direction, which is why the term
  # travels through the environment instead.
  write_registry "$dir" '{
    "labels": [
      {"name": "new-claim", "renamedFrom": ["old\\bclaim"]}
    ]
  }'
  printf 'gh issue list --label "old\\bclaim"\n' >"$dir/.gaia/scripts/reader.sh"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 1 ]
  grep -qF -- 'reader.sh:1' <<<"$output"
}

# Environment arms: each reports rather than passing as clean.

@test "a missing registry exits 2 rather than reporting clean" {
  local dir
  dir="$(make_fixture no_registry)"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'not found' <<<"$output"
}

@test "a malformed registry exits 2 rather than reporting clean" {
  local dir
  dir="$(make_fixture malformed)"
  printf '{ not json\n' >"$dir/.gaia/labels.json"
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot read' <<<"$output"
}

@test "a registry whose entry has renamedFrom but no name exits 2, not jq's own code" {
  local dir
  dir="$(make_fixture nameless)"
  # Parses, and clears the full-spellings read, which never touches `name`.
  # Only the prefix read compares a name against ":", so this is the shape that
  # reaches the second jq call and nothing else does.
  write_registry "$dir" '{"labels": [{"renamedFrom": ["old-claim"]}]}'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot read' <<<"$output"
}

@test "a registry recording no rename says so rather than reporting clean" {
  local dir
  dir="$(make_fixture no_renames)"
  write_registry "$dir" '{"labels": [{"name": "keeper", "renamedFrom": []}]}'
  track_fixture "$dir"

  run bash "$CHECK" "$dir"
  [ "$status" -eq 0 ]
  grep -qF -- 'nothing to scan' <<<"$output"
  grep -qF -- 'clean' <<<"$output" && return 1
  true
}

@test "real tree: the live registry records at least one retired spelling, so the gate is armed" {
  run jq -r '[.labels[] | .renamedFrom[]?] | length' "$REPO_ROOT/.gaia/labels.json"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "real tree: no retired spelling survives in tracked source" {
  run bash "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF -- 'clean' <<<"$output"
}
