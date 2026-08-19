#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so `$?`, `$(...)`, and the variable references inside reach the fixture file as
# literal text. The unexpanded status reference IS the thing under test, so
# letting the shell expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-errexit-status-read.sh: the static gate that flags
# a read of `$?` following a bare command-substitution assignment while errexit
# is armed, where the assignment takes the substitution's status and the shell
# has already exited by the time the read would run.
#
# Three jobs. Prove the detector fires on the class, on both surfaces and
# through every spelling the shape takes; prove it stays quiet on the legitimate
# shapes, which for this gate is the load-bearing half, because the repair its
# own hint text advertises, the `local` form shellcheck already owns, the
# deferred `trap` capture, and every script that simply never arms errexit are
# all things a naive detector reds on; and assert the real scanned tree is clean
# so a regression fails CI.
#
# One test is load-bearing beyond coverage. A gate written for a class must red
# against that class's historical form, or it asserts nothing about the class it
# was written for: "reds against the shipped composite-action shape" carries the
# `run:` body with no explicit `set -e`, which is how both instances in
# gaia-react/gaia#1477 and gaia-react/gaia#1478 were live, so it proves the
# detector reaches the shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. It also requires
# BOTH halves of that surface to be non-empty, so fixture_repo seeds one benign
# file of each kind and each test adds the file it is actually about.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so the fixture reaches the
# file as the characters the gate is meant to read.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_repo: an initialized git repo in $TMP carrying one benign file of each
# scanned kind, so the gate's non-empty-surface precondition is met and a test
# can add just the file it is about.
fixture_repo() {
  TMP="$(mktemp -d -t errexit-status-lint-XXXXXX)"
  git -C "$TMP" init -q .
  fixture_file seed.sh 'echo seed'
  fixture_file .github/workflows/seed.yml 'jobs:
  seed:
    steps:
      - run: |
          echo seed'
}

# fixture_script <body>: the common case, a tracked shell script.
fixture_script() {
  fixture_file check.sh "$1"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the class fires, workflow surface -------------------------------------

@test "reds against the shipped composite-action shape" {
  fixture_repo
  fixture_file .github/actions/merge-and-watch/action.yml 'runs:
  using: composite
  steps:
    - shell: bash
      run: |
        revert_out="$(gaia ci-revert open --pr "$PR")"
        revert_rc=$?
        if [ "$revert_rc" -ne 0 ]; then
          echo "::error::revert failed" >&2
          exit 1
        fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/actions/merge-and-watch/action.yml:7:' <<<"$output"
  grep -qF -- 'the assignment takes the substitution status' <<<"$output"
}

@test "arms a run: body with no explicit set -e, because Actions runs bash -e" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1 --json state)
          rc=$?
          echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.github/workflows/probe.yml:6:' <<<"$output"
}

@test "flags a run: body inside an adopter workflow template" {
  fixture_repo
  fixture_file .gaia/cli/src/automation/templates/workflows/audit.yml.tmpl 'jobs:
  audit:
    steps:
      - run: |
          body=$(cat report.txt)
          rc=$?
          echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'templates/workflows/audit.yml.tmpl:6:' <<<"$output"
}

@test "keeps scanning a template run: body across a mustache section tag" {
  fixture_repo
  fixture_file .gaia/cli/src/automation/templates/workflows/audit.yml.tmpl 'jobs:
  audit:
    steps:
      - run: |
          echo start
{{#with_probe}}
          out=$(probe)
          rc=$?
{{/with_probe}}
          echo done'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'templates/workflows/audit.yml.tmpl:8:' <<<"$output"
}

@test "leaves a run: body at the first dedent, so surrounding YAML is not shell" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1)
        env:
          RC: $?'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the class fires, shell surface ----------------------------------------

@test "flags a quoted command-substitution assignment under set -euo pipefail" {
  fixture_repo
  fixture_script 'set -euo pipefail
out="$(some_command --json)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
  grep -qF -- 'assignment at line 2' <<<"$output"
}

@test "flags the unquoted spelling" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "flags the read spelling shellcheck sees, so the two agree rather than diverge" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
if [ $? -ne 0 ]; then
  echo dead
fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "flags across an intervening comment, which executes nothing" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
# Capture the status so the branch below can report it.
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

@test "flags across an intervening blank line" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)

rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

@test "flags a legacy backtick substitution" {
  fixture_repo
  fixture_script 'set -e
out=`some_command`
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "flags after set -o errexit written the long way" {
  fixture_repo
  fixture_script 'set -o errexit
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "follows a command substitution spanning several lines" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command \
  --flag one \
  --flag two)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:5:' <<<"$output"
  grep -qF -- 'assignment at line 2' <<<"$output"
}

@test "flags a status read inside double quotes, which does expand" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
echo "command exited $?"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "re-arms after a set +e block closes" {
  fixture_repo
  fixture_script 'set -e
set +e
lenient=$(some_command)
rc=$?
set -e
strict=$(other_command)
rc=$?
echo "$lenient $strict $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:7:' <<<"$output"
  grep -qF -- 'check.sh:4:' <<<"$output" && return 1
  true
}

# --- the legitimate shapes stay quiet --------------------------------------

@test "quiet on a script that never arms errexit" {
  fixture_repo
  fixture_script 'out=$(some_command)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "failed" >&2
fi'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on the repair the gate own hint text advertises" {
  fixture_repo
  fixture_script 'set -euo pipefail
rc=0
out="$(some_command)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "failed" >&2
fi'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a local-prefixed assignment, which shellcheck owns as SC2155" {
  fixture_repo
  fixture_script 'set -e
f() {
  local out=$(some_command)
  local rc=$?
  echo "$out $rc"
}
f'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on export- and readonly-prefixed assignments" {
  fixture_repo
  fixture_script 'set -e
export OUT=$(some_command)
rc=$?
readonly OTHER=$(other_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a deferred trap capture, the idiom five scripts here use" {
  fixture_repo
  fixture_script 'set -euo pipefail
TMP=$(mktemp -d)
trap '"'"'rc=$?; if [ "$rc" -ne 0 ]; then cat "$TMP/log"; fi; rm -rf "$TMP"'"'"' EXIT
echo "$TMP"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet while set +e holds" {
  fixture_repo
  fixture_script 'set -e
set +e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet when a real command separates the assignment from the read" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
echo "ran"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on an assignment used as an if condition" {
  fixture_repo
  fixture_script 'set -e
if out=$(some_command); then
  echo "$out"
fi
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on an assignment with no command substitution at all" {
  fixture_repo
  fixture_script 'set -e
out=literal
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "flags the one-line semicolon spelling, which separates rather than joins" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) ; rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:2:' <<<"$output"
}

@test "quiet on a pipeline, where the assignment is not a bare simple command" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) | tee log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on the second statement of a line whose first is guarded" {
  fixture_repo
  fixture_script 'set -e
rc=0
out=$(some_command) || rc=$?; echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a bats suite, the deliberately excluded surface" {
  fixture_repo
  fixture_file suite.bats '@test "fixture" {
  cat > "$BATS_TEST_TMPDIR/bad.sh" <<EOF
set -e
out=\$(some_command)
rc=\$?
EOF
  true
}'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the tokenizer holds sync, or says it could not --------------------------
#
# These six pin the detector's cross-line state. They matter more than their
# count suggests: state is carried across lines deliberately, so a tokenizer that
# desyncs does not misread one statement, it swallows every remaining line of the
# file while the gate still prints `clean`. Each was a measured live failure
# before the fix, not a hypothetical.

@test "keeps reading past a substitution carrying a paren inside a quoted string" {
  fixture_repo
  fixture_script 'set -euo pipefail
cand=$(printf "%s" "$rest" | sed -E "s/[[:space:])].*$//")
echo "$cand"
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:5:' <<<"$output"
}

@test "follows a heredoc opened inside a command substitution" {
  fixture_repo
  fixture_script 'set -euo pipefail
PATHS="$(cat <<EOF
one
two
EOF
)"
out=$(some_command)
rc=$?
echo "$PATHS $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:8:' <<<"$output"
}

@test "quiet on a heredoc body carrying the shape as a fixture" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/fixture.sh <<EOF
set -e
out=\$(some_command)
rc=\$?
EOF
echo done'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a set +e inside a heredoc body does not disarm the script around it" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.sh <<EOF
set +e
EOF
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:6:' <<<"$output"
}

@test "an apostrophe inside a heredoc body does not swallow the rest of the file" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<EOF
this body carries an apostrophe: it is the shell that would not
EOF
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:6:' <<<"$output"
}

@test "quiet on arithmetic expansion, which runs no command and cannot trip errexit" {
  fixture_repo
  fixture_script 'set -euo pipefail
x=$((1 + 2))
rc=$?
echo "$x $rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "reports a file it could not tokenize to the end rather than certifying it" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<NEVERCLOSED
one
two'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'check.sh' <<<"$output"
}

# --- the gate refuses to report clean over nothing -------------------------

@test "errors rather than passing when no tracked shell matches" {
  TMP="$(mktemp -d -t errexit-status-lint-XXXXXX)"
  git -C "$TMP" init -q .
  fixture_file .github/workflows/seed.yml 'jobs:
  seed:
    steps:
      - run: |
          echo seed'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'nothing was scanned' <<<"$output"
}

@test "errors rather than passing when no tracked workflow matches" {
  TMP="$(mktemp -d -t errexit-status-lint-XXXXXX)"
  git -C "$TMP" init -q .
  fixture_file seed.sh 'echo seed'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'nothing was scanned' <<<"$output"
}

# --- the real tree ---------------------------------------------------------

@test "the repository's own scanned surface is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- 'lint-errexit-status-read: clean' <<<"$output"
}
