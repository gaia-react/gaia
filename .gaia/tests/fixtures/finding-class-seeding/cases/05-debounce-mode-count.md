# 05-debounce-mode-count

**Path**: `app/hooks/tests/useDebounce.test.ts`
**Line**: 12

## Title

A describe block claims four debounce modes; the modes array beside it holds three.

## Failure mode

The outer `describe` block is titled `"covers all four debounce modes"`. The `modes`
array the suite iterates over holds three entries. A fourth mode existed briefly during
development and was removed, but the describe title was never updated to match.

## Verified by

Counted the `modes` array's entries against the describe title's stated count: three
entries, title says four.

## Suggested fix

Update the describe title to name the current count, or derive the title's number
programmatically from `modes.length` so the two can't diverge again.
