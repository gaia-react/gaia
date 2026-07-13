#!/usr/bin/env bats

# Regression guard for the member-aware gate on BOTH GAIA-Audit success-status
# POSTs in .github/workflows/code-review-audit.yml:
#
#   - "Write GAIA-Audit commit status"                  (the self-heal push path)
#   - "Write GAIA-Audit commit status (clean, no push)" (the clean-no-commit path)
#
# What these guard against: a status POST that greenlights a diff on the
# frontend member's clearance alone. CI runs exactly ONE auditor (the audit
# step's prompt dispatches code-audit-frontend), so every OTHER member the
# resolver dispatches for the diff is local-only in CI: CI cannot run it and
# never writes its marker. Posting success on the frontend's clearance alone
# therefore defeats the AND-aggregator at the workflow layer and unblocks the
# github.com merge button for a PR a required auditor never reviewed. On a diff
# where a maintainer member owns most of the changed files, that member never
# runs in CI and would withhold its marker locally, yet the shared check goes
# green anyway.
#
# The local producer (.claude/hooks/post-audit-status.sh) is member-aware. The
# workflow is the layer that must agree with it: it runs last, so a
# member-blind POST here silently overrides the agent's deliberate refusal.
#
# Each step pins one property: when the dispatched member set contains any
# member besides code-audit-frontend, the step posts `state=pending` (a
# description that carries NO "<version> <tree-sha>" cleared shape) and NEVER
# `state=success`. The local, member-aware producer posts success once every
# dispatched member's marker exists.
#
# These tests EXECUTE the step's real shell body, extracted from the workflow
# YAML, against a sandbox repo with the real resolver and a mocked `gh`, so they
# exercise the actual shipped decision rather than grepping for a string.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF` for presence; a positive match plus an explicit `return 1` for
# absence (a `!`-negated non-final line never fails a test under `set -e`).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

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

  # The real resolver, so the dispatch decision under test is the shipped one.
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" \
     "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
  install_gh_mock
}

# Fake `gh` on a prepended PATH: records every `gh api` argv so a test can
# assert which status state was POSTed.
install_gh_mock() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
record="$POST_LOG"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  api) printf '%s\n' "$*" >> "$record"; exit 0 ;;
  *)   exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# Extract one step's `run:` shell body from the workflow YAML and dedent it.
# Matches the step's `- name:` line EXACTLY, so "Write GAIA-Audit commit status"
# does not also match its "(clean, no push)" / "(out-of-scope skip)" siblings.
extract_step_body() {
  local step_name="$1" out="$BATS_TEST_TMPDIR/step.sh"
  awk -v want="      - name: ${step_name}" '
    !grab && $0 == want { grab=1; next }
    grab && /^      - name: / { exit }
    grab && !inrun && /^        run: \|[[:space:]]*$/ { inrun=1; next }
    inrun { print }
  ' "$WORKFLOW" | sed 's/^          //' > "$out"
  [ -s "$out" ] || return 1
  printf '%s' "$out"
}

# A mixed app/ + .gaia/**/*.sh diff dispatches BOTH code-audit-frontend (app/)
# and code-audit-maintainer-shell (.gaia/**/*.sh) against the built-in roster.
commit_mixed_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "#!/bin/bash" > "$SANDBOX/.gaia/scripts/example.sh"
  git -C "$SANDBOX" add app/x.ts .gaia/scripts/example.sh
  git -C "$SANDBOX" commit --quiet -m "mixed change"
}

# An app-only diff dispatches code-audit-frontend alone: CI can clear it.
commit_app_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" add app/x.ts
  git -C "$SANDBOX" commit --quiet -m "app-only change"
}

write_frontend_marker() {
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf '{}' > "$SANDBOX/.gaia/local/audit/$1.ok"
}

# Run an extracted step body in the sandbox with the CI env it reads.
run_step() {
  local body="$1" sha="$2"
  ( cd "$SANDBOX" \
    && GITHUB_REPOSITORY="gaia-react/gaia" \
       HEAD_SHA="$sha" \
       AUDIT_SHA="$sha" \
       AUDIT_BASE="main" \
       bash "$body" )
}

# -----------------------------------------------------------------------------
# clean-no-push path
# -----------------------------------------------------------------------------

@test "clean-no-push: mixed diff with only the frontend marker never posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  write_frontend_marker "$sha"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  # The AND-aggregator holds: pending, naming the member that never cleared.
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "context=GAIA-Audit" "$POST_LOG"
  grep -qF "code-audit-maintainer-shell" "$POST_LOG"

  # The bug: a success status here unblocks the github.com merge button for a
  # PR the maintainer-shell auditor never read.
  grep -qF "state=success" "$POST_LOG" && return 1

  # The pending description must not carry the "<version> <tree-sha>" cleared
  # shape, so even a state-blind reader cannot mistake it for cleared.
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG" && return 1
  return 0
}

@test "clean-no-push: app-only diff with the frontend marker still posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  write_frontend_marker "$sha"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "statuses/${sha}" "$POST_LOG"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}

@test "clean-no-push: mixed diff without the frontend marker posts nothing at all" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (clean, no push)')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"
  # No marker: the audit is not proven clean, so the step bails before any POST.

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# self-heal push path (same defect, same gate)
# -----------------------------------------------------------------------------

@test "push path: mixed diff never posts success while a co-dispatched member is pending" {
  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-shell" "$POST_LOG"

  grep -qF "state=success" "$POST_LOG" && return 1
  return 0
}

@test "push path: app-only diff posts success as before" {
  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  commit_app_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "statuses/${sha}" "$POST_LOG"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}
