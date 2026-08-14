#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-git-path-quoting.sh: the static gate that flags
# an executed `git diff --name-only` or `git ls-files` which omits `-z`, so
# git's default `core.quotePath` cannot C-quote a path the caller then parses.
#
# Two jobs, the same pair the sibling array-guard suite carries: prove the
# detector fires on a known-bad fixture in each scanned file type (shell, husky
# hook, workflow YAML) and stays quiet on every legitimate shape (a `-z` call,
# a comment, a markdown code span, a string constant, an untracked file), and
# assert the real scanned tree is clean so a regression fails CI.
#
# Two groups of tests are load-bearing beyond coverage, and both exist because a
# guard that has never been shown to red against a real historical instance has
# asserted nothing about the class it was written for.
#
#   `#1229` makes that binding for the `diff --name-only` half: "reds against
#   the pre-fix worthiness-presence-check.sh derivation" is that test.
#
#   `#1389` makes it binding for the `ls-files` half, and names five discovery
#   call sites the extended guard must red against in their PRE-FIX form. The
#   five `@test`s under "the five pre-fix ls-files discovery sites" are that
#   requirement, one per site. Their point is the fixture BODY, which is the
#   literal pre-fix line copied from each site; the paths are the real ones so a
#   reader can trace a failing test back to what it was written for.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# The linter resolves its scan surface with `git ls-files` relative to cwd, so
# every fixture is a real git repository with its files added. That is also
# what pins the untracked-file test below: an untracked script is not scanned.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-git-path-quoting.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_repo: an initialized git repo in $TMP with no files yet.
fixture_repo() {
  TMP="$(mktemp -d -t git-path-quoting-lint-XXXXXX)"
  git -C "$TMP" init -q .
}

# fixture_file <relpath> <body>: write <body> to $TMP/<relpath> and track it.
# Call fixture_repo first.
fixture_file() {
  mkdir -p "$TMP/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/$1"
  git -C "$TMP" add -f -- "$1"
}

# run_linter: run the gate from the fixture root, where its cwd-relative
# `git ls-files` resolves.
run_linter() {
  run bash -c "cd '$TMP' && bash '$LINTER'"
}

# 1. The real scanned tree is clean (regression gate)

@test "the real scanned tree (shell + husky + workflow YAML) passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 2. The detector fires, once per scanned file type

@test "flags an unquoted diff --name-only in a shell script" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
  grep -qF -- "-z" <<<"$output"
}

@test "flags an unquoted diff --name-only in a husky hook" {
  fixture_repo
  fixture_file .husky/pre-commit $'#!/usr/bin/env sh\nchanged=$(git diff --name-only HEAD~1...HEAD)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".husky/pre-commit:2" <<<"$output"
}

@test "flags an unquoted diff --name-only in a workflow YAML run block" {
  fixture_repo
  fixture_file .github/workflows/ci.yml $'jobs:\n  a:\n    steps:\n      - run: |\n          changed=$(git diff --name-only "${BASE}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/ci.yml:5" <<<"$output"
}

# The binding test. `#1229`'s Suggested fix: whichever guard lands must be shown
# to red against at least one of the four historical sites in its pre-fix form.
# This is .claude/hooks/worthiness-presence-check.sh:169 as it stood before
# PR #1227 fixed it.
@test "reds against the pre-fix worthiness-presence-check.sh derivation" {
  fixture_repo
  fixture_file .claude/hooks/worthiness-presence-check.sh \
    $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/worthiness-presence-check.sh:2" <<<"$output"
}

@test "flags every unquoted call on a line, not only the first" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\na=$(git diff --name-only "$X") ; b=$(git diff --name-only "$Y")'
  run_linter
  [ "$status" -eq 1 ]
  [ "$(grep -cF -- "probe.sh:2" <<<"$output")" -eq 2 ]
}

# 3. Legitimate shapes are NOT flagged

@test "a call carrying -z passes" {
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nchanged="$(git diff --name-only -z "${base}...HEAD" 2>/dev/null | tr \'\\0\' \'\\n\' || true)"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a git -C form is recognized as an invocation and still checked" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only -z "${base}...HEAD" | tr \'\\0\' \'\\n\')"'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a git -C form missing -z is flagged" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged="$(git -C "$root" diff --name-only "${base}...HEAD")"'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

# A legacy backtick command substitution is textually identical to a markdown
# code span, and reading it as prose is a fail-OPEN miss. A backtick opening in
# command position (after `=` or `(`) is substitution, not prose.
@test "a backtick command substitution in assignment position is flagged" {
  fixture_repo
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          changed=`git diff --name-only "${BASE}...HEAD"`'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".github/workflows/ci.yml:5" <<<"$output"
}

@test "a backtick command substitution in subshell position is flagged" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(`git diff --name-only "$B"`)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

# The `invoked` prefix must admit any git global option, not a hand-named pair.
@test "a git --no-pager form is recognized as an invocation" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git --no-pager diff --name-only "$B")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

@test "a git --no-pager form carrying -z passes" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git --no-pager diff --name-only -z "$B" | tr \'\\0\' \'\\n\')'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a full-line comment is skipped" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\n# changed=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 0 ]
}

# The false positive that would otherwise fire on
# .github/workflows/code-review-audit.yml:486, where an agent prompt names the
# command inside a markdown code span.
@test "a call inside a markdown code span is prose, not an invocation" {
  fixture_repo
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          echo "1. Run `git diff --name-only origin/main...HEAD` first."'
  run_linter
  [ "$status" -eq 0 ]
}

# The false positive that would otherwise fire on
# .gaia/scripts/check-audit-base-derivation.sh:278, where the call is the VALUE
# of a fixed-string variable rather than an invocation.
@test "a string constant that is not a git invocation is skipped" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nGAIA_AUDIT_DIFF_CALL=\'diff --name-only\''
  run_linter
  [ "$status" -eq 0 ]
}

# `-z` must sit immediately after the call. Unanchored, a pathspec carrying the
# token would vouch for a call that still quotes -- the same discrimination
# assertion 4 in check-audit-base-derivation.sh makes, and for the same reason.
@test "a -z appearing later in the call does not vouch for it" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD" -- "docs/a -z b.md")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

@test "an untracked script is not scanned" {
  fixture_repo
  # A tracked file is required, else the empty-scan-set guard below fires and
  # this test would pass for the wrong reason.
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  printf '%s\n' $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")' > "$TMP/untracked.sh"
  run_linter
  [ "$status" -eq 0 ]
}

# An empty scan set means the discovery is wrong, never that the tree is clean.
# Without this the gate prints `clean` and exits 0 having scanned nothing, which
# is the lie-green failure it exists to stop elsewhere.
@test "an empty scan set is a hard error, not a clean tree" {
  fixture_repo
  fixture_file README.md $'nothing scannable here'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "nothing was scanned" <<<"$output"
  grep -qF -- "clean" <<<"$output" && return 1
  true
}

# The command-position test recognizes `=` and `(` and nothing else. Both error
# directions are pinned here so neither can drift unnoticed: parenthetical prose
# is flagged (fail-closed, the repair is to reword), and a substitution opening
# after a quote is missed (fail-open, tokenizer-bound). The docblock states this
# as a rule; these two tests are that rule's oracle.
@test "parenthetical prose before a backtick is flagged, fail-closed by design" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\necho "Step 1 (`git diff --name-only origin/main...HEAD`) lists the files."'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

@test "a substitution opening after a quote is missed, fail-open by design" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nif [ -n "`git diff --name-only $B`" ]; then :; fi'
  run_linter
  [ "$status" -eq 0 ]
}

# The scan surface stops at shell, husky hooks and workflow YAML. The bats
# suites are deliberately outside it: check-audit-base-derivation.bats carries
# five intentionally-unquoted agent-prose fixtures for assertion 4, and five
# sibling suites run an unquoted `diff --name-only` under `core.quotePath=true`
# as the positive control proving the hazard is real. A scanner reading raw
# lines cannot tell those from an executed call, and "fixing" them would delete
# the evidence the class exists.
@test "a bats suite is outside the scan surface" {
  fixture_repo
  # A tracked, scannable, clean file so the empty-scan-set guard cannot make
  # this pass for the wrong reason: the exit 0 must come from the .bats file
  # being unscanned, not from there being nothing to scan.
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file probe.bats $'@test "x" {\n  quoted="$(git diff --name-only "${base}...HEAD")"\n}'
  run_linter
  [ "$status" -eq 0 ]
}

# 3b. The ls-files half of the class

# The five pre-fix discovery sites `#1389` names. Each fixture body is that
# site's literal pre-fix line, so a green here means the guard would have caught
# the class where it actually recurred, not merely where it was convenient to
# demonstrate. The last two are the irony that made the issue concrete: both
# guards for this class were themselves instances of it.

@test "reds against the pre-fix shell-lint.sh *.sh discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'*.sh\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against the pre-fix shell-lint.sh *.bats discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'*.bats\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against the pre-fix shell-lint.sh husky-hook discovery" {
  fixture_repo
  fixture_file .gaia/tests/shell-lint.sh \
    $'#!/usr/bin/env bash\ndone < <(git -C "$REPO_ROOT" ls-files \'.husky/*\')'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/shell-lint.sh:2" <<<"$output"
}

@test "reds against this guard's own pre-fix discovery" {
  fixture_repo
  fixture_file .gaia/scripts/lint-git-path-quoting.sh \
    $'#!/usr/bin/env bash\ndone < <(git ls-files \'*.sh\' \'.husky/*\' \'.github/workflows/*.yml\' | LC_ALL=C sort)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/lint-git-path-quoting.sh:2" <<<"$output"
}

@test "reds against the pre-fix lint-workflow-run-interpolation.sh discovery" {
  fixture_repo
  fixture_file .gaia/scripts/lint-workflow-run-interpolation.sh \
    $'#!/usr/bin/env bash\ndone < <(git ls-files \'.github/workflows/*.yml\' \'.github/workflows/*.yaml\' \\\n           | LC_ALL=C sort)'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/lint-workflow-run-interpolation.sh:2" <<<"$output"
}

# The option-region walk, in both directions. `ls-files` carries its selectors
# before `-z`, so the anchored rule the `diff --name-only` half uses would
# reject every real call; terminating the walk at the first non-option is what
# keeps a pathspec from vouching in its place.

@test "an ls-files call carrying -z passes" {
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nwhile IFS= read -r -d \'\' f; do :; done < <(git ls-files -z \'*.sh\')'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an ls-files call whose -z follows selector options passes" {
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\nn=$(git ls-files --others --exclude-standard -z | tr \'\\0\' \'\\n\' | wc -l)'
  run_linter
  [ "$status" -eq 0 ]
}

@test "a -z inside an ls-files pathspec does not vouch for the call" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfiles=$(git ls-files -- "docs/a -z b.md")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "probe.sh:2" <<<"$output"
}

# `--error-unmatch` makes the call an existence assertion whose contract is its
# exit status; git documents it that way and every such call in this tree
# discards stdout. Demanding `-z` there would be a change with no failure mode.
@test "an --error-unmatch existence assertion is exempt" {
  fixture_repo
  fixture_file probe.sh \
    $'#!/usr/bin/env bash\ngit -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an ls-files call inside a markdown code span is prose, not an invocation" {
  fixture_repo
  fixture_file tracked.sh $'#!/usr/bin/env bash\necho hello'
  fixture_file .github/workflows/ci.yml \
    $'jobs:\n  a:\n    steps:\n      - run: |\n          echo "Walk `git ls-files` first."'
  run_linter
  [ "$status" -eq 0 ]
}

@test "an unquoted ls-files is reported as ls-files and hinted with its own idiom" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nfor f in $(git ls-files); do :; done'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "ls-files without -z" <<<"$output"
  grep -qF -- "read -r -d" <<<"$output"
}

# 4. Reporting contract

@test "a clean tree reports clean and exits 0" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\necho hello'
  run_linter
  [ "$status" -eq 0 ]
  grep -qF -- "clean" <<<"$output"
}

@test "the report names the fix idiom" {
  fixture_repo
  fixture_file probe.sh $'#!/usr/bin/env bash\nchanged=$(git diff --name-only "${base}...HEAD")'
  run_linter
  [ "$status" -eq 1 ]
  grep -qF -- "tr " <<<"$output"
}
