#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/awk-interp-lib.sh, the GAIA_AWK
# resolver, and for its wiring into the eight guard-awk-lib.sh consumers that
# source it.
#
# Two halves. The first drives the resolver directly: which interpreter it
# picks, and how it identifies one (by asking the binary, never by trusting a
# basename). The second drives the sentinel wiring from a REAL CONSUMER rather
# than from the library alone: a library-level assertion would pass even with
# a consumer's own case block missing, which is the exact failure FC-5 of
# PLAN-021's README exists to prevent. The consumer roster is derived from the
# literal source line every consumer carries, never hand-listed, so a ninth
# consumer added later is covered without an edit here.
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
  LIB="$REPO_ROOT/.gaia/scripts/awk-interp-lib.sh"
  BASH_BIN="$(command -v bash)"
  TMP="$(mktemp -d -t awk-interp-lib-XXXXXX)"

  mkdir "$TMP/mawk-bin"
  cat >"$TMP/mawk-bin/mawk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'mawk 1.3.4 test-stub\nCopyright test\n'; exit 0; }
exit 1
STUB
  chmod +x "$TMP/mawk-bin/mawk"

  cat >"$TMP/bwk-awk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'awk version test-stub-20260101\n'; exit 0; }
exit 1
STUB
  chmod +x "$TMP/bwk-awk"

  cat >"$TMP/busybox-awk" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'BusyBox v1.36 awk\n'; exit 0; }
exit 1
STUB
  chmod +x "$TMP/busybox-awk"

  cat >"$TMP/gawk-stub" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { printf 'GNU Awk 5.4.1, API 4.1, PMA Avon 8-g1\n'; exit 0; }
exit 1
STUB
  chmod +x "$TMP/gawk-stub"

  # A stub literally named `awk`, identifying as the unsanctioned BusyBox
  # banner: the one fixture that proves identity is decided by asking the
  # binary rather than by trusting the basename, since a basename-keyed
  # resolver would pass this one by accident.
  mkdir "$TMP/named-awk-bin"
  cp "$TMP/busybox-awk" "$TMP/named-awk-bin/awk"

  # A curated PATH that cannot resolve `mawk` (nor the real /usr/bin/awk,
  # once GAIA_AWK_BWK_PATH is overridden away from it) while still resolving
  # every external tool the guards under test actually shell out to. `git`
  # lives beside `mawk` in this host's Homebrew prefix, so excluding that
  # whole prefix would also hide git; a symlink recovers git alone.
  mkdir "$TMP/no-mawk-bin"
  ln -s "$(command -v git)" "$TMP/no-mawk-bin/git"
  NO_MAWK_PATH="$TMP/no-mawk-bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# consumers: every .gaia/scripts/lint-*.sh that carries the literal source
# line guard-awk-lib.sh's consumers all share, one basename per line, sorted.
# Derived from the source rather than hand-listed, so the set this suite
# drives never drifts from the set that actually wires the sentinel.
consumers() {
  grep -l '\. "\$_gaia_guard_lib_dir/guard-awk-lib\.sh"' "$REPO_ROOT"/.gaia/scripts/lint-*.sh \
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
  local path_val="$1" gaia_awk_val="${2:-}" bwk_val="${3:-}"
  (
    unset -v GAIA_AWK GAIA_AWK_BWK_PATH GAIA_AWK_STATUS GAIA_AWK_IDENT GAIA_AWK_INTERP_LIB_SOURCED
    PATH="$path_val"
    [ -n "$gaia_awk_val" ] && GAIA_AWK="$gaia_awk_val"
    [ -n "$bwk_val" ] && GAIA_AWK_BWK_PATH="$bwk_val"
    # shellcheck disable=SC1090
    . "$LIB"
    printf 'GAIA_AWK=%s\nGAIA_AWK_STATUS=%s\nGAIA_AWK_IDENT=%s\n' \
      "$GAIA_AWK" "$GAIA_AWK_STATUS" "$GAIA_AWK_IDENT"
  )
}

# drive_consumer <guard> <PATH> [GAIA_AWK] [GAIA_AWK_BWK_PATH]: run one
# guard-awk-lib.sh consumer from the repo root under the given environment.
# cwd matters: several of these guards refuse a run from anywhere but the
# repository root before they ever reach the awk resolution this suite is
# testing, so every drive below runs from $REPO_ROOT.
drive_consumer() {
  local g="$1" path_val="$2" gaia_awk_val="${3:-}" bwk_val="${4:-}"
  (
    cd "$REPO_ROOT" || exit 90
    unset -v GAIA_AWK GAIA_AWK_BWK_PATH
    export PATH="$path_val"
    # export, not a plain assignment: this spawns a CHILD process below, and
    # an un-exported GAIA_AWK/GAIA_AWK_BWK_PATH is invisible to it, silently
    # falling through to the child's own auto-resolution instead of the pin
    # this drive intends.
    [ -n "$gaia_awk_val" ] && export GAIA_AWK="$gaia_awk_val"
    [ -n "$bwk_val" ] && export GAIA_AWK_BWK_PATH="$bwk_val"
    "$BASH_BIN" ".gaia/scripts/$g.sh"
  )
}

# ---------------------------------------------------------------------------
# Resolver unit tests
# ---------------------------------------------------------------------------

@test "resolver: mawk on PATH resolves and identifies as mawk" {
  run resolve "$TMP/mawk-bin:/usr/bin:/bin" "" ""
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TMP/mawk-bin/mawk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=0' <<<"$output"
  grep -qF 'GAIA_AWK_IDENT=mawk' <<<"$output"
}

@test "resolver: no mawk on PATH falls back to the BWK path and identifies as bwk" {
  run resolve "/usr/bin:/bin" "" "$TMP/bwk-awk"
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TMP/bwk-awk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=0' <<<"$output"
  grep -qF 'GAIA_AWK_IDENT=bwk' <<<"$output"
}

@test "resolver: neither mawk nor a reachable BWK path yields status 5 and an empty GAIA_AWK" {
  run resolve "/usr/bin:/bin" "" "$TMP/does-not-exist"
  [ "$status" -eq 0 ]
  grep -qxF 'GAIA_AWK=' <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=5' <<<"$output"
}

@test "resolver: an explicit GAIA_AWK naming a nonexistent path yields status 5" {
  run resolve "/usr/bin:/bin" "$TMP/does-not-exist-either" ""
  [ "$status" -eq 0 ]
  grep -qxF 'GAIA_AWK=' <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=5' <<<"$output"
}

@test "resolver: an explicit GAIA_AWK naming an unsanctioned interpreter yields status 6" {
  run resolve "/usr/bin:/bin" "$TMP/busybox-awk" ""
  [ "$status" -eq 0 ]
  grep -qF "GAIA_AWK=$TMP/busybox-awk" <<<"$output"
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENT=BusyBox v1.36 awk' <<<"$output"
}

@test "resolver: gawk is never sanctioned even when named explicitly" {
  run resolve "/usr/bin:/bin" "$TMP/gawk-stub" ""
  [ "$status" -eq 0 ]
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENT=GNU Awk' <<<"$output"
}

@test "resolver: a binary literally named awk is identified by its banner, not its name" {
  run resolve "/usr/bin:/bin" "$TMP/named-awk-bin/awk" ""
  [ "$status" -eq 0 ]
  grep -qF 'GAIA_AWK_STATUS=6' <<<"$output"
  grep -qF 'GAIA_AWK_IDENT=BusyBox v1.36 awk' <<<"$output"
}

@test "resolver: sourcing twice in the same shell is a no-op" {
  run bash -c '. "$1"; GAIA_AWK_STATUS=99; . "$1"; printf "%s\n" "$GAIA_AWK_STATUS"' _ "$LIB"
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
  local g
  while IFS= read -r g; do
    run drive_consumer "$g" "/usr/bin:/bin" "$TMP/busybox-awk" ""
    [ "$status" -eq 6 ] || { echo "guard=$g expected status 6, got $status: $output"; return 1; }
    grep -qF 'unsanctioned interpreter' <<<"$output" || { echo "guard=$g missing the unsanctioned-interpreter message: $output"; return 1; }
    grep -qF 'BusyBox v1.36 awk' <<<"$output" || { echo "guard=$g message does not name what it found: $output"; return 1; }
    grep -qF 'guard-awk-lib.sh is missing' <<<"$output" && { echo "guard=$g misreported status 6 as the exit-2 missing-library case: $output"; return 1; }
  done < <(consumers)
  # A `while read` loop's own exit status is the final (EOF-failing) `read`,
  # not the last passing iteration, so an explicit `true` is what makes a
  # loop of all-passing iterations read as a passing test rather than a
  # failing one. Matches the idiom at .gaia/scripts/tests/guard-awk-lib.bats:1234.
  true
}

@test "consumers: every guard-awk-lib.sh consumer refuses at status 5 with no awk at all, distinct from both the status-6 and exit-2 messages" {
  local g
  while IFS= read -r g; do
    run drive_consumer "$g" "$NO_MAWK_PATH" "" "$TMP/does-not-exist"
    [ "$status" -eq 5 ] || { echo "guard=$g expected status 5, got $status: $output"; return 1; }
    grep -qF 'no awk interpreter found' <<<"$output" || { echo "guard=$g missing the no-awk message: $output"; return 1; }
    grep -qF 'guard-awk-lib.sh is missing' <<<"$output" && { echo "guard=$g misreported status 5 as the exit-2 missing-library case: $output"; return 1; }
    grep -qF 'unsanctioned interpreter' <<<"$output" && { echo "guard=$g misreported status 5 as the status-6 case: $output"; return 1; }
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
  local g out rc
  while IFS= read -r g; do
    # `|| rc=$?`, never a bare `rc=$?` on the next line: under errexit, a
    # failing command-substitution assignment aborts THIS line, so a
    # non-zero drive would skip the status read entirely rather than let it
    # observe the failure (.gaia/scripts/lint-errexit-status-read.sh's own
    # class, and this suite is not exempt from it).
    rc=0
    out="$(drive_consumer "$g" "$NO_MAWK_PATH" "" "" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || { echo "guard=$g expected exit 0 under the BWK fallback, got $rc: $out"; return 1; }
    printf '%s' "$out" | grep -qF 'no awk interpreter found' && { echo "guard=$g refused instead of degrading: $out"; return 1; }
  done < <(consumers)
  true
}

@test "consumers: stdout is byte-identical under GAIA_AWK pinned to mawk versus pinned to /usr/bin/awk" {
  local g out_mawk out_bwk rc_mawk rc_bwk
  local real_mawk real_bwk
  real_mawk="$(command -v mawk || true)"
  real_bwk="/usr/bin/awk"
  if [ -z "$real_mawk" ] || [ ! -x "$real_bwk" ]; then
    skip "this host carries neither a real mawk nor a real /usr/bin/awk to compare"
  fi
  while IFS= read -r g; do
    # Same `|| rc=$?` shape as the degradation test above, for the same
    # reason: a bare `rc_mawk=$?` on the next line is unreachable the moment
    # either drive exits non-zero under this test body's errexit.
    rc_mawk=0
    out_mawk="$(drive_consumer "$g" "/usr/bin:/bin" "$real_mawk" "" 2>/dev/null)" || rc_mawk=$?
    rc_bwk=0
    out_bwk="$(drive_consumer "$g" "/usr/bin:/bin" "$real_bwk" "" 2>/dev/null)" || rc_bwk=$?
    [ "$rc_mawk" -eq "$rc_bwk" ] || { echo "guard=$g exit status differs: mawk=$rc_mawk bwk=$rc_bwk"; return 1; }
    [ "$out_mawk" = "$out_bwk" ] || { echo "guard=$g stdout differs between mawk and /usr/bin/awk"; return 1; }
  done < <(consumers)
  true
}
