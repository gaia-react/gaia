# 21-status-writer-pasted-across-jobs

**Path**: `.github/workflows/code-review-audit.yml`
**Line**: 212

## Title

Five jobs each carry their own inline copy of the fail-closed status-posting step.

## Failure mode

The step that posts the gate's commit status is written out five times across this
file, once per job that needs it: same `run:` body, same `curl` invocation, same
retry arm, same error text. Nothing derives one from another and no composite action
holds a single version. A correction to the retry arm therefore has to be applied five
times, and a pull request that exercises only two of the five jobs proves nothing about
the other three, so a site left unedited keeps posting the old behaviour with every
check green.

## Verified by

Extracted each job's status-posting step body and compared them pairwise: five bodies,
byte-identical today, with no `uses:` reference or shared script between them.

## Suggested fix

Move the step body into a composite action under `.github/actions/` and have all five
jobs call it, so the retry arm has one definition.
