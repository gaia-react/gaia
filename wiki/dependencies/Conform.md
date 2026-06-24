---
type: dependency
status: active
package: '@conform-to/react, @conform-to/zod'
version: 1.19.4
role: form-validation
created: 2026-04-20
updated: 2026-04-21
tags: [dependency, forms]
---

# Conform

Form validation library used by [[Form Components]]. Pairs with [[Zod]] for the schema layer.

- `@conform-to/react`: `useForm`, `useInputControl`, `getFormProps`
- `@conform-to/zod`: `parseWithZod` for client + server validation

> [!warning] Use the `/v4` subpath
> Import from `@conform-to/zod/v4` (Zod v4 compatibility), not the root. Enforced by `.claude/skills/react-code/` (auto-loaded) and the `conform` subagent in [[Code Review Audit Agent]].

## Alternatives

[remix-forms](https://remix-forms.seasoned.cc/), [RVF](https://www.rvf-js.io/)

See [[Form Submit Flow]].
