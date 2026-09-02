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

# fixture_repo_bare: an initialized git repo in $TMP with no files yet and no
# seeded surface. Point a test that needs an empty scan set here.
fixture_repo_bare() {
  TMP="$(mktemp -d -t grep-ere-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_repo: fixture_repo_bare with a benign tracked *.bats file already
# seeded. gaia_guard_bats_files hard-errors on an empty *.bats surface, so
# every ordinary fixture needs one already in place to reach this guard's own
# class detection at all.
fixture_repo() {
  fixture_repo_bare
  fixture_file seed.bats '@test "seed" { true; }'
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

# The backtick skip must END at the closing tick. A skip that ran to end of line
# would swallow every escape after a substitution while the gate still printed
# clean, which is the lie-green direction: the pattern below carries a correct
# substitution AND a real defect, and only the defect may be reported.
@test "a closed backtick substitution does not mask a later escape" {
  fixture_repo
  fixture_script 'grep -qE "^a`printf '"'"'\r'"'"'`b\tc$" input.txt'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
  grep -qF -- '\r in an extended-regex grep pattern' <<<"$output" && return 1
  true
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
# identical, and -G is a BRE, a separate class this gate does not claim.
#
# A fixture with no E pins nothing about the clause it appears to name: the
# call is already not-extended before any clearing clause runs, so it passes
# whether or not that clause still exists. `grep -qG` was exactly that, and
# deleting G from the code left every test green. Hence the E in `-qEP` and
# `-qEG`.
#
# Two lines here carry no E, both deliberately. The bare `grep -q` is the
# no-option baseline. `grep -qF` pins nothing about F on its own, and F is
# pinned instead by the conflicting bundle on the last two lines: dropping F
# from the clause reds this test through those, not through the -qF line.
#
# The last two fixtures are a CONFLICTING bundle, pinned in both orders because
# the platforms disagree on it and the gate must not depend on that
# disagreement: BSD grep honours the last matcher letter, making -FE extended
# and -EF fixed, while GNU grep refuses either order with exit 2 and
# `conflicting matchers specified`. So no escape inside one can silently
# diverge, which is why the gate reads both as not-extended rather than
# resolving them.
@test "greens on a matcher other than extended regex" {
  fixture_repo
  fixture_script "grep -qF 'a\tb' input.txt
grep -qEP 'a\tb' input.txt
grep -q 'a\tb' input.txt
grep -qEG 'a\tb' input.txt
grep -EF 'a\tb' input.txt
grep -FE 'a\tb' input.txt"
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

# --- the declared false positives ------------------------------------------

# The header names two shapes the scan reports that are not defects, and states
# the repair for each. Both halves of that are claims about what this guard
# does, and prose making such a claim decays silently while a test re-checks
# itself, so each shape is pinned here in three parts: the hit it produces, an
# edit that does NOT clear it, and the one that does. Two rounds of this suite's
# own review turned on a repair sentence that was wrong, and the non-clearing
# fixture is the half that catches that particular wrongness, since a header
# offering a hatch that does nothing is exactly what those rounds found.

@test "flags a grep pattern quoted inside another tool's program text" {
  fixture_repo
  fixture_script 'awk '"'"'/grep -E "a\tb"/ { print }'"'"' f'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# The non-clearing half, and the reason the header does NOT offer the
# pattern-in-a-variable hatch for this shape: an assignment line still carrying
# the grep token keeps the hit.
@test "the awk shape still flags with its program hoisted into a variable" {
  fixture_repo
  fixture_script 'prog='"'"'/grep -E "a\tb"/ { print }'"'"'
awk "$prog" f'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# The clearing half: only the escaped letter's own line matters.
@test "the awk shape clears once the escape leaves the grep line" {
  fixture_repo
  fixture_script 'esc='"'"'a\tb'"'"'
awk "/grep -E \"$esc\"/ { print }" f'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "flags a trailing shell comment after the call" {
  fixture_repo
  fixture_script 'grep -qE "^x$" f  # tolerate \t here'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# The non-clearing half for this shape: hoisting the PATTERN changes nothing,
# because the escape is in the comment rather than the pattern.
@test "the trailing-comment shape still flags with its pattern hoisted" {
  fixture_repo
  fixture_script 'RE="^x$"
grep -qE "$RE" f  # tolerate \t here'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# The clearing half: the comment has to move, and the full-line skip is what
# then reaches it.
@test "the trailing-comment shape clears once the comment moves to its own line" {
  fixture_repo
  fixture_script '# tolerate \t here
grep -qE "^x$" f'
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

# Tracked bats suites join the surface as their own set: the fixture above,
# once unportable evidence a raw-line scanner could not tell from an executed
# call, is now discriminated by the shared library and reported like any other
# executed shell.
@test "reports an instance now that tracked bats suites join the surface" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "@test \"x\" {
  grep -qE 'a\tb' <<<\"\$output\"
}"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "suite.bats:2:" <<<"$output"
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# Markdown stays out of the surface: the class needs the pattern authored on
# one platform and run on another, and an executed markdown snippet is run by
# an agent on the author's own machine, so the exposure never arises. Pinned
# here so the exclusion cannot be dropped without a test going red.
@test "still does not scan markdown" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file doc.md 'Run this:

```bash
grep -qE "a\tb" input.txt
```'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "errors rather than greening when nothing is scanned" {
  fixture_repo_bare
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output" || return 1
  # Names the sets this gate asked for, not the phrase every empty-surface
  # message carries: the bats error below carries it too, and would other-
  # wise green this test over a scan discovery that reported clean over
  # nothing.
  grep -qF -- "the scan surface (shell husky workflows)" <<<"$output"
}

# The `|| exit $?` on the discovery call is the whole mechanism here. `|| exit 1`
# folds a discovery that never ran into the status this gate uses for a tree it
# read and found nothing in, and an operator handed that would go looking at the
# tree. Run outside any repository, so `git ls-files` fails rather than answering
# empty; that is the one discovery failure a fixture can produce without a stub.
@test "a discovery that never ran exits distinctly from a surface that came back empty" {
  TMP="$(mktemp -d -t grep-ere-lint-XXXXXX)"
  run bash -c "cd '$TMP' && bash '$LINTER' 2>&1"
  [ "$status" -eq 3 ]
  grep -qF -- "discovery failed" <<<"$output" || return 1
  grep -qF -- "nothing was scanned" <<<"$output"
}

# An empty *.bats surface is its own hard error, distinct from the empty
# shell/workflow surface above: a tree with tracked shell and no bats must not
# pass clean carried by the rest of the scan.
@test "errors on an empty bats surface even with a real shell surface present" {
  fixture_repo_bare
  fixture_script "echo ok"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "no tracked bats suites matched the scan surface; nothing was scanned" <<<"$output"
}

# --- the gaia-lint-ignore pragma, on *.bats and beyond ---------------------

@test "an unused pragma is reported" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes: not needed
@test \"x\" { true; }"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "suite.bats:1: unused gaia-lint-ignore for lint-grep-ere-escapes: the line below it carries no instance of that class" <<<"$output"
}

# lint-git-path-quoting.sh alone owns the orphaned-name error, so a single
# malformed pragma anywhere in the tree produces one finding rather than three.
@test "an orphaned pragma name reports nothing from this guard" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore not-a-real-guard: reason here
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
  grep -qF -- "malformed gaia-lint-ignore" <<<"$output" && return 1
  true
}

# Same single-owner rule for a missing reason: this guard prints nothing about
# it, and the pragma still names this guard correctly so it also suppresses
# its target's own instance.
@test "a pragma missing its reason reports nothing from this guard" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  grep -qF -- "malformed" <<<"$output" && return 1
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# The token resolves against the guard's OWN directory, never cwd, so it
# suppresses correctly even though the fixture repo has no .gaia/scripts/.
@test "a well-formed pragma resolves against the guard's own scripts_dir" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes: fixture demonstrates the class
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "a pragma above a real instance in tracked shell is honored nowhere" {
  fixture_repo
  fixture_script "# gaia-lint-ignore lint-grep-ere-escapes: does not apply here
grep -E 'name\tvalue' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
  grep -qF -- "gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here" <<<"$output"
}

@test "a pragma above a real instance in a husky hook is honored nowhere" {
  fixture_repo
  fixture_file .husky/pre-commit "# gaia-lint-ignore lint-grep-ere-escapes: does not apply here
grep -E 'name\tvalue' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
  grep -qF -- "gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here" <<<"$output"
}

@test "a pragma above a real instance in a workflow run body is honored nowhere" {
  fixture_repo
  fixture_file .github/workflows/ci.yml 'jobs:
  t:
    steps:
      - run: |
          # gaia-lint-ignore lint-grep-ere-escapes: does not apply here
          grep -qE "a\tb" input.txt'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
  grep -qF -- "gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here" <<<"$output"
}

# The off-surface finding fires whether or not the target line carries an
# instance: reading it only at the print point would go silently inert here.
@test "a pragma above a clean line in tracked shell is still honored nowhere" {
  fixture_repo
  fixture_script "# gaia-lint-ignore lint-grep-ere-escapes: does not apply here
echo ok"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "gaia-lint-ignore is honored only in *.bats; this pragma waives nothing here" <<<"$output"
  grep -qF -- "in an extended-regex grep pattern" <<<"$output" && return 1
  true
}

@test "a wrapped reason still suppresses the target" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes: the reason
# wraps onto this line too
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "stacked pragmas naming different guards both apply to the target" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-git-path-quoting: unrelated finding
# gaia-lint-ignore lint-grep-ere-escapes: the actual reason
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "a blank line interrupts the pragma block, leaving it unused" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes: does not reach past the blank line

@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "unused gaia-lint-ignore for lint-grep-ere-escapes" <<<"$output"
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

@test "an ordinary comment does not interrupt the pragma block" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "# gaia-lint-ignore lint-grep-ere-escapes: the reason
# just an ordinary remark, not a pragma
@test \"x\" { grep -qE 'a\tb' <<<\"\$x\"; }"
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# --- new behavioral shapes on the bats surface ------------------------------

# A multi-line body handed to bash -c is executed shell however it was
# written, so the assignment's own name is disqualified from the argument-
# region rule and every interior line, including this one, is reported. The
# fixture is long enough that FNR and file_length + FNR cannot coincide, which
# is what a missed NR-to-FNR conversion would print instead.
@test "an interior line of a bash -c body is reported at its own line" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats '@test "x" {
  script='"'"'echo pad1
echo pad2
echo pad3
echo pad4
echo pad5
grep -qE "a\tb" <<<"$1"
echo pad7'"'"'
  bash -c "$script"
}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "suite.bats:7:" <<<"$output"
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# A helper the idiom set does not name is not a recognized fixture writer, so
# its argument is read as ordinary shell and the embedded pattern is reported.
@test "a fixture written through an unrecognized helper is reported" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "@test \"x\" {
  record_pattern out.txt 'grep -qE \"a\tb\" f'
}"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

# Heredoc bodies are swallowed as data on *.bats (README's "What each guard
# reports today" table), the same as they always were on every other surface;
# these three pin that the fixture-region skip did not leak off *.bats onto
# the surfaces that must keep today's coverage unchanged.
@test "a heredoc body in tracked shell is still reported" {
  fixture_repo
  fixture_script "cat <<'EOF'
grep -qE 'a\tb' input.txt
EOF"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

@test "a heredoc body in a husky hook is still reported" {
  fixture_repo
  fixture_file .husky/pre-commit "cat <<'EOF'
grep -qE 'a\tb' input.txt
EOF"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

@test "a heredoc body in a workflow run body is still reported" {
  fixture_repo
  fixture_file .github/workflows/ci.yml 'jobs:
  t:
    steps:
      - run: |
          cat <<'"'"'EOF'"'"'
          grep -qE "a\tb" input.txt
          EOF'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- '\t in an extended-regex grep pattern' <<<"$output"
}

@test "a bats file ending inside an open quote produces the desync error" {
  fixture_repo
  fixture_script "echo ok"
  fixture_file suite.bats "@test \"x\" {
  echo 'unterminated"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ERROR: the scan lost track of shell state before the end of the file" <<<"$output"
}

@test "the real repository tree is clean" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER' 2>&1"
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

# As in the sibling guard: the portable-spelling footer is the repair for a
# class hit, so a run reddened only by pragma hygiene must not print it. Both
# directions are pinned, because withholding the footer unconditionally, by the
# gate regressing to always-false or by the block being deleted, would satisfy
# the withheld direction on its own and cost every real hit its remedy.
@test "the portable-spelling footer is withheld on a run whose findings are all pragma hygiene" {
  fixture_repo
  # A clean non-bats file, because the guard hard-errors on an empty scan
  # surface and this test is about the footer, not about that error.
  fixture_file clean.sh $'#!/usr/bin/env bash\ntrue'
  fixture_file hygiene.bats $'@test "a" {\n  # gaia-lint-ignore lint-grep-ere-escapes: nothing here to suppress\n  true\n}'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "unused gaia-lint-ignore" <<<"$output"
  grep -qF -- "Fix each by writing the character portably:" <<<"$output" && return 1
  true
}

@test "the portable-spelling footer still prints when a real class hit is reported" {
  fixture_repo
  fixture_script "grep -E 'name\tvalue' input.txt"
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "Fix each by writing the character portably:" <<<"$output"
}
