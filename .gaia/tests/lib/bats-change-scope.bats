#!/usr/bin/env bats

# Pins .gaia/tests/bats-change-scope.sh, the classifier that tells a change
# scoped CI leg whether a diff touches harness machinery (a static path list or
# a shell file other shell files source) or a dependency install input.
#
# The fixture cases build a throwaway git repository under $BATS_TEST_TMPDIR,
# commit a base, commit a change, and classify `HEAD~1 HEAD`. The pairs that
# differ by one line (a sourced file versus a standalone one, a `source` line
# present versus removed) prove the shared-library rule can tell the two apart.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only: `.gaia/tests` is release-excluded.

bats_require_minimum_version 1.5.0

setup() {
  CLASSIFIER="$BATS_TEST_DIRNAME/../bats-change-scope.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE"
  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.name fixture
  git -C "$FIXTURE" config user.email fixture@example.invalid
  git -C "$FIXTURE" config commit.gpgsign false
}

write_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "${2:-content}" > "$FIXTURE/$1"
}

commit_all() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "$1"
}

# Commits the files already written as the base, then one edit to each named
# path as the change.
commit_base_then_change() {
  commit_all base
  local changed_path
  for changed_path in "$@"; do
    printf 'changed\n' >> "$FIXTURE/$changed_path"
  done
  commit_all change
}

classify() {
  run bash "$CLASSIFIER" --dir "$FIXTURE" HEAD~1 HEAD
}

# Fails the test unless the output is exactly the given lines, in order.
expect_output_lines() {
  local expected
  expected="$(printf '%s\n' "$@")"
  if [ "$output" != "$expected" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
    return 1
  fi
}

@test "each static harness path classifies as harness" {
  local harness_paths=(
    ".github/workflows/audit-ci-tests.yml"
    ".gaia/tests/bats-shards.sh"
    ".gaia/tests/bats-change-scope.sh"
    ".gaia/scripts/bats-suites-for-change.sh"
    ".gaia/tests/install-bats.sh"
    ".gaia/tests/vendor/bats/x"
    ".gaia/tests/hooks/helpers/x.sh"
    ".gaia/tests/helpers/x.sh"
    ".gaia/scripts/tests/helpers/x.sh"
    ".github/actions/a/action.yml"
    ".gaia/release-exclude"
    ".claude/hooks/lib/x.sh"
    ".claude/hooks/a/lib/x.sh"
    ".gaia/scripts/lib/x.sh"
    "foo/bar-lib.sh"
    "bar-lib.sh"
  )
  local harness_path
  local failures=""
  for harness_path in "${harness_paths[@]}"; do
    rm -rf "$FIXTURE" && mkdir -p "$FIXTURE"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" config user.name fixture
    git -C "$FIXTURE" config user.email fixture@example.invalid
    git -C "$FIXTURE" config commit.gpgsign false
    write_file "$harness_path"
    commit_base_then_change "$harness_path"
    run bash "$CLASSIFIER" --dir "$FIXTURE" HEAD~1 HEAD
    local expected_line
    expected_line="$(printf 'harness\t%s' "$harness_path")"
    if [ "$status" -ne 0 ] || [ "$output" != "$expected_line" ]; then
      failures="$failures
$harness_path -> status $status, output: $output"
    fi
  done
  if [ -n "$failures" ]; then
    printf 'misclassified:%s\n' "$failures" >&2
    return 1
  fi
}

@test "near-miss paths do not classify as harness" {
  local negative_paths=(
    ".gaia/tests/hooks/x.sh"
    ".github/workflows/other.yml"
    "foo/bar-lib.sh.bak"
  )
  local negative_path
  local failures=""
  for negative_path in "${negative_paths[@]}"; do
    rm -rf "$FIXTURE" && mkdir -p "$FIXTURE"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" config user.name fixture
    git -C "$FIXTURE" config user.email fixture@example.invalid
    git -C "$FIXTURE" config commit.gpgsign false
    write_file "$negative_path"
    commit_base_then_change "$negative_path"
    run bash "$CLASSIFIER" --dir "$FIXTURE" HEAD~1 HEAD
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      failures="$failures
$negative_path -> status $status, output: $output"
    fi
  done
  if [ -n "$failures" ]; then
    printf 'misclassified:%s\n' "$failures" >&2
    return 1
  fi
}

@test "a file sourced by a literal operand is harness" {
  write_file a.sh '. "$DIR/shared.sh"'
  write_file shared.sh
  commit_base_then_change shared.sh
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tshared.sh')"
}

@test "a file sourced through a variable-built path is harness" {
  write_file entry.sh 'lib_path="$DIR/../x/gaia-packages.sh"
source "$lib_path"'
  write_file x/gaia-packages.sh
  commit_base_then_change x/gaia-packages.sh
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tx/gaia-packages.sh')"
}

@test "a variable assignment alone does not make a file a library" {
  write_file entry.sh 'lib_path="$DIR/../x/gaia-packages.sh"
echo "$lib_path"'
  write_file x/gaia-packages.sh
  commit_base_then_change x/gaia-packages.sh
  classify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a shellcheck source directive names a library" {
  write_file entry.sh '# shellcheck source=lib/thing.sh
. "$resolved"'
  write_file pkg/thing.sh
  commit_base_then_change pkg/thing.sh
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tpkg/thing.sh')"
}

@test "a shell file no other file sources is not harness, and is once one does" {
  write_file standalone.sh
  write_file other.sh 'echo hello'
  commit_base_then_change standalone.sh
  classify
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  write_file other.sh 'source "$DIR/standalone.sh"'
  commit_all sourcing
  printf 'again\n' >> "$FIXTURE/standalone.sh"
  commit_all change-again
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tstandalone.sh')"
}

@test "a source inside a heredoc body or a comment is not read" {
  write_file entry.sh 'cat <<EOF
source "$DIR/in-heredoc.sh"
EOF
# source "$DIR/in-comment.sh"
echo done'
  write_file in-heredoc.sh
  write_file in-comment.sh
  commit_base_then_change in-heredoc.sh in-comment.sh
  classify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a jq program's dot is not a source operand" {
  write_file entry.sh "jq -r '. as \$rows | \$rows' < input.json"
  write_file as.sh
  commit_base_then_change as.sh
  classify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each install input classifies as dependency and nothing else" {
  local install_inputs=(
    package.json
    pnpm-lock.yaml
    pnpm-workspace.yaml
    .npmrc
    .node-version
    frontend/package.json
    .gaia/cli/package.json
  )
  local install_input
  for install_input in "${install_inputs[@]}"; do
    write_file "$install_input"
  done
  commit_base_then_change "${install_inputs[@]}"
  classify
  [ "$status" -eq 0 ]
  local expected_lines=()
  while IFS= read -r install_input; do
    expected_lines+=("$(printf 'dependency\t%s' "$install_input")")
  done < <(printf '%s\n' "${install_inputs[@]}" | LC_ALL=C sort)
  expect_output_lines "${expected_lines[@]}"
}

@test "--list-install-inputs prints exactly the install inputs, one per line" {
  run bash "$CLASSIFIER" --list-install-inputs
  [ "$status" -eq 0 ]
  expect_output_lines package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc .node-version frontend/package.json .gaia/cli/package.json
}

@test "change-scoped categories classify as nothing" {
  local scoped_paths=(
    ".claude/skills/x/SKILL.md"
    ".claude/commands/x.md"
    ".claude/agents/x.md"
    ".claude/hooks/x.sh"
    ".gaia/cli/src/x.ts"
    "wiki/x/Y Z.md"
  )
  local scoped_path
  local failures=""
  for scoped_path in "${scoped_paths[@]}"; do
    rm -rf "$FIXTURE" && mkdir -p "$FIXTURE"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" config user.name fixture
    git -C "$FIXTURE" config user.email fixture@example.invalid
    git -C "$FIXTURE" config commit.gpgsign false
    write_file "$scoped_path"
    commit_base_then_change "$scoped_path"
    run bash "$CLASSIFIER" --dir "$FIXTURE" HEAD~1 HEAD
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      failures="$failures
$scoped_path -> status $status, output: $output"
    fi
  done
  if [ -n "$failures" ]; then
    printf 'misclassified:%s\n' "$failures" >&2
    return 1
  fi
}

@test "a renamed file lists both its old and new path" {
  write_file old-lib.sh
  commit_all base
  git -C "$FIXTURE" mv old-lib.sh new-lib.sh
  commit_all rename
  classify
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'harness\tnew-lib.sh')" "$(printf 'harness\told-lib.sh')"
}

@test "--paths classifies a newline-delimited path list" {
  write_file entry.sh 'source "$DIR/shared.sh"'
  write_file shared.sh
  commit_all base
  printf 'shared.sh\npackage.json\nwiki/x/Y Z.md\n' > "$BATS_TEST_TMPDIR/paths.txt"
  run bash "$CLASSIFIER" --dir "$FIXTURE" --paths "$BATS_TEST_TMPDIR/paths.txt"
  [ "$status" -eq 0 ]
  expect_output_lines "$(printf 'dependency\tpackage.json')" "$(printf 'harness\tshared.sh')"
}

@test "a diff argument naming a missing commit exits 3 with nothing on stdout" {
  write_file x.txt
  commit_all base
  run --separate-stderr bash "$CLASSIFIER" --dir "$FIXTURE" no-such-commit HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a directory that is not a repository exits 3" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr bash "$CLASSIFIER" --dir "$BATS_TEST_TMPDIR/plain" HEAD~1 HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "no diff argument is a usage error" {
  run bash "$CLASSIFIER" --dir "$FIXTURE"
  [ "$status" -eq 2 ]
}

@test "an unknown option is a usage error" {
  run bash "$CLASSIFIER" --dir "$FIXTURE" --bogus
  [ "$status" -eq 2 ]
}

@test "--list-harness-paths prints the static globs in order" {
  run bash "$CLASSIFIER" --list-harness-paths
  [ "$status" -eq 0 ]
  expect_output_lines \
    '.github/workflows/audit-ci-tests.yml' \
    '.gaia/tests/bats-shards.sh' \
    '.gaia/tests/bats-change-scope.sh' \
    '.gaia/scripts/bats-suites-for-change.sh' \
    '.gaia/tests/install-bats.sh' \
    '.gaia/tests/vendor/**' \
    '.gaia/tests/helpers/**' \
    '.gaia/tests/**/helpers/**' \
    '.gaia/scripts/tests/helpers/**' \
    '.github/actions/**' \
    '.gaia/release-exclude' \
    '.claude/hooks/**/lib/**' \
    '.gaia/scripts/**/lib/**' \
    '**/*-lib.sh'
}

# bats test_tags=whole-tree
@test "the real tree maps its shared libraries to harness" {
  local real_root
  real_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  local library_path
  for library_path in ".claude/hooks/lib/gaia-packages.sh" ".gaia/scripts/spec/uat-lib.sh"; do
    printf '%s\n' "$library_path" > "$BATS_TEST_TMPDIR/real-paths.txt"
    run bash "$CLASSIFIER" --dir "$real_root" --paths "$BATS_TEST_TMPDIR/real-paths.txt"
    [ "$status" -eq 0 ]
    expect_output_lines "$(printf 'harness\t%s' "$library_path")"
  done
}

# bats test_tags=whole-tree
@test "the real tree keeps change-scoped categories out of harness" {
  local real_root
  real_root="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  local skill_doc command_doc agent_doc cli_source wiki_page lone_hook
  skill_doc="$(git -C "$real_root" ls-files -z -- '.claude/skills/*/SKILL.md' | tr '\0' '\n' | sed -n 1p)"
  command_doc="$(git -C "$real_root" ls-files -z -- '.claude/commands/*.md' | tr '\0' '\n' | sed -n 1p)"
  agent_doc="$(git -C "$real_root" ls-files -z -- '.claude/agents/*.md' | tr '\0' '\n' | sed -n 1p)"
  cli_source="$(git -C "$real_root" ls-files -z -- '.gaia/cli/src/*.ts' | tr '\0' '\n' | sed -n 1p)"
  wiki_page="$(git -C "$real_root" ls-files -z -- 'wiki/*.md' | tr '\0' '\n' | sed -n 1p)"
  lone_hook=""
  local hook_path hook_name
  while IFS= read -r hook_path; do
    hook_name="$(basename "$hook_path")"
    if ! git -C "$real_root" grep -q -F -e "$hook_name" -- '*.sh' ':!'"$hook_path"; then
      lone_hook="$hook_path"
      break
    fi
  done < <(git -C "$real_root" ls-files -z -- '.claude/hooks/*.sh' | tr '\0' '\n')
  local category_path
  for category_path in "$skill_doc" "$command_doc" "$agent_doc" "$cli_source" "$wiki_page" "$lone_hook"; do
    [ -n "$category_path" ]
  done
  printf '%s\n' "$skill_doc" "$command_doc" "$agent_doc" "$cli_source" "$wiki_page" "$lone_hook" \
    > "$BATS_TEST_TMPDIR/real-paths.txt"
  run bash "$CLASSIFIER" --dir "$real_root" --paths "$BATS_TEST_TMPDIR/real-paths.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
