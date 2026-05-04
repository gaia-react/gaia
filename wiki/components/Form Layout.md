---
type: component
path: app/components/Form/{Chain,FormActions,FormError}/
status: active
language: typescript
purpose: Form composition helpers — input rows, action rows, server-error banner
depends_on: [[Form Components]]
created: 2026-04-20
updated: 2026-05-04
tags: [component, forms, layout]
---

# Form Layout

Three small helpers that sit around actual input components.

- `Chain` — groups inputs into one chained field (currency+amount, country code+phone). CSS-module selectors round only the outermost corners so chained inputs read as a single visual unit.
- `FormActions` — horizontal button row, defaults to `justify-end`. The `'left'` alignment uses a `pl-0.5` optical nudge so a left-aligned primary button visually sits flush with the form edge.
- `FormError` — dismissible server-error banner that reads `error` from `useActionData`. Uses `<button type="button">` (prevents accidental submit on dismiss) and `<span role="alert">` (screen readers announce). Auto-resurfaces when a new error string arrives.

## Composition order

Place `<FormError />` at the top of the form, `<Chain>` around any grouped inputs, and `<FormActions>` last with submit/cancel buttons. This is convention, not enforcement.

For prop signatures, query Serena (`.claude/rules/code-search.md`).
