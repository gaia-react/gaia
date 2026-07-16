#!/usr/bin/env bats

# Regression guard for the "Write GAIA-Audit commit status (clean, no push)"
# step in .github/workflows/code-review-audit.yml.
#
# The step used to stamp `git rev-parse HEAD`. By the time it runs, the runner's
# HEAD can be a local, never-pushed commit the audit created during the run (an
# empty trailer marker, or a refused self-heal edit), so the
# `gh api .../statuses/<sha>` POST targeted a sha GitHub did not have, returned
# HTTP 422 ("No commit found for SHA"), and -- under `set -eu` -- turned an
# otherwise-clean audit's required check RED on a clean PR.
#
# The fix pins two independent properties, either of which keeps the check green:
#   1. Target the PUSHED PR head from the event payload
#      (github.event.pull_request.head.sha), the only commit GitHub is
#      guaranteed to have, for the status sha, the recomputed frontend
#      digest (C1) that keys the marker lookup, AND the description.
#   2. Make the status POST non-fatal so a failed side-effect never reds a
#      clean audit.
#
# The workflow YAML is not directly unit-testable, so this suite inspects the
# in-tree step block (the same approach required-check-registration.bats uses).
# It lives under .github/audit/tests/ so the CI bats runner (audit-ci-tests.yml,
# check name "bats (.github/audit)") executes it.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

  # Extract only the "clean, no push" step block: from its `- name:` line up to
  # (not including) the next step's `- name:` line. index() matches a literal
  # substring so the parens in the step name need no escaping.
  STEP="$BATS_TEST_TMPDIR/clean-no-push.step"
  awk '
    index($0, "- name: Write GAIA-Audit commit status (clean, no push)") { grab=1; print; next }
    grab && /^      - name: / { exit }
    grab { print }
  ' "$WORKFLOW" > "$STEP"
  [ -s "$STEP" ] || skip "clean, no push step not found"
}

@test "clean-no-push step binds HEAD_SHA to the pushed PR head from the event" {
  run grep -F 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$STEP"
  [ "$status" -eq 0 ]
}

@test "clean-no-push step stamps the pushed head sha, not the runner's HEAD" {
  run grep -F 'statuses/${HEAD_SHA}' "$STEP"
  [ "$status" -eq 0 ]
  # The buggy pattern -- resolving the stamp target from `git rev-parse HEAD` --
  # must not return.
  run grep -F 'head_sha="$(git rev-parse HEAD)"' "$STEP"
  [ "$status" -ne 0 ]
}

@test "clean-no-push step derives the marker from the recomputed frontend digest" {
  # The marker is keyed to the frontend member's content digest (C1), not the
  # pushed head's commit sha or tree: the agent names its marker for the
  # digest it audited, so a commit- or tree-keyed lookup here would never
  # find it. The digest must therefore be recomputed (--ref "${HEAD_SHA}",
  # the pushed head's exact content) BEFORE the marker path is built.
  run grep -F 'bash .gaia/scripts/audit-member-digest.sh' "$STEP"
  [ "$status" -eq 0 ]
  run grep -F -- '--ref "${HEAD_SHA}")"; then' "$STEP"
  [ "$status" -eq 0 ]
  run grep -F 'marker=".gaia/local/audit/${frontend_digest}.ok"' "$STEP"
  [ "$status" -eq 0 ]

  # The tree- or commit-keyed marker paths must not return.
  run grep -F 'marker=".gaia/local/audit/${tree_sha}.ok"' "$STEP"
  [ "$status" -ne 0 ]
  run grep -F 'marker=".gaia/local/audit/${HEAD_SHA}.ok"' "$STEP"
  [ "$status" -ne 0 ]

  # Ordering guard: the digest must be resolved above the marker lookup, or
  # the guard tests an empty key and every clean audit silently stops
  # stamping.
  digest_line=$(grep -nF 'bash .gaia/scripts/audit-member-digest.sh' "$STEP" | head -1 | cut -d: -f1)
  marker_line=$(grep -nF 'marker=".gaia/local/audit/${frontend_digest}.ok"' "$STEP" | head -1 | cut -d: -f1)
  [ -n "$digest_line" ]
  [ -n "$marker_line" ]
  [ "$digest_line" -lt "$marker_line" ]
}

@test "clean-no-push status POST is non-fatal (guarded, never reds a clean audit)" {
  run grep -F 'if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${HEAD_SHA}"' "$STEP"
  [ "$status" -eq 0 ]
}
