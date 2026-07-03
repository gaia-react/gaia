#!/usr/bin/env bash
# Create a second clone of a --with-origin tmp-spec-repo.sh fixture's bare
# origin, for tests that need two independent working trees racing the same
# remote (UAT-002, UAT-003). Prints the clone's path on stdout.
#
# Usage:
#   clone-spec-repo.sh <origin-bare-path>
#
# `git clone` checks out the origin's committed tree verbatim, so the clone
# inherits the lib scripts as real files (not symlinks) with their executable
# bit intact, no separate copy loop needed: the origin already carries
# whatever tmp-spec-repo.sh committed before pushing main.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: clone-spec-repo.sh <origin-bare-path>" >&2
  exit 2
fi

origin="$1"
dir="$(mktemp -d -t gaia-spec-lib-test-clone-XXXXXX)"

git clone --quiet "$origin" "$dir"
git -C "$dir" config user.email "test@example.com"
git -C "$dir" config user.name "Test"
git -C "$dir" config commit.gpgsign false

echo "$dir"
