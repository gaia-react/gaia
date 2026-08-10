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
# check name "Audit CI Tests") executes it.
#
# BOTH PROPERTIES NOW LIVE IN TWO PLACES, AND THIS SUITE PINS BOTH ENDS. #1286
# moved the shared status-writing logic out of the five terminal steps and into
# .github/audit/write-audit-status.sh, so the step supplies the inputs
# (--sha from the event payload, --require-marker, --success-post-non-fatal) and
# the writer implements them. Asserting only the step would leave the writer
# free to ignore a flag; asserting only the writer would leave this path free to
# stop passing one. The behavioral counterpart -- these steps actually EXECUTED
# against a gh mock -- is ci-status-member-gate.bats.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  WORKFLOW="$REPO_ROOT/.github/workflows/code-review-audit.yml"
  [ -f "$WORKFLOW" ] || skip "code-review-audit.yml not found"

  # Extract only the "clean, no push" step block: from its `- name:` line up to
  # (not including) the next step's `- name:` line. index() matches a literal
  # substring so the parens in the step name need no escaping.
  WRITER="$REPO_ROOT/.github/audit/write-audit-status.sh"
  [ -f "$WRITER" ] || skip "write-audit-status.sh not found"

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
  # The step hands the event-payload sha to the writer...
  run grep -F -- '--sha "${HEAD_SHA}"' "$STEP"
  [ "$status" -eq 0 ]
  # ...and the writer stamps the sha it was handed, never one it resolves itself.
  run grep -F 'statuses/${sha}' "$WRITER"
  [ "$status" -eq 0 ]

  # The buggy pattern -- resolving the stamp target from `git rev-parse HEAD` --
  # must not return, at either end.
  run grep -F 'head_sha="$(git rev-parse HEAD)"' "$STEP"
  [ "$status" -ne 0 ]
  run grep -F 'git rev-parse HEAD)"' "$WRITER"
  [ "$status" -ne 0 ]
}

@test "clean-no-push step derives the marker from the recomputed frontend digest" {
  # The marker is keyed to the frontend member's content digest (C1), not the
  # pushed head's commit sha or tree: the agent names its marker for the
  # digest it audited, so a commit- or tree-keyed lookup here would never
  # find it. The digest must therefore be recomputed (--ref "${HEAD_SHA}",
  # the pushed head's exact content) BEFORE the marker path is built.
  # This is the path that requires a marker at all -- the writer only looks one
  # up when asked -- so the step must keep asking.
  run grep -F -- '--require-marker' "$STEP"
  [ "$status" -eq 0 ]

  run grep -F 'bash .gaia/scripts/audit-member-digest.sh' "$WRITER"
  [ "$status" -eq 0 ]
  run grep -F -- '--ref "${sha}")"; then' "$WRITER"
  [ "$status" -eq 0 ]
  run grep -F 'marker=".gaia/local/audit/${frontend_digest}.ok"' "$WRITER"
  [ "$status" -eq 0 ]

  # The tree- or commit-keyed marker paths must not return.
  run grep -F 'marker=".gaia/local/audit/${tree_sha}.ok"' "$WRITER"
  [ "$status" -ne 0 ]
  run grep -F 'marker=".gaia/local/audit/${sha}.ok"' "$WRITER"
  [ "$status" -ne 0 ]

  # Ordering guard: the digest must be resolved above the marker lookup, or
  # the guard tests an empty key and every clean audit silently stops
  # stamping.
  digest_line=$(grep -nF 'bash .gaia/scripts/audit-member-digest.sh' "$WRITER" | head -1 | cut -d: -f1)
  marker_line=$(grep -nF 'marker=".gaia/local/audit/${frontend_digest}.ok"' "$WRITER" | head -1 | cut -d: -f1)
  [ -n "$digest_line" ]
  [ -n "$marker_line" ]
  [ "$digest_line" -lt "$marker_line" ]
}

@test "clean-no-push status POST is non-fatal (guarded, never reds a clean audit)" {
  # Non-fatality is now a flag this path asks for and the writer honours, and
  # this path is the ONLY one that asks: the other three success writers leave
  # the POST bare on purpose. Both ends asserted, because a flag nobody reads
  # and a flag nobody passes fail the same way -- silently, and only on the
  # transient API error this guard exists for.
  run grep -F -- '--success-post-non-fatal' "$STEP"
  [ "$status" -eq 0 ]
  run grep -F 'if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}"' "$WRITER"
  [ "$status" -eq 0 ]
}
