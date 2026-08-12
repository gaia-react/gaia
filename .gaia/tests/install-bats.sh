#!/usr/bin/env bash
# install-bats.sh: install a pinned, digest-verified bats-core release, so
# every matrix leg of .github/workflows/audit-ci-tests.yml runs the exact
# same bats binary regardless of which runner picks it up.
#
# An unpinned gate tool returns a different verdict on a different machine --
# ubuntu-latest's `apt-get install bats` and a maintainer's `brew install
# bats` can resolve to different versions, and different bats versions parse
# and report suites differently. `.github/workflows/shell-lint.yml` pins its
# own linter binary for the identical reason. The digest is pinned, not just
# the version, because a GitHub release TAG is mutable: the archive behind an
# unchanged tag can be regenerated with different bytes, so version-only
# pinning would let a changed upstream feed this script something the
# version string alone cannot distinguish. Verify BEFORE extracting, and
# never pipe curl into tar: a pipe streams bytes into the extractor before
# anything can check them.
#
# bats-core v1.14.0 publishes no release ASSET (an empty `assets` list on the
# GitHub release), so this pins the auto-generated source archive at the tag
# instead. GitHub's archive generation has changed before, which changes the
# digest of an otherwise-unchanged tag; a mismatch here fails loudly rather
# than installing something unverified, and the fix is a deliberate re-pin.
#
# To bump: change BATS_VERSION below, then compute the new digest by actually
# downloading the archive (never copy a digest from anywhere, including a
# plan or a commit message):
#   curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v<X.Y.Z>.tar.gz | shasum -a 256
# and paste the result into BATS_SHA256. This script's own pin was derived
# with that exact command against the v1.14.0 tag.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
#
# Usage:
#   bash .gaia/tests/install-bats.sh
#   bash .gaia/tests/install-bats.sh -h | --help
#
# No-op if `bats --version` already reports BATS_VERSION. Otherwise
# downloads the archive, verifies its digest, extracts it, and runs
# bats-core's own install.sh into /usr/local -- sudo when available and not
# already root, otherwise attempted directly (CI is the supported context;
# a non-root, sudo-less machine without write access to /usr/local fails
# here with a permission error).
#
# Exit codes: 0 on install or no-op. Non-zero on download failure, digest
# mismatch, extraction failure, or a post-install version that still does
# not match BATS_VERSION.
set -euo pipefail

BATS_VERSION='1.14.0'
BATS_SHA256='bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177'

usage() {
  printf 'Usage: bash .gaia/tests/install-bats.sh\n'
  printf '       bash .gaia/tests/install-bats.sh -h | --help\n'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *)
    printf 'install-bats: unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

installed_version() {
  bats --version 2>/dev/null | awk '{print $2}'
}

if [ "$(installed_version)" = "$BATS_VERSION" ]; then
  printf 'bats %s already installed\n' "$BATS_VERSION"
  exit 0
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

archive="$tmpdir/bats-core-${BATS_VERSION}.tar.gz"
url="https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz"

# --retry is not decoration here: eleven matrix legs start within seconds of
# each other and every one of them fetches this archive, and codeload answers
# part of that burst with a 503. A single unretried attempt failed four legs
# of the first sharded run. curl treats a 5xx as a transient error, so --retry
# covers exactly this case; --retry-max-time bounds the whole thing well
# inside the leg's own cap rather than trading a flake for a hang.
curl -fsSL --retry 5 --retry-delay 3 --retry-max-time 120 "$url" -o "$archive"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$BATS_SHA256" "$archive" | sha256sum -c -
else
  printf '%s  %s\n' "$BATS_SHA256" "$archive" | shasum -a 256 -c -
fi

tar -xzf "$archive" -C "$tmpdir"
extracted="$tmpdir/bats-core-${BATS_VERSION}"

if [ "$(id -u)" -eq 0 ]; then
  "$extracted/install.sh" /usr/local
elif command -v sudo >/dev/null 2>&1; then
  sudo "$extracted/install.sh" /usr/local
else
  "$extracted/install.sh" /usr/local
fi

if [ "$(installed_version)" != "$BATS_VERSION" ]; then
  printf 'install-bats: post-install version mismatch: expected %s, got %s\n' \
    "$BATS_VERSION" "$(installed_version)" >&2
  exit 1
fi

printf 'bats %s installed\n' "$BATS_VERSION"
