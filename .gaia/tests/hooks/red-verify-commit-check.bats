#!/usr/bin/env bats

# Tests for .claude/hooks/red-verify-commit-check.sh, the commit-gate half of
# mechanical TDD RED-verification.
#
# The hook denies `git commit` when a new-at-HEAD test that now passes has no
# matching valid RED on record in .gaia/local/red-ledger/<tree-key>/observations.jsonl.
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

# Mirror the repo-relative layout the hook resolves from a tree's own root, in
# whatever tree a case aims a commit at. Every such tree needs its own copy:
# the signal helper is invoked by the repo-relative path
# red_ledger_signal_script returns, run from the tree the gate decides the
# commit acts on, so a linked worktree lacking it emits no signals and drops
# out of the offender scan.
install_tree_links() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/.gaia/scripts"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$dir/.claude/hooks/lib/red-ledger.sh"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/repo-scope.sh" "$dir/.claude/hooks/lib/repo-scope.sh"
  ln -sfn "$HOME_ROOT/.gaia/scripts/red-ledger" "$dir/.gaia/scripts/red-ledger"
  # red_ledger_path (inside the symlinked red-ledger.sh above) sources this
  # relative to ITS OWN location to reach gaia_tree_key, so it needs to
  # resolve inside the tree too, not just from the hook's own BASH_SOURCE.
  ln -sfn "$HOME_ROOT/.gaia/scripts/main-root-lib.sh" "$dir/.gaia/scripts/main-root-lib.sh"
  # The determinism carve-out classifies the test file via this helper; symlink
  # it so the hook resolves it from the tree exactly as in production. The
  # symlinked helper resolves `typescript` from the home repo's node_modules.
  ln -sfn "$HOME_ROOT/.gaia/scripts/classifier" "$dir/.gaia/scripts/classifier"
}

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  HOOK_ABS="$HOME_ROOT/.claude/hooks/red-verify-commit-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"

  REPO=$(mktemp -d -t red-verify-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  install_tree_links "$REPO"

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

# Write file content (creating parent dirs) and stage it. The optional third
# argument names the tree to stage in, defaulting to the tmp repo; a case that
# aims a commit at a linked worktree stages there instead.
stage_file() {
  local path="$1" content="$2" root="${3:-$REPO}"
  mkdir -p "$root/$(dirname "$path")"
  printf '%s' "$content" > "$root/$path"
  git -C "$root" add "$path"
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
  local rel="$1" root="${2:-$REPO}"
  ( cd "$root" && node "$HELPER" "$rel" )
}

# Append a ledger line. Args: file fullName signal [failureKind]. Writes to
# the path the shipped red_ledger_path resolves for REPO, so the seed lands
# exactly where the hook itself will look, rather than a second hardcoded
# copy of the keyed literal.
seed_ledger() {
  local file="$1" full="$2" sig="$3" kind="${4:-assertion}" root="${5:-$REPO}"
  local ledger
  ledger="$( . "$root/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$root" )"
  mkdir -p "$(dirname "$ledger")"
  jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg k "$kind" \
    '{schema:1, file:$f, fullName:$n, signal:$s, failureKind:$k, observedAt:"2026-06-04T00:00:00Z"}' \
    >> "$ledger"
}

# Seed a matching valid RED for one test of a staged file (computes the real
# current signal so the match is exact).
seed_matching_red() {
  local rel="$1" want_full="$2" root="${3:-$REPO}"
  local ndjson sig
  ndjson=$(signals_for "$rel" "$root")
  sig=$(printf '%s\n' "$ndjson" \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$sig" ] || { echo "no signal for '$want_full' in $rel" >&2; return 1; }
  seed_ledger "$rel" "$want_full" "$sig" assertion "$root"
}

# Run the hook with a `git commit` command, from inside the tmp repo.
run_commit_hook() {
  local cmd="${1:-git commit -m change}"
  local json
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}

# The same, from a subdirectory of the tmp repo. The agent's working directory
# is whatever the session last set, not the repository root, so every arm this
# gate depends on has to resolve from a depth nobody chose.
run_commit_hook_from() {
  local sub="$1"
  local cmd="${2:-git commit -m change}"
  local json
  mkdir -p "$REPO/$sub"
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO/$sub" "$json" "$HOOK_ABS"
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }

# Absence assertion: fail the test when the hook denied. A bare `! denied` only
# works as a test's final line -- `set -e` exempts a `!`-negated command from
# aborting, so the moment a later line is appended it silently goes inert. This
# form fails in any position (returns 1 when denied) and stays green as a final
# line when allowed (the completed `if` exits 0). See .claude/rules/bats-assertions.md.
refute_denied() { if denied; then return 1; fi; }

PASSING_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

# A strict-surface test carrying an in-test `//` comment, used for the
# comment-only-edit and absorbed-assertion cases below. PRE/POST differ only
# in the comment's wording (a reword, not a deletion).
COMMENT_STRICT_PRE='import {expect, test} from "vitest";
test("adds two numbers", () => {
  // sanity check
  expect(1 + 1).toBe(2);
});
'
COMMENT_STRICT_POST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  // arithmetic sanity check
  expect(1 + 1).toBe(2);
});
'

# Same test, but the trailing assertion is pulled onto the comment line: the
# live `expect(...)` call is gone from executed code, so the signal changes.
ABSORB_STRICT_PRE="$COMMENT_STRICT_PRE"
ABSORB_STRICT_POST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  // sanity check expect(1 + 1).toBe(2);
});
'

# --- new test with no matching RED -> deny ---

@test "denies a new test with no ledger entry (never run)" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

@test "still denies when the working directory is a subdirectory" {
  # The regression this pins: the gate located its shared libraries by a bare
  # repository-root-relative path, so from any subdirectory the load failed,
  # the capability probe took the fail-open written for a MISSING library, and
  # an ungated commit looked exactly like a clean pass. One `cd` bought that.
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook_from "app/utils"
  [ "$status" -eq 0 ]
  denied
}

@test "still allows a matching RED when the working directory is a subdirectory" {
  # The other half: the rooting must not make the gate deny everything from a
  # subdirectory either, which would be a different silent break.
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  seed_matching_red "app/utils/x/index.test.ts" "adds two numbers"
  run_commit_hook_from "app/utils"
  [ "$status" -eq 0 ]
  refute_denied
}

@test "denies a new first-run-pass test (ledger has no matching RED)" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  # An unrelated RED in the ledger must not satisfy this test.
  seed_ledger "app/utils/other/index.test.ts" "something else" "sha256:deadbeef"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
}

# --- observed-fail then pass -> allow ---

@test "allows a new test that has a matching valid RED" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  seed_matching_red "app/utils/x/index.test.ts" "adds two numbers"
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

# --- prose-only claim does not satisfy the gate ---

@test "denies even when the commit message prose claims a failing test first" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook 'git commit -m "wrote a failing test first, RED observed"'
  [ "$status" -eq 0 ]
  denied
}

# --- Edit-to-pass hole closed: RED at a stale signal does not count ---

@test "denies when the test body changed after its RED (signal mismatch)" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  # Seed a RED for the SAME fullName but a different (stale) body signal.
  seed_ledger "app/utils/x/index.test.ts" "adds two numbers" "sha256:staleoldsignal"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

# --- Edits to EXISTING tests never fire ---

@test "allows editing a test already present at HEAD even with no RED" {
  # The test exists at HEAD with the same fullName.
  commit_file_at_head "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'
  # Stage an edit to that same test (same fullName, changed body) with no RED.
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(2 + 1).toBe(3);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "still allows editing a test present at HEAD when the cwd is a subdirectory" {
  # The HEAD-side signal recompute is a THIRD cwd-resolved read, separate from
  # the two the subdirectory tests above cover. It feeds `head_fullnames`, and
  # empty there means "nothing pre-existed at HEAD", so every current test reads
  # as new-at-HEAD. The failure is an inverted verdict rather than a stood-down
  # gate: an ordinary edit to a long-standing test gets denied for want of a RED
  # it never owed. The two new-test subdirectory cases above cannot see it,
  # because for a genuinely new test an empty HEAD set is the correct answer.
  commit_file_at_head "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(2 + 1).toBe(3);
});
'
  run_commit_hook_from "app/utils"
  [ "$status" -eq 0 ]
  refute_denied
}

@test "denies a brand-new test added to a file that already exists at HEAD" {
  commit_file_at_head "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("existing test", () => {
  expect(1).toBe(1);
});
'
  # Stage: keep the existing test, add a NEW one with no RED.
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
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
  refute_denied
}

@test "allows when 'git commit' appears only inside a quoted message string" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  # No real git commit invocation: the words are inside an echo string.
  run_commit_hook 'echo "remember to git commit later"'
  [ "$status" -eq 0 ]
  refute_denied
}

@test "ignores commands that are not git commit" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook "git status"
  [ "$status" -eq 0 ]
  refute_denied
}

# --- Foreign-repo commit -> out of scope ---

@test "allows a foreign-repo git -C commit" {
  OTHER=$(mktemp -d -t red-verify-other-XXXXXX)
  git -C "$OTHER" init --quiet --initial-branch=main
  git -C "$OTHER" config user.email "t@e.com"
  git -C "$OTHER" config user.name "T"
  git -C "$OTHER" config commit.gpgsign false
  echo x > "$OTHER/f"; git -C "$OTHER" add f; git -C "$OTHER" commit --quiet -m i

  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook "git -C '$OTHER' commit -m change"
  [ "$status" -eq 0 ]
  denied && return 1
  rm -rf "$OTHER"
}

# --- Unparseable staged test -> fail-open (not denied on that file) ---

@test "does not deny an unparseable staged test file" {
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("never closes", () => {
  expect(1).toBe(1)
// missing closing brace and paren
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

# --- Dynamic-title test -> exempt (no computable signal, never in scope) ---

@test "does not deny a new dynamic-title test (template-literal name)" {
  # The signal helper emits NOTHING for a substitution-template title, so the
  # test never enters the current-test set and is exempt by construction,
  # matching the SPEC's fail-open posture for uncomputable identity. A new
  # dynamic-title test passing first must not trigger a deny.
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
const n = 7;
test(`dynamic ${n}`, () => {
  expect(n).toBe(7);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

# --- Type-only tests -> exempt (no runtime assertion; tsc is the enforcer) ---

TYPE_ONLY_EXPECTTYPEOF='import {expectTypeOf, test} from "vitest";
test("type matches", () => {
  expectTypeOf<number>().toEqualTypeOf<number>();
});
'

TYPE_ONLY_TS_EXPECT_ERROR='import {test} from "vitest";
const double = (n: number): number => n * 2;
test("rejects a bad arg", () => {
  // @ts-expect-error - double requires a number
  double("nope");
});
'

@test "allows a new type-only test (expectTypeOf, no runtime assertion)" {
  # No RED on record, yet the commit is allowed: a type-only test has no
  # runtime failure mode for this gate to demand. tsc enforces it instead.
  stage_file "app/utils/x/index.test.ts" "$TYPE_ONLY_EXPECTTYPEOF"
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "allows a new type-only test (@ts-expect-error proof, no runtime assertion)" {
  stage_file "app/utils/x/index.test.ts" "$TYPE_ONLY_TS_EXPECT_ERROR"
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "exempts the type-only sibling but still denies the runtime sibling" {
  stage_file "app/utils/x/index.test.ts" 'import {expectTypeOf, expect, test} from "vitest";
test("type-only sibling", () => {
  expectTypeOf<number>().toEqualTypeOf<number>();
});
test("runtime sibling", () => {
  expect(1 + 1).toBe(2);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"runtime sibling"* ]]
  [[ "$output" != *"type-only sibling"* ]]
}

@test "denies a mixed runtime+type test (runtime assertion present) with no RED" {
  # A type-level proof does NOT exempt a test that also carries a runtime
  # assertion: the runtime red-green still must be observed.
  stage_file "app/utils/x/index.test.ts" 'import {expectTypeOf, expect, test} from "vitest";
test("mixed assertions", () => {
  expect(1 + 1).toBe(2);
  expectTypeOf<number>().toEqualTypeOf<number>();
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"mixed assertions"* ]]
}


@test "ignores a ledger line with an unrecognized schema version" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  # Compute the real current signal but record it under schema 2 (unknown).
  local ndjson sig ledger
  ndjson=$(signals_for "app/utils/x/index.test.ts")
  sig=$(printf '%s\n' "$ndjson" | jq -r 'select(.fullName=="adds two numbers") | .signal' | head -1)
  ledger="$( . "$REPO/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$REPO" )"
  mkdir -p "$(dirname "$ledger")"
  jq -nc --arg s "$sig" \
    '{schema:2, file:"app/utils/x/index.test.ts", fullName:"adds two numbers", signal:$s, failureKind:"assertion", observedAt:"2026-06-04T00:00:00Z"}' \
    >> "$ledger"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
}

# --- Multiple offenders are all named ---

@test "names every offending new test in the deny reason" {
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
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
  stage_file "app/utils/x/index.test.ts" 'import {expect, test} from "vitest";
test("has red", () => { expect(1).toBe(1); });
test("no red", () => { expect(2).toBe(2); });
'
  seed_matching_red "app/utils/x/index.test.ts" "has red"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"no red"* ]]
  [[ "$output" != *'"has red"'* ]]
}

# --- Determinism carve-out: the RED demand is scoped to the strict surface ---
#
# The carve-out classifies the TEST FILE ITSELF via the determinism classifier.
# An emergent verdict relaxes the RED demand (the file is skipped); a strict
# verdict leaves the file under the gate unchanged. The classifier is biased
# err-EMERGENT, so it covers component (.tsx), E2E (.playwright), a11y-helper,
# and clock/entropy/I-O signals. The deterministic surface still demands a RED.

@test "carve-out: a new .tsx component-interaction test commits without a RED" {
  # A .tsx test falls outside the classifier's strict candidate path -> emergent.
  # No RED on record, yet the commit is allowed: forcing a RED on emergent
  # component interaction would be theater.
  stage_file "app/components/Widget/tests/index.test.tsx" 'import {expect, test} from "vitest";
test("renders something", () => { expect(true).toBe(true); });
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "carve-out: a new a11y-helper test (.ts) commits without a RED" {
  # A static-markup a11y check is render-/environment-dependent. The classifier
  # tags expectNoA11yViolations/runAxe as an emergent signal even in a .ts file
  # on the otherwise-deterministic component surface -> exempt from the RED.
  stage_file "app/components/Widget/tests/a11y.test.ts" 'import {expect, test} from "vitest";
import {runAxe} from "test/a11y";
const node = document.body;
test("has no a11y violations", async () => {
  const results = await runAxe(node);
  expect(results).toBeDefined();
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "carve-out: a new test whose own body reads the clock commits without a RED" {
  # The classifier labels any no-arg new Date() emergent wherever it appears,
  # including inside the test body -> the file is exempt from the RED.
  stage_file "app/utils/clock/index.test.ts" 'import {expect, test} from "vitest";
test("uses wall-clock time", () => {
  const now = new Date();
  expect(now).toBeInstanceOf(Date);
});
'
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
}

@test "carve-out: the deterministic surface STILL demands a RED" {
  # A pure .ts test under app/utils classifies strict; the carve-out does not
  # relax it. With no matching RED on record, the commit is denied.
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

@test "carve-out fail-open: missing classifier falls back to the RED demand" {
  # When the classifier helper is unavailable the carve-out must NOT fire: the
  # gate falls back to its pre-carve behavior and still demands the RED, so the
  # deterministic path is never broken and the relax-only posture holds.
  rm -f "$REPO/.gaia/scripts/classifier"
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"adds two numbers"* ]]
}

@test "deny reason includes the TDD RED-verification header and the unblock steps" {
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook
  [ "$status" -eq 0 ]
  grep -qF -- "TDD RED-verification" <<<"$output"
  grep -qF -- "To unblock:" <<<"$output"
  denied
}

# --- comment-only edit vs. an assertion absorbed into a comment (UAT-006, UAT-014, UAT-008) ---

@test "denies when a live assertion is absorbed into a comment (strict, new-at-HEAD, runtime; UAT-006)" {
  stage_file "app/utils/x/index.test.ts" "$ABSORB_STRICT_PRE"
  # Seed the RED at the PRE-absorb signal (staged, working-tree content).
  seed_matching_red "app/utils/x/index.test.ts" "adds two numbers"
  stage_file "app/utils/x/index.test.ts" "$ABSORB_STRICT_POST"
  run_commit_hook
  [ "$status" -eq 0 ]
  grep -qF -- "adds two numbers" <<<"$output"
  denied
}

@test "allows a comment-only reword after a matching RED (strict, new-at-HEAD, runtime; UAT-014 RED half)" {
  stage_file "app/utils/x/index.test.ts" "$COMMENT_STRICT_PRE"
  seed_matching_red "app/utils/x/index.test.ts" "adds two numbers"
  stage_file "app/utils/x/index.test.ts" "$COMMENT_STRICT_POST"
  run_commit_hook
  [ "$status" -eq 0 ]
  refute_denied
  grep -qF -- "adds two numbers" <<<"$output" && return 1
  true
}

@test "denies the same comment-reword fixture when the seeded RED signal doesn't match (UAT-014 RED half, negative control)" {
  stage_file "app/utils/x/index.test.ts" "$COMMENT_STRICT_PRE"
  seed_ledger "app/utils/x/index.test.ts" "adds two numbers" "sha256:staleoldsignal"
  stage_file "app/utils/x/index.test.ts" "$COMMENT_STRICT_POST"
  run_commit_hook
  [ "$status" -eq 0 ]
  grep -qF -- "adds two numbers" <<<"$output"
  denied
}

@test "the RED half of the three-run transition denies on the first run (comment-carrying, strict, new-at-HEAD, runtime; UAT-008)" {
  stage_file "app/utils/x/index.test.ts" "$COMMENT_STRICT_PRE"
  # A literal the current computation does not produce -- the same idiom as
  # the existing signal-mismatch case above.
  seed_ledger "app/utils/x/index.test.ts" "adds two numbers" "sha256:staleoldsignal"
  run_commit_hook
  [ "$status" -eq 0 ]
  grep -qF -- "adds two numbers" <<<"$output"
  denied
}

# --- the tree the commit acts on, not the tree the session sits in ---
#
# A linked worktree is the same repository, so the repo-scope guard reads a
# `git -C <worktree>` or a leading `cd <worktree> &&` as home and this gate
# keeps enforcing. What it must not keep reading is its own checkout: the
# staged set, the HEAD blob, and the per-tree ledger all belong to the checkout
# the commit lands in (gaia-react/gaia#2013).

# A linked worktree of REPO, provisioned the way REPO itself is. Sets WT.
make_worktree() {
  WT="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$WT"
  install_tree_links "$WT"
}

# Run the hook with an explicit payload cwd. run_commit_hook leaves that field
# unset, which is the shape the cases above want; these cases set it because
# the tree the command targets and the tree the session stands in differ here,
# and the field is how the gate learns the latter.
run_commit_hook_in() {
  local cwd="$1" cmd="$2" json
  json=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')
  invoke_hook_in "$cwd" "$json" "$HOOK_ABS"
}

@test "a -C into a linked worktree reads that worktree's staged tests" {
  make_worktree
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST" "$WT"
  run_commit_hook_in "$REPO" "git -C $WT commit -m change"
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "adds two numbers" <<<"$output"
}

@test "a -C into a linked worktree does not read the session checkout's staged tests" {
  # The false-deny half. The session's own staged, un-RED'd test belongs to a
  # tree this commit never touches, so naming it refuses a commit for a RED
  # that commit does not owe.
  make_worktree
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook_in "$REPO" "git -C $WT commit -m change"
  [ "$status" -eq 0 ]
  refute_denied
}

@test "a leading cd into a linked worktree reads that worktree's staged tests" {
  make_worktree
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST" "$WT"
  run_commit_hook_in "$REPO" "cd $WT && git commit -m change"
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "adds two numbers" <<<"$output"
}

@test "a matching RED in the target worktree's own ledger allows the commit" {
  # The ledger is per-tree state, so following the command's target has to
  # reach the ledger lookup as well as the staged read.
  make_worktree
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST" "$WT"
  seed_matching_red "app/utils/x/index.test.ts" "adds two numbers" "$WT"
  run_commit_hook_in "$REPO" "git -C $WT commit -m change"
  [ "$status" -eq 0 ]
  refute_denied
}

@test "commit's own -C names a commit, so the session's staged tests are still read" {
  # `git commit -C <commit>` reuses that commit's message. Read as a directory
  # it aims the gate at a path named for a commit, where git answers nothing
  # and every read below drops out into a silent pass.
  stage_file "app/utils/x/index.test.ts" "$PASSING_TEST"
  run_commit_hook_in "$REPO" "git commit -C HEAD -m change"
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "adds two numbers" <<<"$output"
}
