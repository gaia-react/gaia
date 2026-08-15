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
#      clean audit. #1296 extended that answer to all four success writers, so
#      it is now the writer's only behavior rather than this path's opt-in.
#
# The workflow YAML is not directly unit-testable, so this suite inspects the
# in-tree step block (the same approach required-check-registration.bats uses).
# It lives under .github/audit/tests/ so the CI bats runner (audit-ci-tests.yml,
# check name "Audit CI Tests") executes it.
#
# THE TWO PROPERTIES NOW LIVE AT DIFFERENT ENDS, AND THIS SUITE PINS EACH WHERE
# IT LIVES. #1286 moved the shared status-writing logic out of the five terminal
# steps and into .github/audit/write-audit-status.sh, so the step supplies the
# inputs (--sha from the event payload, --require-marker) and the writer
# implements them. Property 1 is asserted at both ends, because a flag nobody
# reads and a flag nobody passes fail the same way. Property 2 is asserted at the
# writer end alone: #1296 settled non-fatality for every success writer, so this
# path no longer opts into it and there is no step-end input to pin. The
# behavioral counterpart -- these steps actually EXECUTED against a gh mock -- is
# ci-status-member-gate.bats.

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

  # Regex, not -F: a bare substring is satisfiable by any line that merely names
  # the script, so one rationale comment above the call would hollow this pin
  # out while reading green. `bash ` immediately before the path is what binds
  # the assertion to the real invocation, and the path itself stays unpinned
  # because the writer anchors its sibling lookups behind "$repo_root" -- a
  # fixed string would pin the quoting rather than the claim. Same treatment
  # ci-status-member-gate.bats gives its own gate-call pin.
  run grep -E 'bash "?[^"]*audit-member-digest\.sh' "$WRITER"
  [ "$status" -eq 0 ]
  # The digest is recomputed for the sha being stamped. Pinned WITHOUT the
  # `)"; then` tail that used to ride along: that tail asserted the call sits in
  # a fail-closed `if`, which is a behavioral claim and is asserted behaviorally
  # (ci-status-member-gate.bats executes the step with the digest engine removed
  # and requires it to stop before the marker branch). Pinning it here as source
  # text meant a behavior-preserving reformat reddened this suite with a message
  # reading as a lost fail-closed guard.
  run grep -F -- '--ref "${sha}"' "$WRITER"
  [ "$status" -eq 0 ]
  run grep -F 'marker="$repo_root/.gaia/local/audit/${frontend_digest}.ok"' "$WRITER"
  [ "$status" -eq 0 ]

  # The tree- or commit-keyed marker paths must not return.
  run grep -F '.gaia/local/audit/${tree_sha}.ok"' "$WRITER"
  [ "$status" -ne 0 ]
  run grep -F '.gaia/local/audit/${sha}.ok"' "$WRITER"
  [ "$status" -ne 0 ]

  # Ordering guard: the digest must be resolved above the marker lookup, or
  # the guard tests an empty key and every clean audit silently stops
  # stamping. Same regex as the presence pin: with `head -1`, a substring match
  # would return the line number of the first *mention* (a rationale comment)
  # rather than the call, and compare that against the marker lookup.
  digest_line=$(grep -nE 'bash "?[^"]*audit-member-digest\.sh' "$WRITER" | head -1 | cut -d: -f1)
  marker_line=$(grep -nF 'marker="$repo_root/.gaia/local/audit/${frontend_digest}.ok"' "$WRITER" | head -1 | cut -d: -f1)
  [ -n "$digest_line" ]
  [ -n "$marker_line" ]
  [ "$digest_line" -lt "$marker_line" ]
}

@test "clean-no-push status POST is non-fatal (guarded, never reds a clean audit)" {
  # Non-fatality is a property of the writer now, not a flag this path asks for:
  # every success writer gets the same answer, so there is no opt-in left to
  # forget. Asserted at the writer end alone for that reason -- pinning it at the
  # step end would be pinning the ABSENCE of an argument, which any unrelated
  # edit satisfies.
  run grep -F 'if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}"' "$WRITER"
  [ "$status" -eq 0 ]

  # ...and no UNGUARDED spelling sits beside it. The writer POSTs to that
  # endpoint exactly twice -- pending, trailed by `|| true`, and success, headed
  # by `if !` -- so a bare third call, or either of these two losing its guard,
  # breaks the count. That bare shape under `set -eu` is what reddened a clean
  # audit, and it is one deleted token away from returning.
  total=$(grep -cF 'gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}"' "$WRITER")
  guarded=$(grep -cF 'if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}"' "$WRITER")
  [ "$total" -eq 2 ]
  [ "$guarded" -eq 1 ]
  # The other one is the pending POST, non-fatal by its own trailing `|| true`.
  run grep -F -- '--field description="${desc}" || true' "$WRITER"
  [ "$status" -eq 0 ]
}
