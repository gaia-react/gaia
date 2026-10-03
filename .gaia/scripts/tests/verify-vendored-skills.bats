#!/usr/bin/env bats
#
# verify-vendored-skills.sh over scratch fixture trees. Every drift case builds
# its own tree under $BATS_TEST_TMPDIR and points the script at it with --root,
# so the real vendored folder is never mutated.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/verify-vendored-skills.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  TARGET_RELATIVE="frontend/.claude/skills/demo"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Build a two-file vendored folder and a marker recording both hashes.
make_fixture() {
  mkdir -p "$FIXTURE/$TARGET_RELATIVE/references" "$FIXTURE/.gaia/vendor"
  printf 'top level\n' >"$FIXTURE/$TARGET_RELATIVE/SKILL.md"
  printf 'reference body\n' >"$FIXTURE/$TARGET_RELATIVE/references/one.md"
  jq -n \
    --arg target "$TARGET_RELATIVE" \
    --arg top "$(sha256_of "$FIXTURE/$TARGET_RELATIVE/SKILL.md")" \
    --arg one "$(sha256_of "$FIXTURE/$TARGET_RELATIVE/references/one.md")" \
    '{package: "demo", version: "1.0.0", integrity: "x", source: "skills/demo", target: $target, files: {"SKILL.md": $top, "references/one.md": $one}}' \
    >"$FIXTURE/.gaia/vendor/demo.json"
}

@test "passes on an untouched fixture" {
  make_fixture
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "a changed byte fails and names the file as MODIFIED" {
  make_fixture
  printf 'top levem\n' >"$FIXTURE/$TARGET_RELATIVE/SKILL.md"
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MODIFIED $TARGET_RELATIVE/SKILL.md"* ]]
}

@test "an added file fails and names the file as UNEXPECTED" {
  make_fixture
  printf 'stray\n' >"$FIXTURE/$TARGET_RELATIVE/references/extra.md"
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNEXPECTED $TARGET_RELATIVE/references/extra.md"* ]]
}

@test "a removed file fails and names the file as MISSING" {
  make_fixture
  rm "$FIXTURE/$TARGET_RELATIVE/references/one.md"
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING $TARGET_RELATIVE/references/one.md"* ]]
}

@test "an empty marker set exits 2 rather than reporting clean" {
  mkdir -p "$FIXTURE/.gaia/vendor"
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 2 ]
}

@test "a missing jq exits 2 naming jq" {
  make_fixture
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  PATH="$BATS_TEST_TMPDIR/empty-path" run "$BASH" "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq"* ]]
}

@test "an unknown argument exits 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "the real repository passes" {
  run "$SCRIPT" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "the real repository passes with the network unreachable" {
  npm_config_offline=true HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    run "$SCRIPT" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "the script never invokes npm, curl, or wget" {
  # Comment lines are dropped so the header may say what the script avoids.
  grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE '(^|[^[:alnum:]_-])(npm|curl|wget)([[:space:]]|$)' && return 1
  true
}

# The cli-tests job body, from its key to the next job key.
cli_tests_job() {
  awk '/^  cli-tests:$/ {inside=1; next} inside && /^  [a-zA-Z0-9_-]+:$/ {exit} inside {print}' "$WORKFLOW"
}

@test "cli-tests.yml runs the check in the cli-tests job" {
  local job
  job="$(cli_tests_job)"
  [ -n "$job" ]
  grep -qxF -- '        run: bash .gaia/scripts/verify-vendored-skills.sh' <<<"$job"
}

@test "cli-tests.yml filters on every path the check reads" {
  local job path
  job="$(cli_tests_job)"
  [ -n "$job" ]
  for path in 'frontend/.claude/skills/playwright-cli/**' '.gaia/vendor/**' '.gaia/scripts/verify-vendored-skills.sh'; do
    grep -qxF -- "              - '$path'" <<<"$job" || { echo "missing filter entry: $path" >&2; return 1; }
  done
}
