#!/usr/bin/env bats
#
# Tests for .gaia/tests/verify-harness.sh: argument handling, branch-mode
# preconditions and selection, round mode's narrower selection, and the missing-tool
# probes. Every case builds a fixture repository under $BATS_TEST_TMPDIR with
# .gaia/tests/lib/helpers/verify-harness-fixture.sh, whose stub checks log the
# toplevel they ran from, so a passing case proves a check ran rather than a
# label printed. The merge-base comparison and the pass record live in
# verify-harness-baseline.bats.
#
# VERIFY_HARNESS_SOURCE_DIRECTORY points the fixture at a scratch copy of the
# runner and its helpers, which is how a mutant runs without touching the
# working files.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/verify-harness.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/lib/helpers/verify-harness-fixture.sh"
}

fixture() {
  vhf_init "$@" || return 1
  PATH="$VHF_SHIM:$PATH"
  cd "$VHF_ROOT" || return 1
}

run_runner() {
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" "$@"
}

has() {
  grep -qF -- "$1" <<<"$output" && return 0
  printf 'expected output to contain: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

lacks() {
  grep -qF -- "$1" <<<"$output" || return 0
  printf 'expected output not to contain: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

has_line() {
  grep -qE -- "$1" <<<"$output" && return 0
  printf 'expected a line matching: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

# every_label_is <SKIP|PASS> <label>...: each label's one outcome line.
every_label_is() {
  local outcome="$1" label
  shift
  for label in "$@"; do
    if [ "$outcome" = SKIP ]; then
      has_line "^SKIP  $label: " || return 1
      grep -qE -- "^PASS  $label " <<<"$output" && { printf 'skipped step printed PASS: %s\n' "$label" >&2; return 1; }
    else
      has_line "^PASS  $label \\([0-9]+s\\)$" || return 1
      grep -qE -- "^SKIP  $label: " <<<"$output" && { printf 'passing step printed SKIP: %s\n' "$label" >&2; return 1; }
    fi
  done
  true
}

missing_manifest_diagnostic() {
  printf '  - Manifest claims paths missing from staging tree:\n  -   frontend/app/gone.ts\nFAIL  01-files-present.sh: 1 manifest path(s) missing from staging'
}

@test "branch mode reports every failure and withholds the pass record" {
  fixture
  mkdir -p content
  printf 'FORBIDDEN\n' >content/new-page.txt
  vhf_control 01-files-present "$(missing_manifest_diagnostic)"
  vhf_commit "break the whole-tree suite and the manifest"
  run_runner branch
  [ "$status" -eq 1 ]
  has 'suites/whole.bats: whole content'
  has_line '^FAIL  bats whole-tree \([0-9]+s\)$'
  has_line '^FAIL  01-files-present \([0-9]+s\)$'
  has 'frontend/app/gone.ts'
  has_line '^PASS  shell-lint \([0-9]+s\)$'
  has '  reproduce: bash .gaia/tests/distribution/01-files-present.sh'
  has '  reproduce: bash .gaia/scripts/bats5.sh --filter-tags whole-tree suites/whole.bats < /dev/null'
  lacks 'PRE-EXISTING'
  has 'No pass record written'
  [ ! -e "$VHF_RECORD" ]
}

@test "branch mode selects over the merge-base range, not only the HEAD commit" {
  fixture
  vhf_control x-input "broken"
  vhf_commit "break the x suite"
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "an unrelated HEAD commit"
  run_runner branch
  [ "$status" -eq 1 ]
  has_line '^FAIL  bats selected \([0-9]+s\)$'
  has 'suites/x.bats: x input'
  has '  reproduce: bash .gaia/scripts/bats5.sh suites/x.bats < /dev/null'
  lacks '--filter-tags suites/x.bats'
}

@test "the whole-tree step runs only the per-test-marked tests of a suite nothing selects" {
  fixture --no-branch
  vhf_write_suite suites/pertest.bats tests:keep keep dropone droptwo
  vhf_write_suite suites/listed.bats tests+:listed listed other
  vhf_commit "suites marking one test each"
  vhf_branch
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "an unrelated branch change"
  run_runner branch
  [ "$status" -eq 0 ]
  every_label_is PASS 'bats whole-tree'
  [ "$(vhf_suite_runs suites/pertest.bats "$VHF_ROOT")" = "pertest keep" ]
  [ "$(vhf_suite_runs suites/listed.bats "$VHF_ROOT")" = "listed listed" ]
}

@test "the whole-tree step runs every test of a file-marked suite nothing selects" {
  fixture
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "an unrelated branch change"
  run_runner branch
  [ "$status" -eq 0 ]
  every_label_is PASS 'bats whole-tree'
  [ "$(vhf_suite_runs suites/whole.bats "$VHF_ROOT" | LC_ALL=C sort | tr '\n' ',')" = "whole content,whole one,whole zero," ]
}

@test "a per-test-marked suite the change selects runs every test exactly once" {
  fixture --no-branch
  vhf_write_suite suites/pertest.bats tests:keep keep dropone droptwo
  vhf_commit "a suite marking one test"
  vhf_branch
  vhf_add_test suites/pertest.bats extra
  vhf_commit "the branch changes the marked suite"
  run_runner branch
  [ "$status" -eq 0 ]
  every_label_is PASS 'bats whole-tree' 'bats selected'
  [ "$(vhf_suite_runs suites/pertest.bats "$VHF_ROOT" | LC_ALL=C sort | tr '\n' ',')" = "pertest dropone,pertest droptwo,pertest extra,pertest keep," ]
}

@test "a file-marked suite the change selects runs once in full and the whole-tree step says so" {
  fixture
  vhf_add_test suites/whole.bats two
  vhf_commit "the branch changes the file-marked suite"
  run_runner branch
  [ "$status" -eq 0 ]
  has_line '^SKIP  bats whole-tree: every marked suite runs in full under bats selected$'
  has_line '^PASS  bats selected \([0-9]+s\)$'
  [ "$(vhf_suite_runs suites/whole.bats "$VHF_ROOT" | LC_ALL=C sort | tr '\n' ',')" = "whole content,whole one,whole two,whole zero," ]
}

@test "round mode skips both bats steps when no suite references its delta" {
  fixture
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "a frontend-only change"
  run_runner round
  [ "$status" -eq 0 ]
  has 'DELTA  the HEAD commit: 1 path(s)'
  has "SKIP  bats whole-tree: round mode leaves the whole-tree suites to branch mode and CI"
  has_line '^SKIP  bats selected: no suite references the round'"'"'s delta$'
  grep -q '^bats' "$VERIFY_FIXTURE_LOG" && { cat "$VERIFY_FIXTURE_LOG" >&2; return 1; }
  [ "$(vhf_log_entries shell-lint)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries build-staging)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries 01-files-present)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries 03-marker-strip)" = "$VHF_ROOT" ]
}

@test "round mode runs the HEAD commit's selection and leaves the marked suites to branch mode" {
  fixture
  printf 's1 two\n' >src/s1-input.txt
  vhf_commit "an earlier commit touching what s1 names"
  printf 's2 two\n' >.claude/rules/s2-rule.md
  vhf_commit "a HEAD commit touching a harness rule s2 names"
  run_runner round
  [ "$status" -eq 0 ]
  has "SKIP  bats whole-tree: round mode leaves the whole-tree suites to branch mode and CI"
  has_line '^PASS  bats selected \([0-9]+s\)$'
  [ "$(vhf_suite_runs suites/s2.bats "$VHF_ROOT")" = "s2 rule" ]
  [ -z "$(vhf_suite_runs suites/whole.bats "$VHF_ROOT")" ]
  [ -z "$(vhf_suite_runs suites/s1.bats "$VHF_ROOT")" ]
}

@test "round mode runs no marked suite for a staged harness change nothing selects" {
  fixture
  printf 'new rule\n' >.claude/rules/unnamed-rule.md
  vhf_git add .claude/rules/unnamed-rule.md
  run_runner round
  [ "$status" -eq 0 ]
  has 'DELTA  uncommitted tracked changes against HEAD'
  has "SKIP  bats whole-tree: round mode leaves the whole-tree suites to branch mode and CI"
  has_line '^SKIP  bats selected: '
  [ -z "$(vhf_suite_runs suites/whole.bats "$VHF_ROOT")" ]
}

@test "round mode runs a marked suite its delta selects under bats selected" {
  fixture
  vhf_add_test suites/whole.bats two
  vhf_commit "a HEAD commit editing the marked suite"
  run_runner round
  [ "$status" -eq 0 ]
  has "SKIP  bats whole-tree: round mode leaves the whole-tree suites to branch mode and CI"
  has_line '^PASS  bats selected \([0-9]+s\)$'
  [ "$(vhf_suite_runs suites/whole.bats "$VHF_ROOT" | LC_ALL=C sort | tr '\n' ',')" = "whole content,whole one,whole two,whole zero," ]
}

@test "round mode on a parentless HEAD selects over the empty tree without error" {
  fixture --no-branch
  run_runner round
  [ "$status" -eq 0 ]
  has 'DELTA  the root commit'
  lacks 'FAIL  bats selected'
  has "SKIP  bats whole-tree: round mode leaves the whole-tree suites to branch mode and CI"
}

# A harness commit, so both bats steps would run with every tool present.
harness_commit() {
  printf 's2 two\n' >.claude/rules/s2-rule.md
  vhf_commit "a harness change s2 names"
}

@test "a missing linter skips only shell-lint and says so" {
  fixture
  harness_commit
  farm="$(vhf_path_without shellcheck)"
  run env PATH="$farm" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  has 'WARN  shellcheck not found: install with brew install shellcheck; CI remains the only check for shell-lint'
  every_label_is SKIP shell-lint
  every_label_is PASS 'release-scrub leak check' 01-files-present 03-marker-strip 'bats selected'
}

@test "a missing rsync skips the three distribution checks and says so" {
  fixture
  harness_commit
  farm="$(vhf_path_without rsync)"
  run env PATH="$farm" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  has 'WARN  rsync not found: install with brew install rsync; CI remains the only check for release-scrub leak check, 01-files-present, 03-marker-strip'
  every_label_is SKIP 'release-scrub leak check' 01-files-present 03-marker-strip
  every_label_is PASS shell-lint 'bats selected'
  [ -z "$(vhf_log_entries build-staging)" ]
}

@test "a missing bats skips both bats steps and says so" {
  fixture
  harness_commit
  farm="$(vhf_path_without bats)"
  run env PATH="$farm" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  has 'WARN  bats not found: install with brew install bats-core; CI remains the only check for bats whole-tree, bats selected'
  every_label_is SKIP 'bats whole-tree' 'bats selected'
  every_label_is PASS shell-lint 'release-scrub leak check' 01-files-present 03-marker-strip
}

@test "a non-executable maintainer binary skips the three distribution checks and says so" {
  fixture
  harness_commit
  chmod -x .gaia/cli/gaia-maintainer
  run_runner round
  [ "$status" -eq 0 ]
  has 'WARN  .gaia/cli/gaia-maintainer not found: install with pnpm -C .gaia/cli bundle; CI remains the only check for release-scrub leak check, 01-files-present, 03-marker-strip'
  every_label_is SKIP 'release-scrub leak check' 01-files-present 03-marker-strip
  every_label_is PASS shell-lint
}

@test "a missing jq in branch mode skips 01 and writes no pass record, loudly" {
  fixture
  harness_commit
  farm="$(vhf_path_without jq)"
  run env PATH="$farm" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" branch
  [ "$status" -eq 0 ]
  has 'WARN  jq not found: install with brew install jq'
  every_label_is SKIP 01-files-present
  every_label_is PASS shell-lint 'release-scrub leak check' 03-marker-strip 'bats whole-tree' 'bats selected'
  has 'WARN  no pass record written: jq not found; the audit dispatch gate will deny until jq is installed (brew install jq) and branch mode is re-run'
  lacks 'Pass record written'
  [ ! -e "$VHF_RECORD" ]
}

# A bash that reports major version 3 to bats5.sh's probe and runs the real
# bash for everything else.
write_bash_three_shim() {
  local real_bash shim_directory="$BATS_TEST_TMPDIR/bash-three"
  real_bash="$(command -v bash)"
  mkdir -p "$shim_directory"
  cat >"$shim_directory/bash" <<EOF
#!$real_bash
if [ "\${1:-}" = -c ]; then
  case "\${2:-}" in *BASH_VERSINFO*) echo 3; exit 0 ;; esac
fi
exec "$real_bash" "\$@"
EOF
  chmod +x "$shim_directory/bash"
  printf '%s\n' "$shim_directory"
}

@test "bats still runs under a bash 3.2 and relays the bats5 warning" {
  fixture
  vhf_empty_candidates
  harness_commit
  shim_directory="$(write_bash_three_shim)"
  run env PATH="$shim_directory:$PATH" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  has 'WARNING: bats will run under bash 3'
  every_label_is PASS 'bats selected'
}

@test "bats still runs without a parallel runner and relays the serial warning" {
  fixture
  vhf_empty_candidates
  harness_commit
  farm="$(vhf_path_without parallel rush)"
  run env PATH="$farm" bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" round
  [ "$status" -eq 0 ]
  has 'bats5: --jobs needs GNU parallel (brew install parallel); running serially.'
  every_label_is PASS 'bats selected'
}

@test "a shell-lint failure names the check, the file and the reproduce command" {
  fixture
  vhf_control shell-lint "$(printf 'In scripts/broken-lint.sh line 3:\necho $unquoted\n     ^-- SC2086 (info): Double quote to prevent globbing.')"
  vhf_commit "a lint finding"
  run_runner branch
  [ "$status" -eq 1 ]
  has_line '^FAIL  shell-lint \([0-9]+s\)$'
  has 'scripts/broken-lint.sh'
  has '  reproduce: bash .gaia/tests/shell-lint.sh'
}

@test "branch mode refuses uncommitted tracked changes and runs nothing" {
  fixture
  printf 'dirty\n' >src/x-input.txt
  run_runner branch
  [ "$status" -eq 3 ]
  has 'REFUSED  uncommitted tracked changes (see git status): commit first'
  [ ! -s "$VERIFY_FIXTURE_LOG" ]
  [ ! -e "$VHF_RECORD" ]
}

@test "branch mode refuses a detached HEAD and runs nothing" {
  fixture
  vhf_git checkout -q --detach
  run_runner branch
  [ "$status" -eq 3 ]
  has 'REFUSED  branch mode verifies a branch, and HEAD is detached'
  [ ! -s "$VERIFY_FIXTURE_LOG" ]
  [ ! -e "$VHF_RECORD" ]
}

@test "branch mode warns about untracked harness files it does not cover" {
  fixture
  printf 'draft\n' >.claude/rules/untracked-draft.md
  run_runner branch
  [ "$status" -eq 0 ]
  has 'WARN  1 untracked file(s) under harness paths are not covered by this run: .claude/rules/untracked-draft.md'
}

@test "a missing origin/main warns, skips the selection and fails a failing check" {
  fixture
  vhf_control 01-files-present "$(missing_manifest_diagnostic)"
  vhf_commit "a manifest failure"
  vhf_git update-ref -d refs/remotes/origin/main
  run_runner branch
  [ "$status" -eq 1 ]
  has 'WARN  refs/remotes/origin/main not found: run git fetch origin main'
  has 'SKIP  bats selected: no merge base with refs/remotes/origin/main (run git fetch origin main)'
  has_line '^FAIL  01-files-present \([0-9]+s\)$'
  has '  reproduce: bash .gaia/tests/distribution/01-files-present.sh'
  lacks 'PRE-EXISTING'
}

@test "no flag, operand or mode skips the run" {
  fixture
  local arguments
  for arguments in "branch --skip" "branch extra" "round --force" "-n" "bogus" "push" "push not-a-sha" ""; do
    # shellcheck disable=SC2086
    run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" $arguments
    [ "$status" -eq 2 ] || { printf 'arguments [%s] exited %s\n' "$arguments" "$status" >&2; return 1; }
  done
  [ ! -s "$VERIFY_FIXTURE_LOG" ]
}

@test "no environment variable skips a failing check" {
  fixture
  vhf_control 01-files-present "$(missing_manifest_diagnostic)"
  vhf_commit "a manifest failure"
  run env SKIP=1 GAIA_SKIP_PREPUSH=1 GAIA_SKIP_VERIFY=1 bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" branch
  [ "$status" -eq 1 ]
  has_line '^FAIL  01-files-present \([0-9]+s\)$'
}

@test "the runner's own suites carry no whole-tree mark and pass the mark guard" {
  local own_suite
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/verify-harness-bats-lib.sh"
  for own_suite in "$BATS_TEST_DIRNAME/verify-harness.bats" "$BATS_TEST_DIRNAME/verify-harness-baseline.bats"; do
    [ -f "$own_suite" ] || { printf 'missing suite %s\n' "$own_suite" >&2; return 1; }
    # shellcheck disable=SC2154 # assigned by the sourced bats lib
    grep -qE "$verify_whole_tree_mark_pattern" "$own_suite" && { printf 'marked: %s\n' "$own_suite" >&2; return 1; }
  done
  [ -f "$REPO_ROOT/.gaia/tests/whole-tree-mark-guard.sh" ] || skip "the whole-tree mark guard is not in this tree"
  # gaia-lint-ignore whole-tree-mark-guard: the operand is not the tracked tree; the guard
  # scans only the two suites named below, and this suite names both
  run bash "$REPO_ROOT/.gaia/tests/whole-tree-mark-guard.sh" --root "$REPO_ROOT" \
    "$BATS_TEST_DIRNAME/verify-harness.bats" "$BATS_TEST_DIRNAME/verify-harness-baseline.bats"
  [ "$status" -eq 0 ]
}
