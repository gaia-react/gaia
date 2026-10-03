#!/usr/bin/env bats

# Tests for commitlint.config.mjs, driven through the real commitlint binary.
#
# Every refusal here is paired with an acceptance on the same rule's other
# side, so a config that rejects everything (or nothing) fails a test.
#
# This suite needs the root workspace's node_modules, which no bats shard in
# .github/workflows/audit-ci-tests.yml installs, so it lives outside the
# directories .gaia/tests/bats-shards.sh discovers; that workflow's dedicated
# commitlint leg installs the root deps and runs it. Run it locally with
# `.gaia/scripts/bats5.sh .gaia/tests/commitlint/commitlint-config.bats`.
#
# A missing commitlint FAILS setup_file rather than skipping: a skipped guard
# reads as green.

setup_file() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  if [ ! -x "$REPO_ROOT/node_modules/.bin/commitlint" ]; then
    printf 'commitlint is not installed at %s: run pnpm install\n' \
      "$REPO_ROOT/node_modules/.bin/commitlint" >&3
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to derive the type list\n' >&3
    return 1
  fi
}

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  COMMITLINT="$REPO_ROOT/node_modules/.bin/commitlint"
  REAL_CONFIG="$REPO_ROOT/commitlint.config.mjs"
  TYPES_FILE="$REPO_ROOT/.gaia/conventional-commits.json"
}

# lint_with <config> <message>: runs commitlint on the message, sets $status
# and $output.
lint_with() {
  local config="$1" message="$2"
  local message_file="$BATS_TEST_TMPDIR/message.txt"
  printf '%s\n' "$message" > "$message_file"
  cd "$REPO_ROOT" || return 1
  run "$COMMITLINT" --config "$config" --edit "$message_file"
}

# lint <message>: the real repo config.
lint() {
  lint_with "$REAL_CONFIG" "$1"
}

# header_of_length <n>: a `feat: aaa...` header exactly n characters long.
header_of_length() {
  local total="$1" filler_length
  filler_length=$((total - 6))
  printf 'feat: %s' "$(printf 'a%.0s' $(seq 1 "$filler_length"))"
}

@test "commitlint: REFUSES the retired debt type and names type-enum" {
  lint "debt(hooks): widen the guard"
  [ "$status" -ne 0 ]
  [[ "$output" == *"type-enum"* ]]
}

@test "commitlint: ACCEPTS every type in the shared list" {
  local type_name checked=0 expected
  expected=$(jq -r '.types | length' "$TYPES_FILE")
  [ "$expected" -gt 0 ]
  while IFS= read -r type_name; do
    lint "$type_name: do a thing"
    if [ "$status" -ne 0 ]; then
      printf 'type %s was refused: %s\n' "$type_name" "$output" >&3
      return 1
    fi
    checked=$((checked + 1))
  done < <(jq -r '.types[]' "$TYPES_FILE")
  [ "$checked" -eq "$expected" ]
}

@test "commitlint: REFUSES an uppercase type" {
  lint "Feat: Add thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"type-case"* ]]
}

@test "commitlint: REFUSES a trailing full stop" {
  lint "feat: add thing."
  [ "$status" -ne 0 ]
  [[ "$output" == *"subject-full-stop"* ]]
}

@test "commitlint: REFUSES an empty subject" {
  lint "feat:"
  [ "$status" -ne 0 ]
  [[ "$output" == *"subject-empty"* ]]
}

@test "commitlint: REFUSES a 101-character header" {
  local header
  header=$(header_of_length 101)
  [ "${#header}" -eq 101 ]
  lint "$header"
  [ "$status" -ne 0 ]
  [[ "$output" == *"header-max-length"* ]]
}

@test "commitlint: ACCEPTS a 100-character header" {
  local header
  header=$(header_of_length 100)
  [ "${#header}" -eq 100 ]
  lint "$header"
  [ "$status" -eq 0 ]
}

@test "commitlint: ACCEPTS a breaking change with a BREAKING CHANGE footer" {
  lint "$(printf 'feat(api)!: drop v1\n\nBREAKING CHANGE: v1 removed')"
  [ "$status" -eq 0 ]
}

@test "commitlint: ACCEPTS a body line longer than 100 characters" {
  local long_line
  long_line=$(printf 'word %.0s' $(seq 1 40))
  [ "${#long_line}" -gt 100 ]
  lint "$(printf 'feat: add thing\n\n%s' "$long_line")"
  [ "$status" -eq 0 ]
}

@test "commitlint: ACCEPTS the default-ignored message shapes" {
  local message
  for message in \
    "fixup! feat: x" \
    "squash! feat: x" \
    "Merge branch 'main' into feat/x" \
    'Revert "feat: x"'; do
    lint "$message"
    if [ "$status" -ne 0 ]; then
      printf 'ignored shape was refused (%s): %s\n' "$message" "$output" >&3
      return 1
    fi
  done
}

@test "commitlint: the type list is read from the JSON, not copied into the config" {
  local scratch="$BATS_TEST_TMPDIR/single-source"
  mkdir -p "$scratch/.gaia"
  cp "$REAL_CONFIG" "$scratch/commitlint.config.mjs"
  jq '.types += ["zzz"]' "$TYPES_FILE" > "$scratch/.gaia/conventional-commits.json"
  ln -s "$REPO_ROOT/node_modules" "$scratch/node_modules"

  # The added type is only known to the modified JSON beside the copied config.
  lint_with "$scratch/commitlint.config.mjs" "zzz: x"
  [ "$status" -eq 0 ]

  lint "zzz: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"type-enum"* ]]
}

@test "commit-msg hook end to end: git refuses debt and accepts feat" {
  local scratch="$BATS_TEST_TMPDIR/end-to-end"
  mkdir -p "$scratch/.githooks" "$scratch/.gaia" "$scratch/shim"
  # `pnpm exec` in a scratch directory tries to install into the node_modules
  # symlinked below, which would reach the real tree. The shim stands in for it:
  # the hook's `pnpm -C <root> exec <command> ...` runs the real commitlint
  # binary from <root>.
  cat > "$scratch/shim/pnpm" <<SHIM
#!/bin/sh
cd "\$2" || exit 1
shift 3
exec "$REPO_ROOT/node_modules/.bin/\$@"
SHIM
  chmod +x "$scratch/shim/pnpm"
  git -C "$scratch" init --quiet --initial-branch=main
  git -C "$scratch" config user.email "test@example.com"
  git -C "$scratch" config user.name "Test"
  git -C "$scratch" config commit.gpgsign false
  cp "$REAL_CONFIG" "$scratch/commitlint.config.mjs"
  cp "$TYPES_FILE" "$scratch/.gaia/conventional-commits.json"
  cp "$REPO_ROOT/.githooks/commit-msg" "$scratch/.githooks/commit-msg"
  ln -s "$REPO_ROOT/node_modules" "$scratch/node_modules"
  # The real hook, activated the way the root `prepare` script activates it.
  git -C "$scratch" config core.hooksPath .githooks
  printf 'one\n' > "$scratch/file.txt"
  git -C "$scratch" add file.txt

  PATH="$scratch/shim:$PATH" run git -C "$scratch" commit -m "debt: x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Naming Conventions.md"* ]]
  # The refused commit left no commit behind.
  git -C "$scratch" rev-parse --verify --quiet HEAD && return 1

  PATH="$scratch/shim:$PATH" run git -C "$scratch" commit -m "feat: x"
  [ "$status" -eq 0 ]
  git -C "$scratch" rev-parse --verify --quiet HEAD
}
