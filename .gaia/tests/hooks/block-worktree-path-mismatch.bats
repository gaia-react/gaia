#!/usr/bin/env bats

# Tests for .claude/hooks/block-worktree-path-mismatch.sh.
#
# Regression coverage for tech-debt #841: once a session has switched into a
# linked worktree, an Edit/Write/MultiEdit call whose file_path resolves to a
# *different* git worktree (most often the main checkout) is a stale
# pre-switch path applied silently, no error, because both paths are real,
# valid files on disk. This guard denies that call deterministically. It is
# a no-op outside a linked-worktree session (feature-branch mode or a plain
# checkout), and fails open on anything it cannot resolve (a target
# directory that does not exist yet, a path outside any git repository).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-worktree-path-mismatch.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${NONREPO:-}" ] && rm -rf "$NONREPO"
  [ -n "${SYMLINK_REPO:-}" ] && rm -f "$SYMLINK_REPO"
  return 0
}

# Canonicalize via `pwd -P` (mirrors .gaia/scripts/tests/link-worktree.bats):
# macOS resolves /var -> /private/var inside `git rev-parse`, and the hook
# compares its own git-derived paths against this raw REPO/NONREPO value, so a
# non-canonical tmp path would desync from what the hook reports and produce
# a false mismatch that has nothing to do with the guard under test.
make_repo() {
  REPO_RAW=$(mktemp -d -t gaia-wt-mismatch-repo-XXXXXX)
  REPO="$(cd "$REPO_RAW" && pwd -P)"
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <rel> <branch>: a real linked worktree at
# <REPO>/.claude/worktrees/<rel>, mirroring how GAIA creates plan/debt
# worktrees. Sets WT to the worktree's absolute path.
make_worktree() {
  local rel="$1" br="$2"
  git -C "$REPO" branch "$br"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
  WT="$REPO/.claude/worktrees/$rel"
}

# Quote-safe delivery (mandatory, mirrors block-manifest-write.bats): pass
# $json and $HOOK_ABS as positional args to an inner bash -c rather than
# re-wrapping in an outer single-quoted string, so embedded quotes in a
# payload path never terminate the wrapper early.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# --- allowed: editing inside the current worktree ---

@test "Edit on a tracked file inside the current worktree is allowed" {
  make_repo
  make_worktree "debt/1-foo" "debt/1-foo"
  cd "$WT"
  run_hook_edit "Edit" "$WT/f"
  assert_allowed
}

@test "Write on a new file under an existing subdirectory of the current worktree is allowed" {
  make_repo
  make_worktree "debt/2-foo" "debt/2-foo"
  mkdir -p "$WT/sub"
  cd "$WT"
  run_hook_edit "Write" "$WT/sub/new.ts"
  assert_allowed
}

@test "MultiEdit on a tracked file inside the current worktree is allowed" {
  make_repo
  make_worktree "debt/3-foo" "debt/3-foo"
  cd "$WT"
  run_hook_edit "MultiEdit" "$WT/f"
  assert_allowed
}

# --- denied: the #841 regression, a stale path into a different checkout ---

@test "Edit targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/4-foo" "debt/4-foo"
  cd "$WT"
  run_hook_edit "Edit" "$REPO/f"
  assert_denied
}

@test "Write targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/5-foo" "debt/5-foo"
  cd "$WT"
  run_hook_edit "Write" "$REPO/new.ts"
  assert_denied
}

@test "MultiEdit targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/6-foo" "debt/6-foo"
  cd "$WT"
  run_hook_edit "MultiEdit" "$REPO/f"
  assert_denied
}

# --- allowed: no linked-worktree session, nothing to guard ---

@test "Edit in the main checkout targeting a worktree's file is allowed (no worktree session active)" {
  make_repo
  make_worktree "debt/7-foo" "debt/7-foo"
  cd "$REPO"
  run_hook_edit "Edit" "$WT/f"
  assert_allowed
}

# Regression: main_root is derived via `cd ... && pwd`, while current_root and
# file_root come from `git rev-parse --show-toplevel`, which always resolves
# symlinks. Reaching the main checkout through a symlinked path (an external
# volume, a cloud-synced folder, or simply a macOS /tmp -> /private/tmp
# style path) used to desync the two, so the guard wrongly believed itself
# inside a linked worktree and denied a legitimate main-checkout edit.
@test "a main checkout reached via a symlinked path allows editing a worktree file" {
  make_repo
  make_worktree "debt/11-foo" "debt/11-foo"
  SYMLINK_REPO="${REPO}-symlink"
  ln -s "$REPO" "$SYMLINK_REPO"
  cd "$SYMLINK_REPO"
  run_hook_edit "Edit" "$WT/f"
  assert_allowed
}

# --- allowed: the shared .gaia/local tree ---

# create-worktree.sh / link-worktree.sh deliberately symlink the per-machine
# working state (.gaia/local/audit, debt, telemetry, setup-state.json) out of a
# linked worktree and into the main checkout, so audit markers and debt state
# are shared rather than forked. `git -C` resolves a symlink before computing
# --show-toplevel, so a write to the worktree's own .gaia/local/audit/ reports
# file_root as the MAIN checkout and looks like a wrong-checkout write. It is
# the intended write: that tree is shared by construction, and nothing under it
# is a reviewed source surface, so the guard skips it.
@test "a write under the worktree's symlinked .gaia/local tree is allowed" {
  make_repo
  make_worktree "debt/12-foo" "debt/12-foo"
  mkdir -p "$REPO/.gaia/local/audit"
  mkdir -p "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local/audit" "$WT/.gaia/local/audit"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/audit/issue-body-abc123.md"
  assert_allowed
}

# The exemption is a path-prefix test, so it must not leak to a sibling whose
# name merely starts with the same characters.
@test "a main-checkout write to a .gaia/local lookalike sibling is still denied" {
  make_repo
  make_worktree "debt/13-foo" "debt/13-foo"
  mkdir -p "$REPO/.gaia/localish"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/localish/notes.md"
  assert_denied
}

# link-worktree.sh symlinks only setup-state.json, cache/shared, audit,
# telemetry, and debt. The rest of .gaia/local/ is per-worktree, so a stale
# pre-switch path into the main checkout's copy is the #841 silent-wrong-write,
# not a shared-state write, and must stay denied. Exempting the whole
# .gaia/local/ tree would re-open exactly the subtree that receives /gaia-plan,
# /gaia-spec, and /gaia-handoff output.
@test "a stale main-checkout write under non-symlinked .gaia/local is still denied" {
  make_repo
  make_worktree "debt/15-foo" "debt/15-foo"
  mkdir -p "$REPO/.gaia/local/plans"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/plans/PLAN-001.md"
  assert_denied
}

@test "a stale main-checkout write under .gaia/local/specs is still denied" {
  make_repo
  make_worktree "debt/16-foo" "debt/16-foo"
  mkdir -p "$REPO/.gaia/local/specs"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/specs/SPEC-009.md"
  assert_denied
}

# The remaining symlinked dirs get the same coverage as audit/, so a future
# narrowing of the exemption cannot silently drop one.
@test "a write under the worktree's symlinked .gaia/local/debt is allowed" {
  make_repo
  make_worktree "debt/17-foo" "debt/17-foo"
  mkdir -p "$REPO/.gaia/local/debt"
  mkdir -p "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local/debt" "$WT/.gaia/local/debt"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/debt/refresh-requested"
  assert_allowed
}

@test "a write under the worktree's symlinked .gaia/local/telemetry is allowed" {
  make_repo
  make_worktree "debt/20-foo" "debt/20-foo"
  mkdir -p "$REPO/.gaia/local/telemetry"
  mkdir -p "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local/telemetry" "$WT/.gaia/local/telemetry"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/telemetry/tally.jsonl"
  assert_allowed
}

@test "a write under the worktree's symlinked .gaia/local/cache/shared is allowed" {
  make_repo
  make_worktree "debt/18-foo" "debt/18-foo"
  mkdir -p "$REPO/.gaia/local/cache/shared"
  mkdir -p "$WT/.gaia/local/cache"
  ln -s "$REPO/.gaia/local/cache/shared" "$WT/.gaia/local/cache/shared"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/cache/shared/blob.json"
  assert_allowed
}

# Only cache/shared is symlinked. The rest of .gaia/local/cache/ is per-worktree
# and holds draft SPEC content, so widening the arm to cache/* would silently
# allow a stale main-checkout write to a draft.
@test "a stale main-checkout write under non-shared .gaia/local/cache is still denied" {
  make_repo
  make_worktree "debt/21-foo" "debt/21-foo"
  mkdir -p "$REPO/.gaia/local/cache"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/cache/draft-SPEC-001.md"
  assert_denied
}

# setup-state.json is a symlinked FILE, so its target_dir is the worktree's own
# real .gaia/local and it never reaches the exemption; the main-checkout test is
# what allows it. Pinned so that path stays covered.
@test "a write to the worktree's symlinked .gaia/local/setup-state.json is allowed" {
  make_repo
  make_worktree "debt/19-foo" "debt/19-foo"
  mkdir -p "$REPO/.gaia/local"
  echo '{}' >"$REPO/.gaia/local/setup-state.json"
  mkdir -p "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local/setup-state.json" "$WT/.gaia/local/setup-state.json"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/setup-state.json"
  assert_allowed
}

# --- allowed: a sibling worktree, which the guard can no longer adjudicate ---

# The hook infers "this session's worktree" from its own process cwd, and that
# cwd is shared across concurrently active agents: when one teammate calls
# EnterWorktree, every other agent's cwd moves with it. Judging agent A's write
# against agent B's worktree denied correct writes. main_root comes from
# --git-common-dir, which is identical from every worktree of the repo, so
# "does the target resolve to the main checkout" stays correct no matter which
# worktree the shared cwd currently sits in. "Is the target MY worktree" does
# not, so it is no longer adjudicated.
@test "an edit to a sibling worktree is allowed while cwd sits in another worktree" {
  make_repo
  make_worktree "debt/14-a" "debt/14-a"
  WT_A="$WT"
  make_worktree "debt/14-b" "debt/14-b"
  cd "$WT"
  run_hook_edit "Edit" "$WT_A/f"
  assert_allowed
}

# --- ignored: not our matcher ---

@test "a Read tool call is ignored" {
  make_repo
  make_worktree "debt/8-foo" "debt/8-foo"
  cd "$WT"
  run_hook_edit "Read" "$REPO/f"
  assert_allowed
}

# --- fail-open: anything the guard cannot resolve ---

@test "a target directory that does not exist yet fails open (allowed)" {
  make_repo
  make_worktree "debt/9-foo" "debt/9-foo"
  cd "$WT"
  run_hook_edit "Write" "/no-such-parent-dir-xyz/new.ts"
  assert_allowed
}

@test "a target outside any git repository fails open (allowed)" {
  make_repo
  make_worktree "debt/10-foo" "debt/10-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$WT"
  run_hook_edit "Edit" "$NONREPO/scratch.txt"
  assert_allowed
}

@test "a session whose cwd is not inside any git repository fails open (allowed)" {
  make_repo
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$NONREPO"
  run_hook_edit "Edit" "$REPO/f"
  assert_allowed
}

# --- structural ---

@test "block-worktree-path-mismatch.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-worktree-path-mismatch.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
