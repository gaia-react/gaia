#!/usr/bin/env bats

# Tests for .claude/hooks/post-audit-status.sh, the local audit producer's
# GAIA-Audit success status POST. It runs on the Claude-driven merge path after
# the audit marker is written; the marker file is its literal precondition.
#
# The fixture sits here in .github/audit/tests/ so it runs in the same
# audit-ci-tests.yml suite as the other GAIA-Audit readers/producers.
#
# `gh` is mocked on a prepended PATH. The mock answers `gh auth status` (ok or
# fail per the test), `gh repo view --json nameWithOwner` (a fixed slug), and
# `gh api .../statuses ... --method POST` (records the invocation so the test
# asserts the posted state/context/description).
#
# Coverage:
#   1. Marker present  → posts state=success context=GAIA-Audit "<version> <tree>"
#      Marker absent   → no POST (declines)
#   2. gh unauthenticated → marker untouched, no POST (fail-safe asymmetry)
#   3. Member-aware gate (blocker COV-001): a mixed app/ + .gaia/**/*.sh diff
#      declines ("members pending ...") while the maintainer-shell member's
#      marker is absent, posts success once both markers are present, and
#      (resolver absent) falls back to the single-marker POST unchanged.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../../../.claude/hooks/post-audit-status.sh"
  [ -x "$SCRIPT" ] || skip "post-audit-status.sh not executable"

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

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
}

# Install a fake `gh` on a prepended PATH.
#   auth   → exit 0 (ok) or 1 (fail) per $1
#   repo   → print the fixed slug for `gh repo view --json nameWithOwner --jq`
#   api    → append the full argv to POST_LOG and exit 0 (success)
install_gh_mock() {
  local auth_ok="$1"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
auth_ok="$auth_ok"
record="$POST_LOG"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  auth)
    [ "$auth_ok" = "ok" ] && exit 0 || exit 1
    ;;
  repo)
    printf 'gaia-react/gaia\n'
    ;;
  api)
    printf '%s\n' "$*" >> "$record"
    exit 0
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

# Copy the real resolver script into SANDBOX so a test can exercise the
# member-aware gate. Untracked, so it never appears in a git diff itself.
install_resolver() {
  local resolver_abs
  resolver_abs="$THIS_DIR/../../../.gaia/scripts/resolve-audit-members.sh"
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$resolver_abs" "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
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
}

# -----------------------------------------------------------------------------
# 1. Marker-gated POST: posts on marker present, skips on marker absent
# -----------------------------------------------------------------------------

@test "local producer: posts GAIA-Audit success only after marker exists" {
  install_gh_mock ok
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The marker is keyed to the TREE; the status POST still targets the COMMIT
  # (a GitHub commit status has nowhere else to land).
  marker=".gaia/local/audit/${tree}.ok"
  printf '{"sha":"%s","tree":"%s"}\n' "$head_sha" "$tree" > "$SANDBOX/$marker"

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  # The recorded POST carries state=success, the GAIA-Audit context, and the
  # "<version> <tree>" description every state-aware reader accepts as cleared.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${head_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "context=GAIA-Audit" "$POST_LOG"
  grep -q "description=1.2.3 ${tree}" "$POST_LOG"

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
  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${tree}.ok"
  printf '{"sha":"%s","tree":"%s"}\n' "$head_sha" "$tree" > "$SANDBOX/$marker"

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

  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${tree}.ok"
  printf '{}' > "$SANDBOX/$marker"

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
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${tree}.ok"
  printf '{}' > "$SANDBOX/$marker"
  printf '{}' > "$SANDBOX/.gaia/local/audit/${tree}.code-audit-maintainer-shell.ok"

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  [ -f "$POST_LOG" ]
  grep -q "statuses/${head_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "description=1.2.3 ${tree}" "$POST_LOG"
}

# The order-independence the helper's header promises, and that a commit key
# cannot actually deliver. A specialized member clears the tree and writes its
# marker; code-audit-frontend then stamps the GAIA-Audit trailer as an empty
# commit and writes its own. Keyed to HEAD, the frontend's stamp orphans the
# sibling's marker and the POST declines "members pending" even though both
# members audited the identical tree. Keyed to the tree, the POST goes through.
@test "member-aware POST: a sibling's marker survives the trailer stamp's empty commit" {
  install_gh_mock ok
  install_resolver
  commit_mixed_diff

  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  # The specialized member clears the tree first, before the frontend stamps.
  printf '{}' > "$SANDBOX/.gaia/local/audit/${tree}.code-audit-maintainer-shell.ok"

  # code-audit-frontend stamps the trailer: an empty commit, identical tree.
  git -C "$SANDBOX" commit -q --allow-empty -m "chore: code review audit passed"
  [ "$(current_tree)" = "$tree" ]
  stamped_sha=$(git -C "$SANDBOX" rev-parse HEAD)

  marker=".gaia/local/audit/${tree}.ok"
  printf '{}' > "$SANDBOX/$marker"

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]

  # The status lands on the post-stamp commit, carrying the unchanged tree.
  [ -f "$POST_LOG" ]
  grep -q "statuses/${stamped_sha}" "$POST_LOG"
  grep -q "state=success" "$POST_LOG"
  grep -q "description=1.2.3 ${tree}" "$POST_LOG"
}

@test "member-aware POST: resolver absent falls back to the single-marker POST on a mixed diff" {
  install_gh_mock ok
  commit_mixed_diff

  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${tree}.ok"
  printf '{}' > "$SANDBOX/$marker"

  # No resolver copied into SANDBOX: the member-aware gate is skipped and the
  # frontend marker alone clears the POST, same as today.
  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == "status: posted GAIA-Audit success "* ]]
}
