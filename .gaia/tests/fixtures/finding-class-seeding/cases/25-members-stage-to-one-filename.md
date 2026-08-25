# 25-members-stage-to-one-filename

**Path**: `.gaia/scripts/audit-write-findings.sh`
**Line**: 63

## Title

Every co-dispatched reviewer stages its findings array through the same fixed scratch
filename before publishing.

## Failure mode

The writer stages the incoming array at `${TMPDIR}/audit-findings-staging.json`, a path
holding nothing that names the reviewer or the round. The orchestrator dispatches
several reviewers in one wave and they share a scratch directory, so two that stage at
overlapping moments write the same file: the second write lands under the first
reviewer's identity when the first reads it back, and the file a previous round left
behind is republished as though this round produced it. Both outcomes are invisible
downstream, because the published sidecar is the only record anyone reads.

## Verified by

Ran two reviewer invocations concurrently against the same scratch directory with
distinguishable arrays; the published sidecar for the first named the second's findings.

## Suggested fix

Stage through a path carrying the reviewer name and the round key, or skip staging
entirely and stream the array to the writer on standard input.
