#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/awk-interp-lib.sh, the GAIA_AWK
# resolver, and for its wiring into the guard-awk-lib.sh consumers that source
# it.
#
# Two halves. The first drives the resolver directly: which interpreter it
# picks, and how it identifies one (by asking the binary, never by trusting a
# basename). The second drives the sentinel wiring from a REAL CONSUMER rather
# than from the library alone, because a library-level assertion would pass
# even with a consumer's own case block missing, which is the failure that
# wiring exists to prevent. The consumer roster is derived from the literal
# source line every consumer carries, never hand-listed and never counted
# here, so a consumer added to that closure later is covered without an edit
# here and no cardinal is left behind to go stale.
#
# Run under bash 5 (.claude/rules/bats-assertions.md): `source
# .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/awk-interp-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md --
# `grep -qF` / `grep -qxF` with a herestring, POSIX `[ ]`, and an explicit
# `return 1` ending every failing branch inside a loop, never a `!`-negation
# as a non-final statement.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_SCRIPT="$REPO_ROOT/.gaia/scripts/awk-interp-lib.sh"
  BASH_BIN="$(command -v bash)"
  TEMPORARY_DIRECTORY="$(mktemp -d -t awk-interp-lib-XXXXXX)"

  mkdir "$TEMPORARY_DIRECTORY/mawk-bin"
  cat >"$TEMPORARY_DIRECTORY/mawk-bin/mawk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'mawk 1.3.4 test-stub\nCopyright test\n'; exit 0; }
exit 1
STUB
  chmod +x "$TEMPORARY_DIRECTORY/mawk-bin/mawk"

  cat >"$TEMPORARY_DIRECTORY/bwk-awk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'awk version test-stub-20260101\n'; exit 0; }
exit 1
STUB
  chmod +x "$TEMPORARY_DIRECTORY/bwk-awk"

  cat >"$TEMPORARY_DIRECTORY/busybox-awk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'BusyBox v1.36 awk\n'; exit 0; }
exit 1
STUB
  chmod +x "$TEMPORARY_DIRECTORY/busybox-awk"

  cat >"$TEMPORARY_DIRECTORY/gawk-stub" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'GNU Awk 5.4.1, API 4.1, PMA Avon 8-g1\n'; exit 0; }
exit 1
STUB
  chmod +x "$TEMPORARY_DIRECTORY/gawk-stub"

  # A stub literally named `awk`, identifying as the unsanctioned BusyBox
  # banner: the one fixture that proves identity is decided by asking the
  # binary rather than by trusting the basename, since a basename-keyed
  # resolver would pass this one by accident.
  mkdir "$TEMPORARY_DIRECTORY/named-awk-bin"
  cp "$TEMPORARY_DIRECTORY/busybox-awk" "$TEMPORARY_DIRECTORY/named-awk-bin/awk"

  # Absence of mawk is simulated through the library's own seam, never by
  # curating PATH. Where mawk lives is a property of the host: on macOS it is
  # in the Homebrew prefix, which a fixture can leave off PATH, and on the
  # ubuntu runner it is in /usr/bin, beside the tools the guards under test
  # need on PATH to run at all. A PATH-curating fixture therefore proves
  # absence on macOS and silently proves nothing on the runner, where the
  # resolver keeps finding /usr/bin/mawk and every "no mawk" assertion below
  # passes vacuously or fails for the wrong reason.
  NO_MAWK="$TEMPORARY_DIRECTORY/no-such-mawk-binary"

  # A real, SANCTIONED BWK awk, identified by its banner rather than assumed
  # from its path. /usr/bin/awk is BWK one-true-awk on macOS but is gawk on
  # the ubuntu runner, where the resolver refuses it at status 6 -- correctly,
  # since gawk is the interpreter this plan measured and rejected. The two
  # tests below that need a second REAL interpreter skip where none exists,
  # rather than asserting against whatever /usr/bin/awk happens to be.
  REAL_BWK=""
  if [ -x /usr/bin/awk ]; then
    case "$( /usr/bin/awk --version 2>&1 | head -n1 )" in
      "awk version "*) REAL_BWK=/usr/bin/awk ;;
    esac
  fi
}

teardown() {
  [ -n "${TEMPORARY_DIRECTORY:-}" ] && [ -d "$TEMPORARY_DIRECTORY" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# consumers: every .gaia/scripts/lint-*.sh that carries the literal source
# line guard-awk-lib.sh's consumers all share, one basename per line, sorted.
# Derived from the source rather than hand-listed, so the set this suite
# drives never drifts from the set that actually wires the sentinel.
consumers() {
  grep -l '\. "\$_gaia_guard_library_directory/guard-awk-lib\.sh"' "$REPO_ROOT"/.gaia/scripts/lint-*.sh \
    | xargs -n1 basename \
    | sed 's/\.sh$//' \
    | LC_ALL=C sort
}

# resolve <PATH> [GAIA_AWK] [GAIA_AWK_BWK_PATH]: source the library fresh in a
# subshell and print the three variables it sets. A subshell, never a
# re-source in this shell's own environment, because the library's re-source
# guard makes a second source in the same process a no-op -- exercised on
# purpose by its own dedicated test below, not by accident here.
resolve() {
  local path_value="$1" gaia_awk_value="${2:-}" bwk_value="${3:-}" mawk_value="${4:-}"
  (
    unset -v GAIA_AWK GAIA_AWK_BWK_PATH GAIA_AWK_MAWK_PATH GAIA_AWK_STATUS GAIA_AWK_IDENTITY GAIA_AWK_INTERPRETER_LIBRARY_SOURCED
    PATH="$path_value"
    [ -n "$gaia_awk_value" ] && GAIA_AWK="$gaia_awk_value"
    [ -n "$bwk_value" ] && GAIA_AWK_BWK_PATH="$bwk_value"
    [ -n "$mawk_value" ] && GAIA_AWK_MAWK_PATH="$mawk_value"
    # shellcheck disable=SC1090
    . "$LIBRARY_SCRIPT"
    printf 'GAIA_AWK=%s\nGAIA_AWK_STATUS=%s\nGAIA_AWK_IDENTITY=%s\n' \
      "$GAIA_AWK" "$GAIA_AWK_STATUS" "$GAIA_AWK_IDENTITY"
  )
}

# drive_consumer <guard> <PATH> [GAIA_AWK] [GAIA_AWK_BWK_PATH]: run one
# guard-awk-lib.sh consumer from the repo root under the given environment.
# cwd matters: several of these guards refuse a run from anywhere but the
# repository root before they ever reach the awk resolution this suite is
# testing, so every drive below runs from $REPO_ROOT.
drive_consumer() {
  local guard_name="$1" path_value="$2" gaia_awk_value="${3:-}" bwk_value="${4:-}" mawk_value="${5:-}"
  (
    cd "$REPO_ROOT" || exit 90
    unset -v GAIA_AWK GAIA_AWK_BWK_PATH GAIA_AWK_MAWK_PATH
    export PATH="$path_value"
    # export, not a plain assignment: this spawns a CHILD process below, and
    # an un-exported GAIA_AWK/GAIA_AWK_BWK_PATH is invisible to it, silently
    # falling through to the child's own auto-resolution instead of the pin
    # this drive intends.
    [ -n "$gaia_awk_value" ] && export GAIA_AWK="$gaia_awk_value"
    [ -n "$bwk_value" ] && export GAIA_AWK_BWK_PATH="$bwk_value"
    [ -n "$mawk_value" ] && export GAIA_AWK_MAWK_PATH="$mawk_value"
    "$BASH_BIN" ".gaia/scripts/$guard_name.sh"
  )
}

# ---------------------------------------------------------------------------
# Resolver unit tests
# ---------------------------------------------------------------------------

@test "resolver: mawk on PATH resolves and identifies as mawk" {
  run resolve "$TEMPORARY_DIRECTORY/mawk-bin:/usr/bin:/bin" "" ""
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TEMPORARY_DIRECTORY/mawk-bin/mawk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=0' <<<"$output"
  grep -qF 'GAIA_AWK_IDENTITY=mawk' <<<"$output"
}

@test "resolver: no mawk on PATH falls back to the BWK path and identifies as bwk" {
  run resolve "/usr/bin:/bin" "" "$TEMPORARY_DIRECTORY/bwk-awk" "$NO_MAWK"
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TEMPORARY_DIRECTORY/bwk-awk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=0' <<<"$output"
  grep -qF 'GAIA_AWK_IDENTITY=bwk' <<<"$output"
}

@test "resolver: neither mawk nor a reachable BWK path yields status 5 and an empty GAIA_AWK" {
  run resolve "/usr/bin:/bin" "" "$TEMPORARY_DIRECTORY/does-not-exist" "$NO_MAWK"
  [ "$status" -eq 0 ]
  grep -qxF 'GAIA_AWK=' <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=5' <<<"$output"
}

@test "resolver: an explicit GAIA_AWK naming a nonexistent path yields status 5" {
  run resolve "/usr/bin:/bin" "$TEMPORARY_DIRECTORY/does-not-exist-either" ""
  [ "$status" -eq 0 ]
  grep -qxF 'GAIA_AWK=' <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=5' <<<"$output"
}

@test "resolver: an explicit GAIA_AWK naming an unsanctioned interpreter yields status 6" {
  run resolve "/usr/bin:/bin" "$TEMPORARY_DIRECTORY/busybox-awk" ""
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TEMPORARY_DIRECTORY/busybox-awk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENTITY=BusyBox v1.36 awk' <<<"$output"
}

@test "resolver: gawk is never sanctioned even when named explicitly" {
  run resolve "/usr/bin:/bin" "$TEMPORARY_DIRECTORY/gawk-stub" ""
  [ "$status" -eq 0 ]
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENTITY=GNU Awk' <<<"$output"
}

@test "resolver: a binary literally named awk is identified by its banner, not its name" {
  run resolve "/usr/bin:/bin" "$TEMPORARY_DIRECTORY/named-awk-bin/awk" ""
  [ "$status" -eq 0 ]
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENTITY=BusyBox v1.36 awk' <<<"$output"
}

@test "resolver: sourcing twice in the same shell is a no-op" {
  run bash -c '. "$1"; GAIA_AWK_STATUS=99; . "$1"; printf "%s\n" "$GAIA_AWK_STATUS"' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "99" ]
}

# ---------------------------------------------------------------------------
# Consumer-level sentinel wiring (criteria 1-4 of task-mawk-adoption.md)
# ---------------------------------------------------------------------------

@test "consumers: the derived roster is non-empty" {
  run consumers
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "consumers: every guard-awk-lib.sh consumer refuses at status 6 on an unsanctioned interpreter, and never misreports it as the exit-2 missing-library case" {
  local guard_name
  while IFS= read -r guard_name; do
    run drive_consumer "$guard_name" "/usr/bin:/bin" "$TEMPORARY_DIRECTORY/busybox-awk" ""
    [ "$status" -eq 6 ] || { echo "guard=$guard_name expected status 6, got $status: $output"; return 1; }
    grep -qF 'unsanctioned interpreter' <<<"$output" || { echo "guard=$guard_name missing the unsanctioned-interpreter message: $output"; return 1; }
    grep -qF 'BusyBox v1.36 awk' <<<"$output" || { echo "guard=$guard_name message does not name what it found: $output"; return 1; }
    grep -qF 'guard-awk-lib.sh is missing' <<<"$output" && { echo "guard=$guard_name misreported status 6 as the exit-2 missing-library case: $output"; return 1; }
  done < <(consumers)
  # A `while read` loop's own exit status is the final (EOF-failing) `read`,
  # not the last passing iteration, so an explicit `true` is what makes a
  # loop of all-passing iterations read as a passing test rather than a
  # failing one. Matches the idiom at .gaia/scripts/tests/guard-awk-lib.bats:1234.
  true
}

@test "consumers: every guard-awk-lib.sh consumer refuses at status 5 with no awk at all, distinct from both the status-6 and exit-2 messages" {
  local guard_name
  while IFS= read -r guard_name; do
    run drive_consumer "$guard_name" "/usr/bin:/bin" "" "$TEMPORARY_DIRECTORY/does-not-exist" "$NO_MAWK"
    [ "$status" -eq 5 ] || { echo "guard=$guard_name expected status 5, got $status: $output"; return 1; }
    grep -qF 'no awk interpreter found' <<<"$output" || { echo "guard=$guard_name missing the no-awk message: $output"; return 1; }
    grep -qF 'guard-awk-lib.sh is missing' <<<"$output" && { echo "guard=$guard_name misreported status 5 as the exit-2 missing-library case: $output"; return 1; }
    grep -qF 'unsanctioned interpreter' <<<"$output" && { echo "guard=$guard_name misreported status 5 as the status-6 case: $output"; return 1; }
  done < <(consumers)
  true
}

@test "consumers: the pre-existing exit-2 missing-library refusal is unchanged by the sentinel wiring (sampled on one consumer)" {
  # A non-vacuity sample rather than a per-element drive: this refusal
  # predates this task and this task added no code before it, so one
  # consumer establishes that the new block did not disturb it.
  local scratch="$BATS_TEST_TMPDIR/no-lib"
  mkdir -p "$scratch"
  cp "$REPO_ROOT/.gaia/scripts/lint-errexit-status-read.sh" "$scratch/"
  run "$BASH_BIN" "$scratch/lint-errexit-status-read.sh"
  [ "$status" -eq 2 ]
  grep -qF 'guard-awk-lib.sh is missing beside this script' <<<"$output"
}

# ---------------------------------------------------------------------------
# Graceful degradation and interpreter parity (criteria 6-7)
# ---------------------------------------------------------------------------

@test "consumers: with mawk absent from PATH, every guard-awk-lib.sh consumer degrades to the BWK fallback rather than refusing" {
  local guard_name consumer_output exit_status
  [ -n "$REAL_BWK" ] || skip "this host carries no sanctioned BWK awk to degrade to"
  while IFS= read -r guard_name; do
    # `|| exit_status=$?`, never a bare `exit_status=$?` on the next line: under errexit, a
    # failing command-substitution assignment aborts THIS line, so a
    # non-zero drive would skip the status read entirely rather than let it
    # observe the failure (.gaia/scripts/lint-errexit-status-read.sh's own
    # class, and this suite is not exempt from it).
    exit_status=0
    consumer_output="$(drive_consumer "$guard_name" "/usr/bin:/bin" "" "$REAL_BWK" "$NO_MAWK" 2>&1)" || exit_status=$?
    [ "$exit_status" -eq 0 ] || { echo "guard=$guard_name expected exit 0 under the BWK fallback, got $exit_status: $consumer_output"; return 1; }
    printf '%s' "$consumer_output" | grep -qF 'no awk interpreter found' && { echo "guard=$guard_name refused instead of degrading: $consumer_output"; return 1; }
  done < <(consumers)
  true
}

@test "consumers: stdout is byte-identical under GAIA_AWK pinned to mawk versus pinned to /usr/bin/awk" {
  local guard_name mawk_output bwk_output mawk_exit_status bwk_exit_status
  local real_mawk real_bwk
  real_mawk="$(command -v mawk || true)"
  real_bwk="$REAL_BWK"
  if [ -z "$real_mawk" ] || [ -z "$real_bwk" ]; then
    # Not merely "is /usr/bin/awk executable": on the ubuntu runner it is
    # executable and it is gawk, which the resolver refuses at status 6. The
    # old spelling compared a mawk run against a REFUSAL and read the
    # difference as a parity failure.
    skip "this host carries no sanctioned mawk/BWK pair to compare"
  fi
  while IFS= read -r guard_name; do
    # Same `|| rc=$?` shape as the degradation test above, for the same
    # reason: a bare `mawk_exit_status=$?` on the next line is unreachable the moment
    # either drive exits non-zero under this test body's errexit.
    mawk_exit_status=0
    mawk_output="$(drive_consumer "$guard_name" "/usr/bin:/bin" "$real_mawk" "" 2>/dev/null)" || mawk_exit_status=$?
    bwk_exit_status=0
    bwk_output="$(drive_consumer "$guard_name" "/usr/bin:/bin" "$real_bwk" "" 2>/dev/null)" || bwk_exit_status=$?
    [ "$mawk_exit_status" -eq "$bwk_exit_status" ] || { echo "guard=$guard_name exit status differs: mawk=$mawk_exit_status bwk=$bwk_exit_status"; return 1; }
    [ "$mawk_output" = "$bwk_output" ] || { echo "guard=$guard_name stdout differs between mawk and /usr/bin/awk"; return 1; }
  done < <(consumers)
  true
}
