#!/usr/bin/env bats

# Tests for .claude/hooks/audit-stamp-trailer.sh.
#
# Covers all 4 stamp paths plus every refusal case from the frozen stamp
# invariant (.gaia/local/plans/code-review-audit-ci/trailer-format.md):
#   1. clean tree, un-pushed HEAD          -> amend
#   2. clean tree, pushed HEAD             -> empty commit (no auto-push)
#   3. AUDIT_SELF_HEALED=true               -> amend regardless of push status
#   4. detached HEAD (CI checkout)         -> empty commit (no auto-push)
#   5. tree dirty                           -> decline "tree dirty"
#   5b. dirty ONLY from .claude-pr/ runtime  -> stamps (artifact ignored)
#   5c. .claude-pr/ PLUS real dirt           -> decline "tree dirty"
#   6. .gaia/VERSION missing                -> decline "version file missing"
#   7. .gaia/VERSION empty                  -> decline "version file empty"
#   8. AUDIT_TREE_SHA != current tree       -> decline "tree changed since audit started"
#   9. not in a git repo                    -> decline "not in a git repo"
#   10. member-aware gate (mixed diff)      -> decline "members pending <list>" while a
#                                               co-dispatched member withholds; stamps once
#                                               every dispatched member has cleared; a
#                                               single-required-member diff still stamps (no
#                                               deadlock); resolver absent falls back unchanged
#
# The helper never pushes; the agent caller pushes after writing the
# audit marker (see .claude/agents/code-review-audit.md "Audit marker
# (gate handshake)"). Marker-before-push ensures a stamp commit never
# reaches remote history without a corresponding marker.
#
# Each test asserts:
#   - exit code (always 0 for stamp + decline cases)
#   - stdout marker line (`stamp: ...` exact match)
#   - presence/absence of the GAIA-Audit trailer on resulting HEAD
#     (parsed via `git interpret-trailers --parse`)
#   - HEAD sha movement (amend or empty commit moves it; decline does not)
#   - bare upstream is NOT advanced for empty-commit cases (helper never pushes)

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/audit-stamp-trailer.sh
  REPO=$(mktemp -d -t audit-stamp-test-XXXXXX)
  REMOTE=$(mktemp -d -t audit-stamp-remote-XXXXXX)

  # Bare upstream so we can simulate a "pushed" HEAD.
  git -C "$REMOTE" init --bare --quiet --initial-branch=main

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  mkdir -p "$REPO/.gaia"
  printf '1.2.3\n' > "$REPO/.gaia/VERSION"

  # Mirrors the real repo's tracked .gitignore entry for .gaia/local/ (audit
  # markers live there). Without it, a marker a member-aware test writes is an
  # untracked file and the hook's own dirty-tree precondition declines before
  # the member-aware gate is ever reached.
  echo ".gaia/local/" > "$REPO/.gitignore"

  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add .gaia/VERSION .gitignore README.md
  git -C "$REPO" commit --quiet -m "init"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${REMOTE:-}" ] && rm -rf "$REMOTE" || true
  [ -n "${OUTSIDE:-}" ] && rm -rf "$OUTSIDE" || true
  return 0
}

# Helper: link the local repo to the bare upstream and push HEAD.
push_head_to_upstream() {
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push --quiet --set-upstream origin main
}

# Helper: print the GAIA-Audit trailer line(s) on HEAD (empty if none).
trailer_on_head() {
  git -C "$REPO" log -1 --format='%B' \
    | git -C "$REPO" interpret-trailers --parse \
    | grep '^GAIA-Audit:' || true
}

# Helper: copy the real resolver and the shared libs it resolves relative to
# itself into the sandbox, so the hook's member-aware gate has something to
# find at "$REPO/.gaia/scripts/resolve-audit-members.sh".
install_resolver() {
  local src lib
  src="$(cd "$BATS_TEST_DIRNAME/../../../.gaia/scripts" && pwd)/resolve-audit-members.sh"
  mkdir -p "$REPO/.gaia/scripts"
  cp "$src" "$REPO/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"
  lib="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$lib/audit-scope.sh"     "$REPO/.claude/hooks/lib/audit-scope.sh"
  cp "$lib/audit-machinery.sh" "$REPO/.claude/hooks/lib/audit-machinery.sh"
  cp "$lib/audit-clearance.sh" "$REPO/.claude/hooks/lib/audit-clearance.sh"
  # Commit the resolver + libs onto the current branch: untracked, they would
  # trip the stamp hook's OWN tree-dirty precondition (unlike
  # post-audit-status.sh, this hook checks tree cleanliness). Committing here,
  # before any test creates its feature branch, also keeps them out of that
  # branch's diff, so they never affect member dispatch for the test's change.
  git -C "$REPO" add .gaia/scripts .claude/hooks/lib
  git -C "$REPO" commit --quiet -m "install resolver"
}

# Write a writer-shaped schema-2 EARNED clearance for MEMBER, keyed to $REPO's
# HEAD tree. code-audit-frontend is infix-free (<tree>.ok); a specialized
# member carries a ".<member>" infix (<tree>.<member>.ok).
write_marker() {
  local member="$1" tree sha path sidecar
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  sha=$(git -C "$REPO" rev-parse HEAD)
  if [ "$member" = "code-audit-frontend" ]; then
    path="$REPO/.gaia/local/audit/${tree}.ok"
    sidecar="true"
  else
    path="$REPO/.gaia/local/audit/${tree}.${member}.ok"
    sidecar="false"
  fi
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":2,"member":"%s","provenance":"earned","sha":"%s","tree":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$sha" "$tree" "$sidecar" > "$path"
}

# Commit a mixed app/ + .gaia/**/*.sh change on a new `feature` branch off
# REPO's init commit, so the resolver's merge-base(HEAD, main) diff is
# non-empty and dispatches both code-audit-frontend (app/) and
# code-audit-maintainer-shell (.gaia/**/*.sh) against the built-in roster.
commit_mixed_diff() {
  git -C "$REPO" checkout --quiet -b feature
  mkdir -p "$REPO/app" "$REPO/.gaia/scripts"
  echo "export const x = 1;" > "$REPO/app/x.ts"
  echo "#!/bin/bash" > "$REPO/.gaia/scripts/example.sh"
  git -C "$REPO" add app/x.ts .gaia/scripts/example.sh
  git -C "$REPO" commit --quiet -m "mixed change"
}

# -----------------------------------------------------------------------------
# Stamp paths
# -----------------------------------------------------------------------------

@test "clean tree + un-pushed HEAD: amends and writes trailer" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test "clean tree + pushed HEAD: writes empty commit locally (no auto-push)" {
  push_head_to_upstream

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)
  before_remote_sha=$(git -C "$REMOTE" rev-parse main)

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: empty commit (created locally)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  after_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  after_count=$(git -C "$REPO" rev-list --count HEAD)

  [ "$before_sha" != "$after_sha" ]
  # Empty commit -> tree unchanged, history grows by one.
  [ "$before_tree" = "$after_tree" ]
  [ $((after_count - before_count)) -eq 1 ]

  subject=$(git -C "$REPO" log -1 --format='%s')
  [ "$subject" = "chore: code review audit passed" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]

  # Helper never pushes; upstream must NOT have advanced. The caller
  # pushes after writing the audit marker.
  after_remote_sha=$(git -C "$REMOTE" rev-parse main)
  [ "$before_remote_sha" = "$after_remote_sha" ]
}

@test "AUDIT_SELF_HEALED=true on un-pushed HEAD: amends" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="true" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto audit-self-heal HEAD" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test "detached HEAD: writes empty commit (treats as pushed; helper never pushes)" {
  # Simulate the CI checkout: actions/checkout with `ref: <sha>` lands
  # on a detached HEAD. Without an upstream probe, the script must NOT
  # fall through to the un-pushed amend path; that would rewrite a
  # commit the runner does not own.
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)

  # Detach HEAD onto the same commit (no branch, no upstream).
  git -C "$REPO" checkout --quiet --detach HEAD

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: empty commit (created locally)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  after_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  after_count=$(git -C "$REPO" rev-list --count HEAD)

  # Empty commit -> sha advances, tree unchanged, history grows by one.
  [ "$before_sha" != "$after_sha" ]
  [ "$before_tree" = "$after_tree" ]
  [ $((after_count - before_count)) -eq 1 ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test "AUDIT_SELF_HEALED=true on pushed HEAD: still amends (audit owns the commit)" {
  push_head_to_upstream

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="true" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto audit-self-heal HEAD" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  after_count=$(git -C "$REPO" rev-list --count HEAD)

  # Amend, not new commit.
  [ "$before_sha" != "$after_sha" ]
  [ "$before_count" = "$after_count" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

# -----------------------------------------------------------------------------
# Decline paths
# -----------------------------------------------------------------------------

@test "tree dirty: declines and does not move HEAD" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  echo "uncommitted" >> "$REPO/README.md"

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: tree dirty" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test "dirty ONLY from .claude-pr/ runtime artifacts: stamps anyway" {
  # claude-code-action mirrors the repo into .claude-pr/ for sandboxed
  # execution, leaving it untracked. That is not audit output and must not
  # block the stamp. Without the exclusion this declines "tree dirty".
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  mkdir -p "$REPO/.claude-pr/.claude/agents"
  echo "mirror" > "$REPO/.claude-pr/.claude/agents/code-review-audit.md"
  echo "mirror" > "$REPO/.claude-pr/settings.json"

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test ".claude-pr/ artifacts PLUS a real dirty file: still declines" {
  # The exclusion is scoped to .claude-pr/ only; genuine uncommitted audit
  # work outside it must still block the stamp.
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  mkdir -p "$REPO/.claude-pr"
  echo "mirror" > "$REPO/.claude-pr/x"
  echo "uncommitted" >> "$REPO/README.md"

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: tree dirty" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test ".gaia/VERSION missing: declines and does not move HEAD" {
  rm "$REPO/.gaia/VERSION"
  # The removal itself dirties the tree; commit so we can isolate the
  # version-file precondition from the tree-dirty precondition.
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "remove version"

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: version file missing" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test ".gaia/VERSION empty: declines and does not move HEAD" {
  : > "$REPO/.gaia/VERSION"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "blank version"

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: version file empty" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test "AUDIT_TREE_SHA mismatch: declines and does not move HEAD" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  fake_tree="0000000000000000000000000000000000000000"

  cd "$REPO"
  AUDIT_TREE_SHA="$fake_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: tree changed since audit started" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test "not in a git repo: declines" {
  OUTSIDE=$(mktemp -d -t audit-stamp-outside-XXXXXX)
  cd "$OUTSIDE"
  AUDIT_TREE_SHA="" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: not in a git repo" ]
}

# -----------------------------------------------------------------------------
# Member-aware gate: the trailer certifies that EVERY dispatched Code Audit
# Team member cleared this tree, not just the caller. These tests run the
# real hook against a sandbox with the real resolver + libs installed, so
# every existing test above (no resolver present in $REPO) keeps exercising
# the fallback path unchanged.
# -----------------------------------------------------------------------------

@test "member-aware gate: declines while a co-dispatched member withholds" {
  install_resolver
  commit_mixed_diff

  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push --quiet --set-upstream origin feature

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  write_marker code-audit-frontend

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: members pending code-audit-maintainer-shell" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
}

@test "member-aware gate: stamps once every dispatched member has cleared" {
  install_resolver
  commit_mixed_diff

  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push --quiet --set-upstream origin feature

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)

  write_marker code-audit-frontend
  write_marker code-audit-maintainer-shell

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: empty commit (created locally)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  after_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  after_count=$(git -C "$REPO" rev-list --count HEAD)

  [ "$before_sha" != "$after_sha" ]
  [ "$before_tree" = "$after_tree" ]
  [ $((after_count - before_count)) -eq 1 ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test "member-aware gate: single-required-member diff stamps (no deadlock)" {
  install_resolver

  git -C "$REPO" checkout --quiet -b feature-node
  mkdir -p "$REPO/.gaia/cli/src"
  echo "export const y = 1;" > "$REPO/.gaia/cli/src/foo.ts"
  git -C "$REPO" add .gaia/cli/src/foo.ts
  git -C "$REPO" commit --quiet -m "node-only change"

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  write_marker code-audit-maintainer-node

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}

@test "member-aware gate: resolver absent falls back to caller's own judgment unchanged" {
  commit_mixed_diff

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  write_marker code-audit-frontend

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${before_tree}" ]
}
