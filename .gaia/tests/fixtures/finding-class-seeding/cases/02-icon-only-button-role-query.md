# 02-icon-only-button-role-query

**Path**: `app/components/Button/tests/index.test.tsx`
**Line**: 58

## Title

An accessible-name query for the icon-only button variant is satisfied by the button's
wrapping toolbar label, so a missing icon leaves the test passing.

## Failure mode

The test for the icon-only `Button` variant looks up the button with
`getByRole('button', {name: /close/i})`. The button itself renders no accessible name
when its `icon` prop is undefined (a real regression), but the enclosing toolbar has an
`aria-label="Close panel"` on a parent landmark, and testing-library's accessible-name
computation falls back to that ancestor label. The query still finds an element named
"Close panel", so the test passes even with the icon-only button rendering completely
unlabeled.

## Verified by

Removed the `aria-label` prop passed to the `Button`'s icon in a local edit and reran
the suite; `getByRole` still resolved because of the parent landmark's label, and the
test still passed.

## Suggested fix

Query the button element directly with `getByTestId` or a narrower container-scoped
query, or assert `toHaveAccessibleName` against the button node itself rather than a
role query that can traverse to an ancestor's label.
