# 28-guard-cost-grows-with-input

**Path**: `.claude/hooks/block-secrets-write.sh`
**Line**: 74

## Title

The write guard re-scans the whole payload once per candidate line, with no ceiling on
the payload it accepts.

## Failure mode

For every line matching the coarse pre-filter, the guard runs the full pattern set over
the entire payload again rather than over that line, so the work grows with the product
of the payload size and the number of matching lines. A large file written in one call,
the kind a generated lock file or a bundled asset produces, takes the guard into tens of
seconds. Nothing caps the payload it will attempt and nothing bounds the run, so the tool
call it gates simply appears to stall, with no message naming the size as the cause.

## Verified by

Timed the guard against payloads of 16 KB, 64 KB, and 256 KB with a fixed proportion of
matching lines: roughly 0.4 s, 6 s, and 94 s, and the trend continues past that.

## Suggested fix

Scan each candidate line rather than re-scanning the payload per line, and refuse
outright above a stated payload size rather than running for an unbounded time.
