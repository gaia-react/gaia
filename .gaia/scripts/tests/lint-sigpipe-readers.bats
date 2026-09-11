#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` expansions inside it reach the fixture file as literal text. The
# unexpanded pipeline IS the thing under test, so letting this shell expand one
# would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-sigpipe-readers.sh: the static gate that flags a
# short-circuiting reader standing downstream of a pipe in a file that arms
# `pipefail`, the shape whose pipeline status INVERTS on a match because the
# short-circuiting reader closes the pipe and the upstream dies of SIGPIPE.
#
# THIS SUITE IS THE BLOCKING RUNNER. shell-lint.sh invokes the gate a second,
# advisory way, but a gate run against a tree that is already clean reports
# clean whether its predicate works or not, so a broken predicate is
# indistinguishable from an honest tree there. Every test below drives the gate
# against a fixture tree shaped one way at a time.
#
# Three jobs. Prove the detector fires on the class, in each spelling the gate's
# own header enumerates and across the line breaks a real pipeline uses; prove it stays
# quiet on the legitimate shapes, which for this gate includes the repair it
# advertises, since a gate that reds on its own advice cannot ship; and assert
# the real scanned tree is clean so a regression fails CI.
#
# Two tests are load-bearing beyond coverage. "reds against the historical
# wiki-session-stop shape" carries the exact line gaia-react/gaia#1810 was filed
# against, so the gate is proven to reach the instance it was written for rather
# than a tidied stand-in. And "quiet on the here-string repair" carries the
# shape the gate prints as its fix.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The gate resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-sigpipe-readers.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo_bare: an initialized git repo in $TMP with no files yet and no
# seeded surface. Point a test that needs an empty scan set here.
fixture_repo_bare() {
  TMP="$(mktemp -d -t sigpipe-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_repo: fixture_repo_bare with one benign tracked script and one benign
# tracked workflow, so BOTH discoveries are non-empty and a test reaches class
# detection rather than an empty-surface error. The seed is `seed.sh` rather
# than `check.sh` so fixture_script below can overwrite the latter without
# emptying the surface, and the workflow seed is the same idea one surface over:
# fixture_workflow writes `probe.yml`, so `seed.yml` survives it.
fixture_repo() {
  fixture_repo_bare
  fixture_file seed.sh 'true'
  fixture_file .github/workflows/seed.yml 'jobs:
  j:
    steps:
      - name: seed
        run: |
          true'
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so the body reaches the file
# as the characters the gate is meant to read. Call fixture_repo first.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_script <body>: the common case, a tracked shell script that arms
# pipefail. The `set` line is prepended here rather than repeated in every
# fixture, so a test body is the pipeline under test and nothing else; line 1 is
# the shebang, line 2 the `set`, so a one-line body reports at line 3.
fixture_script() {
  fixture_file check.sh "#!/usr/bin/env bash
set -euo pipefail
$1"
}

# fixture_script_unarmed <body>: the same, with no pipefail anywhere.
fixture_script_unarmed() {
  fixture_file check.sh "#!/usr/bin/env bash
set -eu
$1"
}

# indent <n> <body>: reprint <body> with <n> spaces in front of every line, so a
# test writes a `run:` body at column 0 and the helper places it inside the
# block scalar. Written with awk rather than a `sed` substitution so the
# indentation is data rather than part of a pattern.
indent() {
  printf '%s\n' "$2" | awk -v pad="$( printf "%${1}s" '' )" '{ print pad $0 }'
}

# fixture_workflow <body>: a tracked workflow whose one step carries <body> as
# its `run:` block, under GitHub's DEFAULT shell -- no `shell:` key, which is
# every workflow-file step in this repository. The scaffolding is written here
# rather than repeated in every fixture, so a test body is the block under test
# and nothing else; `jobs:` is line 1 and the first body line is line 6.
fixture_workflow() {
  fixture_file .github/workflows/probe.yml "jobs:
  j:
    steps:
      - name: probe
        run: |
$( indent 10 "$1" )"
}

# fixture_action <shell-value> <body>: a tracked composite action whose one step
# names <shell-value> as its shell. This is the surface whose arming comes from
# the RESOLVED SHELL rather than from the body, and GitHub's schema makes
# `shell:` mandatory for a composite `run:` step. `runs:` is line 1 and the
# first body line is line 7.
fixture_action() {
  fixture_file .github/actions/probe/action.yml "runs:
  using: composite
  steps:
    - name: probe
      shell: $1
      run: |
$( indent 8 "$2" )"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the class fires -------------------------------------------------------

@test "reds against the historical wiki-session-stop shape" {
  fixture_repo
  fixture_script 'if git log "$start_sha..HEAD" --name-only --pretty=format: 2>/dev/null | grep -q '"'"'^wiki/'"'"'; then
  echo changed
fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "short-circuits a pipeline under pipefail" <<<"$output"
}

@test "flags a printf feeding a quiet grep" {
  fixture_repo
  fixture_script 'printf "%s\n" "$labels" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags an echo feeding a quiet grep" {
  fixture_repo
  fixture_script 'echo "$out" | grep -qE needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# Coverage is per element: every cluster spelling this gate claims to reach gets
# its own fixture, because a detector keyed on the bare `-q` token passes a
# one-spelling suite while missing every cluster the tree actually writes.
@test "flags each -q-bearing flag cluster" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep -qF one
printf "%s" "$b" | grep -qxF two
printf "%s" "$c" | grep -qvF three
printf "%s" "$d" | grep -qiE four
printf "%s" "$e" | grep -nq five'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "check.sh:4:" <<<"$output" || return 1
  grep -qF -- "check.sh:5:" <<<"$output" || return 1
  grep -qF -- "check.sh:6:" <<<"$output" || return 1
  grep -qF -- "check.sh:7:" <<<"$output"
}

@test "flags the long-form quiet flags" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep --quiet one
printf "%s" "$b" | grep --silent two'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "check.sh:4:" <<<"$output"
}

# A count-limited reader closes the pipe at the Nth match exactly as a quiet one
# closes it at the first, so the pipeline status inverts identically. The class
# is the short circuit, not the flag spelling.
@test "flags a count-limited reader in each of its spellings" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep -m1 one >/dev/null
printf "%s" "$b" | grep -m 1 two >/dev/null
printf "%s" "$c" | grep --max-count=1 three >/dev/null
printf "%s" "$d" | grep --max-count 1 four >/dev/null'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "check.sh:4:" <<<"$output" || return 1
  grep -qF -- "check.sh:5:" <<<"$output" || return 1
  grep -qF -- "check.sh:6:" <<<"$output"
}

# The wrapper rather than the reader occupies the segment head here, so a
# detector reading the head alone grades the segment as some other command.
@test "flags a reader inside a downstream brace group" {
  fixture_repo
  fixture_script 'some_command | { grep -q needle; }'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags a reader inside a downstream subshell, spaced and fused" {
  fixture_repo
  fixture_script 'some_command | ( grep -q needle )
some_command | (grep -q needle)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "check.sh:4:" <<<"$output"
}

@test "flags rg as well as grep" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | rg -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags a path-qualified reader" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | /usr/bin/grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The assignment prefix is the most common modifier spelling in this tree, and
# without an arm for it the command word reads as the assignment itself, so the
# segment grades as some other command and the gate reports clean.
@test "flags a reader behind a VAR=value assignment prefix" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | LC_ALL=C grep -qE needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags a reader behind an assignment prefix stacked on env" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | env LC_ALL=C grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags a reader negated with !, which still reads the pipeline status" {
  fixture_repo
  fixture_script 'some_command | ! grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "flags the right half of a |& pipe" {
  fixture_repo
  fixture_script 'some_command |& grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The continuation shapes are the reason the scan carries line state at all. A
# per-line detector that only looks for a pipe to the LEFT of the reader on the
# same line misses the trailing-bar form entirely, and the tree writes both.
@test "flags a reader on a continuation line opened by a leading bar" {
  fixture_repo
  fixture_script 'some_command \
    "$arg" \
    | grep -qvF needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:5:" <<<"$output"
}

@test "flags a reader on the line after a trailing bar" {
  fixture_repo
  fixture_script 'some_command |
  grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:4:" <<<"$output"
}

@test "flags a reader whose open pipeline is carried across a comment line" {
  fixture_repo
  fixture_script 'some_command |
  # bash accepts a comment where a newline is accepted
  grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:5:" <<<"$output"
}

# The buffered-until-END property. `pipefail` is routinely armed by a caller
# below, or by a `set` line an author moved, so a scan that decided armedness on
# the way past would report this file clean on the strength of line order alone.
@test "flags a pipeline whose file arms pipefail on a LATER line" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
printf "%s" "$a" | grep -q needle
set -o pipefail'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:2:" <<<"$output"
}

# The flag run before -o is unbounded and optional. A pattern requiring the o to
# sit in the FIRST flag token drops every candidate in a file spelling it this
# way, which is legal, idiomatic, and silent.
@test "the split-flag spelling set -e -o pipefail arms the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set -e -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The long-form option spelling, which a flag-token-only run breaks on: the
# option NAME after a leading -o is not a flag token, so a pattern that admits
# only flag tokens never reaches the -o that carries pipefail, and every
# candidate in the file is dropped. The sibling errexit status-read gate already
# treats this spelling as live for its own armedness.
@test "a long-form option ahead of -o pipefail still arms the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set -o errexit -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

@test "two long-form options ahead of -o pipefail still arm the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The opposite direction, and the reason the option name is admitted only
# DIRECTLY after a flag token rather than anywhere in the run. `set` stops
# parsing options at its first non-option word, so this line sets positional
# parameters and arms nothing; a pattern admitting a bare word anywhere would
# grade the file armed and report a site in a file that never runs armed.
@test "a set line whose words are positional parameters arms nothing" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set alpha beta -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

@test "the bare spelling set -o pipefail arms the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The one-line spelling, which the arming pattern read as arming NOTHING until
# gaia-react/gaia#1941: the `;` sat where the pattern demanded whitespace or
# end-of-line, so a file armed only this way was graded unarmed and every quiet
# reader in it went unreported. Confirmed to report clean against exactly this
# fixture before the trailing boundary admitted the semicolon.
@test "the one-line spelling set -euo pipefail; cmd arms the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set -euo pipefail; umask 022
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The script arm mirror of the workflow arm oracle further down, and what makes
# admitting the `;` above safe rather than a trade. Once the boundary admits it,
# the substitution-scoped occurrence on this line MATCHES, and a locator that
# stopped at the leftmost match would ask the depth test about a position inside
# the substitution and read a genuinely armed file as unarmed. That is the false
# negative gaia-react/gaia#1936 closed on the workflow arm; only walking every
# occurrence keeps this arm out of it.
@test "an arming preceded on its line by a substitution-scoped one still arms the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
x=$(set -o pipefail; true); set -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The other direction, and the reason the script arm needed a depth test of its
# own before the boundary could widen. `changed=$(set -o pipefail; ...)` arms
# its own subshell and nothing outside it, and it is the shape this repository
# writes wherever a `git diff -z` feeds a `tr`. Reading it as file-level arming
# would grade every file carrying the idiom armed and report every quiet reader
# in them. Until gaia-react/gaia#1941 the script arm had no depth test at all
# and was saved only by the boundary that rejected the `;`, and no fixture here
# covered the shape: every substitution fixture in this suite drove the workflow
# arm, which is why the boundary could not widen until this arm grew one.
@test "a substitution-scoped set -o pipefail does not arm the file: tree spelling" {
  fixture_repo
  fixture_script_unarmed 'changed=$(set -o pipefail; git diff --name-only -z | tr "\0" "\n")
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a substitution-scoped set -o pipefail does not arm the file: spaced spelling" {
  fixture_repo
  fixture_script_unarmed 'changed=$(set -o pipefail ; git diff --name-only -z | tr "\0" "\n")
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# The script arm's cross-line carry, and the fixture that fails when it is
# driven to zero. The mirror of the workflow arm's split-across-lines test: a
# substitution opened on one line scopes the arming on the next, so the file
# stays unarmed and the reader below the closing paren is not reported. Most
# positive carries in the tree are exactly this shape, which is why the repair
# for a quoted `$(` lowers the carry rather than dropping it.
@test "a substitution-scoped set -o pipefail does not arm the file: split across lines" {
  fixture_repo
  fixture_script_unarmed 'changed=$(
  set -o pipefail
  git diff --name-only -z | tr "\0" "\n"
)
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# The depth both arms carry is a character count, so a `$( ... )` written as
# DATA rather than as code counts too: a grep pattern, a printf template, a
# message. Balanced, it opens and closes on the same line and the carry returns
# to zero, so a real arming below it still arms and the reader below THAT is
# still reported. What this pins is the same-line `)` decrement; it stays green
# with the cross-line carry removed, so the split-substitution fixture above is
# what pins the carry.
@test "a balanced dollar-paren inside a quoted argument leaves the file armed" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
grep -nF "x=$(cmd)" file.txt
set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:4:" <<<"$output"
}

# Unbalanced, a quoted `$(` never spends its `)` on its own line. Counted raw it
# leaves the carry above zero, the file-level arming below reads as scoped, and
# every reader in the file goes unreported with nothing said. The carry takes
# the lower of the raw count and a count with single-quoted spans removed, and
# the removed span is where the literal sits.
@test "an unbalanced dollar-paren inside a single-quoted argument leaves the file armed" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
grep -nF '"'"'x=$('"'"' file.txt
set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:4:" <<<"$output"
}

# Why the carry is the LOWER of the two counts rather than the stripped count
# alone. A strip cannot tell a quote opening a span from an apostrophe inside a
# double-quoted string, so here it pairs the apostrophe with the first quote of
# the later single-quoted word, deletes the `)` between them, and leaves an
# unbalanced `$(` on a line whose raw count is balanced. A stripped-only carry
# reads the arming below as scoped and reports nothing; this reds if the
# minimum is ever simplified to the strip.
@test "a single-quote strip that would raise the carry does not disarm the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
x=$(echo "it'"'"'s"); y='"'"'z'"'"'
set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:4:" <<<"$output"
}

# The unbalanced literal on the arming's OWN line rather than an earlier one.
# The carry never reaches it, since the carry only feeds the next line, so the
# arming test takes the same minimum at the arming position: a raw read puts
# the set at depth 1, arms nothing, and every reader in the file goes
# unreported.
@test "an unbalanced dollar-paren on the arming line leaves the file armed" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
grep -nF '"'"'x=$('"'"' file.txt; set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# The no-rise property at the arming position. Here the strip pairs the
# apostrophe with the quote opening the later word and leaves the prefix at
# depth 1, while the raw prefix is balanced. The arming test is the raw test OR
# the stripped one, never the stripped one alone, and this reds if it is ever
# simplified to the strip.
@test "a single-quote strip that would raise the depth at the arming does not disarm the file" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
x=$(echo "it'"'"'s"); y='"'"'z'"'"'; set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output"
}

# --- the pipefail closure --------------------------------------------------
#
# pipefail is a process option, so a sourced library runs under whatever its
# caller armed. Grading each file by its own `set` line alone would report every
# library clean, and .claude/hooks/lib/ is where three of the four historical
# occurrences lived.

# The library sits in a SUBDIRECTORY deliberately, and this is the only closure
# fixture that does. An edge resolves through a basename-to-path index, and at
# the fixture repo root the basename and the path are the same string, so every
# root-level fixture agrees under either keying and the index is never
# discriminated. The tree's own libraries live in subdirectories
# (.claude/hooks/lib/), which the gate's header names as the family three of the
# four historical occurrences lived in, so this relocation is what puts the
# index key under test at all: re-key it by path and this test, alone, reds.
@test "flags a nested library with no pipefail of its own that an armed file sources" {
  fixture_repo
  fixture_file lib/probe-lib.sh '#!/usr/bin/env bash
probe() { printf "%s" "$1" | grep -q needle; }'
  fixture_file caller.sh '#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib/probe-lib.sh"
probe "$1"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "lib/probe-lib.sh:2:" <<<"$output"
}

@test "flags a library with no pipefail of its own that an armed file sources" {
  fixture_repo
  fixture_file lib.sh '#!/usr/bin/env bash
probe() { printf "%s" "$1" | grep -q needle; }'
  fixture_file caller.sh '#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"
probe "$1"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "lib.sh:2:" <<<"$output"
}

@test "the closure is transitive through an intermediate library" {
  fixture_repo
  fixture_file inner.sh '#!/usr/bin/env bash
probe() { printf "%s" "$1" | grep -q needle; }'
  fixture_file middle.sh '#!/usr/bin/env bash
. "$(dirname "$0")/inner.sh"'
  fixture_file outer.sh '#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/middle.sh"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "inner.sh:2:" <<<"$output"
}

# The bracketed load is the shape .gaia/scripts/lint-errexit-source-guard.sh
# demands of an errexit-arming file, so it is what an armed caller in this tree
# actually writes. A source reader keyed to line start alone draws no edge from
# it and the library it loads goes ungraded.
@test "an edge is drawn from the bracketed load an errexit-armed caller writes" {
  fixture_repo
  fixture_file lib.sh '#!/usr/bin/env bash
probe() { printf "%s" "$1" | grep -q needle; }'
  fixture_file caller.sh '#!/usr/bin/env bash
set -euo pipefail
d="$(dirname "$0")"
set +e; [ -f "$d/lib.sh" ] && . "$d/lib.sh" 2>/dev/null; set -e'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "lib.sh:2:" <<<"$output"
}

@test "a library sourced only by an UNARMED file stays out of the closure" {
  fixture_repo
  fixture_file lib.sh '#!/usr/bin/env bash
probe() { printf "%s" "$1" | grep -q needle; }'
  fixture_file caller.sh '#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/lib.sh"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "reports every hit in a file, not only the first" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep -q one
printf "%s" "$b" | grep -q two
printf "%s" "$c" | grep -q three'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:3:" <<<"$output" || return 1
  grep -qF -- "check.sh:4:" <<<"$output" || return 1
  grep -qF -- "check.sh:5:" <<<"$output"
}

@test "the report carries the remedy footer" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "removing the pipeline rather than making the race safer" <<<"$output"
}

# --- the class does not fire -----------------------------------------------

# The load-bearing half. This gate advertises a repair, and a detector that read
# `grep -q` plus "somewhere on a line with a bar in it" would red on the very
# line it told the author to write.
@test "quiet on the here-string repair the gate advertises" {
  fixture_repo
  fixture_script 'grep -q needle <<<"$a"
grep -qvF other <<<"${b%$'"'"'\n'"'"'}"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a file that arms no pipefail" {
  fixture_repo
  fixture_script_unarmed 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# `set +o pipefail` DISARMS, so it must not arm. The reverse case, a file that
# arms pipefail and then disarms it before the pipeline, still reads as armed
# and is reported; that direction costs a correct edit rather than a missed
# defect, which is the direction a guard is allowed to be wrong in.
@test "quiet on a file whose only pipefail mention disables it" {
  fixture_repo
  fixture_file check.sh '#!/usr/bin/env bash
set +o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a filtering grep with no quiet flag" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | grep -v -e one -e two'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a reader that is not downstream of anything" {
  fixture_repo
  fixture_script 'grep -q needle "$file"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a reader after a logical OR, which is not a pipe" {
  fixture_repo
  fixture_script 'some_command || grep -q needle "$file"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "quiet on a full-line comment showing the shape" {
  fixture_repo
  fixture_script '# printf "%s" "$a" | grep -q needle is the shape this gate forbids
true'
  run_linter
  [ "$status" -eq 0 ]
}

# The command word decides, so a -q sitting in some other command'"'"'s argument is
# never read as a flag of a reader. Without the head test this line reports a
# hit that names a command the gate has no opinion about.
@test "quiet on a downstream command whose argument merely contains -q" {
  fixture_repo
  fixture_script 'printf "%s" "$a" | awk "/-q/ { print }"'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the scan surface ------------------------------------------------------

@test "an untracked file carrying the class is not scanned" {
  fixture_repo
  printf '%s\n' '#!/usr/bin/env bash
set -o pipefail
printf "%s" "$a" | grep -q needle' > "$TMP/untracked.sh"
  run_linter
  [ "$status" -eq 0 ]
}

# bats-core enables no pipefail, so a suite is not a place the class can fire,
# and every consuming suite writes the shape deliberately as a fixture.
@test "a tracked bats suite carrying the class is not scanned" {
  fixture_repo
  fixture_file probe.bats 'set -o pipefail
printf "%s" "$a" | grep -q needle
@test "t" { true; }'
  run_linter
  [ "$status" -eq 0 ]
}

# `.husky/_/h` runs each hook as `sh -e`, which arms no pipefail either. The
# shared library owns this exclusion, so the assertion is that this gate asks
# for the `shell` set alone rather than for `shell husky`.
@test "a tracked husky hook carrying the class is not scanned" {
  fixture_repo
  fixture_file .husky/pre-commit '#!/usr/bin/env bash
set -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the workflow arm, whose arming is a shell oracle ----------------------
#
# The adversarial half `.claude/rules/guards-must-fail.md` demands of a
# guard-shaped deliverable: this arm is driven into its failing state on each of
# the two independent things that arm a block, and the refusal is driven into
# its own. A suite that only proved the arm stays quiet would be satisfied by an
# arm that never runs.

@test "flags a reader in a run: body armed by the step's shell: bash" {
  fixture_repo
  fixture_action bash 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/actions/probe/action.yml:7:" <<<"$output" || return 1
  grep -qF -- "short-circuits a pipeline under pipefail" <<<"$output"
}

# The other half of the same oracle, and independent of it: a body that arms
# pipefail itself is armed whatever its shell resolves to. This fixture carries
# no `shell:` at all, so the resolved shell is the bare default that arms
# nothing, and only the body text can red it.
@test "flags a reader in a run: body armed by its own set -o pipefail" {
  fixture_repo
  fixture_workflow 'set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:7:" <<<"$output"
}

# The body-text arm carried the same boundary gap as the script arm, because
# both read the one shared pattern: a block armed only by the one-line spelling
# was graded unarmed. Both arms are driven into it here rather than one, since a
# gap in one pattern cannot be closed in one arm.
@test "flags a reader in a run: body armed by a one-line set -euo pipefail; cmd" {
  fixture_repo
  fixture_workflow 'set -euo pipefail; umask 022
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:7:" <<<"$output"
}

# The adopter workflow templates render into somebody else's CI, so they are the
# one surface whose defects this repository's review is the last place able to
# see. `.tmpl` matches no `*.yml` glob, hence its own pathspec in the set.
@test "flags a reader in an adopter workflow template" {
  fixture_repo
  fixture_file .gaia/cli/src/automation/templates/workflows/probe.yml.tmpl 'jobs:
  j:
    steps:
      - name: probe
        run: |
          set -euo pipefail
          printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "templates/workflows/probe.yml.tmpl:7:" <<<"$output"
}

# The INLINE `run:` spelling, which is its own one-line block. Grading only the
# block-scalar form left this unscanned at every arming, and the composite
# actions are where it bites: the Actions schema makes `shell:` mandatory there,
# so `shell: bash` arms a reader on the key's own line exactly as it arms one in
# a block. Both directions are pinned, so the boundary cannot drift back to
# silence.
@test "flags a reader in an inline run: value armed by the step's shell" {
  fixture_repo
  fixture_file .github/actions/probe/action.yml 'runs:
  using: composite
  steps:
    - name: probe
      shell: bash
      run: printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/actions/probe/action.yml:6:" <<<"$output" || return 1
  grep -qF -- "short-circuits a pipeline under pipefail" <<<"$output"
}

@test "quiet on an inline run: value under the default shell" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  j:
    steps:
      - name: probe
        run: printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# A block may arm pipefail on a line BELOW its pipeline, exactly as a file may,
# so a block is graded when it ENDS rather than where its `set` sits.
@test "flags a pipeline whose block arms pipefail on a LATER line" {
  fixture_repo
  fixture_workflow 'printf "%s" "$a" | grep -q needle
set -euo pipefail'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:6:" <<<"$output"
}

# The default case, and the reason the body-text test alone cannot grade this
# surface: every workflow-file step in this repository resolves to `bash -e`,
# which arms no pipefail, so the shape here is not an instance.
@test "quiet on a run: body under the default shell, which arms no pipefail" {
  fixture_repo
  fixture_workflow 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# A shell that is neither bash nor a custom invocation naming pipefail arms
# nothing, so an explicit `shell:` is not by itself an arming signal.
@test "quiet on a step whose explicit shell is not a pipefail-arming one" {
  fixture_repo
  fixture_action sh 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# A custom invocation that names pipefail arms the block even though the value
# is not the bare word `bash`.
@test "flags a step whose custom shell invocation names pipefail" {
  fixture_repo
  fixture_action 'bash -eo pipefail {0}' 'printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/actions/probe/action.yml:7:" <<<"$output"
}

# THE DISCRIMINATION THIS TREE'S CURRENT STATE TURNS ON. A substitution-scoped
# `set -o pipefail` arms the subshell and not the block around it, and it is the
# shape this repository writes wherever a `git diff -z` feeds a `tr`. Reading it
# as block-level arming would report every one of those blocks.
#
# The spellings below are stopped by the SAME mechanism, the depth test, and
# each still earns its own fixture because each reaches it differently: the
# tree's own `$(set -o pipefail; ...)` through the semicolon the trailing
# boundary admits, the spaced form through the whitespace it always admitted,
# and the split form across a line break with the depth carried between lines.
# The tree spelling reached no test at all until gaia-react/gaia#1941: the
# boundary rejected the `;` outright, which excluded this shape by accident
# while missing the one-line arming above by the same accident.
@test "a substitution-scoped set -o pipefail does not arm the block: tree spelling" {
  fixture_repo
  fixture_workflow 'set -eu
changed=$(set -o pipefail; git diff --name-only -z | tr "\0" "\n")
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a substitution-scoped set -o pipefail does not arm the block: spaced spelling" {
  fixture_repo
  fixture_workflow 'set -eu
changed=$(set -o pipefail ; git diff --name-only -z | tr "\0" "\n")
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a substitution-scoped set -o pipefail does not arm the block: split across lines" {
  fixture_repo
  fixture_workflow 'set -eu
changed=$(
  set -o pipefail
  git diff --name-only -z | tr "\0" "\n"
)
printf "%s" "$changed" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# The workflow arm carries its depth across a block the same way the script arm
# carries it across a file, through the same carry, so the script arm's
# unbalanced-literal and strip-raise fixtures are mirrored here: a repair
# reaching one arm and not the other reopens the asymmetry the shared carry
# exists to prevent. The balanced fixture is not mirrored, because what it pins
# is the same-line `)` decrement in depth_at, which both arms share.
@test "an unbalanced dollar-paren inside a single-quoted argument leaves the block armed" {
  fixture_repo
  fixture_workflow 'grep -nF '"'"'x=$('"'"' file.txt
set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:8:" <<<"$output"
}

@test "a single-quote strip that would raise the carry does not disarm the block" {
  fixture_repo
  fixture_workflow 'x=$(echo "it'"'"'s"); y='"'"'z'"'"'
set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:8:" <<<"$output"
}

@test "an unbalanced dollar-paren on the arming line leaves the block armed" {
  fixture_repo
  fixture_workflow 'grep -nF '"'"'x=$('"'"' file.txt; set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:7:" <<<"$output"
}

@test "a single-quote strip that would raise the depth at the arming does not disarm the block" {
  fixture_repo
  fixture_workflow 'x=$(echo "it'"'"'s"); y='"'"'z'"'"'; set -euo pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:7:" <<<"$output"
}

# The mirror image of the substitution-scoped tests above, and the reason the
# arming pattern is bound once rather than written twice AND is walked past a
# substitution-scoped match rather than stopped at it. Here a genuine
# block-level arming
# follows a substitution-scoped one on the SAME line. A locator that answers
# with the leftmost match asks the depth test about a position inside the
# substitution and reads the block as unarmed: a false negative, the direction
# this gate must not be wrong in. Confirmed to report clean against exactly this
# shape before the two readers were given one pattern, and again against the
# widened boundary before the locator walked every occurrence: until
# gaia-react/gaia#1941 what kept the leftmost match off this line was the
# boundary rejecting its `;`, so the two are only independent now.
@test "an arming preceded on its line by a substitution-scoped one still arms the block" {
  fixture_repo
  fixture_workflow 'x=$(set -o pipefail; true); set -o pipefail
printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/probe.yml:7:" <<<"$output"
}

# A block ends at the dedent, so one block's arming must not reach the next
# step. Without that boundary the armed block here would red the unarmed one
# below it, which is the whole surface graded by whichever step armed first.
@test "a block's arming does not leak into the next step" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  j:
    steps:
      - name: armed
        run: |
          set -euo pipefail
          echo hi
      - name: unarmed
        run: |
          printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# .github/workflows/shell-lint.yml carries two lines spelled exactly `shell:`
# that name a dorny/paths-filter output inside a `filters: |` block scalar. Read
# as step keys they would arm blocks that resolve to the bare default.
@test "a shell: naming a paths-filter output is not read as a step shell" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'jobs:
  j:
    steps:
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            shell: bash
              - "**/*.sh"
      - name: probe
        run: |
          printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 0 ]
}

# --- the defaults: refusal --------------------------------------------------

@test "a defaults: key is refused rather than resolved" {
  fixture_repo
  fixture_file .github/workflows/probe.yml 'defaults:
  run:
    shell: bash
jobs:
  j:
    steps:
      - name: probe
        run: |
          printf "%s" "$a" | grep -q needle'
  run_linter
  [ "$status" -eq 4 ]
  grep -qF -- ".github/workflows/probe.yml:1" <<<"$output" || return 1
  # Names the issue that tracks the precedence chain, not merely the word
  # `defaults`, so the operator handed this has somewhere to go.
  grep -qF -- "gaia-react/gaia#1814" <<<"$output" || return 1
  # The refusal replaces the verdict rather than riding alongside one: a status
  # 4 that still printed `clean` would read as a graded tree. Written as a
  # positive match for the bad case ending in `return 1`, per
  # .claude/rules/bats-assertions.md: a `!`-negated absence check is exempted
  # from `set -e` and would green here whatever the output said.
  grep -qF -- "lint-sigpipe-readers: clean" <<<"$output" && return 1
  true
}

# The refusal reads YAML STRUCTURE, not the word. A `run:` body is shell text,
# and a line inside one that happens to spell `defaults:` is not a workflow
# default; refusing on it would take the gate down over a string in a script.
@test "a defaults: inside a run: body is not read as a workflow default" {
  fixture_repo
  fixture_workflow 'set -euo pipefail
cat <<YAML
defaults:
  run:
    shell: bash
YAML'
  run_linter
  [ "$status" -eq 0 ]
}

# --- discovery is armed, not merely correct --------------------------------

@test "an empty scan set is a hard error, never a clean tree" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output" || return 1
  # Names the set this gate asked for, not the phrase every empty-surface
  # message carries, so the assertion cannot be satisfied by some other
  # discovery reporting clean over nothing.
  grep -qF -- "the scan surface (shell)" <<<"$output"
}

# The workflow set gets its own emptiness check rather than riding the union
# with `shell`, and this is the test that holds the two calls apart. Under a
# single union call a tracked `*.sh` would carry an empty YAML surface past the
# check, and the arm above would report clean having opened no workflow at all,
# which is the fail-open discovery `.claude/rules/guards-must-fail.md` names.
@test "an empty workflow surface is a hard error, never a clean tree" {
  fixture_repo_bare
  fixture_file seed.sh 'true'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output" || return 1
  grep -qF -- "the scan surface (workflows)" <<<"$output"
}

# The `|| exit $?` on the discovery call is the whole mechanism here. `|| exit 1`
# folds a discovery that never ran into the status this gate uses for a tree it
# read and found nothing in, and an operator handed that would go looking at the
# tree. Run outside any repository, so `git ls-files` fails rather than answering
# empty; that is the one discovery failure a fixture can produce without a stub.
@test "a discovery that never ran exits distinctly from a surface that came back empty" {
  TMP="$(mktemp -d -t sigpipe-lint-XXXXXX)"
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- "discovery failed" <<<"$output" || return 1
  grep -qF -- "nothing was scanned" <<<"$output"
}

# The gate resolves the shared library beside itself, so a copy standing alone
# has no discovery at all. It must say so rather than scan nothing quietly.
@test "a gate whose shared library is missing exits 2 rather than reporting clean" {
  fixture_repo
  cp "$LINTER" "$TMP/lone-gate.sh"
  run bash -c "cd '$TMP' && bash '$TMP/lone-gate.sh' 2>&1"
  [ "$status" -eq 2 ]
  grep -qF -- "guard-awk-lib.sh is missing beside this script" <<<"$output"
}

# --- the real tree ---------------------------------------------------------

@test "the real scanned tree passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
