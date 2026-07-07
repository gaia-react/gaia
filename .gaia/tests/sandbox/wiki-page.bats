#!/usr/bin/env bats
# UAT-010: conformance greps against wiki/concepts/OS Sandbox.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  WIKI="$REPO_ROOT/wiki/concepts/OS Sandbox.md"
}

@test "UAT-010/FC-4: wiki page contains the canonical honesty phrase" {
  [ -f "$WIKI" ]
  grep -qF 'enabling the sandbox alone does not protect .env' "$WIKI"
}

@test "UAT-010: wiki page names the official sandboxing docs link (literal, unconditional)" {
  grep -qF 'code.claude.com/docs/en/sandboxing.md' "$WIKI"
}

@test "UAT-010: the official sandboxing docs link resolves 2xx/3xx (network-gated, skips with no connectivity)" {
  grep -qF 'code.claude.com/docs/en/sandboxing.md' "$WIKI"

  command -v curl >/dev/null 2>&1 || skip "curl not available on this runner"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -L \
    'https://code.claude.com/docs/en/sandboxing.md' 2>/dev/null) || http_code=""
  [ -n "$http_code" ] || skip "no network connectivity to code.claude.com"

  case "$http_code" in
    2??|3??) : ;;
    *) return 1 ;;
  esac
}

@test "UAT-010/FC-4: wiki page does not name the raw config keys or the bubblewrap install command" {
  grep -qF 'sandbox.excludedCommands' "$WIKI" && return 1
  grep -qF 'sandbox.network.allowedDomains' "$WIKI" && return 1
  grep -qF 'apt-get install bubblewrap' "$WIKI" && return 1
  return 0
}

@test "UAT-010: wiki page contains no SPEC or UAT working-doc identifiers" {
  grep -nE 'SPEC-[0-9]+' "$WIKI" && return 1
  grep -nE 'UAT-[0-9]+' "$WIKI" && return 1
  return 0
}

@test "DP-003/UAT-010: wiki page contains no platform x capability table row, in any orientation" {
  # A conventional matrix puts one platform per row (e.g. "| macOS | Seatbelt
  # | ready |"); this must be caught the same as a wide row naming several
  # platforms on one line. Reject any |-delimited line that pairs a platform
  # name with a capability/status/mechanism token, regardless of how many
  # platforms it names. Prose sentences naming platforms (no pipes) are fine.
  grep -nE '\|.*\b(macOS|Linux|Windows|WSL)\b.*\|.*\b(ready|needs-deps|unsupported|Seatbelt|bubblewrap)\b' "$WIKI" && return 1
  return 0
}
