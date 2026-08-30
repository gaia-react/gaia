# 34-fixture-reparsed-per-loop-iteration

**Path**: `.gaia/cli/src/automation/__tests__/slash-position.test.ts`
**Line**: 96

## Title

The four-position test re-parses its three fixtures inside the position loop, starting
twelve node processes where three would produce the same result.

## Failure mode

The suite iterates four positions and, inside that loop, parses each of the three
fixture files by spawning the parser as a child process. The fixture content does not
depend on the position, so each of the three parses returns the same value on all four
iterations: twelve spawns for three distinct results. Nothing is wrong with the
assertions, and the suite passes; the cost is suite wall-clock, and it multiplies by the
position count every time a position is added.

## Verified by

Counted child-process spawns for one run of the file: twelve. Hoisted the three parses
above the loop and re-ran: three spawns, identical assertions, identical result, suite
time down from 4.1s to 1.2s.

## Suggested fix

Parse the three fixtures once before the position loop and index into the results inside
it.
