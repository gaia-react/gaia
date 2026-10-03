# Zod 4, Zod 3 → Zod 4 Migration Map

## Authoritative source, consult before judging a schema

Zod 4 reworked the API heavily from v3, and most v3 forms still type-check, so training memory is an unreliable guide here: it is easy to "correct" valid v4 code back into deprecated v3 code, or to reject a valid form as invalid. The array union `z.literal(['a', 'b'])` in the migration map below is real Zod 4, not a mistake. So before writing a schema you are unsure of, and especially before flagging or rewriting an existing Zod form as wrong, verify it against the installed Zod's official docs and treat them as authoritative over memory.

The docs are hosted, and the package advertises their URLs through the `package.json` auto-discovery convention. Read the URL from the installed package rather than hardcoding it:

```bash
node -p "require('./node_modules/zod/package.json').llmsFull"  # https://zod.dev/llms-full.txt, full concatenated docs
node -p "require('./node_modules/zod/package.json').llms"      # https://zod.dev/llms.txt, curated index
```

WebFetch that URL with a specific question instead of reading it into context. The full doc is ~65k tokens, but WebFetch distills it through a side model and returns only the answer, so context pays for the answer, not the doc. Ask for the exact signature and request a verbatim quote (e.g. "quote the exact `z.literal` signature for multiple values"). When the topic is unclear, WebFetch the smaller index first to find the right page. If the fields are absent, fall back to `https://zod.dev/llms-full.txt`.

Version caveat: these hosted docs track the latest published Zod, not the installed one, so confirm the installed major matches before trusting them with `node -p "require('./node_modules/zod/package.json').version"`. If the project is ever pinned behind what zod.dev serves, the docs run ahead of the installed API and the memory-versus-reality problem returns.

## Migration map

This project uses Zod 4; default to the Zod 4 form in every schema.

| Zod 3, avoid                             | Zod 4, use                            |
| ---------------------------------------- | ------------------------------------- |
| `z.object({…}).strict()`                 | `z.strictObject({…})`                 |
| `z.object({…}).passthrough()`            | `z.looseObject({…})`                  |
| `z.record(z.string())`                   | `z.record(z.string(), z.string())`    |
| `z.string().email()`                     | `z.email()`                           |
| `z.string().url()`                       | `z.url()`                             |
| `z.string().uuid()`                      | `z.uuid()`                            |
| `z.string().datetime()`                  | `z.iso.datetime()`                    |
| `z.enum(['metric', 'imperial'])`         | `z.literal(['imperial', 'metric'])`, values sorted alphanumerically (`z.enum()` is valid Zod 4, but the project standardizes on the literal-array form) |
| `z.function().args(a).returns(b)`        | `z.function({input: [a], output: b})` |
| `z.string({required_error: 'Required'})` | `z.string({error: 'Required'})`       |

## Strict objects

`.strict()` / `.passthrough()` / `.strip()` are deprecated methods. Use the top-level factories.

```ts
// BAD, Zod 3 chained method
const Payload = z.object({id: z.string(), tags: z.array(z.string())}).strict();

// GOOD, Zod 4 factory
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

Both key and value schemas are required, single-arg `z.record()` is Zod 3.

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
