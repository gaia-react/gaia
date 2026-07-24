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
#   11. UAT-008: stamped trailer's field 2 is the frontend content digest
#       (64-hex) and field 3 is the real HEAD tree (40-hex), distinctly
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
#     (parsed via `git interpret-trailers --parse`), three positional fields
#     "<version> <frontend-digest> <tree>" (UAT-008: digest at field 2, tree
#     at field 3, distinctly)
#   - HEAD sha movement (amend or empty commit moves it; decline does not)
#   - bare upstream is NOT advanced for empty-commit cases (helper never pushes)

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/audit-stamp-trailer.sh
  DIGEST_LIB=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/audit-digest.sh
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
  [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN" || true
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

# Helper: the real audit_member_digest, sourced fresh in a subshell (mirrors
# .gaia/tests/hooks/audit-digest-lib.bats's digest_of), so assertions compute
# the SAME digest the hook itself derives rather than hardcoding one.
digest_of() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIB" "$root" "$member" "$ref"
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

# Write a writer-shaped schema-3 EARNED clearance for MEMBER, keyed to MEMBER's
# OWN content digest (owned files + machinery, computed via digest_of, NOT the
# tree). code-audit-frontend is infix-free (<digest>.ok); a specialized member
# carries a ".<member>" infix (<digest>.<member>.ok). `tree` stays in the body
# as a plain data field (janitor liveness only), never the validity key.
write_marker() {
  local member="$1" digest tree sha path sidecar
  digest=$(digest_of "$REPO" "$member")
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  sha=$(git -C "$REPO" rev-parse HEAD)
  if [ "$member" = "code-audit-frontend" ]; then
    path="$REPO/.gaia/local/audit/${digest}.ok"
    sidecar="true"
  else
    path="$REPO/.gaia/local/audit/${digest}.${member}.ok"
    sidecar="false"
  fi
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" > "$path"
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
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "clean tree + pushed HEAD: writes empty commit locally (no auto-push)" {
  push_head_to_upstream

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)
  before_remote_sha=$(git -C "$REMOTE" rev-parse main)
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

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
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]

  # Helper never pushes; upstream must NOT have advanced. The caller
  # pushes after writing the audit marker.
  after_remote_sha=$(git -C "$REMOTE" rev-parse main)
  [ "$before_remote_sha" = "$after_remote_sha" ]
}

@test "AUDIT_SELF_HEALED=true on un-pushed HEAD: amends" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="true" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto audit-self-heal HEAD" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "detached HEAD: writes empty commit (treats as pushed; helper never pushes)" {
  # Simulate the CI checkout: actions/checkout with `ref: <sha>` lands
  # on a detached HEAD. Without an upstream probe, the script must NOT
  # fall through to the un-pushed amend path; that would rewrite a
  # commit the runner does not own.
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

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
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "AUDIT_SELF_HEALED=true on pushed HEAD: still amends (audit owns the commit)" {
  push_head_to_upstream

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  before_count=$(git -C "$REPO" rev-list --count HEAD)
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

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
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "UAT-008: trailer records the frontend digest at field 2 and the tree at field 3, distinctly" {
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  # A digest-keyed fixture where the two fields genuinely differ: a 64-hex
  # sha256 content digest vs. a 40-hex sha1 tree, so a reader keying on the
  # wrong field is caught rather than accidentally matching.
  [ "$expected_digest" != "$before_tree" ]
  [ "${#expected_digest}" -eq 64 ]
  [ "${#before_tree}" -eq 40 ]

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]

  # Positional proof: field 2 (after the version) is the digest, field 3 is
  # the tree. "GAIA-Audit:" is $1, version is $2 in an awk split.
  field2=$(awk '{print $3}' <<<"$trailer")
  field3=$(awk '{print $4}' <<<"$trailer")
  [ "$field2" = "$expected_digest" ]
  [ "$field3" = "$before_tree" ]
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
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

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
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
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

# --- --root: the audited tree is the one the caller names, not the ambient cwd
#
# This is the linked-worktree dispatch shape. There the cwd is the MAIN
# checkout while the reviewed tree is somewhere else entirely, so a root taken
# from cwd stamps a tree nobody audited. The test above is the paired half: the
# same cwd, no --root, declines rather than guessing.

@test "--root: stamps the named repo from a cwd outside it" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  OUTSIDE=$(mktemp -d -t audit-stamp-outside-XXXXXX)
  cd "$OUTSIDE"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS" --root "$REPO"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "--root=<path>: the equals form resolves the same repo" {
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  OUTSIDE=$(mktemp -d -t audit-stamp-outside-XXXXXX)
  cd "$OUTSIDE"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS" "--root=$REPO"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]
}

@test "--root naming a path that is not a directory: declines" {
  cd "$REPO"
  AUDIT_TREE_SHA="" AUDIT_SELF_HEALED="false" run "$HOOK_ABS" --root "$REPO/README.md"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: root not a directory" ]
}

@test "--root with no value: declines rather than consuming the next thing" {
  cd "$REPO"
  AUDIT_TREE_SHA="" AUDIT_SELF_HEALED="false" run "$HOOK_ABS" --root

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: --root requires a path" ]
}

@test "an unrecognized argument: declines and does not move HEAD" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)

  cd "$REPO"
  AUDIT_TREE_SHA="" AUDIT_SELF_HEALED="false" run "$HOOK_ABS" --bogus

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: unknown argument: --bogus" ]
  [ "$before_sha" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "frontend digest unavailable (sha256 tool masked): declines fail-closed and does not move HEAD" {
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  # Shadow sha256sum with a stub that always fails, on a prepended PATH: the
  # digest engine's own fail-closed posture (never a partial/empty digest,
  # per audit-digest-lib.bats UAT-013) must surface here as a clean decline,
  # never a stamped trailer with a missing or empty digest field.
  FAKEBIN=$(mktemp -d -t audit-stamp-fakebin-XXXXXX)
  cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$FAKEBIN/sha256sum"

  cd "$REPO"
  PATH="$FAKEBIN:$PATH" AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: declined: frontend digest unavailable" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
  [ -z "$(trailer_on_head)" ]
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
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

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
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
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
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  write_marker code-audit-maintainer-node

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

@test "member-aware gate: resolver absent falls back to caller's own judgment unchanged" {
  commit_mixed_diff

  before_sha=$(git -C "$REPO" rev-parse HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  expected_digest=$(digest_of "$REPO" code-audit-frontend)

  write_marker code-audit-frontend

  cd "$REPO"
  AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" run "$HOOK_ABS"

  [ "$status" -eq 0 ]
  [ "$output" = "stamp: amended onto HEAD (un-pushed)" ]

  after_sha=$(git -C "$REPO" rev-parse HEAD)
  [ "$before_sha" != "$after_sha" ]

  trailer=$(trailer_on_head)
  [ "$trailer" = "GAIA-Audit: 1.2.3 ${expected_digest} ${before_tree}" ]
}

# -----------------------------------------------------------------------------
# Concurrency: the guard-through-commit critical section is mutex-serialized
# -----------------------------------------------------------------------------

@test "concurrency: two racing stampers stamp exactly once, no double-commit, no index.lock" {
  before_count=$(git -C "$REPO" rev-list --count HEAD)
  before_tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  # Detached HEAD (as in the "detached HEAD" stamp-path test above) puts both
  # racers on the empty-commit path with no resolver installed in $REPO, so
  # the member-aware gate is skipped and both racers reach the commit region
  # near-simultaneously, the scenario the stamp lock exists to serialize.
  git -C "$REPO" checkout --quiet --detach HEAD

  # Redirect each racer's output into $REMOTE (a scratch bare-repo dir, torn
  # down by teardown()) rather than into $REPO, writing an output file inside
  # $REPO would itself dirty the tree the hook is about to check.
  ( cd "$REPO"; AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" "$HOOK_ABS" >"$REMOTE/o1" 2>&1 ) & p1=$!
  ( cd "$REPO"; AUDIT_TREE_SHA="$before_tree" AUDIT_SELF_HEALED="false" "$HOOK_ABS" >"$REMOTE/o2" 2>&1 ) & p2=$!
  wait "$p1"; s1=$?
  wait "$p2"; s2=$?

  [ "$s1" -eq 0 ]
  [ "$s2" -eq 0 ]

  after_count=$(git -C "$REPO" rev-list --count HEAD)
  [ $((after_count - before_count)) -eq 1 ]

  trailer_count=$(git -C "$REPO" log -1 --format='%B' \
    | git -C "$REPO" interpret-trailers --parse \
    | grep -c '^GAIA-Audit:' || true)
  [ "$trailer_count" -eq 1 ]

  combined="$(cat "$REMOTE/o1" "$REMOTE/o2")"
  grep -qF -- "stamp: empty commit (created locally)" <<<"$combined" || return 1
  grep -qF -- "stamp: declined: already stamped" <<<"$combined" || return 1

  grep -qiF -- "index.lock" <<<"$combined" && return 1
  return 0
}
