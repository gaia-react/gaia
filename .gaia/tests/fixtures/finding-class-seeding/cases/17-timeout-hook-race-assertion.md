# 17-timeout-hook-race-assertion

**Path**: `app/hooks/tests/useTimeout.test.ts`
**Line**: 44

## Title

A test asserts a timeout callback fired using a bare `setTimeout` race rather than
waiting on the hook's own signal.

## Failure mode

The test schedules the hook's timeout for 50ms, then does
`await new Promise(r => setTimeout(r, 60))` before asserting the callback ran. On a
loaded CI runner, the assertion sometimes reads the DOM before React has flushed the
state update the callback triggers, so the test intermittently fails even when the hook
behaves correctly, and intermittently passes even on a build that delays the callback
well past 60ms.

## Verified by

Ran the suite under artificial CPU throttling; the test failed roughly one run in eight
with no code change, purely from timing.

## Suggested fix

Replace the fixed-delay race with `waitFor` (or the hook's own completion signal) so
the assertion waits on the actual state change rather than a guessed delay.
