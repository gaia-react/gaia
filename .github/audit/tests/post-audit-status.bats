#!/usr/bin/env bats

# Tests for .claude/hooks/post-audit-status.sh, the local audit producer's
# GAIA-Audit success status POST. It runs on the Claude-driven merge path after
# the audit marker is written; the marker file is its literal precondition.
#
# The fixture sits here in .github/audit/tests/ so it runs in the same
# audit-ci-tests.yml suite as the other GAIA-Audit readers/producers.
#
# `gh` is mocked on a prepended PATH. The mock answers `gh auth status` (ok or
# fail per the test), `gh repo view --json nameWithOwner` (a fixed slug),
# `gh pr view --json headRefOid` (the pushed head sha captured by push_branch),
# and `gh api .../statuses ... --method POST` (records the invocation only when
# the target sha exists on a bare remote, proving it is genuinely fetchable,
# not just that the mock accepted it unconditionally).
#
# SANDBOX pushes to a bare remote (origin) so `gh pr view`'s resolution has a
# real pushed head to target, and so the mock can reject a status posted to a
# sha the remote doesn't carry -- the same 422 an unpushed target sha gets from
# the real GitHub API.
#
# Coverage:
#   1. Marker present  → posts state=success context=GAIA-Audit
#      "<version> <frontend-digest> <tree>" (three positional fields; field 2
#      is the digest, UAT-008 field-position proof)
#      Marker absent   → no POST (declines)
#   2. gh unauthenticated → marker untouched, no POST (fail-safe asymmetry)
#   3. Member-aware gate (blocker COV-001): a mixed app/ + .gaia/**/*.sh diff
#      declines ("members pending ...") while the maintainer-shell member's
#      marker is absent, posts success once both markers are present (each
#      member keyed to its OWN content digest, not the tree), and (resolver
#      absent) falls back to the single-marker POST unchanged. There is no
#      carried provenance, so the description never carries a trailing
#      "carried" suffix.
#   4. Status target: posts to the pushed PR head sha, not local HEAD, so an
#      unpushed empty-commit trailer stamp never orphans the status POST
#      (#726); declines "audited tree not on pushed head" when local HEAD's
#      tree genuinely isn't on the pushed head. The surfaced "status: posted"
#      line carries the short form of the POSTed sha, not local HEAD's short
#      sha, on this same divergence (#794).
#   5. Frontend digest unavailable (masked sha256 tool) → declines fail-closed,
#      never posts a status with a missing or empty digest field.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../../../.claude/hooks/post-audit-status.sh"
  [ -x "$SCRIPT" ] || skip "post-audit-status.sh not executable"
  DIGEST_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-digest.sh"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  # A bare remote makes the pushed head sha fetchable, so the gh mock's `api`
  # case can prove a POST targets a sha the remote actually carries instead of
  # accepting anything unconditionally (the gap that let #726 hide).
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  PUSHED_HEAD_FILE="$BATS_TEST_TMPDIR/pushed-head"
  git init --quiet --bare "$REMOTE"
  git -C "$SANDBOX" remote add origin "$REMOTE"
  push_branch

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
}

# Push SANDBOX's current branch to origin and record the pushed head sha (both
# in $PUSHED_HEAD and in $PUSHED_HEAD_FILE, which the gh mock's `pr` case reads
# at run time) -- the sha the retargeted POST must land on.
push_branch() {
  local branch
  branch="$(git -C "$SANDBOX" rev-parse --abbrev-ref HEAD)"
  git -C "$SANDBOX" push --quiet --set-upstream origin "$branch"
  PUSHED_HEAD="$(git -C "$SANDBOX" rev-parse HEAD)"
  printf '%s' "$PUSHED_HEAD" > "$PUSHED_HEAD_FILE"
}

# Install a fake `gh` on a prepended PATH.
#   auth   → exit 0 (ok) or 1 (fail) per $1
#   repo   → print the fixed slug for `gh repo view --json nameWithOwner --jq`
#   pr     → print the pushed head sha (from PUSHED_HEAD_FILE, written by
#            push_branch) for `gh pr view --json headRefOid --jq .headRefOid`
#   api    → verify the `statuses/<sha>` target exists on the bare REMOTE
#            before accepting: append the full argv to POST_LOG and exit 0
#            only when the sha is a fetchable commit there, else exit 1 and
#            record nothing (the same 422 a real unpushed target sha gets),
#            so a regression to the local unpushed sha fails the test.
install_gh_mock() {
  local auth_ok="$1"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
auth_ok="$auth_ok"
record="$POST_LOG"
remote="$REMOTE"
pushed_head_file="$PUSHED_HEAD_FILE"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth)
    [ "$auth_ok" = "ok" ] && exit 0 || exit 1
    ;;
  repo)
    printf 'gaia-react/gaia\n'
    ;;
  pr)
    [ -f "$pushed_head_file" ] && cat "$pushed_head_file" || exit 1
    ;;
  api)
    sha="${2##*statuses/}"
    sha="${sha%% *}"
    if [ -n "$sha" ] && git -C "$remote" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      printf '%s\n' "$*" >> "$record"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

run_helper() {
  ( cd "$SANDBOX" && "$SCRIPT" "$1" )
}

current_tree() {
  git -C "$SANDBOX" rev-parse "HEAD^{tree}"
}

# The real audit_member_digest, sourced fresh in a subshell (mirrors
# .gaia/tests/hooks/audit-digest-lib.bats's digest_of), so assertions compute
# the SAME digest the script itself derives rather than hardcoding one.
digest_of() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIB" "$root" "$member" "$ref"
}

# Write a writer-shaped schema-3 EARNED clearance for MEMBER at PATH (an
# absolute path under SANDBOX), keyed to MEMBER's OWN content digest (owned
# files + machinery), NOT the tree. The precondition now accepts only such
# bodies, not a bare `{}`: `digest` equals the filename key and `member`
# matches. `tree` stays in the body as a plain data field.
write_body() {
  local path="$1" member="$2" digest tree sha sidecar
  digest=$(digest_of "$SANDBOX" "$member")
  tree=$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")
  sha=$(git -C "$SANDBOX" rev-parse HEAD)
  if [ "$member" = "code-audit-frontend" ]; then sidecar="true"; else sidecar="false"; fi
  mkdir -p "$(dirname "$path")"
  printf '{"version":"1.2.3","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" > "$path"
}

# Copy the real resolver script into SANDBOX so a test can exercise the
# member-aware gate. Untracked, so it never appears in a git diff itself.
install_resolver() {
  local resolver_abs lib_dir
  resolver_abs="$THIS_DIR/../../../.gaia/scripts/resolve-audit-members.sh"
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$resolver_abs" "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"

  # The resolver copy resolves its libs relative to ITSELF
  # ($SANDBOX/.claude/hooks/lib/), so provision the shared ownership
  # classifier alongside it.
  lib_dir="$THIS_DIR/../../../.claude/hooks/lib"
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  cp "$lib_dir/audit-scope.sh" "$SANDBOX/.claude/hooks/lib/audit-scope.sh"
  cp "$lib_dir/audit-machinery.sh" "$SANDBOX/.claude/hooks/lib/audit-machinery.sh"
  cp "$lib_dir/audit-clearance.sh" "$SANDBOX/.claude/hooks/lib/audit-clearance.sh"
}

# Commit a mixed app/ + .gaia/**/*.sh change on a new `feature` branch off
# SANDBOX's init commit, so the resolver's merge-base(HEAD, main) diff is
# non-empty and dispatches both code-audit-frontend (app/) and
# code-audit-maintainer-shell (.gaia/**/*.sh) against the built-in roster.
commit_mixed_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app" "$SANDBOX/.gaia/scripts"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "#!/bin/bash" > "$SANDBOX/.gaia/scripts/example.sh"
  git -C "$SANDBOX" add app/x.ts .gaia/scripts/example.sh
  git -C "$SANDBOX" commit --quiet -m "mixed change"
  # Push before any later local-only stamp commit, so the pushed head sha this
  # captures is the one post-audit-status.sh must target (not local HEAD).
  push_branch
}

# -----------------------------------------------------------------------------
# 1. Marker-gated POST: posts on marker present, skips on marker absent
# -----------------------------------------------------------------------------

@test "local producer: posts GAIA-Audit success only after marker exists" {
  install_gh_mock ok
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The marker is keyed to the member's own content digest; the status POST
  # still targets the COMMIT (a GitHub commit status has nowhere else to land).
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  # The recorded POST carries state=success, the GAIA-Audit context, and the
  # three-field "<version> <frontend-digest> <tree>" description every
  # state-aware reader accepts as cleared.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${head_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "context=GAIA-Audit" "$POST_LOG"
  grep -q "description=1.2.3 ${digest} ${tree}" "$POST_LOG"

  # Marker absent → no POST, declines.
  rm -f "$POST_LOG"
  run run_helper ".gaia/local/audit/does-not-exist.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: marker absent" ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# 2. gh unauthenticated → marker stays, no POST (fail-safe asymmetry)
# -----------------------------------------------------------------------------

@test "local producer: gh unauthenticated → marker stays, no status post (fail-safe asymmetry)" {
  install_gh_mock fail
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: gh unauthenticated" ]

  # The marker the caller wrote is untouched; only the POST is skipped.
  [ -f "$SANDBOX/$marker" ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# 3. Member-aware POST gate (Interface contract 2, blocker COV-001): a mixed
#    diff requires every dispatched member's marker, not just the caller's own.
# -----------------------------------------------------------------------------

@test "member-aware POST: declines while a co-dispatched maintainer-shell member withholds" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: members pending code-audit-maintainer-shell" ]

  # The button stays blocked: a decline never posts, and the caller's own
  # marker (already validated present) is untouched.
  [ ! -f "$POST_LOG" ]
  [ -f "$SANDBOX/$marker" ]
}

@test "member-aware POST: posts success once every dispatched member has cleared" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  [ -f "$POST_LOG" ]
  grep -q "statuses/${head_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG"
}

# The order-independence the helper's header promises, and that a commit key
# cannot actually deliver. A specialized member clears the content and writes
# its marker; code-audit-frontend then stamps the GAIA-Audit trailer as an
# empty commit and writes its own. Keyed to HEAD, the frontend's stamp orphans
# the sibling's marker and the POST declines "members pending" even though
# both members audited identical content. Keyed to the content digest (blobs
# unchanged by an empty commit), the POST goes through.
@test "member-aware POST: a sibling's marker survives the trailer stamp's empty commit" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The specialized member clears the content first, before the frontend stamps.
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell

  # Push before the stamp: pushed_head is the fetchable sha the retargeted POST
  # must land on.
  push_branch
  pushed_head="$PUSHED_HEAD"

  # code-audit-frontend stamps the trailer: an empty commit, identical blobs,
  # left UNPUSHED -- the sha the pre-fix code targeted, which 422s (#726).
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  stamped_sha=$(git -C "$SANDBOX" rev-parse HEAD)

  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1

  # The status lands on the pushed (pre-stamp) head, not the unpushed stamp,
  # carrying the unchanged content.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${pushed_head}" "$POST_LOG"
  grep -qF -- "statuses/${stamped_sha}" "$POST_LOG" && return 1
  grep -q "state=success" "$POST_LOG"
  grep -q "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG"
}

@test "member-aware POST: resolver absent falls back to the single-marker POST on a mixed diff" {
  install_gh_mock ok
  commit_mixed_diff

  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  # No resolver copied into SANDBOX: the member-aware gate is skipped and the
  # frontend marker alone clears the POST, same as today.
  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]
}

# -----------------------------------------------------------------------------
# 4. Status target (#726): posts to the pushed PR head sha, not local HEAD, and
#    declines when the audited tree genuinely isn't on the pushed head.
# -----------------------------------------------------------------------------

@test "local producer: declines when the audited tree is not on the pushed head (unpushed tree-changing work)" {
  install_gh_mock ok

  # Unpushed tree-changing work (e.g. an unpushed self-heal): local HEAD's tree
  # now differs from the pushed head's tree (still the init commit's).
  echo "changed" >> "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "unpushed tree change"

  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: audited tree not on pushed head" ]
  [ ! -f "$POST_LOG" ]
}

@test "#726: status posts to the pushed head sha, not the unpushed empty-commit stamp" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend
  pushed_head="$PUSHED_HEAD"

  # The empty-commit trailer stamp: a local, un-pushed commit. Under the
  # pre-fix code (target local HEAD) the mock rejects this sha as absent from
  # the remote and no POST is recorded, reproducing #726.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  unpushed_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  [ "$unpushed_sha" != "$pushed_head" ]

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  grep -qF -- "status: posted GAIA-Audit success " <<<"$output" || return 1

  [ -f "$POST_LOG" ]
  grep -q "statuses/${pushed_head}" "$POST_LOG"
  grep -qF -- "statuses/${unpushed_sha}" "$POST_LOG" && return 1
  return 0
}

@test "#794: the posted-status line surfaces the short POSTed sha, not local HEAD's short sha" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend
  pushed_head="$PUSHED_HEAD"
  pushed_head_short=$(git -C "$SANDBOX" rev-parse --short "$pushed_head")

  # The empty-commit trailer stamp: a local, un-pushed commit ahead of the
  # pushed head, tree unchanged so the audited-tree gate still passes. Local
  # HEAD's short sha now diverges from the pushed head's short sha.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  local_head_short=$(git -C "$SANDBOX" rev-parse --short HEAD)
  [ "$local_head_short" != "$pushed_head_short" ]

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: posted GAIA-Audit success ${pushed_head_short}" ]
}

# -----------------------------------------------------------------------------
# Description shape: three-field "<version> <frontend-digest> <tree>", never a
# trailing "carried" suffix. There is no carried provenance under digest
# keying (every dispatched member's clearance is earned), so the shape is
# fixed with no branch.
# -----------------------------------------------------------------------------

@test "an all-earned mixed diff posts the three-field description with no carried suffix" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  frontend_digest=$(digest_of "$SANDBOX" code-audit-frontend)
  shell_digest=$(digest_of "$SANDBOX" code-audit-maintainer-shell)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${frontend_digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend
  write_body "$SANDBOX/.gaia/local/audit/${shell_digest}.code-audit-maintainer-shell.ok" code-audit-maintainer-shell

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ -f "$POST_LOG" ]
  grep -q "description=1.2.3 ${frontend_digest} ${tree}" "$POST_LOG"
  # No carried token appended, and never can be (there is no carried family).
  grep -qF -- "carried" "$POST_LOG" && return 1
  return 0
}

# -----------------------------------------------------------------------------
# Frontend digest unavailable (masked sha256 tool): declines fail-closed,
# never posts a status with a missing or empty digest field.
# -----------------------------------------------------------------------------

@test "frontend digest unavailable (sha256 tool masked): declines fail-closed, no POST" {
  install_gh_mock ok
  digest=$(digest_of "$SANDBOX" code-audit-frontend)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${digest}.ok"
  write_body "$SANDBOX/$marker" code-audit-frontend

  # Shadow sha256sum with a stub that always fails, on a prepended PATH: the
  # digest engine's own fail-closed posture (never a partial/empty digest, per
  # audit-digest-lib.bats UAT-013) must surface here as a clean decline, never
  # a posted status with a missing or empty digest field.
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$FAKEBIN/sha256sum"

  PATH="$FAKEBIN:$PATH" run run_helper "$marker"

  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: frontend digest unavailable" ]
  [ ! -f "$POST_LOG" ]
}
