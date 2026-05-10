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
#   6. .gaia/VERSION missing                -> decline "version file missing"
#   7. .gaia/VERSION empty                  -> decline "version file empty"
#   8. AUDIT_TREE_SHA != current tree       -> decline "tree changed since audit started"
#   9. not in a git repo                    -> decline "not in a git repo"
#
# The helper never pushes — the agent caller pushes after writing the
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

  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add .gaia/VERSION README.md
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

  # Helper never pushes — upstream must NOT have advanced. The caller
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
  # fall through to the un-pushed amend path — that would rewrite a
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
