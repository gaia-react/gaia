#!/usr/bin/env bats
# UAT-016: operational, OS-level enforcement of the sandbox.
#
# MANUAL / gated (RT-001): this exercises real OS-level enforcement, not a
# simulation. It only makes sense run from inside a Bash call that is itself
# already sandboxed, i.e. after a human has run `gaia sandbox apply`,
# restarted Claude Code so the enabled sandbox takes effect, and is now
# invoking this suite from within that sandboxed session with
# GAIA_SANDBOX_CAPABLE=1 exported to attest to the setup. CI here is
# ubuntu-latest without bubblewrap/socat and cannot provide any of that, so
# this test MUST report SKIPPED here, never a vacuous pass.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

@test "UAT-016: sandboxed Bash blocks an unrecognized .env reader and a non-allowlisted network call" {
  [ "${GAIA_SANDBOX_CAPABLE:-}" = "1" ] || skip "requires a sandbox-capable runner (set GAIA_SANDBOX_CAPABLE=1 after applying and restarting into an enabled sandbox)"
  [ -f "$REPO_ROOT/.env" ] || skip "no .env present at repo root to probe"

  # Unrecognized reader: a Node script opening .env directly bypasses GAIA's
  # Read/Edit tool-level deny; only the sandbox's merged deny (which reaches
  # subprocesses of sandboxed Bash) can still block it.
  run node -e "require('fs').readFileSync('$REPO_ROOT/.env')"
  [ "$status" -ne 0 ] || return 1

  # Non-allowlisted network call: the minimal seed only allowlists the
  # registry host, so a call to an unrelated host must fail closed.
  run curl -s -o /dev/null -w '%{http_code}' --max-time 3 https://example.com
  [ "$status" -ne 0 ] || return 1
}
