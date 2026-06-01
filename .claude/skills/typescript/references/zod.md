# Zod 4 — Zod 3 → Zod 4 Migration Map

This project uses Zod 4. Claude's training leans Zod 3; several Zod 3 forms still type-check and lint clean, so nothing flags them until runtime or a `react-doctor` scan. Default to the Zod 4 form in every schema — form validation, API parsers, and standalone validators alike, not just Conform forms.

| Zod 3 — avoid | Zod 4 — use |
| --- | --- |
| `z.object({…}).strict()` | `z.strictObject({…})` |
| `z.object({…}).passthrough()` | `z.looseObject({…})` |
| `z.record(z.string())` | `z.record(z.string(), z.string())` |
| `z.string().email()` | `z.email()` |
| `z.string().url()` | `z.url()` |
| `z.string().uuid()` | `z.uuid()` |
| `z.string().datetime()` | `z.iso.datetime()` |
| `z.enum(['metric', 'imperial'])` | `z.literal(['imperial', 'metric'])` |
| `z.function().args(a).returns(b)` | `z.function({input: [a], output: b})` |
| `z.string({required_error: 'Required'})` | `z.string({error: 'Required'})` |

## Strict objects

`.strict()` / `.passthrough()` / `.strip()` are deprecated methods. Use the top-level factories.

```ts
// BAD — Zod 3 chained method
const Payload = z.object({id: z.string(), tags: z.array(z.string())}).strict();

// GOOD — Zod 4 factory
const Payload = z.strictObject({id: z.string(), tags: z.array(z.string())});
```

## String formats

Format validators moved from `ZodString` methods to top-level functions (`z.iso.*` for ISO date/time).

```ts
// BAD
z.object({email: z.string().email(), createdAt: z.string().datetime()});

// GOOD
z.object({email: z.email(), createdAt: z.iso.datetime()});
```

## Records

Both key and value schemas are required — single-arg `z.record()` is Zod 3.

```ts
// BAD
z.record(z.number());

// GOOD
z.record(z.string(), z.number());
```

## Functions

`.args()` / `.returns()` chaining is replaced by an `{input, output}` object; `input` is the array of argument schemas.

```ts
// BAD
const fn = z.function().args(z.string(), z.number()).returns(z.boolean());

// GOOD
const fn = z.function({input: [z.string(), z.number()], output: z.boolean()});
```

## Error customization

The unified `error` key replaces `message`, `required_error`, `invalid_type_error`, and `errorMap`.

```ts
// BAD
z.string({required_error: 'Required', invalid_type_error: 'Must be text'});
z.string().min(5, {message: 'Too short'});

// GOOD
z.string({error: 'Required'});
z.string().min(5, {error: 'Too short'});
```

## String unions — project convention

Prefer `z.literal([...])` over `z.enum()` for string unions, and sort the values alphanumerically. (`z.enum()` is valid Zod 4, but the project standardizes on the literal-array form.)

```ts
// BAD
z.enum(['metric', 'imperial']);

// GOOD
z.literal(['imperial', 'metric']);
```

## Conform forms

When wiring Conform, import from the `/v4` subpath — `import {parseWithZod} from '@conform-to/zod/v4'`. The default `@conform-to/zod` export targets Zod 3 and throws at runtime; typecheck, lint, and build do not catch it. Full wiring lives in the react-code skill's `references/conform-forms.md`.
