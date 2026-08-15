# 12-ledger-status-margin-vs-window-failure

**Path**: `.gaia/cli/src/harden/ledger.ts`
**Line**: 87

## Title

The ledger status command's "suppressed" message covers both a genuinely low
recurrence count and a failed window read.

## Failure mode

`renderStatus()` prints "suppressed: recurrence below margin" whenever
`distinctPrCount < margin`. That condition is also true when the pull-request window
read itself failed and returned an empty list (`distinctPrCount` defaults to `0` in
that case), which is a different problem: the entry may actually be well above the
margin, but the tool couldn't tell because it never got a real count. The rendered
message doesn't distinguish "we checked and it's genuinely low" from "the check itself
failed," so an operator reading "suppressed: recurrence below margin" waits for more
pull requests instead of investigating why the window read failed.

## Verified by

Forced the window-read call to reject (simulated a failed `gh` call) and confirmed
`renderStatus()` printed the identical "suppressed: recurrence below margin" message it
prints for a real low count.

## Suggested fix

Track whether the window read succeeded separately from the resulting count, and print
a distinct message when the count is `0` because the read failed rather than because
recurrence is genuinely low.
