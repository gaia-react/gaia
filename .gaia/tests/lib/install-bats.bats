#!/usr/bin/env bats
# Guard suite for .gaia/tests/install-bats.sh's vendored bats archive.
#
# Eleven matrix legs of audit-ci-tests.yml install bats, and they start within
# seconds of each other. While that install fetched the archive from GitHub's
# codeload, the burst drew 503s: an unretried curl failed four legs outright,
# and a fixed 3-second retry delay still lost two more. Exponential backoff
# turned it green at a cost of about 128 seconds of backoff on the worst leg,
# which is a bound on the damage rather than a fix -- a third-party host stayed
# on the pull-request critical path, once per leg, on every run.
#
# The archive is vendored instead, so the install reads a tracked file and the
# network is not involved at all. That removes the flake by construction, and
# it moves the whole risk onto one question this suite exists to answer: is the
# committed blob still the archive the script's digest pin describes? An
# archive that drifts from the pin fails every leg loudly at the digest check;
# an archive missing for the pinned version fails them before that. Neither is
# silent, but both are cheaper to catch here than across eleven red legs.
#
# The two structural assertions (V5, V6) pin the properties the pin exists for,
# which vendoring must not quietly relax: verify before extracting, and never
# stream bytes into the extractor. V4 pins the network's absence, which is the
# one that would otherwise rot silently -- restoring a download re-creates the
# burst while every test still passes and every leg still greens.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/tests/lib/install-bats.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/tests/install-bats.sh"
  BATS_VERSION_PIN="$(sed -n "s/^BATS_VERSION='\(.*\)'\$/\1/p" "$SCRIPT")"
  BATS_SHA256_PIN="$(sed -n "s/^BATS_SHA256='\(.*\)'\$/\1/p" "$SCRIPT")"
  VENDORED="$REPO_ROOT/.gaia/tests/vendor/bats-core-${BATS_VERSION_PIN}.tar.gz"
}

# The sha256 of $1, bare, matching the two-implementation fallback the script
# itself uses: GNU coreutils ships sha256sum, macOS ships shasum only.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Match $1 against the script's executable lines only, failing when it matches.
# Whole-line comments are stripped first: the header documents the re-vendor
# recipe, which names the very commands V4 exists to keep out of the code, so
# scanning the raw file would red on its own instructions.
refute_code_match() {
  grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -nE "$1" && return 1
  return 0
}

@test "V1: the version and digest pins parse out of the script" {
  [ -n "$BATS_VERSION_PIN" ]
  [ -n "$BATS_SHA256_PIN" ]
}

@test "V2: a vendored archive exists for the pinned version" {
  [ -f "$VENDORED" ]
}

@test "V3: the vendored archive's digest matches the script's pin" {
  local actual
  actual="$(file_sha256 "$VENDORED")"
  [ "$actual" = "$BATS_SHA256_PIN" ]
}

@test "V4: the install reaches no network" {
  refute_code_match '(^|[^[:alnum:]_-])(curl|wget|nc|scp)([^[:alnum:]_-]|$)'
}

@test "V5: the digest is checked before the archive is extracted" {
  local verify_line extract_line
  verify_line="$(grep -n 'sha256sum -c -' "$SCRIPT" | head -1 | cut -d: -f1)"
  extract_line="$(grep -n 'tar -xzf' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$verify_line" ]
  [ -n "$extract_line" ]
  [ "$verify_line" -lt "$extract_line" ]
}

@test "V6: nothing is piped into tar" {
  refute_code_match '\|[[:space:]]*(sudo[[:space:]]+)?tar([^[:alnum:]_-]|$)'
}
