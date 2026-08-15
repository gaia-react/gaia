#!/usr/bin/env bats
# SC2016 is intentional file-wide: every fixture body is single-quoted precisely
# so the `$` anchors and the backslash escapes reach the fixture file as literal
# text. The unexpanded escape IS the thing under test, so letting the shell
# expand one would delete the evidence.
# shellcheck disable=SC2016
#
# Tests for .gaia/scripts/lint-grep-ere-escapes.sh: the static gate that flags a
# backslash-escaped letter inside an extended-regex grep pattern, where BSD grep
# and GNU grep resolve POSIX's undefined behaviour differently and the same
# pattern therefore means two things depending on which machine runs it.
#
# Three jobs. Prove the detector fires on the class; prove it stays quiet on
# every legitimate shape, which for this gate is the load-bearing half, because
# the allowlisted escapes and the repairs the gate's own hint text advertises are
# all things a naive detector reds on; and assert the real scanned tree is clean
# so a regression fails CI.
#
# One test is load-bearing beyond coverage. A gate written for a class must red
# against that class's historical form, or it asserts nothing about the class it
# was written for: "reds against the CRLF-tolerant pattern shape" carries the
# `\r?` spelling that inverted between macOS and CI, so it proves the detector
# reaches the shape that actually shipped rather than a tidied stand-in.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-grep-ere-escapes.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo: an initialized git repo in $TMP with no files yet.
fixture_repo() {
  TMP="$(mktemp -d -t grep-ere-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_file <relpath> <body>: write <body> verbatim to $TMP/<relpath> and
# track it. `printf %s` never interprets an escape, so a `\t` in <body> reaches
# the file as the two characters the gate is meant to read. Call fixture_repo
# first.
fixture_file() {
  local dest="$TMP/$1"
  mkdir -p "$( dirname "$dest" )"
  printf '%s\n' "$2" > "$dest"
  git -C "$TMP" add -A
}

# fixture_script <body>: the common case, a tracked shell script.
fixture_script() {
  fixture_file check.sh "$1"
}

# run_linter: run the gate from inside the fixture repo.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
}

# --- the class fires -------------------------------------------------------

@test "reds against the CRLF-tolerant pattern shape" {
  fixture_repo
  fixture_script 'if printf "%s\n" "$line" | grep -qE "^key:\r?$"; then
  echo found
fi'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
  grep -qF -- '\r in an extended-regex grep pattern' <<<"$output"
}

@test "flags a tab escape" {
  fixture_repo
  fixture_script "grep -E 'name\tvalue' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

@test "flags a digit-class escape" {
  fixture_repo
  fixture_script "grep -qE '^v\d+$' <<<\"\$version\""
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\d in an extended-regex grep pattern' <<<"$output"
}

@test "flags a letter both implementations happen to treat as a literal" {
  fixture_repo
  fixture_script "grep -E 'a\qb' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\q in an extended-regex grep pattern' <<<"$output"
}

@test "flags egrep, which is extended-regex with no option to say so" {
  fixture_repo
  fixture_script "egrep 'a\tb' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# grep options are idiomatically bundled and freely ordered, so the mode is read
# out of the option region rather than matched at a fixed position. Each of
# these spellings sent the call down the not-extended arm before the region walk
# existed, which is a fail-open on the gate's own class.
@test "finds extended mode in any option bundle or order" {
  fixture_repo
  fixture_script "grep -Eq 'a\tb' one.txt
grep -qE 'c\td' two.txt
grep -rEn 'e\tf' three/
grep --extended-regexp 'g\th' four.txt
grep -E -e 'i\tj' five.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "check.sh:1:" <<<"$output"
  grep -qF -- "check.sh:2:" <<<"$output"
  grep -qF -- "check.sh:3:" <<<"$output"
  grep -qF -- "check.sh:4:" <<<"$output"
  grep -qF -- "check.sh:5:" <<<"$output"
}

@test "flags a path-invoked grep" {
  fixture_repo
  fixture_script "/usr/bin/grep -E 'a\tb' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# --- the legitimate shapes stay quiet --------------------------------------

# The gate's own hint text advertises these three repairs. A detector that reds
# on the fix is worse than no detector, because the only way past it is to
# bypass it.
@test "greens on the bracket-expression repair" {
  fixture_repo
  fixture_script "grep -qE '^key:[[:space:]]*\$' input.txt
grep -qE '^v[[:digit:]]+\$' input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# Both spellings hand grep a real control character produced by the SHELL, so
# the pattern never carries the ambiguity. The command-substitution form is the
# one that works in POSIX sh, where `$'...'` is not available.
@test "greens on the shell-produced control character repairs" {
  fixture_repo
  fixture_script "grep -qE \$'^key:\\r?\$' input.txt
grep -qE \"^key:\$(printf '\\r')?\$\" input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# The legacy spelling of the substitution repair above. It is reachable in the
# workflow `run:` bodies and the *.tmpl templates this gate scans, neither of
# which shellcheck reads, so nothing else in the pipeline discourages a backtick
# there.
@test "greens on the legacy backtick spelling of the substitution repair" {
  fixture_repo
  fixture_script 'grep -qE "^key:`printf '"'"'\r'"'"'`?$" input.txt'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "greens on the tr normalization repair" {
  fixture_repo
  fixture_script "tr -d '\r' < input.txt | grep -qE '^key:\$'"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# Six escapes BSD grep and GNU grep both implement with the same meaning. Around
# ten call sites in the real tree use them; flagging them would cost a flood of
# edits with no defect behind any of them.
@test "greens on the six escapes both implementations agree on" {
  fixture_repo
  fixture_script "grep -qE '\b(ghp|gho)_[A-Za-z0-9]{20,}' <<<\"\$content\"
grep -qE 'a\sb' input.txt
grep -qE 'a\wb' input.txt
grep -qE 'a\Sb' input.txt
grep -qE 'a\Wb' input.txt
grep -qE 'a\Bb' input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "greens on POSIX escapes of a non-letter" {
  fixture_repo
  fixture_script "grep -qE '^\.github/workflows/code-review-audit\.yml\$' input.txt
grep -qE 'cost \\\$[0-9]+' input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# A `\\` pair is a literal backslash and is portable. Reading its second byte as
# the start of a new escape would flag the real tree's hook-scope manifest check.
@test "greens on an escaped backslash inside a bracket expression" {
  fixture_repo
  fixture_script "grep -qE '(^|[^/\\\\])\.gaia/local' <<<\"\$text\" && printf '%s\n' hit"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# The walk stops at the first UNQUOTED terminator, so an escape belonging to a
# different command downstream of the pipe is not this gate's to demand.
@test "does not read past the end of the grep command" {
  fixture_repo
  fixture_script "grep -oE '^[a-z]+' input.txt | tr '\n' ' '
grep -Eq \"\$pattern\" < <(sed -E 's/\t/ /g' input.txt)"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# -F has no regex at all, -P is PCRE where every escape here is defined and
# identical, and -G is a BRE, a separate class this gate does not claim. Each
# also wins over an earlier -E, because grep honours the last matcher option.
@test "greens on a matcher other than extended regex" {
  fixture_repo
  fixture_script "grep -qF 'a\tb' input.txt
grep -qP 'a\tb' input.txt
grep -q 'a\tb' input.txt
grep -EF 'a\tb' input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "greens on a pattern held in a variable" {
  fixture_repo
  fixture_script "KEY_RE='a\tb'
grep -qE \"\$KEY_RE\" input.txt"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "skips a full-line comment showing a bad pattern" {
  fixture_repo
  fixture_script "# never write grep -E 'a\tb', it inverts between platforms
echo ok"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "ignores an identifier that merely contains grep" {
  fixture_repo
  fixture_script "ugrep -E 'a\tb' input.txt
zgrep -E 'c\td' input.txt
grepped=\"a\tb\"
echo \"\$grepped\""
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# --- the scan surface ------------------------------------------------------

@test "flags a pattern in a workflow run body" {
  fixture_repo
  fixture_file .github/workflows/ci.yml 'jobs:
  t:
    steps:
      - run: |
          printf "%s\n" "$changed" | grep -qE "^app/.*\.tsx?\r?$"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ci.yml:5:" <<<"$output"
}

@test "flags a pattern in a composite action" {
  fixture_repo
  fixture_file .github/actions/thing/action.yml 'runs:
  using: composite
  steps:
    - shell: bash
      run: |
        grep -qE "a\tb" input.txt'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "action.yml:6:" <<<"$output"
}

# The templates render into an adopter's own CI, where a pattern authored and
# verified on macOS is executed by GNU grep on a runner nobody here watches.
@test "flags a pattern in an adopter workflow template" {
  fixture_repo
  fixture_file .gaia/cli/src/automation/templates/workflows/gaia-ci.yml.tmpl 'jobs:
  run:
    steps:
      - run: |
          grep -qE "^{{tool_id}}:\s*\d+$" report.txt'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-ci.yml.tmpl:5:" <<<"$output"
  grep -qF -- '\d in an extended-regex grep pattern' <<<"$output"
}

# `.gaia/cli/templates/workflows/` is a build artifact copied from `src/`.
# Scanning it as well would report every hit twice and name a file the repair
# must not hand-edit.
@test "does not scan the bundled template artifact" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file .gaia/cli/templates/workflows/gaia-ci.yml.tmpl 'jobs:
  run:
    steps:
      - run: |
          grep -qE "a\tb" input.txt'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# A bats suite is where this class is demonstrated: the fixtures above are
# themselves unportable patterns, and a raw-line scanner cannot tell one from an
# executed call. This is a declared fail-open, pinned here so the exclusion
# cannot be dropped without a test going red.
@test "does not scan bats suites or markdown" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "@test \"x\" {
  grep -qE 'a\tb' <<<\"\$output\"
}"
  fixture_file doc.md 'Run this:

```bash
grep -qE "a\tb" input.txt
```'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "errors rather than greening when nothing is scanned" {
  fixture_repo
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
}

@test "the real repository tree is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}
