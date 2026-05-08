#!/usr/bin/env bash
# Stub gh script for forensics harness tests.
#
# When placed on PATH ahead of the real gh binary, this script captures
# all argv to $STUB_GH_CAPTURE_FILE (env var must be set by the caller).
# Exits zero to simulate a successful gh invocation.
#
# Usage (from a bats test):
#   export STUB_GH_CAPTURE_FILE="$BATS_TEST_TMPDIR/gh-argv.txt"
#   export PATH="$(dirname "$BATS_TEST_FILENAME")/lib:$PATH"
#   # (rename this script to "gh" in the lib/ dir, or copy it)
#
# The capture file contains one argv token per line, so the caller can
# assert individual flags:
#   grep -x -- '--repo' "$STUB_GH_CAPTURE_FILE"
#   grep -x -- 'gaia-react/gaia' "$STUB_GH_CAPTURE_FILE"

set -euo pipefail

if [[ -z "${STUB_GH_CAPTURE_FILE:-}" ]]; then
  printf 'stub-gh: STUB_GH_CAPTURE_FILE is not set\n' >&2
  exit 1
fi

# Write each argv token on its own line
printf '%s\n' "$@" >> "$STUB_GH_CAPTURE_FILE"

# Simulate gh issue create stdout: a fake issue URL
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
  printf 'https://github.com/gaia-react/gaia/issues/999\n'
fi

exit 0
