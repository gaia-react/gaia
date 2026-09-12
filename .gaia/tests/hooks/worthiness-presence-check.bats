#!/usr/bin/env bats

# Tests for .claude/hooks/worthiness-presence-check.sh, the merge-time half of
# the worthiness audit.
#
# The hook denies `gh pr merge` when an emergent test the PR changed has no
# worthiness-ledger line (.gaia/local/worthiness-ledger/<tree-key>/worthiness.jsonl)
# matching its current content. It scopes to the emergent test files this PR changed (the diff
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

# Mirror the repo-relative layout the hook resolves from a tree's own root, in
# whatever tree a case aims a merge at. Every such tree needs its own copy: the
# signal helper is invoked by the repo-relative path red_ledger_signal_script
# returns, run from the tree the gate decides the merge acts on, so a linked
# worktree lacking it emits no signals and drops out of the offender scan.
install_tree_links() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/.gaia/scripts"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/red-ledger.sh" "$dir/.claude/hooks/lib/red-ledger.sh"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/repo-scope.sh" "$dir/.claude/hooks/lib/repo-scope.sh"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/worthiness-ledger.sh" "$dir/.claude/hooks/lib/worthiness-ledger.sh"
  ln -sfn "$HOME_ROOT/.gaia/scripts/red-ledger" "$dir/.gaia/scripts/red-ledger"
  ln -sfn "$HOME_ROOT/.gaia/scripts/classifier" "$dir/.gaia/scripts/classifier"
  # red_ledger_path and worthiness_ledger_path (inside the symlinked libs
  # above) each source this relative to THEIR OWN location to reach
  # gaia_tree_key, so it needs to resolve inside the tree too, not just from
  # the hook's own BASH_SOURCE.
  ln -sfn "$HOME_ROOT/.gaia/scripts/main-root-lib.sh" "$dir/.gaia/scripts/main-root-lib.sh"
}

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  HOOK_ABS="$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"

  REPO=$(mktemp -d -t worthiness-presence-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  install_tree_links "$REPO"

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
# The optional third argument names the tree to commit in, defaulting to the
# tmp repo; a case that aims a merge at a linked worktree commits there.
commit_file() {
  local path="$1" content="$2" root="${3:-$REPO}"
  mkdir -p "$root/$(dirname "$path")"
  printf '%s' "$content" > "$root/$path"
  git -C "$root" add "$path"
  git -C "$root" commit --quiet -m "change $path"
}

# Compute the (fullName,signal) NDJSON for a repo-relative path's CURRENT on-disk
# content, using the same helper the hook uses, run from the tmp repo.
signals_for() {
  local rel="$1" root="${2:-$REPO}"
  ( cd "$root" && node "$HELPER" "$rel" )
}

# Append a worthiness-ledger line. Args: file fullName signal verdict [artifact].
# Writes to the path the shipped worthiness_ledger_path resolves for REPO, so
# the seed lands exactly where the hook itself will look, rather than a
# second hardcoded copy of the keyed literal.
seed_ledger() {
  local file="$1" full="$2" sig="$3" verdict="${4:-keep}" artifact="${5:-}" root="${6:-$REPO}"
  local ledger
  ledger="$( . "$root/.claude/hooks/lib/worthiness-ledger.sh" && worthiness_ledger_path "$root" )"
  mkdir -p "$(dirname "$ledger")"
  if [ -n "$artifact" ]; then
    jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg v "$verdict" --arg a "$artifact" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z", artifact:$a}' \
      >> "$ledger"
  else
    jq -nc --arg f "$file" --arg n "$full" --arg s "$sig" --arg v "$verdict" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z"}' \
      >> "$ledger"
  fi
}

# Seed a matching ledger line for one test of a changed file (computes the real
# current signal so the match is exact).
seed_matching() {
  local rel="$1" want_full="$2" verdict="${3:-keep}" root="${4:-$REPO}"
  local ndjson sig
  ndjson=$(signals_for "$rel" "$root")
  sig=$(printf '%s\n' "$ndjson" \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$sig" ] || { echo "no signal for '$want_full' in $rel" >&2; return 1; }
  seed_ledger "$rel" "$want_full" "$sig" "$verdict" "" "$root"
}

# Run the hook with a `gh pr merge` command, from inside the tmp repo.
run_merge_hook() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}

# The same, from a subdirectory of the tmp repo. The agent's working directory
# is whatever the session last set, not the repository root, so every arm this
# gate depends on has to resolve from a depth nobody chose.
run_merge_hook_from() {
  local sub="$1"
  local cmd="${2:-gh pr merge 30 --squash --delete-branch}"
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

# An emergent component test (.tsx under app/components/** classifies emergent).
EMERGENT_TEST='import {expect, test} from "vitest";
test("renders a label", () => {
  expect(true).toBe(true);
});
'

# An emergent component test carrying an in-test `//` comment, used for the
# comment-only-edit and absorbed-assertion cases below. PRE/POST differ only
# in the comment's wording (a reword, not a deletion).
COMMENT_EMERGENT_PRE='import {expect, test} from "vitest";
test("renders a widget", () => {
  // check the label
  expect(true).toBe(true);
});
'
COMMENT_EMERGENT_POST='import {expect, test} from "vitest";
test("renders a widget", () => {
  // verify the label text
  expect(true).toBe(true);
});
'

# Same test, but the trailing assertion is pulled onto the comment line: the
# live `expect(...)` call is gone from executed code, so the signal changes.
ABSORB_EMERGENT_PRE="$COMMENT_EMERGENT_PRE"
ABSORB_EMERGENT_POST='import {expect, test} from "vitest";
test("renders a widget", () => {
  // check the label expect(true).toBe(true);
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

@test "still denies when the working directory is a subdirectory" {
  # The regression this pins: the gate located its shared libraries, and read
  # the changed test files, by bare repository-root-relative paths, so from any
  # subdirectory the loads and the reads all failed and every path out of them
  # was a fail-open. One `cd` cleared the merge with no verdict demanded, and
  # nothing said so.
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook_from "app/components"
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "renders a label" <<<"$output"
}

@test "still allows a matching verdict when the working directory is a subdirectory" {
  # The other half: the rooting must not make the gate deny everything from a
  # subdirectory either, which would be a different silent break.
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  seed_matching "app/components/Foo/tests/index.test.tsx" "renders a label" "keep"
  run_merge_hook_from "app/components"
  [ "$status" -eq 0 ]
  refute_denied
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

# --- path encoding: a non-ASCII path is still scoped in ---

# Under git's default core.quotePath, `git diff --name-only` C-quotes a path
# carrying non-ASCII bytes, emitting the surrounding double quotes as literal
# characters. A quoted token starts with `"`, so it matches none of the
# emergent-surface case patterns above, drops out of the loop, and the gate
# passes on exactly the input it exists to hold -- indistinguishable, by then,
# from having nothing to flag.
@test "denies an emergent component test whose path carries non-ASCII bytes" {
  commit_file "app/components/Café/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
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

@test "deny reason includes the unblock steps and the ledger-writer invocation" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF -- "To unblock:" <<<"$output"
  grep -qF -- "node .gaia/scripts/audit-ledger/append-worthiness.mjs" <<<"$output"
  denied
}

# --- comment-only edit vs. an assertion absorbed into a comment (UAT-005, UAT-014, UAT-008) ---

@test "allows a comment-only reword after a matching verdict (emergent, UAT-005)" {
  commit_file "app/components/Widget/tests/index.test.tsx" "$COMMENT_EMERGENT_PRE"
  # Seed BEFORE the edit, against the pre-edit revision's real signal.
  seed_matching "app/components/Widget/tests/index.test.tsx" "renders a widget"
  commit_file "app/components/Widget/tests/index.test.tsx" "$COMMENT_EMERGENT_POST"
  run_merge_hook
  [ "$status" -eq 0 ]
  refute_denied
  grep -qF -- "renders a widget" <<<"$output" && return 1
  true
}

@test "denies the same comment-reword fixture when the ledger's signal doesn't match (UAT-005 negative control)" {
  commit_file "app/components/Widget/tests/index.test.tsx" "$COMMENT_EMERGENT_PRE"
  seed_ledger "app/components/Widget/tests/index.test.tsx" "renders a widget" \
    "sha256:0000000000000000000000000000000000000000000000000000000000000000" "keep"
  commit_file "app/components/Widget/tests/index.test.tsx" "$COMMENT_EMERGENT_POST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
}

@test "denies when a live assertion is absorbed into a comment after a matching verdict (emergent, UAT-014)" {
  commit_file "app/components/Widget/tests/index.test.tsx" "$ABSORB_EMERGENT_PRE"
  seed_matching "app/components/Widget/tests/index.test.tsx" "renders a widget"
  commit_file "app/components/Widget/tests/index.test.tsx" "$ABSORB_EMERGENT_POST"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF -- "renders a widget" <<<"$output"
  denied
}

@test "three-run transition: deny, then allow once a matching line is appended, then allow again (UAT-008, TST-009)" {
  commit_file "app/components/Widget/tests/index.test.tsx" "$COMMENT_EMERGENT_PRE"
  # Run 1: a non-matching literal seeded -- deny.
  seed_ledger "app/components/Widget/tests/index.test.tsx" "renders a widget" \
    "sha256:0000000000000000000000000000000000000000000000000000000000000000" "keep"
  run_merge_hook
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"

  # Run 2: append a line at the CURRENT signal -- allow.
  seed_matching "app/components/Widget/tests/index.test.tsx" "renders a widget"
  run_merge_hook
  [ "$status" -eq 0 ]
  refute_denied

  # Run 3: unchanged -- allow again (idempotent).
  run_merge_hook
  [ "$status" -eq 0 ]
  refute_denied
}

# ---------------------------------------------------------------------------
# Shared verb-arming adoption: the tokenizer arm this hook gained, and the
# data-proof that keeps a heredoc-body merge from arming it. Every case seeds
# an emergent test with NO ledger entry, so the hook has a real reason to
# deny once armed; the assertion is on the DENY TEXT, never the exit status,
# per README.md's "trap directive TST-008" for this suite.
# ---------------------------------------------------------------------------

# Stage the whole of .claude/hooks, lib/ included, into a fresh tree and
# delete LIBNAME from the staged copy, then run the STAGED hook with cwd =
# $REPO (whose OTHER libs stay the setup()-installed symlinks; this hook
# sources those cwd-relatively, so only the BASH_SOURCE-anchored verb-arming
# load is affected by which copy of the hook file runs).
run_merge_hook_lib_absent() {
  local libname="$1" cmd="$2" json stage
  stage="$BATS_TEST_TMPDIR/staged-hooks-${libname}"
  if [ ! -d "$stage" ]; then
    cp -r "$(dirname "$HOOK_ABS")" "$stage"
    rm -f "$stage/lib/$libname"
  fi
  json=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$stage/worthiness-presence-check.sh"
}

@test "arming: a quoted verb now reaches the gate (tokenizer arm)" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook 'gh pr "merge" 30 --squash'
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"Worthiness presence gate"* ]]
}

@test "arming: a cat-to-file heredoc body carrying the verb does not reach the gate" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook $'cat > f.txt <<EOF\ngh pr merge 30 --squash\nEOF\n'
  [ "$status" -eq 0 ]
  refute_denied
}

@test "arming: removing the heredoc opener line leaves the same body text reaching the gate" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook $'gh pr merge 30 --squash\nEOF\n'
  [ "$status" -eq 0 ]
  denied
}

@test "arming: a heredoc piped into bash still reaches the gate" {
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook $'cat <<EOF | bash\ngh pr merge 30 --squash\nEOF\n'
  [ "$status" -eq 0 ]
  denied
}

@test "library-absent: verb-arming.sh missing denies every Bash tool call, naming the file" {
  run_merge_hook_lib_absent "verb-arming.sh" "echo hi"
  [ "$status" -eq 0 ]
  denied
  grep -qF 'verb-arming.sh' <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# The tree the merge acts on, not the tree the session sits in.
#
# A linked worktree is the same repository, so the repo-scope guard reads a
# leading `cd <worktree> &&` as home and this gate keeps enforcing. What it
# must not keep reading is its own checkout: the merge-base diff and the
# per-tree ledger both belong to the checkout the merge acts on
# (gaia-react/gaia#2013).
# ---------------------------------------------------------------------------

# A linked worktree of REPO, cut from main so its own merge-base diff holds
# only what a case commits there, and provisioned the way REPO itself is.
# Sets WT.
make_worktree() {
  WT="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$WT" main
  install_tree_links "$WT"
}

# Run the hook with an explicit payload cwd. run_merge_hook leaves that field
# unset, which is the shape the cases above want; these cases set it because
# the tree the command targets and the tree the session stands in differ here,
# and the field is how the gate learns the latter.
run_merge_hook_in() {
  local cwd="$1" cmd="$2" json
  json=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')
  invoke_hook_in "$cwd" "$json" "$HOOK_ABS"
}

@test "a leading cd into a linked worktree reads that worktree's changed tests" {
  make_worktree
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST" "$WT"
  run_merge_hook_in "$REPO" "cd $WT && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "renders a label" <<<"$output"
}

@test "a leading cd into a linked worktree does not read the session checkout's changed tests" {
  # The false-deny half. The session's own un-ledgered emergent test belongs to
  # a tree this merge never lands on.
  make_worktree
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook_in "$REPO" "cd $WT && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  refute_denied
}

@test "a matching verdict in the target worktree's own ledger allows the merge" {
  # The ledger is per-tree state, so following the command's target has to
  # reach the ledger lookup as well as the diff.
  make_worktree
  commit_file "app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST" "$WT"
  seed_matching "app/components/Foo/tests/index.test.tsx" "renders a label" "keep" "$WT"
  run_merge_hook_in "$REPO" "cd $WT && gh pr merge 30 --squash"
  [ "$status" -eq 0 ]
  refute_denied
}
