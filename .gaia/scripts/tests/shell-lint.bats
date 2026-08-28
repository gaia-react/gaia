#!/usr/bin/env bats
# Tests for .gaia/tests/shell-lint.sh: the whole-tree guards the deterministic
# local shell gate folds in (.gaia/scripts/lint-*.sh), and the concurrent
# linter harness those passes run alongside. Each detector's own
# correctness is covered by its own suite; this one covers the wiring.
#
# The gate's bash-3.2 parse pass, its `--only` flag, and its argument parsing
# live in the sibling suite .gaia/scripts/tests/shell-lint-bash32.bats, split
# out along the seam the gate itself has -- `--only bash32-parse` names that
# pass precisely because it is separable from everything here.
#
# Why two files rather than one. A shard's cost is the sum of its files'
# runtimes and the sharder assigns whole files, so a suite that outruns the
# group's ~150s floor becomes an irreducible leg that no repartition can
# relieve; one file holding every gate run here reached the 13-minute cap in
# .github/workflows/audit-ci-tests.yml and was cancelled (#1619). Each half now
# sits under that floor. The seam is the gate's own, not an arbitrary cut: a
# test belongs here if it drives the gate's whole run, and there if it drives
# the pass `--only` can select.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no linter
# binary). The rig below is duplicated in the sibling rather than shared:
# this repo has no bats helper-loading precedent, and a helper file would land
# under .gaia/scripts/tests/ carrying an extension that either escapes
# shell-lint's own *.sh discovery or joins the capability oracle's obligated
# surface. Keep the two copies in step.
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
}

teardown() {
  [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  return 0
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

# gate_pass_headers: the name of every pass the gate announces, one per line,
# read off the gate itself. A pass's header is the only thing that says it ran
# whether or not it found anything, and the name is the part of that header
# carrying no interpolation, so it is the part a test can match literally.
#
# The short read is the dangerous case here, not the empty one: a header shape
# the `sed` below cannot read would drop that pass out of the set silently and
# leave a caller asserting over a subset while its name still says every. So the
# marker is counted a second way, by a plain literal match rather than by the
# extraction, and a disagreement returns non-zero instead of a shorter list.
gate_pass_headers() {
  local raw names
  raw="$(grep -c '"--> ' "$GATE")"
  names="$(sed -n 's/^[[:space:]]*echo "--> \([^(:]*\).*/\1/p' "$GATE" | sed 's/[[:space:]]*$//')"
  [ "$(printf '%s\n' "$names" | grep -c .)" -eq "$raw" ] || return 1
  printf '%s\n' "$names"
}


# The gate folds seven whole-tree guard passes into its run, and the class this
# asserts is one of them losing its invocation while its header echo stays.
#
# ONE gate run covers all seven, not one run per guard. A clean-tree run is the
# same execution whichever proof line is grepped afterwards, and it is the
# suite's most expensive single operation -- the folded guards each walk every
# tracked script, and lint-oracle-blind-invocations alone costs ~20s of it. The
# seven separate tests this replaced paid that seven times over for seven greps
# against byte-identical output, which is most of why this file could hold a
# scripts-N shard at the 13-minute cap in .github/workflows/audit-ci-tests.yml
# (#1619). Splitting one execution across seven @test bodies bought no isolation
# either: a run that fails reds every one of them together.
#
# The set is derived from the gate rather than listed here, for the reason the
# --only absence loop below records: a hand-written list falls behind the gate
# silently. The list this replaced had already done so -- it never named
# lint-errexit-source-guard, so that pass could have lost its invocation with
# nothing red. Deriving it means a guard folded in tomorrow is covered the day
# it lands.
#
# SHELLCHECK_LOG is set on this run so the husky dialect assertion rides along
# rather than paying for a run of its own. The stub is a pure always-clean fake
# with the variable unset, and recording argv changes nothing else it does.

@test "the gate invokes every folded guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIR:$PATH" SHELLCHECK_LOG="$STUB_DIR/argv.log" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qF -- "shell-lint passed" <<<"$output"

  # Each folded guard is asserted twice: the gate's own header, which says the
  # gate reached the pass, and the guard's OWN clean line, which is printed by
  # the guard script itself and so appears only if the invocation actually ran.
  # The header alone would survive exactly the edit this test exists to catch.
  local p folded=0
  while IFS= read -r p; do
    case "$p" in lint-*) ;; *) continue ;; esac
    folded=$(( folded + 1 ))
    grep -qF -- "--> $p" <<<"$output"
    grep -qF -- "$p: clean" <<<"$output"
  done < <(gate_pass_headers)

  # A refused or short derivation would make the loop above assert over a subset
  # while its name still says every, so the count is taken a second way, by a
  # literal match on the gate rather than by the extraction, and a disagreement
  # reds here instead of quietly shrinking the set.
  [ "$folded" -eq "$(grep -c 'echo "--> lint-' "$GATE")" ]
  [ "$folded" -gt 1 ]

  # The husky hooks are extensionless, so they match neither the *.sh nor the
  # *.bats discovery glob and need a pass of their own. Husky runs them as
  # `sh -e`, so that pass pins the dialect: shellcheck takes one dialect per
  # invocation, which is why this cannot fold into the *.sh pass.
  grep -qE -- '(^| )-s sh( |$).*\.husky/pre-commit' "$STUB_DIR/argv.log"
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
