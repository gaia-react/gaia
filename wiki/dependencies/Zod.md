---
type: dependency
status: active
package: zod
version: 4.4.3
role: schema-validation
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, validation]
---

# Zod

Schema validation. Used for form validation ([[Conform]]), API response parsing (`parsers.ts`), env var validation (`app/env.server.ts`), and TypeScript type inference. See [[API Service Pattern]] and [[Form Components]].

## v4 conventions

> [!key-insight] Zod v4 changes to enforce
>
> - Use `z.email()` not `z.string().email()` (deprecated)
> - Use `z.literal()` not `z.enum()` per project rules
> - Import Conform integration from `@conform-to/zod/v4`

See [[ESLint Fixes]] for the deprecation rule.

## Alternatives mentioned in docs

[Yup](https://github.com/jquense/yup), [Superstruct](https://github.com/ianstormtaylor/superstruct)
