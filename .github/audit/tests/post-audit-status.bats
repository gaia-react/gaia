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

# -----------------------------------------------------------------------------
# 1. Marker-gated POST: posts on marker present, skips on marker absent
# -----------------------------------------------------------------------------

@test "local producer: posts GAIA-Audit success only after marker exists" {
  install_gh_mock ok
  head_sha=$(git -C "$SANDBOX" rev-parse HEAD)
  tree=$(current_tree)
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${head_sha}.ok"
  printf '{"sha":"%s"}\n' "$head_sha" > "$SANDBOX/$marker"

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
  mkdir -p "$SANDBOX/.gaia/local/audit"
  marker=".gaia/local/audit/${head_sha}.ok"
  printf '{"sha":"%s"}\n' "$head_sha" > "$SANDBOX/$marker"

  run run_helper "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "status: declined: gh unauthenticated" ]

  # The marker the caller wrote is untouched; only the POST is skipped.
  [ -f "$SANDBOX/$marker" ]
  [ ! -f "$POST_LOG" ]
}
