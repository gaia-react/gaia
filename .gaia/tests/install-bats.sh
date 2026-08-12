#!/usr/bin/env bash
# install-bats.sh: install a pinned, digest-verified bats-core release from a
# vendored archive, so every matrix leg of
# .github/workflows/audit-ci-tests.yml runs the exact same bats binary
# regardless of which runner picks it up.
#
# An unpinned gate tool returns a different verdict on a different machine --
# ubuntu-latest's `apt-get install bats` and a maintainer's `brew install
# bats` can resolve to different versions, and different bats versions parse
# and report suites differently. `.github/workflows/shell-lint.yml` pins its
# own linter binary for the identical reason. The digest is pinned, not just
# the version, because a GitHub release TAG is mutable: the archive behind an
# unchanged tag can be regenerated with different bytes, so a bump pinning
# only the version cannot say which bytes it reviewed. With the archive
# tracked, the check below is what catches a corrupted or swapped blob before
# anything is extracted. Verify BEFORE extracting, and never pipe a stream
# into tar: a pipe hands bytes to the extractor before anything can check
# them.
#
# bats-core v1.14.0 publishes no release ASSET (an empty `assets` list on the
# GitHub release), so the pin is the auto-generated source archive at the tag.
#
# The archive is a tracked file rather than a download because eleven matrix
# legs install within seconds of each other, and codeload answers part of that
# burst with 503s -- measured, not theorized: an unretried fetch failed four
# legs, and a fixed 3-second retry delay still lost two more, because the
# rejection outlasts a 15-second window. Exponential backoff turns it green
# but leaves a third-party host on the pull-request critical path once per
# leg, and the worst leg spent about 128 seconds inside that backoff,
# comparable to an entire clean shard. Reading a tracked file removes the host
# rather than absorbing it. There is deliberately no fallback download: a
# missing archive fails loudly here, where falling back to the network would
# restore the burst with nothing reporting that it had.
#
# To bump: change BATS_VERSION below, then download the archive and derive its
# digest by hand (never copy a digest from anywhere, including a plan or a
# commit message):
#   curl -fsSL -o .gaia/tests/vendor/bats-core-<X.Y.Z>.tar.gz \
#     https://github.com/bats-core/bats-core/archive/refs/tags/v<X.Y.Z>.tar.gz
#   shasum -a 256 .gaia/tests/vendor/bats-core-<X.Y.Z>.tar.gz
# Paste that digest into BATS_SHA256, commit the new archive, and delete the
# one it replaces. `.gaia/tests/lib/install-bats.bats` reds on a bump that
# skips any of those steps.
#
# Derive the digest from that fresh download and nowhere else, because no
# check in the tree can catch it if you do not. The archive and the pin are
# committed together and are therefore self-consistent by construction: a
# wrong blob committed beside a digest taken from it satisfies the check
# below, the guard suite, and every other check here. Upstream is the only
# thing that disagrees, which is why the recipe above starts by asking it.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so neither this script nor the vendored archive
# reaches an adopter.
#
# Usage:
#   bash .gaia/tests/install-bats.sh
#   bash .gaia/tests/install-bats.sh -h | --help
#
# No-op if `bats --version` already reports BATS_VERSION. Otherwise verifies
# the vendored archive's digest, extracts it, and runs bats-core's own
# install.sh into /usr/local -- sudo when available and not already root,
# otherwise attempted directly (CI is the supported context; a non-root,
# sudo-less machine without write access to /usr/local fails here with a
# permission error).
#
# Exit codes: 0 on install or no-op. Non-zero on a missing vendored archive,
# digest mismatch, extraction failure, or a post-install version that still
# does not match BATS_VERSION.
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

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
archive="$REPO_ROOT/.gaia/tests/vendor/bats-core-${BATS_VERSION}.tar.gz"

if [ ! -f "$archive" ]; then
  printf 'install-bats: no vendored archive for bats %s at %s\n' \
    "$BATS_VERSION" "$archive" >&2
  printf 'install-bats: a BATS_VERSION bump must commit the matching archive; see the bump recipe in this header.\n' >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

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

# The version probe above ran `bats` before the install, and a successful
# lookup enters bash's command hash table. On a machine that already carries a
# different bats -- a maintainer's laptop, not the CI runner -- the check below
# would otherwise re-run the OLD binary and report a mismatch against an
# install that actually succeeded.
hash -r 2>/dev/null || true

if [ "$(installed_version)" != "$BATS_VERSION" ]; then
  printf 'install-bats: post-install version mismatch: expected %s, got %s\n' \
    "$BATS_VERSION" "$(installed_version)" >&2
  exit 1
fi

printf 'bats %s installed\n' "$BATS_VERSION"
