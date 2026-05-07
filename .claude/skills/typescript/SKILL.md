---
name: typescript
description: Patterns and conventions for all TypeScript code. Use this skill whenever writing or reviewing TypeScript — naming identifiers, typing exports, choosing between type and interface, using Zod schemas, structuring function parameters, or enforcing code patterns like avoiding switch statements and enums.
model: haiku
---

# TypeScript

Patterns and conventions for all TypeScript code.

## Types

- `import type {}` for type-only imports: `import type {FC} from 'react'`

## Naming — camelCase

All identifiers use camelCase: Zod fields, form `name`/`id`/`htmlFor`, props, state, params.

**Exceptions (snake_case OK):**

- `types/database.ts` — mirrors DB column names
- Dynamic template literal names where variable part is already lowercase
- Environment variable names (`SUPABASE_URL`)

Map snake_case ↔ camelCase at API call boundaries, not in schemas or UI code.

## Naming — Descriptive and Self-Documenting

Follow Apple's Swift API Design Guidelines: names should be clear at the point of use, reading like prose. Favor long, descriptive names over short or abbreviated ones. Code should be readable without consulting documentation.

- **Functions and methods** — imperative verb phrases: `calculateProgressPercentageFromCompletedSets`, `processUserOnboardingProfile`
- **Parameters** — role, not type: `totalSeconds` not `n`, `emailAddress` not `s`
- **Variables** — what they hold: `restDurationInSeconds`, `submitButton`, `weightInputValue`
- **No abbreviations** — spell out unless universally known (`url`, `id`, `api`): `animationDurationInMilliseconds` not `animDur`
- **No redundant words** — `availableExercises` not `exerciseArray`, but don't sacrifice clarity for brevity

> **Exception — React event handlers** follow `handle{Action}{Element}` from the react-code skill
> (e.g. `handleClickSave`, `handleChangeInput`). The descriptive naming guidelines above apply
> to utilities, hooks, callbacks, and non-event-handler functions.

Read `references/naming-conventions.md` for extended BAD/GOOD examples of each naming pattern.

## Exported Functions — Explicit Return Types

All exported functions must have explicit return types.

**Exceptions:**

- Route loaders/actions (complex generics)
- React components typed with `FC<Props>` (return type provided by generic)

```tsx
// BAD
export const formatDate = (date: Date) => format(date, 'yyyy-MM-dd');

// GOOD
export const formatDate = (date: Date): string => format(date, 'yyyy-MM-dd');
```

## General Rules

- Use `type` not `interface` — interfaces support declaration merging, which creates unpredictable behavior; `type` is consistent and predictable
- Arrays: `string[]` not `Array<string>`
- Boolean naming: `^((can|has|hide|is|show)[A-Z]|checked|disabled|required)`

## Code Patterns

- No `switch` statements — use if/else chains or object maps; switch requires `break`, is prone to fallthrough bugs, and is harder to type-check exhaustively
- No TypeScript enums — use `as const` objects with derived types; enums compile to runtime objects with surprising behavior and don't tree-shake well
- JSX boolean props: always explicit `={true}` — makes props grep-able and avoids confusion when a prop is later refactored to a non-boolean type
- Max 3 function parameters — use an options object beyond that; call sites with 4+ positional args are hard to read and argument order mistakes are common

## Zod

- **`z.literal()` not `z.enum()`** — sort values alphanumerically

```tsx
// BAD
z.enum(['metric', 'imperial']);

// GOOD
z.literal(['imperial', 'metric']);
```
