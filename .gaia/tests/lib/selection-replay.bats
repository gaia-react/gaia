#!/usr/bin/env bats

# Fixture suite for .gaia/tests/selection-replay.sh, the replay that re-runs the
# change-scoped selection over historical pull-request heads and reports whether
# each recorded failing test would still run. Every case builds on a fixture git
# repository holding copies of the sharder, the change classifier, the change
# selector and the mark-pattern library at their real relative paths, plus a
# fixture workflow carrying the filter block and a few tiny suites. The sharder
# derives its repository root from its own location, so the copy inside the
# fixture runs the fixture's own classifier and selector, and the real tree is
# never read.
#
# Each fixture commit touches exactly one path; a case pairs a commit with its
# parent. Cases that need a different suite shape rewrite one fixture suite in
# that test's own copy of the repository.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX [ ] and grep only.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# write_suite <path> <file-tag-line|-> <test-tag-line|-> <test-name>...
# Writes a suite whose first test carries the given test tag line. The mark lines
# arrive assembled, so this file never holds one at column 0.
write_suite() {
  local path="$1" file_tag="$2" test_tag="$3" name first=1
  shift 3
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bats\n'
    if [ "$file_tag" != - ]; then printf '%s\n' "$file_tag"; fi
    printf '\n'
    for name in "$@"; do
      if [ "$first" -eq 1 ] && [ "$test_tag" != - ]; then printf '%s\n' "$test_tag"; fi
      first=0
      printf '@test "%s" {\n  true\n}\n\n' "$name"
    done
  } >"$path"
}

# commit_path <repo> <path>: appends a line to the path, records it in one
# fixture commit and prints the commit's SHA.
commit_path() {
  local repo="$1" path="$2"
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$RANDOM$RANDOM" >>"$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -q -m "touch $path"
  git -C "$repo" rev-parse HEAD
}

setup_file() {
  local seed="$BATS_FILE_TMPDIR/seed" lib="$BATS_FILE_TMPDIR/seed/.gaia/tests/lib"
  local whole_file whole_test dependency_file
  whole_file="$(printf '# bats file_tags=%s' whole-tree)"
  whole_test="$(printf '# bats test_tags=%s' whole-tree)"
  dependency_file="$(printf '# bats file_tags=%s' installed-dependencies)"
  mkdir -p "$seed/.gaia/tests/helpers" "$seed/.gaia/scripts" "$seed/.github/workflows"
  cp "$REAL_ROOT/.gaia/tests/bats-shards.sh" "$REAL_ROOT/.gaia/tests/bats-change-scope.sh" "$seed/.gaia/tests/"
  cp "$REAL_ROOT/.gaia/scripts/bats-suites-for-change.sh" "$seed/.gaia/scripts/"
  cp "$REAL_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh" "$seed/.gaia/tests/helpers/"
  {
    printf 'name: fixture\njobs:\n  shards:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - uses: dorny/paths-filter@0000000000000000000000000000000000000000\n'
    printf '        id: filter\n        with:\n          filters: |\n'
    printf '            code:\n              - ".gaia/tests/bats-shards.sh"\n'
    printf '            scoped:\n              - "docs/**"\n'
    printf '            sandbox:\n              - "sandbox-input/**"\n'
    printf '            commitlint:\n              - "commitlint.config.txt"\n'
  } >"$seed/.github/workflows/audit-ci-tests.yml"
  write_suite "$lib/selected.bats" - - "reads the thing"
  printf '# names data/thing.conf\n' >>"$lib/selected.bats"
  write_suite "$lib/marked.bats" - "$whole_test" "marked test" "unmarked test"
  write_suite "$lib/plain.bats" - - "plain test"
  write_suite "$lib/filemarked.bats" "$whole_file" - "file marked test"
  write_suite "$lib/dependency.bats" "$dependency_file" - "dependency test"
  write_suite "$lib/dependency-plain.bats" - - "dependency plain test"
  write_suite "$seed/.gaia/tests/concurrency/meter.bats" - - "meter test"
  write_suite "$seed/.gaia/tests/commitlint/lint.bats" - - "lint test"
  mkdir -p "$seed/data"
  printf 'x\n' >"$seed/data/thing.conf"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.email fixture@example.invalid
  git -C "$seed" config user.name fixture
  git -C "$seed" config commit.gpgsign false
  git -C "$seed" add -A
  git -C "$seed" commit -q -m base
  {
    printf 'BASE=%s\n' "$(git -C "$seed" rev-parse HEAD)"
    printf 'SELECTED=%s\n' "$(commit_path "$seed" data/thing.conf)"
    printf 'UNRELATED=%s\n' "$(commit_path "$seed" misc/unrelated.txt)"
    printf 'LOCKFILE=%s\n' "$(commit_path "$seed" pnpm-lock.yaml)"
    printf 'HELPER=%s\n' "$(commit_path "$seed" .gaia/tests/helpers/note.txt)"
    printf 'SCOPED=%s\n' "$(commit_path "$seed" docs/scoped-note.md)"
    printf 'NOWHERE=%s\n' "$(commit_path "$seed" elsewhere/nowhere.txt)"
    printf 'COMMITLINT=%s\n' "$(commit_path "$seed" commitlint.config.txt)"
  } >"$BATS_FILE_TMPDIR/shas"
}

setup() {
  cp -R "$BATS_FILE_TMPDIR/seed" "$BATS_TEST_TMPDIR/repo"
  # shellcheck disable=SC1091
  . "$BATS_FILE_TMPDIR/shas"
  SCRIPT="$REAL_ROOT/.gaia/tests/selection-replay.sh"
  CASES="$BATS_TEST_TMPDIR/cases.json"
  RESULTS="$BATS_TEST_TMPDIR/results.json"
}

# parent_of <sha>: the fixture commit before it.
parent_of() {
  git -C "$BATS_TEST_TMPDIR/repo" rev-parse "$1^"
}

# write_case <head> <suite> <test> [<extra-json-object>]: a one-case input file.
write_case() {
  local head="$1" suite="$2" test_name="$3" extra="${4:-}" merge_base
  if [ -z "$extra" ]; then extra='{}'; fi
  merge_base="$(parent_of "$head")"
  jq -n --arg head "$head" --arg merge_base "$merge_base" --arg suite "$suite" \
    --arg test "$test_name" --argjson extra "$extra" \
    '[{run_id: 1, pr: 2, head: $head, merge_base: $merge_base, leg: "lib", suite: $suite, test: $test} + $extra]' >"$CASES"
}

verdict_of() {
  jq -r '.[0].verdict' "$RESULTS"
}

@test "a suite naming a changed file is selected in full" {
  write_case "$SELECTED" .gaia/tests/lib/selected.bats "reads the thing"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = selected-full ]
}

@test "a test carrying the whole-tree test mark is kept on an unrelated change" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = whole-tree-marked ]
}

@test "an unmarked test on an unrelated change is a miss, exit 1, named on stderr" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "unmarked test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
  printf '%s\n' "$output" | grep -qF -- "unmarked test"
}

@test "removing the mark turns the marked case into a miss" {
  local suite="$BATS_TEST_TMPDIR/repo/.gaia/tests/lib/marked.bats"
  grep -v 'test_tags' "$suite" >"$suite.tmp"
  mv "$suite.tmp" "$suite"
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
  printf '%s\n' "$output" | grep -qF -- "marked test"
}

@test "a lockfile change keeps an installed-dependencies suite" {
  write_case "$LOCKFILE" .gaia/tests/lib/dependency.bats "dependency test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = dependency-full ]
}

@test "a lockfile change on a suite without the dependency mark is a miss" {
  write_case "$LOCKFILE" .gaia/tests/lib/dependency-plain.bats "dependency plain test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
}

@test "a harness-only change runs the whole shard" {
  write_case "$HELPER" .gaia/tests/lib/plain.bats "plain test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = harness-full ]
}

@test "a concurrency suite is armed by a path in the scoped filter" {
  write_case "$SCOPED" .gaia/tests/concurrency/meter.bats "meter test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = leg-armed ]
}

@test "a concurrency suite is a miss when the change touches no filter" {
  write_case "$NOWHERE" .gaia/tests/concurrency/meter.bats "meter test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
}

@test "a commitlint suite is armed by the commitlint filter" {
  write_case "$COMMITLINT" .gaia/tests/commitlint/lint.bats "lint test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = leg-armed ]
}

@test "a commitlint suite is a miss on a change only the scoped filter holds" {
  write_case "$SCOPED" .gaia/tests/commitlint/lint.bats "lint test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
}

@test "a test that is gone resolves to its marked successor" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "renamed away" \
    '{"successor_suite": ".gaia/tests/lib/marked.bats", "successor_test": "marked test"}'
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = whole-tree-marked ]
}

@test "a gone test without a successor is test-gone-today, exit 1" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "renamed away"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = test-gone-today ]
}

@test "a whole-suite successor on a file-marked suite is whole-tree-marked" {
  write_case "$UNRELATED" .gaia/tests/lib/plain.bats "gone" \
    '{"successor_suite": ".gaia/tests/lib/filemarked.bats", "successor_test": null}'
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(verdict_of)" = whole-tree-marked ]
}

@test "a whole-suite successor on an unmarked suite is a miss" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "gone" \
    '{"successor_suite": ".gaia/tests/lib/plain.bats", "successor_test": null}'
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
}

@test "a whole-suite successor does not count a single-test mark" {
  write_case "$UNRELATED" .gaia/tests/lib/plain.bats "gone" \
    '{"successor_suite": ".gaia/tests/lib/marked.bats", "successor_test": null}'
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  [ "$(verdict_of)" = miss ]
}

@test "a commit absent from the repository exits 2" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
  jq '.[0].head = "0123456789012345678901234567890123456789"' "$CASES" >"$CASES.tmp"
  mv "$CASES.tmp" "$CASES"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "0123456789012345678901234567890123456789"
}

@test "a merge_base equal to head exits 2" {
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
  jq '.[0].merge_base = .[0].head' "$CASES" >"$CASES.tmp"
  mv "$CASES.tmp" "$CASES"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "merge_base"
}

@test "malformed JSON exits 2" {
  printf '[{"run_id": 1,\n' >"$CASES"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi -- "json"
}

@test "a workflow with no filter block exits 2" {
  printf 'name: fixture\njobs:\n  shards:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    >"$BATS_TEST_TMPDIR/repo/.github/workflows/audit-ci-tests.yml"
  write_case "$UNRELATED" .gaia/tests/lib/marked.bats "marked test"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi -- "filter"
}

@test "a missing output argument exits 2" {
  run bash "$SCRIPT" --input "$CASES"
  [ "$status" -eq 2 ]
}

@test "results are one entry per case in input order with the six fields" {
  local merge_base_one merge_base_two
  merge_base_one="$(parent_of "$SELECTED")"
  merge_base_two="$(parent_of "$UNRELATED")"
  jq -n --arg h1 "$SELECTED" --arg b1 "$merge_base_one" --arg h2 "$UNRELATED" --arg b2 "$merge_base_two" '[
    {run_id: 11, pr: 21, head: $h2, merge_base: $b2, leg: "lib", suite: ".gaia/tests/lib/marked.bats", test: "marked test"},
    {run_id: 12, pr: 22, head: $h1, merge_base: $b1, leg: "lib", suite: ".gaia/tests/lib/selected.bats", test: "reads the thing"}
  ]' >"$CASES"
  run bash "$SCRIPT" --input "$CASES" --output "$RESULTS" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$RESULTS")" -eq 2 ]
  [ "$(jq -r '[.[].run_id] | map(tostring) | join(",")' "$RESULTS")" = "11,12" ]
  [ "$(jq -r '[.[].verdict] | join(",")' "$RESULTS")" = "whole-tree-marked,selected-full" ]
  [ "$(jq -r '.[0] | keys | join(",")' "$RESULTS")" = "head,pr,run_id,suite,test,verdict" ]
}
