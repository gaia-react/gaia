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

# The env prefix survives every prefix word the shell accepts before the command
# word. These six were held for four review rounds as KNOWN FALSE POSITIVES: the
# exclusion inspected a single token, stopped at the first redirection or second
# assignment, and reported a line the shell runs. The consumption loop
# (gaia-react/gaia#1486) reaches the command word behind the whole prefix, so
# each of them is now the quiet verdict the shell justifies, and each is asserted
# against a real shell as a row of the prefix matrix at the end of this file too.
#
# They stay written out here as well as in the matrix on purpose: the matrix
# fails as one test naming a row, while a named test says which shape broke
# without reading a matrix diff.

@test "a redirection before the command word does not hide the env prefix" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) > log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the same with an explicit file descriptor" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2> log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the same behind a descriptor duplicate" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) 2>&1 run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a >& redirection is consumed whole, so its & is not read as an operator" {
  fixture_repo
  # `>&` has to be consumed by the operator pattern in one piece. Matched as a
  # bare `>`, the leftover `&` reads as a control operator and terminates the
  # prefix walk one token early, which is the single-token failure in a new
  # spelling.
  fixture_script 'set -e
out=$(some_command) >& log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an &> redirection reaches the loop rather than being read as an operator" {
  fixture_repo
  # `&>` needs its own alternative in the operator pattern: its leading `&`
  # matches no part of `[0-9]*[<>]`, so without one it never enters the loop at
  # all and falls through to the statement-separator test.
  fixture_script 'set -e
out=$(some_command) &> log run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a further assignment before the command word is consumed, not stopped at" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) FOO=1 run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

# The two mechanisms the prefix consumption loop does not supply on its own: the
# redirection operand that is a nested command rather than a word, and the
# knowledge of WHICH substitution ran last. Both are now the quiet verdict the
# shell justifies, and both are asserted against a real shell in the prefix
# matrix at the end of this file as well, for the reason the six above are: the
# matrix fails as one test naming a row, a named test says which shape broke.

@test "a process substitution operand is followed rather than broken on" {
  fixture_repo
  # The operand is a nested command rather than a word. Broken on at its `(` the
  # leftover paren reads as a statement separator and `run_thing` behind it is
  # never reached, so the line is reported although the shell runs it and takes
  # `run_thing`'s status.
  fixture_script 'set -e
out=$(some_command) > >(cat >/dev/null) run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the same for an input process substitution" {
  fixture_repo
  fixture_script 'set -e
out=$(some_command) < <(echo x) run_thing
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a later substitution in the same assignment list takes the status" {
  fixture_repo
  # A statement that is only assignments takes the status of the LAST
  # substitution it ran, so `out=$(false) FOO=$(true)` survives while
  # `out=$(false) BAR=1` exits. What the `$?` below reads is the second
  # substitution's status, never the flagged assignment's.
  fixture_script 'set -e
out=$(some_command) FOO=$(other_command)
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a later substitution in a REDIRECTION OPERAND takes the status too" {
  fixture_repo
  # The same last-substitution-wins behaviour reached by a different route, and
  # the spelling the narrower "in the same assignment list" reading missed. The
  # unquoted and concatenated operand spellings behave identically.
  fixture_script 'set -e
out=$(some_command) > "$(other_command)"
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a SINGLE-QUOTED substitution in an operand runs nothing, so it still reports" {
  fixture_repo
  # The negative control for the two above: single quotes make the operand a
  # literal filename, no second substitution runs, and the flagged assignment's
  # own status is what the shell takes. Confirmed against the shell, which exits
  # here on both bash 3.2 and bash 5.
  fixture_script 'set -e
out=$(some_command) > '"'"'$(other_command)'"'"'
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
}

@test "an input redirection with no command word is reported on both bash readings" {
  fixture_repo
  # The one shape here whose ground truth is version-dependent, so it is a
  # documented modelling decision rather than a bound. bash 3.2 takes the
  # substitution status and exits, so the read is unreachable. bash 5 resets the
  # status to zero and carries on, so the read is reachable and ALWAYS READS
  # ZERO while `out` is empty and the command failed. Both readings are the
  # defect this gate exists to catch, approached from opposite sides, and the
  # repair it prints (`rc=0; out="$(cmd)" || rc=$?`) is correct for both, so the
  # gate reports on either. The output direction exits on both versions and is
  # covered above. Deliberately absent from the prefix matrix, which measures one
  # interpreter and would record whichever it ran as the whole truth.
  fixture_script 'set -e
out=$(some_command) < log
rc=$?
echo "$rc"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- 'check.sh:3:' <<<"$output"
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

# --- the prefix matrix, differential against a real shell -------------------
#
# Four defects landed on the env-prefix exclusion across four review rounds,
# each one a shape the previous enumeration had not reached, and the fourth
# widening was a silent fail-open. Enumerating a fifth shape by hand is the move
# that produced them, so this asserts AGREEMENT WITH THE SHELL rather than a
# remembered list: every row below is run under a real bash to see whether the
# line after the assignment is reached, and the gate's verdict has to match what
# the shell did. The ground truth is measured on every run, so a row nobody
# reasoned about correctly still fails here, and a new shape costs one line.

# probe_shell: the interpreter the ground truth is measured with, echoed on
# stdout; non-zero when none is available.
#
# Bash 4 or newer is required rather than whatever `bash` resolves to. Some rows
# use operators bash 3.2 cannot PARSE at all (`&>>` is bash 4.0+), and a shell
# that cannot parse a row measures nothing about it. Resolution mirrors
# .gaia/scripts/bats5.sh, which the project's bats rule already routes these
# suites through.
probe_shell() {
  local cand major
  for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$( command -v bash )"; do
    [ -n "$cand" ] || continue
    [ -x "$cand" ] || continue
    major="$( "$cand" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null )"
    case "$major" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$major" -ge 4 ] || continue
    printf '%s' "$cand"
    return 0
  done
  return 1
}

# prefix_reaches <shell> <suffix>: the ground truth, as three outcomes rather
# than two.
#
#   0  a real shell runs past the assignment: the prefixed command's status is
#      the one it takes, the `$?` read below is live, and the gate must stay
#      quiet.
#   1  errexit kills the script on the assignment: the class, and the gate must
#      report.
#   2  the shell could not PARSE the row, so nothing about it was measured.
#
# The third outcome is what keeps the matrix from certifying itself. Folding an
# unparseable row into `report` makes a syntax error indistinguishable from
# errexit firing, so a row edited into nonsense reads as measured ground truth
# and greens against a gate that is also reporting, having established nothing.
# That is the same fail-open the gate under test refuses to commit when it loses
# tokenizer sync, and the matrix owes the same answer.
#
# `log` and `my log` are pre-created so a `<` redirection fails on nothing but
# the shape under test.
#
# A PROCESS SUBSTITUTION row picks its operand carefully: the row is EXECUTED
# here, so `<(cat)` would leave cat reading the stdin this probe inherits and the
# whole suite blocks forever. That is the same stdin-inheritance trap the fd-9
# read below exists for, reached from the other end. Every such row names a
# command that terminates on its own: `<(echo x)` writes and exits, and
# `>(cat >/dev/null)` reads the pipe to EOF.
#
# Two shapes the gate handles are deliberately absent from this matrix rather
# than forgotten, both because a measured row would record something untrue.
# `out=$(false) FOO=$(false)` has no static answer at all, since it is the same
# shape as the `FOO=$(true)` row and differs only in a runtime status. `< log`
# with no command word has no version-stable one, since bash 3.2 exits and bash 5
# carries on, so a row measured under whichever interpreter this probe resolved
# would pin that interpreter's answer as the gate's contract. Both are pinned by
# named tests above instead, and the script header carries the reasoning.
prefix_reaches() {
  local sh="$1" suffix="$2" dir out
  dir="$(mktemp -d -t errexit-status-probe-XXXXXX)"
  : > "$dir/log"
  : > "$dir/my log"
  printf '%s\n' 'set -e' "out=\$(false) $suffix" 'rc=$?' 'echo REACHED' > "$dir/probe.sh"
  if ! "$sh" -n "$dir/probe.sh" 2>/dev/null; then
    rm -rf "$dir"
    return 2
  fi
  out="$( cd "$dir" && "$sh" probe.sh 2>/dev/null || true )"
  rm -rf "$dir"
  case "$out" in *REACHED*) return 0 ;; *) return 1 ;; esac
}

# prefix_verdict <suffix>: set PREFIX_VERDICT to the gate's verdict on the same
# body. `error` rather than `report` when the gate exits non-zero without the
# location pin, so a desync is told apart from a verdict.
prefix_verdict() {
  PREFIX_VERDICT=""
  fixture_repo
  fixture_script "set -e
out=\$(false) $1
rc=\$?
echo \"\$rc\""
  run_linter
  rm -rf "$TMP"
  TMP=""
  if [ "$status" -eq 0 ]; then
    PREFIX_VERDICT=quiet
  elif grep -qF -- 'check.sh:3:' <<<"$output"; then
    PREFIX_VERDICT=report
  else
    PREFIX_VERDICT=error
  fi
}

@test "the gate agrees with a real shell across the prefix matrix" {
  local suffix expected sh rc failures=""
  # Refuse to report clean over nothing, the same posture the gate itself takes
  # on a region it cannot read: with no bash 4+ to measure against, this test has
  # no ground truth and says so rather than passing.
  sh="$( probe_shell )" || {
    printf 'no bash 4+ available to measure ground truth; the matrix measured nothing\n'
    return 1
  }
  # Read on fd 9: the gate is run through bats `run`, which inherits stdin, and
  # a matrix on stdin would be eaten a row at a time by whatever the fixture
  # runs.
  while IFS= read -r suffix <&9; do
    # The guarded form this gate itself advertises: bats runs a test body under
    # errexit, so a bare call returning non-zero would abort the loop on the
    # first `report` row rather than recording it.
    rc=0
    prefix_reaches "$sh" "$suffix" || rc=$?
    case "$rc" in
      0) expected=quiet ;;
      1) expected=report ;;
      *) failures="$failures
  out=\$(false) $suffix    UNPARSEABLE under $sh, so nothing was measured"
         continue ;;
    esac
    prefix_verdict "$suffix"
    [ "$expected" = "$PREFIX_VERDICT" ] || failures="$failures
  out=\$(false) $suffix    shell: $expected    gate: $PREFIX_VERDICT"
  done 9<<'MATRIX'
> log true
>> log true
2> log true
2>&1 true
>& log true
&> log true
&>> log true
< log true
FOO=1 true
FOO=1 BAR=2 true
FOO=1 > log true
> log FOO=1 true
> "my log" true
> log#x true
> 'my log' true
FOO="a b" true
>| log true
>| log
FOO=$(true) true
true
> log
2>&1
FOO=1
> "my log"
&> log
>& log
> >(cat >/dev/null) true
< <(echo x) true
> >(cat >/dev/null)
FOO=$(true)
> "$(echo ab)"
> $(echo ab)
> log$(echo x)
> '$(echo ab)'
MATRIX
  [ -z "$failures" ] || {
    printf 'prefix matrix disagreements:%s\n' "$failures"
    return 1
  }
}

# --- the real tree ---------------------------------------------------------

@test "the repository's own scanned surface is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- 'lint-errexit-status-read: clean' <<<"$output"
}
