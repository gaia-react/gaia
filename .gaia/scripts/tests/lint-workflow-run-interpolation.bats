#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-workflow-run-interpolation.sh: the static gate
# that flags a `${{ }}` expression inside a workflow `run:` body, where Actions
# substitutes it into the script text before bash parses it.
#
# Two jobs, the same pair the sibling diff-quoting suite carries: prove the
# detector fires on a known-bad fixture and stays quiet on every legitimate
# shape (`env:`, `with:`, `if:`, `name:`, and a run body that only references
# shell variables), and assert the real scanned tree is clean so a regression
# fails CI.
#
# One test is load-bearing beyond coverage. A gate written for a class must red
# against that class's historical form, or it asserts nothing about the class it
# was written for: "reds against the pre-fix forensics-triage handler shape"
# carries a verbatim copy of a real pre-fix handler step, so it proves the
# detector reaches the shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-workflow-run-interpolation.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo: an initialized git repo in $TMP with no files yet.
fixture_repo() {
  TMP="$(mktemp -d -t run-interp-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_workflow <name> <body>: write <body> to $TMP/.github/workflows/<name>
# and track it. Call fixture_repo first.
fixture_workflow() {
  mkdir -p "$TMP/.github/workflows"
  printf '%s\n' "$2" > "$TMP/.github/workflows/$1"
  git -C "$TMP" add -A
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

@test "reds against the pre-fix forensics-triage handler shape" {
  fixture_repo
  fixture_workflow triage.yml 'jobs:
  t:
    steps:
      - name: Handle malformed body
        run: |
          set -eu
          "$FORENSICS_DIR/handlers/handle-malformed-body.sh" \
            "$ISSUE_NUMBER" \
            "${{ steps.parse.outputs.parsed_file }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "triage.yml:9:" <<<"$output"
  grep -qF -- "env: block" <<<"$output"
}

@test "greens on the env: indirection that replaces it" {
  fixture_repo
  fixture_workflow triage.yml 'jobs:
  t:
    steps:
      - name: Handle malformed body
        env:
          PARSED_FILE: ${{ steps.parse.outputs.parsed_file }}
        run: |
          set -eu
          "$FORENSICS_DIR/handlers/handle-malformed-body.sh" \
            "$ISSUE_NUMBER" \
            "$PARSED_FILE"'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "ignores expressions in with:, if:, name: and job-level env:" {
  fixture_repo
  fixture_workflow other.yml 'name: X
on: push
env:
  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
jobs:
  t:
    if: ${{ github.event_name == "push" }}
    steps:
      - name: Run ${{ github.actor }}
        uses: some/action@v1
        with:
          prompt: ${{ steps.render.outputs.body }}'
  run_linter
  [ "$status" -eq 0 ]
}

@test "flags an expression on an inline run: value" {
  fixture_repo
  fixture_workflow inline.yml 'jobs:
  t:
    steps:
      - run: ./script.sh "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "inline.yml:4:" <<<"$output"
}

@test "flags an expression inside a comment in a run body" {
  fixture_repo
  fixture_workflow commented.yml 'jobs:
  t:
    steps:
      - run: |
          # value was ${{ steps.x.outputs.y }}
          echo hi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "commented.yml:5:" <<<"$output"
}

@test "does not leak past the end of a run block" {
  fixture_repo
  fixture_workflow boundary.yml 'jobs:
  t:
    steps:
      - name: First
        run: |
          echo hi
      - name: Second
        env:
          V: ${{ steps.x.outputs.y }}
        run: |
          echo "$V"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "keeps scanning after a run block ends" {
  fixture_repo
  fixture_workflow second.yml 'jobs:
  t:
    steps:
      - name: First
        run: |
          echo hi
      - name: Second
        run: |
          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "second.yml:9:" <<<"$output"
}

@test "blank lines do not end a run block" {
  fixture_repo
  fixture_workflow blanks.yml 'jobs:
  t:
    steps:
      - run: |
          echo one

          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "blanks.yml:7:" <<<"$output"
}

# The three tests below pin block-scalar header shapes that are legal YAML and
# whose bodies Actions runs normally. Each one, before the header pattern was
# widened, sent the header down the inline arm and left every line of the body
# unscanned -- a fail-open on a real shape rather than a declared blind spot.

@test "a comment after the block-scalar indicator does not hide the body" {
  fixture_repo
  fixture_workflow commented-header.yml 'jobs:
  t:
    steps:
      - run: | # note
          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "commented-header.yml:5:" <<<"$output"
}

@test "indentation and chomping indicators in either order do not hide the body" {
  fixture_repo
  fixture_workflow indicator-order.yml 'jobs:
  t:
    steps:
      - name: A
        run: |2-
          echo "${{ steps.x.outputs.y }}"
      - name: B
        run: |-2
          echo "${{ steps.a.outputs.b }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "indicator-order.yml:6:" <<<"$output"
  grep -qF -- "indicator-order.yml:9:" <<<"$output"
}

@test "a folded scalar with a trailing comment does not hide the body" {
  fixture_repo
  fixture_workflow folded.yml 'jobs:
  t:
    steps:
      - run: >- # folded
          echo "${{ steps.x.outputs.y }}"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "folded.yml:5:" <<<"$output"
}

# The gate scans composite actions too: workflows here invoke them, so stopping
# at the first `uses:` hop would enforce the class only on the callers.

@test "flags an expression in a composite action run body" {
  TMP="$(mktemp -d -t run-interp-lint-XXXXXX)"
  git -C "$TMP" init -q .
  mkdir -p "$TMP/.github/actions/thing"
  printf '%s\n' 'runs:
  using: composite
  steps:
    - shell: bash
      run: |
        echo "${{ steps.x.outputs.y }}"' > "$TMP/.github/actions/thing/action.yml"
  git -C "$TMP" add -A
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "action.yml:6:" <<<"$output"
}

@test "errors rather than greening when nothing is scanned" {
  TMP="$(mktemp -d -t run-interp-lint-XXXXXX)"
  git -C "$TMP" init -q .
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
}

@test "the real repository tree is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}
