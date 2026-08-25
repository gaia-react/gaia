# 27-runner-sets-no-output-ceiling

**Path**: `.gaia/cli/src/release/changelog.ts`
**Line**: 27

## Title

The command runner captures a full commit log with no ceiling on how much output it will
accept.

## Failure mode

The runner calls `execFile` with no `maxBuffer` option, taking Node's default, and the
command it runs is a `git log` over every commit since the previous tag. A release cut
after a long gap produces more log text than the default allows, so the call rejects
with `ENOBUFS`. The catch arm around it reports "could not read git history", which is
also the message a missing `git` binary produces, so the operator investigates their
installation rather than the size of the range.

## Verified by

Ran the same command against a range producing roughly 1.2 MB of output: the call
rejected with `ENOBUFS`, and the same call with an explicit ceiling above that size
returned the full log.

## Suggested fix

Set an explicit `maxBuffer` sized for the largest range the release process can
legitimately produce, and stream the log rather than buffering it when the range is
open-ended.
