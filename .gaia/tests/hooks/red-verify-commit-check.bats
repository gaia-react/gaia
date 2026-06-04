#!/usr/bin/env bats

# Tests for .claude/hooks/red-verify-commit-check.sh, the commit-gate half of
# mechanical TDD RED-verification.
#
# The hook denies `git commit` when a new-at-HEAD test that now passes has no
# matching valid RED on record in .gaia/local/red-ledger/observations.jsonl.
# Edits/renames/refactors of tests already present at HEAD are out of scope and
# never demand a RED. The hook never re-runs tests; it is a ledger lookup plus
# a signal recompute via the shared helper.
#
# Each test builds a tmp git repo with a HEAD commit plus a staged change,
# seeds the ledger by writing JSONL directly (computing the real signal with
# the same helper the hook uses, so the match is exact), and runs the hook with
# synthetic PreToolUse JSON on stdin. The hook always exits 0; allow vs deny is
# carried in stdout: a deny emits `"permissionDecision": "deny"`, an allow
# emits nothing.
#
# The hook runs with pwd = the tmp repo so bare `git` and the helper's relative
# disk reads resolve against the staged change. In production the hook runs
# with pwd = the project root, where .claude/hooks/lib (the shared shell lib)
# and .gaia/scripts/red-ledger (the signal helper) live and resolve from pwd.
# To reproduce that pwd=root invariant, the setup symlinks those two trees from
# the home repo into the tmp repo at their repo-relative paths. The symlinked
# helper still resolves `typescript` from the home repo's node_modules via
# createRequire(import.meta.url), so the signal recompute works.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABS="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"

  REPO=$(mktemp -d -t red-verify-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  # Mirror the repo-relative layout the hook resolves from pwd.
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  ln -s "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$REPO/.claude/hooks/lib/red-ledger.sh"
  ln -s "$HOME_ROOT/.claude/hooks/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"
  ln -s "$HOME_ROOT/.gaia/scripts/red-ledger" "$REPO/.gaia/scripts/red-ledger"

  # Seed a HEAD commit with a non-test file so HEAD exists. The symlinks are
  # untracked working-tree entries; they never enter the staged diff.
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Write file content (creating parent dirs) and stage it in the tmp repo.
stage_file() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
  git -C "$REPO" add "$path"
}

# Commit a file at HEAD (so a later staged edit is an EXISTING-test edit, not
# a new-at-HEAD test). Leaves a clean tree.
commit_file_at_head() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit --quiet -m "add $path"
}

# Compute the (fullName,signal) NDJSON for a repo-relative path's CURRENT
# on-disk content, using the same helper the hook uses, run from the tmp repo.
signals_for() {
  local rel="$1"
  ( cd "$REPO" && node "$HELPER" "$rel" )
}

# Append a ledger line. Args: file fullName signal [failureKind].
seed_ledger() {
  local file="$1" full="$2" sig="$3" kind="${4:-assertion}"
  mkdir -p "$REPO/.gaia/local/red-ledger"
  jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg k "$kind" \
    '{schema:1, file:$f, fullName:$n, signal:$s, failureKind:$k, observedAt:"2026-06-04T00:00:00Z"}' \
    >> "$REPO/.gaia/local/red-ledger/observations.jsonl"
}

# Seed a matching valid RED for one test of a staged file (computes the real
# current signal so the match is exact).
seed_matching_red() {
  local rel="$1" want_full="$2"
  local ndjson sig
  ndjson=$(signals_for "$rel")
  sig=$(printf '%s\n' "$ndjson" \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$sig" ] || { echo "no signal for '$want_full' in $rel" >&2; return 1; }
  seed_ledger "$rel" "$want_full" "$sig"
}

# Run the hook with a `git commit` command, from inside the tmp repo.
run_commit_hook() {
  local cmd="${1:-git commit -m change}"
  local json
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }

PASSING_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

# --- UAT-001 / UAT-002: new test, no matching RED -> deny ---

@test "denies a new test with no ledger entry (never run)" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

@test "denies a new first-run-pass test (ledger has no matching RED)" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  # An unrelated RED in the ledger must not satisfy this test.
  seed_ledger "app/other/index.test.ts" "something else" "sha256:deadbeef"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
}

# --- UAT-003: observed-fail then pass -> allow ---

@test "allows a new test that has a matching valid RED" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  seed_matching_red "app/x/index.test.ts" "adds two numbers"
  run_commit_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- UAT-004: prose-only claim does not satisfy the gate ---

@test "denies even when the commit message prose claims a failing test first" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook 'git commit -m "wrote a failing test first, RED observed"'
  [ "$status" -eq 0 ]
  denied
}

# --- Edit-to-pass hole closed: RED at a stale signal does not count ---

@test "denies when the test body changed after its RED (signal mismatch)" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  # Seed a RED for the SAME fullName but a different (stale) body signal.
  seed_ledger "app/x/index.test.ts" "adds two numbers" "sha256:staleoldsignal"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

# --- Edits to EXISTING tests never fire ---

@test "allows editing a test already present at HEAD even with no RED" {
  # The test exists at HEAD with the same fullName.
  commit_file_at_head "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'
  # Stage an edit to that same test (same fullName, changed body) with no RED.
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(2 + 1).toBe(3);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  ! denied
}

@test "denies a brand-new test added to a file that already exists at HEAD" {
  commit_file_at_head "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("existing test", () => {
  expect(1).toBe(1);
});
'
  # Stage: keep the existing test, add a NEW one with no RED.
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("existing test", () => {
  expect(1).toBe(1);
});
test("brand new test", () => {
  expect(2).toBe(2);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"brand new test"* ]]
  [[ "$output" != *"existing test"* ]]
}

# --- Non-test / no-new-test commits never fire ---

@test "allows a commit staging only non-test source" {
  stage_file "app/x/index.ts" 'export const x = 1;'
  run_commit_hook
  [ "$status" -eq 0 ]
  ! denied
}

@test "allows when 'git commit' appears only inside a quoted message string" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  # No real git commit invocation: the words are inside an echo string.
  run_commit_hook 'echo "remember to git commit later"'
  [ "$status" -eq 0 ]
  ! denied
}

@test "ignores commands that are not git commit" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook "git status"
  [ "$status" -eq 0 ]
  ! denied
}

# --- Foreign-repo commit -> out of scope ---

@test "allows a foreign-repo git -C commit" {
  OTHER=$(mktemp -d -t red-verify-other-XXXXXX)
  git -C "$OTHER" init --quiet --initial-branch=main
  git -C "$OTHER" config user.email "t@e.com"
  git -C "$OTHER" config user.name "T"
  git -C "$OTHER" config commit.gpgsign false
  echo x > "$OTHER/f"; git -C "$OTHER" add f; git -C "$OTHER" commit --quiet -m i

  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook "git -C '$OTHER' commit -m change"
  [ "$status" -eq 0 ]
  ! denied
  rm -rf "$OTHER"
}

# --- Unparseable staged test -> fail-open (not denied on that file) ---

@test "does not deny an unparseable staged test file" {
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("never closes", () => {
  expect(1).toBe(1)
// missing closing brace and paren
'
  run_commit_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- Dynamic-title test -> exempt (no computable signal, never in scope) ---

@test "does not deny a new dynamic-title test (template-literal name)" {
  # The signal helper emits NOTHING for a substitution-template title, so the
  # test never enters the current-test set and is exempt by construction,
  # matching the SPEC's fail-open posture for uncomputable identity. A new
  # dynamic-title test passing first must not trigger a deny.
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
const n = 7;
test(`dynamic ${n}`, () => {
  expect(n).toBe(7);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- Forward-compat: a ledger line with an unknown schema is ignored ---

@test "ignores a ledger line with an unrecognized schema version" {
  stage_file "app/x/index.test.ts" "$PASSING_TEST"
  # Compute the real current signal but record it under schema 2 (unknown).
  local ndjson sig
  ndjson=$(signals_for "app/x/index.test.ts")
  sig=$(printf '%s\n' "$ndjson" | jq -r 'select(.fullName=="adds two numbers") | .signal' | head -1)
  mkdir -p "$REPO/.gaia/local/red-ledger"
  jq -nc --arg s "$sig" \
    '{schema:2, file:"app/x/index.test.ts", fullName:"adds two numbers", signal:$s, failureKind:"assertion", observedAt:"2026-06-04T00:00:00Z"}' \
    >> "$REPO/.gaia/local/red-ledger/observations.jsonl"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
}

# --- Multiple offenders are all named ---

@test "names every offending new test in the deny reason" {
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("first new", () => { expect(1).toBe(1); });
test("second new", () => { expect(2).toBe(2); });
'
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"first new"* ]]
  [[ "$output" == *"second new"* ]]
}

# --- Mixed: one test with a RED, one without -> deny names only the offender ---

@test "allows the RED-backed test but denies its un-RED'd sibling" {
  stage_file "app/x/index.test.ts" 'import {expect, test} from "vitest";
test("has red", () => { expect(1).toBe(1); });
test("no red", () => { expect(2).toBe(2); });
'
  seed_matching_red "app/x/index.test.ts" "has red"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"no red"* ]]
  [[ "$output" != *'"has red"'* ]]
}

# --- A .tsx test file is also in scope ---

@test "denies a new .tsx test with no RED" {
  stage_file "app/x/index.test.tsx" 'import {expect, test} from "vitest";
test("renders something", () => { expect(true).toBe(true); });
'
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"renders something"* ]]
}
