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
# .github/workflows/audit-ci-tests.yml and was cancelled (#1619). The seam is
# the gate's own, not an arbitrary cut: a test belongs here if it drives the
# gate's whole run, and there if it drives the pass `--only` can select.
#
# The split divides the text and not the cost, which is worth knowing before
# reaching for it again. The whole-tree runs stayed here, so this half remains
# far above that floor while the sibling sits well under it, and the two are
# nowhere near an even division. What the split bought is a smaller unit for
# the sharder to place, not a cheaper one; what keeps this file off the same
# leg as the group's other cost outlier is SCRIPTS_COST_OUTLIERS in
# .gaia/tests/bats-shards.sh, which anchors each of them to a bucket of its own
# rather than letting the byte weight decide. Lowering the number here means
# reducing how many times the tests below re-drive the whole-tree gate.
#
# The shellcheck binary is stubbed with an always-clean, pinned-version fake on
# PATH so the suite runs on the audit-ci-tests box (bats installed, no linter
# binary). The rig below is duplicated in the sibling rather than shared:
# this repo has no bats helper-loading precedent, and a helper file would land
# under .gaia/scripts/tests/ carrying an extension that escapes shell-lint's
# own *.sh discovery.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  GATE="$REPO_ROOT/.gaia/tests/shell-lint.sh"
  # A clean, pinned-version shellcheck stub lets the gate clear both shellcheck
  # passes and reach the array-guard pass without a real shellcheck binary. Its
  # `version:` tracks SHELLCHECK_PIN in shell-lint.sh; a stale stub after a pin
  # bump only makes the gate emit a non-fatal version-drift WARN (stderr, no
  # exit-status change), so this suite still passes -- keep them in sync anyway.
  STUB_DIRECTORY="$(mktemp -d -t shell-lint-stub-XXXXXX)"
  cat > "$STUB_DIRECTORY/shellcheck" <<'STUB'
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
  chmod +x "$STUB_DIRECTORY/shellcheck"
}

teardown() {
  [ -n "$STUB_DIRECTORY" ] && [ -d "$STUB_DIRECTORY" ] && rm -rf "$STUB_DIRECTORY"
  return 0
}

# Derive a rig path the way the gate discovers its file list: NUL-delimited with
# `core.quotepath` off. A plain `git ls-files '*.sh' | head -n 1` disagrees with
# the gate under git's default quoting -- a tracked path carrying a non-ASCII
# byte comes back C-quoted, so SHELLCHECK_FAIL_ON would name a path the pass
# never lints, and the two worker-chunk tests below would assert the gate fails
# closed on a finding that was never planted in either chunk.
# A read loop rather than `head -z`: that flag is GNU-only and absent from
# macOS's head, which is the platform this whole gate exists for.
# `.gaia/scripts/lint-git-path-quoting.sh` now scans `*.bats` too, through the
# shared fixture-versus-execution discriminator, so an executed helper like
# `tracked_sh` above sits on that gate's surface rather than being exempt from
# it.
#
# Args: first|last
tracked_sh() {
  local which_end="$1" tracked_path first="" last=""
  while IFS= read -r -d '' tracked_path; do
    if [ -z "$first" ]; then
      first="$tracked_path"
    fi
    last="$tracked_path"
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

# The gate folds a set of whole-tree guard passes into its run, and the class
# this asserts is one of them losing its invocation while its header echo stays.
# The size of that set is derived below rather than written here, per
# .claude/rules/bats-assertions.md: a cardinal in the prose rots the next time
# the gate gains a guard, and the rotted number reads as a checked assertion.
#
# ONE gate run covers the whole set, not one run per guard. A clean-tree run is the
# same execution whichever proof line is grepped afterwards, and it is the
# suite's most expensive single operation -- the folded guards each walk every
# tracked script, and together they cost most of it. The
# seven separate tests this replaced paid that seven times over for seven greps
# against byte-identical output, which is most of why this file could hold a
# scripts-N shard at the 13-minute cap in .github/workflows/audit-ci-tests.yml
# (#1619). Splitting one execution across seven @test bodies bought no isolation
# either: a run that fails reds every one of them together.
#
# The set is derived from the gate rather than listed here, for the reason the
# --only absence loop below records: a hand-written list falls behind the gate
# silently, and a pass it never named could lose its invocation with nothing
# red. Deriving it means a guard folded in tomorrow is covered the day
# it lands.
#
# SHELLCHECK_LOG is set on this run so the git hooks dialect assertion rides along
# rather than paying for a run of its own. The stub is a pure always-clean fake
# with the variable unset, and recording argv changes nothing else it does.

@test "the gate invokes every folded guard pass and stays green on a clean tree" {
  run env PATH="$STUB_DIRECTORY:$PATH" SHELLCHECK_LOG="$STUB_DIRECTORY/argv.log" bash "$GATE"
  [ "$status" -eq 0 ]
  grep -qF -- "shell-lint passed" <<<"$output"

  # Each folded guard is asserted twice: the gate's own header, which says the
  # gate reached the pass, and the guard's OWN clean line, which is printed by
  # the guard script itself and so appears only if the invocation actually ran.
  # The header alone would survive exactly the edit this test exists to catch.
  local pass_name folded=0
  while IFS= read -r pass_name; do
    case "$pass_name" in lint-*) ;; *) continue ;; esac
    folded=$(( folded + 1 ))
    grep -qF -- "--> $pass_name" <<<"$output"
    grep -qF -- "$pass_name: clean" <<<"$output"
  done < <(gate_pass_headers)

  # A refused or short derivation would make the loop above assert over a subset
  # while its name still says every, so the count is taken a second way, by a
  # literal match on the gate rather than by the extraction, and a disagreement
  # reds here instead of quietly shrinking the set.
  [ "$folded" -eq "$(grep -c 'echo "--> lint-' "$GATE")" ]
  [ "$folded" -gt 1 ]

  # The git hooks are extensionless, so they match neither the *.sh nor the
  # *.bats discovery glob and need a pass of their own. Git runs each one
  # directly and the hooks are POSIX sh by convention, so that pass pins the
  # dialect: shellcheck takes one dialect per invocation, which is why this
  # cannot fold into the *.sh pass.
  grep -qE -- '(^| )-s sh( |$).*\.githooks/pre-commit' "$STUB_DIRECTORY/argv.log"
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
  run env PATH="$STUB_DIRECTORY:$PATH" SHELLCHECK_FAIL_ON="$first_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  # The failing worker's buffered log has to replay too, or the gate reds
  # without ever naming what is broken.
  grep -qF -- "In $first_sh line 1:" <<<"$output"
}

@test "shell-lint fails closed on a finding in the LAST worker's chunk" {
  last_sh="$(tracked_sh last)"
  [ -n "$last_sh" ]
  run env PATH="$STUB_DIRECTORY:$PATH" SHELLCHECK_FAIL_ON="$last_sh" bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "In $last_sh line 1:" <<<"$output"
}

# stub_all_guards overrides EVERY folded guard with a trivial stub that emits
# only its own "<name>: clean" line, on the stream the real guard would have
# used, so a test that fails one guard does not pay for a real tree scan per
# guard to prove every other guard still ran and reports under its own
# banner.
#
# The stdout/stderr split below is fixture data reproduced from the real
# guard scripts (the ones named here are those printing their clean line via
# a bare `printf`, no `>&2`) rather than derived live -- a stub rig is
# allowed to assume the shape it stands in for. No count here: the list goes
# stale by gaining a member, and a cardinal beside it would only go stale
# twice. Re-derive it with `grep -n ': clean' .gaia/scripts/lint-*.sh` when a
# guard is folded in.
#
# Prints one `SHELL_LINT_GUARD_OVERRIDE_<slug>=<path>` line per folded guard,
# meant to be read into an array and passed to `env`; a caller needing a
# guard's real detection logic overrides that one slug again afterward, and
# the later assignment for the same name wins.
#
# Args: <directory to write stub scripts into>
stub_all_guards() {
  local directory="$1" stdout_guards pass_name script stream_redirect variable_name
  stdout_guards="lint-hook-jq-availability"
  while IFS= read -r pass_name; do
    case "$pass_name" in lint-*) ;; *) continue ;; esac
    script="$directory/$pass_name.stub.sh"
    case " $stdout_guards " in
      *" $pass_name "*) stream_redirect="" ;;
      *) stream_redirect=" >&2" ;;
    esac
    cat > "$script" <<EOF
#!/usr/bin/env bash
printf '%s: clean\n' "$pass_name"$stream_redirect
exit 0
EOF
    chmod +x "$script"
    variable_name="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$pass_name" | tr '-' '_')"
    printf '%s=%s\n' "$variable_name" "$script"
  done < <(gate_pass_headers)
}

# The settings drift pass is not a lint-* guard, so the loops above never drive
# it. This drives it into its failing state through the same override seam.
@test "a failing settings drift check fails the gate" {
  local stub="$STUB_DIRECTORY/drift-fail.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: drift" >&2
exit 1
STUB
  chmod +x "$stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIRECTORY")
  overrides+=("SHELL_LINT_GUARD_OVERRIDE_check_settings_drift=$stub")
  run env PATH="$STUB_DIRECTORY:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "--> check-settings-drift" <<<"$output"
  grep -qF -- "stub failure: drift" <<<"$output"
  grep -qF -- "shell-lint FAILED" <<<"$output"
}

# The retired-path pass is not a lint-* guard either, so it gets the same
# drive-into-failure test through the override seam.
@test "a failing retired-path check fails the gate" {
  local stub="$STUB_DIRECTORY/retired-fail.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: retired" >&2
exit 1
STUB
  chmod +x "$stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIRECTORY")
  overrides+=("SHELL_LINT_GUARD_OVERRIDE_check_retired_paths=$stub")
  run env PATH="$STUB_DIRECTORY:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "--> check-retired-paths" <<<"$output"
  grep -qF -- "stub failure: retired" <<<"$output"
  grep -qF -- "shell-lint FAILED" <<<"$output"
}

@test "a failing guard fails the gate and every other guard still runs" {
  local first override_variable_name stub
  first="$(gate_pass_headers | grep '^lint-' | sed -n '1p')"
  [ -n "$first" ]
  override_variable_name="SHELL_LINT_GUARD_OVERRIDE_$(printf '%s' "$first" | tr '-' '_')"
  stub="$STUB_DIRECTORY/guard-fail.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "stub failure: guard" >&2
exit 1
STUB
  chmod +x "$stub"
  local overrides=() line
  while IFS= read -r line; do
    overrides+=("$line")
  done < <(stub_all_guards "$STUB_DIRECTORY")
  overrides+=("$override_variable_name=$stub")
  run env PATH="$STUB_DIRECTORY:$PATH" ${overrides[@]+"${overrides[@]}"} bash "$GATE"
  [ "$status" -eq 1 ]
  grep -qF -- "shell-lint FAILED" <<<"$output"
  grep -qF -- "stub failure: guard" <<<"$output"
  # Every guard here is running from an override, and the gate owes a notice
  # naming each one. Without this, deleting that notice leaves the whole suite
  # green while a substituted guard becomes invisible again: the run reports
  # the same banners, the same exit status and the same verdict as a real one,
  # and the only residue is one `: clean` line missing, which nothing looks
  # for. The sibling SHELL_LINT_BASH32 seam is pinned the same
  # way, by asserting the substituted interpreter it names.
  grep -qF -- "$first: GUARD OVERRIDE" <<<"$output"
  local pass_name
  while IFS= read -r pass_name; do
    case "$pass_name" in lint-*) ;; *) continue ;; esac
    [ "$pass_name" = "$first" ] && continue
    grep -qF -- "--> $pass_name" <<<"$output"
  done < <(gate_pass_headers)
}
