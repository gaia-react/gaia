---
type: component
path: app/components/Form/YearMonthDay/
status: active
language: typescript
purpose: Composite date-of-birth input — three locale-aware Selects + hidden ISO date
depends_on: [[Form Select]], [[Conform]], [[Form Components]]
created: 2026-04-20
updated: 2026-04-20
tags: [component, forms, date, gotcha]
---

# Form YearMonthDay

Three [[Form Select]]s (year, month, day) feeding one hidden `<input type="hidden" name="dob">` that carries the ISO-8601 date string to the server. The canonical example of a custom stateful component that integrates with Conform.

## Props

`name` (default `'dob'`), `value` (ISO 8601 `yyyy-MM-dd`), `onChange`, `onBlur?`, `error?`, `label?`, `required?`, `className?`, `classNameSelect?`. See `app/components/Form/YearMonthDay/index.tsx:27-37`.

## Year / Month / Day option generation

`YearMonthDay/utils.ts`:

- `YEARS = range(thisYear - 120, thisYear - 12).toReversed()` — 120-year span ending 12 years ago (minor)
- `MONTHS = range(1, 12)`
- Dates recompute per-render via `useMemo` keyed on `language`, `year`, `month` — count matches `getDaysInMonth`
- Labels localize through `date-fns`: `formatFullYear`, `formatAbbreviatedMonth`, `formatOrdinalDay` (Japanese etc. use ordinal day labels — English uses plain numbers)

## `getSafeValue` — leap-year / month-end clamping

When the user changes year or month, `getSafeValue` computes the new ISO string, clamping the day to the last valid day of the new month. Prevents 2024-02-29 from rolling over to 2023-02-29.

## Conform integration — two non-obvious gotchas

> [!warning]
> The two pitfalls below are non-obvious. Skip them and submission breaks silently.

### 1. Block native `input` events from bubbling to Conform

A native `addEventListener` on the container div stops child Select `input` events before they reach Conform's document-level handler. React `onInput` cannot do this — after SSR hydration both React and Conform handlers land on the same `document` node, so `stopPropagation` is a no-op between them. See `app/components/Form/YearMonthDay/index.tsx:64-68`.

### 2. Sync the hidden input's DOM value before calling `onChange`

`onChange` triggers Conform revalidation, which reads `FormData` from the DOM — not React state. The hidden input must be updated at DOM level first, before `onChange` fires. See `app/components/Form/YearMonthDay/index.tsx:78-82`.

## Caller pattern — `useInputControl`

Always wire via `useInputControl` — local `useState` desyncs from Conform once validation fails. See `app/components/Form/YearMonthDay/tests/index.stories.tsx:22-39` for the canonical usage and [[Component Testing]] for the test.

## Related

- [[Form Select]] — the primitive
- [[Conform]] — form library
- [[Form Components]] — overview
