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
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-worktree-path-mismatch.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
  MAIN_ROOT_LIBRARY="$(cd "$HOOKS_SOURCE_DIRECTORY/../.." && pwd)/.gaia/scripts/main-root-lib.sh"
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
  write_registry
}

# The guard reads the exempt set from .gaia/state-registry.json via
# .gaia/scripts/state-registry-lib.sh (gaia_registry_recognizes,
# gaia_registry_classify), never a hardcoded list. Every test repo therefore
# needs a registry the reader can find at <main-root>/.gaia/state-registry.json.
# This is a minimal fixture, not the real registry, so the tests exercise the
# registry-read MECHANISM and stay decoupled from the shipped registry's exact
# contents. It carries the four symlinked shared dirs (audit, debt, telemetry,
# cache/shared) plus the symlinked setup-state.json file, three main-anchored
# dirs (the two real ledgers, plans and specs, plus a synthetic third,
# fixture-main-dir, that exists only to prove the guard's arm consumes the
# whole main-only-dir set rather than a hand-listed pair), one main-only FILE
# (cache/gh-artifact-pr.json) that must NOT exempt its cache/ segment, and one
# per-tree dir (handoff) representing the keyed entries the flip protects.
write_registry() {
  mkdir -p "$REPO/.gaia"
  cat >"$REPO/.gaia/state-registry.json" <<'JSON'
{
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
    { "id": "fixture-main-dir", "path": "fixture-main-dir/<name>/", "match": "prefix", "kind": "dir", "scope": "main-only" },
    { "id": "gh-cache", "path": "cache/gh-artifact-pr.json", "match": "exact", "kind": "file", "scope": "main-only" },
    { "id": "handoff", "path": "handoff/", "match": "prefix", "kind": "dir", "scope": "per-tree" }
  ],
  "residue": []
}
JSON
}

# The acting tree's own gaia_tree_key, computed via the real
# main-root-lib.sh (not fixture-specific; the resolver depends only on git
# layout, never on the registry). Used to construct a per-tree write the
# guard must recognize as this tree's own.
own_tree_key() {
  bash "$MAIN_ROOT_LIBRARY" --tree-key "$1"
}

# make_worktree <worktree_name> <branch>: a real linked worktree at
# <REPO>/.claude/worktrees/<worktree_name>, mirroring how GAIA creates plan/debt
# worktrees. Sets WORKTREE to the worktree's absolute path.
make_worktree() {
  local worktree_name="$1" branch_name="$2"
  git -C "$REPO" branch "$branch_name"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$worktree_name" "$branch_name"
  WORKTREE="$REPO/.claude/worktrees/$worktree_name"
}

# A payload path can carry quotes of its own, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg tool_name "$tool" --arg file_path "$path" '{tool_name: $tool_name, tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# --- allowed: editing inside the current worktree ---

@test "Edit on a tracked file inside the current worktree is allowed" {
  make_repo
  make_worktree "debt/1-foo" "debt/1-foo"
  cd "$WORKTREE"
  run_hook_edit "Edit" "$WORKTREE/f"
  assert_allowed_by_json
}

@test "Write on a new file under an existing subdirectory of the current worktree is allowed" {
  make_repo
  make_worktree "debt/2-foo" "debt/2-foo"
  mkdir -p "$WORKTREE/sub"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/sub/new.ts"
  assert_allowed_by_json
}

@test "MultiEdit on a tracked file inside the current worktree is allowed" {
  make_repo
  make_worktree "debt/3-foo" "debt/3-foo"
  cd "$WORKTREE"
  run_hook_edit "MultiEdit" "$WORKTREE/f"
  assert_allowed_by_json
}

# --- denied: the #841 regression, a stale path into a different checkout ---

@test "Edit targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/4-foo" "debt/4-foo"
  cd "$WORKTREE"
  run_hook_edit "Edit" "$REPO/f"
  assert_denied_by_json
}

@test "Write targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/5-foo" "debt/5-foo"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/new.ts"
  assert_denied_by_json
}

@test "MultiEdit targeting the main checkout while the session is inside the worktree is denied" {
  make_repo
  make_worktree "debt/6-foo" "debt/6-foo"
  cd "$WORKTREE"
  run_hook_edit "MultiEdit" "$REPO/f"
  assert_denied_by_json
}

# --- allowed: no linked-worktree session, nothing to guard ---

@test "Edit in the main checkout targeting a worktree's file is allowed (no worktree session active)" {
  make_repo
  make_worktree "debt/7-foo" "debt/7-foo"
  cd "$REPO"
  run_hook_edit "Edit" "$WORKTREE/f"
  assert_allowed_by_json
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
  run_hook_edit "Edit" "$WORKTREE/f"
  assert_allowed_by_json
}

# --- allowed: the shared .gaia/local tree ---

# link-worktree.sh deliberately symlinks a linked worktree's per-machine working
# state out to the main checkout, so audit markers and debt state are shared
# rather than forked. `git -C` resolves a symlink before computing
# --show-toplevel, so a write to the worktree's own .gaia/local/audit/ reports
# file_root as the MAIN checkout and looks like a wrong-checkout write. It is
# the intended write: that tree is shared by construction, and nothing under it
# is a reviewed source surface, so the guard skips it.
@test "a write under the worktree's symlinked .gaia/local tree is allowed" {
  make_repo
  make_worktree "debt/12-foo" "debt/12-foo"
  mkdir -p "$REPO/.gaia/local/audit"
  mkdir -p "$WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local/audit" "$WORKTREE/.gaia/local/audit"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/audit/issue-body-abc123.md"
  assert_allowed_by_json
}

# The exemption is a path-prefix test, so it must not leak to a sibling whose
# name merely starts with the same characters.
@test "a main-checkout write to a .gaia/local lookalike sibling is still denied" {
  make_repo
  make_worktree "debt/13-foo" "debt/13-foo"
  mkdir -p "$REPO/.gaia/localish"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/localish/notes.md"
  assert_denied_by_json
}

# link-worktree.sh now symlinks the worktree's whole .gaia/local wholesale to
# main's own .gaia/local, so a write into ANY subpath of it -- handoff/
# included -- physically resolves to main and would otherwise look like the
# #841 silent-wrong-write. handoff/ is per-tree scope, so its protection is no
# longer "was this write symlinked in", it is "does the path carry the ACTING
# tree's own key" (gaia_tree_key, .gaia/scripts/main-root-lib.sh). The three
# cases below are the guard's whole remaining per-tree contract: the acting
# tree's own keyed subtree is the correct write and stays allowed; a peer
# tree's keyed subtree, or the bare unkeyed container, is exactly the
# #841-shaped mistake and stays denied.

@test "a worktree-mode write to its own keyed handoff subtree in the main checkout is allowed" {
  make_repo
  make_worktree "debt/15-foo" "debt/15-foo"
  own_key="$(own_tree_key "$WORKTREE")"
  mkdir -p "$REPO/.gaia/local/handoff/$own_key"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/handoff/$own_key/HANDOFF-2026-01-01.md"
  assert_allowed_by_json
}

@test "a worktree-mode write to a PEER tree's keyed handoff subtree in the main checkout is denied" {
  make_repo
  make_worktree "debt/15b-foo" "debt/15b-foo"
  peer_key="deadbeefdeadbeef"
  own_key="$(own_tree_key "$WORKTREE")"
  [ "$peer_key" != "$own_key" ]
  mkdir -p "$REPO/.gaia/local/handoff/$peer_key"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/handoff/$peer_key/HANDOFF-2026-01-01.md"
  assert_denied_by_json
  # The refusal has to name the key, not repeat the generic stale-path advice.
  # Re-resolving the repository root does not move a path that reaches main
  # through the one .gaia/local symlink, so the generic message would send the
  # caller round a loop it cannot exit -- which is how a loud refusal becomes
  # useless without ever going silent.
  grep -qF -- "$own_key" <<<"$output" || return 1
  grep -qF -- "git rev-parse --show-toplevel" <<<"$output" && return 1
  return 0
}

@test "a worktree-mode write to the bare unkeyed handoff container in the main checkout is denied" {
  make_repo
  make_worktree "debt/15c-foo" "debt/15c-foo"
  mkdir -p "$REPO/.gaia/local/handoff"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/handoff/HANDOFF-2026-01-01.md"
  assert_denied_by_json
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
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/plans/PLAN-001/PROGRESS.md"
  assert_allowed_by_json
}

# The spec-colocated arm of the same contract: a plan under
# .gaia/local/specs/<SPEC-ID>/plan/ writes its PROGRESS.md there, and the
# consolidated SUMMARY.md one directory up, both in the main checkout.
@test "a worktree-mode write to the main checkout's .gaia/local/specs ledger is allowed" {
  make_repo
  make_worktree "debt/32-foo" "debt/32-foo"
  mkdir -p "$REPO/.gaia/local/specs/SPEC-009/plan"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/specs/SPEC-009/plan/PROGRESS.md"
  assert_allowed_by_json
}

# The plans/specs carve-out is a path-segment match like the shared-state arm
# above, so it must not leak to a sibling that merely shares a prefix.
@test "a main-checkout write to a .gaia/local/plans lookalike sibling is still denied" {
  make_repo
  make_worktree "debt/33-foo" "debt/33-foo"
  mkdir -p "$REPO/.gaia/local/plansible"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/plansible/notes.md"
  assert_denied_by_json
}

# Copies the shipped registry into the fixture repo, replacing the minimal
# fixture write_registry laid down. Only the runs/ cases below use it: they must
# prove the shipped `runs` entry (not the fixture) is what lets the write
# through. GAIA_TEST_REGISTRY_SRC lets a mutation run point it at a scratch copy.
use_real_registry() {
  cp "${GAIA_TEST_REGISTRY_SRC:-$BATS_TEST_DIRNAME/../../../.gaia/state-registry.json}" \
    "$REPO/.gaia/state-registry.json"
}

# The execution doctrine writes .gaia/local/runs/<key>/STATE.md through Bash
# in the main checkout's shared store; the shipped registry registers runs/ as
# a shared prefix so a linked worktree's write to it is not an unregistered path.
@test "a worktree-mode write to the main checkout's .gaia/local/runs folder is allowed (real registry)" {
  make_repo
  use_real_registry
  make_worktree "feat/9-sample" "feat/9-sample"
  mkdir -p "$REPO/.gaia/local/runs/feat/9-sample"
  echo state >"$REPO/.gaia/local/runs/feat/9-sample/STATE.md"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/runs/feat/9-sample/STATE.md"
  assert_allowed_by_json
}

# Pairs with the case above: same payload shape and real registry, an
# unregistered sibling. Without it the allow could be a blanket allow.
@test "a worktree-mode write to an unregistered runsx sibling is denied (real registry)" {
  make_repo
  use_real_registry
  make_worktree "feat/9-sample-b" "feat/9-sample-b"
  mkdir -p "$REPO/.gaia/local/runsx/feat/9-sample"
  echo state >"$REPO/.gaia/local/runsx/feat/9-sample/STATE.md"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/runsx/feat/9-sample/STATE.md"
  assert_denied_by_json
  grep -qF -- "no entry in .gaia/state-registry.json recognizes it" <<<"$output" || return 1
}

# The protected folder is recognized as an ancestor of the two registered
# rows, and its scope is not per-tree, so a linked worktree's write to a file
# directly under it lands in main's copy and is allowed here. Refusing Claude's
# write to it is block-audit-loop-write.sh's job, not this hook's.
@test "a worktree-mode write to an unregistered file under the main checkout's protected folder is allowed (real registry)" {
  make_repo
  use_real_registry
  make_worktree "feat/9-sample-c" "feat/9-sample-c"
  mkdir -p "$REPO/.gaia/local/protected"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/protected/new-state.json"
  assert_allowed_by_json
}

@test "a worktree-mode write to the registered protected override file is allowed (real registry)" {
  make_repo
  use_real_registry
  make_worktree "feat/9-sample-d" "feat/9-sample-d"
  mkdir -p "$REPO/.gaia/local/protected"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/protected/checkpoint-override.json"
  assert_allowed_by_json
}

# Paired deny control for the two allows above: with both protected rows gone
# the same write is denied, so the allow is the registry's recognition and not
# a failed cd or a blanket allow.
@test "a worktree-mode write under protected is denied once both protected rows are removed (real registry)" {
  make_repo
  use_real_registry
  jq '.entries |= map(select(.id != "audit-loop-state" and .id != "checkpoint-override"))' \
    "$REPO/.gaia/state-registry.json" >"$REPO/.gaia/state-registry.json.new"
  mv "$REPO/.gaia/state-registry.json.new" "$REPO/.gaia/state-registry.json"
  make_worktree "feat/9-sample-e" "feat/9-sample-e"
  mkdir -p "$REPO/.gaia/local/protected"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/protected/new-state.json"
  assert_denied_by_json
  grep -qF -- "no entry in .gaia/state-registry.json recognizes it" <<<"$output" || return 1
}

# The remaining symlinked dirs get the same coverage as audit/, so a future
# narrowing of the exemption cannot silently drop one.
@test "a write under the worktree's symlinked .gaia/local/debt is allowed" {
  make_repo
  make_worktree "debt/17-foo" "debt/17-foo"
  mkdir -p "$REPO/.gaia/local/debt"
  mkdir -p "$WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local/debt" "$WORKTREE/.gaia/local/debt"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/debt/refresh-requested"
  assert_allowed_by_json
}

@test "a write under the worktree's symlinked .gaia/local/telemetry is allowed" {
  make_repo
  make_worktree "debt/20-foo" "debt/20-foo"
  mkdir -p "$REPO/.gaia/local/telemetry"
  mkdir -p "$WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local/telemetry" "$WORKTREE/.gaia/local/telemetry"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/telemetry/tally.jsonl"
  assert_allowed_by_json
}

@test "a write under the worktree's symlinked .gaia/local/cache/shared is allowed" {
  make_repo
  make_worktree "debt/18-foo" "debt/18-foo"
  mkdir -p "$REPO/.gaia/local/cache/shared"
  mkdir -p "$WORKTREE/.gaia/local/cache"
  ln -s "$REPO/.gaia/local/cache/shared" "$WORKTREE/.gaia/local/cache/shared"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/cache/shared/blob.json"
  assert_allowed_by_json
}

# Once .gaia/local is one shared symlink, cache/ has no worktree-side copy at
# all -- draft SPEC content included -- so denying a write into it protects
# nothing; it only blocks the sole correct write (tech-debt #934's class).
# cache/ is a recognized container (an ancestor of cache/shared/ and the
# main-only cache/gh-artifact-pr.json entry) and holds no per-tree entry, so
# it is allowed the same way debt/, telemetry/, and audit/ already are above.
@test "a write under .gaia/local/cache is allowed (no worktree-side copy exists to protect)" {
  make_repo
  make_worktree "debt/21-foo" "debt/21-foo"
  mkdir -p "$REPO/.gaia/local/cache"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/cache/draft-SPEC-001.md"
  assert_allowed_by_json
}

# setup-state.json is a symlinked FILE, so its target_dir is the worktree's own
# real .gaia/local and it never reaches the exemption; the main-checkout test is
# what allows it. Pinned so that path stays covered.
@test "a write to the worktree's symlinked .gaia/local/setup-state.json is allowed" {
  make_repo
  make_worktree "debt/19-foo" "debt/19-foo"
  mkdir -p "$REPO/.gaia/local"
  echo '{}' >"$REPO/.gaia/local/setup-state.json"
  mkdir -p "$WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local/setup-state.json" "$WORKTREE/.gaia/local/setup-state.json"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/setup-state.json"
  assert_allowed_by_json
}

# fixture-main-dir/ is a synthetic third main-only directory in the fixture
# registry (scope main-only, kind dir) with no worktree-side copy, so a write
# to it from a worktree resolves to main legitimately. It is exempt through
# gaia_registry_main_only_dirs, the same arm as plans/ and specs/, proving that
# arm consumes the whole main-only-dir set rather than a hand-listed plans+specs
# pair.
@test "a worktree-mode write to the main checkout's main-anchored fixture-main-dir is allowed" {
  make_repo
  make_worktree "debt/40-foo" "debt/40-foo"
  mkdir -p "$REPO/.gaia/local/fixture-main-dir/some-lock"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/fixture-main-dir/some-lock/lock"
  assert_allowed_by_json
}

# The exemption is registry-driven (gaia_registry_recognizes +
# gaia_registry_classify), not a fixed list baked into this hook. A directory
# newly classified `shared` in the registry is exempted here with no edit to
# the guard: this is the structural property that keeps the guard
# and link-worktree.sh in lockstep off one registry,
# replacing the byte-locked-twin enumeration a hand-maintained list would
# need. A synthetic shared dir the fixture does not otherwise carry proves
# the guard reads the registry rather than a hardcoded set.
@test "a shared dir added to the registry is auto-exempted with no edit to the hook" {
  make_repo
  make_worktree "debt/41-foo" "debt/41-foo"
  jq '.entries += [{ "id": "newshared", "path": "newshared/", "match": "prefix", "kind": "dir", "scope": "shared" }]' \
    "$REPO/.gaia/state-registry.json" >"$REPO/.gaia/state-registry.json.tmp"
  mv "$REPO/.gaia/state-registry.json.tmp" "$REPO/.gaia/state-registry.json"
  mkdir -p "$REPO/.gaia/local/newshared"
  mkdir -p "$WORKTREE/.gaia/local"
  ln -s "$REPO/.gaia/local/newshared" "$WORKTREE/.gaia/local/newshared"
  cd "$WORKTREE"
  run_hook_edit "Write" "$WORKTREE/.gaia/local/newshared/marker"
  assert_allowed_by_json
}

# The converse of the auto-exempt case: the guard exempts ONLY what the
# registry recognizes, by direct entry or as an ancestor of one. A stale
# main-checkout write into a .gaia/local tree the registry has never heard of
# (no entry, and no registered descendant) stays denied, so the
# registry-driven exemption cannot silently widen to the whole .gaia/local
# tree.
@test "a stale main-checkout write into a registry-unknown .gaia/local tree is still denied" {
  make_repo
  make_worktree "debt/42-foo" "debt/42-foo"
  mkdir -p "$REPO/.gaia/local/unregistered"
  cd "$WORKTREE"
  run_hook_edit "Write" "$REPO/.gaia/local/unregistered/notes.md"
  assert_denied_by_json
  # An unregistered path under .gaia/local is denied because the guard cannot
  # tell shared state from per-tree state without a registry row, and it must
  # say that rather than blame a stale path -- the same reason as the peer-key
  # case: re-resolving the root cannot move a path that reaches main through
  # the one symlink.
  grep -qF -- ".gaia/state-registry.json" <<<"$output" || return 1
  grep -qF -- "git rev-parse --show-toplevel" <<<"$output" && return 1
  return 0
}

# --- denied: a sibling worktree, the same wrong-checkout write as #841 ---

# The guard adjudicates one question: does the target resolve into the acting
# tree. A sibling worktree is a different, equally valid checkout, so a write
# from this worktree into a sibling's file is the same silent-wrong-write a stale
# main-checkout path is: a real, valid file in another checkout the edit tools
# apply with no error. The acting tree comes from the process cwd.
@test "an edit to a sibling worktree is denied while cwd sits in another worktree" {
  make_repo
  make_worktree "debt/14-a" "debt/14-a"
  SIBLING_WORKTREE="$WORKTREE"
  make_worktree "debt/14-b" "debt/14-b"
  cd "$WORKTREE"
  run_hook_edit "Edit" "$SIBLING_WORKTREE/f"
  assert_denied_by_json
}

# --- ignored: not our matcher ---

@test "a Read tool call is ignored" {
  make_repo
  make_worktree "debt/8-foo" "debt/8-foo"
  cd "$WORKTREE"
  run_hook_edit "Read" "$REPO/f"
  assert_allowed_by_json
}

# --- fail-open: anything the guard cannot resolve ---

@test "a target directory that does not exist yet fails open (allowed)" {
  make_repo
  make_worktree "debt/9-foo" "debt/9-foo"
  cd "$WORKTREE"
  run_hook_edit "Write" "/no-such-parent-dir-xyz/new.ts"
  assert_allowed_by_json
}

@test "a target outside any git repository fails open (allowed)" {
  make_repo
  make_worktree "debt/10-foo" "debt/10-foo"
  NONREPO=$(mktemp -d -t gaia-wt-mismatch-nonrepo-XXXXXX)
  cd "$WORKTREE"
  run_hook_edit "Edit" "$NONREPO/scratch.txt"
  assert_allowed_by_json
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
  assert_allowed_by_json
}

# --- defense in depth: the file_path chain's own two guards ---

# tech-debt #944. `dirname --` and `CDPATH=''` on the target_dir/
# resolved_target_dir pair are unreachable in practice, because
# .claude/skills/gaia/references/isolation.md contracts file_path as an absolute
# path with no cwd resolution, and an absolute path defeats both. The two tests
# below cover them anyway: that contract rests on an external convention the
# script cannot enforce, so if the harness ever emits a relative file_path,
# they are the only thing standing there, and without coverage a future edit
# dropping either one regresses in silence. Both cases are mutation-verified:
# each fails against a hook with its guard removed.

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
  ln -s "$REPO" "$WORKTREE/inner"
  cd "$WORKTREE"
  export CDPATH="$REPO/.gaia/local/audit"
  run_hook_edit "Write" "inner/f"
  assert_denied_by_json
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
  cd "$WORKTREE"
  run_hook_edit "Write" "-x/f"
  assert_allowed_by_json
}

# --- structural ---

@test "block-worktree-path-mismatch.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' block-worktree-path-mismatch.sh
}

# --- library-load degradation (gaia-react/gaia#1556) ------------------------
# These run a COPY of the hook staged inside the tmp repo, so the .gaia/scripts
# it resolves off BASH_SOURCE is one the test controls. Running $HOOK_ABSOLUTE_PATH would
# always resolve the real checkout's libs, where neither the absent nor the
# unparseable case can be expressed.
#
# Two ways a library goes unusable, and this fail-open guard must allow through
# both: it is gone, and it is present but does not parse (an unresolved merge
# conflict, a truncated write). Under `set -e` a failed `.` abandons the shell
# in both cases, at different cost: a file bash cannot open exits 1, an
# advisory that lets the edit through with a raw diagnostic on stderr, while
# one it cannot parse exits 2, the PreToolUse deny code, which turns this
# fail-open guard into one that blocks a legitimate edit.
#
# Both libraries get the pair, and state-registry-lib.sh is not the redundant
# half: it never fails open on its own. gaia_registry_recognizes is consulted
# from inside an `if` condition, so an undefined function reads as "no entry
# recognizes this path" and routes the write to the unregistered DENY arm.
#
# The controls are what give the four cases teeth: their assertions (exit 0, no
# deny) are equally satisfied by a hook that adjudicates nothing at all, so each
# interpreter gets a control proving the same staging still DENIES.
stage_hook_repo() {
  make_repo
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  STAGED_HOOK="$REPO/.claude/hooks/block-worktree-path-mismatch.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
  # The jq-availability arm loads ahead of both libraries these cases degrade,
  # and refuses when it cannot find its own, so a staging without it answers
  # every case below with that refusal rather than the degrade under test.
  cp "${HOOK_ABSOLUTE_PATH%/*}/lib/jq-availability.sh" "$REPO/.claude/hooks/lib/"
  cp "${MAIN_ROOT_LIBRARY%/*}/main-root-lib.sh" "${MAIN_ROOT_LIBRARY%/*}/state-registry-lib.sh" \
    "$REPO/.gaia/scripts/"
  make_worktree "debt/lib-degrade" "debt/lib-degrade"
}

# run_staged_hook <path> <cwd> [interpreter]: runs the staged hook with its
# process cwd at <cwd>, which is what the acting tree now resolves from.
run_staged_hook() {
  local json interpreter="${3:-bash}"
  json=$(jq -n --arg file_path "$1" '{tool_name: "Edit", tool_input: {file_path: $file_path}}')
  run bash -c 'cd "$1" && printf %s "$2" | "$3" "$4"' _ "$2" "$json" "$interpreter" "$STAGED_HOOK"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "staged hook, both libs usable: still denies the cross-tree write (control)" {
  stage_hook_repo
  run_staged_hook "$REPO/f" "$WORKTREE"
  assert_denied_by_json
}

# The stock-/bin/bash control. Without it the /bin/bash-pinned cases below would
# stay green if the staged hook stopped adjudicating entirely under 3.2.
@test "staged hook under stock /bin/bash, both libs usable: still denies (control)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  run_staged_hook "$REPO/f" "$WORKTREE" /bin/bash
  assert_denied_by_json
}

# The four cases below are pinned to stock /bin/bash, and it is the pin rather
# than the failure mode that decides. Both loads carried `|| exit 0` before this
# change, and bash 5 reaches that arm for a missing file AND for an unparseable
# one, so only 3.2 tells the parse check apart from the form it replaced.
# Measured both ways on this machine: 3.2.57 exits 1 (missing) and 2
# (unparseable) on the old form and 0 on the new, 5.3.15 exits 0 on both forms.
# On a bash-5 /bin/bash (Linux CI) all four pass either way.
@test "staged hook whose main-root-lib.sh is absent, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  rm -f "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "$REPO/f" "$WORKTREE" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The registry reader loads at its point of use rather than beside the
# resolver, so reaching it takes a write under .gaia/local naming a path the
# registry does not recognize -- the arm that would otherwise DENY. A payload
# aimed anywhere else never loads the lib at all, and a case written that way
# would green against any spelling of this load, including no load whatsoever.
stage_unregistered_local_target() {
  UNREGISTERED_DIRECTORY="$REPO/.gaia/local/fixture-unregistered"
  mkdir -p "$UNREGISTERED_DIRECTORY"
}

# The control for the pair below: with the reader usable, this exact path is
# the DENY the fail-open cases must be shown flipping.
@test "staged hook, registry usable: an unregistered .gaia/local write is denied (control)" {
  stage_hook_repo
  stage_unregistered_local_target
  run_staged_hook "$UNREGISTERED_DIRECTORY/x" "$WORKTREE"
  assert_denied_by_json
}

@test "staged hook under stock /bin/bash, registry usable: the same write is denied (control)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  stage_unregistered_local_target
  run_staged_hook "$UNREGISTERED_DIRECTORY/x" "$WORKTREE" /bin/bash
  assert_denied_by_json
}

@test "staged hook whose state-registry-lib.sh is absent, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  stage_unregistered_local_target
  rm -f "$REPO/.gaia/scripts/state-registry-lib.sh"

  run_staged_hook "$UNREGISTERED_DIRECTORY/x" "$WORKTREE" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staged hook whose main-root-lib.sh holds conflict markers, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  write_conflicted_library "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "$REPO/f" "$WORKTREE" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "staged hook whose state-registry-lib.sh holds conflict markers, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  stage_unregistered_local_target
  write_conflicted_library "$REPO/.gaia/scripts/state-registry-lib.sh"

  run_staged_hook "$UNREGISTERED_DIRECTORY/x" "$WORKTREE" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
