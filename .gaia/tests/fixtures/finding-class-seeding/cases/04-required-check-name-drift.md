# 04-required-check-name-drift

**Path**: `.github/workflows/verify-required-checks.yml`
**Line**: 9

## Title

A step comment names a required-check id that branch protection no longer registers
under that name.

## Failure mode

A comment directly above the verification step reads "confirms `lint-and-typecheck` is
registered as a required status check." Branch protection's required-checks list
carries `quality-gate` instead; the job id was renamed when the gate was consolidated,
and the comment was never updated. A maintainer troubleshooting a blocked merge who
greps for `lint-and-typecheck` to find the check that is supposedly required finds
nothing under that name.

## Verified by

Compared the comment's named id against the workflow's own job id and the
branch-protection required-checks list; neither carries `lint-and-typecheck`.

## Suggested fix

Update the comment to name `quality-gate`, or reference the job id programmatically so
the comment cannot drift from it again.
