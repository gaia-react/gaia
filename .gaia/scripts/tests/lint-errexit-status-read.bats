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
  # The `$?` sits on the FIRST line past the dedent, with nothing between it and
  # the assignment. An intervening key would consume the pending assignment as an
  # ordinary statement and leave the test green even with the dedent check
  # broken, which is the shape that made this test hollow.
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out=$(gh pr view 1)
        RC: $?'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- 'probe.yml' <<<"$output" && return 1
  true
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
  # The shape reaches disk UNESCAPED and outside any heredoc, so this fixture is
  # quiet only because *.bats is off the scan surface. Written with `\$` it would
  # be quiet either way (walk consumes the escape), and written inside a heredoc
  # the swallow would hide it, so both spellings test nothing.
  fixture_file suite.bats 'setup() {
  set -e
  out=$(some_command)
  rc=$?
}'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the same bytes in a tracked .sh are flagged, so the exclusion is what quiets them" {
  fixture_repo
  fixture_script 'setup() {
  set -e
  out=$(some_command)
  rc=$?
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
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
a lone apostrophe that must not leak into the walk: it'"'"'s here
EOF
)"
out=$(some_command)
rc=$?
echo "$PATHS $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:7:' <<<"$output"
}

@test "quiet on a heredoc body carrying the shape as a fixture" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/fixture.sh <<EOF
set -e
out=$(some_command)
rc=$?
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
this body carries an apostrophe: it'"'"'s the byte that desyncs
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

# --- the husky surface arms like the run: bodies, not like a script ---------

@test "arms a husky hook with no set -e, because husky runs it under sh -e" {
  fixture_repo
  fixture_file .husky/pre-commit 'out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '.husky/pre-commit:2:' <<<"$output"
}

@test "a set +e in a husky hook still disarms from that point" {
  fixture_repo
  fixture_file .husky/pre-commit 'set +e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a .sh under .husky is scanned once, not once per overlapping pathspec" {
  fixture_repo
  fixture_file .husky/helper.sh 'set -e
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  # A git pathspec glob crosses `/`, so this file matches BOTH the `*.sh` set and
  # the `.husky/*` set. Armed by its own `set -e` it would be hit in each pass
  # and reported twice, which reads as two defects on one line.
  [ "$(grep -cF -- '.husky/helper.sh:3:' <<<"$output")" -eq 1 ]
}

@test "an ordinary tracked script is still off by default" {
  fixture_repo
  fixture_script 'out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

# --- assignment shapes ------------------------------------------------------

@test "flags an appending assignment, which takes the substitution status too" {
  fixture_repo
  fixture_script 'set -e
out=seed
out+=$(some_command)
rc=$?
echo "$out $rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

@test "quiet on an env-prefix assignment, whose status belongs to the command" {
  fixture_repo
  fixture_script 'set -e
FOO=$(some_command) run_thing --flag
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an env-prefix pair with no command is still a bare assignment" {
  fixture_repo
  fixture_script 'set -e
FOO=$(some_command) BAR=1
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a redirection after the value does not read as an env prefix" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) > log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a redirection carrying an explicit file descriptor is still a redirection" {
  fixture_repo
  # `2>` is the shape that exempted itself: the leading digit read as the first
  # letter of a command word, so the identical statement was reported with `>`
  # and silently passed with `2>`.
  fixture_script 'set -e
out=$(some_command) 2> log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a descriptor-duplicating redirection is not a control operator" {
  fixture_repo
  # The `&` in `2>&1` is file-descriptor syntax on the same simple command, not
  # an AND-OR or a background operator, so the assignment still stands alone.
  fixture_script 'set -e
out=$(some_command) 2>&1
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "an all-streams redirection is not a control operator either" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) &>log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

# These three pin a KNOWN FALSE POSITIVE rather than correct behaviour. The
# env-prefix exclusion reads one token, so it stops at a redirection and never
# reaches the command word behind it; the shell runs these lines and takes the
# prefixed command's status, so the report is wrong. They are held as tests
# because a bound nothing enforces drifts: the structural repair (one quote-aware
# loop consuming every prefix word, gaia-react/gaia#1486) will red all three,
# which is the signal to move them into the quiet column deliberately rather than
# by accident.
#
# The consumption loop that would have fixed them was reverted: its operand
# matcher was whitespace-delimited, so a quoted operand silently exempted a real
# defect, which is a worse direction than the false positives below.

@test "bound: a redirection before the command word hides the env prefix" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) > log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "bound: the same with an explicit file descriptor" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2> log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
}

@test "bound: the same behind a descriptor duplicate" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2>&1 run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
}

@test "a redirection whose operand is quoted is still reported" {
  fixture_repo
  # The regression the reverted loop introduced: its operand matcher stopped at
  # whitespace, so `> "my log"` left `log"` behind, which read as a command word
  # and certified a genuine defect clean. Confirmed against the shell:
  # `set -e; out=$(false) > "/tmp/my log"` exits.
  fixture_script 'set -e
out=$(some_command) > "my log"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a redirection with no command behind it is still a bare assignment" {
  fixture_repo
  # The other direction of the same consumption: an empty tail means the
  # statement was the assignment plus its redirections and nothing else.
  fixture_script 'set -e
out=$(some_command) > log 2> err
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a genuine background & still exempts the statement" {
  fixture_repo
  # The discrimination above must not swallow the real control operator: a
  # backgrounded assignment does not kill the shell on failure.
  fixture_script 'set -e
out=$(some_command) &
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a trailing comment that merely mentions the status variable" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
some_cmd   # returns $? to the caller
echo done'
  run_linter
  [ "$status" -eq 0 ]
}

@test "still flags a real read on a line that also carries a comment" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command)
rc=$?   # capture before anything else runs
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "a desync report does not print the status-read repair, which is not its fix" {
  fixture_repo
  fixture_script 'set -euo pipefail
cat > /tmp/f.txt <<NEVERCLOSED
one'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'letting the assignment hand its status on' <<<"$output" && return 1
  true
}

# --- arms and branches with no other fixture --------------------------------

@test "quiet after the long-form set +o errexit disarm" {
  fixture_repo
  fixture_script 'set -o errexit
set +o errexit
out=$(some_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an env-prefix indented inside a function is still not the class" {
  fixture_repo
  fixture_script 'set -e
f() {
  FOO=$(some_command) run_thing --flag
  rc=$?
  echo "$rc"
}'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an indented BARE assignment is still flagged, so the exclusion is not blanket" {
  fixture_repo
  fixture_script 'set -e
f() {
  out=$(some_command)
  rc=$?
  echo "$rc"
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:4:' <<<"$output"
}

@test "an env-prefix inside a run: body is not the class either" {
  fixture_repo
  # The YAML half is the surface armed by DEFAULT and every line of a block
  # scalar is indented, so this is where an exclusion keyed on the wrong
  # whitespace goes silently inert.
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          FOO=$(gh pr view 1) run_thing --flag
          rc=$?
          echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a run: body that cannot be tokenized to its end is reported, not certified" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out="$(gh pr view 1
      - name: next
        run: echo done'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'a run: body' <<<"$output"
}

@test "the last run: body in a file is checked for desync too" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  probe:
    steps:
      - run: |
          out="$(gh pr view 1'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'lost track of shell state' <<<"$output"
  grep -qF -- 'the last run: body' <<<"$output"
}

@test "a double-quoted string closes, so a later trap capture is still deferred" {
  fixture_repo
  # Test 20 covers the trap alone. If has_status_read never leaves double-quote
  # state, everything after the first `"` on the line reads as quoted, the trap
  # body stops being recognised as single-quoted, and this reports.
  fixture_script 'set -euo pipefail
TMP=$(mktemp -d)
echo "working in $TMP"; trap '"'"'rc=$?; rm -rf "$TMP"'"'"' EXIT
echo done'
  run_linter
  [ "$status" -eq 0 ]
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
