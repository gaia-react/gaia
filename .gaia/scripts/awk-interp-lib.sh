#!/usr/bin/env bash
# shellcheck shell=bash
# GAIA_AWK_STATUS and GAIA_AWK_IDENT are read by every consumer that sources
# this file (through guard-awk-lib.sh), never by this file itself, so a
# single-file lint view reads both as unused. Disabled file-wide for that
# reason.
# shellcheck disable=SC2034
#
# awk-interp-lib.sh: resolves GAIA_AWK, the interpreter the awk-tokenizer
# guards run under. Sourced by guard-awk-lib.sh, never run directly.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite .gaia/scripts/tests/awk-interp-lib.bats,
# which the `Audit CI Tests` scripts shard runs, and reached transitively by
# every consumer's own suite via .gaia/tests/shell-lint.sh.
# gaia:maintainer-only:end
#
# Why a resolver at all: nothing in this repository pinned an awk
# implementation before this file existed. `.github/workflows/shell-lint.yml`
# installs none, so CI runs ubuntu's default `awk`, which is mawk, while a
# maintainer on macOS runs BWK one-true-awk (`/usr/bin/awk`, version
# 20200816). The awk-heavy guards ran under two different interpreters with
# nothing saying so. This closes that divergence rather than opening one, the
# same way .gaia/scripts/lint-grep-ere-escapes.sh closes the sibling
# divergence between BSD and GNU grep.
#
# Speed is the secondary argument, and it is measured: mawk 1.3.4 runs the
# awk-tokenizer guards roughly 1.7x to 2.1x faster than BWK one-true-awk on
# this workload. gawk is REJECTED on the same measurement: it is slower than
# the macOS default on every guard tested, the opposite of the usual
# expectation and why this needed measuring rather than assuming. gawk is
# never resolved automatically and is not offered as a fallback.
#
# Resolution order: an explicit GAIA_AWK already in the environment wins;
# otherwise the first of `mawk`, then `/usr/bin/awk`, that `command -v`
# resolves. Both ends of that order are overridable by a test-only seam, for
# the reason stated beside them. Identity is decided by ASKING THE BINARY, on every path into
# GAIA_AWK including an explicit override, never by trusting a basename: a
# binary named `awk` is exactly the case that must not pass on its name
# alone. `--version` is the probe because it is the one flag both sanctioned
# interpreters answer legibly: mawk's first banner line opens with
# "mawk ", BWK one-true-awk's opens with "awk version ". Anything else --
# gawk's "GNU Awk ...", a BusyBox stub, silence, an error -- is unsanctioned.
#
# The governed surface is stated closed, in the form
# lint-grep-ere-escapes.sh uses for `sed -E`: GAIA_AWK governs exactly the
# guard-awk-lib.sh closure, this library and its consumers. Nothing else in
# the tree is claimed. `.gaia/scripts/**/*.sh` and `.gaia/tests/**/*.sh` hold
# further command-position awk sites in files that do not source
# guard-awk-lib.sh (verify-audit-roster.sh, check-audit-base-derivation.sh,
# lint-hook-array-guard.sh, audit-respawn-prune.sh, lib/serena-lang.sh,
# shell-lint.sh itself, among others). A substantial minority of them carry
# no .gaia/release-exclude entry and ship, where this resolver must not
# exist at all. Widening the surface to reach them would be a re-decision,
# not a correction: the divergence this file closes was measured on the
# guard-awk-lib.sh consumers specifically, and converting the rest is a
# larger project than adopting this resolver.
#
# The refusal signals through a SENTINEL, GAIA_AWK_STATUS, never through this
# file's own return status. Every consumer sources guard-awk-lib.sh (and so
# this library) inside a `set +e; ...; set -e` bracket whose failure is
# detected only by a `type` probe on a function this library does not
# define, so a non-zero `return` here would be silently discarded and
# misreported as "guard-awk-lib.sh is missing". This file therefore never
# `return`s non-zero and never `exit`s; it always returns 0, having recorded
# what it found in GAIA_AWK_STATUS and GAIA_AWK_IDENT for the consumer to
# check and refuse on in its own block, with its own message.
#
#   GAIA_AWK_STATUS  0 resolved and sanctioned; 5 no awk at all, neither
#                    mawk nor /usr/bin/awk exists; 6 something resolved and
#                    identifies as neither mawk nor BWK awk.
#   GAIA_AWK_IDENT   the interpreter's own --version banner (status 6), the
#                    sanctioned tag `mawk` or `bwk` (status 0), or empty
#                    (status 5). Carried so a consumer's status-6 message can
#                    name what it actually found rather than only that
#                    something was wrong.
#
# bash 3.2 safe: no `mapfile`, no `declare -A`, no `${var^^}`. Sourced, never
# run, and a no-op to source twice.

if [ -n "${GAIA_AWK_INTERP_LIB_SOURCED:-}" ]; then return 0; fi
GAIA_AWK_INTERP_LIB_SOURCED=1

GAIA_AWK_STATUS=0
GAIA_AWK_IDENT=""

# _gaia_awk_identify <path>: print "mawk" or "bwk" and return 0 when the
# banner at that path's `--version` matches one of the two sanctioned
# interpreters; otherwise print the banner verbatim (for the caller's
# status-6 message) and return 1. A prefix match, not equality: mawk's
# banner continues with a version and two copyright lines, and BWK's with a
# bare date, neither of which this resolver needs to parse.
_gaia_awk_identify() {
  local candidate="$1" banner
  banner="$("$candidate" --version 2>&1)"
  case "$banner" in
    "mawk "*) printf 'mawk'; return 0 ;;
    "awk version "*) printf 'bwk'; return 0 ;;
  esac
  printf '%s' "$banner"
  return 1
}

# Two test-only seams, unset in every real invocation, matching the shape
# .gaia/scripts/tests/guard-awk-lib.bats already uses (GAIA_GUARD_LIB,
# GAIA_GUARD_STUB) for the same reason: each end of the resolution order names
# something a bats fixture cannot move out of its own way.
#
# The fallback names a fixed system path, /usr/bin/awk, that a fixture has no
# write access to and must never be given one. The preferred end names a
# command looked up on PATH, and a fixture cannot simulate its ABSENCE by
# curating PATH, because where mawk lives is a property of the host: on macOS
# it sits in the Homebrew prefix, which a fixture can leave out, and on the
# ubuntu runner it sits in /usr/bin beside the very tools the guards under
# test need on PATH to run at all. A fixture that curated PATH would therefore
# prove absence on one host and silently prove nothing on the other, which is
# what these two seams exist to stop.
GAIA_AWK_BWK_PATH="${GAIA_AWK_BWK_PATH:-/usr/bin/awk}"
GAIA_AWK_MAWK_PATH="${GAIA_AWK_MAWK_PATH:-mawk}"

if [ -z "${GAIA_AWK:-}" ]; then
  if command -v "$GAIA_AWK_MAWK_PATH" >/dev/null 2>&1; then
    GAIA_AWK="$(command -v "$GAIA_AWK_MAWK_PATH")"
  elif command -v "$GAIA_AWK_BWK_PATH" >/dev/null 2>&1; then
    GAIA_AWK="$GAIA_AWK_BWK_PATH"
  fi
fi

if [ -z "${GAIA_AWK:-}" ] || ! command -v "$GAIA_AWK" >/dev/null 2>&1; then
  GAIA_AWK_STATUS=5
  GAIA_AWK=""
else
  GAIA_AWK="$(command -v "$GAIA_AWK")"
  if GAIA_AWK_IDENT="$(_gaia_awk_identify "$GAIA_AWK")"; then
    :
  else
    GAIA_AWK_STATUS=6
  fi
fi

export GAIA_AWK
