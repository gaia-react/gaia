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
  [ -n "${OTHER_REPO:-}" ] && rm -rf "$OTHER_REPO"
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
  write_registry
}

# The guard reads the exempt set from .gaia/state-registry.json via
# .gaia/scripts/state-registry-lib.sh (linkable shared dirs + wholly
# main-anchored dirs), never a hardcoded list. Every test repo therefore needs a
# registry the reader can find at <main-root>/.gaia/state-registry.json. This is
# a minimal fixture, not the real registry, so the tests exercise the
# registry-read MECHANISM and stay decoupled from the shipped registry's exact
# contents. It carries the four symlinked shared dirs (audit, debt, telemetry,
# cache/shared) plus the symlinked setup-state.json file, the two main-anchored
# ledger dirs (plans, specs) plus worktree-locks, and one main-only FILE
# (cache/gh-artifact-pr.json) that must NOT exempt its cache/ segment.
write_registry() {
  mkdir -p "$REPO/.gaia"
  cat >"$REPO/.gaia/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "block-worktree-path-mismatch test fixture",
  "entries": [
    { "id": "setup-state", "path": "setup-state.json", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "cache-shared", "path": "cache/shared/", "match": "prefix", "kind": "dir", "scope": "shared" },
    { "id": "audit", "path": "audit/*.ok", "match": "glob", "kind": "file", "scope": "shared" },
    { "id": "telemetry", "path": "telemetry/cost.jsonl", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "debt", "path": "debt/count.json", "match": "exact", "kind": "file", "scope": "shared" },
    { "id": "specs", "path": "specs/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "plans", "path": "plans/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "worktree-locks", "path": "worktree-locks/<name>/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "gh-cache", "path": "cache/gh-artifact-pr.json", "match": "exact", "kind": "file", "scope": "main-only" }
  ],
  "residue": [],
  "drop_zones": []
}
JSON
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

# Same delivery contract as run_hook_edit, plus the payload's `cwd` field: the
# working directory Claude Code reports for the agent that issued the call. The
# process cwd stays whatever the test `cd`s to, so the two can be set
# independently and the hook's choice between them is observable.
run_hook_edit_cwd() {
  local tool="$1" path="$2" cwd="$3"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" --arg c "$cwd" \
    '{tool_name: $t, cwd: $c, tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

# An unrelated git repository, used to check that a payload cwd naming some
# other repo is not honored. No commit is needed: `rev-parse` answers
# --show-toplevel and --git-common-dir on an empty repo.
make_other_repo() {
  local raw
  raw=$(mktemp -d -t gaia-wt-mismatch-other-XXXXXX)
  OTHER_REPO="$(cd "$raw" && pwd -P)"
  git -C "$OTHER_REPO" init -q --initial-branch=main
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

# Regression: both roots the guard compares are symlink-canonicalized (main_root
# through the shared resolver, current_root and file_root through `pwd -P`), so
# they stay on the same footing. Reaching the main checkout through a symlinked
# path (an external volume, a cloud-synced folder, or simply a macOS /tmp ->
# /private/tmp style path) resolves to the same physical root either way, so the
# guard does not mistake the main checkout for a linked worktree and deny a
# legitimate main-checkout edit.
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

# create-worktree.sh / link-worktree.sh deliberately symlink a fixed set of
# per-machine working state out of a linked worktree and into the main
# checkout, so audit markers and debt state are shared rather than forked. `git -C` resolves a symlink before computing
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

# link-worktree.sh symlinks a fixed, closed set of shared-state paths, and
# handoff/ is not in it. Most of the rest of .gaia/local/ is per-worktree, so a
# stale pre-switch path into the main checkout's copy is the #841
# silent-wrong-write, not a shared-state write, and must stay denied. Exempting
# the whole .gaia/local/ tree would re-open exactly that. handoff/ stands in for
# the per-worktree remainder here; plans/ and specs/ are the two carve-outs, and
# they get their own cases below.
@test "a stale main-checkout write under non-symlinked .gaia/local is still denied" {
  make_repo
  make_worktree "debt/15-foo" "debt/15-foo"
  mkdir -p "$REPO/.gaia/local/handoff"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/handoff/2026-01-01.md"
  assert_denied
}

# tech-debt #934. plan.md puts the plan folder in the main checkout by contract
# and has the worktree-mode orchestrator write PROGRESS.md back to it after
# every phase. A linked worktree's own .gaia/local/plans/ is empty, so the
# main-checkout path is the ONLY path that resolves to a real ledger: there is
# no valid twin, which is what the #841 silent-wrong-write requires. Denying
# these blocks the sole correct write, costing every worktree-mode plan run its
# phase-findings ledger and its resume point.
@test "a worktree-mode write to the main checkout's .gaia/local/plans ledger is allowed" {
  make_repo
  make_worktree "debt/31-foo" "debt/31-foo"
  mkdir -p "$REPO/.gaia/local/plans/PLAN-001"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/plans/PLAN-001/PROGRESS.md"
  assert_allowed
}

# The spec-colocated arm of the same contract: a plan under
# .gaia/local/specs/<SPEC-ID>/plan/ writes its PROGRESS.md there, and the
# consolidated SUMMARY.md one directory up, both in the main checkout.
@test "a worktree-mode write to the main checkout's .gaia/local/specs ledger is allowed" {
  make_repo
  make_worktree "debt/32-foo" "debt/32-foo"
  mkdir -p "$REPO/.gaia/local/specs/SPEC-009/plan"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/specs/SPEC-009/plan/PROGRESS.md"
  assert_allowed
}

# The plans/specs carve-out is a path-segment match like the shared-state arm
# above, so it must not leak to a sibling that merely shares a prefix.
@test "a main-checkout write to a .gaia/local/plans lookalike sibling is still denied" {
  make_repo
  make_worktree "debt/33-foo" "debt/33-foo"
  mkdir -p "$REPO/.gaia/local/plansible"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/plansible/notes.md"
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

# worktree-locks/ is a wholly main-anchored directory in the registry
# (scope main-only, kind dir) with no worktree-side copy, so a write to it from a
# worktree resolves to main legitimately. It is exempt through
# gaia_registry_main_only_dirs, the same arm as plans/ and specs/, proving that
# arm consumes the whole main-only-dir set rather than a hand-listed plans+specs
# pair.
@test "a worktree-mode write to the main checkout's main-anchored worktree-locks dir is allowed" {
  make_repo
  make_worktree "debt/40-foo" "debt/40-foo"
  mkdir -p "$REPO/.gaia/local/worktree-locks/some-lock"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/worktree-locks/some-lock/lock"
  assert_allowed
}

# The exemption is registry-driven, not a fixed list baked into this hook. A
# directory newly classified `shared` in the registry is exempted here with no
# edit to the guard: this is the structural property that keeps the guard,
# link-worktree.sh, and link-worktree.ts in lockstep off one registry, replacing
# the byte-locked-twin enumeration a hand-maintained list would need. A synthetic
# shared dir the fixture does not otherwise carry proves the guard reads the
# registry rather than a hardcoded set.
@test "a shared dir added to the registry is auto-exempted with no edit to the hook" {
  make_repo
  make_worktree "debt/41-foo" "debt/41-foo"
  jq '.entries += [{ "id": "newshared", "path": "newshared/", "match": "prefix", "kind": "dir", "scope": "shared" }]' \
    "$REPO/.gaia/state-registry.json" >"$REPO/.gaia/state-registry.json.tmp"
  mv "$REPO/.gaia/state-registry.json.tmp" "$REPO/.gaia/state-registry.json"
  mkdir -p "$REPO/.gaia/local/newshared"
  mkdir -p "$WT/.gaia/local"
  ln -s "$REPO/.gaia/local/newshared" "$WT/.gaia/local/newshared"
  cd "$WT"
  run_hook_edit "Write" "$WT/.gaia/local/newshared/marker"
  assert_allowed
}

# The converse of the auto-exempt case: the guard exempts ONLY what the registry
# classifies shared or main-only. A stale main-checkout write into a .gaia/local
# tree the registry does not know stays denied, so the registry-driven exemption
# cannot silently widen to the whole .gaia/local tree.
@test "a stale main-checkout write into a registry-unknown .gaia/local tree is still denied" {
  make_repo
  make_worktree "debt/42-foo" "debt/42-foo"
  mkdir -p "$REPO/.gaia/local/unregistered"
  cd "$WT"
  run_hook_edit "Write" "$REPO/.gaia/local/unregistered/notes.md"
  assert_denied
}

# --- allowed: a sibling worktree, which the guard can no longer adjudicate ---

# The guard adjudicates one question: does the target resolve to the main
# checkout. main_root comes from --git-common-dir, which is identical from every
# worktree of the repo, so that answer holds no matter which worktree the
# calling agent sits in. A sibling worktree is a different, equally valid
# checkout, and judging one agent's write against another agent's worktree would
# deny correct writes, so the guard leaves that to the caller's own
# RESOLVED_ROOT discipline.
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

# A process cwd outside every git repository leaves the hook with no checkout to
# adjudicate in, and this payload names none either, so there is nothing to fall
# back to and the call fails open. The companion case below, where the payload
# DOES name a checkout, is the one that must keep guarding.
@test "a session whose cwd is not inside any git repository fails open (allowed)" {
  make_repo
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$NONREPO"
  run_hook_edit "Edit" "$REPO/f"
  assert_allowed
}

# --- the calling agent's cwd comes from the payload ---

# The payload names the working directory of the agent that issued the call,
# which is the only value that answers "which checkout is this agent in". The
# hook's own process cwd answers "which checkout is this hook process in", a
# different question that coincides only as long as the harness keeps the two
# aligned. Pin the payload as the authority: when it says the agent is in the
# worktree, a target in the main checkout is the wrong-checkout write, no matter
# where the hook process itself sits.
@test "a payload cwd inside the worktree denies a main-checkout target from a main-checkout process cwd" {
  make_repo
  make_worktree "debt/22-foo" "debt/22-foo"
  cd "$REPO"
  run_hook_edit_cwd "Edit" "$REPO/f" "$WT"
  assert_denied
}

# The mirror of the case above: the same payload cwd, targeting that agent's own
# worktree, is the correct write and stays allowed.
@test "a payload cwd inside the worktree allows a worktree target from a main-checkout process cwd" {
  make_repo
  make_worktree "debt/23-foo" "debt/23-foo"
  cd "$REPO"
  run_hook_edit_cwd "Edit" "$WT/f" "$WT"
  assert_allowed
}

# A payload without `cwd` still adjudicates off the process cwd. The rest of
# this suite exercises that path implicitly; this pins it by name so a future
# change cannot drop the fallback silently.
@test "a payload with no cwd field falls back to the process cwd" {
  make_repo
  make_worktree "debt/24-foo" "debt/24-foo"
  cd "$WT"
  run_hook_edit "Edit" "$REPO/f"
  assert_denied
}

# A payload cwd the hook cannot resolve is not a reason to stop guarding. Both
# unusable shapes, a path that does not exist and a real directory outside any
# git repository, fall back to the process cwd rather than going inert.
@test "a payload cwd naming a nonexistent path falls back to the process cwd" {
  make_repo
  make_worktree "debt/25-foo" "debt/25-foo"
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "/no-such-agent-cwd-xyz"
  assert_denied
}

@test "a payload cwd naming a directory outside any git repository falls back to the process cwd" {
  make_repo
  make_worktree "debt/26-foo" "debt/26-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "$NONREPO"
  assert_denied
}

# The payload cwd is authoritative for tree identity whenever it is absolute and
# resolves to a checkout: the guard takes it at its word, with no cross-check
# against the process cwd. A payload naming an unrelated repository therefore
# makes the guard resolve THAT repository, find it is not a linked worktree, and
# stand down. Here the process cwd sits in the main checkout, so the outcome is
# allowed either way; the companion case below, with the process cwd in the
# worktree, is where taking the payload at its word is observable.
@test "a payload cwd inside an unrelated repository is taken at its word (process cwd in main)" {
  make_repo
  make_worktree "debt/27-foo" "debt/27-foo"
  make_other_repo
  cd "$REPO"
  run_hook_edit_cwd "Edit" "$REPO/f" "$OTHER_REPO"
  assert_allowed
}

# The accepted residual of making the payload authoritative (the dropped
# payload-versus-process cross-check). The process cwd is inside the worktree, so
# the old cross-check would have used it and denied the stale main-checkout
# write. The payload names an unrelated repository and is now taken at its word,
# so the guard resolves that repository, sees no linked worktree, and stands
# down. This gives up defense against a harness that ever delivers a well-shaped
# cwd from an unrelated checkout; across every measured configuration the harness
# delivers the acting agent's own tree, never a cross-repository one, so the
# cross-check only ever fired on the false positive it was invented to suppress
# (which was itself a false deny of a legitimate edit). Pinned so a future
# re-introduction of the cross-check is a deliberate, visible decision.
@test "a foreign payload cwd is taken at its word, standing the guard down (accepted residual)" {
  make_repo
  make_worktree "debt/39-foo" "debt/39-foo"
  make_other_repo
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "$OTHER_REPO"
  assert_allowed
}

# The payload cwd is honored only when it is absolute. The absolute check gates
# the payload before it reaches `git -C`, so a relative value is never resolved
# against the hook's own process cwd and mistaken for the agent's tree: `git -C
# linkdir` would otherwise resolve `linkdir` relative to wherever the hook
# process sits. The absolute requirement also shuts the leading-dash door (a
# value like `-P` would option-parse inside a bare `cd`). A relative cwd
# resolving to the main checkout is the observable case: honored, it would read
# the agent as sitting in the main checkout and allow the target; ignored, the
# worktree process cwd stays in charge and denies.
@test "a relative payload cwd is ignored in favour of the process cwd" {
  make_repo
  make_worktree "debt/28-foo" "debt/28-foo"
  ln -s "$REPO" "$WT/linkdir"
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "linkdir"
  assert_denied
}

# The mirror of the load-bearing deny case above, and the one case reading the
# cwd from the payload deliberately loosens: when the payload says the agent is
# in the MAIN checkout, a main-checkout target is that agent's own correct
# write, even though the hook's process cwd sits in a worktree. Adjudicating off
# the process cwd alone denies it.
@test "a payload cwd in the main checkout allows a main-checkout target from a worktree process cwd" {
  make_repo
  make_worktree "debt/29-foo" "debt/29-foo"
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "$REPO"
  assert_allowed
}

# A payload cwd below the main checkout's root, not at it. The shared resolver
# answers "is this a linked worktree" and "where is main" identically from a
# subdirectory as from the root (it resolves git's directory-relative common-dir
# form itself), so the guard reads a main-checkout subdirectory as the main
# checkout, not a worktree, and allows the agent's own main-checkout write. A
# derivation that mishandled the subdirectory case would read it as a worktree
# and deny the correct write.
@test "a payload cwd in a main-checkout subdirectory is read as the main checkout" {
  make_repo
  make_worktree "debt/30-foo" "debt/30-foo"
  mkdir -p "$REPO/sub"
  cd "$WT"
  run_hook_edit_cwd "Edit" "$REPO/f" "$REPO/sub"
  assert_allowed
}

# tech-debt #940. main_root used to derive from the hook's own process cwd even
# after the rest of the adjudication had migrated to the payload cwd, so a hook
# process sitting outside every git repository failed the --git-common-dir call
# and exited before any payload-aware logic ran. The guard went inert for that
# call, and inertness here is an ALLOW: it fails silently rather than loudly.
# Both roots now come from whichever source wins, so a payload cwd naming the
# worktree still adjudicates with no usable process cwd at all.
@test "a payload cwd inside the worktree guards even when the process cwd is outside any git repository" {
  make_repo
  make_worktree "debt/36-foo" "debt/36-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$NONREPO"
  run_hook_edit_cwd "Edit" "$REPO/f" "$WT"
  assert_denied
}

# The mirror of the case above: the same payload cwd, targeting that agent's own
# worktree, is the correct write and stays allowed.
@test "a payload cwd inside the worktree allows its own target when the process cwd is outside any git repository" {
  make_repo
  make_worktree "debt/37-foo" "debt/37-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$NONREPO"
  run_hook_edit_cwd "Edit" "$WT/f" "$WT"
  assert_allowed
}

# The payload is authoritative and both roots come from it, so a target in a
# different repository can never equal the payload repo's main root: a foreign
# payload cwd cannot produce a false deny of an edit in this repo. Here the
# process cwd is outside every repository, confirming the payload alone decides
# regardless of where the hook process sits.
@test "a payload cwd in an unrelated repository cannot deny a target in this repo" {
  make_repo
  make_worktree "debt/38-foo" "debt/38-foo"
  make_other_repo
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$NONREPO"
  run_hook_edit_cwd "Edit" "$REPO/f" "$OTHER_REPO"
  assert_allowed
}

# --- defense in depth: the file_path chain's own two guards ---

# tech-debt #944. `dirname --` and `CDPATH=''` on the target_dir/
# resolved_target_dir pair are unreachable in practice, because
# .claude/skills/gaia/references/isolation.md contracts file_path as an absolute
# path with no cwd resolution, and an absolute path defeats both. The two tests
# below cover them anyway, for a reason specific to this pair: unlike the
# identically-shaped guards on the payload_cwd chain, whose unreachability rests
# on an absolute-cwd invariant THIS script enforces itself, these rest on an
# external convention the script cannot enforce. If the harness ever emits a
# relative file_path, they are the only thing standing there, and without
# coverage a future edit dropping either one regresses in silence. Both cases
# are mutation-verified: each fails against a hook with its guard removed.

# CDPATH killer. With CDPATH honored, `cd inner` resolves through CDPATH into
# the exempt audit tree instead of through the worktree's own `inner` symlink,
# so the write is waved through as shared state while git still resolves it to
# the main checkout: a deny becomes an allow. The CDPATH hit lands on a
# SUBdirectory of the exempt tree deliberately. bash echoes the resolved path to
# stdout whenever cd consults CDPATH, so the mutant's capture is two lines; only
# a match one level below the arm's own directory leaves the trailing `*` free
# to absorb the second line, which is what makes the mutant reach the exemption.
@test "a relative file_path is resolved without CDPATH, so an exempt-tree decoy cannot mask it" {
  make_repo
  make_worktree "debt/34-foo" "debt/34-foo"
  mkdir -p "$REPO/.gaia/local/audit/inner"
  ln -s "$REPO" "$WT/inner"
  cd "$WT"
  export CDPATH="$REPO/.gaia/local/audit"
  run_hook_edit "Write" "inner/f"
  assert_denied
}

# `dirname --` killer. A file_path whose leading component reads as an option
# stops at the `--` terminator and yields `-x`, which the following bare `cd`
# rejects, so the hook fails open the way it does for any unresolvable target.
# Drop the terminator and `dirname` itself option-parses, exiting non-zero under
# `set -e` and aborting the hook mid-adjudication: the status assertion, not the
# verdict, is what separates a clean fail-open from that crash.
@test "a file_path whose dirname component leads with a dash fails open cleanly" {
  make_repo
  make_worktree "debt/35-foo" "debt/35-foo"
  cd "$WT"
  run_hook_edit "Write" "-x/f"
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
