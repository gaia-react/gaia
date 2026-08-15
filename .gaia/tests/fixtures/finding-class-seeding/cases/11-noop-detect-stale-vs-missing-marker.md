# 11-noop-detect-stale-vs-missing-marker

**Path**: `.gaia/scripts/audit-noop-detect.sh`
**Line**: 33

## Title

The no-op detector's message for a validation failure is printed whether the marker is
stale or was never written at all.

## Failure mode

When the earned-marker validation check fails, the script prints "stale marker: audit
ran on a superseded commit, re-run the audit." That branch is reached both when a
marker file exists but its digest no longer matches HEAD (genuinely stale) and when no
marker file exists at all (the audit never wrote one, for instance because it crashed
before completing). The script does not distinguish the two cases in its message, so
an operator reading "stale marker, re-run the audit" in the missing-marker case is
pointed at re-running an audit that already ran to completion once, rather than at
investigating why no marker was ever produced.

## Verified by

Deleted a marker file entirely (rather than making it stale) and reran the detector; it
printed the same "stale marker" message as the genuinely-stale case.

## Suggested fix

Check for the marker file's existence separately from its digest match, and print a
distinct message ("no marker was ever written" vs. "marker is stale") for each case.
