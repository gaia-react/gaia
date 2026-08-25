# 24-status-step-takes-local-head

**Path**: `.github/workflows/audit-ci-tests.yml`
**Line**: 96

## Title

The status-posting step reads the commit to stamp from the checked-out `HEAD` rather
than from the event payload.

## Failure mode

The step computes `sha=$(git rev-parse HEAD)` and posts the check status against that
value. On a `pull_request` event the runner checks out the merge commit GitHub creates
for the run, which is not the pull request's head commit and does not exist in the
repository the status is being posted to. The API call succeeds against a commit no
branch protection rule ever reads, so the status is published, the step is green, and
the required check on the pull request's own head stays permanently absent.

## Verified by

Compared the step's computed value with `github.event.pull_request.head.sha` on a real
run: the two differ, and the posted status appears under the merge commit rather than
under the head the pull request shows.

## Suggested fix

Take the commit from `github.event.pull_request.head.sha`, falling back to
`github.sha` only on event types that carry no pull request.
