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

# The historical and test surfaces, one test each: the repair differs for each,
# and a single test standing for the set would not notice one arm dropping out.

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

@test "a test file is exempt: the rename's own migration test drives the old spelling" {
  local dir
  dir="$(make_fixture tests_exempt)"
  write_registry "$dir" "$RENAMED_ONE"
  mkdir -p "$dir/.gaia/cli/src/labels/__tests__"
  printf "expect(plan).toEqual(['label', 'edit', 'old-claim', '--name', 'new-claim']);\n" \
    >"$dir/.gaia/cli/src/labels/__tests__/sync.test.ts"
  printf '@test "renames old-claim" { true; }\n' >"$dir/.gaia/scripts/sample.bats"
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
# leave the gate un-greenable.

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
