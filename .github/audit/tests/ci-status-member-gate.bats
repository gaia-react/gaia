#!/usr/bin/env bats

# Guards the member-aware gate on every GAIA-Audit success-status POST in
# .github/workflows/code-review-audit.yml, and the shared gate script
# .github/audit/gate-pending-members.sh that all three consult.
#
# THREE steps can POST `state=success`, and each is a way to clear the required
# GAIA-Audit check and open the github.com merge button:
#
#   1. "Write GAIA-Audit commit status"                  (self-heal push path)
#   2. "Write GAIA-Audit commit status (clean, no push)" (clean-no-commit path)
#   3. "Write GAIA-Audit commit status (out-of-scope skip)" (has_source == false)
#
# What they guard against: stamping success on the FRONTEND member's clearance
# alone. CI runs exactly ONE auditor (the audit step's prompt dispatches
# code-audit-frontend), so every OTHER member the resolver dispatches is
# local-only in CI: CI cannot run it, and its marker lives under gitignored
# .gaia/local/, so CI never sees a clearance for it. Success on the frontend's
# clearance alone defeats the Code Audit Team AND-aggregator and unblocks the
# merge button for a diff a required auditor never read.
#
# Path 3 is the subtle one: "out of scope" there means out of scope for the
# FRONTEND member (has_source mirrors that member's auditable-base set exactly).
# A specialized member's globs sit OUTSIDE that set, so a diff touching only
# framework CLI source or framework bash yields has_source == 'false' while the
# resolver still dispatches a member owning every changed file.
#
# Two invariants the gate script pins, each of which silently re-opens the bypass
# if broken:
#   - Membership is resolved over the FULL PR diff, never the review increment.
#     The incremental audit base advances to the newest ancestor carrying a clean
#     GAIA-Audit trailer, and that trailer is stamped by the frontend agent alone
#     (it is not member-aware), so an increment measured from it can exclude a
#     maintainer-owned file a co-dispatched member never cleared.
#   - Fail-open is LOUD. An unusable resolver yields no pending members (a broken
#     resolver must not brick the merge path), but it says so on stderr, so a
#     disarmed gate is distinguishable from a genuinely clean one.
#
# The step tests EXECUTE the real `run:` body extracted from the workflow YAML
# against a sandbox repo with the real resolver and a mocked `gh`, so they
# exercise shipped code rather than grepping for a string.
#
# Assertion style per .claude/rules/bats-assertions.md: POSIX `[ ]` and `grep -qF`
# for presence; a positive match plus an explicit `return 1` for absence (a
# `!`-negated non-final line never fails a test under `set -e`).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  GATE="$REPO_ROOT/.github/audit/gate-pending-members.sh"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"
  [ -f "$GATE" ] || skip "gate-pending-members.sh not found"

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

  # The real resolver and the real gate, so the decision under test is shipped.
  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.github/audit"
  cp "$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" "$SANDBOX/.gaia/scripts/"
  cp "$GATE" "$SANDBOX/.github/audit/"
  chmod +x "$SANDBOX/.gaia/scripts/resolve-audit-members.sh" \
           "$SANDBOX/.github/audit/gate-pending-members.sh"

  POST_LOG="$BATS_TEST_TMPDIR/gh-post.log"
  rm -f "$POST_LOG"
  install_gh_mock
}

# Fake `gh` on a prepended PATH: records every `gh api` argv.
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
# Matches the `- name:` line EXACTLY, so "Write GAIA-Audit commit status" does
# not also match its "(clean, no push)" / "(out-of-scope skip)" siblings.
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

base_sha() { git -C "$SANDBOX" rev-parse main; }

# app/ + .gaia/cli/src/** -> dispatches code-audit-frontend AND
# code-audit-maintainer-node against the built-in roster.
commit_mixed_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app" "$SANDBOX/.gaia/cli/src"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  echo "export const y = 2;" > "$SANDBOX/.gaia/cli/src/y.ts"
  git -C "$SANDBOX" add app/x.ts .gaia/cli/src/y.ts
  git -C "$SANDBOX" commit --quiet -m "mixed change"
}

# app/ only -> code-audit-frontend alone: CI can clear it by itself.
commit_app_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/app"
  echo "export const x = 1;" > "$SANDBOX/app/x.ts"
  git -C "$SANDBOX" add app/x.ts
  git -C "$SANDBOX" commit --quiet -m "app-only change"
}

# .gaia/cli/src/** only -> has_source == 'false' (the frontend member owns
# nothing here) yet the resolver dispatches code-audit-maintainer-node. This is
# the shape the out-of-scope skip path must NOT wave through.
commit_maintainer_only_diff() {
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/.gaia/cli/src"
  echo "export const y = 2;" > "$SANDBOX/.gaia/cli/src/y.ts"
  git -C "$SANDBOX" add .gaia/cli/src/y.ts
  git -C "$SANDBOX" commit --quiet -m "maintainer-only change"
}

write_frontend_marker() {
  mkdir -p "$SANDBOX/.gaia/local/audit"
  printf '{}' > "$SANDBOX/.gaia/local/audit/$1.ok"
}

run_gate() { ( cd "$SANDBOX" && bash .github/audit/gate-pending-members.sh "$@" ); }

# Run an extracted step body in the sandbox with the CI env it reads.
run_step() {
  local body="$1" sha="$2"
  ( cd "$SANDBOX" \
    && GITHUB_REPOSITORY="gaia-react/gaia" \
       HEAD_SHA="$sha" \
       AUDIT_SHA="$sha" \
       PR_BASE_SHA="$(base_sha)" \
       bash "$body" )
}

# -----------------------------------------------------------------------------
# gate-pending-members.sh, the shared gate
# -----------------------------------------------------------------------------

@test "gate: mixed diff reports the co-dispatched maintainer member as pending" {
  commit_mixed_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
  # CI runs the frontend member itself, so it is never "pending".
  grep -qF "code-audit-frontend" <<<"$output" && return 1
  return 0
}

@test "gate: app-only diff reports nothing pending (CI can clear it alone)" {
  commit_app_only_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "gate: maintainer-only diff reports the member pending even though has_source is false" {
  commit_maintainer_only_diff
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
}

@test "gate: an unusable resolver fails open, but says so on stderr" {
  commit_mixed_diff
  rm -f "$SANDBOX/.gaia/scripts/resolve-audit-members.sh"

  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  # Fails open: no members pending, so a broken resolver cannot brick the merge.
  grep -qF "code-audit-maintainer" <<<"$output" && return 1
  # But never silently: the operator can tell a disarmed gate from a clean one.
  grep -qF "failing open" <<<"$output"
}

@test "gate: an incremental base that skips the maintainer file shrinks the member set" {
  # Pins WHY the workflow must pass the full-PR base. A base advanced past the
  # maintainer-owned file (what a frontend-only GAIA-Audit trailer would do to
  # the incremental base) yields an empty member set -- the bypass this gate
  # exists to close. The workflow binds PR_BASE_SHA to the PR base for exactly
  # this reason; the binding is asserted in the step tests below.
  commit_mixed_diff
  maintainer_commit="$(git -C "$SANDBOX" rev-parse HEAD)"
  # A later app-only commit; measuring from $maintainer_commit sees only app/.
  echo "export const z = 3;" > "$SANDBOX/app/z.ts"
  git -C "$SANDBOX" add app/z.ts
  git -C "$SANDBOX" commit --quiet -m "app-only follow-up"

  run run_gate --base "$maintainer_commit"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]

  # The full-PR base still sees the maintainer file and holds the gate shut.
  run run_gate --base "$(base_sha)"
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-node" <<<"$output"
}

# -----------------------------------------------------------------------------
# All three status steps bind the FULL-PR base, never the incremental one
# -----------------------------------------------------------------------------

@test "every status step resolves members over the full-PR base" {
  for step in \
    "Write GAIA-Audit commit status" \
    "Write GAIA-Audit commit status (clean, no push)" \
    "Write GAIA-Audit commit status (out-of-scope skip)"
  do
    body="$(extract_step_body "$step")"
    grep -qF 'gate-pending-members.sh --base "${PR_BASE_SHA}"' "$body" || return 1
    # The incremental audit base must never decide membership.
    grep -qF 'gate-pending-members.sh --base "${AUDIT_BASE}"' "$body" && return 1
  done

  # PR_BASE_SHA is the PR's base sha from the event payload, for all three steps.
  run grep -cF 'PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}' "$WORKFLOW"
  [ "$output" -eq 3 ]
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
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "context=GAIA-Audit" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

  grep -qF "state=success" "$POST_LOG" && return 1

  # The pending description must not carry the cleared "<version> <tree-sha>"
  # shape, so a state-blind reader cannot mistake it for cleared.
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

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]
  [ ! -f "$POST_LOG" ]
}

# -----------------------------------------------------------------------------
# self-heal push path
# -----------------------------------------------------------------------------

@test "push path: mixed diff never posts success while a co-dispatched member is pending" {
  body="$(extract_step_body 'Write GAIA-Audit commit status')"
  commit_mixed_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

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

# -----------------------------------------------------------------------------
# out-of-scope skip path: "out of scope" is frontend-relative, not team-relative
# -----------------------------------------------------------------------------

@test "out-of-scope skip: maintainer-only diff never posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  commit_maintainer_only_diff
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  grep -qF "state=pending" "$POST_LOG"
  grep -qF "code-audit-maintainer-node" "$POST_LOG"

  # A success here clears the required check for a diff whose only auditor never
  # ran: the merge button opens on wholly un-reviewed framework source.
  grep -qF "state=success" "$POST_LOG" && return 1
  return 0
}

@test "out-of-scope skip: a genuinely unowned diff still posts success" {
  body="$(extract_step_body 'Write GAIA-Audit commit status (out-of-scope skip)')"
  # docs-only: no member owns it, so the skip is a real skip.
  git -C "$SANDBOX" checkout --quiet -b feature
  mkdir -p "$SANDBOX/docs"
  echo "# notes" > "$SANDBOX/docs/notes.md"
  git -C "$SANDBOX" add docs/notes.md
  git -C "$SANDBOX" commit --quiet -m "docs only"
  sha="$(git -C "$SANDBOX" rev-parse HEAD)"

  run run_step "$body" "$sha"
  [ "$status" -eq 0 ]

  [ -f "$POST_LOG" ]
  tree="$(git -C "$SANDBOX" rev-parse "HEAD^{tree}")"
  grep -qF "state=success" "$POST_LOG"
  grep -qF "description=1.2.3 ${tree}" "$POST_LOG"
}
