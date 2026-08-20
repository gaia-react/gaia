#!/usr/bin/env bats
# Tests for .gaia/tests/shell-lint.sh: assert the deterministic local shell gate
# folds the hook array-guard (.gaia/scripts/lint-hook-array-guard.sh) into its
# run, so every shell-lint caller enforces the bash-3.2 empty-array-abort class
# locally, not only the Audit CI Tests job. The detector's own
# correctness is covered by lint-hook-array-guard.bats; this suite covers the
# wiring.
#
# The bash-3.2 parse pass has no separate detector to cover it, so its four
# branches are asserted here directly, through the SHELL_LINT_BASH32 seam: a
# clean sweep, a parse error, a too-new interpreter that must skip LOUDLY, and
# an interpreter this pass cannot reason about, which must fail closed. Driving
# them through a stub rather than the host's real /bin/bash is what makes the
# suite give the same verdict on an ubuntu runner and on macOS -- the exact
# host-dependence the pass under test exists to surface.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no shellcheck)
# and stays fast: the only real work left is the array-guard scanning the real
# .claude/hooks tree, which lint-hook-array-guard.bats already asserts clean.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GATE="$REPO_ROOT/.gaia/tests/shell-lint.sh"
  # A clean, pinned-version shellcheck stub lets the gate clear both shellcheck
  # passes and reach the array-guard pass without a real shellcheck binary. Its
  # `version:` tracks SHELLCHECK_PIN in shell-lint.sh; a stale stub after a pin
  # bump only makes the gate emit a non-fatal version-drift WARN (stderr, no
  # exit-status change), so this suite still passes -- keep them in sync anyway.
  STUB_DIR="$(mktemp -d -t shell-lint-stub-XXXXXX)"
  cat > "$STUB_DIR/shellcheck" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
# Record one line per invocation when a log path is set, so a test can assert
# which files a pass linted and with which dialect. Unset by default, so the
# stub stays a pure always-clean fake for every other test.
if [ -n "${SHELLCHECK_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SHELLCHECK_LOG"
fi
# Report a finding for exactly one named file, so a test can place a failure in
# a chosen worker's chunk. Quoted inside the pattern, so a path is matched
# literally rather than as a glob. Unset by default.
if [ -n "${SHELLCHECK_FAIL_ON:-}" ]; then
  case " $* " in
    *" $SHELLCHECK_FAIL_ON "*)
      printf 'In %s line 1:\nSC9999 (error): stub finding\n' "$SHELLCHECK_FAIL_ON"
      exit 1
      ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUB_DIR/shellcheck"

  # A fake interpreter for the bash-3.2 parse pass. BASH32_MAJOR is the major
  # version it reports when the gate asks (default 3, an in-range interpreter);
  # BASH32_FAIL_ON is a space-separated LIST of files it rejects, so a test can
  # place parse errors at chosen positions in the sweep without authoring files
  # no bash can parse. A list rather than one name because proving the sweep
  # reports EVERY broken script takes two failures in a single run; matched with
  # the same quoted `case` shape the shellcheck stub above uses, so a path is
  # compared literally rather than as a glob.
  cat > "$STUB_DIR/bash32" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then
  printf '%s\n' "${BASH32_MAJOR-3}"
  exit 0
fi
if [ "$1" = "-n" ]; then
  if [ -n "${BASH32_FAIL_ON:-}" ]; then
    case " $BASH32_FAIL_ON " in
      *" $2 "*)
        printf '%s: line 1: syntax error: unexpected end of file\n' "$2" >&2
        exit 2
        ;;
    esac
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB_DIR/bash32"
}

teardown() {
  [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  return 0
}

# The gate runs the hook array-guard as one of its passes and reports it.

@test "shell-lint folds in the hook array-guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # Grep the guard's OWN stderr proof line, not shell-lint's header echo: this
  # string is printed by lint-hook-array-guard.sh itself, so it appears only if
  # the guard actually ran, catching a future edit that drops the invocation but
  # leaves the header.
  grep -qF -- "lint-hook-array-guard: clean" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output"
}

# The same wiring assertion for the git path-quoting guard. Its own correctness
# is covered by lint-git-path-quoting.bats; this covers only that the gate
# still invokes it, which is the class the sibling assertion above exists for.

@test "shell-lint folds in the git path-quoting guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-git-path-quoting: clean" <<<"$output"
}

# The same wiring assertion for the workflow run-interpolation guard. Its own
# correctness is covered by lint-workflow-run-interpolation.bats; this covers
# only that the gate still invokes it.

@test "shell-lint folds in the workflow run-interpolation guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-workflow-run-interpolation: clean" <<<"$output"
}

# The same wiring assertion for the grep ERE-escape guard. Its own correctness
# is covered by lint-grep-ere-escapes.bats; this covers only that the gate still
# invokes it.

@test "shell-lint folds in the grep ERE-escape guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-grep-ere-escapes: clean" <<<"$output"
}

# The same wiring assertion for the errexit status-read guard. Its own
# correctness is covered by lint-errexit-status-read.bats; this covers only that
# the gate still invokes it.

@test "shell-lint folds in the errexit status-read guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE"
  [ "$status" -eq 0 ]
  # The guard's OWN stderr proof line, for the same reason as above: it appears
  # only if the guard actually ran, so a future edit dropping the invocation but
  # leaving the header echo is caught.
  grep -qF -- "lint-errexit-status-read: clean" <<<"$output"
}

# The husky hooks are extensionless, so they match neither the *.sh nor the
# *.bats discovery glob and need a pass of their own. Husky runs them as
# `sh -e`, so that pass pins the dialect: shellcheck takes one dialect per
# invocation, which is why this cannot fold into the *.sh pass.

@test "shell-lint lints the tracked husky hooks as sh" {
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_LOG="$STUB_DIR/argv.log" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qE -- '(^| )-s sh( |$).*\.husky/pre-commit' "$STUB_DIR/argv.log"
}

# Derive a rig path the way the gate discovers its file list: NUL-delimited with
# `core.quotepath` off. A plain `git ls-files '*.sh' | head -n 1` disagrees with
# the gate under git's default quoting -- a tracked path carrying a non-ASCII
# byte comes back C-quoted, so BASH32_FAIL_ON would name a path the sweep never
# sees and the absence assertion in the loud-skip test below would pass
# trivially, degrading it from "proved no sweep ran" to "the warning printed".
# A read loop rather than `head -z`: that flag is GNU-only and absent from
# macOS's head, which is the platform this whole gate exists for.
# `.gaia/scripts/lint-git-path-quoting.sh` excludes *.bats by design, so nothing
# catches this shape here.
#
# Args: first|last
tracked_sh() {
  local which_end="$1" f first="" last=""
  while IFS= read -r -d '' f; do
    if [ -z "$first" ]; then
      first="$f"
    fi
    last="$f"
  done < <(git -C "$REPO_ROOT" -c core.quotepath=false ls-files -z '*.sh')
  if [ "$which_end" = "first" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$last"
  fi
}

# The bash-3.2 parse pass. Shellcheck models bash 5's grammar, so a construct
# that is a syntax error only on 3.2 clears every pass above it; this pass is
# the one that reads the tree with the interpreter the scripts declare support
# for. Its four branches follow.

@test "the bash-3.2 parse pass runs and stays green when every script parses" {
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qF -- "bash-3.2 parse ($STUB_DIR/bash32 -n)" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output"
}

@test "the bash-3.2 parse pass fails the gate on a script the interpreter cannot parse" {
  first_sh="$(tracked_sh first)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    BASH32_FAIL_ON="$first_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  # The interpreter's own diagnostic has to reach the operator, or the gate
  # reds without naming the file that will not parse.
  grep -qF -- "$first_sh: line 1: syntax error" <<<"$output"
}

@test "the bash-3.2 parse pass reports EVERY broken script, not only the first" {
  # The sweep's header claims one invocation names every broken script rather
  # than only the first. Rigging a single file cannot check that claim wherever
  # it is placed: rig only the first and an abort-after-it still prints that
  # one diagnostic, rig only the last and an abort-on-first-error aborts with
  # nothing left to report, so both produce byte-identical output. Two failures
  # in ONE run is what discriminates, and rigging the two ends also covers the
  # whole-list-coverage claim a truncated sweep would break.
  first_sh="$(tracked_sh first)"
  last_sh="$(tracked_sh last)"
  [ -n "$first_sh" ]
  [ -n "$last_sh" ]
  [ "$first_sh" != "$last_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    BASH32_FAIL_ON="$first_sh $last_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "$first_sh: line 1: syntax error" <<<"$output"
  grep -qF -- "$last_sh: line 1: syntax error" <<<"$output"
}

@test "the bash-3.2 parse pass skips LOUDLY when the interpreter is too new" {
  # A file is rigged to fail the sweep at the same time. That is what makes the
  # green below mean "did not sweep" rather than merely "swept and found
  # nothing": had the too-new interpreter parsed the tree, it would have hit
  # this file and red.
  first_sh="$(tracked_sh first)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    BASH32_MAJOR=5 BASH32_FAIL_ON="$first_sh" bash "$GATE"
  # A skip is not a failure: an ubuntu runner has no bash 3.2 and must still be
  # able to clear the rest of the gate.
  [ "$status" -eq 0 ]
  # Loud, not silent. A silent skip would let every bash-5 host report the tree
  # clean over syntax nothing on that host ever parsed.
  grep -qF -- "WARNING:" <<<"$output"
  grep -qF -- "parse pass was SKIPPED" <<<"$output"
  # The rigged file's diagnostic is absent, so no sweep ran. Written as the bad
  # case plus an explicit `return 1`, per .claude/rules/bats-assertions.md, so
  # the assertion keeps failing correctly if a later edit appends to this test.
  grep -qF -- "$first_sh: line 1: syntax error" <<<"$output" && return 1
  true
}

@test "the bash-3.2 parse pass fails closed when the interpreter is missing" {
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/no-such-bash" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "is not executable; the bash-3.2 parse pass cannot run" <<<"$output"
  grep -qF -- "shell-lint FAILED" <<<"$output"
}

@test "the bash-3.2 parse pass fails closed when the interpreter reports no version" {
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    BASH32_MAJOR= bash "$GATE"
  # Fail closed rather than skip: an interpreter whose version cannot be read is
  # one this pass cannot place on either side of the 3.2 line, and reporting
  # clean having parsed nothing is the outcome the pass is here to rule out.
  [ "$status" -eq 1 ]
  grep -qF -- "reported no numeric major version" <<<"$output"
  grep -qF -- "shell-lint FAILED" <<<"$output"
}

# The *.sh and *.bats passes split their file list across concurrent shellcheck
# workers, one buffered log each. Two ways that aggregation goes green over a
# real finding, and one test for each end of the list: collecting the status of
# only the last worker (what a bare `wait` returns), and collecting the status of
# only the first. The gate discovers files in `git ls-files` order and slices
# that list contiguously, so the first tracked path is always in the first
# worker's chunk and the last is always in the last worker's. On a single-core
# host both tests still assert the finding fails the gate, just without
# distinguishing the two workers.

@test "shell-lint fails closed on a finding in the FIRST worker's chunk" {
  first_sh="$(tracked_sh first)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$first_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  # The failing worker's buffered log has to replay too, or the gate reds
  # without ever naming what is broken.
  grep -qF -- "In $first_sh line 1:" <<<"$output"
}

@test "shell-lint fails closed on a finding in the LAST worker's chunk" {
  last_sh="$(tracked_sh last)"
  [ -n "$last_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_FAIL_ON="$last_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "In $last_sh line 1:" <<<"$output"
}

# `--only bash32-parse`: the pass-selection flag the macOS CI leg in
# .github/workflows/shell-lint.yml runs on. Every runner in this repo is bash 5,
# where the parse pass above can only skip, so the pass was enforced by nothing
# mechanical until a leg with a real /bin/bash 3.2 ran it. That leg must not pay
# for the shellcheck harness -- macOS runner minutes bill at 10x -- so the flag
# has to reach the parse pass without shellcheck present at all.

@test "--only bash32-parse runs the parse pass and skips every other pass" {
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    bash "$GATE" --only bash32-parse
  [ "$status" -eq 0 ]
  grep -qF -- "bash-3.2 parse ($STUB_DIR/bash32 -n)" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output"
  # Each absence is asserted against the pass's own header line, so a pass that
  # ran is caught whether or not it found anything. Written as the bad case plus
  # an explicit `return 1` per .claude/rules/bats-assertions.md.
  grep -qF -- "shellcheck *.sh" <<<"$output" && return 1
  grep -qF -- "shellcheck *.bats" <<<"$output" && return 1
  grep -qF -- "shellcheck .husky/*" <<<"$output" && return 1
  grep -qF -- "lint-hook-array-guard" <<<"$output" && return 1
  grep -qF -- "lint-git-path-quoting" <<<"$output" && return 1
  grep -qF -- "lint-workflow-run-interpolation" <<<"$output" && return 1
  grep -qF -- "lint-grep-ere-escapes" <<<"$output" && return 1
  grep -qF -- "lint-errexit-status-read" <<<"$output" && return 1
  true
}

@test "--only bash32-parse runs with no shellcheck on PATH at all" {
  # The cost argument the flag exists for: the macOS leg installs no shellcheck,
  # so an unconditional binary precondition would red it on every run. A stub
  # cannot express "absent", hence a PATH trimmed to the system directories,
  # which carry git, getconf and mktemp on both platforms and carry shellcheck
  # on neither (Homebrew and the pinned CI tarball both land elsewhere). Skipped
  # rather than asserted where that does not hold, so the test never lies.
  if PATH="/usr/bin:/bin" command -v shellcheck >/dev/null 2>&1; then
    skip "this host carries shellcheck in /usr/bin or /bin"
  fi
  run env PATH="/usr/bin:/bin" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    bash "$GATE" --only bash32-parse
  [ "$status" -eq 0 ]
  grep -qF -- "bash-3.2 parse ($STUB_DIR/bash32 -n)" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output"
}

@test "--only bash32-parse still fails closed on a script the interpreter cannot parse" {
  # Selecting one pass must not soften it: the flag narrows what runs, never
  # what a run that finds something reports.
  first_sh="$(tracked_sh first)"
  [ -n "$first_sh" ]
  run env PATH="$STUB_DIR:$PATH" SHELL_LINT_BASH32="$STUB_DIR/bash32" \
    BASH32_FAIL_ON="$first_sh" bash "$GATE" --only bash32-parse
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "$first_sh: line 1: syntax error" <<<"$output"
}

@test "an unknown --only pass is a usage error, not a silent full run" {
  # A typo falling through to the default would run the whole gate on a host
  # that has no shellcheck, reporting the flag's own absence as a lint failure.
  run env PATH="$STUB_DIR:$PATH" bash "$GATE" --only no-such-pass
  [ "$status" -eq 2 ]
  grep -qF -- "unknown --only pass" <<<"$output"
  grep -qF -- "shell-lint passed" <<<"$output" && return 1
  true
}

@test "an unknown argument is a usage error" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE" --bogus
  [ "$status" -eq 2 ]
  grep -qF -- "unknown argument" <<<"$output"
}

@test "--only with no pass name is a usage error" {
  run env PATH="$STUB_DIR:$PATH" bash "$GATE" --only
  [ "$status" -eq 2 ]
  grep -qF -- "needs a pass name" <<<"$output"
}

@test "the CI workflow arms the parse pass on a runner that carries bash 3.2" {
  # The pin that keeps the flag armed. The harness half of this fix is inert on
  # its own: every assertion above passes with the workflow leg deleted, which
  # is the exact posture -- enforcement resting on a voluntary local run -- that
  # this leg exists to end.
  wf="$REPO_ROOT/.github/workflows/shell-lint.yml"
  [ -f "$wf" ]
  # Scoped to the job's own block, never the whole file. Three of these four
  # strings also appear, or could be relocated, elsewhere in this workflow: the
  # sibling ubuntu job's paths-filter carries a byte-identical `- '**/*.sh'`
  # entry, and a refactor that moved the `--only bash32-parse` step onto that
  # job would leave every string present with the pass running on bash 5, where
  # it can only take its exit-0 loud skip. A file-wide grep pins the presence of
  # strings; this pins the leg being armed.
  #
  # The block runs from the job key to the next 2-space-indented key. The
  # terminator asks only whether the third character is a space, which is the
  # one thing that distinguishes a sibling key from this job's own step lines.
  # Deliberately not a job-id character class: any such class is a copy of
  # GitHub's grammar living here, free to drift from it and to miss a spelling
  # it allows, and a quoted key (`  "Smoke":`) is exactly that miss. What a
  # missed terminator costs is not a red but a green: extraction runs to EOF
  # and a later job's strings satisfy the assertions below while this job sits
  # de-armed. Nothing inside a job block sits at 2-space indent, so the
  # terminator cannot fire early; if one ever did, it would fail loudly here
  # rather than pass.
  job="$(awk '/^  bash32-parse:/{f=1;next} f&&/^  [^ ]/{exit} f' "$wf")"
  [ -n "$job" ]
  grep -qF -- "runs-on: macos-latest" <<<"$job"
  grep -qF -- ".gaia/tests/shell-lint.sh --only bash32-parse" <<<"$job"
  # The leg's own precondition. Without it the leg inherits the pass's exit-0
  # loud skip, so an image that stopped shipping 3.2.57 would turn this whole
  # fix back into a green that parsed nothing.
  grep -qF -- 'BASH_VERSINFO[0]' <<<"$job"
  # The arming entry. Narrowing this job's filter to a pathspec no pull request
  # matches retires the leg on every run while leaving the three strings above
  # untouched, which is the quietest way this fix could be undone.
  grep -qF -- "- '**/*.sh'" <<<"$job"
}
