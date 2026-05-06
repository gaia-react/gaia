---
type: component
path: app/components/Form/YearMonthDay/
status: active
language: typescript
purpose: Composite date-of-birth input — three locale-aware Selects + hidden ISO date
depends_on:
  - "[[Form Select]]"
  - "[[Conform]]"
  - "[[Form Components]]"
created: 2026-04-20
updated: 2026-05-04
tags: [component, forms, date, gotcha]
---

# Form YearMonthDay

Three [[Form Select]]s (year, month, day) feeding one hidden `<input type="hidden" name="dob">` that carries the ISO-8601 date string to the server. The canonical example of a custom stateful component that integrates with Conform.

## Why this composite exists

Native `<input type="date">` is locale-inconsistent across browsers and OSes. A three-select composite gives full control over labels (`date-fns` localizes year/month/day) and ordering, while the hidden ISO field keeps the server contract simple. The 120-year span ending 12 years ago is a privacy / minor-protection default — adjust per product policy.

## Conform integration — two non-obvious gotchas

> [!warning]
> The two pitfalls below are non-obvious. Skip them and submission breaks silently.

### 1. Block native `input` events from bubbling to Conform

A native `addEventListener` on the container div stops child Select `input` events before they reach Conform's document-level handler. React `onInput` cannot do this — after SSR hydration both React and Conform handlers land on the same `document` node, so `stopPropagation` is a no-op between them.

### 2. Sync the hidden input's DOM value before calling `onChange`

`onChange` triggers Conform revalidation, which reads `FormData` from the DOM — not React state. The hidden input must be updated at DOM level first, before `onChange` fires.

## `getSafeValue` — leap-year / month-end clamping

When the user changes year or month, `getSafeValue` computes the new ISO string, **clamping the day to the last valid day of the new month**. Prevents 2024-02-29 from rolling over to 2023-02-29 (which is not a real date).

## Caller pattern — `useInputControl`

Always wire via `useInputControl` — local `useState` desyncs from Conform once validation fails. See `app/components/Form/YearMonthDay/tests/index.stories.tsx` for the canonical usage and [[Component Testing]] for the test.

For prop signatures, query Serena (`.claude/rules/code-search.md`).

## Related

- [[Form Select]] — the primitive
- [[Conform]] — form library
- [[Form Components]] — overview
