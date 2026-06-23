#!/usr/bin/env bats

# Tests for .claude/hooks/worthiness-presence-check.sh, the merge-time half of
# the worthiness audit.
#
# The hook denies `gh pr merge` when an emergent test the PR changed has no
# worthiness-ledger line (.gaia/local/audit-ledger/worthiness.jsonl) matching its
# current content. It scopes to the emergent test files this PR changed (the diff
# against the merge base with the default branch), decides emergent membership via
# the determinism classifier, recomputes each test's signal via the shared RED
# helper, and checks PRESENCE + signal match only, never the verdict. Stale-signal
# lines are rejected on recompute. It fails open on missing git/jq/node/lib/
# classifier and skips unparseable files. When zero emergent tests changed, it is
# a no-op.
#
# Setup models a PR: a base commit on `main`, then a `feature` branch carrying the
# change under test. merge-base(HEAD, main) resolves to the base commit, so the
# gate diffs only the feature's files. No remote is needed; the hook falls back
# from origin/main to main.
#
# The hook runs with pwd = the tmp repo so bare `git` resolves the staged change.
# In production pwd = the project root, where .claude/hooks/lib and .gaia/scripts
# live. To reproduce that invariant the setup symlinks those trees from the home
# repo into the tmp repo at their repo-relative paths; the symlinked helpers
# resolve `typescript` from the home repo's node_modules via createRequire.
#
# The hook always exits 0; allow vs deny is carried in stdout: a deny emits
# `"permissionDecision": "deny"`, an allow emits nothing.

setup() {
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABS="$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"

  REPO=$(mktemp -d -t worthiness-presence-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  # Mirror the repo-relative layout the hook resolves from pwd.
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  ln -s "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$REPO/.claude/hooks/lib/red-ledger.sh"
  ln -s "$HOME_ROOT/.claude/hooks/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"
  ln -s "$HOME_ROOT/.gaia/scripts/red-ledger" "$REPO/.gaia/scripts/red-ledger"
  ln -s "$HOME_ROOT/.gaia/scripts/classifier" "$REPO/.gaia/scripts/classifier"

  # Base commit on main with a non-test file so HEAD/merge-base exist. The
  # symlinks are untracked; they never enter the diff.
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  git -C "$REPO" checkout --quiet -b feature
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Commit a file on the feature branch (so it appears in the merge-base diff).
commit_file() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit --quiet -m "change $path"
}

# Compute the (fullName,signal) NDJSON for a repo-relative path's CURRENT on-disk
# content, using the same helper the hook uses, run from the tmp repo.
signals_for() {
  local rel="$1"
  ( cd "$REPO" && node "$HELPER" "$rel" )
}

# Append a worthiness-ledger line. Args: file fullName signal verdict [artifact].
seed_ledger() {
  local file="$1" full="$2" sig="$3" verdict="${4:-keep}" artifact="${5:-}"
  mkdir -p "$REPO/.gaia/local/audit-ledger"
  if [ -n "$artifact" ]; then
    jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg v "$verdict" --arg a "$artifact" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z", artifact:$a}' \
      >> "$REPO/.gaia/local/audit-ledger/worthiness.jsonl"
  else
    jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg v "$verdict" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z"}' \
      >> "$REPO/.gaia/local/audit-ledger/worthiness.jsonl"
  fi
}

# Seed a matching ledger line for one test of a changed file (computes the real
# current signal so the match is exact).
seed_matching() {
  local rel="$1" want_full="$2" verdict="${3:-keep}"
  local ndjson sig
  ndjson=$(signals_for "$rel")
  sig=$(printf '%s\n' "$ndjson" \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$sig" ] || { echo "no signal for '$want_full' in $rel" >&2; return 1; }
  seed_ledger "$rel" "$want_full" "$sig" "$verdict"
}

# Run the hook with a `gh pr merge` command, from inside the tmp repo.
run_merge_hook() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }

# An emergent component test (.tsx under app/components/** classifies emergent).
EMERGENT_TEST='import {expect, test} from "vitest";
test("renders a label", () => {
  expect(true).toBe(true);
});
'

# A deterministic util test (.ts under app/utils/** classifies strict) -> the
# presence gate excludes it (RED-gated, not worthiness-gated).
STRICT_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

# --- no-op when nothing emergent changed ---

@test "allows a PR that changes no emergent test files (no-op)" {
  commit_file "README.md" "# changed"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

@test "allows a PR changing only a deterministic util test (RED-gated, excluded)" {
  commit_file "app/utils/x/index.test.ts" "$STRICT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

@test "allows a PR changing only non-test source under app/components" {
  commit_file "app/components/Foo/index.tsx" "export const Foo = () => null;"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- clean-case deny: emergent test changed, no matching ledger line ---

@test "denies an emergent component test with no ledger entry" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"renders a label"* ]]
}

@test "denies an emergent test when the ledger has only an unrelated line" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  seed_ledger "app/components/Other/tests/index.test.tsx" "something else" "sha256:deadbeef" "keep"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
}

# --- allow: matching ledger line present ---

@test "allows an emergent test with a matching keep line" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  seed_matching "app/components/Foo/tests/index.test.tsx" "renders a label" "keep"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

@test "allows on a matching line regardless of verdict (verdict not gated)" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  # A `fix` verdict still satisfies presence + signal match; the verdict is
  # advisory and never read for the presence decision.
  seed_ledger "app/components/Foo/tests/index.test.tsx" "renders a label" \
    "$(signals_for app/components/Foo/tests/index.test.tsx | jq -r 'select(.fullName=="renders a label") | .signal')" \
    "fix" "no-interaction-assertions"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- stale-signal rejection ---

@test "denies when the ledger line carries a stale (pre-edit) signal" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  # A line written before a later edit: real file, real fullName, wrong signal.
  seed_ledger "app/components/Foo/tests/index.test.tsx" "renders a label" \
    "sha256:0000000000000000000000000000000000000000000000000000000000000000" "keep"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
}

# --- playwright emergent surface ---

@test "denies an emergent .playwright spec with no ledger entry" {
  commit_file ".playwright/e2e/home.spec.ts" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
}

@test "allows an emergent .playwright spec with a matching line" {
  commit_file ".playwright/e2e/home.spec.ts" "$EMERGENT_TEST"
  seed_matching ".playwright/e2e/home.spec.ts" "renders a label" "keep"
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- fail-open: unparseable file is skipped, not denied ---

@test "skips (allows) an emergent test file with a syntax error" {
  commit_file "app/components/Foo/tests/index.test.tsx" 'import {test} from "vitest";
test("oops" => { syntax(((;'
  run_merge_hook
  [ "$status" -eq 0 ]
  ! denied
}

# --- command-position match ---

@test "ignores commands that are not gh pr merge" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook "git status"
  [ "$status" -eq 0 ]
  ! denied
}

@test "matches gh pr merge after a shell separator" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook "git fetch origin && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  denied
}

# --- coexistence: deny names this gate, distinct from the audit gate ---

@test "deny reason references the worthiness presence gate" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"Worthiness presence gate"* ]]
}
