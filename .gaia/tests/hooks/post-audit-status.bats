#!/usr/bin/env bats

# Tests for .claude/hooks/post-audit-status.sh.
#
# Handed an EARNED marker, the hook posts the GAIA-Audit success commit status
# on the PUSHED PR head (head_sha, resolved via `gh pr view --json headRefOid`,
# falling back to the upstream tracking tip and then local HEAD) once every
# dispatched Code Audit Team member has cleared. Handed a REFUSAL it posts
# state=failure and skips that member-aware gate entirely (case 9 below).
# Fail-safe asymmetry is its governing invariant on both arms: every
# precondition that fails DECLINES with a marker line on stdout and exit 0, so
# an absent status can never invert into a cleared gate.
#
# Covered here:
#   1. no marker-path argument              -> exit 2, usage on stderr
#   2. marker absent                        -> decline "marker absent"
#   3. present non-writer-produced marker   -> decline "marker not a valid clearance"
#   4. un-pushed tree-changing work         -> decline "audited tree not on pushed head"
#   5. un-pushed content-preserving stamp   -> decline "stamp not pushed", in both
#      of the stamp's shapes (empty commit on the pushed path, amend of a pushed
#      commit), neither of which the tree guard can see
#   6. local HEAD == pushed PR head         -> posts, targeting the pushed head
#   7. no PR and no upstream                -> head_sha falls back to local HEAD, so
#      the sha guard does not fire and the run reaches the POST
#   8. detached HEAD at the PR head sha (the CI checkout shape) -> posts
#   9. a writer-shaped REFUSAL               -> posts state=failure on the pushed
#      head, including when the same digest's earned marker sits beside it, with
#      a description that carries neither the cleared shape nor a version in
#      field 1; a refusal naming another member declines on the same
#      well-formedness key the success arm uses, and the pushed-head guards
#      apply to the failure state too
#
# Case 5 is the regression this suite exists to pin. The GAIA-Audit trailer
# stamp is content-preserving by design, so a stamp commit that exists only
# locally leaves local HEAD's tree byte-identical to the pushed head's tree and
# the tree guard is blind to it. Posting there lands the success status on the
# pre-stamp head; pushing the stamp afterwards advances the PR head and strands
# the status on a sha no reader checks, so a required GAIA-Audit check waits
# forever. The sha guard is the deterministic backstop under the audit members'
# push-then-post ordering.
#
# Harness: `gh` is stubbed on a prepended PATH (mirroring
# pr-merge-audit-check.bats). The stub answers `auth`, `pr view` (the head sha
# the test chooses, or a non-zero exit for "no PR"), and `repo view`, and
# records every `gh api` invocation to a file so a test can assert whether a
# POST happened and which sha it targeted. Every fixture digest comes from the
# real digest engine, never a hardcoded value.
#
# Ownership. Two suites guard this one hook, each run by its own shard leg of
# .github/workflows/audit-ci-tests.yml's matrix (this file lands in one of the
# hooks-1..hooks-4 shards; .github/audit/tests/ runs whole as the `audit`
# shard), both armed by that job's shared `code` path filter. This suite owns
# the usage and marker-shape preconditions, the
# divergence guards as enumerated decline lines, and the head_sha fallback
# paths. Its sibling .github/audit/tests/post-audit-status.bats owns the
# member-aware gate arms and the status-target arms; it installs the real
# resolver and its gh mock rejects a status posted to a sha its bare remote
# does not carry. Add a new arm to whichever suite already owns its family
# instead of duplicating it in both.
#
# Scope limit to read the two posting arms honestly. REPO stages only
# .gaia/VERSION and README.md, so .gaia/scripts/resolve-audit-members.sh is not
# executable inside the fixture and the hook's member-aware gate is SKIPPED in
# every test here (the hook's `[ -x "$resolver" ]` branch falls through to the
# single-marker POST). The posting arms therefore clear less of the precondition
# chain than a green line suggests: they prove the sha guard lets a matching head
# through, not that a full dispatched roster cleared. The member-aware gate is
# deliberately covered by the sibling suite instead, and no resolver stub belongs
# here.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/post-audit-status.sh
  DIGEST_LIB=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/audit-digest.sh
  REPO=$(mktemp -d -t post-audit-status-test-XXXXXX)
  REMOTE=$(mktemp -d -t post-audit-status-remote-XXXXXX)

  # Bare upstream so a test can simulate a "pushed" head.
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

  API_CALLS="$BATS_TEST_TMPDIR/api-calls"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${REMOTE:-}" ] && rm -rf "$REMOTE" || true
  return 0
}

# Helper: link the local repo to the bare upstream and push HEAD.
push_head_to_upstream() {
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push --quiet --set-upstream origin main
}

# Helper: the real audit_member_digest, sourced fresh in a subshell (mirroring
# audit-stamp-trailer.bats), so a fixture marker carries the SAME digest the
# hook itself derives rather than a hardcoded one.
digest_of() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIB" "$root" "$member" "$ref"
}

# Write a writer-shaped schema-3 EARNED clearance for MEMBER, keyed to MEMBER's
# OWN content digest at REPO's current HEAD, and print the marker path. Only
# such a marker passes the hook's clearance_acceptable precondition.
write_marker() {
  local member="${1:-code-audit-frontend}" digest tree sha path sidecar
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
  printf '%s\n' "$path"
}

# Write a writer-shaped schema-3 REFUSAL for MEMBER, keyed to MEMBER's OWN
# content digest at REPO's current HEAD, and print its path. The refusal twin of
# write_marker above; only such an artifact reaches the hook's failure arm.
write_refusal() {
  local member="${1:-code-audit-frontend}" digest tree sha path
  digest=$(digest_of "$REPO" "$member")
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  sha=$(git -C "$REPO" rev-parse HEAD)
  if [ "$member" = "code-audit-frontend" ]; then
    path="$REPO/.gaia/local/audit/${digest}.refused"
  else
    path="$REPO/.gaia/local/audit/${digest}.${member}.refused"
  fi
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"%s","provenance":"refused","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$member" "$digest" "$tree" "$sha" > "$path"
  printf '%s\n' "$path"
}

# Install a gh stub on a prepended PATH.
#   $1  the sha `gh pr view --json headRefOid` reports; empty means "no PR
#       resolvable" (the stub exits non-zero, as gh does off a PR branch).
#   $2  the exit status `gh api` returns (default 0, a successful POST).
# Every `gh api` invocation is appended to $API_CALLS, so a test can assert a
# POST happened on the expected sha, or that none happened at all.
install_gh_stub() {
  local pr_head="${1:-}" api_rc="${2:-0}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$pr_head" > "$BATS_TEST_TMPDIR/pr-head"
  printf '%s' "$api_rc" > "$BATS_TEST_TMPDIR/api-rc"
  : > "$API_CALLS"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
stub_dir="$BATS_TEST_TMPDIR"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth) exit 0 ;;
  pr)
    pr_head="$(cat "$stub_dir/pr-head")"
    [ -n "$pr_head" ] || exit 1
    printf '%s\n' "$pr_head"
    exit 0
    ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  api)
    printf '%s\n' "$*" >> "$stub_dir/api-calls"
    exit "$(cat "$stub_dir/api-rc")"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# Mirror the empty-commit stamp shape: HEAD advances, every blob stays
# byte-identical, so the audited tree is still the pushed head's tree.
stamp_empty_commit() {
  git -C "$REPO" commit --quiet --allow-empty -m "chore: code review audit passed"
}

# Mirror the amend stamp shape on an already-pushed commit: the trailer joins
# HEAD's message, HEAD's sha rotates, the tree is untouched.
stamp_amend() {
  local msg digest tree
  msg="$(git -C "$REPO" log -1 --format='%B')"
  digest="$(digest_of "$REPO" code-audit-frontend)"
  tree="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
  git -C "$REPO" commit --quiet --amend -m "${msg}
GAIA-Audit: 1.2.3 ${digest} ${tree}"
}

# Assert no POST reached the API (the fail-safe half of every decline arm).
assert_no_post() {
  [ -f "$API_CALLS" ] || return 0
  [ ! -s "$API_CALLS" ] || return 1
  return 0
}

# -----------------------------------------------------------------------------
# Usage + marker preconditions
# -----------------------------------------------------------------------------

@test "no marker-path argument: exits 2 with the usage line on stderr" {
  install_gh_stub "$(git -C "$REPO" rev-parse HEAD)"

  cd "$REPO"
  run bash -c "'$HOOK_ABS' 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  run bash -c "'$HOOK_ABS' 2>&1"
  [ "$status" -eq 2 ]
  grep -qF -- "usage: post-audit-status.sh <marker-path>" <<<"$output" || return 1
  assert_no_post
}

@test "marker absent: declines" {
  install_gh_stub "$(git -C "$REPO" rev-parse HEAD)"
  digest=$(digest_of "$REPO" code-audit-frontend)

  cd "$REPO"
  run "$HOOK_ABS" "$REPO/.gaia/local/audit/${digest}.ok"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker absent" ]
  assert_no_post
}

@test "marker present but not writer-produced: declines as not a valid clearance" {
  install_gh_stub "$(git -C "$REPO" rev-parse HEAD)"
  digest=$(digest_of "$REPO" code-audit-frontend)
  marker="$REPO/.gaia/local/audit/${digest}.ok"
  mkdir -p "$(dirname "$marker")"
  # A hand-written, non-JSON body at the right path: present, but nothing the
  # shared clearance writer would ever produce.
  printf 'audited, trust me\n' > "$marker"

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker not a valid clearance" ]
  assert_no_post
}

# -----------------------------------------------------------------------------
# Divergence guards
# -----------------------------------------------------------------------------

@test "un-pushed tree-changing work: declines audited tree not on pushed head" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  # Real content divergence: a tracked change committed locally and never
  # pushed, so the audited tree is not the tree the PR head carries.
  echo "export const x = 1;" > "$REPO/x.ts"
  git -C "$REPO" add x.ts
  git -C "$REPO" commit --quiet -m "local work"

  # The marker is written AFTER the divergent commit: the change rotates the
  # frontend digest, so a marker keyed to the earlier digest would decline one
  # guard earlier and this test would pass for the wrong reason.
  marker=$(write_marker code-audit-frontend)

  # The fixture's discriminating property: the trees genuinely differ here.
  [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" != "$(git -C "$REPO" rev-parse "${pushed_sha}^{tree}")" ]

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: audited tree not on pushed head" ]
  assert_no_post
}

@test "un-pushed empty-commit stamp: declines stamp not pushed (tree guard is blind to it)" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  marker=$(write_marker code-audit-frontend)
  stamp_empty_commit

  # The fixture's discriminating property: the tree guard passes (identical
  # trees) while the shas differ, which is exactly the arm under test.
  [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" = "$(git -C "$REPO" rev-parse "${pushed_sha}^{tree}")" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" != "$pushed_sha" ]

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: stamp not pushed" ]
  assert_no_post
}

@test "un-pushed amend stamp on a pushed commit: declines stamp not pushed" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  marker=$(write_marker code-audit-frontend)
  stamp_amend

  [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" = "$(git -C "$REPO" rev-parse "${pushed_sha}^{tree}")" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" != "$pushed_sha" ]

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: stamp not pushed" ]
  assert_no_post
}

# -----------------------------------------------------------------------------
# Posting arms: the sha guard must not fire where local HEAD IS the target
# -----------------------------------------------------------------------------

@test "local HEAD is the pushed PR head: posts the success status on that sha" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  marker=$(write_marker code-audit-frontend)
  digest=$(digest_of "$REPO" code-audit-frontend)
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")
  short=$(git -C "$REPO" rev-parse --short "$pushed_sha")

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit success ${short}" ]

  # The POST targets the pushed head, and carries the three-field description.
  grep -qF -- "repos/gaia-react/gaia/statuses/${pushed_sha}" "$API_CALLS" || return 1
  grep -qF -- "state=success" "$API_CALLS" || return 1
  grep -qF -- "context=GAIA-Audit" "$API_CALLS" || return 1
  grep -qF -- "description=1.2.3 ${digest} ${tree}" "$API_CALLS" || return 1
}

@test "no PR and no upstream: head_sha falls back to local HEAD, so the sha guard does not fire" {
  # No remote at all and no PR resolvable, so both fallbacks land on local
  # HEAD. head_sha then equals local HEAD by construction and the sha guard
  # must stay silent; the run reaches the POST, which fails on its own here
  # (api_rc 1) and declines "post failed", unchanged by the sha guard.
  install_gh_stub "" 1
  marker=$(write_marker code-audit-frontend)

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: post failed" ]
  # Reaching the POST at all is the proof the sha guard did not fire.
  grep -qF -- "repos/gaia-react/gaia/statuses/$(git -C "$REPO" rev-parse HEAD)" "$API_CALLS" || return 1
}

@test "detached HEAD at the PR head sha (CI checkout shape): posts" {
  # CI checks the PR head sha out directly, landing on a detached HEAD whose
  # sha IS headRefOid. The sha guard must not fire there.
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  marker=$(write_marker code-audit-frontend)
  git -C "$REPO" checkout --quiet --detach HEAD
  short=$(git -C "$REPO" rev-parse --short "$pushed_sha")

  cd "$REPO"
  run "$HOOK_ABS" "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit success ${short}" ]
  grep -qF -- "repos/gaia-react/gaia/statuses/${pushed_sha}" "$API_CALLS" || return 1
}

# -----------------------------------------------------------------------------
# Refusal arm: the compensating failure status
# -----------------------------------------------------------------------------
# Refusal precedence has a server-side signal only if the refusal itself posts
# one. GitHub's auto-merge fires on the required GAIA-Audit status and never
# runs the merge hook that honors a refusal, so a refusal landing behind an
# already-green status merges over it unless a failure post retracts that green.
# These arms pin the post, its state, and the description shape that keeps it
# unreadable as cleared.

@test "refusal for the current digest: posts the failure status on the pushed head" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  refusal=$(write_refusal code-audit-frontend)
  short=$(git -C "$REPO" rev-parse --short "$pushed_sha")

  cd "$REPO"
  run "$HOOK_ABS" "$refusal"

  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit failure ${short}" ]

  grep -qF -- "repos/gaia-react/gaia/statuses/${pushed_sha}" "$API_CALLS" || return 1
  grep -qF -- "state=failure" "$API_CALLS" || return 1
  grep -qF -- "context=GAIA-Audit" "$API_CALLS" || return 1
}

@test "refusal posts with no .gaia/VERSION: the arm reads neither the version nor the frontend digest" {
  # The success description's inputs are not the refusal description's, so
  # declining a retraction over a field it never reads would withhold it while
  # the stale success it exists to retract stands.
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  refusal=$(write_refusal code-audit-frontend)
  rm -f "$REPO/.gaia/VERSION"
  short=$(git -C "$REPO" rev-parse --short "$pushed_sha")

  cd "$REPO"
  run "$HOOK_ABS" "$refusal"

  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit failure ${short}" ]
  grep -qF -- "state=failure" "$API_CALLS" || return 1
}

@test "refusal description carries neither the cleared shape nor a version in field 1" {
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  refusal=$(write_refusal code-audit-frontend)
  digest=$(digest_of "$REPO" code-audit-frontend)
  tree=$(git -C "$REPO" rev-parse "HEAD^{tree}")

  cd "$REPO"
  run "$HOOK_ABS" "$refusal"

  [ "$status" -eq 0 ]
  # Names the refusing member and the exact content, so an operator can find
  # the artifact on disk.
  grep -qF -- "description=refused by code-audit-frontend ${digest}" "$API_CALLS" || return 1
  # And can never be read as cleared by a state-blind reader.
  grep -qF -- "description=1.2.3 ${digest} ${tree}" "$API_CALLS" && return 1
  true
}

@test "refusal posts even when the earned marker for the same digest is present" {
  # The incident shape: an earlier wave cleared and posted success, a later wave
  # of the same member refused the same content. The writer publishes the
  # refusal BESIDE the earned marker rather than replacing it, so both are on
  # disk and the refusal must still post its retraction.
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  write_marker code-audit-frontend >/dev/null
  refusal=$(write_refusal code-audit-frontend)
  short=$(git -C "$REPO" rev-parse --short "$pushed_sha")
  # No resolver is executable in this fixture, so the member-aware gate is
  # skipped here by construction (see the scope limit in this file's header);
  # the refused-member-inside-the-gate arm lives in the sibling suite that
  # installs the real resolver.

  cd "$REPO"
  run "$HOOK_ABS" "$refusal"

  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit failure ${short}" ]
  grep -qF -- "state=failure" "$API_CALLS" || return 1
}

@test "refusal whose body names another member: declines as not a valid clearance" {
  # The failure arm reuses the same well-formedness key the success arm does,
  # so a refusal that is not this member's own for this digest posts nothing.
  push_head_to_upstream
  install_gh_stub "$(git -C "$REPO" rev-parse HEAD)"

  digest=$(digest_of "$REPO" code-audit-frontend)
  path="$REPO/.gaia/local/audit/${digest}.refused"
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"code-audit-maintainer-shell","provenance":"refused","digest":"%s","tree":"t","sha":"s"}\n' \
    "$digest" > "$path"

  cd "$REPO"
  run "$HOOK_ABS" "$path"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker not a valid clearance" ]
  assert_no_post || return 1
}

@test "refusal on un-pushed tree-changing work: declines rather than posting" {
  # The pushed-head guards apply to both states. Declining here is the
  # fail-safe direction: the local gate still denies the merge, and a head the
  # audit never covered carries no success to retract.
  push_head_to_upstream
  pushed_sha=$(git -C "$REPO" rev-parse HEAD)
  install_gh_stub "$pushed_sha"

  echo "unpushed change" >> "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "unpushed"
  refusal=$(write_refusal code-audit-frontend)

  cd "$REPO"
  run "$HOOK_ABS" "$refusal"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: audited tree not on pushed head" ]
  assert_no_post || return 1
}
