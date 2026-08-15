# 18-config-flag-typo-tolerance

**Path**: `.gaia/cli/src/automation/read-config.ts`
**Line**: 29

## Title

An unrecognized command-line flag is silently ignored rather than rejected or warned
about.

## Failure mode

The argument parser here matches known flags by exact key lookup and drops anything it
doesn't recognize with no warning, no error, and no log line. A caller who types
`--windowClass` instead of `--window-class` gets no feedback at all: the flag is
silently discarded, and the command proceeds using the default value as though the
flag had never been passed.

## Verified by

Ran the command with the misspelled flag; it exited 0, produced no warning, and
behaved identically to a run with no flag passed at all.

## Suggested fix

Reject unrecognized flags with a non-zero exit and a message naming the unknown flag,
or log a warning naming it, so a typo doesn't silently fall back to default behavior.
