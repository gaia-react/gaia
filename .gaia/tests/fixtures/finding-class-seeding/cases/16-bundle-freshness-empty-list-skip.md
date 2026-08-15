# 16-bundle-freshness-empty-list-skip

**Path**: `.gaia/scripts/verify-cli-bundle-fresh.sh`
**Line**: 15

## Title

The bundle-freshness probe treats an empty file listing as "nothing built yet" using
the same listing it also diffs against source.

## Failure mode

The probe runs `find .gaia/cli/dist -maxdepth 1 -name "*.js"` once. If that listing is
empty, the script logs "no build output found, skipping freshness check" and exits 0
without comparing anything. The same listing also supplies the set of files the script
diffs against `.gaia/cli/src/**` when it is non-empty. A build that emits only `.mjs`
files (a legitimate build shape after a bundler config change) produces an empty
listing from this `-name "*.js"` pattern, and the probe silently skips the comparison
it exists to run, reporting nothing rather than reporting a possible mismatch.

## Verified by

Ran a build that emits `.mjs` output only, confirmed the probe's `find` returned
nothing, and confirmed the script exited 0 with its "skipping" message rather than
performing any comparison.

## Suggested fix

Widen the `find` pattern to also match `.mjs`, and separately, don't let an empty
listing mean "skip": treat zero build files as a failure the probe reports rather than
a condition it exits clean on.
