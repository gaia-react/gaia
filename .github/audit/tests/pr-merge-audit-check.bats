#!/usr/bin/env bats

# Tests for .claude/hooks/pr-merge-audit-check.sh (the PreToolUse Bash hook
# that blocks `gh pr merge` until a code-review-audit signal exists for HEAD).
#
# The hook lives under .claude/hooks/, but its fixture sits here in
# .github/audit/tests/ so it runs in the same audit-ci-tests.yml suite as the
# other GAIA-Audit status readers.
#
# The hook reads a tool-call JSON on stdin (.tool_name, .tool_input.command).
# It denies by printing a permissionDecision: deny JSON; it allows by exiting 0
# with NO output. Each test runs the hook with cwd inside an isolated git
# sandbox on a FEATURE branch off main (so the merge-base diff is non-empty)
# whose diff carries an in-scope path (app/), keeping the marker mandatory so
# neither the out-of-scope nor self-mod bypass fires and the GitHub commit
# status fallback is the deciding signal.
#
# The status fallback path is exercised by mocking `gh` on a prepended PATH.
# The mock returns a full JSON statuses array and runs the hook's real `--jq`
# expression (which includes the state == "success" filter), so a pending
# status is filtered out exactly as the hook filters it. The mock also answers
# `gh pr view --json title` (empty, so the chore(deps) bypass never fires).
#
# Coverage:
#   1. Pending GAIA-Audit status, matching version+tree → deny gh pr merge
#   2. Success GAIA-Audit status, matching version+tree → allow (exit 0, no JSON)

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../../../.claude/hooks/pr-merge-audit-check.sh"
  [ -x "$SCRIPT" ] || skip "pr-merge-audit-check.sh not executable"
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia" "$SANDBOX/app"
  printf '1.2.3\n' > "$SANDBOX/.gaia/VERSION"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the PR branch diverges from here.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add .gaia/VERSION README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  # Feature branch with an in-scope (app/) change, so the out-of-scope and
  # self-mod bypasses both fail-closed and the merge requires an audit signal.
  git -C "$SANDBOX" checkout --quiet -b feature
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" add app/x.ts
  git -C "$SANDBOX" commit --quiet -m "feat: add x"
}

# The hook reads tool-call JSON on stdin and resolves HEAD via the cwd's git,
# so run it with cwd inside the sandbox and a `gh pr merge` command payload.
run_hook() {
  local input
  input=$(jq -nc '{tool_name:"Bash",tool_input:{command:"gh pr merge --squash"}}')
  ( cd "$SANDBOX" && printf '%s' "$input" | "$SCRIPT" )
}

current_tree() {
  git -C "$SANDBOX" rev-parse "HEAD^{tree}"
}

# Install a fake `gh` on a prepended PATH. It dispatches on argv:
#   - `gh api .../statuses --jq <expr>` → run the real jq (with the hook's own
#     state-filtered expression) against the crafted statuses array.
#   - `gh pr view --json title ...`     → print an empty title (no chore(deps)).
#   - anything else                     → empty.
# Returns the full JSON array so the hook's --jq state filter is what decides.
# Also sets GITHUB_REPOSITORY so the hook skips `gh repo view`.
install_gh_array_mock() {
  local payload="$1"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$payload" > "$BATS_TEST_TMPDIR/gh-statuses.json"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
statuses_file="$BATS_TEST_TMPDIR/gh-statuses.json"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
args="$*"
case "$args" in
  *statuses*)
    jq_expr=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_expr="$a"; break; fi
      prev="$a"
    done
    [ -n "$jq_expr" ] || { printf 'null\n'; exit 0; }
    jq -r "$jq_expr" < "$statuses_file"
    ;;
  *"pr view"*|*"pr"*"view"*)
    # No PR title → chore(deps) bypass never fires.
    printf '\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# -----------------------------------------------------------------------------
# 1. Pending GAIA-Audit status with matching version+tree denies gh pr merge
# -----------------------------------------------------------------------------

@test "merge hook: pending GAIA-Audit status with matching version+tree denies gh pr merge" {
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"pending\",\"description\":\"1.2.3 ${tree}\"}]"

  run run_hook
  [ "$status" -eq 0 ]
  # The hook emits a deny JSON; assert the permission decision is deny.
  decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$decision" = "deny" ]
}

# -----------------------------------------------------------------------------
# 2. Success GAIA-Audit status with matching version+tree allows gh pr merge
# -----------------------------------------------------------------------------

@test "merge hook: success GAIA-Audit status with matching version+tree allows gh pr merge" {
  tree=$(current_tree)
  install_gh_array_mock \
    "[{\"context\":\"GAIA-Audit\",\"state\":\"success\",\"description\":\"1.2.3 ${tree}\"}]"

  run run_hook
  [ "$status" -eq 0 ]
  # Allow path: the hook exits 0 with no output (no deny JSON).
  [ -z "$output" ]
}
