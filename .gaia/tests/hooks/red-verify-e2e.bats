#!/usr/bin/env bats

# End-to-end wiring test for mechanical TDD RED-verification.
#
# Phase 1 shipped the ledger schema + signal helper; phase 2 shipped the two
# hooks (capture + check); this suite proves they agree on identity end to end
# once both are registered in .claude/settings.json. The unit suites
# (capture-red-observations.bats, red-verify-commit-check.bats) each exercise
# one hook in isolation against canned inputs; this suite drives the REAL
# capture code path to WRITE the ledger and then the REAL check code path to
# READ it, in one tmp repo, so the signal one hook records is the exact signal
# the other recomputes; the central guarantee the gate rests on.
#
# Both hooks run with pwd = the tmp repo, mirroring production's pwd = repo
# root. The shared shell lib (.claude/hooks/lib) and the signal helper
# (.gaia/scripts/red-ledger) are symlinked from the home repo into the tmp repo
# at their repo-relative paths so they resolve from pwd; the symlinked helper
# still resolves `typescript` from the home repo's node_modules via
# createRequire(import.meta.url).
#
# Running real vitest in bats is impractical (the fixtures fall outside vitest's
# include glob, and a real run is slow/online), so the capture step feeds canned
# vitest json through the capture hook's documented RED_CAPTURE_JSON_OVERRIDE
# seam. The signal is NOT canned: the capture hook recomputes it from the staged
# test file's real on-disk body via the helper, and the check hook recomputes it
# the same way; so RED→GREEN proves a genuine signal handshake, and
# edited-after-RED proves the handshake breaks when the body changes.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # Both hooks recompute RED signals via the Node helper, which resolves
  # `typescript` from node_modules; skip where deps aren't installed (e.g. the
  # lean audit-ci-tests CI box) so `bats .gaia/tests/hooks/` stays green there.
  [ -d "$HOME_ROOT/node_modules/typescript" ] || skip "typescript not installed (node-dependent RED suite)"
  CAPTURE_HOOK="$HOME_ROOT/.claude/hooks/capture-red-observations.sh"
  CHECK_HOOK="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
  BARE_TEST_HOOK="$HOME_ROOT/.claude/hooks/block-bare-test.sh"
  LEDGER_REL=".gaia/local/red-ledger/observations.jsonl"

  REPO=$(mktemp -d -t red-e2e-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  # Mirror the repo-relative layout both hooks resolve from pwd.
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  ln -s "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$REPO/.claude/hooks/lib/red-ledger.sh"
  ln -s "$HOME_ROOT/.claude/hooks/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"
  ln -s "$HOME_ROOT/.gaia/scripts/red-ledger" "$REPO/.gaia/scripts/red-ledger"
  # The check hook's determinism carve-out classifies the test file via this
  # helper; symlink it so the carve-out resolves it as in production. The
  # fixtures live on the strict surface (app/utils/**), so the carve-out leaves
  # the RED demand in place and the RED->GREEN handshake is exercised genuinely.
  ln -s "$HOME_ROOT/.gaia/scripts/classifier" "$REPO/.gaia/scripts/classifier"

  # Seed a HEAD commit so HEAD exists; the test files added later are new at HEAD.
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Write file content (creating parent dirs) without staging.
write_file() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
}

# Stage a path already written into the tmp repo.
stage() { git -C "$REPO" add "$1"; }

# Drive the CAPTURE hook for a `pnpm test --run <file>` PostToolUse, feeding
# canned vitest json via the documented override seam. The hook recomputes the
# signal from the file's CURRENT on-disk content, so the ledger line it writes
# carries the genuine current signal. Args: <test-file-rel> <canned-json-abs>.
run_capture() {
  local file_rel="$1" json_abs="$2"
  local payload
  payload=$(jq -nc --arg c "pnpm test --run $file_rel" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:"", stderr:"", interrupted:false}}')
  run bash -c "cd '$REPO' && export RED_CAPTURE_JSON_OVERRIDE='$json_abs'; printf '%s' '$payload' | bash '$CAPTURE_HOOK'"
}

# Drive the CHECK hook for a `git commit` PreToolUse, from inside the tmp repo.
run_check() {
  local cmd="${1:-git commit -m change}"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$CHECK_HOOK'"
}

# Write a canned vitest json reporting ONE failing per-test result. Args:
# <out-abs> <test-file-rel> <fullName>. The `name` field must equal the staged
# file's repo-relative path so the capture hook keys the ledger to that file.
canned_fail_json() {
  local out="$1" file_rel="$2" full="$3"
  jq -nc --arg name "$file_rel" --arg full "$full" '{
    numTotalTestSuites: 1, numFailedTests: 1, numPassedTests: 0,
    numTotalTests: 1, success: false,
    testResults: [{
      name: $name, status: "failed", message: "",
      assertionResults: [
        {title: $full, fullName: $full, status: "failed",
         failureMessages: ["AssertionError: expected 1 to be 2"]}
      ]
    }]
  }' > "$out"
}

ledger_lines() {
  [ -f "$REPO/$LEDGER_REL" ] && wc -l < "$REPO/$LEDGER_REL" | tr -d ' ' || echo 0
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }

# A test whose body the capture hook can hash and the check hook recomputes.
RED_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

# ---------------------------------------------------------------------------
# RED -> GREEN allowed: capture writes a RED for the test at its current body,
# then the (unchanged-body) staged test commits without a deny. Proves the two
# hooks compute the same signal for the same source.
# ---------------------------------------------------------------------------
@test "RED captured then GREEN: commit is allowed" {
  write_file "app/utils/x/index.test.ts" "$RED_TEST"

  json="$REPO/canned.json"
  canned_fail_json "$json" "app/utils/x/index.test.ts" "adds two numbers"
  run_capture "app/utils/x/index.test.ts" "$json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  # Stage the (unchanged) test; its current signal equals the captured one.
  stage "app/utils/x/index.test.ts"
  run_check
  [ "$status" -eq 0 ]
  ! denied
}

# ---------------------------------------------------------------------------
# Never-failed denied: a new passing test with no capture step has no RED.
# ---------------------------------------------------------------------------
@test "never captured: commit is denied" {
  write_file "app/utils/x/index.test.ts" "$RED_TEST"
  stage "app/utils/x/index.test.ts"
  [ "$(ledger_lines)" -eq 0 ]
  run_check
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

# ---------------------------------------------------------------------------
# Edited-after-RED denied: capture a RED, then change the staged test body so
# its current signal no longer matches the recorded one -> deny. Proves the
# content binding invalidates a stale RED.
# ---------------------------------------------------------------------------
@test "edited after RED: commit is denied on signal mismatch" {
  write_file "app/utils/x/index.test.ts" "$RED_TEST"

  json="$REPO/canned.json"
  canned_fail_json "$json" "app/utils/x/index.test.ts" "adds two numbers"
  run_capture "app/utils/x/index.test.ts" "$json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  # Edit the test body (same fullName, different assertion) AFTER its RED.
  write_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(2 + 2).toBe(4);
});
'
  stage "app/utils/x/index.test.ts"
  run_check
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

# ---------------------------------------------------------------------------
# Regression guard: the untouched block-bare-test.sh still blocks a bare
# `pnpm test` (no --run) with exit 2. The RED-verification feature introduced no
# regression; the assertion targets the existing hook directly and needs neither new hook.
# ---------------------------------------------------------------------------
@test "bare pnpm test is still blocked by block-bare-test.sh (exit 2)" {
  payload=$(jq -nc '{tool_name:"Bash", tool_input:{command:"pnpm test"}}')
  run bash -c "printf '%s' '$payload' | bash '$BARE_TEST_HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "pnpm test --run is NOT blocked by block-bare-test.sh" {
  payload=$(jq -nc '{tool_name:"Bash", tool_input:{command:"pnpm test --run app/utils/x/index.test.ts"}}')
  run bash -c "printf '%s' '$payload' | bash '$BARE_TEST_HOOK'"
  [ "$status" -eq 0 ]
}
